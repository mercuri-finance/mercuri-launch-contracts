#!/usr/bin/env bash
# The ONLY supported way to broadcast script/Deploy.s.sol (the upgradeable, timelock-governed system).
#
# Usage: ./script/deploy.sh [--dry-run] [--no-env] [--isolated-testnet]      (from contracts/)
#   --dry-run   simulate only: nothing is broadcast and nothing is written under deployments/
#   --no-env    do not source ../.env; use only variables already exported in the calling shell
#   --isolated-testnet  explicit live candidate under deployments/candidates/<id>; requires --no-env
#
# Inputs (env): DEPLOYER_PRIVATE_KEY, POOL_MANAGER, POSITION_MANAGER, PERMIT2 (mandatory); EXPECTED_CHAIN_ID
# (derived only when the RPC reports the testnet); PROPOSER, EXECUTOR, GUARDIAN, TREASURY, TIMELOCK_DELAY —
# on the testnet each defaults to the deployer / 60 s; on any other chain all five are mandatory, the delay
# must be >= 172800 s (48 h), and none of the four addresses may be the deployer. On every chain the delay is at
# most 2592000 s (30 days).
#
# RECORDS: Deploy.s.sol writes only deployments/<chainId>.pending.json. This wrapper verifies the broadcast against
# it and only then promotes it (script/records.py: archive the previous record and operation log, move the pending
# record into place). On any failure the tracked record and archive stay byte-identical and the pending file is
# renamed *.failed-<UTC time>.json. DEPLOYMENTS_DIR redirects this for local forks or explicit isolated-testnet candidates.
#
# RUNBOOK: never use `forge script ... --resume` after any other transaction has been sent from the
# deployer account (this script's own retries included). The CREATE address predictions inside
# Deploy.s.sol are computed from the deployer's nonce at the start of the run; if the nonce has moved
# since then (e.g. from a `--resume`'d partial broadcast, or any unrelated transaction), the predicted
# addresses will not match what actually gets deployed and the script's `require`s will revert. Always
# re-run the whole script from a clean nonce instead of resuming. One deployer key = one purpose: never
# reuse this key for anything else.
# The permissionless CREATE2 deployer also permits an identical-init-code front-run.
# This cannot substitute a different hook, but can abort a deployment after earlier
# transactions succeeded. Budget for a fresh attempt; inspect orphaned addresses,
# archive the failed record, and start a newly mined nonce plan. Never use --resume.
#
# KEY HYGIENE: this wrapper never passes $DEPLOYER_PRIVATE_KEY as an argument to any command — a value in
# a process's argv is visible to any other process on the machine via `ps`. It is only ever tested for
# emptiness (`-z`, a shell builtin, not a subprocess argv) and left in the environment for `forge script`
# to read directly via `vm.envUint`, which reads the environment, not argv. The deployer address/balance
# are logged, and the low-balance gate is enforced, inside Deploy.s.sol itself for the same reason — do
# not reintroduce a `cast wallet address --private-key ...` / `cast balance` call here.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=script/common.sh
source script/common.sh

if [[ "${1:-}" == "--selftest" ]]; then
    echo "Self-test: bignum_lt(v, 1 USDC = 1e18 wei) — no network required"
    MIN_BALANCE=1000000000000000000
    for v in 0 999999999999999999 1000000000000000000 20000000000000000000 \
        123456789012345678901234567890; do
        result="$(bignum_lt "$v" "$MIN_BALANCE")"
        if [[ "$result" -eq 1 ]]; then
            verdict="below 1 USDC"
        else
            verdict="at/above 1 USDC"
        fi
        echo "  $v -> $verdict"
    done
    exit 0
fi

DRY_RUN_FLAG=0
USE_ENV=1
ISOLATED_TESTNET_FLAG=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN_FLAG=1 ;;
        --no-env) USE_ENV=0 ;;
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

# OWNER is obsolete: the owner of all three proxies is now always the freshly deployed timelock. Refuse rather
# than silently ignore it, so an old .env that meant "owner = my multisig" cannot deploy with the deployer as
# proposer instead.
if [[ -n "${OWNER:-}" ]]; then
    echo "Refusing to run: OWNER is obsolete (the timelock owns the system). Set PROPOSER / EXECUTOR instead and remove OWNER." >&2
    exit 1
fi
unset_if_empty OWNER PROPOSER EXECUTOR GUARDIAN TREASURY TIMELOCK_DELAY DEPLOYMENTS_DIR \
    EXPECTED_PROPOSER EXPECTED_CANCELLER EXPECTED_EXECUTOR EXPECTED_GUARDIAN EXPECTED_TREASURY EXPECTED_TIMELOCK_DELAY \
    EXPECTED_TIMELOCK EXPECTED_CONFIG_HASH

if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" || -z "${POOL_MANAGER:-}" || -z "${POSITION_MANAGER:-}" || -z "${PERMIT2:-}" ]]; then
    echo "Refusing to run: DEPLOYER_PRIVATE_KEY, POOL_MANAGER, POSITION_MANAGER and PERMIT2 must all be set." >&2
    exit 1
fi

# Kept for the scripts' contradiction check only: whether a run broadcasts is decided by forge itself (`--broadcast`),
# and DRY_RUN=true together with `--broadcast` is refused. Always set explicitly — never inherited.
if [[ "$DRY_RUN_FLAG" -eq 1 ]]; then
    export DRY_RUN=true
else
    export DRY_RUN=false
fi

guard_chain
rehearsal_guard

# M7 (every chain): the delay is at most 30 days.
if [[ -n "${TIMELOCK_DELAY:-}" ]]; then
    if [[ ! "$TIMELOCK_DELAY" =~ ^[0-9]+$ || "$(bignum_lt 2592000 "$TIMELOCK_DELAY")" -eq 1 ]]; then
        echo "Refusing to run: TIMELOCK_DELAY must be an integer <= 2592000 (30 days); got $TIMELOCK_DELAY." >&2
        exit 1
    fi
