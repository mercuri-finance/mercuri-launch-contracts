// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {Jsonl} from "./Jsonl.sol";
import {MirrorLog} from "./MirrorLog.sol";

/// Reverts every call with a fixed, raw revert payload (up to 32 bytes) — real bytecode, so a state-diff
/// recording session sees a genuine revert. Deployed and pointed at with `vm.mockFunction` by a scenario step
/// that needs a call to revert (e.g. a deferred graduation retry); see `_revertShim` and `MirrorLog.liveLogs`'s
/// doc for why this is used instead of `vm.mockCallRevert`. The payload is `immutable` (baked into the runtime
/// bytecode, not storage): `vm.mockFunction` runs this contract's code against the CALLEE's storage, so a
/// storage-backed reason would read back empty.
contract RevertShim {
    bytes32 private immutable reasonWord;
    uint256 private immutable reasonLen;

    constructor(bytes memory reason_) {
        require(reason_.length <= 32, "RevertShim: reason > 32 bytes");
        reasonLen = reason_.length;
        bytes32 w;
        assembly {
            w := mload(add(reason_, 32))
        }
        reasonWord = w;
    }

    fallback() external payable {
        bytes32 w = reasonWord;
        uint256 len = reasonLen;
        assembly {
            mstore(0, w)
            revert(0, len)
        }
    }
}

