// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchFactory} from "../../src/LaunchFactory.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {FeeManager} from "../../src/FeeManager.sol";
import {GraduationManager} from "../../src/GraduationManager.sol";
import {LaunchHook} from "../../src/LaunchHook.sol";
import {LaunchConfig, CreateParams} from "../../src/libraries/LaunchTypes.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract AdvBomb {
    constructor() payable {}

    function boom(address payable to) external {
        selfdestruct(to);
    }
}

/// @dev Adversarial stateful handler on the REAL stack. It never reverts and never asserts: every expectation
///      that fails is recorded in `violationCount` / `firstViolation`, which the invariant test asserts on, so a
///      `fail_on_revert = false` campaign cannot swallow a finding. It keeps an INDEPENDENT model of the fee
///      ledger (creator / referrer / platform split, referral binding) driven by the curves' and the hook's own
///      events plus the FeeManager's raw native-balance delta, never by the FeeManager's events or storage.
contract AdvHandler is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_CURVES = 5;

    // action ids
    uint256 internal constant A_CREATE = 0;
    uint256 internal constant A_CREATE_BUY = 1;
    uint256 internal constant A_BUY = 2;
    uint256 internal constant A_COMPLETE = 3;
    uint256 internal constant A_SELL = 4;
    uint256 internal constant A_RETRY = 5;
    uint256 internal constant A_SWAP_IN_BUY = 6;
    uint256 internal constant A_SWAP_IN_SELL = 7;
    uint256 internal constant A_SWAP_OUT_BUY = 8;
    uint256 internal constant A_SWAP_OUT_SELL = 9;
    uint256 internal constant A_ADD_LIQ = 10;
    uint256 internal constant A_REMOVE_LIQ = 11;
    uint256 internal constant A_DONATE_POOL = 12;
    uint256 internal constant A_BIND = 13;
    uint256 internal constant A_CLAIM = 14;
    uint256 internal constant A_CLAIM_HOSTILE = 15;
    uint256 internal constant A_CLAIM_PLATFORM = 16;
    uint256 internal constant A_SWEEP = 17;
    uint256 internal constant A_FORCE_NATIVE = 18;
    uint256 internal constant A_DONATE_USDC = 19;
    uint256 internal constant A_DONATE_TOKEN = 20;
    uint256 internal constant A_SET_CONFIG = 21;
    uint256 internal constant A_PAUSE = 22;
    uint256 internal constant A_SABOTAGE = 23;
    uint256 internal constant A_ADVANCE = 24;
    uint256 internal constant N_ACTIONS = 25;

    LaunchFactory public factory;
    FeeManager public fm;
    GraduationManager public gm;
    LaunchHook public hook;
    IPoolManager public pm;
    PoolSwapTest public swapRouter;
    PoolModifyLiquidityTest public liqRouter;
    PoolDonateTest public donateRouter;
    address public owner;
    address public guardian;
    LaunchConfig internal baseCfg;

    BondingCurve[] public curves;
    address[] public actors;
    address[] public claimants; // EOAs that may earn
    address[] public ledgerAccounts; // everything summed against totalOwed

    struct Pos {
        uint256 curveIdx;
        int24 lo;
        int24 hi;
        bytes32 salt;
        address ownerActor;
        uint256 liq;
    }

    Pos[] public positions;

    // ---- ghost model
    mapping(address => uint256) public ghostBal;
    uint256 public ghostPlatform;
    uint256 public ghostUnswept; // donated to the FeeManager and not swept yet
    uint256 public ghostGmDonated;
    mapping(address => uint256) public ghostCurveDonated;
    mapping(address => uint256) public ghostCurveTokenDonated;
    mapping(address => address) public ghostRef;
    mapping(address => bool) public ghostTraded;
    mapping(address => address) public tokenOfCurve;
    mapping(address => address) public creatorOf; // by token
    mapping(address => uint256) public cShare; // by token
    mapping(address => uint256) public rShare; // by token
    mapping(address => uint256) public feeBpsOf; // by token
    mapping(address => uint256) public lastK;
    mapping(address => bool) public seenGraduated;
    mapping(address => uint256) public lockedLiq; // by token
    mapping(address => bool) internal isCurve;

    uint256 public cfgIdx;
    bool public sabotaged;
    bool public pausedGhost;
    uint256 public pendingObserved;
    uint256 public sellsWhilePending;
    uint256 public graduations;
    uint256 public graduationsInsideCreate;

    uint256[N_ACTIONS] public okCount;
    uint256[N_ACTIONS] public failCount;
    uint256 public violationCount;
    string public firstViolation;

    // scratch for log settlement
    address internal _pendingRef;
    address internal _pendingHookTrader;

    constructor(
        LaunchFactory factory_,
        FeeManager fm_,
        GraduationManager gm_,
        LaunchHook hook_,
        IPoolManager pm_,
        address owner_,
        address guardian_
    ) {
        (factory, fm, gm, hook, pm, owner, guardian) = (factory_, fm_, gm_, hook_, pm_, owner_, guardian_);
        swapRouter = new PoolSwapTest(pm_);
        liqRouter = new PoolModifyLiquidityTest(pm_);
        donateRouter = new PoolDonateTest(pm_);
        baseCfg = factory_.config();
        for (uint256 i; i < 5; ++i) {
            address a = makeAddr(string.concat("advActor", vm.toString(i)));
            actors.push(a);
            claimants.push(a);
            vm.deal(a, 20_000_000e18);
            vm.startPrank(a);
            IERC20(USDC).approve(address(swapRouter), type(uint256).max);
            IERC20(USDC).approve(address(liqRouter), type(uint256).max);
            IERC20(USDC).approve(address(donateRouter), type(uint256).max);
            vm.stopPrank();
        }
        claimants.push(makeAddr("advRefA"));
        claimants.push(makeAddr("advRefB"));
        claimants.push(makeAddr("advCreatorA"));
        claimants.push(makeAddr("advCreatorB"));
        for (uint256 i; i < claimants.length; ++i) ledgerAccounts.push(claimants[i]);
        ledgerAccounts.push(address(0));
        ledgerAccounts.push(address(fm_));
        ledgerAccounts.push(address(gm_));
        ledgerAccounts.push(address(hook_));
        ledgerAccounts.push(address(pm_));
        ledgerAccounts.push(address(factory_));
        ledgerAccounts.push(address(this));
        ledgerAccounts.push(address(swapRouter));
        vm.deal(address(this), 1_000_000e18);
    }

    // ------------------------------------------------------------------ views for the test

    function curveCount() external view returns (uint256) { return curves.length; }
    function ledgerCount() external view returns (uint256) { return ledgerAccounts.length; }
    function actorCount() external view returns (uint256) { return actors.length; }
    function claimantCount() external view returns (uint256) { return claimants.length; }
    function nActions() external pure returns (uint256) { return N_ACTIONS; }

    function statsCsv() external view returns (string memory s) {
        for (uint256 i; i < N_ACTIONS; ++i) {
            s = string.concat(s, vm.toString(okCount[i]), ",", vm.toString(failCount[i]), ",");
        }
        s = string.concat(
            s,
            vm.toString(curves.length), ",",
            vm.toString(graduations), ",",
            vm.toString(pendingObserved), ",",
            vm.toString(sellsWhilePending), ",",
            vm.toString(graduationsInsideCreate), ",",
            vm.toString(violationCount)
        );
    }

    // ------------------------------------------------------------------ internals

    function _violate(string memory what) internal {
        if (violationCount == 0) firstViolation = what;
        violationCount++;
    }

    function _sync() internal {
        if (!sabotaged) vm.clearMockedCalls();
    }

    function _cfg(uint256 idx) internal view returns (LaunchConfig memory c) {
        c = baseCfg;
        if (idx == 1) {
            c.tradeFeeBps = 250;
            c.creatorShareBps = 1_000;
            c.referrerShareBps = 9_000;
            c.snipeBlocks = 0;
            c.launchFee = 0;
            c.maxInitialBuyTokens = c.curveSupply;
        } else if (idx == 2) {
            c.tradeFeeBps = 0;
            c.creatorShareBps = 0;
            c.referrerShareBps = 0;
            c.launchFee = 100e18;
            c.snipeBlocks = 1_200;
        } else if (idx == 3) {
            c.tradeFeeBps = 500;
            c.creatorShareBps = 3_333;
            c.referrerShareBps = 3_334;
            c.snipeStartBps = 5_000;
            c.snipeBlocks = 7;
            c.launchFee = 3;
        }
    }

    function _refFrom(uint256 seed) internal view returns (address) {
        uint256 k = seed % (claimants.length + 1);
        return k == claimants.length ? address(0) : claimants[k];
    }

    function _creatorFrom(uint256 seed) internal view returns (address) {
        uint256 k = seed % (claimants.length + 2);
        if (k == claimants.length) return address(fm); // hostile: unclaimable
        if (k == claimants.length + 1) return address(hook);
        return claimants[k];
    }

    function _ghostCurveTrade(address token, address trader, address refArg, uint256 fee) internal returns (uint256) {
        if (!ghostTraded[trader]) {
            ghostTraded[trader] = true;
            if (ghostRef[trader] == address(0) && refArg != address(0) && refArg != trader) ghostRef[trader] = refArg;
        }
        return _ghostSplit(token, trader, fee);
    }

    function _ghostSplit(address token, address trader, uint256 fee) internal returns (uint256 parts) {
        uint256 cPart = fee * cShare[token] / BPS;
        address r = ghostRef[trader];
        uint256 rPart = r == address(0) ? 0 : fee * rShare[token] / BPS;
        ghostBal[creatorOf[token]] += cPart;
        if (rPart != 0) ghostBal[r] += rPart;
        parts = cPart + rPart;
    }

    /// @dev Settles a SUCCESSFUL call: reads the curves' Buy/Sell and the hook's HookFee logs, applies the
    ///      independent split, and books the rest of the FeeManager's raw balance delta to the platform.
    function _settle(uint256 fmBefore) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 parts;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 0) continue;
            if (isCurve[l.emitter]) {
                if (l.topics[0] == BondingCurve.Buy.selector) {
                    (,, uint256 fee,,,) = abi.decode(l.data, (uint256, uint256, uint256, uint256, uint256, uint256));
                    parts += _ghostCurveTrade(
                        tokenOfCurve[l.emitter], address(uint160(uint256(l.topics[1]))), _pendingRef, fee
                    );
                } else if (l.topics[0] == BondingCurve.Sell.selector) {
                    (,, uint256 fee,,) = abi.decode(l.data, (uint256, uint256, uint256, uint256, uint256));
                    parts += _ghostCurveTrade(
                        tokenOfCurve[l.emitter], address(uint160(uint256(l.topics[1]))), _pendingRef, fee
                    );
                }
            } else if (l.emitter == address(hook) && l.topics[0] == LaunchHook.HookFee.selector) {
                address token = address(uint160(uint256(l.topics[1])));
                address trader = address(uint160(uint256(l.topics[2])));
                if (trader != _pendingHookTrader) _violate("hook attributed a different trader than hookData decodes to");
                uint256 fee6 = abi.decode(l.data, (uint256));
                parts += _ghostSplit(token, trader, fee6 * 1e12);
            }
        }
        uint256 delta = address(fm).balance - fmBefore;
        if (delta < parts) {
            _violate("FeeManager received less than the creator+referrer parts");
        } else {
            ghostPlatform += delta - parts;
        }
    }

    function _flush() internal {
        vm.getRecordedLogs();
    }

    function _post() internal {
        for (uint256 i; i < curves.length; ++i) {
            BondingCurve c = curves[i];
            BondingCurve.Phase p = c.phase();
            if (p != BondingCurve.Phase.Graduated) {
                uint256 k = (c.virtualUsdc() + c.realUsdc()) * (c.virtualTokens() - c.sold());
                if (k < lastK[address(c)]) _violate("k decreased");
                lastK[address(c)] = k;
            } else if (!seenGraduated[address(c)]) {
                seenGraduated[address(c)] = true;
                graduations++;
                ghostCurveDonated[address(c)] = 0; // swept to the platform by executeGraduation
                address t = tokenOfCurve[address(c)];
                lockedLiq[t] = gm.positionManager().getPositionLiquidity(gm.locker().positionOf(t));
            }
        }
    }

    function _pickCurve(uint256 seed, BondingCurve.Phase want, bool exact) internal view returns (BondingCurve c, bool ok) {
        uint256 n = curves.length;
        for (uint256 i; i < n; ++i) {
            c = curves[(seed % n + i) % n];
            BondingCurve.Phase p = c.phase();
            if (exact ? p == want : p != BondingCurve.Phase.Graduated) return (c, true);
        }
        return (c, false);
    }

    // ------------------------------------------------------------------ actions

    function create(uint256 actorSeed, uint256 creatorSeed, uint256 refSeed, uint256 initialBuy, bool withBuy) external {
        _sync();
        uint256 act = withBuy ? A_CREATE_BUY : A_CREATE;
        if (curves.length >= MAX_CURVES) return;
        address a = actors[actorSeed % actors.length];
        LaunchConfig memory c = _cfg(cfgIdx);
        CreateParams memory p =
            CreateParams("T", "T", "u", _creatorFrom(creatorSeed), _refFrom(refSeed), bytes32(0));
        bool below = curves.length % 2 == 0;
        bool found;
        for (uint256 i; i < 64; ++i) {
            p.salt = bytes32(curves.length * 1_000_000 + i + 1);
            (address predicted,) = factory.computeAddresses(a, p);
            if ((predicted < USDC) == below) { found = true; break; }
        }
        if (!found) return;
        (address predT, address predC) = factory.computeAddresses(a, p);

        uint256 buyValue;
        if (withBuy) {
            buyValue = c.maxInitialBuyTokens == c.curveSupply
                ? bound(initialBuy, 1, 40_000e18)
                : bound(initialBuy, 1, 400e18);
        }
        bytes32 h = factory.configHash();
        uint256 fmBefore = address(fm).balance;
        _pendingRef = p.referrer;
        vm.recordLogs();
        vm.prank(a);
        try factory.createToken{value: c.launchFee + buyValue}(p, h, 0) returns (address t, address cv) {
            if (pausedGhost) _violate("createToken succeeded while paused");
            if (t != predT || cv != predC) _violate("computeAddresses mismatch");
            curves.push(BondingCurve(cv));
            isCurve[cv] = true;
            tokenOfCurve[cv] = t;
            creatorOf[t] = p.creator;
            cShare[t] = c.creatorShareBps;
            rShare[t] = c.referrerShareBps;
            feeBpsOf[t] = c.tradeFeeBps;
            ledgerAccounts.push(cv);
            for (uint256 i; i < actors.length; ++i) {
                vm.startPrank(actors[i]);
                IERC20(t).approve(cv, type(uint256).max);
                IERC20(t).approve(address(swapRouter), type(uint256).max);
                IERC20(t).approve(address(liqRouter), type(uint256).max);
                IERC20(t).approve(address(donateRouter), type(uint256).max);
                vm.stopPrank();
            }
            _settle(fmBefore);
            if (BondingCurve(cv).phase() == BondingCurve.Phase.Graduated) graduationsInsideCreate++;
            okCount[act]++;
        } catch {
            _flush();
            failCount[act]++;
        }
        _post();
    }

    function buy(uint256 curveSeed, uint256 actorSeed, uint256 refSeed, uint256 amount) external {
        _sync();
        if (curves.length == 0) return;
        (BondingCurve c, bool ok) = _pickCurve(curveSeed, BondingCurve.Phase.Trading, true);
        if (!ok) return;
        amount = amount % 7 == 0 ? 1 + amount % 1e13 : bound(amount, 1e12, 9_000e18);
        _buy(c, actors[actorSeed % actors.length], _refFrom(refSeed), amount, A_BUY);
    }

    function completeBuy(uint256 curveSeed, uint256 actorSeed, bool skipSnipe) external {
        _sync();
        if (curves.length == 0) return;
        (BondingCurve c, bool ok) = _pickCurve(curveSeed, BondingCurve.Phase.Trading, true);
        if (!ok) return;
        if (skipSnipe) {
            uint256 end = c.launchBlock() + c.snipeBlocks();
            if (vm.getBlockNumber() < end) vm.roll(end);
        }
        _buy(c, actors[actorSeed % actors.length], address(0), 60_000e18, A_COMPLETE);
    }

    function _buy(BondingCurve c, address a, address ref, uint256 amount, uint256 act) internal {
        uint256 fmBefore = address(fm).balance;
        uint256 curveTokBefore = c.token().balanceOf(address(c));
        _pendingRef = ref;
        vm.recordLogs();
        vm.prank(a);
        try c.buy{value: amount}(0, ref, type(uint256).max) returns (uint256 out) {
            _settle(fmBefore);
            okCount[act]++;
            if (c.phase() == BondingCurve.Phase.GraduationPending) pendingObserved++;
            if (c.phase() != BondingCurve.Phase.Graduated && c.token().balanceOf(address(c)) != curveTokBefore - out) {
                _violate("buy moved a different token amount than it returned");
            }
        } catch {
            _flush();
            failCount[act]++;
        }
        _post();
    }

    function sell(uint256 curveSeed, uint256 actorSeed, uint256 refSeed, uint256 share) external {
        _sync();
        if (curves.length == 0) return;
        (BondingCurve c, bool ok) = _pickCurve(curveSeed, BondingCurve.Phase.Trading, false);
        if (!ok) return;
        LaunchToken t = c.token();
        address a = actors[actorSeed % actors.length];
        for (uint256 i; i < actors.length; ++i) {
            address cand = actors[(actorSeed % actors.length + i) % actors.length];
            if (t.balanceOf(cand) != 0) { a = cand; break; }
        }
        uint256 bal = t.balanceOf(a);
        if (bal == 0) return;
        uint256 amount = share % 5 == 0 ? bal : bal * bound(share, 1, 10_000) / 10_000;
        if (amount == 0) amount = 1;
        bool wasPending = c.phase() == BondingCurve.Phase.GraduationPending;
        uint256 fmBefore = address(fm).balance;
        uint256 balBefore = a.balance;
        _pendingRef = _refFrom(refSeed);
        vm.recordLogs();
        vm.prank(a);
        try c.sell(amount, 0, _pendingRef, type(uint256).max) returns (uint256 out) {
            _settle(fmBefore);
            okCount[A_SELL]++;
            if (wasPending) sellsWhilePending++;
            if (a.balance != balBefore + out) _violate("sell paid a different amount than it returned");
        } catch {
            _flush();
            failCount[A_SELL]++;
        }
        _post();
    }

    function retryGraduation(uint256 curveSeed) external {
        _sync();
        if (curves.length == 0) return;
        (BondingCurve c, bool ok) = _pickCurve(curveSeed, BondingCurve.Phase.GraduationPending, true);
        if (!ok) return;
        uint256 fmBefore = address(fm).balance;
        vm.recordLogs();
        try c.graduate() {
            _settle(fmBefore);
            okCount[A_RETRY]++;
        } catch {
            _flush();
            failCount[A_RETRY]++;
            if (!sabotaged) _violate("unsabotaged graduation retry failed");
        }
        _post();
    }

    function poolSwap(
        uint256 curveSeed,
        uint256 actorSeed,
        uint8 shape,
        uint256 amount,
        uint8 hookDataMode,
        uint256 limitSeed
    ) external {
        _sync();
        if (curves.length == 0) return;
        (BondingCurve c, bool ok) = _pickCurve(curveSeed, BondingCurve.Phase.Graduated, true);
        if (!ok) return;
        shape %= 4;
        bool buyToken = shape == 0 || shape == 2;
        LaunchToken t = c.token();
        address a = actors[actorSeed % actors.length];
        if (!buyToken) {
            for (uint256 i; i < actors.length; ++i) {
                address cand = actors[(actorSeed % actors.length + i) % actors.length];
                if (t.balanceOf(cand) != 0) { a = cand; break; }
            }
            if (t.balanceOf(a) == 0) return;
        }
        PoolKey memory key = gm.poolKey(address(t));
        bool zeroForOne = buyToken == (Currency.unwrap(key.currency0) == USDC);

        int256 specified;
        if (shape == 0) specified = -int256(bound(amount, 1, 3_000e6));
        else if (shape == 1) specified = -int256(bound(amount, 1, t.balanceOf(a)));
        else if (shape == 2) specified = int256(bound(amount, 1, 20_000_000e18));
        else specified = int256(bound(amount, 1, 300e6));

        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (limitSeed % 6 == 0) {
            (uint160 sp,,,) = pm.getSlot0(key.toId());
            uint160 d = sp / uint160(20 + limitSeed % 2_000);
            limit = zeroForOne ? sp - d : sp + d;
        }

        bytes memory hookData;
        hookDataMode %= 6;
        _pendingHookTrader = address(0);
        if (hookDataMode == 0) { hookData = abi.encode(a); _pendingHookTrader = a; }
        else if (hookDataMode == 1) {
            address other = claimants[limitSeed % claimants.length];
            hookData = abi.encode(other);
            _pendingHookTrader = other;
        } else if (hookDataMode == 2) hookData = "";
        else if (hookDataMode == 3) hookData = abi.encode(uint256(uint160(a)) | (uint256(1) << 200)); // dirty
        else if (hookDataMode == 4) hookData = abi.encode(a, a); // 64 bytes
        else hookData = abi.encodePacked(a); // 20 bytes

        uint256 fmBefore = address(fm).balance;
        vm.recordLogs();
        vm.prank(a);
        try swapRouter.swap(key, SwapParams(zeroForOne, specified, limit), PoolSwapTest.TestSettings(false, false), hookData) {
            _settle(fmBefore);
            okCount[A_SWAP_IN_BUY + shape]++;
        } catch {
            _flush();
            failCount[A_SWAP_IN_BUY + shape]++;
        }
        _post();
    }

    function addLiquidity(uint256 curveSeed, uint256 actorSeed, uint256 rangeSeed, uint256 liq) external {
        _sync();
        if (curves.length == 0) return;
        (BondingCurve c, bool ok) = _pickCurve(curveSeed, BondingCurve.Phase.Graduated, true);
        if (!ok) return;
        LaunchToken t = c.token();
        address a = actors[actorSeed % actors.length];
        for (uint256 i; i < actors.length; ++i) {
            address cand = actors[(actorSeed % actors.length + i) % actors.length];
            if (t.balanceOf(cand) != 0) { a = cand; break; }
        }
        PoolKey memory key = gm.poolKey(address(t));
        (int24 lo, int24 hi) = _range(key, rangeSeed);
        liq = bound(liq, 1e6, 5e17);
        bytes32 salt = bytes32(positions.length + 1);
        uint256 fmBefore = address(fm).balance;
        vm.prank(a);
        try liqRouter.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, int256(liq), salt), "") {
            uint256 idx;
            for (; idx < curves.length; ++idx) if (curves[idx] == c) break;
            positions.push(Pos(idx, lo, hi, salt, a, liq));
            okCount[A_ADD_LIQ]++;
        } catch {
            failCount[A_ADD_LIQ]++;
        }
        if (address(fm).balance != fmBefore) _violate("liquidity add moved FeeManager balance");
        _post();
    }

    function _range(PoolKey memory key, uint256 seed) internal view returns (int24 lo, int24 hi) {
        (, int24 tick,,) = pm.getSlot0(key.toId());
        int24 base = (tick / 200) * 200;
        if (tick < 0 && tick % 200 != 0) base -= 200;
        int24 a = int24(int256(seed % 41)) * 200;
        int24 b = int24(int256((seed >> 8) % 41) + 1) * 200;
        uint256 mode = (seed >> 16) % 4;
        if (mode == 0) { lo = base - a; hi = base + b; }
        else if (mode == 1) { lo = base + 200 + a; hi = lo + b; }
        else if (mode == 2) { hi = base - a; lo = hi - b; }
        else { lo = TickMath.minUsableTick(200); hi = TickMath.maxUsableTick(200); }
        int24 minT = TickMath.minUsableTick(200);
        int24 maxT = TickMath.maxUsableTick(200);
        if (lo < minT) lo = minT;
        if (hi > maxT) hi = maxT;
    }

    function removeLiquidity(uint256 posSeed, uint256 share) external {
        _sync();
        if (positions.length == 0) return;
        Pos storage p = positions[posSeed % positions.length];
        if (p.liq == 0) return;
        uint256 amt = share % 3 == 0 ? p.liq : p.liq * bound(share, 1, 10_000) / 10_000;
        if (amt == 0) amt = 1;
        PoolKey memory key = gm.poolKey(tokenOfCurve[address(curves[p.curveIdx])]);
        uint256 fmBefore = address(fm).balance;
        vm.prank(p.ownerActor);
        try liqRouter.modifyLiquidity(key, ModifyLiquidityParams(p.lo, p.hi, -int256(amt), p.salt), "") {
            p.liq -= amt;
            okCount[A_REMOVE_LIQ]++;
        } catch {
            failCount[A_REMOVE_LIQ]++;
        }
        if (address(fm).balance != fmBefore) _violate("liquidity removal moved FeeManager balance");
        _post();
    }

    function donateToPool(uint256 curveSeed, uint256 actorSeed, uint256 usdc6, uint256 tokens) external {
        _sync();
        if (curves.length == 0) return;
        (BondingCurve c, bool ok) = _pickCurve(curveSeed, BondingCurve.Phase.Graduated, true);
        if (!ok) return;
        LaunchToken t = c.token();
        address a = actors[actorSeed % actors.length];
        PoolKey memory key = gm.poolKey(address(t));
        usdc6 = bound(usdc6, 0, 100e6);
        uint256 bal = t.balanceOf(a);
        tokens = bal == 0 ? 0 : bound(tokens, 0, bal / 10);
        bool usdcIs0 = Currency.unwrap(key.currency0) == USDC;
        uint256 fmBefore = address(fm).balance;
        vm.prank(a);
        try donateRouter.donate(key, usdcIs0 ? usdc6 : tokens, usdcIs0 ? tokens : usdc6, "") {
            okCount[A_DONATE_POOL]++;
        } catch {
            failCount[A_DONATE_POOL]++;
        }
        if (address(fm).balance != fmBefore) _violate("pool donation moved FeeManager balance");
    }

    function bindReferrer(uint256 actorSeed, uint256 refSeed) external {
        address a = claimants[actorSeed % claimants.length];
        address r = _refFrom(refSeed);
        bool expectOk = r != address(0) && r != a && !ghostTraded[a] && ghostRef[a] == address(0);
        vm.prank(a);
        try fm.bindReferrer(r) {
            if (!expectOk) _violate("bindReferrer succeeded against the model");
            ghostRef[a] = r;
            okCount[A_BIND]++;
        } catch {
            if (expectOk) _violate("bindReferrer failed against the model");
            failCount[A_BIND]++;
        }
    }

    function claim(uint256 acctSeed, uint256 toSeed) external {
        address r = claimants[acctSeed % claimants.length];
        for (uint256 i; i < claimants.length; ++i) {
            address cand = claimants[(acctSeed % claimants.length + i) % claimants.length];
            if (ghostBal[cand] != 0) { r = cand; break; }
        }
        address to = toSeed % 2 == 0 ? r : claimants[toSeed % claimants.length];
        uint256 owed = ghostBal[r];
        uint256 before = to.balance;
        uint256 fmBefore = address(fm).balance;
        vm.prank(r);
        try fm.claim(to) returns (uint256 amount) {
            if (owed == 0) _violate("claim paid an account the model says is owed nothing");
            if (amount != owed) _violate("claim amount != modelled balance");
            if (to.balance != before + owed) _violate("claim recipient did not receive exactly owed");
            if (fmBefore - address(fm).balance != owed) _violate("claim drained a different amount");
            ghostBal[r] = 0;
            okCount[A_CLAIM]++;
        } catch {
            if (owed != 0) _violate("claim of a modelled balance reverted");
            failCount[A_CLAIM]++;
        }
    }

    /// @dev `ok` here means "reverted as it must".
    function claimHostile(uint256 acctSeed, uint256 toSeed) external {
        address r = claimants[acctSeed % claimants.length];
        for (uint256 i; i < claimants.length; ++i) {
            address cand = claimants[(acctSeed % claimants.length + i) % claimants.length];
            if (ghostBal[cand] != 0) { r = cand; break; }
        }
        if (ghostBal[r] == 0) return;
        address[5] memory dests =
            [address(0), address(fm), address(gm), address(hook), curves.length == 0 ? address(factory) : address(curves[0])];
        address to = dests[toSeed % 5];
        vm.prank(r);
        try fm.claim(to) {
            _violate("claim to a non-receiving destination succeeded");
            failCount[A_CLAIM_HOSTILE]++;
        } catch {
            okCount[A_CLAIM_HOSTILE]++;
        }
    }

    function claimPlatform(uint256 callerSeed) external {
        address treasury = factory.treasury();
        uint256 owed = ghostPlatform;
        uint256 before = treasury.balance;
        vm.prank(claimants[callerSeed % claimants.length]);
        try fm.claimPlatform() returns (uint256 amount) {
            if (amount != owed || owed == 0) _violate("claimPlatform amount != modelled platform bucket");
            if (treasury.balance != before + owed) _violate("treasury did not receive exactly the platform bucket");
            ghostPlatform = 0;
            okCount[A_CLAIM_PLATFORM]++;
        } catch {
            if (owed != 0) _violate("claimPlatform of a modelled balance reverted");
            failCount[A_CLAIM_PLATFORM]++;
        }
    }

    function sweep(uint256 callerSeed) external {
        vm.prank(claimants[callerSeed % claimants.length]);
        try fm.sweepUnaccounted() returns (uint256 amount) {
            if (amount != ghostUnswept || amount == 0) _violate("sweep captured something other than tracked donations");
            ghostPlatform += amount;
            ghostUnswept = 0;
            okCount[A_SWEEP]++;
        } catch {
            if (ghostUnswept != 0) _violate("sweep of tracked donations reverted");
            failCount[A_SWEEP]++;
        }
    }

    function _target(uint256 seed) internal view returns (address to, uint256 kind) {
        kind = seed % 3;
        if (kind == 2 && curves.length == 0) kind = 0;
        to = kind == 0 ? address(fm) : kind == 1 ? address(gm) : address(curves[(seed / 3) % curves.length]);
    }

    function _bookDonation(address to, uint256 kind, uint256 amount) internal {
        if (kind == 0) ghostUnswept += amount;
        else if (kind == 1) ghostGmDonated += amount;
        else ghostCurveDonated[to] += amount;
    }

    function forceNative(uint256 targetSeed, uint256 amount) external {
        (address to, uint256 kind) = _target(targetSeed);
        amount = amount % 4 == 0 ? 1 + amount % 1e12 : bound(amount, 1, 5_000e18);
        AdvBomb b = new AdvBomb{value: amount}();
        b.boom(payable(to));
        _bookDonation(to, kind, amount);
        okCount[A_FORCE_NATIVE]++;
    }

    function donateUsdc(uint256 targetSeed, uint256 actorSeed, uint256 amount6) external {
        (address to, uint256 kind) = _target(targetSeed);
        amount6 = bound(amount6, 1, 5_000e6);
        vm.prank(actors[actorSeed % actors.length]);
        try IERC20(USDC).transfer(to, amount6) {
            _bookDonation(to, kind, amount6 * 1e12);
            okCount[A_DONATE_USDC]++;
        } catch {
            failCount[A_DONATE_USDC]++;
        }
    }

    function donateToken(uint256 curveSeed, uint256 actorSeed, bool toGm, uint256 share) external {
        if (curves.length == 0) return;
        BondingCurve c = curves[curveSeed % curves.length];
        LaunchToken t = c.token();
        address a = actors[actorSeed % actors.length];
        for (uint256 i; i < actors.length; ++i) {
            address cand = actors[(actorSeed % actors.length + i) % actors.length];
            if (t.balanceOf(cand) != 0) { a = cand; break; }
        }
        uint256 amt = t.balanceOf(a) * bound(share, 1, 2_000) / 10_000;
        if (amt == 0) return;
        vm.prank(a);
        t.transfer(toGm ? address(gm) : address(c), amt);
        if (!toGm) ghostCurveTokenDonated[address(c)] += amt;
        okCount[A_DONATE_TOKEN]++;
    }

    function setConfig(uint256 idx) external {
        idx %= 4;
        LaunchConfig memory c = _cfg(idx);
        vm.prank(owner);
        try factory.setConfig(c) {
            cfgIdx = idx;
            okCount[A_SET_CONFIG]++;
        } catch {
            failCount[A_SET_CONFIG]++;
        }
    }

    function togglePause(bool on) external {
        vm.prank(guardian);
        if (on) {
            try factory.pause() { pausedGhost = true; okCount[A_PAUSE]++; } catch { failCount[A_PAUSE]++; }
        } else {
            try factory.unpause() { pausedGhost = false; okCount[A_PAUSE]++; } catch { failCount[A_PAUSE]++; }
        }
    }

    function sabotageGraduation(bool on) external {
        sabotaged = on;
        if (on) vm.mockCallRevert(address(gm), abi.encodeWithSelector(gm.graduate.selector), bytes("sabotage"));
        else vm.clearMockedCalls();
        okCount[A_SABOTAGE]++;
    }

    function advance(uint256 blocks, uint256 secs) external {
        vm.roll(vm.getBlockNumber() + bound(blocks, 1, 200));
        vm.warp(block.timestamp + bound(secs, 1, 3_600));
        okCount[A_ADVANCE]++;
    }
}
