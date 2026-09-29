// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {Deployments} from "./utils/Deployments.sol";
import {DefaultConfig} from "./DefaultConfig.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {FeeManager} from "../src/FeeManager.sol";
import {GraduationManager} from "../src/GraduationManager.sol";
import {LiquidityLocker} from "../src/LiquidityLocker.sol";
import {LaunchHook} from "../src/LaunchHook.sol";

/// @notice H3: the two wiring getters a PositionManager exposes — `poolManager()` from v4-periphery's
///         `ImmutableState` and `permit2()` from its `Permit2Forwarder`. Declared locally because
///         `IPositionManager` inherits the first but not the second (`IPermit2Forwarder` declares only
///         `permit`).
interface IPositionManagerWiring {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

/// @notice Deploys the upgradeable system (upgradeability design, section 5). Transaction order (and therefore
///         nonce order) is fixed, one EOA, every CREATE address predicted up front and asserted afterwards:
///           n+0  TimelockController(delay, [proposer], [executor], admin = address(0))
///           n+1  FeeManager implementation
///           n+2  GraduationManager implementation
///           n+3  LaunchFactory implementation
///           n+4  LaunchHook (CREATE2 through the deterministic deployer; salt mined over the PROXY addresses)
///           n+5  LiquidityLocker (points at the GraduationManager proxy)
///           n+6  FeeManager proxy         ┐
///           n+7  GraduationManager proxy  ├ each an ERC1967Proxy initialised in its constructor, owner = timelock
///           n+8  LaunchFactory proxy      ┘
/// @dev Governance inputs (env): PROPOSER, EXECUTOR, GUARDIAN, TREASURY, TIMELOCK_DELAY. On the testnet (5042002)
///      each address defaults to the deployer and the delay to 60 s, so the real schedule → wait → execute path is
///      exercised. On any other chain all five are mandatory, the delay must be at least 48 h, and any of
///      proposer / executor / guardian / treasury being the deployer is refused. On every chain the delay is at most
///      30 days. Only a `--broadcast` run writes anything, and then only `<chainId>.pending.json` (see Deployments).
contract Deploy is Script {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 internal constant TESTNET_DEFAULT_DELAY = 60;
    uint256 internal constant MIN_PRODUCTION_DELAY = 172_800; // 48 h
    uint256 internal constant MAX_DELAY = 2_592_000; // 30 days

    struct Governance {
        address proposer;
        address executor;
        address guardian;
        address treasury;
        uint256 delay;
    }

    struct Externals {
        address poolManager;
        address positionManager;
        address permit2;
    }

    struct Deployed {
        address timelock;
        address feeManagerImpl;
        address gmImpl;
        address factoryImpl;
        address hook;
        address locker;
        address feeManager;
        address gm;
        address factory;
    }

    function run() external {
        // H3: the single most expensive mistake this script could make is deploying to the wrong chain, so it
        // is the first thing checked, before a key is even read. There is no default: the caller must state
        // which chain they mean (deploy.sh derives it only when the RPC already says testnet).
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "chain id does not match EXPECTED_CHAIN_ID");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        Externals memory ext = Externals({
            poolManager: vm.envAddress("POOL_MANAGER"),
            positionManager: vm.envAddress("POSITION_MANAGER"),
            permit2: vm.envAddress("PERMIT2")
        });

        // I1: whether this run broadcasts comes from forge itself (`--broadcast`), never from env; DRY_RUN=true
        // together with `--broadcast` is refused as contradictory. A pending record left by an earlier run must be
        // dealt with first.
        bool live = Deployments.broadcasting();
        Deployments.requireNoPending();
        Governance memory g = _governance(deployer);

        // Deployer address/balance are logged and gated here (never via a `cast` subprocess call in the
        // wrapper) so the private key is never expanded into any process's argv, where `ps` could see it.
        console2.log("deployer           ", deployer);
        console2.log("deployer balance   ", deployer.balance);
        console2.log("proposer           ", g.proposer);
        console2.log("executor           ", g.executor);
        console2.log("guardian           ", g.guardian);
        console2.log("treasury           ", g.treasury);
        console2.log("timelock delay (s) ", g.delay);

        // A broadcasting run refuses below 1 USDC. A simulation (`forge script` without `--broadcast`) only warns,
        // so the full path can be exercised with an unfunded throwaway key; it sends nothing and writes nothing.
        if (deployer.balance < 1e18 && !live) {
            console2.log(
                "WARNING: deployer balance is below 1 USDC (1e18 wei); continuing because this is a simulation"
            );
        }
        require(deployer.balance >= 1e18 || !live, "deployer balance below 1 USDC");

        _checkExternals(ext);

        Deployed memory d = _deploy(pk, deployer, g, ext);

        string memory json = _serialize(deployer, g, ext, d);

        // H2 / I2: this script never touches the tracked record. forge runs the whole script BEFORE it sends a
        // single transaction, so anything written here describes a deployment that has not happened yet. A
        // broadcasting run therefore writes only `<chainId>.pending.json`; deploy.sh promotes it (archiving the
        // previous record and operation log first) only after the broadcast succeeded and Verify passed against
        // it. A simulation writes nothing at all.
        _log(d);
        if (!live) {
            console2.log("SIMULATION (no --broadcast): writing nothing");
            return;
        }
        vm.writeJson(json, Deployments.pendingRecordPath());
        console2.log("wrote pending record", Deployments.pendingRecordPath());
    }