abstract contract ScenarioBase is V4Fixture {
    using Jsonl for *;

    string internal dir;
    string internal chainPath;
    uint256 internal txIndex;
    uint256 internal logIndex;
    address[] internal known;        // every contract whose code and state the export records
    mapping(address => uint256) internal createdAt; // creation block written to code.jsonl (replay: no code before it)
    address[] internal accounts;     // every address seen as a sender or in a log (call-table arguments)
    mapping(address => bool) internal seen;

    function _begin(string memory name) internal {
        dir = string.concat("test-export/", name, "/");
        vm.createDir(dir, true);
        chainPath = string.concat(dir, "chain.jsonl");
        if (vm.exists(chainPath)) vm.removeFile(chainPath);
        vm.deal(address(this), 1e36);
    }

    /// external so the self-call in `_emit` is a real CALL (see the comment there); pure logic otherwise, so the
    /// isolation costs only gas, which this test-only exporter does not budget for.
    function _liveLogs(Vm.Log[] memory logs, Vm.AccountAccess[] memory acc) external pure returns (Vm.Log[] memory) {
        return MirrorLog.liveLogs(logs, acc);
    }

    /// Deploys a `RevertShim` carrying `reason`. Redirect a call to it with `vm.mockFunction(target, shim, sel)`
    /// to make `target`'s call to `sel` revert with `reason` — unlike `vm.mockCallRevert`, this runs real
    /// bytecode, so `Vm.AccountAccess[].reverted` (which `_liveLogs` relies on) stays accurate.
    function _revertShim(bytes memory reason) internal returns (address) {
        return address(new RevertShim(reason));
    }

    function _see(address x) internal {
        if (x != address(0) && !seen[x]) {
            seen[x] = true;
            accounts.push(x);
        }
    }

    function _openBlock(uint256 n, uint256 time) internal {
        vm.roll(n);
        vm.warp(time);
        txIndex = 0;
        logIndex = 0;
        Jsonl.write(chainPath, string.concat('{"t":"block","n":', Jsonl.n(n), ',"time":', Jsonl.n(time), "}"));
    }

    function _emit(address from, address to, bytes memory input, Vm.Log[] memory logs, Vm.AccountAccess[] memory acc) private {
        bytes32 h = keccak256(abi.encode(block.number, txIndex));
        Jsonl.write(chainPath, string.concat('{"t":"tx","hash":', Jsonl.h32(h), ',"block":', Jsonl.n(block.number), ',"index":',
            Jsonl.n(txIndex), ',"from":', Jsonl.a(from), ',"to":', to == address(0) ? "null" : Jsonl.a(to), ',"input":', Jsonl.h(input), "}"));
        // Routed through an external self-call: via_ir's whole-program inliner otherwise merges this, MirrorLog.build
        // and the Jsonl writers below into a single Yul function and fails with "stack too deep" (this file compiles
        // at the default profile's astronomically high optimizer_runs, tuned for deployed src/ bytecode, not this
        // test-only exporter); a real CALL is a hard boundary the inliner cannot cross.
        Vm.Log[] memory live = this._liveLogs(logs, acc);
        Vm.Log[] memory out = MirrorLog.build(live, acc, from, address(this));
        for (uint256 i; i < out.length; i++) {
            Jsonl.write(chainPath, string.concat('{"t":"log","block":', Jsonl.n(block.number), ',"li":', Jsonl.n(logIndex++), ',"tx":',
                Jsonl.h32(h), ',"addr":', Jsonl.a(out[i].emitter), ',"topics":', Jsonl.topics(out[i].topics), ',"data":', Jsonl.h(out[i].data), "}"));
            for (uint256 t = 1; t < out[i].topics.length; t++) {
                if (uint256(out[i].topics[t]) >> 160 == 0) _see(address(uint160(uint256(out[i].topics[t]))));
            }
        }
        _see(from);
        txIndex++;
    }

    function _call(address from, address to, uint256 value, bytes memory data) internal returns (bytes memory ret) {
        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.prank(from);
        (bool ok, bytes memory r) = to.call{value: value}(data);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(ok, "scenario transaction reverted");
        _emit(from, to, data, logs, acc);
        return r;
    }

    /// Runs a call expected to revert. A reverted transaction is still real on a real chain — it has a hash, a
    /// sender and input — it simply has no logs and no state effect, so it is exported like any other transaction
    /// but with no logs and no account accesses (nothing moved, so no synthetic mirrors either).
    function _callExpectFail(address from, address to, uint256 value, bytes memory data) internal {
        vm.recordLogs(); // drained below regardless of outcome, so nothing leaks into the next call's recording
        vm.prank(from);
        (bool ok,) = to.call{value: value}(data);
        vm.getRecordedLogs();
        require(!ok, "scenario transaction expected to revert but succeeded");
        _emit(from, to, data, new Vm.Log[](0), new Vm.AccountAccess[](0));
    }

    /// Records a contract that exists before (or outside) the exported transactions, e.g. the PoolManager or
    /// the USDC interface, with the block from which replay-rpc serves its code.
    function _known(address a, uint256 blockNumber) internal {
        known.push(a);
        createdAt[a] = blockNumber;
    }

    function _create(address from, bytes memory initcode) internal returns (address created) {
        vm.recordLogs();
        vm.startStateDiffRecording();
        assembly {
            created := create(0, add(initcode, 0x20), mload(initcode))
        }
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(created != address(0), "scenario create failed");
        _emit(from, address(0), initcode, logs, acc);
        _known(created, block.number);
    }

    /// CREATE2 from this contract (the hook's mined salt); exported as a creation transaction of `from`.
    function _create2(address from, bytes32 salt, bytes memory initcode) internal returns (address created) {
        vm.recordLogs();
        vm.startStateDiffRecording();
        assembly {
            created := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(created != address(0), "scenario create2 failed");
        _emit(from, address(0), initcode, logs, acc);
        _known(created, block.number);
    }

    /// Writes calls-<block>.jsonl (every known contract × every selector the reconcile plan uses × every seen
    /// address) and storage-<block>.jsonl (ERC-1967 slots), then marks the snapshot in chain.jsonl. Complete by
    /// construction: the Go harness fails on any "not recorded" read.
    function _snapshot(bytes[] memory calls, address[] memory targets, address[] memory slotAddrs, bytes32[] memory slots) internal {
        string memory cp = string.concat(dir, "calls-", Jsonl.n(block.number), ".jsonl");
        string memory sp = string.concat(dir, "storage-", Jsonl.n(block.number), ".jsonl");
        for (uint256 i; i < calls.length; i++) {
            (bool ok, bytes memory ret) = targets[i].staticcall(calls[i]);
            if (!ok) continue; // the chain would revert too; the Go side treats an unrecorded call as a test failure
            Jsonl.write(cp, string.concat('{"to":', Jsonl.a(targets[i]), ',"data":', Jsonl.h(calls[i]), ',"ret":', Jsonl.h(ret), "}"));
        }
        for (uint256 i; i < slots.length; i++) {
            Jsonl.write(sp, string.concat('{"addr":', Jsonl.a(slotAddrs[i]), ',"slot":', Jsonl.h32(slots[i]), ',"value":', Jsonl.h32(vm.load(slotAddrs[i], slots[i])), "}"));
        }
        Jsonl.write(chainPath, string.concat('{"t":"snapshot","n":', Jsonl.n(block.number), "}"));
    }

    function _finish() internal {
        string memory p = string.concat(dir, "code.jsonl");
        for (uint256 i; i < known.length; i++) {
            Jsonl.write(p, string.concat('{"addr":', Jsonl.a(known[i]), ',"code":', Jsonl.h(known[i].code), ',"block":', Jsonl.n(createdAt[known[i]]), "}"));
        }
    }
}
