// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {GraduationManager} from "../../src/GraduationManager.sol";
import {LiquidityLocker} from "../../src/LiquidityLocker.sol";
import {LaunchHook} from "../../src/LaunchHook.sol";
import {LaunchConfig} from "../../src/libraries/LaunchTypes.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {GasCappedBuyer} from "../utils/GasCappedBuyer.sol";

contract GraduationTest is LaunchFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deploySystem();
    }

    /// @param expectedCollectedUsdcWei native-USDC (18-dec) `realUsdc` the curve held right before graduating
    ///        (i.e. what `poolSupply` gets paired against at the curve's final marginal price)
    /// @param priceRelTolerance `assertApproxEqRel`-style relative tolerance (1e18 == 100%) for the pool-vs-curve
    ///        price comparison
    /// @param usdcAbsTolerance6 absolute tolerance, in 6-decimal USDC units, for the pool's USDC balance
    function _assertGraduated(
        LaunchToken token,
        BondingCurve curve,
        uint256 expectedCollectedUsdcWei,
        uint256 priceRelTolerance,
        uint256 usdcAbsTolerance6
    ) internal view {
        // Curve price at sell-out in native-USDC wei per whole token. (curve.price() is only meaningful while
        // Trading: graduation moves the reserve out and zeroes realUsdc.)
        uint256 endPriceWeiPerToken =
            Math.mulDiv(cfg.virtualUsdc + expectedCollectedUsdcWei, 1e18, cfg.virtualTokens - cfg.curveSupply);
        PoolKey memory key = _key(address(token));
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        assertGt(sqrtPriceX96, 0, "pool not initialized");

        // Pool price (currency1 per currency0, raw units) converted to native-USDC wei per whole token.
        // Fix round 2: `sqrtPriceX96 * sqrtPriceX96` (plain uint256 multiplication) can itself overflow once
        // `sqrtPriceX96` is large — exactly what a small/skewed pool produces (the same class of bug fixed in
        // `GraduationManager._sqrtPriceX96`, this time in the test's own price-comparison math).
        // NOTE: an earlier version of this fix computed `sqrt(2^192 * 1e30 / sqrtPriceX96^2)`-equivalent via
        // `mulDiv(2^96, 1e15, sqrtPriceX96)` and squared that — overflow-safe, but it collapses sqrtPriceX96
        // down to a small (~5-digit) integer *before* squaring, which throws away precision that squaring
        // cannot recover (verified empirically: ~1.25e-5 relative error on the tiny-pool case, ~10x this
        // function's own tolerance floor). Fixed properly below: `Math.mulDiv` computes the full 512-bit
        // `sqrtPriceX96 * sqrtPriceX96` product internally and divides by `2^192` in one step — the
        // intermediate product is never materialized as a stored 256-bit value, so it never overflows, and no
        // precision is discarded before the division that a single-shot `mulDiv` wouldn't already round away.
        // `priceRatio = sqrtPriceX96^2 / 2^192` itself is bounded (< 2^128, since that's the ceiling on any
        // ratio v4 can represent), so multiplying it by `1e30` afterward (else branch) cannot overflow either.
        bool usdcIs0 = Currency.unwrap(key.currency0) == USDC;
        uint256 poolPrice;
        if (usdcIs0) {
            // 2^192 * 1e30 / sqrtPriceX96^2, as two chained single-precision divisions instead of one
            // division by the (possibly unrepresentable) full square.
            poolPrice = Math.mulDiv(uint256(1) << 192, 1e30, sqrtPriceX96) / sqrtPriceX96;
        } else {
            // sqrtPriceX96^2 * 1e30 / 2^192. NOTE: computing `mulDiv(sqrtPriceX96, sqrtPriceX96, 2^192)`
            // first and multiplying by 1e30 after (as the usdcIs0-mirrored form would) is WRONG here: that
            // inner mulDiv floors to 0 whenever the raw ratio is < 1 (common in this branch — token amounts
            // dwarf 6-decimal USDC amounts), discarding the 1e30 headroom needed to represent it. Instead
            // fold `1e30` in via two chained mulDivs (each keeping the full 512-bit product before dividing),
            // so no intermediate step floors to zero before the scale factor is applied.
            uint256 scaled = Math.mulDiv(uint256(sqrtPriceX96), 1e30, uint256(1) << 96);
            poolPrice = Math.mulDiv(scaled, uint256(sqrtPriceX96), uint256(1) << 96);
        }
        assertApproxEqRel(poolPrice, endPriceWeiPerToken, priceRelTolerance, "pool must open at the curve's final price");

        uint256 tokenId = locker.positionOf(address(token));
        assertGt(tokenId, 0);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(locker));
        assertTrue(locker.isLocked(address(token)));
        assertGt(posm.getPositionLiquidity(tokenId), 0);

        // Everything went into the pool: nothing stranded in the curve or the manager.
        assertEq(token.balanceOf(address(curve)), 0);
        assertEq(address(curve).balance, 0);
        assertEq(token.balanceOf(address(gm)), 0);
        assertEq(address(gm).balance, 0);
        assertApproxEqAbs(
            IERC20(USDC).balanceOf(address(poolManager)), expectedCollectedUsdcWei / 1e12, usdcAbsTolerance6
        );
        assertApproxEqRel(token.balanceOf(address(poolManager)), cfg.poolSupply, 1e12);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function test_graduatesInsideTheFinalBuy_tokenAboveUsdc() public {
        (LaunchToken token, BondingCurve curve) = _createOrdered(false);
        _graduate(curve);
        _assertGraduated(token, curve, 18_000e18, 1e12, 2);
    }

    function test_graduatesInsideTheFinalBuy_tokenBelowUsdc() public {
        (LaunchToken token, BondingCurve curve) = _createOrdered(true);
        _graduate(curve);
        _assertGraduated(token, curve, 18_000e18, 1e12, 2);
    }

    /// @dev Generalized `_graduate`: `LaunchFixture._graduate` hard-codes a 30,000e18 buy sized for the
    ///      default config. This local helper (kept separate from the shared fixture so the fixture stays
    ///      config-agnostic) takes the buy size as a parameter so tests can use a non-default config.
    function _graduateWithBuy(BondingCurve curve, uint256 buyValue) internal {
        vm.prank(bob);
        curve.buy{value: buyValue}(0, address(0), type(uint256).max);
        require(curve.phase() == BondingCurve.Phase.Graduated, "not graduated");
    }

    /// @dev Live-testnet repro config: `virtualUsdc = 0.5e18` (with `poolSupply`/`curveSupply` unchanged) means
    ///      the curve sells out at ~1.5 USDC collected, seeding the pool with only ~1,500,000 6-decimal USDC
    ///      units against 200,000,000e18 tokens. Mutates the inherited `cfg` field (not the fixture file) so
    ///      `_create`/`_createOrdered`'s `cfg.launchFee` stays in sync with what the factory will actually
    ///      charge for tokens created after this call.
    function _useTinyConfig() internal {
        LaunchConfig memory tiny = cfg;
        tiny.virtualUsdc = 0.5e18;
        tiny.launchFee = 0.1e18;
        vm.prank(owner);
        factory.setConfig(tiny);
        cfg = tiny;
    }

    /// @dev The curve's realUsdc when it sells exactly `curveSupply` tokens is an exact invariant of the
    ///      constant-product formula: `x_end = virtualUsdc * virtualTokens / (virtualTokens - curveSupply)`
    ///      (same formula `LaunchFactory._setConfig` uses for its no-arbitrage check), so `x_end - virtualUsdc`
    ///      is the collected amount, computed exactly rather than guessed.
    function _expectedCollectedUsdc(LaunchConfig memory c) internal pure returns (uint256) {
        uint256 yEnd = c.virtualTokens - c.curveSupply;
        uint256 xEnd = Math.mulDiv(c.virtualUsdc, c.virtualTokens, yEnd, Math.Rounding.Ceil);
        return xEnd - c.virtualUsdc;
    }

    /// @dev `assertApproxEqRel`-style relative tolerance (1e18 == 100%) that accounts for 6-decimal USDC
    ///      granularity on small pools: max(1e-6, 2 / usdcUnitsSeeded), expressed in the 1e18 fixed-point form.
    function _priceTolerance(uint256 usdcUnitsSeeded) internal pure returns (uint256) {
        uint256 granularityTolerance = Math.mulDiv(2, 1e18, usdcUnitsSeeded, Math.Rounding.Ceil);
        return granularityTolerance > 1e12 ? granularityTolerance : 1e12;
    }

    /// @dev Live-testnet bug repro: token sorts ABOVE USDC ⇒ USDC is currency0 ⇒ in the old code
    ///      `amount1/amount0 = poolSupply/usdcUnits ≈ 1.33e20 ≥ 2^64` overflowed `Math.mulDiv(amount1, 1 <<
    ///      192, amount0)` with `Panic(0x11)`. Because the panic happens inside `executeGraduation`, which is
    ///      called through `try this.executeGraduation() {} catch {...}`, the outer buy still succeeds but the
    ///      curve is left `GraduationPending` (and emits `GraduationDeferred`) instead of `Graduated` — that is
    ///      the failure this test captures.
    function test_graduatesWithTinyPool_tokenAboveUsdc() public {
        _useTinyConfig();
        (LaunchToken token, BondingCurve curve) = _createOrdered(false); // token ABOVE USDC ⇒ USDC is currency0
        _graduateWithBuy(curve, 3e18);
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated), "must graduate inside the buy");
        uint256 collected = _expectedCollectedUsdc(cfg);
        _assertGraduated(token, curve, collected, _priceTolerance(collected / 1e12), 2);
    }

    /// @dev Control: token sorts BELOW USDC ⇒ token is currency0 ⇒ tiny ratio ⇒ no overflow even before the
    ///      two-branch fix; kept to prove that fix does not regress this ordering.
    function test_graduatesWithTinyPool_tokenBelowUsdc() public {
        _useTinyConfig();
        (LaunchToken token, BondingCurve curve) = _createOrdered(true); // token BELOW USDC ⇒ token is currency0
        _graduateWithBuy(curve, 3e18);
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated), "must graduate inside the buy");
        uint256 collected = _expectedCollectedUsdc(cfg);
        _assertGraduated(token, curve, collected, _priceTolerance(collected / 1e12), 2);
    }

    function test_poolKeyShape() public {
        (LaunchToken token,) = _create("a");
        PoolKey memory key = _key(address(token));
        assertEq(key.fee, 0);
        assertEq(key.tickSpacing, 200);
        assertEq(address(key.hooks), address(hook));
        assertTrue(Currency.unwrap(key.currency0) < Currency.unwrap(key.currency1));
    }

    function test_onlyTheTokensCurveMayGraduate() public {
        (LaunchToken token,) = _create("a");
        vm.deal(address(this), 1e18);
        vm.expectRevert(GraduationManager.Unauthorized.selector);
        gm.graduate{value: 1e18}(address(token));
    }

    function test_nobodyCanPreInitializeThePool() public {
        (LaunchToken token, BondingCurve curve) = _create("a");
        PoolKey memory key = _key(address(token));
        vm.prank(bob);
        // PoolManager wraps hook reverts in CustomRevert.WrappedError(target, selector, reason, details); pin
        // the actual cause by searching the revert data for LaunchHook.NotGraduationManager's selector rather
        // than accepting any revert.
        (bool ok, bytes memory data) =
            address(poolManager).call(abi.encodeCall(poolManager.initialize, (key, uint160(79228162514264337593543950336))));
        assertFalse(ok, "pre-initialize must revert");
        assertTrue(
            _containsSelector(data, LaunchHook.NotGraduationManager.selector),
            "revert must be caused by LaunchHook.NotGraduationManager"
        );
        _graduate(curve); // and graduation still works afterwards
        assertTrue(locker.isLocked(address(token)));
    }

    /// @dev Searches `data` for the four consecutive bytes of `selector`, wherever the ABI encoding placed them
    ///      (e.g. inside CustomRevert.WrappedError's `reason` field).
    function _containsSelector(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i <= data.length - 4; ++i) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    function test_lockerRecordOnlyFromGraduationManager() public {
        vm.expectRevert(LiquidityLocker.Unauthorized.selector);
        locker.record(address(1), 1);
    }

    function test_lockedPositionCannotBeWithdrawnByAnyone() public {
        (LaunchToken token, BondingCurve curve) = _create("a");
        _graduate(curve);
        uint256 tokenId = locker.positionOf(address(token));
        uint128 liquidity = posm.getPositionLiquidity(tokenId);
        PoolKey memory key = _key(address(token));

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, bob);

        address[4] memory attackers = [bob, creator, owner, address(gm)];
        for (uint256 i; i < attackers.length; ++i) {
            vm.prank(attackers[i]);
            vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, attackers[i]));
            posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        }

        vm.prank(bob);
        vm.expectRevert(); // solmate ERC-721's "NOT_AUTHORIZED" string revert
        IERC721(address(posm)).transferFrom(address(locker), bob, tokenId);
        assertEq(posm.getPositionLiquidity(tokenId), liquidity);
    }

    function test_lockerHasNoOutboundSurface() public view {
        // A staticcall to a missing selector reverts the same way as one to an existing state-changing
        // function, so an ABI-surface probe proves nothing. Walk the actual runtime opcodes instead.
        assertFalse(
            _hasOutboundOpcode(address(locker)),
            "locker bytecode must contain no CALL/CALLCODE/DELEGATECALL/CREATE/CREATE2/SELFDESTRUCT"
        );
    }

    function test_opcodeWalkerDetectsCallInARealCaller() public view {
        // Sanity check for the walker itself: GraduationManager makes ordinary external calls (permit2
        // approvals, PositionManager, FeeManager), so it must contain CALL — proving the walker isn't
        // vacuously returning false on everything.
        assertTrue(_hasOutboundOpcode(address(gm)), "sanity check: walker must find CALL in a contract that has one");
    }

    /// @dev Walks `target`'s runtime bytecode opcode by opcode, skipping PUSH1..PUSH32 immediates and the
    ///      trailing Solidity CBOR metadata (whose length is the big-endian uint16 in the code's last two
    ///      bytes), and reports whether it contains CALL, CALLCODE, DELEGATECALL, CREATE, CREATE2 or
    ///      SELFDESTRUCT. STATICCALL is not checked for (the locker's `ownerOf` reads are exactly that).
    function _hasOutboundOpcode(address target) internal view returns (bool) {
        bytes memory code = target.code;
        uint256 len = code.length;
        if (len < 2) return false;
        uint256 metadataLen = (uint256(uint8(code[len - 2])) << 8) | uint256(uint8(code[len - 1]));
        uint256 end = (metadataLen + 2 <= len) ? len - metadataLen - 2 : len;
        uint256 i;
        while (i < end) {
            uint8 op = uint8(code[i]);
            if (op == 0xf0 || op == 0xf1 || op == 0xf2 || op == 0xf4 || op == 0xf5 || op == 0xff) return true;
            // PUSH1 (0x60) .. PUSH32 (0x7f): skip the opcode byte plus its (op - 0x5f) immediate bytes.
            i += (op >= 0x60 && op <= 0x7f) ? (op - 0x5e) : 1;
        }
        return false;
    }

    /// @dev F1 ruling: a third party donates tokens to the manager before sell-out, trying to inflate the
    ///      token leg it seeds the pool with and skew the opening price away from the curve's final price.
    function test_donatedTokensDoNotMoveThePoolPrice() public {
        (LaunchToken token, BondingCurve curve) = _create("a");

        uint256 usdcIn = 500e18;
        (uint256 tokensOut,,,) = curve.quoteBuy(usdcIn);
        vm.prank(alice);
        curve.buy{value: usdcIn}(0, address(0), type(uint256).max);
        uint256 donated = tokensOut / 2;
        assertGt(donated, 0);
        vm.prank(alice);
        token.transfer(address(gm), donated);
        assertGe(token.balanceOf(address(gm)), donated, "donation landed on the manager");

        _graduate(curve);
        // Still opens at the curve's final price, and the pool still gets exactly ~poolSupply tokens —
        // not poolSupply + donated.
        _assertGraduated(token, curve, 18_000e18, 1e12, 2);

        // The donated tokens are swept to the locker with the position dust, never sold into the pool.
        assertGe(token.balanceOf(address(locker)), donated);
    }

    /// @dev F1: below `poolSupply`, `graduate` must refuse rather than silently seed less than the curve
    ///      declared (which would also shift the opening price). Impersonates the curve directly (skipping the
    ///      token transfer it would normally make first) to hit the manager's own balance == 0 while
    ///      `factory.curveOf(token) == msg.sender` still holds, isolating this check from `Unauthorized`.
    function test_graduateRevertsIfBalanceBelowDeclaredPoolSupply() public {
        (LaunchToken token, BondingCurve curve) = _create("a");
        vm.deal(address(curve), 18_000e18);
        vm.prank(address(curve));
        vm.expectRevert(GraduationManager.InsufficientTokenBalance.selector);
        gm.graduate{value: 18_000e18}(address(token));
    }

    /// @dev F5: the `Graduated` event must report what actually entered the pool, not the pre-mint maximum.
    function test_graduatedEventReportsActualPoolAmounts() public {
        (LaunchToken token, BondingCurve curve) = _create("a");
        vm.recordLogs();
        _graduate(curve);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("Graduated(address,bytes32,uint160,uint256,uint256)");
        bool found;
        uint256 emittedUsdcAmount;
        uint256 emittedTokenAmount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(gm) && logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                (, uint256 usdcAmount, uint256 tokenAmount) = abi.decode(logs[i].data, (uint160, uint256, uint256));
                emittedUsdcAmount = usdcAmount;
                emittedTokenAmount = tokenAmount;
                found = true;
            }
        }
        assertTrue(found, "Graduated event not emitted");
        // The pool held none of either asset before this graduation, so its balance is exactly the increase.
        assertEq(emittedTokenAmount, token.balanceOf(address(poolManager)), "emitted token amount must match the pool's balance increase");
        assertEq(emittedUsdcAmount, IERC20(USDC).balanceOf(address(poolManager)), "emitted usdc amount must match the pool's balance increase");
    }

    // ---------------------------------------------------------------- C1: the gas floor, against the real stack

    /// @dev C1 end to end: bisects the smallest gas cap a sell-out buy can succeed with, then proves that
    ///      EVERY cap below it reverts the whole buy with `InsufficientGasForGraduation` and leaves the curve
    ///      exactly as it was. The griefing lever was a cap that let the buy through while starving graduation;
    ///      with the floor in place no such cap exists, so `GraduationPending` is unreachable by gas choice.
    function test_noGasCapCanLeaveTheRealGraduationDeferred() public {
        (, BondingCurve curve) = _create("gasfloor");
        GasCappedBuyer probe = new GasCappedBuyer();
        vm.deal(address(probe), 60_000e18);

        // Control: with ample gas the buy graduates inline, and this is what it actually costs.
        uint256 snap = vm.snapshotState();
        probe.probeBuy(curve, 30_000e18, 30_000_000);
        assertFalse(probe.callReverted(), "control: ample gas must graduate inline");
        uint256 full = probe.gasUsedByCall();
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));
        vm.revertToState(snap);

        uint256 floor_ = curve.GRADUATION_GAS_FLOOR();
        // `lo` always fails, `hi` always succeeds; `full + floor_` is comfortably above the true threshold
        // (which is the floor plus the buy's own pre-graduation work).
        uint256 lo = 300_000;
        uint256 hi = full + floor_;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 s = vm.snapshotState();
            probe.probeBuy(curve, 30_000e18, mid);
            bool ok = !probe.callReverted();
            vm.revertToState(s);
            if (ok) hi = mid;
            else lo = mid;
        }
        emit log_named_uint("sell-out buy gas with ample gas", full);
        emit log_named_uint("smallest cap that graduates", hi);
        emit log_named_uint("largest cap that does not", lo);
        // The floor is what binds: the threshold sits above GRADUATION_GAS_FLOOR by the buy's own work, not
        // at the bare cost of a successful graduation.
        assertGt(hi, floor_, "the floor must be the binding constraint");
        assertLt(full, floor_ + 400_000, "sanity: a successful buy still costs far less than the threshold");

        // Every cap below the threshold: whole buy reverts, nothing deferred, nothing half-done.
        uint256[6] memory caps = [lo, (lo * 9) / 10, lo / 2, 800_000, 400_000, 250_000];
        for (uint256 i; i < caps.length; ++i) {
            uint256 s = vm.snapshotState();
            probe.probeBuy(curve, 30_000e18, caps[i]);
            assertTrue(probe.callReverted(), "a cap below the threshold must revert the buy");
            assertEq(
                bytes4(probe.revertData()),
                BondingCurve.InsufficientGasForGraduation.selector,
                "and it must be the gas guard that rejected it"
            );
            assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Trading), "never left GraduationPending");
            assertEq(curve.sold(), 0);
            assertEq(curve.realUsdc(), 0);
            vm.revertToState(s);
        }

        // And at the threshold it graduates for real.
        probe.probeBuy(curve, 30_000e18, hi);
        assertFalse(probe.callReverted());
        assertEq(uint8(curve.phase()), uint8(BondingCurve.Phase.Graduated));
    }

    // ---------------------------------------------------------------- M3b: donations are not a launch's money

    /// @dev M3b: this contract has no `receive()`, but on Arc any ERC-20 USDC transfer lands as native balance,
    ///      so a stranger can put USDC here at will. Graduation may only sweep what THIS graduation left over.
    function test_onlyThisGraduationsLeftoverIsSwept() public {
        (LaunchToken token, BondingCurve curve) = _create("donation");
        uint256 donation = 5e18;
        vm.deal(address(gm), donation);

        vm.recordLogs();
        _graduate(curve);
        uint256 sweptByTheManager = _platformAccruedFrom(vm.getRecordedLogs(), address(gm));

        assertEq(address(gm).balance, donation, "a stranger's donation stays exactly where it was put");
        // Whatever the manager itself hands to the platform is only the sub-one-unit remainder of the USDC the
        // curve sent it, never the donation. (The curve separately accrues its own config surplus, which is
        // unrelated and much larger — hence filtering the events by emitter's caller.)
        assertLt(sweptByTheManager, 1e12, "only this graduation's own leftover may be swept");
        assertTrue(locker.isLocked(address(token)));

        // The donation is still there, and still nobody's: a later graduation does not pick it up either.
        (, BondingCurve curve2) = _create("donation2");
        vm.recordLogs();
        _graduate(curve2);
        assertEq(
            _platformAccruedFrom(vm.getRecordedLogs(), address(gm)) < 1e12,
            true,
            "the next graduation does not take it either"
        );
        assertEq(address(gm).balance, donation, "and the donation is still untouched");
    }

    /// @dev Sums `PlatformAccrued(token, from, amount)` amounts whose indexed `from` is `who`.
    function _platformAccruedFrom(Vm.Log[] memory logs, address who) internal view returns (uint256 total) {
        bytes32 sig = keccak256("PlatformAccrued(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(feeManager) && logs[i].topics.length == 3 && logs[i].topics[0] == sig
                    && logs[i].topics[2] == bytes32(uint256(uint160(who)))
            ) total += abi.decode(logs[i].data, (uint256));
        }
    }



    /// @dev Reviewer coverage (d): field-level `vm.expectEmit` on `Graduated`. The four data fields are
    ///      captured from a first, snapshotted graduation and independently cross-checked against the pool's
    ///      own post-state (slot0 price, and the two balances the mint actually moved) BEFORE being replayed as
    ///      the expectation — so the expectation is pinned to values the pool itself vouches for, not merely to
    ///      whatever the event happened to say.
    function test_graduatedEventFields() public {
        (LaunchToken token, BondingCurve curve) = _create("evt");
        PoolKey memory key = _key(address(token));
        bytes32 poolId = PoolId.unwrap(key.toId());

        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        _graduate(curve);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("Graduated(address,bytes32,uint160,uint256,uint256)");
        uint160 sqrtPriceX96;
        uint256 usdcAmount;
        uint256 tokenAmount;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(gm) && logs[i].topics.length == 3 && logs[i].topics[0] == sig) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(token)))), "indexed token");
                assertEq(logs[i].topics[2], poolId, "indexed poolId");
                (sqrtPriceX96, usdcAmount, tokenAmount) = abi.decode(logs[i].data, (uint160, uint256, uint256));
                found = true;
            }
        }
        assertTrue(found, "Graduated event not emitted");

        // Independent corroboration of each data field against the pool itself.
        (uint160 slot0Price,,,) = poolManager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, slot0Price, "sqrtPriceX96 must be the price the pool was initialized at");
        assertEq(usdcAmount, IERC20(USDC).balanceOf(address(poolManager)), "usdcAmount is 6-decimal USDC");
        assertEq(tokenAmount, token.balanceOf(address(poolManager)), "tokenAmount is 18-decimal tokens");

        vm.revertToState(snap);

        vm.expectEmit(true, true, true, true, address(gm));
        emit GraduationManager.Graduated(address(token), poolId, sqrtPriceX96, usdcAmount, tokenAmount);
        _graduate(curve);
    }

}
