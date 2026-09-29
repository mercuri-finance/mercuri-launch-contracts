---
name: mercuri-contract-release
description: Review a Mercurifi contract change against the canonical deployed contracts, audit evidence and network-specific release runbooks before any deployment.
---

# Contract release review

Read `AGENTS.md` here and the workspace's `docs/handoff/mainnet-handover.md`, `docs/runbooks/mainnet-application.md` and current audit reports. This repo is the canonical Launch contract checkout, normally at `contracts/launch`; Trade lives in a separate private repo. Run `bash script/check-contracts.sh` and inspect source hashes, manifest, storage layout and gas changes. Prepare a reviewable release record before asking for any broadcast or governance approval. Do not infer authorization from a dry-run or application release.
