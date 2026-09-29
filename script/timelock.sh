#!/usr/bin/env bash
# The ONLY supported way to run script/Timelock.s.sol (governance runbook, upgradeability design §6).
#
# Usage (from contracts/):
#   MODE=status                                   ./script/timelock.sh [--no-env]
#   MODE=schedule-config [CONFIG_JSON=<file>]     ./script/timelock.sh [--dry-run] [--no-env] [--safe]
#   MODE=schedule-upgrade TARGET=<FeeManager|GraduationManager|LaunchFactory>
#                                                 ./script/timelock.sh [--dry-run] [--no-env] [--safe]
#   MODE=execute OP_ID=0x...                      ./script/timelock.sh [--dry-run] [--no-env] [--safe]
#   MODE=cancel  OP_ID=0x...                      ./script/timelock.sh [--dry-run] [--no-env] [--safe]
#   MODE=sync                                     ./script/timelock.sh [--dry-run] [--no-env]
#
#   --isolated-testnet  requires --no-env and a non-live candidate record; upgrades are forbidden.
#   --dry-run   simulate only: nothing is broadcast and nothing is written under deployments/
#   --no-env    do not source ../.env; use only variables already exported in the calling shell
#   --safe      the role is held by a multisig: nothing needing the role is sent; the exact timelock calldata
#               (schedule / execute / cancel, with the operation id) is PRINTED for the multisig to submit.
#               Proposals are recorded in the operation log as `proposed-offchain`. schedule-upgrade still deploys
#               the new implementation from DEPLOYER_PRIVATE_KEY (any funded key).
#
# status and execute discover operations from the timelock's own logs, so operations scheduled by anyone (e.g. the
# multisig) are seen; status flags any open operation missing from the operation log as UNKNOWN ORIGIN.
# After a broadcast `execute`, and on MODE=sync, the record's implementation addresses / config hash are brought in
# line with the chain (only for changes an executed timelock operation explains), verified, then promoted.
# After a multisig executes an operation, run MODE=sync.
#
# CONFIG_JSON must be a file under ./deployments (the only directory forge scripts may read): one JSON object with
# a decimal-string field per LaunchConfig member, by member name.
# schedule-upgrade first runs script/check-storage.sh and refuses to continue if the storage layout of any proxied
# contract lost, reordered or retyped a field.
#
# RECORDS: the forge script writes only pending files; this wrapper promotes them (script/records.py) after the
# broadcast succeeded (and Verify passed, for a record). On failure the tracked files stay byte-identical and the
# pending files are renamed *.failed-<UTC time>.json.
#
# KEY HYGIENE: as in deploy.sh, DEPLOYER_PRIVATE_KEY is only ever tested for emptiness and read by the forge script
# from the environment — never put on any argv.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=script/common.sh
source script/common.sh

DRY_RUN_FLAG=0
USE_ENV=1
SAFE_FLAG=0
ISOLATED_TESTNET_FLAG=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN_FLAG=1 ;;
        --no-env) USE_ENV=0 ;;
        --safe) SAFE_FLAG=1 ;;
        --isolated-testnet) ISOLATED_TESTNET_FLAG=1 ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

if [[ "$ISOLATED_TESTNET_FLAG" == "1" && "$USE_ENV" != "0" ]]; then
    echo "Refusing: --isolated-testnet requires --no-env." >&2
    exit 1
fi
load_env "$USE_ENV"
unset_if_empty CONFIG_JSON OP_SALT DEPLOYMENTS_DIR \
    EXPECTED_PROPOSER EXPECTED_CANCELLER EXPECTED_EXECUTOR EXPECTED_GUARDIAN EXPECTED_TREASURY EXPECTED_TIMELOCK_DELAY \
    EXPECTED_TIMELOCK EXPECTED_CONFIG_HASH

