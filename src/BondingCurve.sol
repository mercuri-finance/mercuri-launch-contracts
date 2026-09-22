// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {LaunchConfig} from "./libraries/LaunchTypes.sol";
import {IFeeManager} from "./interfaces/IFeeManager.sol";
import {IGraduationManager} from "./interfaces/IGraduationManager.sol";

/// @notice One per launch. Sells `curveSupply` tokens on a constant-product curve over virtual reserves,
///         quoted in native (18-decimal) USDC, then hands `poolSupply` tokens and the collected USDC to the
///         GraduationManager during the final buy, or defers for a permissionless retry if graduation fails.
/// @dev Curve bytecode and config are immutable. Its FeeManager and GraduationManager dependencies are
///      upgradeable proxies: a governance upgrade can change fee processing or future graduation behavior.
contract BondingCurve is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Lifecycle: Trading accepts buys/sells; GraduationPending accepts sells/retry; Graduated closes curve trading.
    enum Phase {
        Trading,
        GraduationPending,
        Graduated
    }

    /// @dev Uniswap prices the pool in 6-decimal USDC; native USDC has 18.
    uint256 private constant USDC_SCALE = 1e12;

    /// @notice Gas that must still be available before the buy that sells the curve out is allowed to attempt
    ///         graduation inline. Measured on the live chain: such a buy uses 700–757k gas in total, 600–660k
    ///         of it inside graduation, so 1,000,000 leaves a comfortable margin over the worst observed cost.
    /// @dev C1. Without this floor a buy sent with a deliberately small gas limit sells the curve out while the
    ///      inner `try this.executeGraduation()` runs out of gas (EIP-150 forwards only 63/64 of what is left),
    ///      which used to record a deferral; a zero-proceeds `sell` in the same transaction then flipped the
    ///      phase back to `Trading`, so the permissionless `graduate()` retry never had a block in which it was
    ///      callable. Reverting the WHOLE buy instead leaves nothing half-done and forces every wallet's gas
    ///      estimation above the floor.
    uint256 public constant GRADUATION_GAS_FLOOR = 1_000_000;

    /// @notice Deploying factory proxy; sole initial-buy caller in the launch block.
    address public immutable factory;
    /// @notice Fixed-supply token deployed by this curve.
    LaunchToken public immutable token;
    /// @notice Fee manager proxy; address is immutable, implementation and fee accounting are governed.
    IFeeManager public immutable feeManager;
    /// @notice Graduation manager proxy; address is immutable, graduation behavior is governed.
    IGraduationManager public immutable graduationManager;
    /// @notice Block at deployment; anchors the block-based anti-snipe decay and initial-buy window.
    uint256 public immutable launchBlock;

    /// @notice Initial virtual USDC reserve in 18-decimal native wei; not an actual deposited balance.
    uint256 public immutable virtualUsdc;
    /// @notice Initial virtual token reserve in 18-decimal token units.
    uint256 public immutable virtualTokens;
    /// @notice Maximum net tokens sold by the curve, in 18-decimal units.
    uint256 public immutable curveSupply;
    /// @notice Token allocation reserved for graduation, in 18-decimal units.
    uint256 public immutable poolSupply;
    /// @notice Maximum tokens for the factory's tax-exempt initial buy, in 18-decimal units.
    uint256 public immutable maxInitialBuyTokens;
    /// @notice Curve trade fee in basis points; independent of future pool fee policy changes.
    uint256 public immutable tradeFeeBps;
    /// @notice Initial buy tax in basis points of the value remaining after the curve trade fee.
    uint256 public immutable snipeStartBps;
    /// @notice Number of blocks until the buy tax becomes zero; zero disables the tax.
    uint256 public immutable snipeBlocks;

    /// @notice USDC backing the tokens currently in circulation.
    uint256 public realUsdc;
    /// @notice Tokens sold and not yet sold back.
    uint256 public sold;
    /// @notice Current lifecycle phase; graduation failure may defer completion and a sell may reopen trading.
    Phase public phase;

    /// @param trader address credited with the tokens (for `initialBuy` this is the buyer the factory named,
    ///        not the factory)
    /// @param usdcIn NET native USDC (18-dec wei) actually priced on the curve, i.e. the amount that moved
    ///        `realUsdc`. The gross the trader paid is `usdcIn + fee + tax`; any unspent part of `msg.value`
    ///        was refunded and appears in NO field of this event
    /// @param tokensOut tokens (18-dec) transferred to `trader`
    /// @param fee trade fee in native USDC wei, already forwarded to the FeeManager
    /// @param tax snipe tax in native USDC wei, already forwarded to the FeeManager's platform bucket
    /// @param realUsdc the curve's USDC reserve (18-dec wei) AFTER this buy
    /// @param sold tokens (18-dec) sold and not yet sold back, AFTER this buy
    event Buy(
        address indexed trader, uint256 usdcIn, uint256 tokensOut, uint256 fee, uint256 tax, uint256 realUsdc, uint256 sold
    );
    /// @param trader address whose tokens were pulled in and who received `usdcOut`
    /// @param tokensIn tokens (18-dec) sold back to the curve
    /// @param usdcOut native USDC wei (18-dec) paid to `trader`, i.e. the gross proceeds minus `fee`
    /// @param fee trade fee in native USDC wei, taken out of the gross proceeds and forwarded to the FeeManager
    /// @param realUsdc the curve's USDC reserve (18-dec wei) AFTER this sell
    /// @param sold tokens (18-dec) sold and not yet sold back, AFTER this sell
    event Sell(
        address indexed trader, uint256 tokensIn, uint256 usdcOut, uint256 fee, uint256 realUsdc, uint256 sold
    );
    /// @notice Emitted once the curve has sold out and is handing its reserve to the GraduationManager.
    /// @param usdcForPool native USDC wei (18-dec) sent to the GraduationManager as the pool's USDC leg,
    ///        always a whole multiple of 1e12 so it converts to 6-decimal pool units without a remainder
    /// @param tokensForPool tokens (18-dec) sent to the GraduationManager as the pool's token leg, always
    ///        exactly `poolSupply`
    event CurveCompleted(uint256 usdcForPool, uint256 tokensForPool);
    /// @notice Emitted when graduation reverted but the final buy succeeded; anyone may retry with `graduate()`.
    /// @dev The gas floor rejects starved buys for the measured implementation. Nested-call out-of-gas may
    ///      still be indistinguishable from another revert; an upgraded graduation path must be gas-tested.
    /// @param reason the raw revert data returned by the failed `executeGraduation()` call, verbatim
    event GraduationDeferred(bytes reason);

    error Expired();
    error NotTrading();
    error NotPending();
    error ZeroAmount();
    error Slippage();
    error Unauthorized();
    error InitialBuyTooLarge();
    error TransferFailed();
    error InsufficientGasForGraduation();

    /// @notice Snapshots factory-validated terms and deploys a fixed-supply token into this curve.
    /// @dev No independent config validation; the canonical factory must validate cfg before construction.
    /// @param cfg Launch terms, with native USDC and token amounts in 18-decimal units.
    /// @param name_ Token display name.
    /// @param symbol_ Token display symbol.
    /// @param metadataURI_ Permanent token metadata reference.
    /// @param feeManager_ Fee manager proxy trusted to account for fees.
    /// @param graduationManager_ Graduation manager proxy receiving the pool allocation on graduation.
    constructor(
        LaunchConfig memory cfg,
        string memory name_,
        string memory symbol_,
        string memory metadataURI_,
        address feeManager_,
        address graduationManager_
    ) {
        factory = msg.sender;
        feeManager = IFeeManager(feeManager_);
        graduationManager = IGraduationManager(graduationManager_);
        launchBlock = block.number;

        virtualUsdc = cfg.virtualUsdc;
        virtualTokens = cfg.virtualTokens;
        curveSupply = cfg.curveSupply;
        poolSupply = cfg.poolSupply;
        maxInitialBuyTokens = cfg.maxInitialBuyTokens;
        tradeFeeBps = cfg.tradeFeeBps;
        snipeStartBps = cfg.snipeStartBps;
        snipeBlocks = cfg.snipeBlocks;

        // The token mints its whole supply to its deployer, i.e. this curve.
        token = new LaunchToken{salt: bytes32(0)}(name_, symbol_, metadataURI_);
    }

    // ---------------------------------------------------------------- trading

    /// @notice Buys tokens with msg.value in native USDC; the final buy is capped and excess value is refunded.
    /// @dev May graduate inline or enter GraduationPending. Requires Trading, positive output, slippage and deadline.
    /// @param minTokensOut Minimum 18-decimal tokens to receive.
    /// @param referrer Optional referral considered only at the wallet's first curve trade.
    /// @param deadline Latest permitted block timestamp in seconds; equality is accepted.
    /// @return tokensOut Tokens transferred to msg.sender in 18-decimal units.
    function buy(uint256 minTokensOut, address referrer, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (block.timestamp > deadline) revert Expired();
        tokensOut = _buy(msg.sender, referrer, minTokensOut, currentSnipeBps());
    }

    /// @notice Executes the factory's initial buy during the launch block, exempt from snipe tax and capped in size.
    /// @param buyer Token/refund recipient supplied by the factory.
    /// @param referrer Optional first-trade referral.
    /// @param minTokensOut Minimum 18-decimal tokens to receive.
    /// @return tokensOut Tokens transferred, capped by maxInitialBuyTokens.
    function initialBuy(address buyer, address referrer, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (msg.sender != factory || block.number != launchBlock) revert Unauthorized();
        tokensOut = _buy(buyer, referrer, minTokensOut, 0);
        // The cap is on what THIS call bought. It can only run in the launch block, before any other trade, so
        // `tokensOut == sold` here either way; bounding `tokensOut` states the intent directly instead of
        // relying on that coincidence.
        if (tokensOut > maxInitialBuyTokens) revert InitialBuyTooLarge();
    }

    /// @notice Sells tokens back to the curve. Allowed while Trading or GraduationPending — a sell while pending
    ///         drops `sold` back below `curveSupply` and reopens Trading, so a later buy that completes the curve
    ///         again can retry graduation; both are closed once Graduated.
    /// @dev Requires token approval. Rejects sales whose gross proceeds round down to zero; even a tiny sale with
    ///      nonzero proceeds can reopen Trading. This preserves an exit path while graduation is pending, subject
    ///      to slippage, available reserves and the governed FeeManager remaining operational.
    /// @param tokensIn Tokens to sell in 18-decimal units.
    /// @param minUsdcOut Minimum native USDC wei to receive after fees.
    /// @param referrer Optional referral considered only at the wallet's first curve trade.
    /// @param deadline Latest permitted block timestamp in seconds; equality is accepted.
    /// @return usdcOut Native USDC wei paid to msg.sender after the trade fee.
    function sell(uint256 tokensIn, uint256 minUsdcOut, address referrer, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdcOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (phase == Phase.Graduated) revert NotTrading();
        if (tokensIn == 0) revert ZeroAmount();

        uint256 fee;
        (usdcOut, fee) = quoteSell(tokensIn);
        if (usdcOut + fee == 0) revert ZeroAmount();
        if (usdcOut < minUsdcOut) revert Slippage();

        realUsdc -= usdcOut + fee;
        sold -= tokensIn;
        if (phase == Phase.GraduationPending) phase = Phase.Trading;
        emit Sell(msg.sender, tokensIn, usdcOut, fee, realUsdc, sold);

        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokensIn);
        feeManager.accrueTradeFee{value: fee}(address(token), msg.sender, referrer);
        _send(msg.sender, usdcOut);
    }

    // ---------------------------------------------------------------- graduation

    /// @notice Retry a graduation that failed inside the final buy. Anyone may call.
    function graduate() external nonReentrant {
        if (phase != Phase.GraduationPending) revert NotPending();
        this.executeGraduation();
    }

    /// @dev External only so it can be wrapped in try/catch; callable solely by this contract.
    /// @notice Executes graduation through an external self-call used for revert isolation.
    /// @dev Callable only by this curve while pending; not a public retry entry point. Use graduate().
    function executeGraduation() external {
        if (msg.sender != address(this)) revert Unauthorized();
        if (phase != Phase.GraduationPending) revert NotPending();
        phase = Phase.Graduated;

        // USDC that pairs `poolSupply` at the curve's final marginal price x / y, in whole 6-decimal units.
        uint256 x = virtualUsdc + realUsdc;
        uint256 y = virtualTokens - sold;
        uint256 usdcForPool = Math.min(realUsdc, Math.mulDiv(poolSupply, x, y));
        usdcForPool -= usdcForPool % USDC_SCALE;
        realUsdc = 0;
        emit CurveCompleted(usdcForPool, poolSupply);

        IERC20(address(token)).safeTransfer(address(graduationManager), poolSupply);
        graduationManager.graduate{value: usdcForPool}(address(token));

        // Rounding dust and any config surplus belong to the platform.
        uint256 rest = address(this).balance;
        if (rest != 0) feeManager.accruePlatform{value: rest}(address(token));
    }

    // ---------------------------------------------------------------- views

    /// @notice Returns the current buy tax based on elapsed blocks.
    /// @return Tax in basis points of gross value after the trade fee.
    function currentSnipeBps() public view returns (uint256) {
        return CurveMath.snipeBps(snipeStartBps, snipeBlocks, block.number - launchBlock);
    }

    /// @notice Quotes a gross native-USDC buy at current reserves and block tax.
    /// @dev Does not enforce phase, deadline or positive output; a quote is not a guarantee of execution.
    /// @param usdcIn Gross native USDC wei available (18 decimals).
    /// @return tokensOut Tokens quoted in 18-decimal units, capped at remaining curve inventory.
    /// @return usdcUsed Gross native USDC wei consumed including fee and tax; the balance would be refunded.
    /// @return fee Native USDC wei trade fee.
    /// @return tax Native USDC wei anti-snipe tax.
    function quoteBuy(uint256 usdcIn) external view returns (uint256 tokensOut, uint256 usdcUsed, uint256 fee, uint256 tax) {
        return _quoteBuy(usdcIn, currentSnipeBps());
    }

    /// @notice Quotes sale proceeds at current virtual and real reserves.
    /// @dev Does not enforce phase, ownership or tokensIn <= sold; callers must check trade eligibility separately.
    /// @param tokensIn Tokens to price in 18-decimal units.
    /// @return usdcOut Native USDC wei after fee.
    /// @return fee Native USDC wei trade fee, rounded down.
    function quoteSell(uint256 tokensIn) public view returns (uint256 usdcOut, uint256 fee) {
        uint256 gross = CurveMath.usdcForTokens(virtualUsdc + realUsdc, virtualTokens - sold, tokensIn);
        fee = gross * tradeFeeBps / CurveMath.BPS;
        usdcOut = gross - fee;
    }

    /// @notice Marginal price: native USDC wei per whole token (1e18 units). Returns 0 once Graduated, since
    ///         `realUsdc` is swept to the pool at that point and the pool becomes the price source.
    /// @return Native USDC wei per whole token, or zero after graduation.
    function price() external view returns (uint256) {
        if (phase == Phase.Graduated) return 0;
        return (virtualUsdc + realUsdc) * 1e18 / (virtualTokens - sold);
    }

    /// @notice Returns the net sold share of curve inventory.
    /// @return Progress in basis points, rounded down; 10,000 means sold out.
    function progressBps() external view returns (uint256) {
        return sold * CurveMath.BPS / curveSupply;
    }

    // ---------------------------------------------------------------- internals

    function _buy(address trader, address referrer, uint256 minTokensOut, uint256 taxBps)
        private
        returns (uint256 tokensOut)
    {
        if (phase != Phase.Trading) revert NotTrading();
        if (msg.value == 0) revert ZeroAmount();

        (uint256 tokens, uint256 used, uint256 fee, uint256 tax) = _quoteBuy(msg.value, taxBps);
        if (tokens == 0) revert ZeroAmount();
        if (tokens < minTokensOut) revert Slippage();
        tokensOut = tokens;

        uint256 net = used - fee - tax;
        realUsdc += net;
        sold += tokensOut;
        bool complete = sold == curveSupply;
        if (complete) phase = Phase.GraduationPending;
        emit Buy(trader, net, tokensOut, fee, tax, realUsdc, sold);

        IERC20(address(token)).safeTransfer(trader, tokensOut);
        feeManager.accrueTradeFee{value: fee}(address(token), trader, referrer);
        if (tax != 0) feeManager.accruePlatform{value: tax}(address(token));
        // Refund before graduating: graduation sweeps whatever balance is left.
        if (msg.value > used) _send(trader, msg.value - used);

        if (complete) {
            // Reject a buy below the calibrated graduation gas budget, rolling back the whole buy.
            // This floor must be re-tested against future GraduationManager implementations.
            if (gasleft() < GRADUATION_GAS_FLOOR) revert InsufficientGasForGraduation();

            // EIP-150 leaves roughly 1/64 of the caller's gas when the immediate child exhausts its budget.
            // Treat a similarly depleted catch path as insufficient gas and roll back the buy. This is a
            // heuristic, not an OOG classifier: an expensive ordinary revert may also roll back, while OOG
            // in a nested dependency can return enough gas to record a deferral. The fixed floor covers
            // measured current execution, not arbitrary future implementations or chain gas schedules.
            uint256 g0 = gasleft();
            try this.executeGraduation() {}
            catch (bytes memory reason) {
                if (gasleft() <= g0 / 63) revert InsufficientGasForGraduation();
                emit GraduationDeferred(reason);
            }
        }
    }

    function _quoteBuy(uint256 value, uint256 taxBps)
        private
        view
        returns (uint256 tokensOut, uint256 used, uint256 fee, uint256 tax)
    {
        uint256 net;
        (fee, tax, net) = CurveMath.splitBuy(value, tradeFeeBps, taxBps);
        uint256 x = virtualUsdc + realUsdc;
        uint256 y = virtualTokens - sold;
        uint256 remaining = curveSupply - sold;

        used = value;
        tokensOut = CurveMath.tokensForUsdc(x, y, net);
        if (tokensOut >= remaining) {
            // Final buy: sell exactly what is left and charge only for that.
            tokensOut = remaining;
            uint256 gross = CurveMath.grossUp(CurveMath.costOfTokens(x, y, remaining), tradeFeeBps, taxBps);
            if (gross < value) {
                used = gross;
                (fee, tax,) = CurveMath.splitBuy(gross, tradeFeeBps, taxBps);
            }
        }
    }

    /// @dev No `to == address(0)` guard: the only two call sites pass `msg.sender` (in `sell`) and the `trader`
    ///      a completed `_buy` just credited tokens to. `msg.sender` is never the zero address, and `trader` is
    ///      either `msg.sender` or the `buyer` the factory named, which `LaunchFactory.createToken` fixes to its
    ///      own `msg.sender`. Zero is therefore unreachable here; on Arc a native send to `address(0)` reverts
    ///      anyway, so even an unreachable case would fail closed rather than burn funds.
    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
