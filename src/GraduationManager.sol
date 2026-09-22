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
import {IGraduationManager} from "./interfaces/IGraduationManager.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";
import {IFeeManager} from "./interfaces/IFeeManager.sol";
import {LiquidityLocker} from "./LiquidityLocker.sol";

/// @dev The calling curve's own declared pool allocation, read from `msg.sender` (already authenticated as
///      `factory.curveOf(token)`) rather than trusting this contract's token balance, which anyone can inflate
///      by donating tokens directly (the launch token is freely transferable).
interface ICurvePoolSupply {
    function poolSupply() external view returns (uint256);
}

/// @notice Turns a sold-out curve into a Uniswap v4 pool: initializes it at the curve's final price and mints
///         one full-range position, through Uniswap's PositionManager, straight to the LiquidityLocker.
/// @dev Deployed behind an `ERC1967Proxy` (UUPS). The owner (the timelock) is used ONLY to authorize upgrades;
///      it has no other power here. All state lives in the ERC-7201 namespace below; upgrades may only append.
///      Upgrades affect all pending/future graduations, including existing curves. Current call safety relies
///      on factory-authenticated, reentrancy-guarded curves, standard launch tokens and verified canonical
///      PoolManager/PositionManager/Permit2 dependencies. Reassess these assumptions for every upgrade.
contract GraduationManager is IGraduationManager, Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    /// @notice LP fee for newly seeded pools; swap fees are charged separately by the hook.
    uint24 public constant POOL_FEE = 0; // all fee logic lives in the hook
    /// @notice Tick spacing for full-range pool positions.
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
    bytes32 private constant GRADUATION_MANAGER_STORAGE_LOCATION =
        0xdfc244c108cce1dc0764199c84a7237715b67e0ee0a042edd6d8c27d20b1f700;

    /// @param token the launch token that graduated
    /// @param poolId the v4 pool id (`PoolKey.toId()`) of the pool this graduation created
    /// @param sqrtPriceX96 Q64.96 price the pool was initialized at, i.e. `sqrt(amount1 / amount0) * 2^96` in
    ///        raw currency units, which is the curve's final marginal price
    /// @param usdcAmount 6-decimal USDC actually pulled into the pool by the mint (post-mint balance delta;
    ///        excludes any USDC left over as dust)
    /// @param tokenAmount token amount (18-dec) actually pulled into the pool by the mint (post-mint balance
    ///        delta; excludes rounding dust and any tokens donated to this contract, both of which are swept to
    ///        the locker instead)
    event Graduated(
        address indexed token, bytes32 indexed poolId, uint160 sqrtPriceX96, uint256 usdcAmount, uint256 tokenAmount
    );
    /// @param token the launch token whose liquidity was locked
    /// @param poolId the v4 pool id the position belongs to
    /// @param tokenId the PositionManager ERC-721 id of the minted full-range position, now owned by the locker
    /// @param liquidity the position's liquidity as requested at mint time, in v4's internal liquidity units
    event LiquidityLocked(address indexed token, bytes32 indexed poolId, uint256 indexed tokenId, uint128 liquidity);

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
    /// @notice Locks the implementation against initialization; initialize only through a proxy constructor.
    constructor() {
        _disableInitializers();
    }

    /// @param owner_ the upgrade authority (the timelock)
    /// @notice Initializes system peers once through the proxy constructor.
    /// @param factory_ Factory proxy used to authenticate curves.
    /// @param poolManager_ Canonical Uniswap v4 PoolManager.
    /// @param positionManager_ Canonical PositionManager wired to poolManager_ and permit2_.
    /// @param permit2_ Canonical Permit2 allowance transfer contract.
    /// @param hook_ Immutable hook included in every pool key.
    /// @param locker_ Immutable recipient of position NFTs and token dust.
    /// @param feeManager_ Fee manager proxy receiving this graduation's USDC dust.
    /// @param usdc_ Arc's 6-decimal ERC-20 interface to native USDC.
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

    /// @notice Returns the configured factory peer.
    /// @return Address/interface fixed at initialization unless governance upgrades the implementation.
    function factory() external view returns (ILaunchFactory) {
        return _s().factory;
    }

    /// @notice Returns the configured poolManager peer.
    /// @return Address/interface fixed at initialization unless governance upgrades the implementation.
    function poolManager() external view returns (IPoolManager) {
        return _s().poolManager;
    }

    /// @notice Returns the configured positionManager peer.
    /// @return Address/interface fixed at initialization unless governance upgrades the implementation.
    function positionManager() external view returns (IPositionManager) {
        return _s().positionManager;
    }

    /// @notice Returns the configured permit2 peer.
    /// @return Address/interface fixed at initialization unless governance upgrades the implementation.
    function permit2() external view returns (IAllowanceTransfer) {
        return _s().permit2;
    }

    /// @notice Returns the configured hook peer.
    /// @return Address/interface fixed at initialization unless governance upgrades the implementation.
    function hook() external view returns (address) {
        return _s().hook;
    }

    /// @notice Returns the configured locker peer.
    /// @return Address/interface fixed at initialization unless governance upgrades the implementation.
    function locker() external view returns (LiquidityLocker) {
        return _s().locker;
    }

    /// @notice Returns the configured feeManager peer.
    /// @return Address/interface fixed at initialization unless governance upgrades the implementation.
    function feeManager() external view returns (IFeeManager) {
        return _s().feeManager;
    }

    /// @notice Returns the configured usdc peer.
    /// @return Address/interface fixed at initialization unless governance upgrades the implementation.
    function usdc() external view returns (address) {
        return _s().usdc;
    }

    // ---------------------------------------------------------------- graduation

    /// @notice Builds the deterministic pool key; does not assert that the pool exists.
    /// @param token Launch token to pair with the configured USDC interface.
    /// @return Sorted currencies, zero LP fee, 200 tick spacing and the configured hook.
    function poolKey(address token) public view returns (PoolKey memory) {
        GraduationManagerStorage storage $ = _s();
        address usdc_ = $.usdc;
        (address c0, address c1) = usdc_ < token ? (usdc_, token) : (token, usdc_);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, TICK_SPACING, IHooks($.hook));
    }

    /// @inheritdoc IGraduationManager
    function graduate(address token) external payable {
        GraduationManagerStorage storage $ = _s();
        if ($.factory.curveOf(token) != msg.sender) revert Unauthorized();
        address usdc_ = $.usdc;
        IPositionManager posm = $.positionManager;
        LiquidityLocker locker_ = $.locker;

        // On Arc the native balance and the USDC ERC-20 balance are the same balance.
        uint256 usdcAmount = msg.value / USDC_SCALE;
        // F1 ruling: the token leg is the curve's own declared `poolSupply`, never this contract's balance —
        // the launch token is freely transferable, so anyone could otherwise inflate the balance by donating
        // tokens before sell-out and skew the pool's opening price away from the curve's final price.
        uint256 tokenAmount = ICurvePoolSupply(msg.sender).poolSupply();
        if (usdcAmount == 0 || tokenAmount == 0) revert NothingToSeed();
        if (IERC20(token).balanceOf(address(this)) < tokenAmount) revert InsufficientTokenBalance();

        PoolKey memory key = poolKey(token);
        bool usdcIs0 = Currency.unwrap(key.currency0) == usdc_;
        (uint256 amount0, uint256 amount1) = usdcIs0 ? (usdcAmount, tokenAmount) : (tokenAmount, usdcAmount);

        // price = amount1 / amount0, so the pool opens exactly where the curve ended.
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

        // F5: report what actually entered the pool (post-mint balance deltas), not the pre-mint maximums —
        // MINT_POSITION's `liquidity` may consume slightly less than `amount0`/`amount1` after rounding.
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 usdcBefore = IERC20(usdc_).balanceOf(address(this));
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        locker_.record(token, tokenId);
        uint256 tokenConsumed = tokenBefore - IERC20(token).balanceOf(address(this));
        uint256 usdcConsumed = usdcBefore - IERC20(usdc_).balanceOf(address(this));

        bytes32 poolId = PoolId.unwrap(key.toId());
        emit Graduated(token, poolId, sqrtPriceX96, usdcConsumed, tokenConsumed);
        emit LiquidityLocked(token, poolId, tokenId, liquidity);

        // Rounding dust AND any donated tokens: locked away with the position, never sold. USDC dust goes to
        // the platform.
        uint256 tokenDust = IERC20(token).balanceOf(address(this));
        if (tokenDust != 0) IERC20(token).safeTransfer(address(locker_), tokenDust);
        // M3b: only what THIS graduation left over — the part of `msg.value` the mint did not consume, which
        // includes the sub-1e12 remainder that never fit in a whole 6-decimal pool unit. Deliberately NOT
        // `address(this).balance`: this contract has no `receive()`, but on Arc a hook `take` or any other
        // ERC-20 USDC transfer lands directly as native balance, so a stranger could otherwise donate USDC
        // here and have it attributed to whichever launch graduates next. Any such balance simply stays put
        // and is not this function's business.
        uint256 usdcDust = msg.value - usdcConsumed * USDC_SCALE;
        if (usdcDust != 0) $.feeManager.accruePlatform{value: usdcDust}(token);
    }

    /// @notice Approves canonical Permit2 and PositionManager for graduation settlement.
    /// @dev Unlimited allowances persist. Security depends on these verified external contracts.
    /// @param asset Token or USDC ERC-20 interface to approve.
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

    /// @notice Computes `sqrt(amount1 / amount0) * 2^96` (the Q64.96 `sqrtPriceX96` v4 pools are initialized
    ///         with) without overflowing, for any ratio Uniswap v4 can represent.
    /// @dev Fix round 2: `Math.mulDiv(amount1, 1 << 192, amount0)` panics (0x11) once `amount1 / amount0 ≥
    ///      2^64`, because the exact quotient `amount1 * 2^192 / amount0` then no longer fits in 256 bits —
    ///      hit on the live testnet whenever USDC is currency0 and the pool is small (token/usdc6 ratio easily
    ///      exceeds 2^64 ≈ 1.8e19). Two branches, chosen by an overflow-free comparison (never a try/catch of
    ///      the panic):
    ///        - `amount1 / amount0 < 2^64` (checked as `amount1 >> 64 < amount0`, which is exactly equivalent
    ///          and never overflows): the full-precision path `sqrt(mulDiv(amount1, 2^192, amount0))` is safe
    ///          and exact up to `sqrt`'s own ≤1-unit rounding.
    ///        - otherwise: `mulDiv(amount1, 2^192, amount0)` would overflow, so scale by `2^128` instead —
    ///          `mulDiv(amount1, 2^128, amount0) = ratio * 2^128` fits in 256 bits for any ratio Uniswap v4 can
    ///          represent (its maximum price is `< 2^128`, since `TickMath.MAX_SQRT_PRICE < 2^160` and price is
    ///          `sqrtPrice^2 / 2^192`). `sqrt(ratio * 2^128) = sqrt(ratio) * 2^64`; left-shifting by 32 gives
    ///          `sqrt(ratio) * 2^96`, i.e. the same quantity as the full-precision path, at the coarser but
    ///          still sub-wei-of-price precision of a 128-bit (instead of 192-bit) fixed-point input.
    ///      Either way the raw result is range-checked against `[TickMath.MIN_SQRT_PRICE,
    ///      TickMath.MAX_SQRT_PRICE)` and reverts with a named error rather than failing deep inside
    ///      `PoolManager.initialize`.
    function _sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        uint256 price = (amount1 >> 64 < amount0)
            ? Math.sqrt(Math.mulDiv(amount1, uint256(1) << 192, amount0))
            : Math.sqrt(Math.mulDiv(amount1, uint256(1) << 128, amount0)) << 32;
        if (price < TickMath.MIN_SQRT_PRICE || price >= TickMath.MAX_SQRT_PRICE) revert InvalidSqrtPrice(price);
        return price.toUint160();
    }
}
