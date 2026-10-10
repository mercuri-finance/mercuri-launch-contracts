# Contributing

This public repository owns the Mercurifi Launch contracts as deployed on Arc, including their tests and release
tooling. Anyone can read the code behind the addresses, rebuild it and check the bytecode. A change to a deployed
contract requires a new reviewed release and the applicable timelock process. Pull requests are reviewed, but
merging one never authorizes a contract transaction.

## What is welcome

- **Security reports** — privately, through **Security → Report a vulnerability**. See [`SECURITY.md`](SECURITY.md).
- **Issues** for anything else you find: a mismatch between the code and what the README or the docs say, a
  build that does not reproduce, a link that does not resolve, an integration question (events, the API). Include
  the commit you built and, for on-chain behaviour, a transaction hash.
- **Corrections to the documentation** are welcome as issues too; they are folded into the next update.

## What happens to a pull request

Changes are reviewed against the deployed source, storage layout, tests and release evidence. A merged change
does not alter deployed contracts. Security reports belong in the private reporting channel above.

## Building

```sh
forge build
bash script/check-contracts.sh
# Read-only runtime check after a build, with a matching deployment record:
ARC_RPC=<your RPC URL> python3 script/verify-runtime.py --record deployments/5042.json
```

`forge build` uses the pinned toolchain in `foundry.toml` and the vendored `lib/` tree. The contract gate also
needs Python 3. The runtime verifier reads the RPC URL from the process environment, checks the chain ID and
compares every runtime byte, including reconstructed immutable values, at one pinned block.