MODE="${MODE:-}"
case "$MODE" in
    status | schedule-config | sync) ;;
    schedule-upgrade)
        case "${TARGET:-}" in
            FeeManager | GraduationManager | LaunchFactory) ;;
            *)
                echo "Refusing to run: MODE=schedule-upgrade needs TARGET=FeeManager|GraduationManager|LaunchFactory." >&2
                exit 1
                ;;
        esac
        ;;
    execute | cancel)
        if [[ ! "${OP_ID:-}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
            echo "Refusing to run: MODE=$MODE needs OP_ID=0x<64 hex digits>." >&2
            exit 1
        fi
        ;;
    *)
        echo "Refusing to run: MODE must be one of status, schedule-config, schedule-upgrade, execute, cancel, sync." >&2
        exit 1
        ;;
esac
export MODE

# Always set explicitly — never inherited — so a stale value in the caller's shell cannot change behaviour.
if [[ "$SAFE_FLAG" -eq 1 ]]; then export SAFE_MODE=true; else export SAFE_MODE=false; fi
if [[ "$DRY_RUN_FLAG" -eq 1 ]]; then export DRY_RUN=true; else export DRY_RUN=false; fi
unset STORAGE_CHECK_PASSED VERIFY_PENDING

# A key is needed only to send something: never for status / sync; in --safe mode only to deploy an implementation.
NEEDS_KEY=1
case "$MODE" in
    status | sync) NEEDS_KEY=0 ;;
    schedule-config | execute | cancel)
        if [[ "$SAFE_FLAG" -eq 1 ]]; then NEEDS_KEY=0; fi
        ;;
