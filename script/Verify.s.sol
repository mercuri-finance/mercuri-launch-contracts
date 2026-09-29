// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Deployments} from "./utils/Deployments.sol";
import {TimelockHistory} from "./utils/TimelockHistory.sol";
import {DefaultConfig} from "./DefaultConfig.sol";
import {LaunchConfig} from "../src/libraries/LaunchTypes.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {FeeManager} from "../src/FeeManager.sol";
import {GraduationManager} from "../src/GraduationManager.sol";
import {LiquidityLocker} from "../src/LiquidityLocker.sol";
import {LaunchHook} from "../src/LaunchHook.sol";

/// @notice Read-only post-deploy check: loads `deployments/<chainId>.json` and asserts, against the chain, that every
///         contract has code, every cross-wiring getter (read through the proxies) points where it should, and the
///         governance is exactly what was intended (upgradeability design, section 5): each proxy's ERC-1967
///         implementation slot equals the recorded implementation; implementations and proxies both reject
///         `initialize`; `owner() == timelock` on all three proxies with no pending transfer; the timelock's delay,
///         and the exact holder set of each of its roles; guardian; treasury; config hash. Needs no private key and
///         sends no transaction — run it with nothing but `--rpc-url`. `deploy.sh` runs it after a broadcast and
///         `timelock.sh` after an executed operation.
/// @dev Expected values. On the testnet (5042002) every EXPECTED_* is optional and defaults to the value recorded in
///      the JSON (so the check is record == chain). On any other chain EXPECTED_PROPOSER, EXPECTED_EXECUTOR,
///      EXPECTED_GUARDIAN, EXPECTED_TREASURY and EXPECTED_TIMELOCK_DELAY are MANDATORY — a record written by a
///      mis-configured deploy must not be able to vouch for itself. EXPECTED_TIMELOCK and EXPECTED_CONFIG_HASH are
///      optional everywhere (defaults: the recorded values).
///      Role holders are enumerated exactly from the timelock's `RoleGranted` logs since the recorded deploy block
///      (every account that ever received a role appears there; see utils/TimelockHistory.sol), then each candidate
///      is re-checked with `hasRole` against current state. Open (scheduled, not executed) operations found in the
///      same logs are listed. With VERIFY_PENDING=true the pending record is verified instead of the tracked one.
contract Verify is Script {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    /// @dev Uniswap v4 encodes a hook's permissions in the low 14 bits of its address.
    uint160 internal constant HOOK_FLAG_MASK = uint160((1 << 14) - 1);
    /// @dev ERC-1967: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev OpenZeppelin 5.x Initializable (ERC-7201 "openzeppelin.storage.Initializable")
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    error VerificationFailed(string what);

    struct Record {
        LaunchFactory factory;
        FeeManager feeManager;
        GraduationManager gm;
        LiquidityLocker locker;
        LaunchHook hook;
        TimelockController timelock;
        address factoryImpl;
        address feeManagerImpl;
        address gmImpl;
        address poolManager;
        address positionManager;
        address permit2;
        address usdc;
        uint256 deployBlock;
    }

    struct Expected {
        address timelock;
        address proposer;
        address canceller;
        address executor;
        address guardian;
        address treasury;
        uint256 delay;
        bytes32 configHash;
    }

    uint256 private checks;

    function run() external {
        // deploy.sh / timelock.sh verify a PENDING record (VERIFY_PENDING=true) before promoting it.
        string memory path =
            vm.envOr("VERIFY_PENDING", false) ? Deployments.pendingRecordPath() : Deployments.recordPath();
        _req(vm.exists(path), "deployment record not found for the connected chain");
        string memory json = vm.readFile(path);
        _req(vm.parseJsonUint(json, ".chainId") == block.chainid, "record chainId does not match the RPC chain");

        Record memory r = _load(json);
        Expected memory e = _expected(json);

        _checkCode(r);
        _checkWiring(r);
        _checkProxies(r, e);
        TimelockHistory.History memory h = TimelockHistory.read(address(r.timelock), r.deployBlock);
        _checkTimelock(r, e, h);
        _checkFactoryGovernance(r, e);

        console2.log("chain id           ", block.chainid);
        console2.log("record             ", path);
        console2.log("timelock           ", address(r.timelock));
        console2.log("timelock delay (s) ", e.delay);
        console2.log("proposer           ", e.proposer);
        console2.log("canceller          ", e.canceller);
        console2.log("executor           ", e.executor);
        console2.log("guardian           ", e.guardian);
        console2.log("treasury           ", e.treasury);
        console2.log("factory            ", address(r.factory));
        console2.log("feeManager         ", address(r.feeManager));
        console2.log("graduationManager  ", address(r.gm));
        console2.log("liquidityLocker    ", address(r.locker));
        console2.log("launchHook         ", address(r.hook));
        console2.log("factory impl       ", r.factoryImpl);
        console2.log("feeManager impl    ", r.feeManagerImpl);
        console2.log("graduationMgr impl ", r.gmImpl);
        console2.log("configHash         ", vm.toString(e.configHash));
        console2.log(
            "config is DefaultConfig:", e.configHash == keccak256(abi.encode(DefaultConfig.get())) ? "yes" : "no"
        );
        console2.log("createToken paused :", r.factory.paused() ? "yes" : "no");
        _reportOpenOperations(r.timelock, h);
        console2.log(string.concat("VERIFY OK: ", vm.toString(checks), " assertions passed"));
    }

    // ---------------------------------------------------------------- inputs

    function _load(string memory json) internal pure returns (Record memory r) {
        r.factory = LaunchFactory(vm.parseJsonAddress(json, ".factory"));
        r.feeManager = FeeManager(vm.parseJsonAddress(json, ".feeManager"));
        r.gm = GraduationManager(vm.parseJsonAddress(json, ".graduationManager"));
        r.locker = LiquidityLocker(vm.parseJsonAddress(json, ".liquidityLocker"));
        r.hook = LaunchHook(vm.parseJsonAddress(json, ".launchHook"));
        r.timelock = TimelockController(payable(vm.parseJsonAddress(json, ".timelock")));
        r.factoryImpl = vm.parseJsonAddress(json, ".factoryImplementation");
        r.feeManagerImpl = vm.parseJsonAddress(json, ".feeManagerImplementation");
        r.gmImpl = vm.parseJsonAddress(json, ".graduationManagerImplementation");
        r.poolManager = vm.parseJsonAddress(json, ".poolManager");
        r.positionManager = vm.parseJsonAddress(json, ".positionManager");
        r.permit2 = vm.parseJsonAddress(json, ".permit2");
        r.usdc = vm.parseJsonAddress(json, ".usdc");
        r.deployBlock = vm.parseJsonUint(json, ".deployBlock");
    }

    function _expected(string memory json) internal returns (Expected memory e) {
        bool testnet = Deployments.isTestnet();
        e.timelock = vm.envOr("EXPECTED_TIMELOCK", vm.parseJsonAddress(json, ".timelock"));
        e.proposer = _expectAddress("EXPECTED_PROPOSER", json, ".proposer", testnet);
        // Deployed equal to the proposer; off the testnet it defaults to EXPECTED_PROPOSER.
        bool recordHasCanceller = vm.keyExistsJson(json, ".canceller");
        if (vm.envExists("EXPECTED_CANCELLER")) {
            e.canceller = vm.envAddress("EXPECTED_CANCELLER");
        } else if (!testnet) {
            e.canceller = e.proposer;
        } else {
            // Read the record key only when no expectation was given.
            _req(recordHasCanceller, "record has no .canceller key and EXPECTED_CANCELLER is not set");
            e.canceller = vm.parseJsonAddress(json, ".canceller");
        }
        e.executor = _expectAddress("EXPECTED_EXECUTOR", json, ".executor", testnet);
        e.guardian = _expectAddress("EXPECTED_GUARDIAN", json, ".guardian", testnet);
        e.treasury = _expectAddress("EXPECTED_TREASURY", json, ".treasury", testnet);
        e.delay = testnet
            ? vm.envOr("EXPECTED_TIMELOCK_DELAY", vm.parseJsonUint(json, ".timelockDelay"))
            : vm.envUint("EXPECTED_TIMELOCK_DELAY");
        e.configHash = vm.envOr("EXPECTED_CONFIG_HASH", vm.parseJsonBytes32(json, ".configHash"));

        // The record must agree with the expectations too: a consumer reads addresses from the record.
        _req(vm.parseJsonAddress(json, ".timelock") == e.timelock, "recorded timelock != EXPECTED_TIMELOCK");
        _req(vm.parseJsonAddress(json, ".proposer") == e.proposer, "recorded proposer != EXPECTED_PROPOSER");
        if (recordHasCanceller) {
            _req(vm.parseJsonAddress(json, ".canceller") == e.canceller, "recorded canceller != EXPECTED_CANCELLER");
        } else {
            console2.log("NOTE: the record has no .canceller key; the chain is checked against EXPECTED_CANCELLER only");
        }
        _req(vm.parseJsonAddress(json, ".executor") == e.executor, "recorded executor != EXPECTED_EXECUTOR");
        _req(vm.parseJsonAddress(json, ".guardian") == e.guardian, "recorded guardian != EXPECTED_GUARDIAN");
        _req(vm.parseJsonAddress(json, ".treasury") == e.treasury, "recorded treasury != EXPECTED_TREASURY");
        _req(vm.parseJsonUint(json, ".timelockDelay") == e.delay, "recorded timelockDelay != EXPECTED_TIMELOCK_DELAY");
        _req(vm.parseJsonBytes32(json, ".configHash") == e.configHash, "recorded configHash != EXPECTED_CONFIG_HASH");
    }

    function _expectAddress(string memory envName, string memory json, string memory key, bool testnet)
        internal
        view
        returns (address)
    {
        return testnet ? vm.envOr(envName, vm.parseJsonAddress(json, key)) : vm.envAddress(envName);
    }

    // ---------------------------------------------------------------- checks

    function _checkCode(Record memory r) internal {
        _req(address(r.timelock).code.length != 0, "timelock has no code");
        _req(address(r.factory).code.length != 0, "factory has no code");
        _req(address(r.feeManager).code.length != 0, "feeManager has no code");
        _req(address(r.gm).code.length != 0, "graduationManager has no code");
        _req(address(r.locker).code.length != 0, "liquidityLocker has no code");
        _req(address(r.hook).code.length != 0, "launchHook has no code");
        _req(r.factoryImpl.code.length != 0, "factory implementation has no code");
        _req(r.feeManagerImpl.code.length != 0, "feeManager implementation has no code");
        _req(r.gmImpl.code.length != 0, "graduationManager implementation has no code");
        _req(r.poolManager.code.length != 0, "poolManager has no code");
        _req(r.positionManager.code.length != 0, "positionManager has no code");
        _req(r.permit2.code.length != 0, "permit2 has no code");
        _req(r.usdc == USDC, "recorded usdc is not the canonical interface address");
        _req(r.usdc.code.length != 0, "usdc interface has no code");
    }

    function _checkWiring(Record memory r) internal {
        // ---- factory
        _req(address(r.factory.feeManager()) == address(r.feeManager), "factory.feeManager mismatch");
        _req(r.factory.graduationManager() == address(r.gm), "factory.graduationManager mismatch");

        // ---- fee manager
        _req(address(r.feeManager.factory()) == address(r.factory), "feeManager.factory mismatch");
        _req(r.feeManager.hook() == address(r.hook), "feeManager.hook mismatch");
        _req(r.feeManager.graduationManager() == address(r.gm), "feeManager.graduationManager mismatch");

        // ---- graduation manager
        _req(address(r.gm.factory()) == address(r.factory), "graduationManager.factory mismatch");
        _req(address(r.gm.poolManager()) == r.poolManager, "graduationManager.poolManager mismatch");
        _req(address(r.gm.positionManager()) == r.positionManager, "graduationManager.positionManager mismatch");
        _req(address(r.gm.permit2()) == r.permit2, "graduationManager.permit2 mismatch");
        _req(r.gm.hook() == address(r.hook), "graduationManager.hook mismatch");
        _req(address(r.gm.locker()) == address(r.locker), "graduationManager.locker mismatch");
        _req(address(r.gm.feeManager()) == address(r.feeManager), "graduationManager.feeManager mismatch");
        _req(r.gm.usdc() == r.usdc, "graduationManager.usdc mismatch");

        // ---- liquidity locker (immutable; must point at the GraduationManager PROXY)
        _req(address(r.locker.positionManager()) == r.positionManager, "liquidityLocker.positionManager mismatch");
        _req(r.locker.graduationManager() == address(r.gm), "liquidityLocker.graduationManager mismatch");

        // ---- hook (immutable; must point at the PROXIES)
        _req(address(r.hook.poolManager()) == r.poolManager, "launchHook.poolManager mismatch");
        _req(address(r.hook.feeManager()) == address(r.feeManager), "launchHook.feeManager mismatch");
        _req(r.hook.graduationManager() == address(r.gm), "launchHook.graduationManager mismatch");
        _req(r.hook.usdc() == r.usdc, "launchHook.usdc mismatch");
        _req(
            uint160(address(r.hook)) & HOOK_FLAG_MASK == r.hook.FLAGS(),
            "launchHook address bits do not carry exactly FLAGS"
        );
    }

    function _checkProxies(Record memory r, Expected memory e) internal {
        _checkProxy("factory", address(r.factory), r.factoryImpl, e.timelock);
        _checkProxy("feeManager", address(r.feeManager), r.feeManagerImpl, e.timelock);
        _checkProxy("graduationManager", address(r.gm), r.gmImpl, e.timelock);

        LaunchConfig memory cfg = DefaultConfig.get();
        address a = address(1);
        // Initializers: every implementation is locked, every proxy already initialised once.
        _rejectsInit(
            "factory implementation", r.factoryImpl, abi.encodeCall(LaunchFactory.initialize, (a, a, a, a, a, cfg))
        );
        _rejectsInit(
            "factory proxy", address(r.factory), abi.encodeCall(LaunchFactory.initialize, (a, a, a, a, a, cfg))
        );
        _rejectsInit("feeManager implementation", r.feeManagerImpl, abi.encodeCall(FeeManager.initialize, (a, a, a, a)));
        _rejectsInit("feeManager proxy", address(r.feeManager), abi.encodeCall(FeeManager.initialize, (a, a, a, a)));
        bytes memory gmInit = abi.encodeCall(GraduationManager.initialize, (a, a, a, a, a, a, a, a, a));
        _rejectsInit("graduationManager implementation", r.gmImpl, gmInit);
        _rejectsInit("graduationManager proxy", address(r.gm), gmInit);
    }

    function _checkProxy(string memory name, address proxy, address impl, address timelock) internal {
        address slotImpl = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        _req(slotImpl == impl, string.concat(name, ": ERC-1967 implementation slot != recorded implementation"));
        // M6: the proxy is the stock OpenZeppelin ERC1967Proxy (it has no immutables, so its runtime code is the
        // same for every deployment built with this toolchain).
        _req(
            proxy.codehash == keccak256(type(ERC1967Proxy).runtimeCode),
            string.concat(name, ": proxy runtime code is not the ERC1967Proxy this build expects")
        );
        // Implementation: `_disableInitializers()` wrote type(uint64).max and left `_initializing` false (the whole
        // word: uint64 `_initialized` in the low bytes, bool `_initializing` right above it).
        _req(
            uint256(vm.load(impl, INITIALIZABLE_SLOT)) == type(uint64).max,
            string.concat(name, ": implementation initializers are not disabled")
        );
        // M5 — proxy: initialised (version >= 1; a later upgrade may use `reinitializer(n)`), never locked with
        // `_disableInitializers()` (type(uint64).max), and not mid-initialisation.
        uint256 word = uint256(vm.load(proxy, INITIALIZABLE_SLOT));
        uint64 version = uint64(word);
        _req(version != 0, string.concat(name, ": proxy is not initialised"));
        _req(version != type(uint64).max, string.concat(name, ": proxy initializers are disabled"));
        _req(word >> 64 == 0, string.concat(name, ": proxy is mid-initialisation"));
        // All three share Ownable2StepUpgradeable; LaunchFactory's ABI is used only for the two getters.
        _req(LaunchFactory(proxy).owner() == timelock, string.concat(name, ": owner() is not the timelock"));
        _req(
            LaunchFactory(proxy).pendingOwner() == address(0), string.concat(name, ": an ownership transfer is pending")
        );
    }

    /// @dev Calls `initialize` (simulated only: this script never broadcasts) and requires the exact
    ///      `InvalidInitialization()` revert.
    function _rejectsInit(string memory name, address target, bytes memory data) internal {
        (bool ok, bytes memory ret) = target.call(data);
        _req(
            !ok && ret.length == 4 && bytes4(ret) == Initializable.InvalidInitialization.selector,
            string.concat(name, ": initialize() is not rejected with InvalidInitialization")
        );
    }

    function _checkTimelock(Record memory r, Expected memory e, TimelockHistory.History memory h) internal {
        TimelockController t = r.timelock;
        // M6: the stock OpenZeppelin TimelockController (no immutables, so one runtime code for every deployment).
        _req(
            address(t).codehash == keccak256(type(TimelockController).runtimeCode),
            "timelock runtime code is not the TimelockController this build expects"
        );
        _req(address(t) == e.timelock, "recorded timelock != EXPECTED_TIMELOCK");
        _req(t.getMinDelay() == e.delay, "timelock.getMinDelay() != expected delay");
        bytes32 admin = t.DEFAULT_ADMIN_ROLE();
        _req(t.getRoleAdmin(t.PROPOSER_ROLE()) == admin, "PROPOSER_ROLE admin is not DEFAULT_ADMIN_ROLE");
        _req(t.getRoleAdmin(t.EXECUTOR_ROLE()) == admin, "EXECUTOR_ROLE admin is not DEFAULT_ADMIN_ROLE");
        _req(t.getRoleAdmin(t.CANCELLER_ROLE()) == admin, "CANCELLER_ROLE admin is not DEFAULT_ADMIN_ROLE");

        _req(h.grants.length != 0, "no RoleGranted logs found for the timelock since deployBlock");
        _exactHolder(t, h.grants, t.PROPOSER_ROLE(), e.proposer, "PROPOSER_ROLE");
        _exactHolder(t, h.grants, t.CANCELLER_ROLE(), e.canceller, "CANCELLER_ROLE");
        _exactHolder(t, h.grants, t.EXECUTOR_ROLE(), e.executor, "EXECUTOR_ROLE");
        // No admin other than the timelock itself: changing roles or the delay must itself wait out the delay.
        _exactHolder(t, h.grants, admin, address(t), "DEFAULT_ADMIN_ROLE");
    }

    /// @dev Requires that `expected` currently holds `role` and that no other account that was EVER granted
    ///      `role` still holds it.
    function _exactHolder(
        TimelockController t,
        TimelockHistory.RoleGrant[] memory grants,
        bytes32 role,
        address expected,
        string memory name
    ) internal {
        _req(t.hasRole(role, expected), string.concat(name, " is not held by the expected address"));
        uint256 holders;
        for (uint256 i; i < grants.length; ++i) {
            if (grants[i].role != role || !t.hasRole(role, grants[i].account)) continue;
            if (grants[i].account != expected) {
                _req(false, string.concat(name, " is also held by ", vm.toString(grants[i].account)));
            }
            holders++;
        }
        _req(holders != 0, string.concat(name, ": expected holder never appears in RoleGranted logs"));
    }

    /// @dev Informational (not an assertion): every operation the chain says is scheduled and not yet executed or
    ///      cancelled, whoever scheduled it. A queued upgrade is legitimate; it is listed so nobody is surprised.
    function _reportOpenOperations(TimelockController t, TimelockHistory.History memory h) internal view {
        uint256 open;
        for (uint256 i; i < h.scheduled.length; ++i) {
            TimelockHistory.Scheduled memory s = h.scheduled[i];
            if (s.index != 0 || !t.isOperationPending(s.id)) continue;
            console2.log("OPEN OPERATION     ", vm.toString(s.id));
            console2.log("  target / ready at", s.target, t.getTimestamp(s.id));
            ++open;
        }
        console2.log("open timelock operations (from chain logs):", open);
    }

    function _checkFactoryGovernance(Record memory r, Expected memory e) internal {
        _req(r.factory.guardian() == e.guardian, "factory.guardian() != expected guardian");
        _req(r.factory.treasury() == e.treasury, "factory.treasury() != expected treasury");
        _req(r.factory.configHash() == e.configHash, "factory.configHash() != expected config hash");
        _req(
            keccak256(abi.encode(r.factory.config())) == r.factory.configHash(),
            "factory.config() does not hash to factory.configHash()"
        );
    }

    function _req(bool ok, string memory what) internal {
        if (!ok) revert VerificationFailed(what);
        ++checks;
    }
}
