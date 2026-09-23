---
name: mercuri-contract-release
description: Review a Mercurifi contract change against the canonical deployed contracts, audit evidence and network-specific release runbooks before any deployment.
---

# Contract release review

Read `CLAUDE.md` here, compare this separate repo with parent `../contracts/`, and read the parent `docs/handoff/mainnet-handover.md`, `docs/runbooks/mainnet-application.md` and current audit reports. Run local compiler/Foundry checks and inspect source hashes, manifest, storage layout and gas changes. Prepare a reviewable release record before seeking broadcast or governance approval. Do not infer authorization from a dry-run or application release.
