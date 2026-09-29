// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScenarioBase} from "./ScenarioBase.sol";
import {Jsonl} from "./Jsonl.sol";
import {ForwardingRouter, DoubleSwapRouter, SplitRouter, SmartAccount} from "./Routers.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "../../script/utils/HookMiner.sol";
import {DefaultConfig} from "../../script/DefaultConfig.sol";
import {LaunchFactory} from "../../src/LaunchFactory.sol";
import {FeeManager} from "../../src/FeeManager.sol";
import {GraduationManager} from "../../src/GraduationManager.sol";
import {LiquidityLocker} from "../../src/LiquidityLocker.sol";
import {LaunchHook} from "../../src/LaunchHook.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchConfig, CreateParams} from "../../src/libraries/LaunchTypes.sol";
import {FeeManagerV2Mock} from "../utils/upgrade/FeeManagerV2Mock.sol";

contract ScenarioExportTest is ScenarioBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // role names only
    address deployer = makeAddr("deployer"); // deploys; proposer, canceller and executor (testnet-style governance)
    address guardianAddr = makeAddr("guardian");
    address treasuryAddr = makeAddr("treasury");
    address creator = makeAddr("creator");
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address recipient = makeAddr("recipient");
    address referrer = makeAddr("referrer");
    address lp = makeAddr("lp");

    uint256 constant DELAY = 60;
    uint256 constant FIRST = 900; // exported history starts before deployBlock (pool-registry backfill)
    uint256 constant DEPLOY = 1_000; // deployBlock
    uint256 constant T0 = 1_700_000_000;
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;
    bytes32 constant ERC1967_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes4 constant MODIFY = bytes4(keccak256("modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)"));
    string constant META = "sha256:0000000000000000000000000000000000000000000000000000000000000000";

    TimelockController timelock;
    address factory;
    address feeManager;
    address gm;
    address hook;
    address locker;
    address factoryImpl;
    address feeManagerImpl;
    address gmImpl;
    address feeManagerV2Impl;
    address gmFreshImpl;
    PoolSwapTest swapper;
    PoolModifyLiquidityTest liq;
    MockERC20 legacy;
    MockERC20 other8;
    PoolKey legacyKey;
    PoolKey otherKey;
    PoolKey foreignOursKey;
    address tokenBelow;
    address curveBelow;
    address tokenAbove;
    address curveAbove;
    bytes32[] ops;
    uint256 blk;
    bytes[] snapCalls;
    address[] snapTargets;

    function _next(uint256 d) internal {
        blk += d;
        _openBlock(blk, T0 + (blk - FIRST) / 2); // ≈ 0.5 s blocks
    }

    function test_exportRelease1Scenario() public {
        _deployV4(); // the chain's pre-existing contracts: PoolManager, Permit2, PositionManager, the USDC interface
        _begin("release1");
        address[9] memory funded = [deployer, guardianAddr, treasuryAddr, creator, buyer, seller, recipient, referrer, lp];
        for (uint256 i; i < funded.length; i++) {
            vm.deal(funded[i], 1e30);
        }
        blk = FIRST;
        _openBlock(blk, T0);
        _known(USDC, 0); // present from genesis: the witness for creation-block discovery (Task 6)
        _known(address(poolManager), FIRST); // replay-rpc serves no PoolManager code below this block
        _preDeployment();

        blk = DEPLOY - 1;
        _next(1); // deployBlock
        _deployRelease1();

        _next(1);
        (tokenBelow, curveBelow) = _launch(true); // step 1
        _next(1);
        (tokenAbove, curveAbove) = _launch(false); // step 2
        _snap();

        _next(1); // step 3: inside the snipe window (launched 2 blocks ago), with a referrer
        _call(buyer, curveBelow, 10e18, abi.encodeCall(BondingCurve.buy, (0, referrer, type(uint256).max)));

        _next(121); // step 4: after the 120-block window
        _call(seller, curveAbove, 100e18, abi.encodeCall(BondingCurve.buy, (0, address(0), type(uint256).max)));
        _call(seller, tokenAbove, 0, abi.encodeCall(IERC20.approve, (curveAbove, type(uint256).max)));
        uint256 half = IERC20(tokenAbove).balanceOf(seller) / 2;
        _call(seller, curveAbove, 0, abi.encodeCall(BondingCurve.sell, (half, 0, address(0), type(uint256).max)));

        _next(1); // step 5: sell-out buy of the below curve → graduation
        _call(seller, curveBelow, 30_000e18, abi.encodeCall(BondingCurve.buy, (0, address(0), type(uint256).max)));
        require(BondingCurve(curveBelow).phase() == BondingCurve.Phase.Graduated, "below curve graduated");

        _deferredGraduation(); // step 6
        _snap();

        _poolSwaps(); // steps 7–8
        _routedSwaps(); // steps 9–12
        _liquidity(); // step 13
        _snap();

        _foreignPool(); // step 14
        _next(1); // step 15: claims
        _call(creator, feeManager, 0, abi.encodeCall(FeeManager.claim, (creator)));
        _call(treasuryAddr, feeManager, 0, abi.encodeCall(FeeManager.claimPlatform, ()));
        _snap();

        _next(1); // step 16: pre-registered upgrade (listed in implementations.json)
        feeManagerV2Impl = _create(deployer, type(FeeManagerV2Mock).creationCode);
        _timelocked(feeManager, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (feeManagerV2Impl, bytes(""))), bytes32(uint256(16)));
        _next(1); // step 17: an implementation that is NOT listed → the indexer halts at the Upgraded log
        gmFreshImpl = _create(deployer, type(GraduationManager).creationCode);
        _timelocked(gm, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (gmFreshImpl, bytes(""))), bytes32(uint256(17)));
        _next(1); // step 18: rollback to the original FeeManager implementation
        _timelocked(feeManager, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (feeManagerImpl, bytes(""))), bytes32(uint256(18)));
        _snap();

        _next(1); // step 19: schedule a config change, then cancel it
        LaunchConfig memory c19 = DefaultConfig.get();
        c19.tradeFeeBps = 150;
        bytes memory d19 = abi.encodeCall(LaunchFactory.setConfig, (c19));
        bytes32 id19 = timelock.hashOperation(factory, 0, d19, bytes32(0), bytes32(uint256(19)));
        _call(deployer, address(timelock), 0, abi.encodeCall(TimelockController.schedule, (factory, 0, d19, bytes32(0), bytes32(uint256(19)), DELAY)));
        ops.push(id19);
        _next(1);
        _call(deployer, address(timelock), 0, abi.encodeCall(TimelockController.cancel, (id19)));

        _next(1); // step 20: a config change through the timelock
        LaunchConfig memory c20 = DefaultConfig.get();
        c20.tradeFeeBps = 200;
        c20.snipeBlocks = 240;
        _timelocked(factory, abi.encodeCall(LaunchFactory.setConfig, (c20)), bytes32(uint256(20)));
        _snap();

        // -------------------------------------------------------------- Task 57 coverage additions (appended after
        // step 20; the numbering, blocks and snapshots above are untouched)
        _foreignPoolOfOurToken(); // step 21
        _unknownEmitterSweep(); // step 22
        _snap();

        _finish();
        _writeRecords();
    }

    // ------------------------------------------------------------------ history before deployBlock

    function _preDeployment() internal {
        swapper = PoolSwapTest(_create(lp, abi.encodePacked(type(PoolSwapTest).creationCode, abi.encode(poolManager))));
        liq = PoolModifyLiquidityTest(_create(lp, abi.encodePacked(type(PoolModifyLiquidityTest).creationCode, abi.encode(poolManager))));
        legacy = MockERC20(_create(lp, abi.encodePacked(type(MockERC20).creationCode, abi.encode("Legacy", "LGC", uint8(18)))));
        _call(lp, address(legacy), 0, abi.encodeCall(MockERC20.mint, (lp, 1e30)));
        _call(lp, address(legacy), 0, abi.encodeCall(IERC20.approve, (address(liq), type(uint256).max)));
        _call(lp, address(legacy), 0, abi.encodeCall(IERC20.approve, (address(swapper), type(uint256).max)));
        legacyKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(legacy)), 3000, 60, IHooks(address(0)));
        _call(lp, address(poolManager), 0, abi.encodeCall(IPoolManager.initialize, (legacyKey, SQRT_1_1)));
        _next(1);
        _call(lp, address(liq), 10e18, abi.encodeWithSelector(MODIFY, legacyKey, ModifyLiquidityParams(-600, 600, 1e18, 0), bytes("")));
    }

    // ------------------------------------------------------------------ Deploy._deploy, transaction for transaction

    function _deployRelease1() internal {
        address[] memory ps = new address[](1);
        ps[0] = deployer;
        timelock = TimelockController(payable(_create(deployer,
            abi.encodePacked(type(TimelockController).creationCode, abi.encode(DELAY, ps, ps, address(0))))));
        feeManagerImpl = _create(deployer, type(FeeManager).creationCode);
        gmImpl = _create(deployer, type(GraduationManager).creationCode);
        factoryImpl = _create(deployer, type(LaunchFactory).creationCode);

        // Every creation below comes from this contract; CREATE2 bumps its nonce too (hook at n, locker n+1, proxies n+2..n+4).
        uint64 n = vm.getNonce(address(this));
        address pLocker = vm.computeCreateAddress(address(this), n + 1);
        address pFeeManager = vm.computeCreateAddress(address(this), n + 2);
        address pGm = vm.computeCreateAddress(address(this), n + 3);
        address pFactory = vm.computeCreateAddress(address(this), n + 4);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory hookInit =
            abi.encodePacked(type(LaunchHook).creationCode, abi.encode(address(poolManager), pFeeManager, pGm, USDC));
        (address pHook, bytes32 salt) = HookMiner.find(address(this), flags, hookInit);

        hook = _create2(deployer, salt, hookInit);
        locker = _create(deployer, abi.encodePacked(type(LiquidityLocker).creationCode, abi.encode(address(posm), pGm)));
        feeManager = _create(deployer, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(feeManagerImpl,
            abi.encodeCall(FeeManager.initialize, (pFactory, pHook, pGm, address(timelock))))));
        gm = _create(deployer, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(gmImpl,
            abi.encodeCall(GraduationManager.initialize, (pFactory, address(poolManager), address(posm), address(permit2), pHook,
                pLocker, pFeeManager, USDC, address(timelock))))));
        // the treasury seed decodes this creation transaction's input (initcode ++ constructor arguments)
        factory = _create(deployer, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(factoryImpl,
            abi.encodeCall(LaunchFactory.initialize, (address(timelock), guardianAddr, treasuryAddr, pFeeManager, pGm, DefaultConfig.get())))));
        require(hook == pHook && locker == pLocker && feeManager == pFeeManager && gm == pGm && factory == pFactory,
            "release 1.0 address prediction");
    }

    // ------------------------------------------------------------------ launches and curve trades

    function _launch(bool below) internal returns (address token, address curve) {
        bytes32 pinned = LaunchFactory(factory).configHash(); // read before building the call (no prank involved)
        for (uint256 i; i < 256; ++i) {
            CreateParams memory p = CreateParams(below ? "Below" : "Above", below ? "BLW" : "ABV", META, creator, referrer, bytes32(i + 1));
            (address predicted,) = LaunchFactory(factory).computeAddresses(deployer, p);
            if ((predicted < USDC) != below) continue;
            bytes memory ret = _call(deployer, factory, 51e18, abi.encodeCall(LaunchFactory.createToken, (p, pinned, 0)));
            return abi.decode(ret, (address, address)); // 1 USDC launch fee + a 50 USDC initial buy
        }
        revert("no salt for the requested ordering");
    }

    function _deferredGraduation() internal {
        _next(1); // sell-out buy while graduation reverts → GraduationDeferred
        // `vm.mockCallRevert` here corrupts `Vm.AccountAccess[].reverted` for the rest of the recorded call (see
        // `MirrorLog.liveLogs`'s doc), which would make ScenarioBase drop far more than the reverted graduation
        // frame; redirect to a real reverting contract instead so the state-diff recording stays accurate.
        address revertingGraduate = _revertShim(bytes("deferred"));
        vm.mockFunction(gm, revertingGraduate, abi.encodeWithSelector(GraduationManager.graduate.selector));
        _call(seller, curveAbove, 30_000e18, abi.encodeCall(BondingCurve.buy, (0, address(0), type(uint256).max)));
        require(BondingCurve(curveAbove).phase() == BondingCurve.Phase.GraduationPending, "pending");
        _next(1); // a sell while pending reopens Trading
        _call(seller, curveAbove, 0, abi.encodeCall(BondingCurve.sell, (1_000_000e18, 0, address(0), type(uint256).max)));
        _next(1); // sold out again, graduation still failing → deferred again
        _call(seller, curveAbove, 1_000e18, abi.encodeCall(BondingCurve.buy, (0, address(0), type(uint256).max)));
        // `vm.clearMockedCalls()` does not undo a `vm.mockFunction` redirect, so restore real behavior by
        // redirecting back to the real implementation (exactly what the proxy's own delegatecall would run).
        vm.mockFunction(gm, gmImpl, abi.encodeWithSelector(GraduationManager.graduate.selector));
        _next(1); // the permissionless retry
        _call(recipient, curveAbove, 0, abi.encodeCall(BondingCurve.graduate, ()));
        require(BondingCurve(curveAbove).phase() == BondingCurve.Phase.Graduated, "above curve graduated");
    }

    // ------------------------------------------------------------------ pool trades

    function _key(address token) internal view returns (PoolKey memory) {
        return GraduationManager(gm).poolKey(token);
    }

    function _params(PoolKey memory key, bool usdcIn, int256 amountSpecified) internal pure returns (SwapParams memory) {
        bool zeroForOne = usdcIn == (Currency.unwrap(key.currency0) == USDC);
        return SwapParams(zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _swap(address from, PoolKey memory key, SwapParams memory p, bytes memory hookData) internal {
        _call(from, address(swapper), 0, abi.encodeCall(PoolSwapTest.swap, (key, p, PoolSwapTest.TestSettings(false, false), hookData)));
    }

    function _poolSwaps() internal {
        _next(1); // step 7: exact input on both pools (a buy charges in beforeSwap, a sell in afterSwap)
        _call(seller, USDC, 0, abi.encodeCall(IERC20.approve, (address(swapper), type(uint256).max)));
        _call(seller, tokenBelow, 0, abi.encodeCall(IERC20.approve, (address(swapper), type(uint256).max)));
        _call(seller, tokenAbove, 0, abi.encodeCall(IERC20.approve, (address(swapper), type(uint256).max)));
        address[2] memory toks = [tokenBelow, tokenAbove];
        for (uint256 i; i < 2; i++) {
            PoolKey memory key = _key(toks[i]);
            _swap(seller, key, _params(key, true, -100e6), abi.encode(seller));
            _swap(seller, key, _params(key, false, -1_000_000e18), "");
        }
        _next(1); // step 8: exact output on both pools (the grossed-up fee formulas)
        for (uint256 i; i < 2; i++) {
            PoolKey memory key = _key(toks[i]);
            _swap(seller, key, _params(key, true, 1_000_000e18), abi.encode(seller));
            _swap(seller, key, _params(key, false, 50e6), "");
        }
    }

    function _routedSwaps() internal {
        PoolKey memory key = _key(tokenBelow);
        _next(1); // step 9: two swaps of one pool in one transaction
        DoubleSwapRouter dbl = DoubleSwapRouter(_create(lp, abi.encodePacked(type(DoubleSwapRouter).creationCode, abi.encode(swapper))));
        _call(seller, USDC, 0, abi.encodeCall(IERC20.approve, (address(dbl), type(uint256).max)));
        _call(seller, address(dbl), 0, abi.encodeCall(DoubleSwapRouter.swapTwice,
            (key, _params(key, true, -20e6), _params(key, true, -30e6), abi.encode(seller))));
        _next(1); // step 10: a forwarding hop to a different recipient
        ForwardingRouter fwd = ForwardingRouter(_create(lp, abi.encodePacked(type(ForwardingRouter).creationCode, abi.encode(swapper))));
        _call(seller, USDC, 0, abi.encodeCall(IERC20.approve, (address(fwd), type(uint256).max)));
        _call(seller, address(fwd), 0, abi.encodeCall(ForwardingRouter.swapAndForward, (key, _params(key, true, -50e6), bytes(""), recipient)));
        _next(1); // step 11: a smart account trades for its owner
        SmartAccount acct = SmartAccount(payable(_create(seller, abi.encodePacked(type(SmartAccount).creationCode, abi.encode(seller)))));
        _call(seller, USDC, 0, abi.encodeCall(IERC20.transfer, (address(acct), 200e6)));
        _call(seller, address(acct), 0, abi.encodeCall(SmartAccount.execute,
            (USDC, 0, abi.encodeCall(IERC20.approve, (address(swapper), type(uint256).max)))));
        _call(seller, address(acct), 0, abi.encodeCall(SmartAccount.execute, (address(swapper), 0, abi.encodeCall(PoolSwapTest.swap,
            (key, _params(key, true, -60e6), PoolSwapTest.TestSettings(false, false), abi.encode(address(acct)))))));
        _next(1); // step 12: one output split between two recipients
        SplitRouter split = SplitRouter(_create(lp, abi.encodePacked(type(SplitRouter).creationCode, abi.encode(swapper))));
        _call(seller, USDC, 0, abi.encodeCall(IERC20.approve, (address(split), type(uint256).max)));
        _call(seller, address(split), 0, abi.encodeCall(SplitRouter.swapAndSplit,
            (key, _params(key, true, -40e6), bytes(""), buyer, recipient)));
    }

    function _liquidity() internal {
        _next(1); // step 13: third-party liquidity on our pool, around the current tick; more liquidity on the Legacy pool
        PoolKey memory key = _key(tokenBelow);
        _call(seller, tokenBelow, 0, abi.encodeCall(IERC20.transfer, (lp, 10_000_000e18)));
        _call(lp, USDC, 0, abi.encodeCall(IERC20.approve, (address(liq), type(uint256).max)));
        _call(lp, tokenBelow, 0, abi.encodeCall(IERC20.approve, (address(liq), type(uint256).max)));
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        int24 base = tick / key.tickSpacing * key.tickSpacing;
        _call(lp, address(liq), 0, abi.encodeWithSelector(MODIFY, key,
            ModifyLiquidityParams(base - 5 * key.tickSpacing, base + 5 * key.tickSpacing, 1e15, 0), bytes("")));
        // the backfilled pool has no Swap since deployBlock: this delta must not be applied until its state read
        _call(lp, address(liq), 10e18, abi.encodeWithSelector(MODIFY, legacyKey, ModifyLiquidityParams(-1200, 1200, 5e17, 0), bytes("")));
    }

    function _foreignPool() internal {
        _next(1); // step 14: an 8-decimal foreign currency paired with native USDC, no hook
        other8 = MockERC20(_create(lp, abi.encodePacked(type(MockERC20).creationCode, abi.encode("Other", "OTH", uint8(8)))));
        _call(lp, address(other8), 0, abi.encodeCall(MockERC20.mint, (lp, 1e24)));
        _call(lp, address(other8), 0, abi.encodeCall(IERC20.approve, (address(liq), type(uint256).max)));
        _call(lp, address(other8), 0, abi.encodeCall(IERC20.approve, (address(swapper), type(uint256).max)));
        otherKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(other8)), 3000, 60, IHooks(address(0)));
        _call(lp, address(poolManager), 0, abi.encodeCall(IPoolManager.initialize, (otherKey, SQRT_1_1)));
        _call(lp, address(liq), 10e18, abi.encodeWithSelector(MODIFY, otherKey, ModifyLiquidityParams(-600, 600, 1e18, 0), bytes("")));
        _next(1);
        _call(lp, address(swapper), 1e16, abi.encodeCall(PoolSwapTest.swap, (otherKey,
            SwapParams(true, -1e16, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), bytes(""))));
        _call(lp, address(swapper), 0, abi.encodeCall(PoolSwapTest.swap, (otherKey,
            SwapParams(false, -1e6, TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), bytes(""))));
        // the backfilled pool's first Swap since deployBlock (an exact value, overwriting the state read)
        _call(lp, address(swapper), 1e16, abi.encodeCall(PoolSwapTest.swap, (legacyKey,
            SwapParams(true, -1e16, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), bytes(""))));
    }

    // ------------------------------------------------------------------ Task 57 coverage additions (§3.5, §3.2)

    /// Step 21: a v4 pool pairing our own `tokenBelow` with USDC, initialized with NO hook (`IHooks(address(0))`,
    /// never `hook`). By §3.2/§3.5's `Hooks.LaunchHook` test this pool is foreign (`launched_here = false`) exactly
    /// like `legacyKey`/`otherKey` — a pool's "ours-ness" comes only from its hook, never from its currency. §3.5's
    /// last "Pool trade attribution" rule is the point of this step: "a token of ours traded in a foreign pool is
    /// not a trade of that token. It appears only under the pool listing." Nothing before this step ever puts one of
    /// our own launched tokens in a pool without `hook`, so that exclusion has had zero scenario coverage (Task 59).
    function _foreignPoolOfOurToken() internal {
        _next(1); // step 21
        foreignOursKey = PoolKey(Currency.wrap(tokenBelow), Currency.wrap(USDC), 3000, 60, IHooks(address(0)));
        _call(lp, address(poolManager), 0, abi.encodeCall(IPoolManager.initialize, (foreignOursKey, SQRT_1_1)));
        _call(lp, tokenBelow, 0, abi.encodeCall(IERC20.approve, (address(liq), type(uint256).max)));
        _call(lp, USDC, 0, abi.encodeCall(IERC20.approve, (address(liq), type(uint256).max)));
        _call(lp, address(liq), 0, abi.encodeWithSelector(MODIFY, foreignOursKey, ModifyLiquidityParams(-600, 600, 1e18, 0), bytes("")));
        _next(1);
        _call(lp, USDC, 0, abi.encodeCall(IERC20.approve, (address(swapper), type(uint256).max)));
        _call(lp, address(swapper), 0, abi.encodeCall(PoolSwapTest.swap,
            (foreignOursKey, _params(foreignOursKey, true, -10e6), PoolSwapTest.TestSettings(false, false), bytes(""))));
    }

    /// Step 22: `FeeManager.accruePlatform` has no caller check (§3.2 NatSpec quote) and is called directly by `lp`
    /// — not the factory, not a curve, not the GraduationManager, so the indexer does not recognise it as any
    /// attributable role. §3.2: "any other emitter is recorded as kind `sweep` (unattributed platform credit) with
    /// the emitted token, never a halt". This is a real, permissionless call (the same NatSpec paragraph that
    /// documents `sweepUnaccounted()`'s `token = 0` sweep also documents this one), and nothing before this step
    /// ever calls `accruePlatform` from an address the indexer cannot attribute.
    function _unknownEmitterSweep() internal {
        _next(1); // step 22
        // 2e18, not 1e18: the launch fee (step 1) already accrues exactly 1e18 platform credit against tokenBelow,
        // so a distinct amount keeps this row unambiguous to find and assert on.
        _call(lp, feeManager, 2e18, abi.encodeCall(FeeManager.accruePlatform, (tokenBelow)));
    }

    // ------------------------------------------------------------------ governance

    function _timelocked(address target, bytes memory data, bytes32 salt) internal {
        bytes32 id = timelock.hashOperation(target, 0, data, bytes32(0), salt);
        _call(deployer, address(timelock), 0, abi.encodeCall(TimelockController.schedule, (target, 0, data, bytes32(0), salt, DELAY)));
        ops.push(id);
        _next(121); // 60 s at 0.5 s blocks: the real wait, never a warp inside a block
        _call(deployer, address(timelock), 0, abi.encodeCall(TimelockController.execute, (target, 0, data, bytes32(0), salt)));
    }

    // ------------------------------------------------------------------ snapshots and records

    function _q(address to, bytes memory data) internal {
        snapTargets.push(to);
        snapCalls.push(data);
    }

    /// Every read the reconcile plan (Tasks 26, 38) makes, at this block, for every entity and every seen account.
    function _snap() internal {
        delete snapCalls;
        delete snapTargets;
        address[2] memory toks = [tokenBelow, tokenAbove];
        address[2] memory crvs = [curveBelow, curveAbove];
        for (uint256 i; i < 2; i++) {
            if (toks[i] == address(0)) continue;
            _q(crvs[i], abi.encodeWithSignature("realUsdc()"));
            _q(crvs[i], abi.encodeWithSignature("sold()"));
            _q(crvs[i], abi.encodeWithSignature("phase()"));
            _q(toks[i], abi.encodeWithSignature("totalSupply()"));
            for (uint256 j; j < accounts.length; j++) {
                _q(toks[i], abi.encodeCall(IERC20.balanceOf, (accounts[j])));
            }
            _q(toks[i], abi.encodeCall(IERC20.balanceOf, (crvs[i])));
            _q(toks[i], abi.encodeCall(IERC20.balanceOf, (address(poolManager))));
            _q(toks[i], abi.encodeCall(IERC20.balanceOf, (locker)));
        }
        for (uint256 j; j < accounts.length; j++) {
            _q(feeManager, abi.encodeCall(FeeManager.balances, (accounts[j])));
            _q(feeManager, abi.encodeCall(FeeManager.referrerOf, (accounts[j])));
        }
        _q(feeManager, abi.encodeCall(FeeManager.platformBalance, ()));
        _q(feeManager, abi.encodeCall(FeeManager.totalOwed, ()));
        _q(factory, abi.encodeCall(LaunchFactory.configHash, ()));
        _q(factory, abi.encodeCall(LaunchFactory.treasury, ()));
        _q(factory, abi.encodeCall(LaunchFactory.guardian, ()));
        _q(factory, abi.encodeWithSignature("paused()"));
        _q(address(timelock), abi.encodeCall(TimelockController.getMinDelay, ()));
        for (uint256 j; j < ops.length; j++) {
            _q(address(timelock), abi.encodeCall(TimelockController.getOperationState, (ops[j])));
        }
        // foreignOursKey (step 21) is zero-valued at every snapshot before it exists; guarding on its currency0
        // keeps calls-<block>.jsonl byte-for-byte unchanged for every snapshot at or before step 20.
        bool haveForeignOurs = Currency.unwrap(foreignOursKey.currency0) != address(0);
        PoolKey[5] memory keys;
        uint256 nk;
        if (tokenBelow != address(0)) keys[nk++] = _key(tokenBelow);
        if (tokenAbove != address(0)) keys[nk++] = _key(tokenAbove);
        keys[nk++] = legacyKey;
        if (address(other8) != address(0)) keys[nk++] = otherKey;
        if (haveForeignOurs) keys[nk++] = foreignOursKey;
        for (uint256 j; j < nk; j++) {
            bytes32 s0 = keccak256(abi.encode(PoolId.unwrap(keys[j].toId()), uint256(6))); // StateLibrary.POOLS_SLOT
            _q(address(poolManager), abi.encodeWithSignature("extsload(bytes32)", s0));
            _q(address(poolManager), abi.encodeWithSignature("extsload(bytes32)", bytes32(uint256(s0) + 3)));
        }
        // tokenBelow is one of ours, but it is ALSO the non-USDC currency of the step-21 foreign pool: JobsFor
        // (backend/internal/ingest/jobs.go) enqueues a currency job for it exactly as it would for any other
        // foreign pool's non-USDC leg, so the screener reads its decimals()/name()/symbol() same as legacy/other8.
        address[3] memory foreignTokens = [address(legacy), address(other8), haveForeignOurs ? tokenBelow : address(0)];
        for (uint256 j; j < 3; j++) {
            if (foreignTokens[j] == address(0)) continue;
            _q(foreignTokens[j], abi.encodeWithSignature("decimals()"));
            _q(foreignTokens[j], abi.encodeWithSignature("name()"));
            _q(foreignTokens[j], abi.encodeWithSignature("symbol()"));
        }
        address[] memory slotAddrs = new address[](3);
        bytes32[] memory slots = new bytes32[](3);
        (slotAddrs[0], slotAddrs[1], slotAddrs[2]) = (factory, feeManager, gm);
        (slots[0], slots[1], slots[2]) = (ERC1967_SLOT, ERC1967_SLOT, ERC1967_SLOT);
        _snapshot(snapCalls, snapTargets, slotAddrs, slots);
    }

    function _entry(address proxy, address impl, string memory set) internal view returns (string memory) {
        return string.concat('{"proxy":', Jsonl.a(proxy), ',"implementation":', Jsonl.a(impl), ',"codehash":',
            Jsonl.h32(keccak256(impl.code)), ',"decoderSet":', Jsonl.q(set), "}");
    }

    function _writeRecords() internal {
        string memory k = "deployment";
        vm.serializeString(k, "version", "1.0.0");
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "deployBlock", DEPLOY);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "factory", factory);
        vm.serializeAddress(k, "feeManager", feeManager);
        vm.serializeAddress(k, "graduationManager", gm);
        vm.serializeAddress(k, "liquidityLocker", locker);
        vm.serializeAddress(k, "launchHook", hook);
        // the implementations active at the end, like the real record after its upgrade rehearsal
        vm.serializeAddress(k, "factoryImplementation", factoryImpl);
        vm.serializeAddress(k, "feeManagerImplementation", feeManagerImpl);
        vm.serializeAddress(k, "graduationManagerImplementation", gmFreshImpl);
        vm.serializeAddress(k, "timelock", address(timelock));
        vm.serializeUint(k, "timelockDelay", DELAY);
        vm.serializeAddress(k, "proposer", deployer);
        vm.serializeAddress(k, "canceller", deployer);
        vm.serializeAddress(k, "executor", deployer);
        vm.serializeAddress(k, "guardian", guardianAddr);
        vm.serializeAddress(k, "treasury", treasuryAddr);
        vm.serializeBytes32(k, "configHash", LaunchFactory(factory).configHash());
        vm.serializeAddress(k, "poolManager", address(poolManager));
        vm.serializeAddress(k, "positionManager", address(posm));
        vm.serializeAddress(k, "permit2", address(permit2));
        string memory json = vm.serializeAddress(k, "usdc", USDC);
        vm.writeJson(json, string.concat(dir, "deployment.json"));
        vm.writeFile(string.concat(dir, "implementations.json"), string.concat('{"entries":[',
            _entry(factory, factoryImpl, "factory-r1"), ",", _entry(feeManager, feeManagerImpl, "feemanager-r1"), ",",
            _entry(gm, gmImpl, "graduation-r1"), ",", _entry(feeManager, feeManagerV2Impl, "feemanager-r1"), "]}"));
    }
}
