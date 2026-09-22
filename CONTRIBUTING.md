# Contributing

This repository is the published record of the mercuri launch contracts as deployed on Arc. Its purpose is that
anyone can read the code behind the addresses, rebuild it and check the bytecode. It is not the working repository,
so it does not take pull requests: a change to a deployed contract is a new release, made through the timelock and
recorded here afterwards with its deployment record and review.

## What is welcome

- **Security reports** — privately, through **Security → Report a vulnerability**. See [`SECURITY.md`](SECURITY.md).
- **Issues** for anything else you find: a mismatch between the code and what the README or the docs say, a
  build that does not reproduce, a link that does not resolve, an integration question (events, the API). Include
  the commit you built and, for on-chain behaviour, a transaction hash.
- **Corrections to the documentation** are welcome as issues too; they are folded into the next update.

## What happens to a pull request

It is read, and closed with a note. If it points at a real defect it becomes an issue and, where warranted, a
release; the report is credited in the release notes if you want it to be.

## Building

```sh
forge build
python3 script/verify-runtime.py
```

`forge build` uses the pinned toolchain in `foundry.toml` and the vendored `lib/` tree; nothing needs installing
beyond Foundry. The verify script needs only Python 3 and a public Arc RPC.
