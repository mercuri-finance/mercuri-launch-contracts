// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";

/// @notice Where the deployment record and the timelock operation log live, and when a script may write them. Shared
///         by Deploy, Verify and Timelock so they can never disagree about which file describes the connected chain.
/// @dev WRITE DISCIPLINE. Scripts never write the tracked record `<chainId>.json` or the operation log
///      `<chainId>-operations.json`. They write only PENDING files — `<chainId>.pending.json` (a whole record) and
///      `<chainId>-operations.pending.json` (one log entry) — and only when forge itself says this run broadcasts
///      (`forge script --broadcast`), never on the strength of an env variable. The wrappers (deploy.sh,
///      timelock.sh) promote a pending file (via script/records.py) only after the broadcast succeeded AND Verify
///      passed against it; on any failure the tracked files stay byte-identical and the pending file is renamed
///      `*.failed-<UTC time>.json`.
///      `DEPLOYMENTS_DIR` (default `./deployments`) exists ONLY for rehearsals on a local fork of the testnet (which
///      reports the same chain id, 5042002). foundry.toml grants file access to `./deployments` only, so an override
///      must be a directory beneath it. The wrappers refuse a non-default value unless the RPC is localhost, and
///      refuse localhost without one (and without FOUNDRY_NO_STORAGE_CACHING=true, because forge would otherwise
///      cache the fork's local state under the real chain id and real-looking block numbers).
library Deployments {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Arc testnet. The only chain where governance addresses may default to the deployer.
    uint256 internal constant TESTNET_CHAIN_ID = 5042002;

    function dir() internal view returns (string memory) {
        return vm.envOr("DEPLOYMENTS_DIR", string("./deployments"));
    }

    /// @dev `<dir>/<chainId>.json` — the tracked record. Read-only for scripts.
    function recordPath() internal view returns (string memory) {
        return string.concat(dir(), "/", vm.toString(block.chainid), ".json");
    }

    /// @dev `<dir>/<chainId>.pending.json` — a record written by a broadcasting run, awaiting promotion.
    function pendingRecordPath() internal view returns (string memory) {
        return string.concat(dir(), "/", vm.toString(block.chainid), ".pending.json");
    }

    /// @dev `<dir>/<chainId>-operations.json` — the operation log. Read-only for scripts.
    function operationsPath() internal view returns (string memory) {
        return string.concat(dir(), "/", vm.toString(block.chainid), "-operations.json");
    }

    /// @dev `<dir>/<chainId>-operations.pending.json` — one log entry awaiting promotion.
    function pendingOperationPath() internal view returns (string memory) {
        return string.concat(dir(), "/", vm.toString(block.chainid), "-operations.pending.json");
    }

    function isTestnet() internal view returns (bool) {
        return block.chainid == TESTNET_CHAIN_ID;
    }

    /// @dev True when forge will broadcast this run's transactions (`--broadcast` or `--resume`). Derived from forge's
    ///      own execution context, never from env. Refuses the contradictory `DRY_RUN=true` + `--broadcast`.
    function broadcasting() internal view returns (bool b) {
        b = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        require(!(b && vm.envOr("DRY_RUN", false)), "DRY_RUN=true contradicts --broadcast; refusing");
    }

    /// @dev A pending file left behind means an earlier run was never promoted or cleaned up: refuse to pile a new
    ///      one on top of it.
    function requireNoPending() internal view {
        require(!vm.exists(pendingRecordPath()), "a pending record exists; inspect it and remove or rename it first");
        require(
            !vm.exists(pendingOperationPath()),
            "a pending operation entry exists; inspect it and remove or rename it first"
        );
    }
}