    /// @dev Resolves and validates the governance inputs. Off the testnet nothing defaults, the delay floor is
    ///      48 h, and the deployer may hold none of the governance positions. These refusals apply to every run
    ///      (simulation or broadcast), so neither deploy.sh nor a direct `forge script` run can get past them.
    function _governance(address deployer) internal view returns (Governance memory g) {
        if (Deployments.isTestnet()) {
            g.proposer = vm.envOr("PROPOSER", deployer);
            g.executor = vm.envOr("EXECUTOR", deployer);
            g.guardian = vm.envOr("GUARDIAN", deployer);
            g.treasury = vm.envOr("TREASURY", deployer);
            g.delay = vm.envOr("TIMELOCK_DELAY", TESTNET_DEFAULT_DELAY);
        } else {
            g.proposer = vm.envAddress("PROPOSER");
            g.executor = vm.envAddress("EXECUTOR");
            g.guardian = vm.envAddress("GUARDIAN");
            g.treasury = vm.envAddress("TREASURY");
            g.delay = vm.envUint("TIMELOCK_DELAY");
            require(g.delay >= MIN_PRODUCTION_DELAY, "TIMELOCK_DELAY must be >= 172800 (48 h) off the testnet");
            require(g.proposer != deployer, "PROPOSER must not be the deployer off the testnet");
            require(g.executor != deployer, "EXECUTOR must not be the deployer off the testnet");
            require(g.guardian != deployer, "GUARDIAN must not be the deployer off the testnet");
            require(g.treasury != deployer, "TREASURY must not be the deployer off the testnet");
        }
        // A zero proposer would leave nobody able to schedule anything, ever (the timelock administers itself);
        // a zero executor is OpenZeppelin's "anyone may execute", which this system does not intend.
        require(g.proposer != address(0), "PROPOSER is the zero address");
        require(g.executor != address(0), "EXECUTOR is the zero address");
        require(g.treasury != address(0), "TREASURY is the zero address");
        require(g.delay != 0, "TIMELOCK_DELAY is zero");
        // M7: an absurd delay (a typo in the unit, say) would freeze every fix for that long — including the fix
        // for the delay itself, which also has to wait it out.
        require(g.delay <= MAX_DELAY, "TIMELOCK_DELAY must be <= 2592000 (30 days)");
        // GUARDIAN may be the zero address: that means "no guardian" (only the timelock can pause).
    }