fi

# Upgradeability design §3 (pre-mainnet gate): off the testnet all five governance inputs must be set explicitly and
# the delay must be at least 48 h. Deploy.s.sol itself then refuses — in simulation and broadcast alike — any of
# PROPOSER / EXECUTOR / GUARDIAN / TREASURY being the deployer (it knows the deployer address without the key ever
# reaching an argv).
if [[ "$RPC_CHAIN_ID" != "$TESTNET_CHAIN_ID" ]]; then
    for name in PROPOSER EXECUTOR GUARDIAN TREASURY TIMELOCK_DELAY; do
        if [[ -z "${!name:-}" ]]; then
            echo "Refusing to run: on chain $RPC_CHAIN_ID, $name must be set explicitly." >&2
            exit 1
        fi
    done
    if [[ "$(bignum_lt "$TIMELOCK_DELAY" 172800)" -eq 1 ]]; then
        echo "Refusing to run: on chain $RPC_CHAIN_ID, TIMELOCK_DELAY must be >= 172800 (48 h); got $TIMELOCK_DELAY." >&2
        exit 1
    fi
fi

RECORD="$DEPL_DIR/$RPC_CHAIN_ID.json"
PENDING="$DEPL_DIR/$RPC_CHAIN_ID.pending.json"
if [[ "$ISOLATED_TESTNET_FLAG" == "1" && -e "$RECORD" ]]; then
    echo "Refusing: candidate record already exists; choose a fresh run directory." >&2
    exit 1
fi
if [[ -e "$PENDING" ]]; then
    echo "Refusing to run: $PENDING exists (an earlier run was never promoted). Inspect it, then remove or rename it." >&2
    exit 1
fi

compute_gas_price

BROADCAST_FLAG="--broadcast"
if [[ "$DRY_RUN_FLAG" -eq 1 ]]; then
    BROADCAST_FLAG=""
    echo "Dry run: simulating only, not broadcasting, writing nothing."
fi

# shellcheck disable=SC2086
if ! forge script script/Deploy.s.sol --rpc-url "$ARC_RPC" $BROADCAST_FLAG --slow --with-gas-price "$PRICE"; then
    if [[ "$DRY_RUN_FLAG" -eq 1 ]]; then
        echo "DRY RUN FAILED (nothing was sent, nothing was written)." >&2
        exit 1
    fi
    keep_failed_pending "$RPC_CHAIN_ID"
    cat >&2 <<MSG

DEPLOYMENT FAILED: forge exited non-zero (in simulation or during the broadcast).
  * The tracked record $RECORD and the archive are UNCHANGED.
  * If the failure happened during the broadcast, some transactions may have landed: their hashes are in
    broadcast/Deploy.s.sol/$RPC_CHAIN_ID/run-latest.json. Those contracts are orphaned; nothing points at them.
  * The unpromoted record (if one was written) was kept above as *.failed-<time>.json for forensics only.
RECOVERY: fix the cause, then re-run ./script/deploy.sh from the start. NEVER use 'forge script --resume': the
address predictions are made from the deployer's nonce at the start of a run, and the nonce may have moved.
MSG
    exit 1
fi

if [[ "$DRY_RUN_FLAG" -eq 1 ]]; then
    exit 0
fi

if [[ ! -f "$PENDING" ]]; then
    echo "DEPLOYMENT ANOMALY: the broadcast succeeded but no pending record was written at $PENDING." >&2
    echo "The tracked record $RECORD is unchanged. Investigate before any further use." >&2
    exit 1
fi

# H2 / I2: the broadcast is only done when the deployed system reads back correctly from the chain — verified against
# the PENDING record, with the operator's inputs as expectations — and only then does the record become the truth.
echo "Verifying the deployed system on-chain against the pending record..."
export_expectations
if ! VERIFY_PENDING=true forge script script/Verify.s.sol --rpc-url "$ARC_RPC"; then
    keep_failed_pending "$RPC_CHAIN_ID"
    cat >&2 <<MSG

DEPLOYMENT VERIFICATION FAILED: the broadcast landed but the on-chain wiring or governance is wrong.
  * The tracked record $RECORD and the archive are UNCHANGED; the new addresses were NOT published.
  * The unverified record was kept above as *.failed-<time>.json for investigation.
Do NOT use or publish those addresses. Investigate; then re-run ./script/deploy.sh from the start.
MSG
    exit 1
fi

# Compare every hook/locker/implementation byte, reconstructing constructor immutables.
# A wiring-compatible but unreviewed implementation must never become canonical.
if ! ARC_RPC="$ARC_RPC" python3 script/verify-runtime.py --record "$PENDING"; then
    keep_failed_pending "$RPC_CHAIN_ID"
    echo "RUNTIME VERIFICATION FAILED: do not publish or use these addresses; record not promoted." >&2
    exit 1
fi

# --confirmed: this wrapper has just seen the broadcast succeed AND Verify and exact runtime checks pass against the pending record.
if ! python3 script/records.py promote-deploy "$DEPL_DIR" "$RPC_CHAIN_ID" --confirmed; then
    cat >&2 <<MSG

THE BROADCAST SUCCEEDED AND VERIFY PASSED, BUT THE RECORD PROMOTION DID NOT COMPLETE (diagnosis above).
  * Do NOT re-run deploy.sh: the system is deployed; only the files need finishing.
  * Re-run: python3 script/records.py promote-deploy $DEPL_DIR $RPC_CHAIN_ID --confirmed
MSG
    exit 1
fi
echo "Deployment verified and recorded in $RECORD."
