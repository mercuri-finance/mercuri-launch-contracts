// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {GovernedFixture} from "../utils/GovernedFixture.sol";
import {Handler} from "./Handler.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @dev Runs against the governed system (spec section 7): the three proxies are owned by a real
///      `TimelockController`, exactly as in production, rather than by the test contract directly.
contract InvariantsTest is GovernedFixture {
    Handler handler;

    function setUp() public {
        _deployGoverned();
        handler = new Handler(factory, feeManager, gm, new PoolSwapTest(poolManager));
        // `targetContract` is REQUIRED even though `targetSelector` below also names `handler`: with no
        // `targetContract` call at all, forge's default is to fuzz EVERY contract deployed during setUp (their
        // whole ABI, unweighted) rather than restrict itself to `handler` — confirmed the hard way (dropping
        // this line made `BondingCurve`, `LaunchToken` and even `TimelockController` all become fuzz targets,
        // sending near-100% of calls into reverts and collapsing every ghost counter back to zero).
        targetContract(address(handler));

        // Fix round 1 (reviewer): `targetSelector` (not plain `targetContract`'s "every selector equally
        // often") weights the calls that drive graduation, the pending state and the pool-swap shapes above
        // their plain 1-in-N share, so the whole chain lands reliably within a single campaign instead of
        // needing many campaigns' worth of luck. Every external Handler function is still included at least
        // once.
        //
        // Fix round 2 (reviewer): weight-tuning alone still collapsed on fresh (non-searched) seeds, because
        // `buy`'s RANDOM amount could simply fail to land enough calls on the SAME curve within one 64-call run
        // to reach the ~18_000e18 a fresh curve needs. Fixed at the source by `completeCurve` (deterministic
        // sell-out and deterministic forced deferral; see its own doc comment in Handler.sol) — this weighting
        // no longer needs `buy` to carry the burden of completing a curve at all, only of fuzzing sub-window
        // trading. The final weights below (out of 31 draws), and why each one is what it is, from a ~30-attempt
        // empirical search recorded in the report's fix-round-2 section:
        //  - `create` x3: cheap and idempotent past the first two calls (`curves.length >= 2` no-ops
        //    immediately); under-weighting it risks a whole run never selecting it at all (seen directly in a
        //    `FOUNDRY_INVARIANT_RUNS=3 ... -vvvv` trace), which zeroes every other counter for that run since
        //    nothing else can act without a curve.
        //  - `completeCurve` x6: needs to reliably sell out BOTH of the two curves within one 64-call run;
        //    since it now also deterministically forces a deferral every time (see Handler.sol), this single
        //    weight is what makes `pendingObserved`/`graduations` non-zero on essentially every seed tried.
        //  - `sell` x4 vs `retryGraduation` x2: these two are the ONLY ways a `GraduationPending` window closes
        //    (a successful retry graduates it; a sell reopens Trading). Because `completeCurve` forces a fresh
        //    deferral (and `_trackPhase` immediately un-forces it) on every completion, a HIGH-weight retry
        //    tends to win almost every such race, starving `sellsWhilePending`; favouring `sell` 2:1 instead is
        //    what actually got both `sellsWhilePending` and `retriesSucceeded` non-zero across most of the
        //    seeds 1-10 acceptance sweep (see the report) — equal weight, and weight favouring retry, both did
        //    measurably worse across the same sweep.
        //  - `poolSwap` x11: needs enough attempts, across two graduated curves and four (buyToken, exactOutput)
        //    shape combinations, that all four still land at least once within whatever's left of the 64-call
        //    budget after graduation. This is the single heaviest weight and is still the main source of
        //    residual flakiness (see the report): an exact-output shape can revert with the hook's own
        //    `PartialFill()` on anything but an exact fill, and even a balance-aware actor pick (both here and
        //    in `sell`, see their comments) cannot make every attempt succeed.
        //  - `buy`, `toggleGraduationFailure`, `claim`, `claimPlatform`, `advance` x1 each: still exercised
        //    every run, just not more than that — none of them gates any ghost counter's reachability once
        //    `completeCurve` exists.
        bytes4[] memory selectors = new bytes4[](31);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.create.selector;
        selectors[2] = handler.create.selector;
        selectors[3] = handler.completeCurve.selector;
        selectors[4] = handler.completeCurve.selector;
        selectors[5] = handler.completeCurve.selector;
        selectors[6] = handler.completeCurve.selector;
        selectors[7] = handler.completeCurve.selector;
        selectors[8] = handler.completeCurve.selector;
        selectors[9] = handler.buy.selector;
        selectors[10] = handler.sell.selector;
        selectors[11] = handler.sell.selector;
        selectors[12] = handler.sell.selector;
        selectors[13] = handler.sell.selector;
        selectors[14] = handler.toggleGraduationFailure.selector;
        selectors[15] = handler.retryGraduation.selector;
        selectors[16] = handler.retryGraduation.selector;
        selectors[17] = handler.poolSwap.selector;
        selectors[18] = handler.poolSwap.selector;
        selectors[19] = handler.poolSwap.selector;
        selectors[20] = handler.poolSwap.selector;
        selectors[21] = handler.poolSwap.selector;
        selectors[22] = handler.poolSwap.selector;
        selectors[23] = handler.poolSwap.selector;
        selectors[24] = handler.poolSwap.selector;
        selectors[25] = handler.poolSwap.selector;
        selectors[26] = handler.poolSwap.selector;
        selectors[27] = handler.poolSwap.selector;
        selectors[28] = handler.claim.selector;
        selectors[29] = handler.claimPlatform.selector;
        selectors[30] = handler.advance.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// Every curve can always pay out every token in circulation.
    function invariant_curveSolvency() public view {
        for (uint256 i; i < handler.curveCount(); ++i) {
            BondingCurve c = handler.curves(i);
            assertGe(address(c).balance, c.realUsdc(), "balance >= realUsdc");
            // F1: sells are open in both Trading and GraduationPending, so both must stay solvent for a full
            // exit; only once Graduated does realUsdc get swept out and these formulas stop applying.
            if (c.phase() != BondingCurve.Phase.Graduated) {
                uint256 x = c.virtualUsdc() + c.realUsdc();
                uint256 y = c.virtualTokens() - c.sold();
                assertLe(CurveMath.usdcForTokens(x, y, c.sold()), c.realUsdc(), "full exit is payable");
                // F5: x < 1e24 and y < 2e27, so x * y fits comfortably in uint256 without the `/ 1e18` truncation.
                assertGe(x * y, c.virtualUsdc() * c.virtualTokens(), "k never decreases");
            }
        }
    }

    /// Supply is fixed, and the curve never sells more than its allocation.
    function invariant_supplyAndAllocation() public view {
        for (uint256 i; i < handler.curveCount(); ++i) {
            BondingCurve c = handler.curves(i);
            LaunchToken t = c.token();
            assertEq(t.totalSupply(), 1_000_000_000e18);
            assertLe(c.sold(), c.curveSupply());
            // Holds until executeGraduation actually sweeps `poolSupply` out, i.e. through Trading and
            // GraduationPending; sell() can also bring a pending curve back to Trading with `sold` reduced.
            if (c.phase() == BondingCurve.Phase.Trading || c.phase() == BondingCurve.Phase.GraduationPending) {
                assertEq(t.balanceOf(address(c)), 1_000_000_000e18 - c.sold(), "curve holds everything unsold");
            }
        }
    }

    /// FeeManager never owes more than it holds, and its ledger adds up.
    /// Reviewer coverage (g): `totalOwed` is cross-checked TWICE over — once against the sum of the balances of
    /// every address that is supposed to be able to earn, and once against a ghost ledger the handler builds
    /// from the FeeManager's own `FeeAccrued`/`PlatformAccrued` events. Either check alone can be satisfied by a
    /// credit landing on an unexpected address (the ghost total would still match while the per-recipient sum
    /// quietly fell short); together they cannot.
    function invariant_feeConservation() public view {
        assertEq(
            address(feeManager).balance,
            feeManager.totalOwed() + handler.ghostDonations(),
            "exact fee backing including tracked donations"
        );
        uint256 sum = feeManager.platformBalance();
        for (uint256 i; i < handler.recipientCount(); ++i) {
            sum += feeManager.balances(handler.feeRecipients(i));
        }
        assertEq(sum, feeManager.totalOwed(), "ledger sums to totalOwed");
        assertEq(
            handler.ghostAccrued() - handler.ghostClaimed(),
            feeManager.totalOwed(),
            "every wei accrued, minus every wei claimed, is exactly what is owed"
        );
    }

    /// Once graduated, the position stays with the locker and keeps its liquidity.
    function invariant_liquidityStaysLocked() public view {
        for (uint256 i; i < handler.curveCount(); ++i) {
            BondingCurve c = handler.curves(i);
            if (c.phase() != BondingCurve.Phase.Graduated) continue;
            address t = address(c.token());
            assertTrue(locker.isLocked(t), "position held by locker");
            assertGt(posm.getPositionLiquidity(locker.positionOf(t)), 0, "liquidity intact");
        }
    }

    /// F2/F3: does NOT assert per-run (a single run may legitimately miss any one path); logs the ghost
    /// counters so a full campaign's worth of these lines is evidence that pending/retry/graduation and all
    /// four swap shapes each happened at least once somewhere in the campaign (see the report for the tally).
    /// Fix round 2: also clears any mocked call left over from this run's end, as cheap extra insurance on top
    /// of the handler's own `_syncMock` — belt and braces against the mock cheatcode outliving forge's per-run
    /// EVM-state revert.
    function afterInvariant() public {
        vm.clearMockedCalls();
        console2.log("pendingObserved", handler.pendingObserved());
        console2.log("sellsWhilePending", handler.sellsWhilePending());
        console2.log("retriesSucceeded", handler.retriesSucceeded());
        console2.log("graduations", handler.graduations());
        console2.log("exactInBuys", handler.exactInBuys());
        console2.log("exactInSells", handler.exactInSells());
        console2.log("exactOutBuys", handler.exactOutBuys());
        console2.log("exactOutSells", handler.exactOutSells());
        console2.log("ghostAccrued", handler.ghostAccrued());
        console2.log("ghostClaimed", handler.ghostClaimed());
    }
}
