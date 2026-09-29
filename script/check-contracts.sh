#!/usr/bin/env bash
# Local release-candidate checks only. Never loads .env or broadcasts a transaction.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--stress") ]]; then
  echo "usage: bash script/check-contracts.sh [--stress]" >&2
  exit 2
fi

# Storage inspection uses a different compiler output selection; do it before the final full build.
bash script/check-storage.sh
bash script/check-storage.sh --self-test
# Build everything: integration fixtures load PositionManager from its generated artifact.
forge build
python3 script/check-natspec.py
forge test --fuzz-seed 0x5042
python3 -m unittest discover -s test/tooling -v
forge snapshot --check --match-path 'test/{unit,integration,upgrade}/*.t.sol' \
  --no-match-test '^testFuzz_' --fuzz-seed 0x5042

if [[ ${1:-} == "--stress" ]]; then
  # Inline per-test fuzz settings still override this global run count.
  FOUNDRY_FUZZ_RUNS=10000 forge test --no-match-path 'test/invariant/*' --fuzz-seed 0x5042
  campaign_dir=$(mktemp -d -t mercuri-invariant)
  echo "Invariant counterexamples, if any: $campaign_dir"
  FOUNDRY_INVARIANT_RUNS=1024 FOUNDRY_INVARIANT_DEPTH=256 \
    FOUNDRY_INVARIANT_FAIL_ON_REVERT=true \
    FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR="$campaign_dir" \
    forge test --match-path 'test/invariant/*' --fuzz-seed 0x5042002
fi
