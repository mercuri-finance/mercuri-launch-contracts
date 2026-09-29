// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaunchToken} from "../../../src/LaunchToken.sol";
import {LaunchConfig, CreateParams} from "../../../src/libraries/LaunchTypes.sol";
import {IFeeManager} from "../../../src/interfaces/IFeeManager.sol";
import {ILaunchFactory} from "../../../src/interfaces/ILaunchFactory.sol";
import {BondingCurveV2Mock} from "./BondingCurveV2Mock.sol";

/// @dev V2 upgrade test double for LaunchFactory, whose whole point is to prove the ONE thing an upgraded
///      factory is allowed to change: the curve bytecode used by FUTURE launches. `createToken` and
///      `computeAddresses` are `external`/`external view` in production (not `virtual`, and Solidity does not
///      allow calling `super.f()` on an `external` function from a derived contract), so this is a full,
///      independent copy of the production logic rather than an override, with `BondingCurve` swapped for
///      `BondingCurveV2Mock` in exactly those two functions. Every event, error, getter, the storage struct and
///      its slot constant (same namespace, same fields, same formula/value) are copied verbatim, so an upgraded
///      proxy's existing state — config, configHash, every `curveOf` entry, treasury, guardian, owner — is read
///      and written unchanged. A launch created before the upgrade keeps running on its own already-deployed
///      `BondingCurve` bytecode regardless: only `createToken`, called AFTER the upgrade, is affected.
contract LaunchFactoryV2Mock is
    ILaunchFactory,
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 private constant SEED_TOLERANCE = 1e12;

    /// @dev `config` (a nested struct) is deliberately the LAST member: `script/check-storage.sh` allows a
    ///      nested struct to grow only when nothing follows it in this struct, since it would otherwise shift
    ///      the physical slot of every later sibling. Never insert a field after `config`.
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
    // Identical value to LaunchFactory's own (private) LAUNCH_FACTORY_STORAGE_LOCATION.
    bytes32 private constant LAUNCH_FACTORY_STORAGE_LOCATION =
        0xc1a8159a4857d8d2f401e94ad256c9a5cf6e92a0c1811ade7755673b17a2be00;

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
    event ConfigUpdated(bytes32 configHash, LaunchConfig config);
    event TreasuryUpdated(address treasury);
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
    constructor() {
        _disableInitializers();
    }

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

    /// @dev The only line that differs from `LaunchFactory.createToken`: deploys `BondingCurveV2Mock` instead
    ///      of `BondingCurve`.
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
        BondingCurveV2Mock c = new BondingCurveV2Mock{salt: _salt(msg.sender, p.salt)}(
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

    /// @dev The only line that differs from `LaunchFactory.computeAddresses`: predicts the address of a
    ///      `BondingCurveV2Mock`, not a `BondingCurve`.
    function computeAddresses(address deployer, CreateParams calldata p)
        external
        view
        returns (address token, address curve)
    {
        LaunchFactoryStorage storage $ = _s();
        bytes memory curveInit = abi.encodePacked(
            type(BondingCurveV2Mock).creationCode,
            abi.encode($.config, p.name, p.symbol, p.metadataURI, address($.feeManager), $.graduationManager)
        );
        curve = Create2.computeAddress(_salt(deployer, p.salt), keccak256(curveInit));
        bytes memory tokenInit =
            abi.encodePacked(type(LaunchToken).creationCode, abi.encode(p.name, p.symbol, p.metadataURI));
        token = Create2.computeAddress(bytes32(0), keccak256(tokenInit), curve);
    }

    // ---------------------------------------------------------------- getters

    function config() external view returns (LaunchConfig memory) {
        return _s().config;
    }

    function feeManager() external view returns (IFeeManager) {
        return _s().feeManager;
    }

    function graduationManager() external view returns (address) {
        return _s().graduationManager;
    }

    function treasury() external view returns (address) {
        return _s().treasury;
    }

    function guardian() external view returns (address) {
        return _s().guardian;
    }

    function configHash() external view returns (bytes32) {
        return _s().configHash;
    }

    function curveOf(address token) external view returns (address) {
        return _s().curveOf[token];
    }

    // ---------------------------------------------------------------- owner

    function setConfig(LaunchConfig calldata cfg) external onlyOwner {
        _setConfig(cfg);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert InvalidParams();
        _s().treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setGuardian(address guardian_) external onlyOwner {
        _s().guardian = guardian_;
        emit GuardianUpdated(guardian_);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------- owner or guardian

    function pause() external onlyOwnerOrGuardian {
        _pause();
    }

    function unpause() external onlyOwnerOrGuardian {
        _unpause();
    }

    // ---------------------------------------------------------------- internals

    function _checkOwnerOrGuardian() private view {
        if (msg.sender == owner()) return;
        address guardian_ = _s().guardian;
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

        uint256 yEnd = cfg.virtualTokens - cfg.curveSupply;
        uint256 xEnd = Math.mulDiv(cfg.virtualUsdc, cfg.virtualTokens, yEnd, Math.Rounding.Ceil);
        uint256 needed = Math.mulDiv(cfg.poolSupply, xEnd, yEnd);
        if (needed > xEnd - cfg.virtualUsdc + SEED_TOLERANCE) revert InvalidConfig();
        if (needed < 1e18) revert InvalidConfig();

        LaunchFactoryStorage storage $ = _s();
        $.config = cfg;
        bytes32 hash = keccak256(abi.encode(cfg));
        $.configHash = hash;
        emit ConfigUpdated(hash, cfg);
    }
}
