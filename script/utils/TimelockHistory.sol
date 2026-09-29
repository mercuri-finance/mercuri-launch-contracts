// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Reads a TimelockController's full event history from the chain, so governance state is discovered from the
///         timelock itself (every role grant, every scheduled / executed / cancelled operation, whoever sent it), not
///         from any local file. Shared by Verify.s.sol and Timelock.s.sol.
/// @dev One `eth_getLogs` per chunk of blocks, all of the timelock's events at once (no topic filter), dispatched by
///      topic0. The Arc testnet RPC accepts ranges of up to 10,000 blocks (probed 2026-09-19: 10,000 accepted, 10,001
///      rejected with -32012 "requested range too large"), so chunks are 9,999 blocks; if a chunk is rejected anyway it
///      is retried in 9,000-block pieces before giving up.
library TimelockHistory {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant LOG_CHUNK = 9_999;
    uint256 internal constant LOG_CHUNK_FALLBACK = 9_000;

    struct RoleGrant {
        bytes32 role;
        address account;
    }

    /// @dev One `CallScheduled` event (a batch operation emits one per call, with increasing `index`).
    struct Scheduled {
        bytes32 id;
        uint256 index;
        address target;
        uint256 value;
        bytes data;
        bytes32 predecessor;
        uint256 delay;
        bytes32 salt; // from the matching `CallSalt` event; zero when none was emitted (salt == 0)
        uint256 blockNumber;
        bool cancelled; // this scheduling belongs to a cancelled lifecycle
    }

    struct Executed {
        bytes32 id;
        uint256 index;
        address target;
        uint256 value;
        bytes data;
        uint256 blockNumber;
    }

    struct History {
        RoleGrant[] grants;
        Scheduled[] scheduled;
        Executed[] executed;
        bytes32[] cancelled;
    }

    /// @dev Every event the timelock emitted in [fromBlock, latest block].
    function read(address timelock, uint256 fromBlock) internal view returns (History memory h) {
        return parse(_allLogs(timelock, fromBlock, vm.getBlockNumber()));
    }

    function parse(Vm.EthGetLogs[] memory logs) internal pure returns (History memory h) {
        uint256 nGrant;
        uint256 nSched;
        uint256 nExec;
        uint256 nCancel;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            if (t0 == IAccessControl.RoleGranted.selector) ++nGrant;
            else if (t0 == TimelockController.CallScheduled.selector) ++nSched;
            else if (t0 == TimelockController.CallExecuted.selector) ++nExec;
            else if (t0 == TimelockController.Cancelled.selector) ++nCancel;
        }
        h.grants = new RoleGrant[](nGrant);
        h.scheduled = new Scheduled[](nSched);
        h.executed = new Executed[](nExec);
        h.cancelled = new bytes32[](nCancel);
        (nGrant, nSched, nExec, nCancel) = (0, 0, 0, 0);

        for (uint256 i; i < logs.length; ++i) {
            Vm.EthGetLogs memory l = logs[i];
            bytes32 t0 = l.topics[0];
            if (t0 == IAccessControl.RoleGranted.selector) {
                h.grants[nGrant++] = RoleGrant(l.topics[1], address(uint160(uint256(l.topics[2]))));
            } else if (t0 == TimelockController.CallScheduled.selector) {
                Scheduled memory s;
                s.id = l.topics[1];
                s.index = uint256(l.topics[2]);
                (s.target, s.value, s.data, s.predecessor, s.delay) =
                    abi.decode(l.data, (address, uint256, bytes, bytes32, uint256));
                s.blockNumber = l.blockNumber;
                h.scheduled[nSched++] = s;
            } else if (t0 == TimelockController.CallSalt.selector) {
                // Emitted right after the operation's CallScheduled event(s); attach it to every call of that id.
                bytes32 id = l.topics[1];
                bytes32 salt = abi.decode(l.data, (bytes32));
                for (uint256 j; j < nSched; ++j) {
                    if (h.scheduled[j].id == id) h.scheduled[j].salt = salt;
                }
            } else if (t0 == TimelockController.CallExecuted.selector) {
                Executed memory e;
                e.id = l.topics[1];
                e.index = uint256(l.topics[2]);
                (e.target, e.value, e.data) = abi.decode(l.data, (address, uint256, bytes));
                e.blockNumber = l.blockNumber;
                h.executed[nExec++] = e;
            } else if (t0 == TimelockController.Cancelled.selector) {
                bytes32 cancelledId = l.topics[1];
                h.cancelled[nCancel++] = cancelledId;
                // Logs are ordered by block/transaction/log index, including same-block
                // cancel + reschedule. Keep history but exclude the cancelled lifecycle.
                for (uint256 j; j < nSched; ++j) {
                    if (h.scheduled[j].id == cancelledId) h.scheduled[j].cancelled = true;
                }
            }
        }
    }

    /// @dev True if `id` was scheduled as a batch (more than one call, or a call with index > 0).
    function isBatch(History memory h, bytes32 id) internal pure returns (bool) {
        uint256 calls;
        for (uint256 i; i < h.scheduled.length; ++i) {
            if (h.scheduled[i].id != id || h.scheduled[i].cancelled) continue;
            if (h.scheduled[i].index != 0) return true;
            ++calls;
        }
        return calls > 1;
    }

    /// @dev The most recent single-call scheduling of `id`, if any.
    function find(History memory h, bytes32 id) internal pure returns (bool found, Scheduled memory s) {
        for (uint256 i = h.scheduled.length; i > 0; --i) {
            if (h.scheduled[i - 1].id == id) return (true, h.scheduled[i - 1]);
        }
    }

    function _allLogs(address timelock, uint256 fromBlock, uint256 toBlock)
        private
        view
        returns (Vm.EthGetLogs[] memory all)
    {
        if (fromBlock > toBlock) return all;
        uint256 nChunks = (toBlock - fromBlock) / LOG_CHUNK + 1;
        Vm.EthGetLogs[][] memory chunks = new Vm.EthGetLogs[][](nChunks);
        uint256 total;
        uint256 c;
        for (uint256 from = fromBlock; from <= toBlock; from += LOG_CHUNK) {
            uint256 to = from + LOG_CHUNK - 1;
            if (to > toBlock) to = toBlock;
            chunks[c] = _chunk(timelock, from, to);
            total += chunks[c].length;
            ++c;
        }
        all = new Vm.EthGetLogs[](total);
        uint256 n;
        for (uint256 i; i < c; ++i) {
            for (uint256 j; j < chunks[i].length; ++j) {
                all[n++] = chunks[i][j];
            }
        }
    }

    function _chunk(address timelock, uint256 from, uint256 to) private view returns (Vm.EthGetLogs[] memory) {
        bytes32[] memory anyTopic = new bytes32[](0);
        try vm.eth_getLogs(from, to, timelock, anyTopic) returns (Vm.EthGetLogs[] memory logs) {
            return logs;
        } catch {
            // Fallback: smaller pieces. A second failure is a real RPC problem and is not swallowed.
            uint256 pieces = (to - from) / LOG_CHUNK_FALLBACK + 1;
            Vm.EthGetLogs[][] memory parts = new Vm.EthGetLogs[][](pieces);
            uint256 total;
            for (uint256 p; p < pieces; ++p) {
                uint256 a = from + p * LOG_CHUNK_FALLBACK;
                uint256 b = a + LOG_CHUNK_FALLBACK - 1;
                if (b > to) b = to;
                parts[p] = vm.eth_getLogs(a, b, timelock, anyTopic);
                total += parts[p].length;
            }
            Vm.EthGetLogs[] memory out = new Vm.EthGetLogs[](total);
            uint256 n;
            for (uint256 p; p < pieces; ++p) {
                for (uint256 j; j < parts[p].length; ++j) {
                    out[n++] = parts[p][j];
                }
            }
            return out;
        }
    }
}