    function _checkExternals(Externals memory ext) internal view {
        require(ext.poolManager.code.length != 0, "POOL_MANAGER has no code");
        require(ext.positionManager.code.length != 0, "POSITION_MANAGER has no code");
        require(ext.permit2.code.length != 0, "PERMIT2 has no code");
        require(CREATE2_DEPLOYER.code.length != 0, "CREATE2 deployer has no code");
        // H3: the USDC ERC-20 interface is a hard-coded constant, so on a chain that does not have it the
        // whole system would deploy happily and then fail at the first graduation. Refuse up front.
        require(USDC.code.length != 0, "USDC interface has no code on this chain");
        // H3: POSITION_MANAGER must belong to the SAME PoolManager and Permit2 this deployment is wiring in.
        // Mismatched here and every graduation reverts deep inside Uniswap, after the launch has already sold
        // out.
        require(
            IPositionManagerWiring(ext.positionManager).poolManager() == ext.poolManager,
            "POSITION_MANAGER.poolManager() != POOL_MANAGER"
        );
        require(
            IPositionManagerWiring(ext.positionManager).permit2() == ext.permit2,
            "POSITION_MANAGER.permit2() != PERMIT2"
        );
    }

    function _deploy(uint256 pk, address deployer, Governance memory g, Externals memory ext)
        internal
        returns (Deployed memory d)
    {
        // RUNBOOK (see deploy.sh): these predictions are only valid from a clean nonce — never `--resume`.
        uint64 nonce = vm.getNonce(deployer);
        Deployed memory p; // predicted
        p.timelock = vm.computeCreateAddress(deployer, nonce);
        p.feeManagerImpl = vm.computeCreateAddress(deployer, nonce + 1);
        p.gmImpl = vm.computeCreateAddress(deployer, nonce + 2);
        p.factoryImpl = vm.computeCreateAddress(deployer, nonce + 3);
        // nonce + 4 is the hook's CREATE2 call through the deterministic deployer: it consumes a nonce too.
        p.locker = vm.computeCreateAddress(deployer, nonce + 5);
        p.feeManager = vm.computeCreateAddress(deployer, nonce + 6);
        p.gm = vm.computeCreateAddress(deployer, nonce + 7);
        p.factory = vm.computeCreateAddress(deployer, nonce + 8);

        // Must equal `LaunchHook.FLAGS` exactly. Computed inline rather than read from `LaunchHook.FLAGS()`
        // because that constant cannot be read through a contract that has not been deployed yet; verified
        // to match post-deploy below instead.
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes32 salt;
        (p.hook, salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            abi.encodePacked(type(LaunchHook).creationCode, abi.encode(ext.poolManager, p.feeManager, p.gm, USDC))
        );

        address[] memory proposers = new address[](1);
        proposers[0] = g.proposer;
        address[] memory executors = new address[](1);
        executors[0] = g.executor;

        vm.startBroadcast(pk);
        d.timelock = address(new TimelockController(g.delay, proposers, executors, address(0)));
        d.feeManagerImpl = address(new FeeManager());
        d.gmImpl = address(new GraduationManager());
        d.factoryImpl = address(new LaunchFactory());
        d.hook = address(new LaunchHook{salt: salt}(ext.poolManager, p.feeManager, p.gm, USDC));
        d.locker = address(new LiquidityLocker(ext.positionManager, p.gm));
        d.feeManager = address(
            new ERC1967Proxy(
                d.feeManagerImpl, abi.encodeCall(FeeManager.initialize, (p.factory, p.hook, p.gm, d.timelock))
            )
        );
        d.gm = address(
            new ERC1967Proxy(
                d.gmImpl,
                abi.encodeCall(
                    GraduationManager.initialize,
                    (
                        p.factory,
                        ext.poolManager,
                        ext.positionManager,
                        ext.permit2,
                        p.hook,
                        p.locker,
                        p.feeManager,
                        USDC,
                        d.timelock
                    )
                )
            )
        );
        d.factory = address(
            new ERC1967Proxy(
                d.factoryImpl,
                abi.encodeCall(
                    LaunchFactory.initialize,
                    (d.timelock, g.guardian, g.treasury, p.feeManager, p.gm, DefaultConfig.get())
                )
            )
        );
        vm.stopBroadcast();

        require(d.timelock == p.timelock, "timelock address mismatch");
        require(d.feeManagerImpl == p.feeManagerImpl, "feeManager implementation address mismatch");
        require(d.gmImpl == p.gmImpl, "graduationManager implementation address mismatch");
        require(d.factoryImpl == p.factoryImpl, "factory implementation address mismatch");
        require(d.hook == p.hook, "hook address mismatch");
        require(d.locker == p.locker, "locker address mismatch");
        require(d.feeManager == p.feeManager, "feeManager address mismatch");
        require(d.gm == p.gm, "graduationManager address mismatch");
        require(d.factory == p.factory, "factory address mismatch");
        require(LaunchHook(d.hook).FLAGS() == flags, "hook flags drifted");
        // Cheap in-simulation sanity; Verify.s.sol re-reads everything from the chain after the broadcast.
        require(LaunchFactory(d.factory).owner() == d.timelock, "factory owner is not the timelock");
        require(FeeManager(d.feeManager).owner() == d.timelock, "feeManager owner is not the timelock");
        require(GraduationManager(d.gm).owner() == d.timelock, "graduationManager owner is not the timelock");
    }

