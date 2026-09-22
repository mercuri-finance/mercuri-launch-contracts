# Vendored dependencies (committed as plain files; installed with `forge install --no-git --shallow`)

| Path | Package | Version |
| --- | --- | --- |
| `lib/forge-std` | foundry-rs/forge-std | declared 1.16.2; source revision recovered below |
| `lib/openzeppelin-contracts` | OpenZeppelin/openzeppelin-contracts | v5.4.0 |
| `lib/openzeppelin-contracts-upgradeable` | OpenZeppelin/openzeppelin-contracts-upgradeable | v5.4.0 |
| `lib/v4-periphery` | Uniswap/v4-periphery | package version 1.0.4; upstream revision not retained |
| `lib/v4-periphery/lib/v4-core` | Uniswap/v4-core | package version 1.0.2; upstream revision not retained |
| `lib/v4-periphery/lib/permit2` | Uniswap/permit2 | package version 1.0.0; upstream revision not retained |

Nested `.git` directories of sub-dependencies were removed so the files can be tracked directly; the committed tree is
the exact source every test, deployment and audit uses. The on-chain v4 PoolManager on Arc was bytecode-compared at
design time (see `docs/specs/2026-09-18-contracts-design.md` §2).

## Reproducible source identity

The following Git tree hashes pin the actual vendored bytes at repository commit
`8e902eb6b83e3c61d9af6ad8fbb4efe1431177af`. They are local tree identities, **not upstream commit SHAs**.
Package versions alone do not establish correspondence with a release audit. Before the release freeze, recover
upstream provenance or explicitly review and accept the exact vendored trees against the dependency audit scope.

| Path | Git tree |
| --- | --- |
| `lib/openzeppelin-contracts` | `cae1a139ded3e34abe47244923f76dcbbd3e3d63` |
| `lib/openzeppelin-contracts-upgradeable` | `036e55dcd1851c899e9aca4b6e988a7a3e2f245f` |
| `lib/v4-periphery` | `db186469ce4d0073d36cbdcb2f813f50152ad822` |
| `lib/v4-periphery/lib/v4-core` | `58942478c402eb64894ff9e89fe3d46c7f0973c6` |
| `lib/v4-periphery/lib/permit2` | `03bfb927d9b605a7027dfc82a5cdc2d67af8bc5d` |
| `lib/forge-std` | `15cdd0c1a5ef6796d60676119262e5a5774414b3` |

Build with Solidity 0.8.26, Cancun, via-IR and the per-path optimizer profiles in `foundry.toml`.
The reviewed executable identifies itself as Foundry 1.4.3-Homebrew, build timestamp
`2025-10-22T03:58:23Z`; it reports `VERGEN_IDEMPOTENT_OUTPUT` instead of an upstream commit.
The reviewed executable SHA-256 is `7a91e6efdcbb02203367c2c8c7e54928b7d1f3c6e636f7393c73b6201a9020c6`.
Archive/recheck the executable's SHA-256 with release evidence; do not present that placeholder as a revision.
Static analysis in the internal review used Slither 0.11.6.

Pinning does not imply absence of compiler defects. The 2026-09-21 internal review screened published advisories
against source/build settings; see [the compiler advisory screen](../docs/reports/2026-09-21-contract-readiness.md#compiler-advisory-screen).
Applicability and any compiler change require release sign-off and refreshed deployment evidence.

## Upstream comparison follow-up — 2026-09-21

[Machine-readable source comparisons](../docs/reports/2026-09-21-dependency-source-comparison.json)
recover exact Solidity-subtree correspondence for all six packages:

| Package | Upstream reference | Matching Solidity files |
| --- | --- | ---: |
| OpenZeppelin | v5.4.0 | 319 |
| OpenZeppelin upgradeable | v5.4.0 | 197 |
| v4-core | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | 84 |
| v4-periphery | `a7af5b345b479b05fde9182d7e40913a73b3e18f` | 69 |
| Permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | 16 |
| forge-std | `5e3854938622a1bc23906020aedc8ce6df61be59` | 31 |

All 91 library files in the 107-source deployment compilation map to these
comparisons. Forge-std's six differences from the v1.16.2 tag are explained by
the recovered upstream revision. No vendored file was replaced. The scope excludes
non-Solidity files and unused nested dependency trees. Source provenance does not
establish audit coverage: see [audit mapping](../docs/reports/2026-09-21-dependency-audit-mapping.json)
and [the release preparation report](../docs/reports/2026-09-21-release-preparation.md).
