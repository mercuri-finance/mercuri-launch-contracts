// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchHook} from "../../src/LaunchHook.sol";
import {LaunchConfig} from "../../src/libraries/LaunchTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract LaunchHookTest is LaunchFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolSwapTest router;
    address trader = makeAddr("trader");

    function setUp() public {
        _deploySystem();
        router = new PoolSwapTest(poolManager);
        vm.deal(trader, 100_000e18);
    }

    /// @dev A future FeeManager may return any uint16. Every swap shape must price
    ///      above-cap rates identically to 500 bps, including settlement and accounting.
    function test_feeCeilingBothOrderingsAllSwapShapes() public {
        assertEq(hook.MAX_POOL_FEE_BPS(), 500);
        uint16[3] memory excessive = [uint16(501), uint16(10_000), type(uint16).max];
        for (uint256 ordering; ordering < 2; ++ordering) {
            Ctx memory c = _setup(ordering == 0);
            for (uint256 shape; shape < 4; ++shape) {
                bool buy = shape < 2;
                int256 amount = shape == 0
                    ? -int256(100e6)
                    : shape == 1 ? int256(1_000_000e18) : shape == 2 ? -int256(1_000_000e18) : int256(50e6);
                uint256 snap = vm.snapshotState();
                vm.mockCall(
                    address(feeManager),
                    abi.encodeWithSignature("tradeFeeBps(address)", address(c.token)),
                    abi.encode(uint16(500))
                );
                (int256 expectedUsdc, int256 expectedToken) = _swap(c, buy, amount, "");
                uint256 expectedOwed = feeManager.totalOwed();
                uint256 expectedBalance = address(feeManager).balance;
                uint256 fee6 = (expectedOwed - c.owedBefore) / 1e12;
                uint256 gross = buy ? uint256(-expectedUsdc) : uint256(expectedUsdc) + fee6;
                assertApproxEqAbs(fee6, gross * 500 / 10_000, 1);
                _assertFee(c, fee6);
                assertTrue(vm.revertToState(snap));
                for (uint256 i; i < excessive.length; ++i) {
                    snap = vm.snapshotState();
                    vm.mockCall(
                        address(feeManager),
                        abi.encodeWithSignature("tradeFeeBps(address)", address(c.token)),
                        abi.encode(excessive[i])
                    );
                    (int256 actualUsdc, int256 actualToken) = _swap(c, buy, amount, "");
                    assertEq(actualUsdc, expectedUsdc);
                    assertEq(actualToken, expectedToken);
                    assertEq(feeManager.totalOwed(), expectedOwed);
                    assertEq(address(feeManager).balance, expectedBalance);
                    _assertFee(c, fee6);
                    assertTrue(vm.revertToState(snap));
                }
                vm.clearMockedCalls();
            }
        }
    }

    function test_feeCeilingPreservesZeroAndLowerRates() public {
        Ctx memory c = _setup(false);
        uint16[4] memory rates = [uint16(0), uint16(1), uint16(100), uint16(499)];
        for (uint256 i; i < rates.length; ++i) {
            uint256 snap = vm.snapshotState();
            vm.mockCall(
                address(feeManager),
                abi.encodeWithSignature("tradeFeeBps(address)", address(c.token)),
                abi.encode(rates[i])
            );
            (int256 paid,) = _swap(c, true, -100e6, "");
            assertEq(paid, -100e6);
            _assertFee(c, 100e6 * uint256(rates[i]) / 10_000);
            assertTrue(vm.revertToState(snap));
        }
        vm.clearMockedCalls();
    }

    /// @dev Synthetic callback boundary, not a claim that this economic amount is reachable in a pool.
    ///      Zero fee avoids moving synthetic funds; both currency orderings must accept the full int128 domain.
    function test_afterSwapHandlesMinimumSignedDeltaBothOrderings() public {
        for (uint256 i; i < 2; ++i) {
            Ctx memory c = _setup(i == 0);
            vm.mockCall(
                address(feeManager),
                abi.encodeWithSignature("tradeFeeBps(address)", address(c.token)),
                abi.encode(uint16(0))
            );
            SwapParams memory p =
                SwapParams({zeroForOne: c.usdcIs0, amountSpecified: -int256(uint256(1) << 127), sqrtPriceLimitX96: 0});
            BalanceDelta d = c.usdcIs0 ? toBalanceDelta(type(int128).min, 0) : toBalanceDelta(0, type(int128).min);
            vm.prank(address(poolManager));
            (bytes4 selector, int128 feeDelta) = hook.afterSwap(address(this), c.key, p, d, bytes(""));
            assertEq(selector, hook.afterSwap.selector);
            assertEq(feeDelta, 0);
            vm.clearMockedCalls();
        }
    }

    struct Ctx {
        LaunchToken token;
        PoolKey key;
        bool usdcIs0;
        uint256 creatorBefore;
        uint256 platformBefore;
        uint256 owedBefore;
    }

    function _setup(bool tokenBelowUsdc) internal returns (Ctx memory c) {
        BondingCurve curve;
        (c.token, curve) = _createOrdered(tokenBelowUsdc);
        _graduate(curve);
        c.key = _key(address(c.token));
        c.usdcIs0 = Currency.unwrap(c.key.currency0) == USDC;
        // Give the trader tokens to sell (bob holds the whole curve supply after graduating it).
        vm.prank(bob);
        c.token.transfer(trader, 10_000_000e18);
        vm.startPrank(trader);
        c.token.approve(address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.stopPrank();
        c.creatorBefore = feeManager.balances(creator);
        c.platformBefore = feeManager.platformBalance();
        c.owedBefore = feeManager.totalOwed();
    }

    /// @param usdcIn true when the trader pays USDC (a buy)
    function _swap(Ctx memory c, bool usdcIn, int256 amountSpecified, bytes memory hookData)
        internal
        returns (int256 usdcDelta, int256 tokenDelta)
    {
        bool zeroForOne = usdcIn == c.usdcIs0;
        return _swapWithLimit(
            c, usdcIn, amountSpecified, hookData, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    /// @param usdcIn true when the trader pays USDC (a buy)
    function _swapWithLimit(
        Ctx memory c,
        bool usdcIn,
        int256 amountSpecified,
        bytes memory hookData,
        uint160 sqrtPriceLimitX96
    ) internal returns (int256 usdcDelta, int256 tokenDelta) {
        bool zeroForOne = usdcIn == c.usdcIs0;
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        vm.prank(trader);
        BalanceDelta d = router.swap(c.key, p, PoolSwapTest.TestSettings(false, false), hookData);
        (int256 d0, int256 d1) = (d.amount0(), d.amount1());
        (usdcDelta, tokenDelta) = c.usdcIs0 ? (d0, d1) : (d1, d0);
    }

    /// @dev Performs a swap expected to revert (the PoolManager wraps hook reverts), returning the raw
    ///      revert data so callers can look for a specific selector inside it.
    function _swapExpectingRevert(Ctx memory c, bool usdcIn, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (bytes memory revertData)
    {
        bool zeroForOne = usdcIn == c.usdcIs0;
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        vm.prank(trader);
        (bool success, bytes memory data) =
            address(router).call(abi.encodeCall(router.swap, (c.key, p, PoolSwapTest.TestSettings(false, false), "")));
        assertFalse(success, "expected the swap to revert");
        revertData = data;
    }

    /// @dev A tiny price-limit nudge off the pool's current price, in the trade's direction, so a large
    ///      swap request fills only a sliver before the limit binds.
    function _tightLimit(PoolKey memory key, bool zeroForOne) internal view returns (uint160) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint160 nudge = sqrtPriceX96 / 1_000_000 + 1;
        return zeroForOne ? sqrtPriceX96 - nudge : sqrtPriceX96 + nudge;
    }

    function _containsSelector(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i <= data.length - 4; i++) {
            bytes4 chunk;
            assembly {
                chunk := mload(add(add(data, 0x20), i))
            }
            if (chunk == selector) return true;
        }
        return false;
    }

    function _assertFee(Ctx memory c, uint256 expectedFee6) internal view {
        uint256 feeWei = expectedFee6 * 1e12;
        assertEq(feeManager.totalOwed() - c.owedBefore, feeWei, "fee accounted");
        assertEq(feeManager.balances(creator) - c.creatorBefore, feeWei / 2, "creator half");
        assertEq(feeManager.platformBalance() - c.platformBefore, feeWei - feeWei / 2, "platform half (no referrer)");
        assertGe(address(feeManager).balance, feeManager.totalOwed(), "fees are backed");
    }

    // ---- the four swap shapes, token above USDC (USDC is currency0)

    function test_buyExactUsdcIn() public {
        Ctx memory c = _setup(false);
        (int256 usdcDelta, int256 tokenDelta) = _swap(c, true, -100e6, "");
        assertEq(usdcDelta, -100e6); // trader pays exactly what they specified
        assertGt(tokenDelta, 0);
        _assertFee(c, 1e6);
    }

    function test_sellExactTokensIn() public {
        Ctx memory c = _setup(false);
        (int256 usdcDelta, int256 tokenDelta) = _swap(c, false, -1_000_000e18, "");
        assertEq(tokenDelta, -1_000_000e18);
        uint256 net = uint256(usdcDelta);
        uint256 fee = feeManager.totalOwed() - c.owedBefore;
        // fee is 1% of the gross the pool paid out
        assertApproxEqAbs(fee / 1e12, (net + fee / 1e12) / 100, 1);
        _assertFee(c, fee / 1e12);
    }

    function test_buyExactTokensOut() public {
        Ctx memory c = _setup(false);
        (int256 usdcDelta, int256 tokenDelta) = _swap(c, true, 1_000_000e18, "");
        assertEq(tokenDelta, 1_000_000e18);
        uint256 paid = uint256(-usdcDelta);
        uint256 fee = (feeManager.totalOwed() - c.owedBefore) / 1e12;
        assertApproxEqAbs(fee, paid / 100, 1); // 1% of everything the trader paid
        _assertFee(c, fee);
    }

    function test_sellExactUsdcOut() public {
        Ctx memory c = _setup(false);
        (int256 usdcDelta,) = _swap(c, false, 50e6, "");
        assertEq(usdcDelta, 50e6); // trader receives exactly what they specified
        uint256 fee = (feeManager.totalOwed() - c.owedBefore) / 1e12;
        assertApproxEqAbs(fee, uint256(50e6) * 100 / 9_900, 1);
        _assertFee(c, fee);
    }

    // ---- same four with the token below USDC (USDC is currency1)

    function test_buyExactUsdcIn_tokenBelow() public {
        Ctx memory c = _setup(true);
        (int256 usdcDelta,) = _swap(c, true, -100e6, "");
        assertEq(usdcDelta, -100e6);
        _assertFee(c, 1e6);
    }

    function test_sellExactTokensIn_tokenBelow() public {
        Ctx memory c = _setup(true);
        (int256 usdcDelta, int256 tokenDelta) = _swap(c, false, -1_000_000e18, "");
        assertEq(tokenDelta, -1_000_000e18);
        uint256 fee = (feeManager.totalOwed() - c.owedBefore) / 1e12;
        assertApproxEqAbs(fee, (uint256(usdcDelta) + fee) / 100, 1);
        _assertFee(c, fee);
    }

    function test_buyExactTokensOut_tokenBelow() public {
        Ctx memory c = _setup(true);
        (int256 usdcDelta, int256 tokenDelta) = _swap(c, true, 1_000_000e18, "");
        assertEq(tokenDelta, 1_000_000e18);
        uint256 fee = (feeManager.totalOwed() - c.owedBefore) / 1e12;
        assertApproxEqAbs(fee, uint256(-usdcDelta) / 100, 1);
        _assertFee(c, fee);
    }

    function test_sellExactUsdcOut_tokenBelow() public {
        Ctx memory c = _setup(true);
        (int256 usdcDelta,) = _swap(c, false, 50e6, "");
        assertEq(usdcDelta, 50e6);
        uint256 fee = (feeManager.totalOwed() - c.owedBefore) / 1e12;
        assertApproxEqAbs(fee, uint256(50e6) * 100 / 9_900, 1);
        _assertFee(c, fee);
    }

    // ---- F1: never overcharge a partial fill on the specified-USDC shapes; revert instead

    function test_partialFill_exactOutputSellExceedsPool_reverts() public {
        Ctx memory c = _setup(false);
        // Ask for far more USDC out than the ~18,000 USDC pool holds; a full-range CPMM position can
        // asymptotically approach but never deliver that much, so the fill comes up short.
        bool zeroForOne = false == c.usdcIs0;
        bytes memory data = _swapExpectingRevert(
            c, false, 1_000_000e6, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        assertTrue(_containsSelector(data, LaunchHook.PartialFill.selector), "revert data should carry PartialFill");
    }

    function test_partialFill_exactInputBuyPriceLimitBinds_reverts() public {
        Ctx memory c = _setup(false);
        bool zeroForOne = true == c.usdcIs0; // usdcIn = true -> a buy
        uint160 limit = _tightLimit(c.key, zeroForOne);
        bytes memory data = _swapExpectingRevert(c, true, -100e6, limit);
        assertTrue(_containsSelector(data, LaunchHook.PartialFill.selector), "revert data should carry PartialFill");
    }

    function test_partialFill_unspecifiedSell_chargesRealizedFee() public {
        Ctx memory c = _setup(false);
        bool zeroForOne = false == c.usdcIs0; // usdcIn = false -> a sell; USDC is unspecified here
        uint160 limit = _tightLimit(c.key, zeroForOne);
        int256 requested = -1_000_000e18;
        (int256 usdcDelta, int256 tokenDelta) = _swapWithLimit(c, false, requested, "", limit);
        // Reviewer coverage (b): the point of this test is the PARTIAL fill, so assert it was one — the pool
        // took strictly fewer tokens than the swap asked it to, because the price limit bound first.
        assertLt(_abs(tokenDelta), _abs(requested), "the fill must be partial, not full");
        assertGt(_abs(tokenDelta), 0, "but something must have filled");
        uint256 net = uint256(usdcDelta);
        uint256 fee = feeManager.totalOwed() - c.owedBefore;
        assertGt(fee, 0);
        // fee is ~1% of the realized (partially filled) gross USDC leg, not of the requested token amount
        assertApproxEqAbs(fee / 1e12, (net + fee / 1e12) / 100, 1);
        _assertFee(c, fee / 1e12);
    }

    function test_partialFill_unspecifiedBuy_chargesRealizedFee() public {
        Ctx memory c = _setup(false);
        bool zeroForOne = true == c.usdcIs0; // usdcIn = true -> a buy; USDC is unspecified here
        uint160 limit = _tightLimit(c.key, zeroForOne);
        int256 requested = 1_000_000e18;
        (int256 usdcDelta, int256 tokenDelta) = _swapWithLimit(c, true, requested, "", limit);
        // Reviewer coverage (b): exact-OUTPUT token request, price limit binding -> fewer tokens delivered
        // than asked for.
        assertLt(_abs(tokenDelta), _abs(requested), "the fill must be partial, not full");
        assertGt(_abs(tokenDelta), 0, "but something must have filled");
        uint256 paid = uint256(-usdcDelta);
        uint256 fee = (feeManager.totalOwed() - c.owedBefore) / 1e12;
        assertGt(fee, 0);
        assertApproxEqAbs(fee, paid / 100, 1);
        _assertFee(c, fee);
    }

    /// @dev Reviewer coverage (b): a control for the two tests above — without the tight price limit the SAME
    ///      requests fill completely, so their "less than requested" assertions are testing the limit, not a
    ///      pool that simply never fills anything.
    function test_partialFillControl_sameRequestsFillFullyWithoutTheLimit() public {
        Ctx memory c = _setup(false);
        (, int256 tokenDeltaSell) = _swap(c, false, -1_000_000e18, "");
        assertEq(tokenDeltaSell, -1_000_000e18, "control: exact-input sell fills in full");

        Ctx memory c2 = _setup(true);
        (, int256 tokenDeltaBuy) = _swap(c2, true, 1_000_000e18, "");
        assertEq(tokenDeltaBuy, 1_000_000e18, "control: exact-output buy fills in full");
    }

    function _abs(int256 v) internal pure returns (uint256) {
        return v < 0 ? uint256(-v) : uint256(v);
    }

    // ---- referral

    function test_hookDataTraderPaysTheirExistingReferrer() public {
        Ctx memory c = _setup(false);
        vm.prank(trader);
        feeManager.bindReferrer(referrer);
        _swap(c, true, -100e6, abi.encode(trader));
        assertEq(feeManager.balances(referrer), 0.2e18);
        assertEq(feeManager.balances(creator) - c.creatorBefore, 0.5e18);
        assertEq(feeManager.platformBalance() - c.platformBefore, 0.3e18);
    }

    function test_hookDataCannotBindAReferrer() public {
        Ctx memory c = _setup(false);
        _swap(c, true, -100e6, abi.encode(trader));
        assertEq(feeManager.referrerOf(trader), address(0));
        assertFalse(feeManager.hasTraded(trader));
    }

    function test_malformedHookDataIsIgnored() public {
        Ctx memory c = _setup(false);
        _swap(c, true, -100e6, hex"deadbeef");
        _assertFee(c, 1e6);
    }

    function test_dirtyUpperBitsHookDataIsIgnored() public {
        Ctx memory c = _setup(false);
        // A naive `abi.decode(hookData, (address))`-style truncation of `type(uint256).max` would land on
        // `address(type(uint160).max)`. Bind a referrer to exactly that address so the test discriminates:
        // if the guard were broken, that referrer would earn a share; the correct behaviour is address(0).
        address truncatedIfBuggy = address(type(uint160).max);
        vm.prank(truncatedIfBuggy);
        feeManager.bindReferrer(referrer);

        _swap(c, true, -100e6, abi.encode(type(uint256).max));

        assertEq(feeManager.balances(referrer), 0, "dirty hookData must not resolve to a referred trader");
        _assertFee(c, 1e6);
    }

    function test_hookEntryPointsOnlyFromPoolManager() public {
        Ctx memory c = _setup(false);
        SwapParams memory p = SwapParams(true, -1e6, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(LaunchHook.NotPoolManager.selector);
        hook.beforeSwap(trader, c.key, p, "");
        vm.expectRevert(LaunchHook.NotPoolManager.selector);
        hook.afterSwap(trader, c.key, p, BalanceDelta.wrap(0), "");
    }

    // ---- F5: fee == 0 short-circuit

    function test_zeroFeeBpsChargesNothing() public {
        LaunchConfig memory zeroFee = cfg;
        zeroFee.tradeFeeBps = 0;
        vm.prank(owner);
        factory.setConfig(zeroFee);

        Ctx memory c = _setup(false);
        uint256 before = feeManager.totalOwed();
        (int256 usdcDelta,) = _swap(c, true, -100e6, "");
        assertEq(usdcDelta, -100e6);
        assertEq(feeManager.totalOwed(), before, "zero bps must charge nothing");
    }
}