    function _serialize(address deployer, Governance memory g, Externals memory ext, Deployed memory d)
        internal
        returns (string memory json)
    {
        string memory k = "deployment";
        // Release of the launch system this record describes (the first upgradeable release is 1.0.0).
        vm.serializeString(k, "version", "1.0.0");
        vm.serializeUint(k, "chainId", block.chainid);
        // Recorded as a safe LOWER bound for indexer backfill (and Verify's role-log scan): this is the
        // simulation-time block, and the real broadcast lands at or after it, never before.
        vm.serializeUint(k, "deployBlock", block.number);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "factory", d.factory);
        vm.serializeAddress(k, "feeManager", d.feeManager);
        vm.serializeAddress(k, "graduationManager", d.gm);
        vm.serializeAddress(k, "liquidityLocker", d.locker);
        vm.serializeAddress(k, "launchHook", d.hook);
        vm.serializeAddress(k, "factoryImplementation", d.factoryImpl);
        vm.serializeAddress(k, "feeManagerImplementation", d.feeManagerImpl);
        vm.serializeAddress(k, "graduationManagerImplementation", d.gmImpl);
        vm.serializeAddress(k, "timelock", d.timelock);
        vm.serializeUint(k, "timelockDelay", g.delay);
        vm.serializeAddress(k, "proposer", g.proposer);
        // TimelockController gives every proposer the canceller role too; recorded separately so a later
        // timelocked role change can be followed exactly (timelock.sh MODE=sync).
        vm.serializeAddress(k, "canceller", g.proposer);
        vm.serializeAddress(k, "executor", g.executor);
        vm.serializeAddress(k, "guardian", g.guardian);
        vm.serializeAddress(k, "treasury", g.treasury);
        // Kept equal to the chain by `timelock.sh` (MODE=sync) after any executed config change.
        vm.serializeBytes32(k, "configHash", keccak256(abi.encode(DefaultConfig.get())));
        vm.serializeAddress(k, "poolManager", ext.poolManager);
        vm.serializeAddress(k, "positionManager", ext.positionManager);
        vm.serializeAddress(k, "permit2", ext.permit2);
        json = vm.serializeAddress(k, "usdc", USDC);
    }

    function _log(Deployed memory d) private pure {
        console2.log("timelock           ", d.timelock);
        console2.log("factory            ", d.factory);
        console2.log("feeManager         ", d.feeManager);
        console2.log("graduationManager  ", d.gm);
        console2.log("liquidityLocker    ", d.locker);
        console2.log("launchHook         ", d.hook);
        console2.log("factory impl       ", d.factoryImpl);
        console2.log("feeManager impl    ", d.feeManagerImpl);
        console2.log("graduationMgr impl ", d.gmImpl);
    }
}
