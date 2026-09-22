// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IFeeManager} from "./interfaces/IFeeManager.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";

/// @notice Splits every fee between creator, referrer and platform and holds the claimable balances.
///         Pull-based: a recipient that cannot receive funds only blocks its own claim.
/// @dev Deployed behind an `ERC1967Proxy` (UUPS). The owner (the timelock) is used ONLY to authorize upgrades;
///      it has no other power here. All state lives in the ERC-7201 namespace below; upgrades may only append.
///      This describes the current implementation, not a restriction on future code: a malicious upgrade
///      can alter pool rates, fee allocation, claims and accrued balances. Timelocked governance is trusted.
contract FeeManager is
    IFeeManager,
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    uint256 private constant BPS = 10_000;
    uint8 private constant SOURCE_CURVE = 0;
    uint8 private constant SOURCE_HOOK = 1;

    error RenounceDisabled();

    /// @custom:storage-location erc7201:launchpad.storage.FeeManager
    struct FeeManagerStorage {
        ILaunchFactory factory;
        address hook;
        address graduationManager;
        mapping(address token => TokenInfo) tokens;
        mapping(address account => uint256) balances;
        mapping(address trader => address) referrerOf;
        mapping(address trader => bool) hasTraded;
        uint256 platformBalance;
        uint256 totalOwed;
    }

    // keccak256(abi.encode(uint256(keccak256("launchpad.storage.FeeManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FEE_MANAGER_STORAGE_LOCATION = 0xc06a3792578c68935c12bd26baefb14bec09a70b6ceafb53cf611fda2f4dc100;

    function _s() private pure returns (FeeManagerStorage storage $) {
        assembly {
            $.slot := FEE_MANAGER_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice Locks the implementation against initialization; initialize only through a proxy constructor.
    constructor() {
        _disableInitializers();
    }

    /// @param owner_ the upgrade authority (the timelock)
    /// @notice Initializes the proxy once; the implementation constructor disables initialization.
    /// @param factory_ Factory proxy trusted to register launches and supply the treasury.
    /// @param hook_ Immutable hook authorized to report backed pool fees.
    /// @param graduationManager_ Graduation manager proxy recorded as a system peer.
    function initialize(address factory_, address hook_, address graduationManager_, address owner_)
        external
        initializer
    {
        __Ownable_init(owner_);
        FeeManagerStorage storage $ = _s();
        $.factory = ILaunchFactory(factory_);
        $.hook = hook_;
        $.graduationManager = graduationManager_;
    }

    // ---------------------------------------------------------------- getters

    /// @notice Returns the configured factory proxy.
    /// @return Factory used for registration authority and treasury lookup.
    function factory() external view returns (ILaunchFactory) {
        return _s().factory;
    }

    /// @notice Returns the sole hook authorized to report pool fees.
    /// @return Hook address.
    function hook() external view returns (address) {
        return _s().hook;
    }

    /// @notice Returns the configured graduation manager peer.
    /// @return Graduation manager proxy address; this getter confers no additional accrual authority.
    function graduationManager() external view returns (address) {
        return _s().graduationManager;
    }

    /// @inheritdoc IFeeManager
    function balances(address account) external view returns (uint256) {
        return _s().balances[account];
    }

    /// @inheritdoc IFeeManager
    function referrerOf(address trader) external view returns (address) {
        return _s().referrerOf[trader];
    }

    /// @inheritdoc IFeeManager
    function hasTraded(address trader) external view returns (bool) {
        return _s().hasTraded[trader];
    }

    /// @inheritdoc IFeeManager
    function platformBalance() external view returns (uint256) {
        return _s().platformBalance;
    }

    /// @inheritdoc IFeeManager
    function totalOwed() external view returns (uint256) {
        return _s().totalOwed;
    }

    // ---------------------------------------------------------------- fees

    /// @inheritdoc IFeeManager
    function registerToken(
        address token,
        address curve,
        address creator,
        uint16 tradeFeeBps_,
        uint16 creatorShareBps,
        uint16 referrerShareBps
    ) external {
        FeeManagerStorage storage $ = _s();
        if (msg.sender != address($.factory)) revert Unauthorized();
        if ($.tokens[token].curve != address(0)) revert AlreadyRegistered();
        // The immutable hook grosses up exact-output fees using BPS - tradeFeeBps_. Keep that
        // denominator positive even if a future factory implementation changes its policy limit.
        if (tradeFeeBps_ >= BPS) revert InvalidTradeFee();
        // Re-validated here rather than trusted: `LaunchFactory._setConfig` already enforces the same bound,
        // but this contract's `_split` would revert on `amount - creatorAmount - referrerAmount`
        // if it were ever registered with shares summing above 100%, so it does not take that on faith.
        if (uint256(creatorShareBps) + referrerShareBps > BPS) revert InvalidShares();
        $.tokens[token] = TokenInfo(curve, creator, tradeFeeBps_, creatorShareBps, referrerShareBps);
        emit TokenRegistered(token, curve, creator, tradeFeeBps_, creatorShareBps, referrerShareBps);
    }

    /// @inheritdoc IFeeManager
    function accrueTradeFee(address token, address trader, address referrer) external payable {
        FeeManagerStorage storage $ = _s();
        if (msg.sender != $.tokens[token].curve) revert Unauthorized();
        if (!$.hasTraded[trader]) {
            $.hasTraded[trader] = true;
            if ($.referrerOf[trader] == address(0) && referrer != address(0) && referrer != trader) {
                $.referrerOf[trader] = referrer;
                emit ReferralBound(trader, referrer);
            }
        }
        _split(token, trader, msg.value, SOURCE_CURVE);
    }

    /// @inheritdoc IFeeManager
    function accruePlatform(address token) external payable {
        FeeManagerStorage storage $ = _s();
        $.platformBalance += msg.value;
        $.totalOwed += msg.value;
        emit PlatformAccrued(token, msg.sender, msg.value);
    }

    /// @dev The hook has already transferred `amount` in through the USDC ERC-20 interface, which on Arc is
    ///      this contract's native balance. Never binds a referrer: hookData is unauthenticated.
    /// @inheritdoc IFeeManager
    function notifyHookFee(address token, address trader, uint256 amount) external {
        FeeManagerStorage storage $ = _s();
        if (msg.sender != $.hook) revert Unauthorized();
        if (address(this).balance < $.totalOwed + amount) revert Unbacked();
        _split(token, trader, amount, SOURCE_HOOK);
    }

    /// @inheritdoc IFeeManager
    function bindReferrer(address referrer) external {
        if (referrer == address(0) || referrer == msg.sender) revert InvalidReferrer();
        FeeManagerStorage storage $ = _s();
        if ($.hasTraded[msg.sender] || $.referrerOf[msg.sender] != address(0)) revert ReferrerLocked();
        $.referrerOf[msg.sender] = referrer;
        emit ReferralBound(msg.sender, referrer);
    }

    /// @inheritdoc IFeeManager
    function claim(address to) external nonReentrant returns (uint256 amount) {
        FeeManagerStorage storage $ = _s();
        amount = $.balances[msg.sender];
        if (amount == 0) revert NothingToClaim();
        $.balances[msg.sender] = 0;
        $.totalOwed -= amount;
        emit FeeClaimed(msg.sender, to, amount);
        _send(to, amount);
    }

    /// @inheritdoc IFeeManager
    function claimPlatform() external nonReentrant returns (uint256 amount) {
        FeeManagerStorage storage $ = _s();
        amount = $.platformBalance;
        if (amount == 0) revert NothingToClaim();
        $.platformBalance = 0;
        $.totalOwed -= amount;
        address to = $.factory.treasury();
        emit PlatformClaimed(to, amount);
        _send(to, amount);
    }

    /// @notice Credits native USDC this contract holds but owes to nobody to the platform bucket, so the
    ///         ledger's `totalOwed` accounts for every wei of the balance again. Permissionless: it can only
    ///         ever move value INTO the accounted-for side of the ledger, never out of anyone's balance.
    /// @dev Such a balance can arise from an ERC-20 USDC transfer on Arc or a forced native transfer.
    ///      Plain empty-data native calls revert because this implementation has no receive/fallback.
    ///      The canonical hook takes and notifies atomically. Leaving donated value unaccounted makes it
    ///      unclaimable, since `claim`/`claimPlatform` only ever pay out recorded balances.
    /// @return amount native USDC wei (18-dec) moved into the platform bucket
    function sweepUnaccounted() external returns (uint256 amount) {
        FeeManagerStorage storage $ = _s();
        amount = address(this).balance - $.totalOwed;
        if (amount == 0) revert NothingToClaim();
        $.platformBalance += amount;
        $.totalOwed += amount;
        emit PlatformAccrued(address(0), msg.sender, amount);
    }

    /// @inheritdoc IFeeManager
    function tradeFeeBps(address token) external view returns (uint16) {
        return _s().tokens[token].tradeFeeBps;
    }

    /// @inheritdoc IFeeManager
    function tokenInfo(address token) external view returns (TokenInfo memory) {
        return _s().tokens[token];
    }

    function _split(address token, address trader, uint256 amount, uint8 source) private {
        FeeManagerStorage storage $ = _s();
        TokenInfo memory info = $.tokens[token];
        address referrer = $.referrerOf[trader];
        uint256 creatorAmount = amount * info.creatorShareBps / BPS;
        uint256 referrerAmount = referrer == address(0) ? 0 : amount * info.referrerShareBps / BPS;
        uint256 platformAmount = amount - creatorAmount - referrerAmount;

        $.balances[info.creator] += creatorAmount;
        if (referrerAmount != 0) $.balances[referrer] += referrerAmount;
        $.platformBalance += platformAmount;
        $.totalOwed += amount;
        emit FeeAccrued(token, trader, info.creator, referrer, creatorAmount, referrerAmount, platformAmount, source);
    }

    /// @dev Upgrades are authorized by the owner (the timelock) only.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Disabled: renouncing would permanently freeze upgrades. Re-enabling it (to finalise the
    ///         system) would itself take a timelocked upgrade.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    function _send(address to, uint256 amount) private {
        if (to == address(0)) revert TransferFailed();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
