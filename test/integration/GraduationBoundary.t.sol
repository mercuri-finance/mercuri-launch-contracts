// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {LaunchConfig} from "../../src/libraries/LaunchTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @dev Reviewer coverage (a) and (f): the economics AT the graduation boundary, and inline graduation across
///      the whole `curveSupply`/`poolSupply` split the factory will accept.
contract GraduationBoundaryTest is LaunchFixture {
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    PoolSwapTest internal router;

    function setUp() public {
        _deploySystem();
        router = new PoolSwapTest(poolManager);
    }

    // ---------------------------------------------------------------- (a) no arbitrage at the boundary

    /// @dev Buys the last chunk of the curve — the buy that graduates it — and immediately dumps exactly those
    ///      tokens back into the pool that same buy created. If the pool ever opened ABOVE the curve's final
    ///      price, this round trip would be free money and every launch's pool would be drained by the buyer
    ///      who graduated it. Proceeds must come out strictly below cost, for any chunk size and both currency
    ///      orderings.
    function _assertNoBoundaryArbitrage(bool tokenBelowUsdc, uint256 chunkSeed) internal {
        (LaunchToken token, BondingCurve curve) = _createOrdered(tokenBelowUsdc);

        // Step 1: buy everything except the final chunk, priced straight off CurveMath so the split is exact.
        uint256 chunk = bound(chunkSeed, cfg.curveSupply / 100, cfg.curveSupply / 2);
        uint256 upfront = CurveMath.grossUp(
            CurveMath.costOfTokens(cfg.virtualUsdc, cfg.virtualTokens, cfg.curveSupply - chunk), cfg.tradeFeeBps, 0
        );
        vm.prank(alice);
        curve.buy{value: upfront}(0, address(0), type(uint256).max);
        uint256 remaining = cfg.curveSupply - curve.sold();
        assertGt(remaining, 0, "the first buy must not sell the curve out");
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Trading));

        // Step 2: the final chunk, which graduates the launch inside the same transaction.
        uint256 balanceBefore = bob.balance;
        vm.prank(bob);
        uint256 bought = curve.buy{value: 60_000e18}(0, address(0), type(uint256).max);
        uint256 cost = balanceBefore - bob.balance; // native USDC wei actually charged, refund excluded
        assertEq(bought, remaining, "the final buy is capped at what was left");
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));

        // Step 3: sell exactly those tokens straight back into the brand-new pool.
        PoolKey memory key = _key(address(token));
        bool usdcIs0 = Currency.unwrap(key.currency0) == USDC;
        bool zeroForOne = !usdcIs0; // paying the token leg
        vm.startPrank(bob);
        token.approve(address(router), type(uint256).max);
        BalanceDelta d = router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(bought),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();

        int256 usdcDelta = usdcIs0 ? d.amount0() : d.amount1();
        assertGt(usdcDelta, 0, "the dump must pay out something");
        // The pool's USDC leg is 6-decimal; the curve charged 18-decimal native wei.
        uint256 proceeds = uint256(usdcDelta) * 1e12;

        assertLt(proceeds, cost, "round-tripping the graduating buy through the fresh pool must lose money");
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_noArbitrageAtTheBoundary_tokenAboveUsdc(uint256 chunkSeed) public {
        _assertNoBoundaryArbitrage(false, chunkSeed);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_noArbitrageAtTheBoundary_tokenBelowUsdc(uint256 chunkSeed) public {
        _assertNoBoundaryArbitrage(true, chunkSeed);
    }

    // ---------------------------------------------------------------- (f) supply-split fuzz

    /// @dev The relation this fuzz uses, derived rather than assumed. With `C = curveSupply`,
    ///      `P = poolSupply`, `V = virtualTokens`, `U = virtualUsdc`:
    ///          `y_end = V - C`, `x_end = U*V / (V - C)`, `collected = x_end - U = U*C / (V - C)`,
    ///          `needed  = P * x_end / y_end = P*U*V / (V - C)^2`.
    ///      `LaunchFactory._setConfig`'s no-arbitrage condition is `needed <= collected`, i.e.
    ///          `P*V/(V - C) <= C`  ⟺  `P*V <= C*(V - C)`  ⟺  `V * (C - P) >= C^2`  ⟺  `V >= C^2 / (C - P)`
    ///      (which needs `C > P`, i.e. a pool fraction below 50%). The default config satisfies it with
    ///      equality: `800M^2 / 600M = 1,066.67M = virtualTokens`. So for ANY split the minimal consistent
    ///      choice is `virtualTokens = ceil(curveSupply^2 / (curveSupply - poolSupply))`, and that is what this
    ///      test uses. (The brief's suggested `curveSupply / (1 - f)` collapses to exactly `TOTAL_SUPPLY` for
    ///      every f and does NOT satisfy the condition — see the report.)
    function _consistentVirtualTokens(uint256 curveSupply, uint256 poolSupply) internal pure returns (uint256) {
        return Math.mulDiv(curveSupply, curveSupply, curveSupply - poolSupply, Math.Rounding.Ceil);
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_inlineGraduationAcrossSupplySplits(uint256 poolFractionBps, bool tokenBelowUsdc) public {
        uint256 poolBps = bound(poolFractionBps, 1_000, 4_000); // pool gets 10%..40% of the supply
        LaunchConfig memory c = cfg;
        c.poolSupply = TOTAL_SUPPLY * poolBps / 10_000;
        c.curveSupply = TOTAL_SUPPLY - c.poolSupply;
        c.virtualTokens = _consistentVirtualTokens(c.curveSupply, c.poolSupply);
        vm.prank(owner);
        factory.setConfig(c); // reverts InvalidConfig if the relation above were wrong
        cfg = c;

        (LaunchToken token, BondingCurve curve) = _createOrdered(tokenBelowUsdc);

        uint256 collected = Math.mulDiv(c.virtualUsdc, c.curveSupply, c.virtualTokens - c.curveSupply);
        vm.deal(bob, collected * 4 + 100e18);
        vm.prank(bob);
        curve.buy{value: collected * 3 + 50e18}(0, address(0), type(uint256).max);

        // The whole point: `GraduationManager.graduate`'s `amount0.toUint128()` / `amount1.toUint128()` mint
        // maximums, and the liquidity math behind them, must hold for every split the factory accepts.
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated), "inline graduation must not revert");
        assertTrue(locker.isLocked(address(token)));
        assertGt(posm.getPositionLiquidity(locker.positionOf(address(token))), 0);
        assertApproxEqRel(token.balanceOf(address(poolManager)), c.poolSupply, 1e12);
        assertEq(address(curve).balance, 0);
        assertEq(token.balanceOf(address(curve)), 0);
    }
}
