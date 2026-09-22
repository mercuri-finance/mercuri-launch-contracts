// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IFeeManager} from "./interfaces/IFeeManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Immutable Uniswap v4 hook charging fees on the USDC leg of each swap.
/// @dev Only the configured PoolManager calls active callbacks; only GraduationManager initializes pools.
///      FeeManager is a proxy: governance can change accounting or block swaps. Returned rates are clamped to 500 bps.
///      Specified-USDC partial fills revert; token-specified partial fills are charged on realized USDC.
contract LaunchHook is IHooks {
    /// @notice Maximum rate used by this immutable hook's fee calculation, in basis points.
    /// @dev Does not guarantee FeeManager liveness or constrain arbitrary future accounting logic.
    uint256 public constant MAX_POOL_FEE_BPS = 500;

    /// @notice Immutable address permission bitmap validated at construction.
    uint160 public constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    uint256 private constant BPS = 10_000;
    uint256 private constant USDC_SCALE = 1e12;

    /// @notice Canonical Uniswap v4 caller and settlement contract.
    IPoolManager public immutable poolManager;
    /// @notice Governed fee manager proxy supplying pool rates and accounting for collected fees.
    IFeeManager public immutable feeManager;
    /// @notice Only address permitted to initialize pools using this hook.
    address public immutable graduationManager;
    /// @notice Arc USDC ERC-20 interface; 6-decimal transfers update the 18-decimal native balance.
    address public immutable usdc;

    error NotPoolManager();
    error NotGraduationManager();
    error HookNotImplemented();
    /// @dev The specified-USDC leg filled for less (or more) than `beforeSwap` charged the fee on
    ///      (price limit bound, or the pool could not fill the full requested amount).
    error PartialFill();

    /// @notice Emitted for every fee this hook takes out of a pool swap's USDC leg.
    /// @param token the launch token of the pool the swap ran against
    /// @param trader the wallet named by `hookData` whose EXISTING referrer earns the referral share, or
    ///        `address(0)` when `hookData` was empty or malformed (hookData is unauthenticated and never binds)
    /// @param usdcAmount fee taken, in 6-decimal USDC units — the FeeManager is credited `usdcAmount * 1e12`
    ///        native wei for the same fee
    event HookFee(address indexed token, address indexed trader, uint256 usdcAmount);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice Fixes peer addresses and validates the deployed address's hook permission bits.
    /// @param poolManager_ Canonical PoolManager, verified by the deployment procedure.
    /// @param feeManager_ Fee manager proxy; rates used by the hook are capped at 500 bps.
    /// @param graduationManager_ Graduation manager proxy trusted to initialize only token/USDC pools.
    /// @param usdc_ Arc's 6-decimal USDC ERC-20 interface.
    constructor(address poolManager_, address feeManager_, address graduationManager_, address usdc_) {
        poolManager = IPoolManager(poolManager_);
        feeManager = IFeeManager(feeManager_);
        graduationManager = graduationManager_;
        usdc = usdc_;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /// @inheritdoc IHooks
    /// @dev Additionally requires sender to be the configured GraduationManager.
    function beforeInitialize(address sender, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != graduationManager) revert NotGraduationManager();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Charges when USDC is the currency the swapper specified. hookData only attributes existing referrals.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (bool usdcIs0, address token) = _sides(key);
        bool exactInput = params.amountSpecified < 0;
        if (_specifiedIs0(params, exactInput) != usdcIs0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 amount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _fee(feeManager.tradeFeeBps(token), amount, exactInput);
        // Reject an unrepresentable delta before external work. Any later revert would also roll back
        // take/notify atomically; this ordering saves gas and makes the precondition explicit.
        int128 feeDelta = SafeCast.toInt128(SafeCast.toInt256(fee));
        _collect(token, fee, hookData);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(feeDelta, 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Charges when USDC is the unspecified currency. When USDC is the specified currency instead
    ///      (already charged in `beforeSwap`), verifies the pool filled exactly the fee-adjusted amount
    ///      `beforeSwap` asked for, so a partial fill (price limit, or insufficient pool depth) can never
    ///      leave the trader overcharged relative to what they actually got.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        (bool usdcIs0, address token) = _sides(key);
        bool exactInput = params.amountSpecified < 0;
        int128 rawUsdcDelta = usdcIs0 ? delta.amount0() : delta.amount1();
        // Widen before negation: abs(type(int128).min) fits uint256 but not int128.
        uint256 actualUsdc = rawUsdcDelta < 0 ? uint256(-int256(rawUsdcDelta)) : uint256(int256(rawUsdcDelta));

        if (_specifiedIs0(params, exactInput) == usdcIs0) {
            uint256 amount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 fee = _fee(feeManager.tradeFeeBps(token), amount, exactInput);
            uint256 expected = exactInput ? amount - fee : amount + fee;
            if (actualUsdc != expected) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }

        uint256 fee2 = _fee(feeManager.tradeFeeBps(token), actualUsdc, exactInput);
        // Same ordering rule as `beforeSwap`: cast first, take second.
        int128 feeDelta = SafeCast.toInt128(SafeCast.toInt256(fee2));
        _collect(token, fee2, hookData);
        return (IHooks.afterSwap.selector, feeDelta);
    }

    function _sides(PoolKey calldata key) private view returns (bool usdcIs0, address token) {
        usdcIs0 = Currency.unwrap(key.currency0) == usdc;
        token = Currency.unwrap(usdcIs0 ? key.currency1 : key.currency0);
    }

    /// @dev Exact input specifies the input currency; exact output specifies the output currency.
    function _specifiedIs0(SwapParams calldata params, bool exactInput) private pure returns (bool) {
        return exactInput == params.zeroForOne;
    }

    /// @dev Shared by `beforeSwap` and `afterSwap` so the two charging paths can never drift apart.
    ///      Exact input: `amount` is the gross the trader pays/the pool receives -> `amount * bps / BPS`.
    ///      Exact output: `amount` is the net the trader receives/the pool pays -> grossed up by
    ///      `amount * bps / (BPS - bps)`. Both round up (ceiling) so rounding always favours the
    ///      protocol, never the trader; the exact-input formula is capped at `amount` as a defensive
    ///      bound (mathematically already true for any `bps <= BPS`, but keeps a 1-unit dust swap from
    ///      ever being charged more than the swap itself under any future bps change).
    function _fee(uint256 bps, uint256 amount, bool exactInput) private pure returns (uint256 fee) {
        if (bps > MAX_POOL_FEE_BPS) bps = MAX_POOL_FEE_BPS;
        if (bps == 0) return 0;
        fee = exactInput
            ? Math.mulDiv(amount, bps, BPS, Math.Rounding.Ceil)
            : Math.mulDiv(amount, bps, BPS - bps, Math.Rounding.Ceil);
        if (exactInput && fee > amount) fee = amount;
    }

    function _collect(address token, uint256 fee, bytes calldata hookData) private {
        if (fee == 0) return;
        // hookData is unauthenticated: it only selects whose EXISTING referrer earns the referral share.
        // Decode as uint256 first: abi.decode(hookData, (address)) reverts on dirty upper bits, which
        // would let a third-party router's malformed hookData brick an otherwise-valid swap.
        address trader;
        if (hookData.length == 32) {
            uint256 raw = abi.decode(hookData, (uint256));
            if (raw <= type(uint160).max) trader = address(uint160(raw));
        }
        poolManager.take(Currency.wrap(usdc), address(feeManager), fee);
        feeManager.notifyHookFee(token, trader, fee * USDC_SCALE);
        emit HookFee(token, trader, fee);
    }

    // ---- unused hook points: their permission flags are off (see `FLAGS`), so the PoolManager never
    //      calls them. Adding/removing liquidity on the graduated pool is open to anyone; it cannot
    //      touch the locked full-range position, so there is nothing for this hook to police there.
    /// @inheritdoc IHooks
    /// @dev Disabled permission flag; always reverts HookNotImplemented.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    /// @dev Disabled permission flag; always reverts HookNotImplemented.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    /// @dev Disabled permission flag; always reverts HookNotImplemented.
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    /// @dev Disabled permission flag; always reverts HookNotImplemented.
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    /// @dev Disabled permission flag; always reverts HookNotImplemented.
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    /// @dev Disabled permission flag; always reverts HookNotImplemented.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    /// @dev Disabled permission flag; always reverts HookNotImplemented.
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