esac
if [[ "$NEEDS_KEY" -eq 1 && -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
    echo "Refusing to run: DEPLOYER_PRIVATE_KEY (the signer) must be set for MODE=$MODE." >&2
    exit 1
fi

guard_chain
rehearsal_guard
RECORD="$DEPL_DIR/$RPC_CHAIN_ID.json"
if [[ "$ISOLATED_TESTNET_FLAG" == "1" ]]; then
    if [[ "$MODE" == "schedule-upgrade" ]]; then
        echo "Refusing: candidate validation does not authorize upgrades." >&2
        exit 1
    fi
    python3 script/candidate_path.py --dir "$DEPL_DIR" --check-record >/dev/null
fi

if [[ "$MODE" == "status" ]]; then
    forge script script/Timelock.s.sol --rpc-url "$ARC_RPC"
    exit 0
fi

for f in "$DEPL_DIR/$RPC_CHAIN_ID.pending.json" "$DEPL_DIR/$RPC_CHAIN_ID-operations.pending.json"; do
    if [[ -e "$f" ]]; then
        echo "Refusing to run: $f exists (an earlier run was never promoted). Inspect it, then remove or rename it." >&2
        exit 1
    fi
done

# Upgradeability design §6: the storage-layout guard runs before any upgrade is scheduled. ffi stays disabled
# project-wide; this wrapper runs the check itself and tells the script it passed.
if [[ "$MODE" == "schedule-upgrade" ]]; then
    echo "Running the storage-layout check before scheduling an upgrade..."
    if ! ./script/check-storage.sh; then
        echo "Refusing to schedule: the storage-layout check failed." >&2
        exit 1
    fi
    export STORAGE_CHECK_PASSED=true
fi

compute_gas_price

# Every non-dry run is a `--broadcast` run, even when it sends nothing (sync, --safe proposals): the scripts write
# their pending files only in forge's broadcast context.
BROADCAST_FLAG="--broadcast"
if [[ "$DRY_RUN_FLAG" -eq 1 ]]; then
    BROADCAST_FLAG=""
    echo "Dry run: simulating only, not broadcasting, writing nothing."
fi

# What has already changed by the time a step fails — so the failure message says exactly that, never more or less.
CHAIN_CHANGED=0   # a broadcast of this run succeeded
OPLOG_CHANGED=""  # description of the entry appended to the operation log, if any

failed() {
    keep_failed_pending "$RPC_CHAIN_ID"
    {
        echo
        echo "$1"
        if [[ "$CHAIN_CHANGED" -eq 1 ]]; then
            echo "  * CHANGED on chain: this run's transaction(s) DID land (see the forge output above)."
        else
            echo "  * Chain: this run's broadcast did not complete (it failed in simulation or while broadcasting);"
            echo "    check the forge output above for any transaction hash that did land."
        fi
        if [[ -n "$OPLOG_CHANGED" ]]; then
            echo "  * CHANGED: the operation log $DEPL_DIR/$RPC_CHAIN_ID-operations.json (appended: $OPLOG_CHANGED)."
        else
            echo "  * UNCHANGED: the operation log $DEPL_DIR/$RPC_CHAIN_ID-operations.json."
        fi
        echo "  * UNCHANGED: the tracked record $RECORD (it is only replaced as the very last step)."
        echo "  * Any unpromoted file was kept above as *.failed-<time>.json for investigation."
        echo "  * The timelock is the source of truth: MODE=status shows what is scheduled / executed; once the cause"
        echo "    is fixed, MODE=sync brings the record in line with the chain."
    } >&2
    exit 1
}

# Brings the record in line with the chain after an executed operation, verifies it, and promotes it.
sync_record() {
    echo "Syncing the record with the chain..."
    if ! MODE=sync forge script script/Timelock.s.sol --rpc-url "$ARC_RPC" --broadcast; then
        failed "SYNC FAILED: the record could not be brought in line with the chain (see the reason above)."
    fi
    if [[ -f "$DEPL_DIR/$RPC_CHAIN_ID.pending.json" ]]; then
        if ! VERIFY_PENDING=true forge script script/Verify.s.sol --rpc-url "$ARC_RPC"; then
            failed "VERIFICATION FAILED against the synced record: investigate before any further governance action."
        fi
        if ! python3 script/records.py promote-sync "$DEPL_DIR" "$RPC_CHAIN_ID" --confirmed; then
            echo "VERIFY PASSED AGAINST THE SYNCED RECORD, BUT IT WAS NOT PROMOTED: see the diagnosis above." >&2
            exit 1
        fi
    else
        if ! forge script script/Verify.s.sol --rpc-url "$ARC_RPC"; then
            failed "VERIFICATION FAILED: investigate before any further governance action."
        fi
    fi
    echo "Record in sync with the chain and verified."
}

if [[ "$MODE" == "sync" ]]; then
    if [[ "$DRY_RUN_FLAG" -eq 1 ]]; then
        MODE=sync forge script script/Timelock.s.sol --rpc-url "$ARC_RPC"
        exit 0
    fi
    sync_record
    exit 0
fi

# shellcheck disable=SC2086
if ! forge script script/Timelock.s.sol --rpc-url "$ARC_RPC" $BROADCAST_FLAG --slow --with-gas-price "$PRICE"; then
    if [[ "$DRY_RUN_FLAG" -eq 1 ]]; then
        echo "DRY RUN FAILED (nothing was sent, nothing was written)." >&2
        exit 1
    fi
    failed "TIMELOCK OPERATION FAILED: forge exited non-zero (in simulation or during the broadcast)."
fi

if [[ "$DRY_RUN_FLAG" -eq 1 ]]; then
    exit 0
fi

# In --safe mode only schedule-upgrade sends anything (the implementation deployment).
if [[ "$SAFE_FLAG" -eq 0 || "$MODE" == "schedule-upgrade" ]]; then CHAIN_CHANGED=1; fi
if [[ -f "$DEPL_DIR/$RPC_CHAIN_ID-operations.pending.json" ]]; then
    ENTRY=$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); print(e.get("action"), e.get("id"))' \
        "$DEPL_DIR/$RPC_CHAIN_ID-operations.pending.json")
    if ! python3 script/records.py append-op "$DEPL_DIR" "$RPC_CHAIN_ID" --confirmed; then
        echo "THE RUN SUCCEEDED BUT ITS LOG ENTRY ($ENTRY) WAS NOT APPENDED: see the diagnosis above." >&2
        exit 1
    fi
    OPLOG_CHANGED="$ENTRY"
fi

if [[ "$MODE" == "execute" && "$SAFE_FLAG" -eq 0 ]]; then
    sync_record
fi
