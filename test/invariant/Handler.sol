// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchFactory} from "../../src/LaunchFactory.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {FeeManager} from "../../src/FeeManager.sol";
import {GraduationManager} from "../../src/GraduationManager.sol";
import {CreateParams} from "../../src/libraries/LaunchTypes.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IFeeManager} from "../../src/interfaces/IFeeManager.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Random creates, buys, sells, pool swaps, claims and block advances across several launches and actors.
contract Handler is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;

    LaunchFactory public factory;
    FeeManager public feeManager;
    GraduationManager public gm;
    PoolSwapTest public router;

    BondingCurve[] public curves;
    address[] public actors;
    address[] public feeRecipients;

    /// @dev F2: forces GraduationManager.graduate() to revert, so a completing buy's automatic graduation attempt
    ///      defers instead of succeeding, making GraduationPending actually observable and retryable.
    bool public graduationForced;

    /// @dev Ghost counters (F2, F3): all reset per invariant run along with the rest of this contract's storage,
    ///      so `afterInvariant` in Invariants.t.sol reports them per-run; the report sums them across the campaign.
    uint256 public pendingObserved;
    uint256 public sellsWhilePending;
    uint256 public retriesSucceeded;
    uint256 public graduations;
    uint256 public exactInBuys;
    uint256 public exactInSells;
    uint256 public exactOutBuys;
    uint256 public exactOutSells;

    /// @dev Ghost fee ledger (reviewer coverage (g)): every wei the FeeManager has EVER credited, summed from
    ///      its own `FeeAccrued`/`PlatformAccrued` logs rather than from `totalOwed`, and every wei it has paid
    ///      back out. `ghostAccrued - ghostClaimed` must equal `totalOwed` at all times, which pins the running
    ///      total independently of the per-recipient sum the invariant also checks — so a credit landing on an
    ///      address nobody expects shows up as a disagreement between the two.
    uint256 public ghostAccrued;
    uint256 public ghostClaimed;
    /// @dev This handler performs no donations; kept explicit for the exact backing invariant.
    ///      Any future donation action must update this counter independently of FeeManager balances.
    uint256 public ghostDonations;

    mapping(address curve => bool) internal _wasGraduated;

    /// @dev `advance`'s upper bound, derived from the live config's `snipeBlocks` (+30 margin) rather than
    ///      hardcoded: reviewer finding (fix round 1) — when `DefaultConfig.snipeBlocks` went 10 -> 120
    ///      (2026-09-19) while this was a fixed `20`, almost every buy landed inside the 99%->0 snipe-tax window,
    ///      the curve accumulated `realUsdc` far too slowly to sell out within the invariant depth, and
    ///      graduation coverage collapsed (measured ~1/20 single-run campaigns graduating). Reading it once here
    ///      means a future config change cannot silently break coverage the same way again.
    uint256 internal immutable advanceMaxBlocks;

    constructor(LaunchFactory factory_, FeeManager feeManager_, GraduationManager gm_, PoolSwapTest router_) {
        factory = factory_;
        feeManager = feeManager_;
        gm = gm_;
        router = router_;
        advanceMaxBlocks = uint256(factory_.config().snipeBlocks) + 30;
        // Fix round 1 (reviewer): start forced ON (mirrors `toggleGraduationFailure(true)`), rather than
        // Solidity's default `false`. Traced with `FOUNDRY_INVARIANT_RUNS=N ... -vvvv`: with the default false
        // start, a curve's FIRST sell-out attempt graduates directly (no deferral) unless a `toggleGraduationFailure`
        // call happens to land first — most runs never even reach `GraduationPending`, since one big buy (see
        // `buy`'s bound below) is now enough to complete a fresh curve almost immediately. Starting forced
        // means the very first sell-out defers by default, which is what actually exercises
        // `GraduationPending`/`sellsWhilePending`/`retriesSucceeded`; the fuzzer's own random
        // `toggleGraduationFailure` calls still flip it in both directions from there.
        graduationForced = true;
        vm.mockCallRevert(address(gm_), abi.encodeWithSelector(gm_.graduate.selector), bytes("forced"));
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            vm.deal(a, 10_000_000e18);
            vm.prank(a);
            IERC20(USDC).approve(address(router), type(uint256).max);
        }
        feeRecipients.push(makeAddr("creator"));
        for (uint256 i; i < actors.length; ++i) {
            feeRecipients.push(actors[i]);
        }
    }

    function curveCount() external view returns (uint256) {
        return curves.length;
    }

    function recipientCount() external view returns (uint256) {
        return feeRecipients.length;
    }

    /// @dev F5: alternates (by curve index parity) between a salt whose predicted token address sorts below USDC
    ///      and one above, so both pool orderings get covered, same pattern as `LaunchFixture._createOrdered`.
    function create(uint256 actorSeed, uint256 initialBuy) external {
        // F2/F3, revisited by fix round 1: briefly tried capping at 1 (every relevant call then lands on the
        // one curve that exists), which is what first made the deferred-graduation chain land reliably at all
        // (see the report's fix-round-1 section). But `sellsWhilePending` and `retriesSucceeded` resolve the
        // SAME pending episode in mutually exclusive ways — whichever of `sell`/`retryGraduation` reaches a
        // curve's one pending window first is the only one that can fire for it — so with a single curve, a
        // whole campaign observes at most one of the two outcomes for its last (reported) run. Restored to 2:
        // with two independent curves, each can defer and resolve on its own, so a single run can show one
        // curve's window closing by `sell` and the other's by a successful retry. `create`, `buy` and the
        // `sell` actor pick (below) were all fixed since the cap was last 2, so the dilution that motivated
        // dropping it to 1 is no longer the bottleneck.
        if (curves.length >= 2) return;
        // Normalize before adding offsets: arbitrary uint256 seeds can otherwise overflow in the harness.
        actorSeed %= actors.length;
        address a = actors[actorSeed];
        address ref = actors[(actorSeed + 1) % actors.length];
        initialBuy = bound(initialBuy, 0, 200e18);
        bool tokenBelowUsdc = curves.length % 2 == 0;

        bytes32 salt;
        bool found;
        for (uint256 i; i < 256; ++i) {
            bytes32 candidate = bytes32(curves.length * 1_000_000 + i + 1);
            CreateParams memory probe = CreateParams("T", "T", "", feeRecipients[0], ref, candidate);
            (address predictedToken,) = factory.computeAddresses(a, probe);
            if ((predictedToken < USDC) == tokenBelowUsdc) {
                salt = candidate;
                found = true;
                break;
            }
        }
        if (!found) return;

        CreateParams memory p = CreateParams("T", "T", "", feeRecipients[0], ref, salt);
        // M4: `expectedConfigHash` is mandatory now. Read it BEFORE `vm.prank`: an external call in between
        // would consume the prank and `createToken` would run as this handler (which holds no USDC).
        bytes32 pinned = factory.configHash();
        _startFeeRecording();
        vm.prank(a);
        (, address curve) = factory.createToken{value: 1e18 + initialBuy}(p, pinned, 0);
        _harvestFees();
        curves.push(BondingCurve(curve));
    }

    function buy(uint256 curveSeed, uint256 actorSeed, uint256 amount) external {
        actorSeed %= actors.length;
        _syncMock();
        if (curves.length == 0) return;
        BondingCurve c = curves[curveSeed % curves.length];
        if (c.phase() != BondingCurve.Phase.Trading) return;
        // Fix round 1 (reviewer): floor raised from 1e12, ceiling from 8_000e18. Selling out `DefaultConfig`'s
        // curve from empty costs ~18_000e18 total; forge's fuzzer samples heavily near both bounds of a `bound`
        // range, so a 1e12 floor produced many near-zero buys that never meaningfully advanced `sold`, and
        // graduations stayed rare even once a single large buy COULD complete a curve outright. Raising the
        // floor means every buy contributes meaningfully; the range still spans two orders of magnitude so
        // buy size stays fuzzed.
        amount = bound(amount, 2_000e18, 25_000e18);
        // C1: a buy that completes the curve refuses to graduate below `GRADUATION_GAS_FLOOR`, and reverts the
        // whole buy if it is under it. Handler buys must therefore always carry far more than the floor, so the
        // campaign keeps exercising real graduations instead of silently bouncing off the new guard. (Forge
        // gives each call the whole test gas limit, so this guard never actually trips; it is here so a future
        // change to the runner cannot quietly turn every sell-out buy into a no-op.)
        if (gasleft() < c.GRADUATION_GAS_FLOOR() * 3) return;
        address a = actors[actorSeed % actors.length];
        _startFeeRecording();
        vm.prank(a);
        // Fix round 1: `_harvestFees()` must only run on the SUCCESS arm. `vm.getRecordedLogs()` returns every
        // log emitted since `vm.recordLogs()`, including ones from a call that ultimately reverted — Foundry
        // does not discard cheatcode-recorded logs the way a real EVM discards a reverted call's logs. Calling
        // it unconditionally after a `try/catch` would credit `ghostAccrued` for a `FeeAccrued`/`PlatformAccrued`
        // event emitted mid-call by a buy that was then caught and discarded, even though the corresponding
        // `totalOwed` increment never actually happened (the revert rolled it back). Caught by the reviewer via
        // `invariant_feeConservation` failing once `poolSwap` (same pattern, fixed below) started reverting
        // after `notifyHookFee` had already fired.
        try c.buy{value: amount}(0, actors[(actorSeed + 1) % actors.length], type(uint256).max) {
            _harvestFees();
        } catch {}
        _trackPhase(c);
    }

    /// @dev Fix round 2 (reviewer): deterministic completion. `buy`'s amount is random within
    ///      `[2_000e18, 25_000e18]`; on some seeds it simply never lands enough calls on the SAME curve within
    ///      one 64-call run to accumulate the ~18_000e18 a fresh `DefaultConfig` curve needs, so graduation
    ///      itself — and everything downstream of it (`GraduationPending`, both pool orderings' worth of
    ///      `poolSwap` shapes) — stayed probabilistic rather than reliable (measured: seed 55 graduated nothing
    ///      at all; seeds 7 and 99 each missed at least one downstream counter). This sells a `Trading` curve
    ///      out UNCONDITIONALLY whenever selected, computed straight from its own reserves exactly the way
    ///      `BondingCurve._quoteBuy`'s own "final buy" branch does internally:
    ///        1. rolls past the snipe-tax window first (`launchBlock + snipeBlocks`) if still inside it, so the
    ///           value below needs no tax margin, only the ordinary trade-fee markup;
    ///        2. `CurveMath.costOfTokens` gives the exact net USDC that buys every remaining token;
    ///           `CurveMath.grossUp` (with the curve's own `tradeFeeBps`, zero tax) turns that into a gross
    ///           value, plus a flat 1 USDC margin against rounding;
    ///        3. sends that value with ample (2,000,000) gas. If the value modestly overshoots what is actually
    ///           needed, `BondingCurve.buy` itself caps the purchase at `remaining` and refunds the difference
    ///           (the same "Final buy" branch), so overshooting here is harmless — this never needs to be exact.
    ///      Deferral vs. immediate graduation: fix round 2's first version left this to whatever
    ///      `graduationForced` the fuzzer's own random `toggleGraduationFailure` calls happened to have left
    ///      behind — but a 10-seed acceptance sweep (seeds 1-10, see the report) showed that still left
    ///      `pendingObserved`/`sellsWhilePending`/`retriesSucceeded` probabilistic: whichever of `completeCurve`
    ///      (frequent) or `toggleGraduationFailure` (rare) happened to run first for a given curve was a race,
    ///      and losing it meant that curve never deferred, so the whole GraduationPending/retry/sell chain
    ///      never had a window to run in. Since the reviewer's explicit goal is "deterministic instead of
    ///      probabilistic," this now forces `graduationForced = true` immediately before EVERY completing buy
    ///      it drives (below), guaranteeing at least one deferral per curve regardless of how
    ///      `toggleGraduationFailure` has been called so far. This does not remove `toggleGraduationFailure`
    ///      from the fuzz surface or make it a no-op: it is still called randomly by the fuzzer (before AND
    ///      after this point), still governs ordinary `buy`'s own completions exactly as before, still decides
    ///      whether a LATER re-completion of a curve that reopened via `sellsWhilePending` defers again or not,
    ///      and `retryGraduation`'s "tolerated failure while still forced" arm is still reachable (the fuzzer
    ///      can re-force it, or `completeCurve` can fire again for a curve that somehow re-entered Trading,
    ///      before a retry attempt lands).
    function completeCurve(uint256 curveSeed, uint256 actorSeed) external {
        _syncMock();
        if (curves.length == 0) return;
        BondingCurve c = curves[curveSeed % curves.length];
        if (c.phase() != BondingCurve.Phase.Trading) return;
        if (gasleft() < 2_100_000) return;

        uint256 endOfWindow = c.launchBlock() + c.snipeBlocks();
        if (vm.getBlockNumber() < endOfWindow) vm.roll(endOfWindow);

        uint256 remaining = c.curveSupply() - c.sold();
        if (remaining == 0) return; // defensive: Trading implies sold < curveSupply

        // See the doc comment above: unconditionally (re-)forces a deferral for THIS completion.
        graduationForced = true;
        vm.mockCallRevert(address(gm), abi.encodeWithSelector(gm.graduate.selector), bytes("forced"));

        uint256 x = c.virtualUsdc() + c.realUsdc();
        uint256 y = c.virtualTokens() - c.sold();
        uint256 netNeeded = CurveMath.costOfTokens(x, y, remaining);
        uint256 grossNeeded = CurveMath.grossUp(netNeeded, c.tradeFeeBps(), 0);
        uint256 value = grossNeeded + 1e18; // 1 USDC margin; any excess is refunded by the curve itself

        address a = actors[actorSeed % actors.length];
        _startFeeRecording();
        vm.prank(a);
        // See the comment in `buy()`: only harvest on the success arm.
        try c.buy{value: value, gas: 2_000_000}(0, address(0), type(uint256).max) {
            _harvestFees();
        } catch {}
        _trackPhase(c);
    }

    /// @dev Sell is allowed while Trading OR GraduationPending (a sell while pending reopens Trading), so both
    ///      paths get exercised; it is closed only once Graduated.
    function sell(uint256 curveSeed, uint256 actorSeed, uint256 share) external {
        actorSeed %= actors.length;
        if (curves.length == 0) return;
        BondingCurve c = curves[curveSeed % curves.length];
        if (c.phase() == BondingCurve.Phase.Graduated) return;
        bool wasPending = c.phase() == BondingCurve.Phase.GraduationPending;
        LaunchToken t = c.token();
        // Fix round 1 (reviewer): picks the first actor (starting from the fuzzed `actorSeed`, wrapping around)
        // who actually HOLDS this curve's token, rather than a uniformly random one. With only 4 actors and
        // often just one or two of them having bought into a given curve, a plain random pick left `sell`
        // silently no-oping (`amount == 0`, see below) most of the time it was selected — including during a
        // `GraduationPending` window, which is why `sellsWhilePending` almost never fired even when `sell` had
        // a fair share of the call budget: the window closed some other way before a `sell` call ever landed on
        // an actor who could act on it.
        address a = actors[actorSeed % actors.length];
        for (uint256 i; i < actors.length; ++i) {
            address candidate = actors[(actorSeed + i) % actors.length];
            if (t.balanceOf(candidate) != 0) {
                a = candidate;
                break;
            }
        }
        // Fix round 1 (reviewer): capped from 10_000 (100%) to 2_000 (20%) of the actor's balance. Raising
        // `buy`'s bound (above) means one buy can now push a curve to the edge of selling out in a single call;
        // uncapped, a single subsequent `sell` from the SAME actor could immediately reverse most of that
        // progress (an actor holding a huge just-bought balance could sell 100% of it back), which is what made
        // graduations themselves unreliable from run to run even after `buy` alone could complete a curve.
        // Partial sells up to a meaningful fifth of a holding are still fuzzed; only the "dump everything back"
        // extreme is excluded here (it is exercised directly in `test/unit/BondingCurve.t.sol`).
        uint256 amount = t.balanceOf(a) * bound(share, 1, 2_000) / 10_000;
        if (amount == 0) return;
        // C1: a sell whose gross proceeds round to zero now reverts, so skip those rather than spend the
        // campaign's call budget on guaranteed reverts.
        (uint256 quotedOut, uint256 quotedFee) = c.quoteSell(amount);
        if (quotedOut + quotedFee == 0) return;
        _startFeeRecording();
        vm.startPrank(a);
        t.approve(address(c), amount);
        c.sell(amount, 0, address(0), type(uint256).max);
        vm.stopPrank();
        _harvestFees();
        if (wasPending) sellsWhilePending++;
    }

    /// @dev F2: toggles a forced revert of GraduationManager.graduate() so a completing buy's automatic
    ///      graduation attempt defers into GraduationPending instead of always succeeding.
    function toggleGraduationFailure(bool on) external {
        graduationForced = on;
        if (on) {
            vm.mockCallRevert(address(gm), abi.encodeWithSelector(gm.graduate.selector), bytes("forced"));
        } else {
            vm.clearMockedCalls();
        }
    }

    /// @dev F2: retries a deferred graduation. While forced, the retry is expected to revert (tolerated); once
    ///      not forced, `curve.graduate()` must succeed and leave the curve Graduated.
    function retryGraduation(uint256 curveSeed) external {
        _syncMock();
        if (curves.length == 0) return;
        BondingCurve c = curves[curveSeed % curves.length];
        if (c.phase() != BondingCurve.Phase.GraduationPending) return;
        _startFeeRecording();
        if (graduationForced) {
            // See the comment in `buy()`: only harvest on the success arm, never after a caught revert.
            try c.graduate() {
                _harvestFees();
            } catch {}
        } else {
            c.graduate();
            assertEq(uint256(c.phase()), uint256(BondingCurve.Phase.Graduated), "retry should graduate");
            retriesSucceeded++;
            _harvestFees();
        }
        _trackPhase(c);
    }

    /// @dev F3: exercises all four swap shapes against the graduated pool. `exactOutput` picks exact-input
    ///      (amountSpecified negative) vs exact-output (amountSpecified positive); `buyToken` picks direction.
    ///      Exact-USDC-in buys and exact-USDC-out sells now revert with `PartialFill()` on anything but an exact
    ///      fill (LaunchHook change); both are still attempted and only counted on success.
    function poolSwap(uint256 curveSeed, uint256 actorSeed, bool buyToken, bool exactOutput, uint256 amount) external {
        actorSeed %= actors.length;
        if (curves.length == 0) return;
        BondingCurve c = curves[curveSeed % curves.length];
        if (c.phase() != BondingCurve.Phase.Graduated) return;
        address a = actors[actorSeed % actors.length];
        LaunchToken t = c.token();
        if (!buyToken) {
            // Fix round 2 (reviewer): same fix as `sell()` — the two SELL shapes (1, 3) need `a` to actually
            // hold this curve's token, but a uniformly random actor often holds none of it (only whoever
            // bought does), which silently no-oped (`bal < 1e18`, below) far more often than the shapes'
            // genuine AMM revert rate alone would explain, leaving `exactInSells`/`exactOutSells` at zero on
            // several otherwise-healthy seeds.
            for (uint256 i; i < actors.length; ++i) {
                address candidate = actors[(actorSeed + i) % actors.length];
                if (t.balanceOf(candidate) != 0) {
                    a = candidate;
                    break;
                }
            }
        }
        PoolKey memory key = gm.poolKey(address(t));
        bool usdcIs0 = Currency.unwrap(key.currency0) == USDC;
        bool zeroForOne = buyToken == usdcIs0;

        int256 specified;
        uint8 shape;
        if (buyToken && !exactOutput) {
            specified = -int256(bound(amount, 1e6, 500e6));
            shape = 0;
        } else if (!buyToken && !exactOutput) {
            uint256 bal = t.balanceOf(a);
            if (bal < 1e18) return;
            specified = -int256(bound(amount, 1e18, bal));
            shape = 1;
        } else if (buyToken && exactOutput) {
            specified = int256(bound(amount, 1e18, 1_000_000e18));
            shape = 2;
        } else {
            if (t.balanceOf(a) < 1e18) return;
            // Fix round 2 (reviewer): shrunk from `[1e6, 200e6]`. An exact-USDC-OUT sell needs the trader to hold
            // enough tokens to cover whatever input the pool computes for that output; at the post-graduation
            // price (huge tokens per USDC, since a launch's whole curve supply backs a comparatively small USDC
            // pool leg) a request as large as 200 USDC often needed more tokens than a single actor had bought,
            // so the call simply reverted (caught, harmless, but `exactOutSells` never got credited). A much
            // smaller request is still an exact-output swap in every way that matters to this test, and is far
            // more often affordable out of whatever balance a `completeCurve`/`buy` actually left an actor with.
            specified = int256(bound(amount, 1e6, 5e6));
            shape = 3;
        }

        _startFeeRecording();
        vm.startPrank(a);
        t.approve(address(router), type(uint256).max);
        // See the comment in `buy()`: only harvest on the success arm. This is the exact call the reviewer
        // caught the bug through — an exact-output swap (shape 3) can have `LaunchHook.beforeSwap` call
        // `FeeManager.notifyHookFee` (emitting `FeeAccrued`) and THEN have PoolManager's own settlement revert
        // with `ERC20InsufficientBalance` later in the same call, once the hook has already computed how many
        // tokens to pull. Harvesting unconditionally would count that fee even though the whole swap, and the
        // real `totalOwed` increment, was rolled back.
        try router.swap(
            key,
            SwapParams(zeroForOne, specified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(a)
        ) {
            if (shape == 0) exactInBuys++;
            else if (shape == 1) exactInSells++;
            else if (shape == 2) exactOutBuys++;
            else exactOutSells++;
            _harvestFees();
        } catch {}
        vm.stopPrank();
    }

    /// @dev F4: checked claim — asserts the payout matches what was owed and the ledger is fully cleared.
    function claim(uint256 seed) external {
        address r = feeRecipients[seed % feeRecipients.length];
        uint256 owed = feeManager.balances(r);
        if (owed == 0) return;
        uint256 before = r.balance;
        vm.prank(r);
        uint256 amount = feeManager.claim(r);
        assertEq(amount, owed, "claim returns owed amount");
        assertEq(r.balance, before + owed, "recipient balance rose by owed");
        assertEq(feeManager.balances(r), 0, "recipient balance cleared after claim");
        ghostClaimed += owed;
    }

    /// @dev F4: checked platform claim — same shape, against the factory's treasury.
    function claimPlatform() external {
        uint256 owed = feeManager.platformBalance();
        if (owed == 0) return;
        address treasury = factory.treasury();
        uint256 before = treasury.balance;
        uint256 amount = feeManager.claimPlatform();
        assertEq(amount, owed, "claimPlatform returns owed amount");
        assertEq(treasury.balance, before + owed, "treasury balance rose by owed");
        assertEq(feeManager.platformBalance(), 0, "platform balance cleared after claim");
        ghostClaimed += owed;
    }

    function advance(uint256 blocks) external {
        vm.roll(vm.getBlockNumber() + bound(blocks, 1, advanceMaxBlocks));
    }

    /// @dev Fix round 2: `graduationForced` is ordinary handler storage and resets to false at the start of
    ///      every invariant run when forge reverts to its post-setUp snapshot, but the cheatcode-level mock
    ///      installed by `vm.mockCallRevert` may not be included in that revert. Called at the top of every
    ///      function that can reach `gm.graduate` (`buy`, `retryGraduation`) so the mock can never disagree with
    ///      the flag: if the flag reads off, the mock is forced off too, regardless of what forge did or didn't
    ///      revert.
    function _syncMock() private {
        if (!graduationForced) {
            vm.clearMockedCalls();
        }
    }

    /// @dev Reviewer coverage (g): reads every credit the FeeManager made during the call just performed
    ///      straight off its own events, so the ghost total is derived independently of `totalOwed`.
    function _startFeeRecording() private {
        vm.recordLogs();
    }

    function _harvestFees() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeAccrued = IFeeManager.FeeAccrued.selector;
        bytes32 platformAccrued = IFeeManager.PlatformAccrued.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(feeManager) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == feeAccrued) {
                (,, uint256 creatorAmount, uint256 referrerAmount, uint256 platformAmount,) =
                    abi.decode(logs[i].data, (address, address, uint256, uint256, uint256, uint8));
                ghostAccrued += creatorAmount + referrerAmount + platformAmount;
            } else if (logs[i].topics[0] == platformAccrued) {
                ghostAccrued += abi.decode(logs[i].data, (uint256));
            }
        }
    }

    /// @dev Records GraduationPending sightings and first-time graduations (never double-counts a curve that is
    ///      already known Graduated, since phase never reverts out of it).
    function _trackPhase(BondingCurve c) internal {
        BondingCurve.Phase p = c.phase();
        if (p == BondingCurve.Phase.GraduationPending) {
            pendingObserved++;
            // Fix round 1 (reviewer): the moment a deferral is OBSERVED, clear the forced flag. Pure
            // weight-tuning could not reliably reach `retriesSucceeded` — it needs `graduationForced` to be
            // true when the completing buy runs (so it defers at all) but false again soon after, before a
            // stray `sell` closes the window, and no single `toggleGraduationFailure` weight serves both:
            // frequent enough to flip off in time made it too likely to have already flipped off BEFORE the
            // completing buy (skipping the deferral entirely, see the report's fix-round-1 measurements); rare
            // enough to stay forced through completion left it forced for the rest of the pending window too.
            // Clearing it here mirrors an operator who notices the failure once it happens and fixes it before
            // the next retry — it does not remove any coverage: the fuzzer's own random
            // `toggleGraduationFailure` calls still run before AND after this point, so a forced retry attempt
            // (the "tolerated failure" arm in `retryGraduation`) and a later re-forced deferral are both still
            // reachable.
            if (graduationForced) {
                graduationForced = false;
                vm.clearMockedCalls();
            }
        } else if (p == BondingCurve.Phase.Graduated && !_wasGraduated[address(c)]) {
            _wasGraduated[address(c)] = true;
            graduations++;
        }
    }
}
