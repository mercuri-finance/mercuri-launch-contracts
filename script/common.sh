# shellcheck shell=bash
# Shared by deploy.sh and timelock.sh — sourced, never executed. Callers run with `set -euo pipefail` from the
# contracts/ directory.
#
# KEY HYGIENE: nothing in here ever expands $DEPLOYER_PRIVATE_KEY into a command's argv (visible to any process via
# `ps`). It is only ever tested for emptiness with `-z` (a shell builtin) and left in the environment for
# `forge script` to read via `vm.envUint`.

TESTNET_CHAIN_ID=5042002

if ! command -v python3 >/dev/null 2>&1; then
    echo "Refusing to run: python3 is required (arbitrary-precision wei-scale arithmetic)." >&2
    exit 1
fi

# Native USDC and gas-price*2 values routinely exceed bash's 64-bit SIGNED integer range (max
# ~9223372036854775807, i.e. ~9.22e18 wei / ~9.22 USDC): `[[ -lt ]]` and `$(( ))` on such values fail
# with "value too great for base" under `set -e`. Do all wei-scale comparisons/arithmetic with
# arbitrary-precision python3 instead of bash integer ops.
bignum_lt() {
    python3 -c "import sys; print(1 if int(sys.argv[1]) < int(sys.argv[2]) else 0)" "$1" "$2"
}

