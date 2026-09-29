#!/usr/bin/env bash
# Storage-layout guard for the three proxied contracts (spec section 7).
#
# `forge inspect <Contract> storageLayout --json` reports an EMPTY layout for FeeManager, GraduationManager and
# LaunchFactory themselves: their whole state lives in one ERC-7201 namespaced struct reached through an
# inline-assembly accessor, never through an actual declared state variable, and solc only emits "types" entries
# for a struct that backs a real declared state variable (confirmed the same is true of OpenZeppelin's own
# upgradeable contracts, e.g. OwnableUpgradeable, which uses the identical pattern). So this script instead
# inspects the tiny probe contracts in test/utils/upgrade/StorageLayoutProbe.sol, each of which declares exactly
# one throwaway state variable of the real namespaced struct type, purely so the struct's member list (label,
# offset, slot, type) shows up in `forge inspect`'s "types" section.
#
# Modes:
#   ./script/check-storage.sh            compare each contract's current layout against its snapshot; exits
#                                         non-zero with a clear message if any snapshot member was removed,
#                                         reordered or retyped, including mapped structs and array element stride.
#   ./script/check-storage.sh --update   (re)write contracts/storage-layouts/<Contract>.json from the current
#                                         build.
#   ./script/check-storage.sh --self-test
#                                         runs the comparator's own negative/positive self-tests (a hand-built
#                                         reordered-field layout, which MUST fail) — no Solidity compile
#                                         involved, so this is fast and toolchain-independent.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE="${1:-check}"
SNAP_DIR="storage-layouts"

if [[ "$MODE" == "--self-test" ]]; then
  python3 script/check_storage_diff.py --self-test
  PYTHONPATH=test/tooling python3 -m unittest test_release_guards.StorageTests -v
  exit 0
fi

if [[ "$MODE" != "check" && "$MODE" != "--update" ]]; then
  echo "usage: $0 [--update|--self-test]" >&2
  exit 2
fi

mkdir -p "$SNAP_DIR"

# contract name -> its layout-probe contract (test/utils/upgrade/StorageLayoutProbe.sol)
CONTRACTS=(FeeManager GraduationManager LaunchFactory)
probe_for() {
  case "$1" in
    FeeManager) echo "FeeManagerLayoutProbe" ;;
    GraduationManager) echo "GraduationManagerLayoutProbe" ;;
    LaunchFactory) echo "LaunchFactoryLayoutProbe" ;;
  esac
}

STATUS=0
for CONTRACT in "${CONTRACTS[@]}"; do
  PROBE=$(probe_for "$CONTRACT")
  SNAP_FILE="$SNAP_DIR/$CONTRACT.json"
  TMP_NEW="$(mktemp -t "check-storage-${CONTRACT}")"

  if ! forge inspect "$PROBE" storageLayout --json | python3 script/extract_storage_snapshot.py "$CONTRACT" > "$TMP_NEW"; then
    echo "FAILED to extract the current storage layout for $CONTRACT" >&2
    rm -f "$TMP_NEW"
    STATUS=1
    continue
  fi

  if [[ "$MODE" == "--update" ]]; then
    mv "$TMP_NEW" "$SNAP_FILE"
    echo "updated $SNAP_FILE"
    continue
  fi

  if [[ ! -f "$SNAP_FILE" ]]; then
    echo "no snapshot for $CONTRACT at $SNAP_FILE — run '$0 --update' first" >&2
    rm -f "$TMP_NEW"
    STATUS=1
    continue
  fi

  if python3 script/check_storage_diff.py "$SNAP_FILE" "$TMP_NEW"; then
    :
  else
    STATUS=1
  fi
  rm -f "$TMP_NEW"
done

exit "$STATUS"
