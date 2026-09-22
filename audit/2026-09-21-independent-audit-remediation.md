# Independent audit remediation — 2026-09-21

Status: local remediation of the owner's approved recommendations. No mainnet transaction,
push, hosted deployment, paid resource or DNS change. Live testnet and the separate frontend
repositories remain unchanged. This document supplements, and does not alter, the
[original Claude review](2026-09-21-independent-contract-audit.md).

## Scope and disposition

| Audit item | Local change | Remaining boundary |
| --- | --- | --- |
| L-01: mapped storage structs omitted | Schema v2 recursively records mapping keys/values, array elements and struct members. Comparator rejects reordering, removal, retyping and array element stride changes; allows compatible append-only mapped structs. Snapshots were regenerated from the original reviewed probe artifacts. | The guard is structural, not a semantic upgrade audit. Recursive type graphs fail closed for manual review. |
| L-02: weak upgrade preflight | Simulated upgrades preserve timelock ownership, zero pending owner, wiring, factory configuration/pause/treasury/guardian and FeeManager aggregate liabilities. They must leave implementation initialization disabled and allow a second upgrade. The same checks run before Safe execute calldata is printed. | Does not enumerate every mapping entry or prove future accounting correct. Deliberate migrations need a separately reviewed procedure. |
| I-01: cancelled operation counted as batch | Parser marks cancelled scheduling lifecycles and excludes them from batch detection, including same-block cancel/reschedule. | Real batches still require the dedicated/manual governance path. |
| I-02: identical hook CREATE2 front-run | Deployment wrapper and rollout checklist document retry funds, partial-deployment inspection and a fresh nonce/salt plan. | Gas/time grief remains possible. No automatic resume or change to permissionless CREATE2 semantics. |
| I-03: runtime identity | `deploy.sh` requires a read-only exact byte comparison for the hook, locker and three implementations after Verify and before record promotion. Immutable address words are reconstructed, not ignored. Reads pin a block and check its hash again. | Requires the reviewed build artifacts and correct RPC. A mismatch keeps the record unpromoted; broadcast transactions cannot be undone. |
| D-01: unbounded hook rate | `MAX_POOL_FEE_BPS = 500` and a clamp in the shared fee formula. Current DefaultConfig remains 100 bps (1%). | Ceiling rounding in 6-decimal units still applies to dust. FeeManager can still revert or change arbitrary accounting; this is not a guarantee of liveness or protection against every malicious governance action. |

Only `LaunchHook.sol` changes protocol executable behavior in this remediation. The other
production contract sources, dependency revisions, compiler pin and default fees are unchanged.
AST output is enabled solely to resolve immutable references for runtime comparison. The hook
init code changes, so old mined hook addresses are obsolete. The actual deployer rehearsal
must mine again using the final build and current nonce; no mainnet address is invented here.

## Validation

- Full isolated Solidity suite: **190 passed, 0 failed** (179 existing plus 11 new), seed `0x5042`.
  This is the ordinary suite, including the default 64 × 64 invariants, not the deferred long campaign.
- New hook coverage: all four swap shapes × both currency orderings at 500, 501, 10,000 and
  65,535 bps; zero, 1, 100 and 499 bps preserve expected lower fees. Above-cap rates match
  the 500 bps settlement and fee ledger exactly.
- Nine new tooling Solidity tests cover good upgrades of all three proxies, wrong namespace,
  disabled future upgrades, unlocked initialization, Safe execution preflight, cancel/reschedule,
  real batches and local runtime export. No Safe deployment/recovery rehearsal was repeated.
- **12 Python checks pass**, including the CLI matching actual locally deployed code for all five
  targets through a localhost RPC fixture, and rejecting a tampered hook. No live RPC was used.
- The auditor's original `fm_orig.json` passes; its `fm_mut.json` now exits **1** with
  `FeeManager.tokens.value: member(s) removed`. All three real storage-layout comparisons pass,
  as do the four prior comparator self-tests and seven new storage regressions.
- NatSpec: **107 ABI entries, zero failures**. Changed Solidity formatting, shell syntax and
  Git whitespace checks pass.
- [Refreshed compiler evidence](2026-09-21-audit-remediation-compiler-evidence.json): **107 source
  identities; all 10 creation/runtime targets reproduced exactly** with pinned solc 0.8.26.
  The screened named-error/Yul recursion triggers remain absent. Only LaunchHook and the Deploy
  script embedding it differ from the prior evidence. Hook runtime grows **3,390 → 3,448 bytes**;
  its creation code grows **4,126 → 4,185 bytes**. The other eight targets retain identical bytecode.
- Gas baseline reviewed before update: 155 existing cases retained, two new hook cases added.
  Of existing cases, 35 rise by **22–220 test gas units**; 120 stay identical. These small changes
  are consistent with the clamp and changed hook dispatch; they include fixture/assertion cost and
  are not a mainnet fee estimate. The refreshed 157-case snapshot check passes.

During validation, the first test invocation lacked PositionManager's artifact; a full build resolved
that known pinned-toolchain fixture requirement. A new test's narrow integer expected-value calculation
also overflowed; widening that test calculation to uint256 resolved it. Neither required an additional
protocol behavior change. Failed and final logs are retained for traceability.
Evidence is retained under `.release-evidence/mainnet-2026-09-21/audit-remediation/`.
The isolated workspace contains selected public sources only and runs with a clean process environment;
it does not load repository `.env` files, inherit signing material, or access live RPC.

The original audit report SHA-256 is
`6b7bd72f19d1c35898d19358649eb60241a7930dda3bba330aaafded53375d9f`.
Its original candidate manifest and compiler evidence are preserved as historical audit inputs.
The new hook and tooling are subsequent changes, not retroactively covered by that report.

## Local release identity

Implementation checkpoint: `f9ab5a18ce26e4303ce33c79419f488a144c2175` on
`release/mainnet-preparation-2026-09-21`. The original three preparation commits are retained;
local `main` remains at `8e902eb6b83e3c61d9af6ad8fbb4efe1431177af`. Nothing was pushed.

[Refreshed candidate manifest](2026-09-21-audit-remediation-candidate-manifest.json):
**3122 selected source/config files**, with every current file and archive member checked.
Source manifest SHA-256: `227f3d9cff4d6c1cf327774f6ac250ad75b129fcc5b933c6c8a8fd6488a896d9`.
Archive SHA-256: `e4d4896285388eda8c1b48b2e5f8d6445ad5962100ed723267878de40e1e16bc`.
The manifest records separate frontend Git identities without archiving or editing their working trees.

## Release boundary and next step

The owner's “yes to all your recommendations” authorizes these local fixes and their local
checkpoint. It does not constitute blanket acceptance of the remaining risks or permission to
broadcast mainnet transactions. The independent review is an agent review, not a professional
external audit certification.

Remaining release decisions include governance/accounting/liveness trust, permanently locked
liquidity without migration, external dependency/compiler scope limits, referral revenue leakage,
software signer/device risk and the other risks listed in the original review. The next contract
step is review of this refreshed candidate and the release decision, followed by the actual
funded deployer's no-broadcast rehearsal with the approved Safe addresses and 48-hour delay.
The deployer is `0x36E5f6AE800846DBf5cCd271f7fe47a9e056b595`; the last verified balance was
1,200.757452 USDC, not a new balance observation in this remediation.

Do not repeat completed Safe/recovery tests or long load campaigns. For application rollout,
0014 then 0015 must precede the candidate API. Dedicated backend-admin software wallets remain
separate from governance signers. Preserve existing testnet records/services and current frontend UI work.
