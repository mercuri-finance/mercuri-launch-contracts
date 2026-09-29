// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";

/// @dev Inserts synthetic native-USDC mirror Transfer logs the way Arc's node emits them (§3.1, §10.1).
///      Positions are plausible, not authoritative: the golden receipts pin real positions and the decoding
///      invariance test guarantees no rule depends on them.
library MirrorLog {
    address internal constant MIRROR = address(uint160(type(uint160).max - 1)); // 0xffff…fffe
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    /// A call frame that reverts leaves no trace on a real chain: revert unwinds its logs along with its state
    /// changes, even when an enclosing `try/catch` (or a checked low-level `.call()`) catches it and the outer
    /// transaction still succeeds — e.g. BondingCurve's deferred-graduation retry, whose `executeGraduation()`
    /// reverts and is caught by `_buy`. `vm.recordLogs()`/`vm.getRecordedLogs()` do not retroactively drop logs
    /// emitted inside such a reverted sub-call, so this walks the recorded logs against the state diff's
    /// per-call `reverted` flag (`Vm.AccountAccess`), in execution order, and drops any log whose owning call
    /// reverted, matching what a real node's receipt would contain.
    ///
    /// Matching a log to the call that emitted it: consecutive account accesses of "enters a new call" kinds
    /// (Call/DelegateCall/CallCode/StaticCall/Create) occur in the same relative order as the logs emitted
    /// inside them, so walking both lists with a single forward-only cursor, advancing on the first unconsumed
    /// access whose account equals the log's emitter, recovers that call's reverted status. A log with no such
    /// access ahead of the cursor (e.g. one emitted directly by a still-open, non-reverted caller after a
    /// caught revert, with no intervening call to re-anchor on) is kept, matching a real receipt.
    ///
    /// Relies on `Vm.AccountAccess[].reverted` being accurate. `vm.mockCallRevert` corrupts it (every access
    /// recorded from that point on in the same `vm.startStateDiffRecording` session reports `reverted: true`,
    /// even ones that plainly committed) — a scenario that needs a call to revert should deploy a tiny contract
    /// that actually reverts and redirect to it with `vm.mockFunction`, not `vm.mockCallRevert`, or this filter
    /// will drop far more than the reverted frame.
    function liveLogs(Vm.Log[] memory logs, Vm.AccountAccess[] memory acc) internal pure returns (Vm.Log[] memory out) {
        bool anyReverted;
        for (uint256 i; i < acc.length; i++) {
            if (acc[i].reverted) {
                anyReverted = true;
                break;
            }
        }
        if (!anyReverted) return logs; // common case: nothing reverted anywhere in this transaction

        bool[] memory keep = new bool[](logs.length);
        uint256 kept;
        uint256 a;
        for (uint256 j; j < logs.length; j++) {
            while (a < acc.length && !(_entersCall(acc[a].kind) && acc[a].account == logs[j].emitter)) a++;
            if (a < acc.length) {
                keep[j] = !acc[a].reverted;
                a++;
            } else {
                keep[j] = true;
            }
            if (keep[j]) kept++;
        }
        out = new Vm.Log[](kept);
        uint256 k;
        for (uint256 j; j < logs.length; j++) {
            if (keep[j]) out[k++] = logs[j];
        }
    }

    function _entersCall(VmSafe.AccountAccessKind kind) private pure returns (bool) {
        return kind == VmSafe.AccountAccessKind.Call || kind == VmSafe.AccountAccessKind.DelegateCall
            || kind == VmSafe.AccountAccessKind.CallCode || kind == VmSafe.AccountAccessKind.StaticCall
            || kind == VmSafe.AccountAccessKind.Create;
    }

    function _mirror(address from, address to, uint256 value) private pure returns (Vm.Log memory l) {
        l.topics = new bytes32[](3);
        l.topics[0] = TRANSFER;
        l.topics[1] = bytes32(uint256(uint160(from)));
        l.topics[2] = bytes32(uint256(uint160(to)));
        l.data = abi.encode(value);
        l.emitter = MIRROR;
    }

    function build(Vm.Log[] memory logs, Vm.AccountAccess[] memory acc, address from, address self)
        internal
        pure
        returns (Vm.Log[] memory out)
    {
        // before[j] counts mirrors inserted before log j; tail counts those appended after the last log.
        uint256[] memory before = new uint256[](logs.length);
        Vm.Log[] memory pending = new Vm.Log[](acc.length);
        uint256[] memory slot = new uint256[](acc.length); // insertion index (logs.length = tail)
        uint256 m;
        uint256 p;
        for (uint256 i; i < acc.length; i++) {
            if (acc[i].reverted || acc[i].value == 0) continue;
            address src = acc[i].accessor == self ? from : acc[i].accessor;
            uint256 j = p;
            while (j < logs.length && logs[j].emitter != acc[i].account) j++;
            pending[m] = _mirror(src, acc[i].account, acc[i].value);
            slot[m] = j;
            if (j < logs.length) {
                before[j]++;
                p = j;
            }
            m++;
        }
        uint256 extra = m;
        for (uint256 j; j < logs.length; j++) {
            if (logs[j].emitter == USDC && logs[j].topics.length == 3 && logs[j].topics[0] == TRANSFER) extra++;
        }
        out = new Vm.Log[](logs.length + extra);
        uint256 k;
        for (uint256 j; j <= logs.length; j++) {
            for (uint256 x; x < m; x++) {
                if (slot[x] == j) out[k++] = pending[x];
            }
            if (j == logs.length) break;
            if (logs[j].emitter == USDC && logs[j].topics.length == 3 && logs[j].topics[0] == TRANSFER) {
                uint256 v = abi.decode(logs[j].data, (uint256));
                out[k++] = _mirror(address(uint160(uint256(logs[j].topics[1]))), address(uint160(uint256(logs[j].topics[2]))), v * 1e12);
            }
            out[k++] = logs[j];
        }
        assembly {
            mstore(out, k)
        }
    }
}
