// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BondingCurve} from "./BondingCurve.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {LaunchConfig, CreateParams} from "./libraries/LaunchTypes.sol";
import {IFeeManager} from "./interfaces/IFeeManager.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";

/// @notice Deploys launches. In this implementation the owner (the timelock) can change the terms of FUTURE launches, the
///         treasury address, the guardian, and upgrade this contract (which changes the curve code of FUTURE
///         launches only). The owner or the guardian can pause creation.
/// @dev Deployed behind an `ERC1967Proxy` (UUPS). All state lives in the ERC-7201 namespace below; upgrades may
///      only append fields to it as an operational policy, not an on-chain restriction. An arbitrary upgrade
///      can also change the registry GraduationManager uses to authenticate existing curves and redirect
///      future platform claims through treasury lookup; governance remains trusted.
contract LaunchFactory is
    ILaunchFactory,
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// @dev One 6-decimal USDC unit, the granularity the pool is seeded in.
    uint256 private constant SEED_TOLERANCE = 1e12;

    /// @dev `config` (a nested struct) is deliberately the LAST member: `script/check-storage.sh` allows a
    ///      nested struct to grow only when nothing follows it in this struct, since appending fields to any
    ///      earlier nested struct would shift the physical slot of every later sibling. Never insert a field
    ///      after `config`.
    /// @custom:storage-location erc7201:launchpad.storage.LaunchFactory
    struct LaunchFactoryStorage {
        IFeeManager feeManager;
        address graduationManager;
        address treasury;
        address guardian;
        bytes32 configHash;
        mapping(address token => address curve) curveOf;
        LaunchConfig config;
    }

    // keccak256(abi.encode(uint256(keccak256("launchpad.storage.LaunchFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LAUNCH_FACTORY_STORAGE_LOCATION =
        0xc1a8159a4857d8d2f401e94ad256c9a5cf6e92a0c1811ade7755673b17a2be00;

    /// @param token the newly deployed launch token
    /// @param curve the newly deployed bonding curve, which holds the whole supply at this point
    /// @param creator address that will earn the creator share of every fee on `token`
    /// @param deployer the wallet that sent `createToken`, i.e. who paid the launch fee and received any
    ///        initial-buy tokens; it also seeds the curve's CREATE2 salt
    /// @param name the token's ERC-20 name
    /// @param symbol the token's ERC-20 symbol
    /// @param metadataURI off-chain metadata location, stored on the token with no setter
    /// @param configHash `keccak256(abi.encode(config))` at creation time — the terms this launch is pinned to
    /// @param config the full parameter set snapshotted into the curve's immutables; never retroactive
    event TokenCreated(
        address indexed token,
        address indexed curve,
        address indexed creator,
        address deployer,
        string name,
        string symbol,
        string metadataURI,
        bytes32 configHash,
        LaunchConfig config
    );
    /// @notice Emitted by `initialize` and by every `setConfig`; affects FUTURE launches only.
    /// @param configHash `keccak256(abi.encode(config))`, the value `createToken` callers must now pin to
    /// @param config the full new parameter set
    event ConfigUpdated(bytes32 configHash, LaunchConfig config);
    /// @param treasury the address `FeeManager.claimPlatform()` will pay the platform bucket to from now on
    event TreasuryUpdated(address treasury);
    /// @notice Emitted by `initialize` and by every `setGuardian`.
    /// @param guardian the address that can now pause / unpause `createToken` (besides the owner); `address(0)`
    ///        means no guardian
    event GuardianUpdated(address guardian);

    error InvalidConfig();
    error InvalidParams();
    error ConfigChanged();
    error InsufficientLaunchFee();
    error NotOwnerOrGuardian();
    error RenounceDisabled();

    modifier onlyOwnerOrGuardian() {
        _checkOwnerOrGuardian();
        _;
    }

    function _s() private pure returns (LaunchFactoryStorage storage $) {
        assembly {
            $.slot := LAUNCH_FACTORY_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice Locks the implementation against initialization; initialize only through a proxy constructor.
    constructor() {
        _disableInitializers();
    }

    /// @param owner_ the timelock: sole authority for `setConfig`, `setTreasury`, `setGuardian` and upgrades
    /// @param guardian_ may pause / unpause `createToken` alongside the owner; `address(0)` is allowed and means
    ///        "no guardian": only the owner can then pause / unpause
    /// @notice Initializes the proxy and validates the first launch configuration.
    /// @param treasury_ Nonzero recipient for future platform claims.
    /// @param feeManager_ Fee manager proxy used by all launches.
    /// @param graduationManager_ Graduation manager proxy used by all launches.
    /// @param cfg Terms for future launches; USDC/token quantities use 18 decimals.
    function initialize(
        address owner_,
        address guardian_,
        address treasury_,
        address feeManager_,
        address graduationManager_,
        LaunchConfig calldata cfg
    ) external initializer {
        if (treasury_ == address(0)) revert InvalidParams();
        __Ownable_init(owner_);
        __Pausable_init();
        LaunchFactoryStorage storage $ = _s();
        $.feeManager = IFeeManager(feeManager_);
        $.graduationManager = graduationManager_;
        $.treasury = treasury_;
        $.guardian = guardian_;
        emit GuardianUpdated(guardian_);
        _setConfig(cfg);
    }

    /// @notice Creates an immutable curve and token on the terms expectedConfigHash pins, charging the launch
    ///         fee and spending any excess on an initial buy.
    /// @param expectedConfigHash MANDATORY (M4): must equal the current `configHash()`. There is no wildcard —
    ///        `bytes32(0)` reverts `ConfigChanged` like any other stale value — so a config change can never
    ///        silently land a creator on terms they did not quote. Read `configHash()` in the same call batch
    ///        that builds the transaction.
    /// @param p Metadata, fee recipient, optional referral and deployer-scoped salt.
    /// @param minTokensOut Minimum 18-decimal tokens for the optional initial buy; ignored if no buy value is sent.
    /// @return token Newly deployed fixed-supply token.
    /// @return curve Newly deployed curve holding the remaining allocation.
    function createToken(CreateParams calldata p, bytes32 expectedConfigHash, uint256 minTokensOut)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (address token, address curve)
    {
        _validate(p);
        LaunchFactoryStorage storage $ = _s();
        LaunchConfig memory cfg = $.config;
        bytes32 configHash_ = $.configHash;
        if (expectedConfigHash != configHash_) revert ConfigChanged();
        if (msg.value < cfg.launchFee) revert InsufficientLaunchFee();

        IFeeManager feeManager_ = $.feeManager;
        BondingCurve c = new BondingCurve{salt: _salt(msg.sender, p.salt)}(
            cfg, p.name, p.symbol, p.metadataURI, address(feeManager_), $.graduationManager
        );
        curve = address(c);
        token = address(c.token());
        $.curveOf[token] = curve;

        feeManager_.registerToken(token, curve, p.creator, cfg.tradeFeeBps, cfg.creatorShareBps, cfg.referrerShareBps);
        emit TokenCreated(token, curve, p.creator, msg.sender, p.name, p.symbol, p.metadataURI, configHash_, cfg);

        if (cfg.launchFee != 0) feeManager_.accruePlatform{value: cfg.launchFee}(token);
        uint256 buyValue = msg.value - cfg.launchFee;
        if (buyValue != 0) c.initialBuy{value: buyValue}(msg.sender, p.referrer, minTokensOut);
    }

    /// @notice Predicts CREATE2 addresses using the current factory implementation and configuration.
    /// @dev Configuration or implementation changes can change these predictions. Does not reserve either address.
    /// @param deployer Wallet that will call createToken; salts are scoped to this address.
    /// @param p Proposed launch parameters.
    /// @return token Predicted token address.
    /// @return curve Predicted curve address.
    function computeAddresses(address deployer, CreateParams calldata p)
        external
        view
        returns (address token, address curve)
    {
        LaunchFactoryStorage storage $ = _s();
        bytes memory curveInit = abi.encodePacked(
            type(BondingCurve).creationCode,
            abi.encode($.config, p.name, p.symbol, p.metadataURI, address($.feeManager), $.graduationManager)
        );
        curve = Create2.computeAddress(_salt(deployer, p.salt), keccak256(curveInit));
        bytes memory tokenInit =
            abi.encodePacked(type(LaunchToken).creationCode, abi.encode(p.name, p.symbol, p.metadataURI));
        token = Create2.computeAddress(bytes32(0), keccak256(tokenInit), curve);
    }

    // ---------------------------------------------------------------- getters

    /// @notice Returns the current terms for future launches.
    /// @return Configuration; existing curves retain their own snapshots.
    function config() external view returns (LaunchConfig memory) {
        return _s().config;
    }

    /// @notice Returns the fee manager proxy wired into new curves.
    /// @return Fee manager interface.
    function feeManager() external view returns (IFeeManager) {
        return _s().feeManager;
    }

    /// @notice Returns the graduation manager proxy wired into new curves.
    /// @return Graduation manager address.
    function graduationManager() external view returns (address) {
        return _s().graduationManager;
    }

    /// @inheritdoc ILaunchFactory
    function treasury() external view returns (address) {
        return _s().treasury;
    }

    /// @notice Returns the address allowed to pause and unpause creation alongside the owner.
    /// @return Guardian address; zero means only the owner can pause or unpause.
    function guardian() external view returns (address) {
        return _s().guardian;
    }

    /// @notice Returns the hash callers must pin when creating a launch.
    /// @return keccak256(abi.encode(config)); zero is not a wildcard.
    function configHash() external view returns (bytes32) {
        return _s().configHash;
    }

    /// @inheritdoc ILaunchFactory
    function curveOf(address token) external view returns (address) {
        return _s().curveOf[token];
    }

    // ---------------------------------------------------------------- owner

    /// @notice Changes terms for future launches; restricted to the timelock owner.
    /// @param cfg Validated configuration; does not modify existing curve snapshots.
    function setConfig(LaunchConfig calldata cfg) external onlyOwner {
        _setConfig(cfg);
    }

    /// @notice Changes the recipient of subsequent platform claims; restricted to the timelock owner.
    /// @param treasury_ Nonzero treasury address, including for already accrued platform funds.
    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert InvalidParams();
        _s().treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    /// @notice Sets the address that may pause / unpause `createToken` alongside the owner.
    /// @param guardian_ the new guardian; `address(0)` is allowed and means "no guardian" (only the owner can then
    ///        pause / unpause), i.e. it revokes the current guardian
    function setGuardian(address guardian_) external onlyOwner {
        _s().guardian = guardian_;
        emit GuardianUpdated(guardian_);
    }

    /// @notice Disabled: renouncing would permanently freeze upgrades, `setConfig`, `setTreasury` and
    ///         `setGuardian`. Re-enabling it (to finalise the system) would itself take a timelocked upgrade.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------- owner or guardian

    /// @notice Pauses new launch creation; callable by the owner or guardian.
    /// @dev Existing curve trades, graduations, pool swaps and fee claims remain available.
    function pause() external onlyOwnerOrGuardian {
        _pause();
    }

    /// @notice Resumes new launch creation; callable by the owner or guardian.
    function unpause() external onlyOwnerOrGuardian {
        _unpause();
    }

    // ---------------------------------------------------------------- internals

    function _checkOwnerOrGuardian() private view {
        if (msg.sender == owner()) return;
        address guardian_ = _s().guardian;
        // `address(0)` means "no guardian", never "the zero address is the guardian".
        if (guardian_ == address(0) || msg.sender != guardian_) revert NotOwnerOrGuardian();
    }

    /// @dev Upgrades are authorized by the owner (the timelock) only.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _salt(address deployer, bytes32 userSalt) private pure returns (bytes32) {
        return keccak256(abi.encode(deployer, userSalt));
    }

    function _validate(CreateParams calldata p) private pure {
        uint256 nameLen = bytes(p.name).length;
        uint256 symbolLen = bytes(p.symbol).length;
        if (
            p.creator == address(0) || nameLen == 0 || nameLen > 32 || symbolLen == 0 || symbolLen > 10
                || bytes(p.metadataURI).length > 256
        ) revert InvalidParams();
    }

    function _setConfig(LaunchConfig memory cfg) private {
        if (
            cfg.virtualUsdc == 0 || cfg.poolSupply == 0 || cfg.curveSupply + cfg.poolSupply != TOTAL_SUPPLY
                || cfg.virtualTokens <= cfg.curveSupply || cfg.tradeFeeBps > 500
                || uint256(cfg.creatorShareBps) + cfg.referrerShareBps > 10_000 || cfg.snipeStartBps > 9_900
                || cfg.snipeBlocks > 1_200 || cfg.launchFee > 100e18 || cfg.maxInitialBuyTokens > cfg.curveSupply
        ) revert InvalidConfig();

        // No-arbitrage seeding: pairing `poolSupply` at the curve's final price must not need more USDC than
        // the curve collects by selling out.
        uint256 yEnd = cfg.virtualTokens - cfg.curveSupply;
        uint256 xEnd = Math.mulDiv(cfg.virtualUsdc, cfg.virtualTokens, yEnd, Math.Rounding.Ceil);
        uint256 needed = Math.mulDiv(cfg.poolSupply, xEnd, yEnd);
        if (needed > xEnd - cfg.virtualUsdc + SEED_TOLERANCE) revert InvalidConfig();
        // Fix round 2: below 1 USDC (18-dec wei) of pool seeding, the 6-decimal pool leg has under a million
        // units of price resolution, and `GraduationManager.graduate` could even see `usdcAmount == 0` and
        // revert `NothingToSeed`. Reject at config time instead of leaving that reachable from a legitimate
        // launch.
        if (needed < 1e18) revert InvalidConfig();

        LaunchFactoryStorage storage $ = _s();
        $.config = cfg;
        bytes32 hash = keccak256(abi.encode(cfg));
        $.configHash = hash;
        emit ConfigUpdated(hash, cfg);
    }
}
