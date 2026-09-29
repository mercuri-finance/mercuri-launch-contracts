// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {SqrtPriceHarness} from "../utils/SqrtPriceHarness.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {GraduationManager} from "../../src/GraduationManager.sol";
import {LaunchConfig} from "../../src/libraries/LaunchTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @dev Property test over pool sizes x both currency orderings (the live-testnet overflow incident's shape),
///      plus direct unit/fuzz tests of `GraduationManager._sqrtPriceX96` through `SqrtPriceHarness`.
contract GraduationFuzzTest is LaunchFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SqrtPriceHarness internal harness;

    function setUp() public {
        _deploySystem();
        harness = new SqrtPriceHarness();
    }

    // ---------------------------------------------------------------- §3: graduation property test

    /// @dev Same formula `LaunchFactory._setConfig` uses for its no-arbitrage check: the curve's realUsdc when
    ///      it sells exactly `curveSupply` tokens is `x_end - virtualUsdc`, computed exactly rather than
    ///      guessed (deliberately duplicated from `GraduationTest` so the two suites stay independent).
    function _expectedCollectedUsdc(LaunchConfig memory c) internal pure returns (uint256) {
        uint256 yEnd = c.virtualTokens - c.curveSupply;
        uint256 xEnd = Math.mulDiv(c.virtualUsdc, c.virtualTokens, yEnd, Math.Rounding.Ceil);
        return xEnd - c.virtualUsdc;
    }

    /// @dev `assertApproxEqRel`-style relative tolerance (1e18 == 100%) accounting for 6-decimal USDC
    ///      granularity on small pools: max(1e-6, 2 / usdcUnitsSeeded).
    function _priceTolerance(uint256 usdcUnitsSeeded) internal pure returns (uint256) {
        uint256 granularityTolerance = Math.mulDiv(2, 1e18, usdcUnitsSeeded, Math.Rounding.Ceil);
        return granularityTolerance > 1e12 ? granularityTolerance : 1e12;
    }

    /// @dev Pool price (currency1/currency0) converted to native-USDC wei per whole token, computed the same
    ///      overflow-safe way as `GraduationTest._assertGraduated` (duplicated for the same reason as above).
    function _poolPriceWeiPerToken(PoolKey memory key) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        bool usdcIs0 = Currency.unwrap(key.currency0) == USDC;
        if (usdcIs0) {
            return Math.mulDiv(uint256(1) << 192, 1e30, sqrtPriceX96) / sqrtPriceX96;
        }
        uint256 scaled = Math.mulDiv(uint256(sqrtPriceX96), 1e30, uint256(1) << 96);
        return Math.mulDiv(scaled, uint256(sqrtPriceX96), uint256(1) << 96);
    }

    function _graduateAtSellOut(bool tokenBelowUsdc, uint256 virtualUsdcSeed)
        internal
        returns (LaunchToken token, BondingCurve curve, uint256 collected)
    {
        uint256 virtualUsdc = bound(virtualUsdcSeed, 0.4e18, 50_000e18);
        LaunchConfig memory c = cfg;
        c.virtualUsdc = virtualUsdc;
        vm.prank(owner);
        factory.setConfig(c);
        cfg = c;

        (token, curve) = _createOrdered(tokenBelowUsdc);
        collected = _expectedCollectedUsdc(cfg);

        // Generously oversized: the curve caps the final buy at `curveSupply` and refunds the rest, so any
        // value comfortably above what's needed (gross of fee/tax) reliably sells out the curve.
        uint256 buyValue = collected * 3 + 10e18;
        vm.prank(bob);
        curve.buy{value: buyValue}(0, address(0), type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_graduatesAtCurveFinalPrice_tokenAboveUsdc(uint256 virtualUsdcSeed) public {
        (LaunchToken token, BondingCurve curve, uint256 collected) = _graduateAtSellOut(false, virtualUsdcSeed);
        _assertGraduatedAtFinalPrice(token, curve, collected);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_graduatesAtCurveFinalPrice_tokenBelowUsdc(uint256 virtualUsdcSeed) public {
        (LaunchToken token, BondingCurve curve, uint256 collected) = _graduateAtSellOut(true, virtualUsdcSeed);
        _assertGraduatedAtFinalPrice(token, curve, collected);
    }

    function _assertGraduatedAtFinalPrice(LaunchToken token, BondingCurve curve, uint256 collected) internal view {
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated), "must graduate inside the buy");
        uint256 tokenId = locker.positionOf(address(token));
        assertGt(tokenId, 0, "locker must hold the position");
        assertTrue(locker.isLocked(address(token)));

        uint256 endPriceWeiPerToken =
            Math.mulDiv(cfg.virtualUsdc + collected, 1e18, cfg.virtualTokens - cfg.curveSupply);
        PoolKey memory key = _key(address(token));
        uint256 poolPrice = _poolPriceWeiPerToken(key);
        assertApproxEqRel(
            poolPrice,
            endPriceWeiPerToken,
            _priceTolerance(collected / 1e12),
            "pool must open at the curve's final price"
        );
    }

    /// @dev Reviewer coverage (f): a deliberately NARROW range that always lands in `_sqrtPriceX96`'s coarse
    ///      (`<< 32`) branch, which the wide fuzz above only visits incidentally. With the token sorting ABOVE
    ///      USDC, USDC is currency0, so `amount0` is the 6-decimal USDC leg and `amount1` is `poolSupply`; the
    ///      branch is coarse exactly when `amount1 >> 64 >= amount0`. For the default supply split the curve
    ///      collects `3 * virtualUsdc`, so `virtualUsdc` in [0.4e18, 3.6e18] gives `amount0` in
    ///      [1.2e6, 1.08e7] against `poolSupply >> 64 = 10,842,021` — the whole range is coarse, and the lower
    ///      end still seeds the pool with the >= 1 USDC `_setConfig` demands.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_graduatesInTheCoarseSqrtBranch_tokenAboveUsdc(uint256 virtualUsdcSeed) public {
        uint256 virtualUsdc = bound(virtualUsdcSeed, 0.4e18, 3.6e18);
        LaunchConfig memory c = cfg;
        c.virtualUsdc = virtualUsdc;
        c.launchFee = 0.1e18;
        vm.prank(owner);
        factory.setConfig(c);
        cfg = c;

        uint256 collected = _expectedCollectedUsdc(cfg);
        // The branch predicate, asserted on the exact amounts graduation will pass in.
        assertGe(cfg.poolSupply >> 64, collected / 1e12, "this range must take the coarse sqrt branch");
        assertGe(collected, 1e18, "and must still seed at least 1 USDC");

        (LaunchToken token, BondingCurve curve) = _createOrdered(false); // token ABOVE USDC => USDC is currency0
        PoolKey memory key = _key(address(token));
        assertEq(Currency.unwrap(key.currency0), USDC, "USDC must be currency0 for this ordering");

        vm.prank(bob);
        curve.buy{value: collected * 3 + 10e18}(0, address(0), type(uint256).max);

        _assertGraduatedAtFinalPrice(token, curve, collected);
    }

    // ---------------------------------------------------------------- §4: _sqrtPriceX96 direct unit tests

    function test_sqrtPriceX96_equalAmounts() public view {
        assertEq(harness.sqrtPriceX96(1e18, 1e18), uint160(1) << 96);
    }

    function test_sqrtPriceX96_ratioFour() public view {
        assertEq(harness.sqrtPriceX96(1e18, 4e18), uint160(2) << 96);
    }

    function test_sqrtPriceX96_justBelow2Pow64Boundary_usesFullPrecisionBranch() public view {
        // amount1 = 2^64 - 1, amount0 = 1: ratio just under 2^64, must take the full-precision branch and
        // match the exact sqrt to the last bit.
        uint256 amount1 = (uint256(1) << 64) - 1;
        uint160 result = harness.sqrtPriceX96(1, amount1);
        uint160 expected = uint160(Math.sqrt(Math.mulDiv(amount1, uint256(1) << 192, 1)));
        assertEq(result, expected);
    }

    function test_sqrtPriceX96_at2Pow64Boundary_usesCoarseBranch() public view {
        // amount1 = 2^64, amount0 = 1: ratio exactly 2^64 would overflow the full-precision mulDiv, so this
        // must take the coarse branch; the two branches agree to within the coarse branch's own precision.
        uint256 amount1 = uint256(1) << 64;
        uint160 result = harness.sqrtPriceX96(1, amount1);
        uint256 coarseExpected = Math.sqrt(Math.mulDiv(amount1, uint256(1) << 128, 1)) << 32;
        assertEq(result, coarseExpected);
        // Sanity: matches the true value (sqrt(2^64) * 2^96 = 2^32 * 2^96 = 2^128) exactly, since 2^64 is a
        // perfect square and introduces no rounding either way.
        assertEq(result, uint160(1) << 128);
    }

    function test_sqrtPriceX96_liveIncidentRatio() public view {
        // The exact live-testnet numbers: poolSupply (18-dec) against 1,500,000 6-decimal USDC units.
        uint256 amount0 = 1_500_000;
        uint256 amount1 = 200_000_000e18;
        uint160 result = harness.sqrtPriceX96(amount0, amount1);
        assertGt(result, TickMath.MIN_SQRT_PRICE);
        assertLt(result, TickMath.MAX_SQRT_PRICE);
        // Reconstructed ratio must match amount1/amount0 within the coarse branch's precision (ratio ~1.33e20
        // >= 2^64, so this takes the coarse branch).
        uint256 reconstructed = Math.mulDiv(uint256(result), uint256(result), uint256(1) << 192);
        assertApproxEqRel(reconstructed, amount1 / amount0, 1e9); // 1e-9 relative
    }

    function test_sqrtPriceX96_ratio2Pow100() public view {
        // amount1/amount0 = 2^100 (>= 2^64, coarse branch); 2^100 is a perfect square power, so the result is
        // exact: sqrt(2^100) * 2^96 = 2^50 * 2^96 = 2^146.
        uint160 result = harness.sqrtPriceX96(1, uint256(1) << 100);
        assertEq(result, uint160(1) << 146);
    }

    function test_sqrtPriceX96_verySmallRatio() public view {
        // The live incident's amounts with currency0/currency1 swapped: a tiny ratio, full-precision branch.
        uint256 amount0 = 200_000_000e18;
        uint256 amount1 = 1_500_000;
        uint160 result = harness.sqrtPriceX96(amount0, amount1);
        assertGt(result, 0);
        uint160 expected = uint160(Math.sqrt(Math.mulDiv(amount1, uint256(1) << 192, amount0)));
        assertEq(result, expected);
    }

    function test_sqrtPriceX96_reconstructionCounterexample() public view {
        testFuzz_sqrtPriceX96_reconstructsRatio(4e18, 591173564);
    }

    /// @dev Fuzz check: for any representable amounts, `_sqrtPriceX96`'s result squares back to the original
    ///      ratio within the precision the branch promises (full precision: exact to sqrt's own <=1-unit
    ///      rounding; coarse: precision of a 128-bit, not 192-bit, fixed-point input — bounded well within
    ///      1e-9 relative for the magnitudes exercised here).
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_sqrtPriceX96_reconstructsRatio(uint256 amount0Seed, uint256 amount1Seed) public view {
        uint256 amount0 = bound(amount0Seed, 1, 1e36);
        uint256 amount1 = bound(amount1Seed, 1, 1e36);
        uint160 result = harness.sqrtPriceX96(amount0, amount1);
        assertGe(result, TickMath.MIN_SQRT_PRICE);
        assertLt(result, TickMath.MAX_SQRT_PRICE);

        // Squaring into 1e18 units entails up to two integer truncations. Check the
        // sum of a two-unit absolute allowance and the original relative tolerance,
        // at EVERY magnitude (not only below the previous arbitrary 1e6 cutoff).
        uint256 scaled = Math.mulDiv(uint256(result), 1e18, uint256(1) << 96);
        uint256 reconstructedScaled = Math.mulDiv(scaled, uint256(result), uint256(1) << 96);
        uint256 trueRatioScaled = Math.mulDiv(amount1, 1e18, amount0);
        uint256 tolerance = 2 + Math.mulDiv(trueRatioScaled, 1e9, 1e18, Math.Rounding.Ceil);
        assertApproxEqAbs(reconstructedScaled, trueRatioScaled, tolerance);
    }
}
