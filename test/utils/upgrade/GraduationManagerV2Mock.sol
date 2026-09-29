// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IGraduationManager} from "../../../src/interfaces/IGraduationManager.sol";
import {ILaunchFactory} from "../../../src/interfaces/ILaunchFactory.sol";
import {IFeeManager} from "../../../src/interfaces/IFeeManager.sol";
import {LiquidityLocker} from "../../../src/LiquidityLocker.sol";

/// @dev Mirrors `GraduationManager`'s own local interface (never imported: it is intentionally private to that
///      file), so this V2 double can read a curve's declared pool allocation exactly the same way.
interface ICurvePoolSupply {
    function poolSupply() external view returns (uint256);
}

/// @dev V2 upgrade test double for GraduationManager, used to prove an upgrade applies to a curve that is
///      already live (created before the upgrade, not yet graduated). This is a full, independent copy of the
///      production contract's logic rather than an override: `graduate` is `external` in production (not
///      `virtual`, and Solidity does not allow calling `super.f()` on an `external` function from a derived
///      contract), so the only way to change ONE line of behaviour inside it without touching production
///      visibility is to hold a second copy. Every event, error, getter and the `_sqrtPriceX96` maths are
///      copied verbatim from `GraduationManager.sol`; the storage struct and its slot constant are IDENTICAL
///      (same namespace, same fields, same formula/value), so an upgraded proxy's existing state is read and
///      written unchanged. The only behavioural addition is the `GraduatedV2` event emitted at the end of
///      `graduate`.
contract GraduationManagerV2Mock is IGraduationManager, Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    uint24 public constant POOL_FEE = 0; // all fee logic lives in the hook
    int24 public constant TICK_SPACING = 200;
    uint256 private constant USDC_SCALE = 1e12;

    /// @custom:storage-location erc7201:launchpad.storage.GraduationManager
    struct GraduationManagerStorage {
        ILaunchFactory factory;
        IPoolManager poolManager;
        IPositionManager positionManager;
        IAllowanceTransfer permit2;
        address hook;
        LiquidityLocker locker;
        IFeeManager feeManager;
        address usdc;
    }

    // keccak256(abi.encode(uint256(keccak256("launchpad.storage.GraduationManager")) - 1)) & ~bytes32(uint256(0xff))
    // Identical value to GraduationManager's own (private) GRADUATION_MANAGER_STORAGE_LOCATION.
    bytes32 private constant GRADUATION_MANAGER_STORAGE_LOCATION =
        0xdfc244c108cce1dc0764199c84a7237715b67e0ee0a042edd6d8c27d20b1f700;

    event Graduated(
        address indexed token, bytes32 indexed poolId, uint160 sqrtPriceX96, uint256 usdcAmount, uint256 tokenAmount
    );
    event LiquidityLocked(address indexed token, bytes32 indexed poolId, uint256 indexed tokenId, uint128 liquidity);
    /// @notice V2-only: proves this exact call ran through the upgraded implementation.
    /// @param token the launch token that graduated through the V2 logic
    event GraduatedV2(address indexed token);

    error Unauthorized();
    error NothingToSeed();
    error InsufficientTokenBalance();
    error InvalidSqrtPrice(uint256 sqrtPriceX96);
    error RenounceDisabled();

    function _s() private pure returns (GraduationManagerStorage storage $) {
        assembly {
            $.slot := GRADUATION_MANAGER_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address factory_,
        address poolManager_,
        address positionManager_,
        address permit2_,
        address hook_,
        address locker_,
        address feeManager_,
        address usdc_,
        address owner_
    ) external initializer {
        __Ownable_init(owner_);
        GraduationManagerStorage storage $ = _s();
        $.factory = ILaunchFactory(factory_);
        $.poolManager = IPoolManager(poolManager_);
        $.positionManager = IPositionManager(positionManager_);
        $.permit2 = IAllowanceTransfer(permit2_);
        $.hook = hook_;
        $.locker = LiquidityLocker(locker_);
        $.feeManager = IFeeManager(feeManager_);
        $.usdc = usdc_;
    }

    // ---------------------------------------------------------------- getters

    function factory() external view returns (ILaunchFactory) {
        return _s().factory;
    }

    function poolManager() external view returns (IPoolManager) {
        return _s().poolManager;
    }

    function positionManager() external view returns (IPositionManager) {
        return _s().positionManager;
    }

    function permit2() external view returns (IAllowanceTransfer) {
        return _s().permit2;
    }

    function hook() external view returns (address) {
        return _s().hook;
    }

    function locker() external view returns (LiquidityLocker) {
        return _s().locker;
    }

    function feeManager() external view returns (IFeeManager) {
        return _s().feeManager;
    }

    function usdc() external view returns (address) {
        return _s().usdc;
    }

    // ---------------------------------------------------------------- graduation

    function poolKey(address token) public view returns (PoolKey memory) {
        GraduationManagerStorage storage $ = _s();
        address usdc_ = $.usdc;
        (address c0, address c1) = usdc_ < token ? (usdc_, token) : (token, usdc_);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, TICK_SPACING, IHooks($.hook));
    }

    function graduate(address token) external payable {
        GraduationManagerStorage storage $ = _s();
        if ($.factory.curveOf(token) != msg.sender) revert Unauthorized();
        address usdc_ = $.usdc;
        IPositionManager posm = $.positionManager;
        LiquidityLocker locker_ = $.locker;

        uint256 usdcAmount = msg.value / USDC_SCALE;
        uint256 tokenAmount = ICurvePoolSupply(msg.sender).poolSupply();
        if (usdcAmount == 0 || tokenAmount == 0) revert NothingToSeed();
        if (IERC20(token).balanceOf(address(this)) < tokenAmount) revert InsufficientTokenBalance();

        PoolKey memory key = poolKey(token);
        bool usdcIs0 = Currency.unwrap(key.currency0) == usdc_;
        (uint256 amount0, uint256 amount1) = usdcIs0 ? (usdcAmount, tokenAmount) : (tokenAmount, usdcAmount);

        uint160 sqrtPriceX96 = _sqrtPriceX96(amount0, amount1);
        $.poolManager.initialize(key, sqrtPriceX96);

        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        _approve(token);
        _approve(usdc_);

        uint256 tokenId = posm.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            amount0.toUint128(),
            amount1.toUint128(),
            address(locker_),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 usdcBefore = IERC20(usdc_).balanceOf(address(this));
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        locker_.record(token, tokenId);
        uint256 tokenConsumed = tokenBefore - IERC20(token).balanceOf(address(this));
        uint256 usdcConsumed = usdcBefore - IERC20(usdc_).balanceOf(address(this));

        bytes32 poolId = PoolId.unwrap(key.toId());
        emit Graduated(token, poolId, sqrtPriceX96, usdcConsumed, tokenConsumed);
        emit LiquidityLocked(token, poolId, tokenId, liquidity);

        uint256 tokenDust = IERC20(token).balanceOf(address(this));
        if (tokenDust != 0) IERC20(token).safeTransfer(address(locker_), tokenDust);
        uint256 usdcDust = msg.value - usdcConsumed * USDC_SCALE;
        if (usdcDust != 0) $.feeManager.accruePlatform{value: usdcDust}(token);

        // V2 addition: proves the upgraded implementation ran this call.
        emit GraduatedV2(token);
    }

    function _approve(address asset) private {
        GraduationManagerStorage storage $ = _s();
        address permit2_ = address($.permit2);
        IERC20(asset).forceApprove(permit2_, type(uint256).max);
        IAllowanceTransfer(permit2_).approve(asset, address($.positionManager), type(uint160).max, type(uint48).max);
    }

    /// @dev Upgrades are authorized by the owner (the timelock) only.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Disabled: renouncing would permanently freeze upgrades. Re-enabling it (to finalise the
    ///         system) would itself take a timelocked upgrade.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @dev Identical maths to `GraduationManager._sqrtPriceX96`; see that file for the derivation.
    function _sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        uint256 price = (amount1 >> 64 < amount0)
            ? Math.sqrt(Math.mulDiv(amount1, uint256(1) << 192, amount0))
            : Math.sqrt(Math.mulDiv(amount1, uint256(1) << 128, amount0)) << 32;
        if (price < TickMath.MIN_SQRT_PRICE || price >= TickMath.MAX_SQRT_PRICE) revert InvalidSqrtPrice(price);
        return price.toUint160();
    }
}
