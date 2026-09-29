// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Deployments} from "./utils/Deployments.sol";
import {TimelockHistory} from "./utils/TimelockHistory.sol";
import {DefaultConfig} from "./DefaultConfig.sol";
import {LaunchConfig} from "../src/libraries/LaunchTypes.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {FeeManager} from "../src/FeeManager.sol";
import {GraduationManager} from "../src/GraduationManager.sol";

/// @notice Governance runbook for the timelocked system (upgradeability design, section 6). Run it through
///         `script/timelock.sh`, which adds the chain guard, the gas-price floor, the storage-layout check and the
///         promotion of pending files. The mode comes from env `MODE`:
///           status            read-only: governance state, and EVERY scheduled-not-executed operation found in the
///                             timelock's own logs; any not in the operation log is flagged "UNKNOWN ORIGIN"
///           schedule-config   `LaunchFactory.setConfig(cfg)`; cfg = DefaultConfig.get(), or the JSON file named by
///                             env CONFIG_JSON (under ./deployments; one decimal-string field per LaunchConfig member)
///           schedule-upgrade  env TARGET = FeeManager | GraduationManager | LaunchFactory: deploys a new
///                             implementation from the current build, then schedules `upgradeToAndCall(newImpl, "")`
///           execute           env OP_ID: the operation is reconstructed from the timelock's CallScheduled/CallSalt
///                             logs (so an operation scheduled by anyone, e.g. a multisig, works)
///           cancel            env OP_ID
///           sync              updates the record's governed fields (implementations, configHash, treasury, guardian,
///                             timelockDelay, proposer / canceller / executor) from chain state, but only for changes
///                             explained by an executed timelock operation; refuses otherwise
///         SAFE MODE (env SAFE_MODE=true, `timelock.sh --safe`): for a role held by a multisig. Nothing that needs the
///         role is sent; the script simulates the call as the timelock and PRINTS the exact timelock calldata
///         (schedule: target, value, data, predecessor, salt, delay and the operation id; or execute / cancel) for the
///         multisig to submit. schedule-upgrade still deploys the implementation (any funded key). Proposals are
///         recorded in the operation log as `proposed-offchain`.
///         Optional env: OP_SALT (bytes32; default = the current block timestamp).
/// @dev Writes: only in a `--broadcast` run (forge's own context, see Deployments), and only pending files — one
///      operation-log entry (`<chainId>-operations.pending.json`) or, for sync, a whole record
///      (`<chainId>.pending.json`). timelock.sh promotes them after the broadcast succeeded (and, for the record,
///      after Verify passed). The signing key is env DEPLOYER_PRIVATE_KEY, never a command-line argument.
contract Timelock is Script {
    /// @dev ERC-1967: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct System {
        TimelockController timelock;
        address factory;
        address feeManager;
        address gm;
        uint256 deployBlock;
        string recordJson;
    }

    /// @dev One single-call operation.
    struct Op {
        bytes32 id;
        string kind; // "config" | "upgrade" | "other"
        string targetName;
        address target;
        uint256 value;
        bytes data;
        bytes32 predecessor;
        bytes32 salt;
        uint256 delay;
        address newImplementation; // upgrade only
        bytes32 configHash; // config only
    }

    bool private live;
    bool internal safe;

    function run() external {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "chain id does not match EXPECTED_CHAIN_ID");
        live = Deployments.broadcasting();
        safe = vm.envOr("SAFE_MODE", false);
        string memory mode = vm.envString("MODE");
        System memory s = _load();

        bytes32 m = keccak256(bytes(mode));
        if (m == keccak256("status")) return _status(s);
        Deployments.requireNoPending();
        if (m == keccak256("schedule-config")) return _scheduleConfig(s);
        if (m == keccak256("schedule-upgrade")) return _scheduleUpgrade(s);
        if (m == keccak256("execute")) return _execute(s);
        if (m == keccak256("cancel")) return _cancel(s);
        if (m == keccak256("sync")) return _sync(s);
        revert("MODE must be one of: status, schedule-config, schedule-upgrade, execute, cancel, sync");
    }

    // ---------------------------------------------------------------- modes

    function _status(System memory s) internal view {
        TimelockController t = s.timelock;
        console2.log("timelock           ", address(t));
        console2.log("min delay (s)      ", t.getMinDelay());
        console2.log("now (timestamp)    ", block.timestamp);
        _statusProxy("LaunchFactory", s.factory, t);
        _statusProxy("FeeManager", s.feeManager, t);
        _statusProxy("GraduationManager", s.gm, t);
        LaunchFactory f = LaunchFactory(s.factory);
        console2.log("factory configHash ", vm.toString(f.configHash()));
        console2.log(
            "  is DefaultConfig :", f.configHash() == keccak256(abi.encode(DefaultConfig.get())) ? "yes" : "no"
        );
        console2.log("factory guardian   ", f.guardian());
        console2.log("factory treasury   ", f.treasury());
        console2.log("createToken paused :", f.paused() ? "yes" : "no");

        // M3: discovered from the chain, not from the local log.
        TimelockHistory.History memory h = TimelockHistory.read(address(t), s.deployBlock);
        string memory log = vm.exists(Deployments.operationsPath()) ? vm.readFile(Deployments.operationsPath()) : "";
        uint256 open;
        uint256 done;
        for (uint256 i; i < h.scheduled.length; ++i) {
            TimelockHistory.Scheduled memory sc = h.scheduled[i];
            if (sc.index != 0) continue;
            if (t.isOperationDone(sc.id)) {
                ++done;
                continue;
            }
            if (!t.isOperationPending(sc.id)) continue; // cancelled
            Op memory op = _fromScheduled(s, sc);
            console2.log("---- OPEN OPERATION");
            _printOp(op);
            if (TimelockHistory.isBatch(h, sc.id)) console2.log("  BATCH operation (only call 0 shown)");
            console2.log("  state            ", _stateName(t.getOperationState(sc.id)));
            console2.log("  earliest execute ", t.getTimestamp(sc.id));
            string memory origin = _loggedAction(log, sc.id, address(t));
            console2.log(
                "  origin           ",
                bytes(origin).length == 0
                    ? "UNKNOWN ORIGIN (not in the operation log)"
                    : string.concat("operation log: ", origin)
            );
            ++open;
        }
        console2.log("open operations (from chain logs):", open);
        console2.log("executed operations (from chain logs):", done);
        console2.log("cancelled operations (from chain logs):", h.cancelled.length);
    }

    function _scheduleConfig(System memory s) internal {
        LaunchConfig memory cfg = _config();
        bytes32 newHash = keccak256(abi.encode(cfg));
        console2.log("current configHash ", vm.toString(LaunchFactory(s.factory).configHash()));
        console2.log("new configHash     ", vm.toString(newHash));
        require(LaunchFactory(s.factory).configHash() != newHash, "factory is already on this config; nothing to do");

        Op memory op = _newOp(s, s.factory, abi.encodeCall(LaunchFactory.setConfig, (cfg)));
        _preflight(s, op);
        if (safe) return _proposeOffchain(s, op);

        uint256 pk = _signerWithRole(s.timelock, s.timelock.PROPOSER_ROLE(), "PROPOSER_ROLE");
        vm.startBroadcast(pk);
        s.timelock.schedule(op.target, op.value, op.data, op.predecessor, op.salt, op.delay);
        vm.stopBroadcast();
        _afterSchedule(s, op);
    }

    function _scheduleUpgrade(System memory s) internal {
        string memory name = vm.envString("TARGET");
        address proxy = _proxyFor(s, name);
        _storageGate();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        if (!safe) {
            // Checked before anything is deployed, so a signer without the role does not waste an implementation.
            _signerWithRole(s.timelock, s.timelock.PROPOSER_ROLE(), "PROPOSER_ROLE");
        }

        // Nothing is broadcast unless the whole run succeeds, so if the preflight below refuses the operation the
        // implementation deployment is dropped with it.
        vm.startBroadcast(pk);
        address newImpl = _newImplementation(name);
        vm.stopBroadcast();

        Op memory op = _newOp(s, proxy, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, "")));
        console2.log("current impl       ", _implementationOf(proxy));
        console2.log("new implementation ", newImpl);
        _preflight(s, op);
        if (safe) return _proposeOffchain(s, op);

        vm.startBroadcast(pk);
        s.timelock.schedule(op.target, op.value, op.data, op.predecessor, op.salt, op.delay);
        vm.stopBroadcast();
        _afterSchedule(s, op);
    }

    function _execute(System memory s) internal {
        bytes32 id = vm.envBytes32("OP_ID");
        Op memory op = _fromChain(s, id);
        _executeReady(s, op);
    }

    function _executeReady(System memory s, Op memory op) internal {
        bytes32 id = op.id;
        _printOp(op);
        TimelockController.OperationState state = s.timelock.getOperationState(id);
        console2.log("  state            ", _stateName(state));
        console2.log("  earliest execute ", s.timelock.getTimestamp(id));
        console2.log("  now (timestamp)  ", block.timestamp);
        require(state == TimelockController.OperationState.Ready, "operation is not Ready (see state above)");

        _preflight(s, op);
        if (safe) {
            console2.log("SAFE MODE: submit this through an EXECUTOR_ROLE holder, then run MODE=sync:");
            console2.log("  to               ", address(s.timelock));
            console2.log("  value             0");
            console2.log("  execute calldata:");
            console2.logBytes(
                abi.encodeCall(TimelockController.execute, (op.target, op.value, op.data, op.predecessor, op.salt))
            );
            return;
        }

        uint256 pk = _signerWithRole(s.timelock, s.timelock.EXECUTOR_ROLE(), "EXECUTOR_ROLE");
        vm.startBroadcast(pk);
        s.timelock.execute(op.target, op.value, op.data, op.predecessor, op.salt);
        vm.stopBroadcast();

        require(s.timelock.isOperationDone(id), "operation not Done after execute");
        if (_eq(op.kind, "upgrade")) {
            require(_implementationOf(op.target) == op.newImplementation, "implementation slot != new implementation");
        } else if (_eq(op.kind, "config")) {
            require(LaunchFactory(s.factory).configHash() == op.configHash, "configHash != scheduled config hash");
        }
        console2.log("EXECUTED", vm.toString(id));
        _writeActionEntry(s, "execute", id);
    }

    function _cancel(System memory s) internal {
        bytes32 id = vm.envBytes32("OP_ID");
        Op memory op = _fromChain(s, id);
        _printOp(op);
        require(s.timelock.isOperationPending(id), "operation is not pending (already executed or cancelled)");

        if (safe) {
            console2.log("SAFE MODE: submit this through a CANCELLER_ROLE holder:");
            console2.log("  to               ", address(s.timelock));
            console2.log("  value             0");
            console2.log("  cancel calldata:");
            console2.logBytes(abi.encodeCall(TimelockController.cancel, (id)));
            return;
        }

        uint256 pk = _signerWithRole(s.timelock, s.timelock.CANCELLER_ROLE(), "CANCELLER_ROLE");
        vm.startBroadcast(pk);
        s.timelock.cancel(id);
        vm.stopBroadcast();
        require(s.timelock.getOperationState(id) == TimelockController.OperationState.Unset, "cancel did not clear it");
        console2.log("CANCELLED", vm.toString(id));
        _writeActionEntry(s, "cancel", id);
    }

    /// @dev Brings every governed field of the record in line with the chain — implementations, config hash, treasury,
    ///      guardian, timelock delay and the proposer / canceller / executor role holders — but only where the chain's
    ///      value was produced by an executed timelock operation found in the timelock's own `CallExecuted` logs
    ///      (the executed call's selector and arguments are decoded and must match exactly; calls inside a batch count
    ///      too). An unexplained difference is refused: the record must never silently absorb it. The record models
    ///      exactly one holder per role (Verify requires exactly that), so a role with zero or several holders is
    ///      refused too — rotate a role with one batch (grantRole + revokeRole) so no intermediate state exists.
    function _sync(System memory s) internal {
        TimelockHistory.History memory h = TimelockHistory.read(address(s.timelock), s.deployBlock);
        string[10] memory keys = [
            ".factoryImplementation",
            ".feeManagerImplementation",
            ".graduationManagerImplementation",
            ".configHash",
            ".treasury",
            ".guardian",
            ".timelockDelay",
            ".proposer",
            ".canceller",
            ".executor"
        ];
        string[10] memory values;
        uint256 nChanged;

        // implementations
        address[3] memory proxies = [s.factory, s.feeManager, s.gm];
        for (uint256 i; i < 3; ++i) {
            address onChain = _implementationOf(proxies[i]);
            if (_sameAddress(s, keys[i], onChain)) continue;
            _explain(
                _executedCall(h, proxies[i], UUPSUpgradeable.upgradeToAndCall.selector, abi.encode(onChain), 32),
                keys[i]
            );
            values[i] = vm.toString(onChain);
            ++nChanged;
        }
        // config hash
        LaunchFactory f = LaunchFactory(s.factory);
        bytes32 chainHash = f.configHash();
        _logChange(".configHash", vm.toString(vm.parseJsonBytes32(s.recordJson, ".configHash")), vm.toString(chainHash));
        if (chainHash != vm.parseJsonBytes32(s.recordJson, ".configHash")) {
            _explain(_configExplained(h, s.factory, chainHash), ".configHash");
            values[3] = vm.toString(chainHash);
            ++nChanged;
        }
        // treasury, guardian (factory setters)
        if (!_sameAddress(s, keys[4], f.treasury())) {
            _explain(
                _executedCall(h, s.factory, LaunchFactory.setTreasury.selector, abi.encode(f.treasury()), 32), keys[4]
            );
            values[4] = vm.toString(f.treasury());
            ++nChanged;
        }
        if (!_sameAddress(s, keys[5], f.guardian())) {
            _explain(
                _executedCall(h, s.factory, LaunchFactory.setGuardian.selector, abi.encode(f.guardian()), 32), keys[5]
            );
            values[5] = vm.toString(f.guardian());
            ++nChanged;
        }
        // timelock delay (updateDelay can only be called by the timelock on itself)
        uint256 delay = s.timelock.getMinDelay();
        uint256 recordedDelay = vm.parseJsonUint(s.recordJson, ".timelockDelay");
        _logChange(".timelockDelay", vm.toString(recordedDelay), vm.toString(delay));
        if (delay != recordedDelay) {
            _explain(
                _executedCall(h, address(s.timelock), TimelockController.updateDelay.selector, abi.encode(delay), 32),
                ".timelockDelay"
            );
            values[6] = vm.toString(delay);
            ++nChanged;
        }
        // role holders
        bytes32[3] memory roles = [s.timelock.PROPOSER_ROLE(), s.timelock.CANCELLER_ROLE(), s.timelock.EXECUTOR_ROLE()];
        for (uint256 i; i < 3; ++i) {
            address holder = _soleHolder(s.timelock, h, roles[i], keys[7 + i]);
            if (_sameAddress(s, keys[7 + i], holder)) continue;
            _explain(
                _executedCall(
                    h, address(s.timelock), IAccessControl.grantRole.selector, abi.encode(roles[i], holder), 64
                ),
                keys[7 + i]
            );
            values[7 + i] = vm.toString(holder);
            ++nChanged;
        }

        if (nChanged == 0) {
            console2.log("SYNC: record already matches the chain; nothing to write");
            return;
        }
        if (!live) {
            console2.log("SIMULATION (no --broadcast): not writing the pending record");
            return;
        }
        string memory pending = Deployments.pendingRecordPath();
        vm.writeJson(s.recordJson, pending);
        for (uint256 i; i < keys.length; ++i) {
            if (bytes(values[i]).length == 0) continue;
            // timelockDelay is a JSON number; everything else a string
            vm.writeJson(i == 6 ? values[i] : string.concat('"', values[i], '"'), pending, keys[i]);
        }
        console2.log("SYNC: wrote pending record", pending);
        console2.log("SYNC: fields changed:", nChanged);
    }

    function _sameAddress(System memory s, string memory key, address onChain) internal pure returns (bool) {
        address recorded = vm.parseJsonAddress(s.recordJson, key);
        _logChange(key, vm.toString(recorded), vm.toString(onChain));
        return recorded == onChain;
    }

    function _logChange(string memory key, string memory recorded, string memory onChain) internal pure {
        console2.log(string.concat(key, " recorded / chain: ", recorded, " / ", onChain));
    }

    function _explain(bool explained, string memory key) internal pure {
        require(
            explained,
            string.concat(
                "UNEXPLAINED change of ", key, ": no executed timelock operation produced it; refusing to sync"
            )
        );
        console2.log(string.concat("  ", key, ": explained by an executed timelock operation"));
    }

    /// @dev The single current holder of `role` (every account ever granted it, re-checked with hasRole).
    function _soleHolder(TimelockController t, TimelockHistory.History memory h, bytes32 role, string memory key)
        internal
        view
        returns (address holder)
    {
        address[] memory seen = new address[](h.grants.length);
        uint256 n;
        for (uint256 i; i < h.grants.length; ++i) {
            address a = h.grants[i].account;
            if (h.grants[i].role != role || !t.hasRole(role, a)) continue;
            bool dup;
            for (uint256 j; j < n; ++j) {
                if (seen[j] == a) dup = true;
            }
            if (dup) continue;
            seen[n++] = a;
            holder = a;
        }
        require(
            n == 1,
            string.concat(
                key,
                ": the role has ",
                vm.toString(n),
                " holders; the record (and Verify) model exactly one - rotate roles in one batch (grantRole + revokeRole)"
            )
        );
    }

    // ---------------------------------------------------------------- scheduling helpers

    function _newOp(System memory s, address target, bytes memory data) internal view returns (Op memory op) {
        op = _describe(s, target, data);
        op.salt = vm.envOr("OP_SALT", bytes32(block.timestamp));
        op.delay = s.timelock.getMinDelay();
        op.id = s.timelock.hashOperation(op.target, op.value, op.data, op.predecessor, op.salt);
        require(
            s.timelock.getOperationState(op.id) == TimelockController.OperationState.Unset,
            "an operation with this id already exists (set a different OP_SALT)"
        );
    }

    /// @dev Simulates the call and upgrade postconditions, then restores every write.
    function _preflight(System memory s, Op memory op) internal {
        uint256 snap = vm.snapshotState();
        bytes32 beforeState;
        bool upgrade = _eq(op.kind, "upgrade");
        if (upgrade) beforeState = _upgradeState(s, op.target);
        vm.prank(address(s.timelock));
        (bool ok, bytes memory ret) = op.target.call{value: op.value}(op.data);
        if (ok && upgrade) {
            require(_implementationOf(op.target) == op.newImplementation, "preflight: implementation mismatch");
            require(_upgradeState(s, op.target) == beforeState, "preflight: protected state changed");
            // A UUPS implementation whose authorization is now broken must not be scheduled.
            vm.prank(address(s.timelock));
            (bool canUpgrade,) =
                op.target.call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (op.newImplementation, bytes(""))));
            require(canUpgrade, "preflight: future upgrade disabled");
            require(_upgradeState(s, op.target) == beforeState, "preflight: repeat upgrade changed state");
            bytes32 initSlot = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
            require(
                uint64(uint256(vm.load(op.newImplementation, initSlot))) == type(uint64).max,
                "preflight: implementation initializer unlocked"
            );
        }
        require(vm.revertToState(snap), "preflight: snapshot restore failed");
        if (!ok) {
            console2.logBytes(ret);
            revert("preflight: the call reverts when executed by the timelock; refusing to schedule it");
        }
        console2.log("preflight: call and protected upgrade state checks passed");
    }

    /// @dev In-place upgrades through this wrapper must preserve control and wiring.
    ///      Deliberate migrations need a separately reviewed migration procedure.
    function _upgradeState(System memory s, address proxy) internal view returns (bytes32) {
        LaunchFactory common = LaunchFactory(proxy);
        require(common.owner() == address(s.timelock), "preflight: owner is not timelock");
        require(common.pendingOwner() == address(0), "preflight: pending owner");
        if (proxy == s.feeManager) {
            FeeManager f = FeeManager(proxy);
            return
                keccak256(abi.encode(f.factory(), f.hook(), f.graduationManager(), f.totalOwed(), f.platformBalance()));
        }
        if (proxy == s.gm) {
            GraduationManager g = GraduationManager(proxy);
            return keccak256(
                abi.encode(
                    g.factory(),
                    g.poolManager(),
                    g.positionManager(),
                    g.permit2(),
                    g.hook(),
                    g.locker(),
                    g.feeManager(),
                    g.usdc()
                )
            );
        }
        require(proxy == s.factory, "preflight: unsupported upgrade target");
        return keccak256(
            abi.encode(
                common.feeManager(),
                common.graduationManager(),
                common.treasury(),
                common.guardian(),
                common.configHash(),
                common.config(),
                common.paused()
            )
        );
    }

    function _signerWithRole(TimelockController t, bytes32 role, string memory roleName)
        internal
        view
        returns (uint256 pk)
    {
        pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        if (t.hasRole(role, vm.addr(pk)) || t.hasRole(role, address(0))) return pk;
        console2.log("signer             ", vm.addr(pk));
        revert(string.concat("signer does not hold ", roleName, "; use timelock.sh --safe to print the calldata"));
    }

    function _proposeOffchain(System memory s, Op memory op) internal {
        console2.log("SAFE MODE: PROPOSE THROUGH A PROPOSER_ROLE HOLDER (nothing below has been scheduled):");
        console2.log("  to (timelock)    ", address(s.timelock));
        console2.log("  value             0");
        console2.log("  call: schedule(target, value, data, predecessor, salt, delay)");
        console2.log("    target         ", op.target);
        console2.log("    value          ", op.value);
        console2.log("    data:");
        console2.logBytes(op.data);
        console2.log("    predecessor    ", vm.toString(op.predecessor));
        console2.log("    salt           ", vm.toString(op.salt));
        console2.log("    delay          ", op.delay);
        console2.log("  operation id     ", vm.toString(op.id));
        console2.log("  schedule calldata (the whole transaction data):");
        console2.logBytes(
            abi.encodeCall(
                TimelockController.schedule, (op.target, op.value, op.data, op.predecessor, op.salt, op.delay)
            )
        );
        _writeScheduleEntry(s, op, "proposed-offchain");
    }

    function _afterSchedule(System memory s, Op memory op) internal {
        require(s.timelock.isOperationPending(op.id), "operation not pending after schedule");
        console2.log("SCHEDULED");
        _printOp(op);
        console2.log("  earliest execute ", block.timestamp + op.delay);
        _writeScheduleEntry(s, op, "schedule");
    }

    function _writeScheduleEntry(System memory s, Op memory op, string memory action) internal {
        if (!live) {
            console2.log("SIMULATION (no --broadcast): not recording the operation");
            return;
        }
        string memory k = "entry";
        vm.serializeString(k, "action", action);
        vm.serializeBytes32(k, "id", op.id);
        vm.serializeString(k, "kind", op.kind);
        vm.serializeString(k, "targetName", op.targetName);
        vm.serializeAddress(k, "target", op.target);
        vm.serializeUint(k, "value", op.value);
        vm.serializeBytes(k, "data", op.data);
        vm.serializeBytes32(k, "dataHash", keccak256(op.data));
        vm.serializeBytes32(k, "predecessor", op.predecessor);
        vm.serializeBytes32(k, "salt", op.salt);
        vm.serializeUint(k, "delay", op.delay);
        vm.serializeUint(k, "recordedAt", block.timestamp);
        vm.serializeUint(k, "block", block.number);
        vm.serializeAddress(k, "newImplementation", op.newImplementation);
        vm.serializeAddress(
            k, "previousImplementation", _eq(op.kind, "upgrade") ? _implementationOf(op.target) : address(0)
        );
        vm.serializeBytes32(k, "configHash", op.configHash);
        _writePending(vm.serializeAddress(k, "timelock", address(s.timelock)));
    }

    function _writeActionEntry(System memory s, string memory action, bytes32 id) internal {
        if (!live) {
            console2.log("SIMULATION (no --broadcast): not recording the operation");
            return;
        }
        string memory k = "entry";
        vm.serializeString(k, "action", action);
        vm.serializeBytes32(k, "id", id);
        vm.serializeUint(k, "recordedAt", block.timestamp);
        vm.serializeUint(k, "block", block.number);
        _writePending(vm.serializeAddress(k, "timelock", address(s.timelock)));
    }

    function _writePending(string memory entry) internal {
        vm.writeJson(entry, Deployments.pendingOperationPath());
        console2.log("wrote pending operation entry", Deployments.pendingOperationPath());
    }

    // ---------------------------------------------------------------- lookups

    function _load() internal view returns (System memory s) {
        string memory path = Deployments.recordPath();
        require(vm.exists(path), "deployment record not found for the connected chain");
        s.recordJson = vm.readFile(path);
        require(
            vm.parseJsonUint(s.recordJson, ".chainId") == block.chainid, "record chainId does not match the RPC chain"
        );
        s.timelock = TimelockController(payable(vm.parseJsonAddress(s.recordJson, ".timelock")));
        s.factory = vm.parseJsonAddress(s.recordJson, ".factory");
        s.feeManager = vm.parseJsonAddress(s.recordJson, ".feeManager");
        s.gm = vm.parseJsonAddress(s.recordJson, ".graduationManager");
        s.deployBlock = vm.parseJsonUint(s.recordJson, ".deployBlock");
        require(address(s.timelock).code.length != 0, "recorded timelock has no code");
    }

    /// @dev Reconstructs a single-call operation from the timelock's own logs and re-hashes it.
    function _fromChain(System memory s, bytes32 id) internal view returns (Op memory op) {
        TimelockHistory.History memory h = TimelockHistory.read(address(s.timelock), s.deployBlock);
        (bool found, TimelockHistory.Scheduled memory sc) = TimelockHistory.find(h, id);
        require(found, "OP_ID was never scheduled on this timelock (per its CallScheduled logs)");
        require(!TimelockHistory.isBatch(h, id), "OP_ID is a batch operation; this tool handles single calls only");
        op = _fromScheduled(s, sc);
        require(
            s.timelock.hashOperation(op.target, op.value, op.data, op.predecessor, op.salt) == id,
            "logs do not reconstruct OP_ID (hashOperation mismatch)"
        );
    }

    function _fromScheduled(System memory s, TimelockHistory.Scheduled memory sc) internal pure returns (Op memory op) {
        op = _describe(s, sc.target, sc.data);
        op.id = sc.id;
        op.value = sc.value;
        op.predecessor = sc.predecessor;
        op.salt = sc.salt;
        op.delay = sc.delay;
    }

    /// @dev Classifies a call: an upgrade of one of our proxies, a factory config change, or anything else.
    function _describe(System memory s, address target, bytes memory data) internal pure returns (Op memory op) {
        op.target = target;
        op.data = data;
        op.kind = "other";
        op.targetName = target == s.factory
            ? "LaunchFactory"
            : target == s.feeManager
                ? "FeeManager"
                : target == s.gm
                    ? "GraduationManager"
                    : target == address(s.timelock) ? "TimelockController" : "unknown";
        if (data.length < 4) return op;
        bytes4 sel = bytes4(data);
        if (sel == UUPSUpgradeable.upgradeToAndCall.selector) {
            (op.newImplementation,) = abi.decode(_args(data), (address, bytes));
            op.kind = "upgrade";
        } else if (sel == LaunchFactory.setConfig.selector && target == s.factory) {
            op.configHash = keccak256(abi.encode(abi.decode(_args(data), (LaunchConfig))));
            op.kind = "config";
        }
    }

    /// @dev True if the timelock executed a call to `target` with `selector` whose first `argLen` bytes of arguments
    ///      equal `args` (a prefix match, so trailing arguments such as upgradeToAndCall's `data` are ignored).
    function _executedCall(
        TimelockHistory.History memory h,
        address target,
        bytes4 selector,
        bytes memory args,
        uint256 argLen
    ) internal pure returns (bool) {
        for (uint256 i; i < h.executed.length; ++i) {
            TimelockHistory.Executed memory e = h.executed[i];
            if (e.target != target || e.data.length < 4 + argLen || bytes4(e.data) != selector) continue;
            bool same = true;
            for (uint256 j; j < argLen; ++j) {
                if (e.data[4 + j] != args[j]) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }

    function _configExplained(TimelockHistory.History memory h, address factory, bytes32 cfgHash)
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < h.executed.length; ++i) {
            TimelockHistory.Executed memory e = h.executed[i];
            if (e.target != factory || e.data.length < 4 || bytes4(e.data) != LaunchFactory.setConfig.selector) {
                continue;
            }
            if (keccak256(abi.encode(abi.decode(_args(e.data), (LaunchConfig)))) == cfgHash) return true;
        }
        return false;
    }

    /// @dev The action of the latest operation-log entry for `id` on `timelock`, or "" if none.
    function _loggedAction(string memory log, bytes32 id, address timelock) internal view returns (string memory a) {
        if (bytes(log).length == 0) return a;
        for (uint256 i; vm.keyExistsJson(log, _entry(i, "")); ++i) {
            if (vm.parseJsonBytes32(log, _entry(i, ".id")) != id) continue;
            if (vm.parseJsonAddress(log, _entry(i, ".timelock")) != timelock) continue;
            a = vm.parseJsonString(log, _entry(i, ".action"));
        }
    }

    function _entry(uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".operations[", vm.toString(i), "]", field);
    }

    function _args(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }

    function _proxyFor(System memory s, string memory name) internal pure returns (address) {
        if (_eq(name, "FeeManager")) return s.feeManager;
        if (_eq(name, "GraduationManager")) return s.gm;
        if (_eq(name, "LaunchFactory")) return s.factory;
        revert("TARGET must be FeeManager, GraduationManager or LaunchFactory");
    }

    function _newImplementation(string memory name) internal returns (address) {
        if (_eq(name, "FeeManager")) return address(new FeeManager());
        if (_eq(name, "GraduationManager")) return address(new GraduationManager());
        if (_eq(name, "LaunchFactory")) return address(new LaunchFactory());
        revert("TARGET must be FeeManager, GraduationManager or LaunchFactory");
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    /// @dev Spec section 6: the storage-layout check runs before any upgrade is scheduled. `timelock.sh` runs
    ///      `script/check-storage.sh` itself and then exports STORAGE_CHECK_PASSED=true (ffi stays disabled
    ///      project-wide). A direct `forge script --ffi` run gets the check through ffi instead; without either,
    ///      the upgrade is refused.
    function _storageGate() internal {
        if (vm.envOr("STORAGE_CHECK_PASSED", false)) {
            console2.log("storage-layout check: passed (run by timelock.sh)");
            return;
        }
        string[] memory cmd = new string[](1);
        cmd[0] = "script/check-storage.sh";
        try vm.tryFfi(cmd) returns (Vm.FfiResult memory res) {
            if (res.exitCode != 0) {
                console2.log(string(res.stderr));
                revert("storage-layout check FAILED; refusing to schedule the upgrade");
            }
            console2.log("storage-layout check: passed (ffi)");
        } catch {
            revert("storage-layout check not run: use script/timelock.sh, or run forge with --ffi");
        }
    }

    // ---------------------------------------------------------------- config input

    function _config() internal view returns (LaunchConfig memory cfg) {
        string memory path = vm.envOr("CONFIG_JSON", string(""));
        if (bytes(path).length == 0) {
            console2.log("config source      : DefaultConfig.get()");
            return DefaultConfig.get();
        }
        console2.log("config source      :", path);
        string memory json = vm.readFile(path);
        cfg.virtualUsdc = vm.parseJsonUint(json, ".virtualUsdc");
        cfg.virtualTokens = vm.parseJsonUint(json, ".virtualTokens");
        cfg.curveSupply = vm.parseJsonUint(json, ".curveSupply");
        cfg.poolSupply = vm.parseJsonUint(json, ".poolSupply");
        cfg.launchFee = vm.parseJsonUint(json, ".launchFee");
        cfg.maxInitialBuyTokens = vm.parseJsonUint(json, ".maxInitialBuyTokens");
        cfg.tradeFeeBps = _u16(json, ".tradeFeeBps");
        cfg.creatorShareBps = _u16(json, ".creatorShareBps");
        cfg.referrerShareBps = _u16(json, ".referrerShareBps");
        cfg.snipeStartBps = _u16(json, ".snipeStartBps");
        uint256 blocks = vm.parseJsonUint(json, ".snipeBlocks");
        require(blocks <= type(uint32).max, "snipeBlocks does not fit uint32");
        cfg.snipeBlocks = uint32(blocks);
    }

    function _u16(string memory json, string memory key) internal pure returns (uint16) {
        uint256 v = vm.parseJsonUint(json, key);
        require(v <= type(uint16).max, string.concat(key, " does not fit uint16"));
        return uint16(v);
    }

    // ---------------------------------------------------------------- printing

    function _printOp(Op memory op) internal pure {
        console2.log("  id               ", vm.toString(op.id));
        console2.log("  kind             ", op.kind);
        console2.log("  target           ", op.targetName, op.target);
        console2.log("  calldata hash    ", vm.toString(keccak256(op.data)));
        console2.log("  salt             ", vm.toString(op.salt));
        console2.log("  delay (s)        ", op.delay);
        if (op.newImplementation != address(0)) console2.log("  new impl         ", op.newImplementation);
        if (op.configHash != bytes32(0)) console2.log("  new configHash   ", vm.toString(op.configHash));
    }

    function _statusProxy(string memory name, address proxy, TimelockController t) internal view {
        address o = LaunchFactory(proxy).owner();
        console2.log(name, proxy);
        console2.log("  implementation   ", _implementationOf(proxy));
        console2.log("  owner is timelock:", o == address(t) ? "yes" : "NO");
        console2.log("  pendingOwner     ", LaunchFactory(proxy).pendingOwner());
    }

    function _stateName(TimelockController.OperationState st) internal pure returns (string memory) {
        if (st == TimelockController.OperationState.Waiting) return "Waiting";
        if (st == TimelockController.OperationState.Ready) return "Ready";
        if (st == TimelockController.OperationState.Done) return "Done";
        return "Unset (never scheduled, or cancelled)";
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
