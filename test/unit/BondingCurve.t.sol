// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {FeeManager} from "../../src/FeeManager.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {LaunchConfig} from "../../src/libraries/LaunchTypes.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {DefaultConfig} from "../../script/DefaultConfig.sol";
import {MockGraduationManager} from "../utils/MockGraduationManager.sol";
import {Proxies} from "../utils/Proxies.sol";
import {RejectingBuyer} from "../utils/RejectingBuyer.sol";
import {ReenteringBuyer} from "../utils/ReenteringBuyer.sol";
import {GasCappedBuyer, GriefingBuyer} from "../utils/GasCappedBuyer.sol";

contract BondingCurveTest is Test {
    BondingCurve curve;
    LaunchToken token;
    FeeManager fm;
    MockGraduationManager gm;
    LaunchConfig cfg;

    address treasuryAddr = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address referrer = makeAddr("referrer");
    uint256 constant FOREVER = type(uint256).max;

    // The test contract plays the factory.
    function treasury() external view returns (address) {
        return treasuryAddr;
    }

    function setUp() public {
        cfg = DefaultConfig.get();
        gm = new MockGraduationManager();
        fm = Proxies.feeManager(address(this), makeAddr("hook"), address(gm), address(this));
        curve = new BondingCurve(cfg, "Example", "EX", "uri", address(fm), address(gm));
        token = curve.token();
        fm.registerToken(
            address(token), address(curve), creator, cfg.tradeFeeBps, cfg.creatorShareBps, cfg.referrerShareBps
        );
        vm.deal(alice, 100_000e18);
        vm.deal(bob, 100_000e18);
    }

    function _afterSnipeWindow() internal {
        vm.roll(block.number + cfg.snipeBlocks);
    }

    function test_buyDeadlineEqualitySucceeds() public {
        vm.warp(1000);
        vm.prank(alice);
        uint256 tokensOut = curve.buy{value: 1e18}(0, address(0), block.timestamp);
        assertGt(tokensOut, 0);
    }

    function test_initialState() public view {
        assertEq(token.balanceOf(address(curve)), 1_000_000_000e18);
        assertEq(curve.factory(), address(this));
        assertEq(curve.launchBlock(), block.number);
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Trading));
        assertEq(curve.price(), cfg.virtualUsdc * 1e18 / cfg.virtualTokens);
        assertEq(curve.progressBps(), 0);
    }

    function test_buyAfterSnipeWindow() public {
        _afterSnipeWindow();
        uint256 expected = CurveMath.tokensForUsdc(cfg.virtualUsdc, cfg.virtualTokens, 99e18);
        (uint256 qTokens, uint256 qUsed, uint256 qFee, uint256 qTax) = curve.quoteBuy(100e18);
        assertEq(qTokens, expected);
        assertEq(qUsed, 100e18);
        assertEq(qFee, 1e18);
        assertEq(qTax, 0);

        vm.prank(alice);
        uint256 out = curve.buy{value: 100e18}(expected, referrer, FOREVER);
        assertEq(out, expected);
        assertEq(token.balanceOf(alice), expected);
        assertEq(curve.realUsdc(), 99e18);
        assertEq(curve.sold(), expected);
        assertEq(address(curve).balance, 99e18);
        assertEq(fm.balances(creator), 0.5e18);
        assertEq(fm.balances(referrer), 0.2e18);
        assertEq(fm.platformBalance(), 0.3e18);
    }

    function test_snipeTaxAtLaunchBlockGoesToPlatform() public {
        assertEq(curve.currentSnipeBps(), 9_900);
        vm.prank(alice);
        curve.buy{value: 100e18}(0, address(0), FOREVER);
        // fee 1, tax 99% of 99 = 98.01, net 0.99
        assertEq(curve.realUsdc(), 0.99e18);
        assertEq(fm.balances(creator), 0.5e18);
        assertEq(fm.platformBalance(), 0.5e18 + 98.01e18);
        assertEq(token.balanceOf(alice), CurveMath.tokensForUsdc(cfg.virtualUsdc, cfg.virtualTokens, 0.99e18));
    }

    function test_snipeTaxDecaysPerBlock() public {
        // Reads the block number via the cheatcode (vm.getBlockNumber()) rather than the bare `block.number`
        // opcode: under this project's via-ir + high-optimizer-runs profile, solc treats two `block.number`
        // reads in the same function as a common subexpression and elides the second one, so it does not see
        // the vm.roll() in between.
        uint256 half = cfg.snipeBlocks / 2;
        vm.roll(vm.getBlockNumber() + half);
        assertEq(curve.currentSnipeBps(), uint256(cfg.snipeStartBps) * (cfg.snipeBlocks - half) / cfg.snipeBlocks);
        vm.roll(vm.getBlockNumber() + (cfg.snipeBlocks - half - 1));
        assertGt(curve.currentSnipeBps(), 0); // last taxed block
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(curve.currentSnipeBps(), 0);
    }

    function test_buySlippageAndDeadline() public {
        _afterSnipeWindow();
        vm.startPrank(alice);
        vm.expectRevert(BondingCurve.Slippage.selector);
        curve.buy{value: 100e18}(type(uint256).max, address(0), FOREVER);
        vm.warp(1_000);
        vm.expectRevert(BondingCurve.Expired.selector);
        curve.buy{value: 100e18}(0, address(0), 999);
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        curve.buy{value: 0}(0, address(0), FOREVER);
        vm.stopPrank();
    }

    function test_sellReturnsUsdcMinusFee() public {
        _afterSnipeWindow();
        vm.startPrank(alice);
        uint256 bought = curve.buy{value: 1_000e18}(0, address(0), FOREVER);
        token.approve(address(curve), bought);
        (uint256 qOut, uint256 qFee) = curve.quoteSell(bought);
        uint256 before = alice.balance;
        uint256 out = curve.sell(bought, qOut, address(0), FOREVER);
        vm.stopPrank();

        assertEq(out, qOut);
        assertEq(alice.balance - before, qOut);
        assertEq(qFee, (qOut + qFee) * 100 / 10_000);
        assertLe(qOut + qFee, 990e18); // never more than what went in
        assertEq(curve.sold(), 0);
        assertEq(address(curve).balance, curve.realUsdc());
    }

    function test_sellSlippage() public {
        _afterSnipeWindow();
        vm.startPrank(alice);
        uint256 bought = curve.buy{value: 1_000e18}(0, address(0), FOREVER);
        token.approve(address(curve), bought);
        vm.expectRevert(BondingCurve.Slippage.selector);
        curve.sell(bought, type(uint256).max, address(0), FOREVER);
        vm.stopPrank();
    }

    function test_finalBuyIsCappedRefundedAndGraduates() public {
        _afterSnipeWindow();
        uint256 before = alice.balance;
        (uint256 qTokens, uint256 qUsed,,) = curve.quoteBuy(30_000e18);
        assertEq(qTokens, cfg.curveSupply);

        vm.prank(alice);
        uint256 out = curve.buy{value: 30_000e18}(0, address(0), FOREVER);

        assertEq(out, cfg.curveSupply);
        assertEq(token.balanceOf(alice), cfg.curveSupply);
        assertEq(before - alice.balance, qUsed);
        assertApproxEqAbs(qUsed, uint256(18_000e18) * 10_000 / 9_900, 1e12); // 18,000 net of the 1% fee
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));
        assertEq(gm.calls(), 1);
        assertEq(gm.receivedTokens(), cfg.poolSupply);
        assertEq(gm.receivedUsdc() % 1e12, 0); // whole 6-decimal units only
        assertApproxEqAbs(gm.receivedUsdc(), 18_000e18, 1e12);
        assertEq(address(curve).balance, 0);
        assertEq(token.balanceOf(address(curve)), 0);
        assertEq(curve.price(), 0); // realUsdc is swept; the pool is the price source from here on
    }

    function test_tradingClosedAfterGraduation() public {
        _afterSnipeWindow();
        vm.prank(alice);
        curve.buy{value: 30_000e18}(0, address(0), FOREVER);

        vm.prank(bob);
        vm.expectRevert(BondingCurve.NotTrading.selector);
        curve.buy{value: 1e18}(0, address(0), FOREVER);

        vm.startPrank(alice);
        token.approve(address(curve), 1e18);
        vm.expectRevert(BondingCurve.NotTrading.selector);
        curve.sell(1e18, 0, address(0), FOREVER);
        vm.stopPrank();
    }

    function test_failedGraduationIsDeferredNotFatal() public {
        _afterSnipeWindow();
        gm.setShouldRevert(true);
        vm.prank(alice);
        uint256 out = curve.buy{value: 30_000e18}(0, address(0), FOREVER);
        assertEq(out, cfg.curveSupply); // the buy itself succeeded
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.GraduationPending));
        assertEq(token.balanceOf(address(curve)), cfg.poolSupply);

        vm.expectRevert(); // still failing
        curve.graduate();

        gm.setShouldRevert(false);
        vm.prank(bob); // anyone may retry
        curve.graduate();
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));
        assertEq(gm.calls(), 1);
    }

    function test_graduateOnlyWhenPending() public {
        vm.expectRevert(BondingCurve.NotPending.selector);
        curve.graduate();
        vm.expectRevert(BondingCurve.Unauthorized.selector);
        curve.executeGraduation();
    }

    function test_initialBuyIsTaxExemptAndFactoryOnly() public {
        vm.prank(alice);
        vm.expectRevert(BondingCurve.Unauthorized.selector);
        curve.initialBuy{value: 100e18}(alice, address(0), 0);

        vm.deal(address(this), 100e18);
        uint256 out = curve.initialBuy{value: 100e18}(creator, address(0), 0);
        assertEq(out, CurveMath.tokensForUsdc(cfg.virtualUsdc, cfg.virtualTokens, 99e18)); // no tax at block 0
        assertEq(token.balanceOf(creator), out);
    }

    function test_initialBuyCapAndLaunchBlockOnly() public {
        vm.deal(address(this), 10_000e18);
        vm.expectRevert(BondingCurve.InitialBuyTooLarge.selector);
        curve.initialBuy{value: 1_000e18}(creator, address(0), 0); // ~150M tokens > 50M cap

        vm.roll(block.number + 1);
        vm.expectRevert(BondingCurve.Unauthorized.selector);
        curve.initialBuy{value: 1e18}(creator, address(0), 0);
    }

    function testFuzz_solventAfterAnyBuySellPair(uint256 buyAmount, uint256 sellShare) public {
        _afterSnipeWindow();
        buyAmount = bound(buyAmount, 1e15, 15_000e18);
        sellShare = bound(sellShare, 1, 10_000);
        vm.startPrank(alice);
        uint256 bought = curve.buy{value: buyAmount}(0, address(0), FOREVER);
        uint256 toSell = bought * sellShare / 10_000;
        if (toSell > 0) {
            token.approve(address(curve), toSell);
            curve.sell(toSell, 0, address(0), FOREVER);
        }
        vm.stopPrank();
        assertGe(address(curve).balance, curve.realUsdc());
        // Selling everything still outstanding must be payable from the reserve.
        uint256 x = cfg.virtualUsdc + curve.realUsdc();
        uint256 y = cfg.virtualTokens - curve.sold();
        assertLe(CurveMath.usdcForTokens(x, y, curve.sold()), curve.realUsdc());
    }

    // ---------------------------------------------------------------- F1: exit while graduation is pending

    function test_sellWhileGraduationPendingReopensTradingAndCanRegraduate() public {
        _afterSnipeWindow();
        gm.setShouldRevert(true);
        vm.prank(alice);
        uint256 bought = curve.buy{value: 30_000e18}(0, address(0), FOREVER); // sells out; graduation deferred
        assertEq(bought, cfg.curveSupply);
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.GraduationPending));

        uint256 toSell = bought / 8;
        vm.startPrank(alice);
        token.approve(address(curve), toSell);
        uint256 before = alice.balance;
        uint256 out = curve.sell(toSell, 0, address(0), FOREVER);
        vm.stopPrank();

        assertGt(out, 0);
        assertEq(alice.balance - before, out);
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Trading));
        assertEq(curve.sold(), cfg.curveSupply - toSell);

        vm.expectRevert(BondingCurve.NotPending.selector);
        curve.graduate();

        // The mock no longer reverting: the next buy that sells the curve out graduates again.
        gm.setShouldRevert(false);
        vm.prank(bob);
        uint256 out2 = curve.buy{value: 10_000e18}(0, address(0), FOREVER);
        assertEq(out2, toSell);
        assertEq(curve.sold(), cfg.curveSupply);
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));
        assertEq(gm.calls(), 1);
    }

    function test_buyStillClosedWhileGraduationPending() public {
        _afterSnipeWindow();
        gm.setShouldRevert(true);
        vm.prank(alice);
        curve.buy{value: 30_000e18}(0, address(0), FOREVER);
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.GraduationPending));

        vm.prank(bob);
        vm.expectRevert(BondingCurve.NotTrading.selector);
        curve.buy{value: 1e18}(0, address(0), FOREVER);
    }

    // ---------------------------------------------------------------- F2: final-buy branch coverage

    function testFuzz_finalBuyBranchIsSolventAndExact(uint256 firstBuy, uint256 finalBuy) public {
        _afterSnipeWindow();
        firstBuy = bound(firstBuy, 1e15, 17_000e18);
        finalBuy = bound(finalBuy, 20_000e18, 40_000e18);

        vm.prank(alice);
        curve.buy{value: firstBuy}(0, address(0), FOREVER);
        uint256 soldBefore = curve.sold();
        uint256 realUsdcBefore = curve.realUsdc();
        vm.assume(soldBefore < cfg.curveSupply);

        (, uint256 usdcUsed2, uint256 fee2, uint256 tax2) = curve.quoteBuy(finalBuy);
        uint256 expectedNet2 = usdcUsed2 - fee2 - tax2;

        uint256 beforeBal = bob.balance;
        vm.prank(bob);
        uint256 out = curve.buy{value: finalBuy}(0, address(0), FOREVER);
        uint256 charged = beforeBal - bob.balance;

        assertEq(out, cfg.curveSupply - soldBefore);
        assertEq(charged, usdcUsed2);
        assertLe(charged, finalBuy);
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));
        assertEq(address(curve).balance, 0);
        assertEq(token.balanceOf(address(curve)), 0);
        assertEq(gm.receivedTokens(), cfg.poolSupply);
        assertEq(gm.receivedUsdc() % 1e12, 0);
        assertLe(gm.receivedUsdc(), realUsdcBefore + expectedNet2);
    }

    function test_finalBuyWithExactlyTheRequiredValue() public {
        _afterSnipeWindow();
        (, uint256 used,,) = curve.quoteBuy(30_000e18);

        vm.prank(alice);
        uint256 out = curve.buy{value: used}(0, address(0), FOREVER);
        assertEq(out, cfg.curveSupply);
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));

        // A value clearly short of what's required must not sell out a (fresh) curve.
        //
        // Deliberately not the literal `used - 1`: at the default config's magnitudes,
        // `used` (the exact required gross) is computed via CurveMath.grossUp(CurveMath.costOfTokens(...)),
        // two nested *ceiling* roundings; `used - 1` still lands 2 raw wei below the true crossover, because
        // CurveMath.tokensForUsdc's *floor* rounding at this reserve ratio only moves by ~11,110 raw token
        // units per wei of input (verified by direct computation mirroring CurveMath: at `used - 1`,
        // tokensForUsdc's own floor-rounded — i.e. protocol-safe lower-bound — estimate is still
        // curveSupply + 11,110, i.e. it independently proves the payment funds more than the full remaining
        // supply, so selling out at that value is correct and does not shortchange the protocol; the true
        // crossover for these numbers is at `used - 2`). A one-wei-scale margin is a brittle, config-specific
        // number to hardcode, so this uses a proportionally tiny but generous margin (1e6 wei, ~1e-12 USDC)
        // that reliably falls on the "not enough" side for any similarly-scaled config, without asserting a
        // false claim about the exact boundary the way a literal `-1` would.
        MockGraduationManager gm2 = new MockGraduationManager();
        FeeManager fm2 = Proxies.feeManager(address(this), makeAddr("hook2"), address(gm2), address(this));
        BondingCurve curve2 = new BondingCurve(cfg, "Example2", "EX2", "uri", address(fm2), address(gm2));
        LaunchToken token2 = curve2.token();
        fm2.registerToken(
            address(token2), address(curve2), creator, cfg.tradeFeeBps, cfg.creatorShareBps, cfg.referrerShareBps
        );
        vm.roll(curve2.launchBlock() + cfg.snipeBlocks);

        (, uint256 used2,,) = curve2.quoteBuy(30_000e18);
        vm.deal(bob, used2);
        vm.prank(bob);
        uint256 out2 = curve2.buy{value: used2 - 1e6}(0, address(0), FOREVER);
        assertLt(out2, cfg.curveSupply);
        assertEq(uint8(curve2.phase()), uint8(BondingCurve.Phase.Trading));
        assertGe(address(curve2).balance, curve2.realUsdc());
    }

    function test_buyPartialSellThenSellOutStaysSolvent() public {
        _afterSnipeWindow();
        vm.startPrank(alice);
        uint256 bought = curve.buy{value: 5_000e18}(0, address(0), FOREVER);
        assertGe(address(curve).balance, curve.realUsdc());

        uint256 toSell = bought / 3;
        token.approve(address(curve), toSell);
        curve.sell(toSell, 0, address(0), FOREVER);
        assertGe(address(curve).balance, curve.realUsdc());
        vm.stopPrank();

        vm.prank(bob);
        curve.buy{value: 40_000e18}(0, address(0), FOREVER); // sells out whatever remains
        assertGe(address(curve).balance, curve.realUsdc());
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));
    }

    // ---------------------------------------------------------------- F3: refund-path failure modes

    function test_rejectingBuyerRefundFailureLeavesStateUntouched() public {
        _afterSnipeWindow();
        RejectingBuyer rej = new RejectingBuyer();
        vm.deal(address(rej), 30_000e18);

        uint256 soldBefore = curve.sold();
        uint256 realBefore = curve.realUsdc();
        uint8 phaseBefore = uint8(curve.phase());

        vm.expectRevert(BondingCurve.TransferFailed.selector);
        rej.buy(curve, 30_000e18, 0, address(0), FOREVER);

        assertEq(curve.sold(), soldBefore);
        assertEq(curve.realUsdc(), realBefore);
        assertEq(uint8(curve.phase()), phaseBefore);
    }

    // ---------------------------------------------------------------- C1: gas-starved graduation

    /// @dev C1.1 — the reviewer's repro: `buy{gas: 400_000}` that sells the curve out used to SUCCEED while
    ///      the inner `try this.executeGraduation()` ran out of gas, leaving the curve GraduationPending. The
    ///      whole buy must revert instead, leaving nothing half-done.
    function test_gasCappedSellOutBuyRevertsAndLeavesStateUntouched() public {
        _afterSnipeWindow();
        GasCappedBuyer b = new GasCappedBuyer();
        vm.deal(address(b), 40_000e18);

        uint256 soldBefore = curve.sold();
        uint256 realBefore = curve.realUsdc();

        vm.expectRevert(BondingCurve.InsufficientGasForGraduation.selector);
        b.buyBubbling(curve, 30_000e18, 400_000);

        assertEq(curve.sold(), soldBefore);
        assertEq(curve.realUsdc(), realBefore);
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Trading));
        assertEq(gm.calls(), 0);
        assertEq(token.balanceOf(address(b)), 0);
    }

    /// @dev C1.1 — and it is the PRE-`try` floor check that fires, not the out-of-gas discriminator: the call
    ///      aborts having consumed only the buy's own work, far short of the 400k it was given.
    function test_gasFloorAbortsBeforeSpendingTheWholeCap() public {
        _afterSnipeWindow();
        GasCappedBuyer b = new GasCappedBuyer();
        vm.deal(address(b), 40_000e18);

        b.probeBuy(curve, 30_000e18, 400_000);

        assertTrue(b.callReverted());
        assertEq(bytes4(b.revertData()), BondingCurve.InsufficientGasForGraduation.selector);
        assertLt(b.gasUsedByCall(), 300_000, "the floor check must abort early, not burn the whole cap");
        assertEq(curve.GRADUATION_GAS_FLOOR(), 1_000_000);
    }

    /// @dev With this OOG mock, each sampled cap either reverts the buy or leaves it Pending.
    ///      Only a ZERO-PROCEEDS sale is refused. A nonzero-proceeds dust sale can reopen
    ///      Trading, including after caller-forced deferral via PoolManager.unlock (L-03).
    ///      This test does not prove that callers cannot force a pending or near-sold-out state.
    function test_noGasCapCanLeaveTheCurveSoldOutAndTrading() public {
        _afterSnipeWindow();
        // Graduation can never complete inside any cap tried here, so this sweeps the whole "starved" space.
        gm.setGasToBurn(50_000_000);
        GasCappedBuyer b = new GasCappedBuyer();
        vm.deal(address(b), 40_000e18);

        uint256[9] memory caps =
            [uint256(200_000), 400_000, 700_000, 999_999, 1_100_000, 1_500_000, 2_000_000, 5_000_000, 20_000_000];
        for (uint256 i; i < caps.length; ++i) {
            uint256 snap = vm.snapshotState();
            b.probeBuy(curve, 30_000e18, caps[i]);

            if (b.callReverted()) {
                // Either the gas guard rejected it, or the cap was so small the buy ran out of gas before it
                // even got there (empty revert data). Both leave the curve untouched, which is the point.
                if (b.revertData().length != 0) {
                    assertEq(bytes4(b.revertData()), BondingCurve.InsufficientGasForGraduation.selector);
                }
                assertEq(curve.sold(), 0);
                assertEq(curve.realUsdc(), 0);
                assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Trading));
            } else {
                // A retryable deferral. The single token-wei sale below has zero proceeds;
                // a larger dust sale with nonzero proceeds can reopen Trading.
                assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.GraduationPending));
                assertEq(curve.sold(), cfg.curveSupply);
                vm.prank(address(b));
                token.approve(address(curve), 1);
                vm.prank(address(b));
                vm.expectRevert(BondingCurve.ZeroAmount.selector);
                curve.sell(1, 0, address(0), FOREVER);
                assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.GraduationPending), "still pending");
                // And anyone can finish it off once graduation works again.
                gm.setGasToBurn(0);
                vm.prank(bob);
                curve.graduate();
                assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));
            }
            vm.revertToState(snap);
        }
    }

    /// @dev C1.2 — the other side of the discriminator: a graduation that reverts with plenty of gas left still
    ///      defers, so the buy succeeds and anyone may retry. (`test_failedGraduationIsDeferredNotFatal` asserts
    ///      the same thing end to end; this one pins that the deferral is reached with ample gas available.)
    function test_genuineGraduationRevertStillDefersWithAmpleGas() public {
        _afterSnipeWindow();
        gm.setShouldRevert(true);
        GasCappedBuyer b = new GasCappedBuyer();
        vm.deal(address(b), 40_000e18);

        b.probeBuy(curve, 30_000e18, 5_000_000);

        assertFalse(b.callReverted(), "a genuine graduation failure must not fail the buy");
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.GraduationPending));
        assertEq(curve.sold(), cfg.curveSupply);
    }

    /// @dev C1.3 — the free re-open lever: a buy that starves graduation followed, in the SAME transaction, by
    ///      a 1-unit sell whose proceeds round to zero. Neither leg may leave the curve sold-out-but-Trading.
    function test_griefingSequenceCannotParkTheCurveOneTokenShort() public {
        _afterSnipeWindow();
        gm.setGasToBurn(50_000_000);
        GriefingBuyer g = new GriefingBuyer();
        vm.deal(address(g), 40_000e18);

        g.attack(curve, 30_000e18, 400_000);

        assertTrue(g.buyReverted(), "the starved buy must revert outright");
        assertTrue(g.sellReverted(), "and the zero-proceeds sell must revert too");
        assertEq(curve.sold(), 0, "the curve must be exactly where it started");
        assertEq(curve.realUsdc(), 0);
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Trading));
        assertTrue(curve.sold() != cfg.curveSupply - 1, "never parked one token short of sell-out");
        assertEq(gm.calls(), 0);
    }

    /// @dev C1.3 — a sell that pays nothing is rejected outright.
    function test_zeroProceedsSellReverts() public {
        _afterSnipeWindow();
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        curve.sell(1, 0, address(0), FOREVER);

        // Still true once the curve holds a real reserve (the gross only gets smaller per token as `sold`
        // grows relative to the reserve, so dust sells stay worthless).
        vm.prank(alice);
        uint256 bought = curve.buy{value: 1_000e18}(0, address(0), FOREVER);
        vm.startPrank(alice);
        token.approve(address(curve), bought);
        (uint256 gross, uint256 grossFee) = curve.quoteSell(1);
        assertEq(gross + grossFee, 0, "one token unit is worth nothing on this curve");
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        curve.sell(1, 0, address(0), FOREVER);
        // A sell big enough to actually pay out is of course still fine.
        curve.sell(bought, 0, address(0), FOREVER);
        vm.stopPrank();
        assertEq(curve.sold(), 0);
    }

    // ---------------------------------------------------------------- reviewer coverage (d): event fields

    function test_buyAndSellEventFields() public {
        _afterSnipeWindow();
        uint256 net = 99e18;
        uint256 expectedTokens = CurveMath.tokensForUsdc(cfg.virtualUsdc, cfg.virtualTokens, net);

        vm.expectEmit(true, true, true, true, address(curve));
        emit BondingCurve.Buy(alice, net, expectedTokens, 1e18, 0, net, expectedTokens);
        vm.prank(alice);
        curve.buy{value: 100e18}(0, referrer, FOREVER);

        (uint256 out, uint256 fee) = curve.quoteSell(expectedTokens);
        vm.startPrank(alice);
        token.approve(address(curve), expectedTokens);
        vm.expectEmit(true, true, true, true, address(curve));
        emit BondingCurve.Sell(alice, expectedTokens, out, fee, net - out - fee, 0);
        curve.sell(expectedTokens, 0, address(0), FOREVER);
        vm.stopPrank();
    }

    function test_reenteringBuyerCannotDoubleGraduate() public {
        _afterSnipeWindow();
        ReenteringBuyer reenterer = new ReenteringBuyer();
        vm.deal(address(reenterer), 30_000e18);

        uint256 out = reenterer.buy(curve, 30_000e18, 0, address(0), FOREVER);

        assertEq(out, cfg.curveSupply);
        assertTrue(reenterer.buyReverted());
        assertTrue(reenterer.sellReverted());
        assertTrue(reenterer.graduateReverted());
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));
        assertEq(gm.calls(), 1);
    }
}