bignum_mul() {
    python3 -c "import sys; print(int(sys.argv[1]) * int(sys.argv[2]))" "$1" "$2"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Loads ../.env when present and $1 is 1. Already-exported variables win when --no-env is passed, or when
# ../.env does not exist, so the wrappers stay testable with a throwaway key exported in the caller's shell.
load_env() {
    if [[ "$1" -eq 1 && -f ../.env ]]; then
        set -a
        # shellcheck disable=SC1091
        source ../.env
        set +a
    fi
    # H3: the RPC variable is ARC_RPC. ARC_TESTNET_RPC is still accepted as a fallback because existing .env
    # files (which these scripts must never read out loud, only source) still carry the old name.
    : "${ARC_RPC:=${ARC_TESTNET_RPC:-https://rpc.testnet.arc.io}}"
}

# Some forge versions may treat a variable that is SET-BUT-EMPTY differently from UNSET when resolving
# `vm.envOr(...)`. Unset each named variable outright when it is empty so the scripts always see a
# genuinely-unset variable and fall back to their defaults deterministically.
unset_if_empty() {
    local name
    for name in "$@"; do
        if [[ -z "${!name:-}" ]]; then
            unset "$name"
        fi
    done
}

# H3: establish which chain we are actually pointed at BEFORE anything else. EXPECTED_CHAIN_ID is mandatory,
# with exactly one convenience: if the RPC itself reports the known testnet id, derive-and-confirm it. On any
# other chain the operator has to say so explicitly, which is the whole point of the guard. Sets RPC_CHAIN_ID.
guard_chain() {
    RPC_CHAIN_ID=$(cast chain-id --rpc-url "$ARC_RPC")
    if [[ -z "${EXPECTED_CHAIN_ID:-}" ]]; then
        if [[ "$RPC_CHAIN_ID" == "$TESTNET_CHAIN_ID" ]]; then
            EXPECTED_CHAIN_ID="$TESTNET_CHAIN_ID"
            echo "EXPECTED_CHAIN_ID not set; RPC reports the known testnet ($TESTNET_CHAIN_ID), using that."
        else
            echo "Refusing to run: EXPECTED_CHAIN_ID must be set explicitly (RPC reports chain $RPC_CHAIN_ID)." >&2
            exit 1
        fi
    fi
    export EXPECTED_CHAIN_ID
    if [[ "$RPC_CHAIN_ID" != "$EXPECTED_CHAIN_ID" ]]; then
        echo "Refusing to run: RPC chain $RPC_CHAIN_ID != EXPECTED_CHAIN_ID $EXPECTED_CHAIN_ID." >&2
        exit 1
    fi
}

# Design §2: scripts set maxFeePerGas >= 20 gwei (Arc's floor). Use max(2 x current, 30 gwei), and never
# go below the 20 gwei floor even if the RPC reports something implausibly low. Needs no key. Sets PRICE.
compute_gas_price() {
    local current floor min doubled
    current=$(cast gas-price --rpc-url "$ARC_RPC")
    floor=20000000000   # 20 gwei
    min=30000000000     # 30 gwei
    doubled=$(bignum_mul "$current" 2)
    if [[ "$(bignum_lt "$min" "$doubled")" -eq 1 ]]; then
        PRICE=$doubled
    else
        PRICE=$min
    fi
    if [[ "$(bignum_lt "$PRICE" "$floor")" -eq 1 ]]; then
        echo "Refusing to run: computed gas price $PRICE is below Arc's 20 gwei floor." >&2
        exit 1
    fi
    echo "Current gas price: $current wei; using: $PRICE wei"
}

# Exports EXPECTED_<NAME> from <NAME> for Verify.s.sol when the caller supplied <NAME> and did not already set
# EXPECTED_<NAME> — so the post-broadcast verification checks the chain against what the operator asked for,
# not only against the record the deploy wrote. Unset inputs stay unset (Verify then uses the recorded value,
# which it only allows on the testnet).
export_expectations() {
    local name
    for name in PROPOSER EXECUTOR GUARDIAN TREASURY TIMELOCK_DELAY; do
        local exp="EXPECTED_${name}"
        if [[ -z "${!exp:-}" && -n "${!name:-}" ]]; then
            export "$exp=${!name}"
        fi
    done
}

# M1 — rehearsal safety. A local fork of the testnet reports the SAME chain id (5042002) as the testnet, so:
#   * against a remote RPC, DEPLOYMENTS_DIR must be unset (or ./deployments): the tracked records are the truth;
#   * against localhost, DEPLOYMENTS_DIR must point somewhere else under ./deployments (the real record must never be
#     touched by a rehearsal), and FOUNDRY_NO_STORAGE_CACHING=true must be exported (otherwise forge caches the fork's
#     local state under the real chain id and real-looking block numbers).
# --isolated-testnet additionally permits HTTPS chain 5042002 with a separate candidate directory.
# Sets DEPL_DIR.
rehearsal_guard() {
    local host dir
    host=$(python3 -c "import sys, urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).hostname or '')" "$ARC_RPC")
    dir="${DEPLOYMENTS_DIR:-./deployments}"
    # N2: compare canonical absolute paths, so "./deployments/.", "$PWD/deployments", "deployments/../deployments"
    # or a symlink to it can never pass as a rehearsal directory.
    local canon_dir canon_default
    canon_dir=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dir")
    canon_default=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "./deployments")
    local is_default=0
    if [[ "$canon_dir" == "$canon_default" ]]; then is_default=1; fi
    # Explicit live-candidate exception. Never applies to mainnet or a local fork,
    # and never permits the canonical directory (including path/symlink aliases).
    if [[ "${ISOLATED_TESTNET_FLAG:-0}" == "1" ]]; then
        if [[ "$RPC_CHAIN_ID" != "$TESTNET_CHAIN_ID" || "$EXPECTED_CHAIN_ID" != "$TESTNET_CHAIN_ID" ||
              "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
            echo "Refusing: --isolated-testnet requires the real Arc testnet, chain 5042002." >&2
            exit 1
        fi
        if [[ "$ARC_RPC" != https://* ]]; then
            echo "Refusing: --isolated-testnet requires an HTTPS RPC." >&2
            exit 1
        fi
        DEPL_DIR=$(python3 script/candidate_path.py --dir "$dir")
        export DEPLOYMENTS_DIR="$DEPL_DIR"
        echo "ISOLATED TESTNET: records go to $DEPL_DIR; canonical records are excluded."
        return
    fi
    if [[ "$host" == "127.0.0.1" || "$host" == "localhost" || "$host" == "::1" ]]; then
        if [[ "$is_default" -eq 1 ]]; then
            echo "Refusing to run: the RPC is localhost (a fork?) but DEPLOYMENTS_DIR is the tracked ./deployments." >&2
            echo "  Set: export DEPLOYMENTS_DIR=./deployments/rehearsal FOUNDRY_NO_STORAGE_CACHING=true" >&2
            exit 1
        fi
        if [[ "${FOUNDRY_NO_STORAGE_CACHING:-}" != "true" ]]; then
            echo "Refusing to run: the RPC is localhost; forge's RPC storage cache must be off for a fork." >&2
            echo "  Set: export FOUNDRY_NO_STORAGE_CACHING=true   (and start anvil with --no-storage-caching)" >&2
            exit 1
        fi
        echo "REHEARSAL: localhost RPC; records go to $dir (not ./deployments)."
    elif [[ "$is_default" -eq 0 ]]; then
        echo "Refusing to run: DEPLOYMENTS_DIR=$dir is only allowed against a localhost RPC (rehearsals)." >&2
        echo "  Unset it: unset DEPLOYMENTS_DIR" >&2
        exit 1
    fi
    DEPL_DIR="$dir"
}

# Renames any unpromoted pending file to *.failed-<UTC time>.json. $1 = chain id.
keep_failed_pending() {
    python3 script/records.py fail "$DEPL_DIR" "$1"
}
