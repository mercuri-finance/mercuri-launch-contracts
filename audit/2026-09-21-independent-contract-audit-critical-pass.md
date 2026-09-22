# Mercuri Launch — independent contract review, critical second pass (revision 2), 2026-09-21

> **How to read this file.** The original revision-1 report is preserved unchanged at
> [`2026-09-21-independent-contract-audit.md`](2026-09-21-independent-contract-audit.md) (SHA-256 `6b7bd72f…375d9f`, as
> recorded by the remediation report). This file is self-contained: §1–§8 repeat revision 1 for context; **§9 is the
> critical pass and §10 reviews the remediated candidate.** Where they disagree, §9/§10 win.
>
> **Which code was reviewed.** §1–§9 were performed on the **original** candidate (source manifest `0c0bbc00…88c53`).
> While the critical pass was running, a separate owner-authorized session remediated the revision-1 findings and
> produced a **refreshed candidate** (source manifest `227f3d9c…896d9`, commit `f9ab5a1`), changing `LaunchHook.sol`
> (500 bps fee clamp) and release tooling. §10 covers that delta. I briefly edited the original report in place before
> noticing it had been committed and hash-referenced; I restored it byte-for-byte and moved my text here.

**Reviewer:** fresh AI agent session (Claude), no involvement in the earlier review or remediation.
**Nature of this document:** additional assurance from an independent agent review. It is **not** a professional
external audit certification, not risk acceptance and not release approval; those belong to the owner.

## Summary (revision 2 — after the critical second pass, strict external-audit grading)

The owner asked whether the first pass had been lenient and then requested a more critical audit. Revision 2 adds
§9 (critical pass) and **regrades everything on a strict scale**. Where revision 1 and revision 2 disagree, revision 2 wins.

- **Still no exploitable defect.** Four adversarial reviewers (curve/factory, hook/v4 settlement, graduation/custody,
  fee ledger/system) plus my own work produced about 85 new tests, >300,000 fuzz/invariant calls on the real v4 stack and 97
  meaningful mutants. Nobody could extract funds, create unbacked fee credit, block exits, move locked liquidity,
  pre-initialize a pool, or find a factory-accepted config that cannot graduate.
- **Regraded / new contract-level items:** M-01 (was D-01) hook has no fee ceiling — **Medium** (trust/centralization in
  an immutable contract); L-03 graduation deferral can be **forced at will** by any final buyer (griefing, recoverable);
  L-04 the curve's `g0/63` out-of-gas backstop is **dead code** and its NatSpec overstates it; L-05 referral binding is
  keyed to `msg.sender`, so a shared router/smart-account is captured by its first user.
- **The test evidence is weaker than both earlier reports implied** (verified by me): TA-01 the USDC shim's transfers
  **survive reverted calls** under Foundry 1.4.3; TA-02 in the default configuration the invariant handler's assertions are
  swallowed — a `claim` that never zeroes the balance passes all four invariants (it *is* caught under `--stress`);
  TA-03 17 of 97 meaningful mutants survive the existing suite, including fee-rounding direction in the immutable hook
  and three checks in the immutable locker; TA-04 one existing fuzz test is flaky and hidden by fixed seeds.
- **Recommendation on the strict scale: further evidence required before mainnet — not "stop for a defect".** See §9.6,
  and §10.4 for how the remediation changes it (M-01 is now fixed and verified; the rest stands).

I was asked to be impartial and to weigh tradeoffs in the context of a launchpad. Revision 1 labelled design choices as
tradeoffs; revision 2 keeps the launchpad context but grades the way an external firm would.

---

## 1. Reviewed identity, tools, scope

| Item | Value |
| --- | --- |
| Repository / baseline | `<workspace>`, commit `8e902eb6b83e3c61d9af6ad8fbb4efe1431177af`, **working tree** (uncommitted candidate) |
| Candidate manifest | `docs/reports/2026-09-21-release-candidate-manifest.json`; `sourceManifestSha256` recomputed = `0c0bbc009d1038c4e93d85bbfa7b3cc27aec7483fcb07e6285f42e36bea88c53` ✔ |
| Source archive | `.release-evidence/mainnet-2026-09-21/candidate-sources.tar.gz`, SHA-256 `ffc7804e…278f3` ✔; all 3,119 members match the manifest; **working tree vs manifest: 0 drifted, 0 missing** |
| Compiler evidence | `docs/reports/2026-09-21-release-compiler-evidence.json`: all 107 source hashes match the working tree (**no drift**) |
| Bytecode reproduction | My isolated build reproduced creation **and** runtime SHA-256 for all 10 targets (7 protocol contracts, `TimelockController` [`small` profile], `ERC1967Proxy`, `Deploy`) |
| Toolchain | Foundry `forge/cast 1.4.3-Homebrew` (binary SHA-256 `7a91e6ef…020c6`, matches `lib-versions.md`), solc `0.8.26+commit.8a97fa7a`, Cancun, via-IR, per-path optimizer profiles from `foundry.toml` (src = 200 runs), Python 3.13.7. Revision 1 did not run Slither; **revision 2 installed Slither 0.11.6 in a scratch virtualenv and re-ran it** (§9.2). |
| Executable delta vs baseline commit | Exactly two executable lines: `FeeManager.registerToken` `tradeFeeBps_ >= BPS` rejection, and `LaunchHook.afterSwap` widen-before-negate. Everything else in `src/` is NatSpec/formatting. |

**In scope (read in full by me):** `src/{LaunchFactory,LaunchToken,BondingCurve,FeeManager,GraduationManager,LaunchHook,LiquidityLocker}.sol`,
`src/libraries/*`, `src/interfaces/*`, `script/{DefaultConfig,Deploy.s,Verify.s}.sol`, `script/utils/{HookMiner,Deployments}.sol`,
`script/{deploy,common}.sh`, test fixtures/shim/mocks, and the reachable parts of vendored v4-core (`Hooks`, `PoolManager`
swap/sync/settle/take, `Pool.swap` zero-amount path) and v4-periphery `PositionManager` (mint, payer mapping, Permit2 pull).

**Delegated to a sub-reviewer, claims I relied on re-verified by me:** `Timelock.s.sol`, `timelock.sh`, `TimelockHistory.sol`,
`records.py`, storage-layout guard, upgrade tests. Compiler/dependency advisory research (web, primary sources).

**Omitted / not re-done:** backend, frontend, infrastructure; Safe contracts and the completed Safe/recovery tests;
long invariant/capacity campaigns (I ran the default 64×64 campaigns once; revision 2 added a new 98,304-call real-stack
campaign instead of repeating the old one);
bytecode-level audit of the canonical on-chain Uniswap/Permit2/USDC deployments (I compared code hashes only, §5);
Arc node internals.

---

## 2. Findings

Severity reflects impact on **user funds and the immutable contracts**. This section is the revision-1 list (tooling and
deployment items, all still valid). **The strict regrade and the new contract-level items (M-01, L-03, L-04, L-05, TA-01…TA-04)
are in §9.**

### L-01 — Storage-layout guard does not inspect structs stored as mapping values (`TokenInfo`) — **proven, tooling only**

- **Where:** `contracts/script/extract_storage_snapshot.py:31-34` (expands a struct only when `encoding == "inplace"`),
  consumed by `check_storage_diff.py` and `check-storage.sh`; snapshot `storage-layouts/FeeManager.json` records
  `tokens` only as the label `mapping(address => struct IFeeManager.TokenInfo)`.
- **Root cause:** the guard never descends into mapping/array value types, so member order, offsets and removals inside
  `IFeeManager.TokenInfo` are invisible to it. `TokenInfo` is the only such struct today (`LaunchConfig` is in-place and covered).
- **Who / preconditions:** not attacker-reachable. It matters when governance prepares a FeeManager upgrade whose
  `TokenInfo` was edited (reordered, field removed/inserted mid-struct). `Timelock.s.sol` `_preflight` (lines 420-431)
  only checks that the upgrade call does not revert, so nothing else in the tool chain would catch it.
- **Impact:** after such an upgrade every registered token's `curve`/`creator`/`tradeFeeBps`/shares would be misread:
  curves fail `accrueTradeFee` authorization (all curve buys/sells revert), creator fees are credited to wrong addresses,
  and the immutable hook reads a garbage pool fee rate. Recoverable by another timelocked upgrade (≥48 h) if
  upgradeability itself survived.
- **Reproduction (run by me):** take forge's `storageLayout` for the FeeManager probe, swap `curve`/`creator` inside
  `TokenInfo` and delete `tradeFeeBps`, then
  `python3 script/extract_storage_snapshot.py FeeManager < fm_mut.json > mut.snap.json && python3 script/check_storage_diff.py storage-layouts/FeeManager.json mut.snap.json`
  → prints `OK: FeeManager storage layout is a valid append-only evolution`, exit `0`.
  Inputs/outputs: `.release-evidence/mainnet-2026-09-21/independent-contract-audit/storage-guard-gap/`.
- **Fix:** recurse into mapping value types and array base types when building the snapshot; regenerate the three
  snapshots; add a negative self-test with a mutated mapping-value struct.
- **Regression requirement:** the mutated `TokenInfo` layout above must make `check-storage.sh` exit non-zero.
- **Release relevance:** does **not** affect the v1.0 deployment (no prior layout exists). Must be fixed before the first
  FeeManager upgrade is scheduled.

### L-02 — Upgrade preflight asserts only "call did not revert" — **confirmed by reading, hardening**

- **Where:** `contracts/script/Timelock.s.sol:420-431`; `execute --safe` path performs no simulation at all (`:200-209`).
- **Why it matters here specifically:** the immutable hook and every immutable curve call the FeeManager proxy on every
  trade (D-01). An upgrade that silently zeroes state (edited ERC-7201 constant), breaks `_authorizeUpgrade`, or loses
  ownership would pass the preflight. If upgradeability is lost at the same time, the freeze is permanent and the locked
  pools can never trade through the official hook again. OpenZeppelin's `upgradeToAndCall` does reject non-UUPS and
  code-less implementations (tested in `Upgrades.t.sol:323-346`), so the residual is a *wrong-but-UUPS* implementation.
- **Fix:** inside the snapshot, after the simulated upgrade, assert `owner()==timelock`, `pendingOwner()==0`, wiring
  getters and (factory) `configHash` unchanged, implementation initializers disabled, and that a second
  `upgradeToAndCall` to the same implementation still succeeds; run the same simulation in `execute --safe`.
- **Regression requirement:** a V2 mock with a changed namespace constant, and one whose `_authorizeUpgrade` always
  reverts, must both be refused by `schedule-upgrade`.
- Not a v1.0 deployment blocker; do before the first upgrade.

### I-01 — Timelock tool refuses `execute`/`cancel` for an id that was cancelled and re-scheduled — **confirmed by reading**

`TimelockHistory.isBatch` (`script/utils/TimelockHistory.sol:110-118`) counts `CallScheduled` logs per id, so a second
scheduling of the same id (possible only when `OP_SALT` is deliberately reused after a cancel) is misclassified as a
batch and `_fromChain` (`Timelock.s.sol:541`) refuses it. Workaround: different salt, or a direct Safe call. Fix: ignore
schedulings that precede the most recent `Cancelled` for that id.

### I-02 — Hook CREATE2 deployment can be griefed (no fund risk)

`Deploy.s.sol` deploys the hook through the permissionless deterministic deployer (`0x4e59…956C`). Anyone who sees the
pending transaction can deploy the *identical* init code + salt first (same address, same code, same immutables). The
deployer's transaction then reverts, forge stops, and the runbook correctly says to abandon the run and restart from a
fresh nonce plan. Cost: gas for ≤4 orphaned contracts and time. Nothing can be hijacked: the CREATE2 address binds the
init code, proxies initialize atomically in their constructors, implementations are locked. Operational note: fund
the one-purpose deployer for more than one attempt or have a second deployer ready.

### I-03 — Verify does not compare deployed runtime bytecode with the reviewed build

`Verify.s.sol` checks wiring, proxy/timelock stock code hashes, initializer state, roles and config, but not that the
hook, locker and three implementations equal the artifacts in the compiler evidence (immutables masked). The earlier
review did this comparison manually for testnet. Make it a required post-deploy step for mainnet (operational
prerequisite, not a code defect).

---

## 3. Design tradeoffs assessed (not defects) — consequences stated

### D-01 (regraded **M-01, Medium** in §9.3) — Immutable hook and curves depend on the upgradeable FeeManager for liveness; hook also for its **rate**

- **Code:** `LaunchHook.sol:108,134,140` read `feeManager.tradeFeeBps(token)` on every swap; `:182-183` `take` then
  `notifyHookFee`. `BondingCurve.sol:224,326-327` forward fees with `accrueTradeFee` / `accruePlatform`.
  The curve's own rate is an immutable (`tradeFeeBps`, `BondingCurve.sol:65`); the hook's is not.
- **Unprivileged attacker:** none. Current FeeManager has no rate setter; rates are fixed at registration (≤500 bps by
  factory policy, <10,000 by FeeManager).
- **Malicious or faulty governance upgrade (excluded by the threat model — consequences):** (a) a new FeeManager can
  return any rate <10,000 bps for **existing** pools, i.e. divert up to ~99.99 % of the USDC leg of every swap on pools
  whose liquidity is locked forever, with 48 h notice (and the delay itself is changeable through the same path);
  (b) a rate ≥10,000 or any revert in `tradeFeeBps`/`notifyHookFee`/`accrueTradeFee` freezes all pool swaps and all
  curve buys **and sells**; (c) if that upgrade also loses upgradeability (see L-02) the freeze is permanent.
  Locked liquidity can never be *withdrawn* by anyone — that guarantee holds — but it can be taxed or frozen.
- **Launchpad context:** this is a stronger posture than fully-upgradeable launchpads, and the timelock gives an exit
  window while exits still work. It is weaker than designs whose immutable hook carries its own fee ceiling.
- **Optional hardening, only possible before the hook is deployed:** clamp in the hook's single `_fee` path, e.g.
  `if (bps > MAX_POOL_FEE_BPS) bps = MAX_POOL_FEE_BPS;` with an immutable constant (500 matches factory policy; any
  value <10,000 also removes the division-by-zero/underflow dependency on FeeManager behaviour). ~1 line, negligible gas,
  and it turns "governance can tax locked pools arbitrarily" into "governance can tax them up to X %".
  I considered and do **not** recommend wrapping FeeManager calls in `try/catch` (fail-open): it adds surface to immutable
  code and could mask accounting faults. If the clamp is adopted: re-mine the hook address, refresh compiler evidence,
  add tests for clamp at/above the cap in all four swap shapes.
- **Owner decision required either way** (accept, or add the clamp).

### D-02 — Unauthenticated `hookData` and referrals: what it can and cannot do

`hookData` selects whose **already-bound** referrer earns `referrerShareBps` of a pool fee (`LaunchHook.sol:172-185`,
`FeeManager.sol:169-174,235-248`). It never binds, never marks a wallet as traded (tested). The referral share comes
**only out of the platform bucket**: creator share, trader cost and pool pricing are unaffected. Therefore any router
or trader can pre-bind a wallet pair (`bindReferrer`) and name it on every swap, capturing up to `referrerShareBps`
(20 % of the fee under DefaultConfig) that would otherwise go to the platform. The same self-referral is available on the
curve with two wallets. Effect: platform revenue leakage bounded by `referrerShareBps`; no user harm. Accept as designed,
or lower `referrerShareBps` if the leakage matters commercially.

### D-03 — Graduation failure handling

Verified by reading and by test against the real GraduationManager/v4 stack (`test_deferThenExitThenRegraduate_realStack`):
a reverted graduation rolls back completely (tokens and reserve stay in the curve), holders can sell while pending,
any non-zero-proceeds sell reopens trading, and the next completing buy graduates at the curve's final price. The gas
floor/`g0/63` heuristic (`BondingCurve.sol:331-346`) fails closed (whole buy reverts) rather than half-completing.
No permanent-DoS path for an unprivileged attacker: only the GraduationManager can initialize a pool with this hook
(`LaunchHook.sol:90-93`, tested), pool keys are deterministic, token donations cannot move the opening price
(`GraduationManager.sol:211`), and forced native balance on the curve is swept to the platform without touching pricing.
Residual: if graduation is persistently broken (governance/dependency), late buyers' only exit is selling back down the
curve at a fee loss. The 1,000,000 gas floor is immutable and was calibrated to the current implementation.

### D-04 — Stranded donations

ERC-20 USDC or forced native value sent to the GraduationManager stays there (recoverable only by an upgrade); sent to
the hook or locker it is unrecoverable. Nobody but the donor loses. FeeManager has `sweepUnaccounted` (tested, including
mid-claim re-entry).

### D-05 — Other approved designs, confirmed as implemented

Guardian pause covers `createToken` only (and the guardian can also *un*pause); timelock is self-administered with
admin `address(0)` and deploy-time ≥48 h, changeable later through itself; deployer is refused for every role off
testnet (`Deploy.s.sol:151-155`) and holds no role afterwards; Factory upgrade can change the `curveOf` registry the
GraduationManager trusts (a malicious upgrade could pre-initialize a not-yet-graduated token's pool or redirect future
graduations — governance trust); persistent max allowances to canonical Permit2/PositionManager are only exercisable
with the GraduationManager as `msgSender()` of `modifyLiquidities`, and the manager holds no funds between graduations.

---

## 4. Reassessment of the earlier review

| Earlier item | My view |
| --- | --- |
| FeeManager rejects `tradeFeeBps >= 10,000` at registration | **Agree**, correct and tested at 0/9,999/10,000. As that report says, it does not bind a future implementation; only a hook-side clamp (D-01) would. |
| Hook widens `int128` before negation | **Agree**, the fix is right (`uint256(-int256(raw))`); the old form truncated only at `int128.min`, which is not economically reachable. |
| Invariant handler seed normalization | **Agree**; `HandlerBoundaries` passes in my isolated run. |
| Slither `arbitrary-send-eth` (FeeManager `_send`) | **Agree**: pull payment of the caller's own balance or to `factory.treasury()`, CEI + transient guard. My `test_claimCallbackCannotDesyncLedger` re-enters from the payee (trades on a curve, attempts `sweepUnaccounted`) and the ledger stays exactly backed. |
| `incorrect-equality` ×4, `unused-return` ×3, `uninitialized-local`, `timestamp` ×2 | **Agree** with each disposition. |
| `reentrancy-no-eth` ×2 / `reentrancy-events` ×2 in graduation | **Agree**, with the reason made explicit: there is no callback surface today — `LaunchToken` has no transfer hooks, `PositionManager` mints with `_mint` (not `_safeMint`), the hook has no liquidity callbacks enabled, and Arc's USDC `transfer` moves balance without calling the recipient (per the public arc-node source on `main`; not verified against the mainnet binary). Curves hold their transient guard across the whole graduation. |
| `missing-zero-check` ×3 on immutable constructors | **Agree** that Verify's wiring checks cover it; add the runtime-bytecode comparison (I-03). |
| Compiler advisory screen | **Agree.** Independently re-derived from `bugs_by_version.json`: five entries cover 0.8.26 (SOL-2026-6, -4, -2, -5, SOL-2025-1); none is triggerable here (no named-argument `require`, zero recursive Yul components in an independent SCC scan of all deployed contracts, legacy-pipeline-only, no storage arrays). SOL-2026-1 (transient clearing) starts at 0.8.28 and needs `transient` variables — not applicable. |
| Dependency screen | OpenZeppelin 5.4.0: only GHSA-9rcw-c2f9-2j55 (`Bytes.lastIndexOf`), unreachable. No published advisories for v4-core, v4-periphery, Permit2 or Foundry. The v4-core fix for the native/ERC-20 duality drain (OpenZeppelin audit, Critical, PR #779 → `NonzeroNativeValue`) **is present** in the vendored `PoolManager._settle` and the on-chain PoolManager code hash is identical on Arc testnet and mainnet. 20 spot-hashed dependency files match the stated upstream revisions. |
| "179 tests / 1,048,576 handler calls" | Reproduced 179/179 (plus my 7) at seed `0x5042`. I agree with that report's own caveat: handler calls ≠ successful trades, and coverage of `GraduationManager` branches was low in the baseline measurement. My added tests target those gaps (snipe-window final buy, real-stack deferral, initial-buy graduation). |

I found nothing the earlier review dismissed that I would escalate. What it did not identify: L-01, L-02, I-01, and the
asymmetry in D-01 (stated there as general governance trust, without noting the curve pins its rate and the hook does not).

---

## 5. Commands actually run and results

Isolated workspace: `…/scratchpad/audit-ws/contracts`, extracted **only** from the hash-verified archive (no `.env`,
no credentials, no `broadcast/` or `out/`), built and tested with `env -i HOME PATH FOUNDRY_OFFLINE=true` so no signing
material could be inherited. No production file, compiler pin, dependency or gas baseline was changed.
PoC sources and logs are persisted (git-ignored) at
`.release-evidence/mainnet-2026-09-21/independent-contract-audit/`.

| # | Command (abridged) | Result |
| --- | --- | --- |
| 1 | Python: recompute `sourceManifestSha256`, archive SHA-256, per-file hashes of working tree and archive members | all match; 0 drift |
| 2 | Python: 107 compiler-evidence source hashes vs working tree | 0 drift |
| 3 | `forge build` (isolated, full) | success; lint notes only |
| 4 | Python: artifact creation/runtime SHA-256 vs compiler evidence | 10/10 reproduce |
| 5 | `forge test --no-match-path 'test/audit-fork/*' --fuzz-seed 0x5042` | **186 passed, 0 failed** (179 existing + 7 audit) — `logs/full-suite-seed-0x5042.log` |
| 6 | `forge test --match-path 'test/audit/*' --fuzz-runs 2000 --fuzz-seed 0x5042` | **7 passed** — `logs/audit-tests-fuzz2000.log` |
| 7 | `cast keccak` recomputation of the three ERC-7201 roots | all equal the source constants |
| 8 | Storage-guard mutation (L-01) | guard wrongly prints OK, exit 0 |
| 9 | Public read-only RPC, testnet: FeeManager `balance` vs `totalOwed()` | equal to the wei (`11651715515151515153`); GM/hook/locker balances 0 |
| 10 | Public read-only RPC: code hashes testnet vs mainnet | USDC interface identical; PoolManager identical; PositionManager differs in exactly 4 immutable values (chain id, two addresses, one 32-byte separator); Permit2 differs (chain-bound immutables, expected) |
| 11 | In-memory fork probe `test/audit-fork/ArcUsdcForkProbe.t.sol` on both public RPCs | `balanceOf` works; **`transfer` reverts with empty data after consuming all gas** — a local EVM cannot execute Arc's USDC precompile path |

One failure occurred during my work and was mine: the first version of a price assertion overflowed (`poolSupply << 192`);
corrected to `mulDiv`, then passed. No contract behaviour was involved.

**What my tests establish** (`test/audit/AuditHook.t.sol`, `AuditCurve.t.sol`): for both currency orderings × both
directions × exact-in/exact-out × fuzzed size × empty/valid/dirty/short/long `hookData`: FeeManager's balance delta equals
the credited fee exactly; USDC and tokens are conserved across trader/PoolManager/FeeManager; the hook retains nothing;
the fee equals the documented formula on the **realized** USDC leg; a 1-unit buy (fee == amount, zero swap) settles;
a never-initialized key naming this hook can neither swap nor be initialized by a third party; a final buy at any point
in the snipe window (tax up to 99 %) charges exactly the quote, refunds the rest, graduates, leaves curve and
GraduationManager empty and the FeeManager exactly backed; an initial buy that sells out the curve graduates inside
`createToken`.

**Model limitations.** All local tests use `NativeUsdcShim` (cheatcode balance moves). It cannot establish: real
precompile gas costs (the 1,000,000 floor was calibrated on testnet by the team, not by me); blocklist/pause behaviour;
Arc's rule that value sends to the zero address, blocklisted or already-destructed accounts revert; EIP-7708 system
`Transfer` logs; or that an ERC-20 `transfer` never executes recipient code. Command 11 shows a fork cannot close this
gap either — **only a live Arc chain can**. What narrows it: the live testnet runs the baseline code (bytecode-matched by
the earlier review), has completed three real native-USDC graduations and hook fee flows with the ledger exactly backed
(command 9), the candidate differs from that code by two arithmetic/validation lines that do not touch USDC movement,
and the Uniswap/USDC code it integrates with is the same on mainnet (command 10).

---

## 6. Release recommendation (revision 1 — **superseded by §9.6**)

**No demonstrated blocker within the stated scope.** I found no exploitable defect in the contracts and I agree with
the earlier remediation. This is a single-pass review by an AI agent over hours, not weeks; it lowers but does not
remove the chance of an undiscovered defect, and the contracts that matter most are immutable once deployed.

Before deployment (small, owner-decidable):
1. **Decide D-01** — accept governance-set pool rates on locked pools, or add the immutable fee clamp to the hook now
   (then refresh evidence and re-run the suites; the hook cannot be changed later).
2. Add the post-deploy **runtime-bytecode comparison** (I-03) to the deployment-day checklist.
3. Be ready for a deployment restart (I-02).

Before the **first upgrade** (not before deployment): fix L-01 and L-02, and I-01 if convenient.

Remaining uncertainty, candidly: the candidate bytecode itself has never executed on a real Arc chain. Given the
two-line delta this is a small gap, but it is a gap. A graduation rehearsal is impractical on mainnet (~18,000 USDC of
buys) and the current wrappers refuse a second, separately-recorded testnet deployment, so closing it would need an
owner-authorized tooling/records decision. I do not consider it a blocker; the owner may.

## 7. Residual risks requiring explicit owner acceptance (not accepted here)

1. **Governance can tax or freeze existing curves and locked pools** through FeeManager/GraduationManager/Factory
   upgrades (D-01, D-05); one person controls all signers of all three 2-of-3 Safes; the 48 h delay is changeable via
   the same path; Safe owner changes and Treasury transfers are not timelocked.
2. **No migration path:** token, curve, hook and locker are immutable and LP positions can never be withdrawn; a defect
   found after launch in any of them cannot be patched, only abandoned for future launches.
3. **Guardian pause stops new launches only.** Direct contract calls continue regardless of the UI.
4. **Circle/Arc externalities:** blocklisting of the FeeManager or PoolManager address would freeze trading; blocklisted
   users cannot receive curve proceeds at that address; chain-level USDC semantics are outside this codebase.
5. **Canonical Uniswap v4 / Permit2 deployments on Arc** are trusted as deployed; I compared code hashes, not audited them.
6. **Persistent unlimited allowances** from the GraduationManager to Permit2/PositionManager.
7. **Referral leakage** up to `referrerShareBps` of fees from the platform bucket via self-referral/`hookData` (D-02).
8. **Immutable 1,000,000 gas floor** must be re-tested against every future GraduationManager implementation.
9. **Metadata** URIs are permanent references; availability and content are off-chain.
10. **No professional external audit** has been performed; this review and the earlier internal one are agent reviews.

## 8. Integration assumptions logged for backend/frontend (out of primary scope)

- `Buy.usdcIn` is **net** of fee and tax; refunds appear in no event. `HookFee.trader` and `FeeAccrued.trader` on the
  hook path are unauthenticated. `PlatformAccrued.token` is caller-supplied (`accruePlatform` is permissionless) and
  must not be treated as launch activity.
- A buy that *becomes* the final buy because another transaction landed first was gas-estimated as an ordinary buy and
  will revert `InsufficientGasForGraduation`. Funds are safe; the UI should pad the gas limit above ~1.1 M whenever the
  purchase could reach the remaining supply, and should present the revert as "retry", not failure.
- Quotes do not check phase/deadline; `computeAddresses` changes with config or factory implementation; pin `configHash`.
- Arc emits system `Transfer` logs for native movements and may give several blocks the same timestamp; indexers must
  filter by emitter and not assume strictly increasing timestamps.
- Specified-USDC swaps with a binding price limit revert (`PartialFill`) by design; routers should not set tight limits
  on the USDC-specified side.

---

## 9. Revision 2 — critical second pass (strict grading)

### 9.1 Why and how

After revision 1 the owner asked whether I had been lenient. My honest answer was: the checks were not softened, but
three judgment calls leaned lenient (D-01 labelled a tradeoff; "never ran on real Arc" called a non-blocker; limited depth).
This pass removes those leanings. Method: four independent adversarial reviewers, each with a private copy of the
hash-verified workspace, instructed to break one slice and to **mutation-test** it (change one line of production code in the
copy, see whether the *existing* suite notices). I re-ran or re-derived every claim below that I rely on, in my own pristine
workspace. All material is in `.release-evidence/mainnet-2026-09-21/independent-contract-audit/critical-pass/`.
No production file was changed; the candidate still matches the manifest (re-checked).

### 9.2 Depth gaps from revision 1 — now closed

| Gap admitted in revision 1 | Result |
| --- | --- |
| "Testnet runs the baseline" was taken on trust | **Verified by me.** Built the baseline commit separately; masked-immutable runtime comparison against live Arc testnet: all 7 contracts **match baseline**. Candidate `BondingCurve`, `LaunchToken`, `LiquidityLocker`, `GraduationManager`, `LaunchFactory` are **byte-identical to what is live**; only `FeeManager` (6,556 vs 6,531 bytes) and `LaunchHook` (3,390 vs 3,431) differ. ⇒ the one immutable contract whose candidate bytecode has never executed on a real Arc chain is the **hook**. |
| Slither not re-run | Re-ran 0.11.6 on candidate `src/`: 1 High, 10 Medium, 7 Low — the same detectors and counts as the retained run. I read each High/Medium myself: all false positives for the reasons in §4. |
| No coverage | Measured, but `--ir-minimum` line mapping is visibly wrong (marks executed lines unhit); used only as a hint. It pointed at the locker's revert branches, which mutation testing then confirmed are untested. |
| Tooling/advisories delegated | Unchanged; three tooling claims were re-verified by me in revision 1. |

### 9.3 Contract-level findings on the strict scale

**M-01 (Medium — trust/centralization, immutable contract) — hook has no fee ceiling.** Same facts as D-01 (§3). An external
firm would not file this as a "tradeoff": an upgradeable dependency sets the fee of an immutable hook on permanently locked
liquidity, with a single operator behind governance. Fix (pre-deployment only): immutable `MAX_POOL_FEE_BPS` clamp in `_fee`.
Owner decision required; if declined, it must appear in user-facing risk disclosure.

**L-03 (Low — griefing, recoverable) — graduation deferral can be forced on demand.** *Found independently by two reviewers;
PoC re-run by me (`critical-pass/adv-curve/AdvForcedDeferral.t.sol`, `adv-grad/GradForcedDeferralAdv.t.sol`).*
Root cause: `GraduationManager.graduate` → `PositionManager.modifyLiquidities` → `PoolManager.unlock`, which reverts
`AlreadyUnlocked` if the caller is already inside an unlock callback. A final buy made from inside `PoolManager.unlock`
therefore succeeds with ample gas (30M in the PoC) while graduation reverts cheaply → `GraduationDeferred`, phase
`GraduationPending`, buys closed. Adding a dust sell in the same transaction parks the curve one sliver short in `Trading`
with `graduate()` reverting `NotPending` — the state the C1 gas-floor fix was meant to make unreachable, reached by another
route. **Impact:** delay only. Anyone's `graduate()` (if Pending) or a dust buy (if Trading) completes graduation; the attacker
gains nothing, pays fees and must win the final buy each time. **Consequences:** (1) a keeper/UI must handle *both* branches;
(2) `BondingCurve.t.sol`'s comment that Pending cannot be reached by caller choice is wrong; (3) legitimate aggregators that
buy from inside an unlock will also defer. **Fix options (curve is immutable — decide before deploy):** accept and document
(my recommendation; any on-chain fix that restricts sells-while-pending trades away an exit path), or have `buy` in
`GraduationPending` first attempt `executeGraduation` instead of reverting. **Regression:** keep both PoCs in the repo.

**L-04 (Low/Informational — immutable dead code) — the `gasleft() <= g0/63` backstop never fires.** `BondingCurve.sol:341-345`.
Out-of-gas always occurs at least one frame below `executeGraduation` (inside `GraduationManager.graduate`), so `_buy`
regains ≈2/64 of `g0`, above the `g0/63` threshold; the buy is deferred, not rolled back. Verified by test
(`adv-curve/AdvMutantKillers.t.sol::test_nestedOogAboveFloorIsDeferred_heuristicNeverFires`) and by mutation: deleting the
check, or changing 63→640, survives the whole suite. (Revision 1 derived the same arithmetic and failed to draw the
conclusion.) Outcome is benign — a deferral is retryable — but only the fixed `GRADUATION_GAS_FLOOR = 1_000_000` protects
inline graduation, against a path that is upgradeable (GraduationManager) and external (Uniswap, Arc gas schedule). Local
measurement: smallest gas cap that graduates ≈1.16M. **Fix:** delete the heuristic or correct the NatSpec; add a test that
pins graduation gas under the floor so a future GraduationManager upgrade cannot silently exceed it.

**L-05 (Low — design) — referrals are bound to `msg.sender`, so shared routers are captured.** `BondingCurve` passes
`msg.sender` as `trader`; `FeeManager.accrueTradeFee` binds that address's referrer once, forever. A router, aggregator,
bot contract or shared smart-account is bound by its **first** user's referrer; every later user's named referrer is ignored
and the first referrer earns the share (PoC `adv-fee/AdvFeeFactory.t.sol::test_adv_sharedRouterReferralCapture`). No principal
at risk; referral revenue is misdirected. Together with D-02 this means referral attribution is only reliable for direct EOA
trades. Accept and document, or (immutable curve — pre-deploy only) add an explicit `trader` parameter authenticated some
other way, which I do not recommend for v1.0.

**Informational.** (a) The hook `take`s its fee before the swapper settles; a swap whose fee alone exceeds all USDC held by
the PoolManager reverts — economically absurd sizes only. (b) **Dependency-level, not Mercuri:** because Arc's 6-decimal
`balanceOf` floors an 18-decimal balance that the PoolManager shares between native-currency and ERC-20-USDC accounting,
a forced 1-wei top-up between `sync` and `settle` can be credited as one whole USDC unit (≤1e12 wei ≈ $0.000001 per
iteration, thousands of times below gas cost). Shown only against the shim; worth reporting to Uniswap/Arc, no action for
this release. (c) A creator address set to the FeeManager/hook strands only that creator's own fees.

**Attacks attempted and refuted (evidence in `critical-pass/`):** extraction by rounding or any `_setConfig`-accepted extreme
(30,000 runs × 7 configs: `virtualUsdc` 1 wei, `virtualTokens = curveSupply+1`, `poolSupply` 1 wei, fee 0–500, snipe 0–9,900);
blocked exits; double graduation or graduation with `sold < curveSupply`; a factory-accepted config that cannot graduate
(472 accepted configs, both orderings, all graduated; pool never opened above curve price; worst deviation ≈2 ppm, default 0);
`MaximumAmountExceeded`/liquidity rounding (180,000 runs); sub-1e12 remainders in the manager; pool pre-initialization
(7 key variants × 3 callers); `nextTokenId` races; Permit2 `lockdown`/nonce tricks; moving, approving, decreasing or burning the
locked position incl. ERC-1271 `permit`; false `PartialFill` with Uniswap's **protocol fee** at maximum and asymmetric settings;
ERC-6909 claim settlement; ten swaps in one unlock across pools; fee dodging by choice of specified currency, dust, splitting,
price limits; hostile `hookData` (only ever moves the platform slice; 64 KB costs only the caller gas); third-party concentrated
liquidity, donations and multi-tick crossings; sweep between the hook's `take` and `notifyHookFee` (fails closed with
`Unbacked`); binding or locking another wallet's referrer; hostile `claim` destinations; re-entrant payees; `createToken`
re-entry via the refund; CREATE2 squatting; a 98,304-call real-stack campaign with an independent fee model (strict
equalities `feeManager.balance == totalOwed + donations`, `curve.balance == realUsdc + donations`; 0 violations; every
action type succeeded thousands of times; 2,360 graduations).

### 9.4 Test-assurance findings (these weaken earlier evidence; verified by me)

**TA-01 (Medium for assurance) — the USDC shim leaks state through reverts.** `NativeUsdcShim` moves balances with `vm.deal`;
under Foundry 1.4.3 those moves are **not rolled back when the enclosing call reverts**. My minimal test
(`critical-pass/verify/ShimRevert.t.sol`): a transfer inside a call that reverts leaves the recipient +1e18 and the sender −1e18.
Consequence: every caught revert after a hook `take` leaves phantom USDC in the FeeManager, so
`invariant_feeConservation`'s `balance >= totalOwed` accumulates slack and could hide unbacked credit; any test that
relies on "reverted ⇒ balances unchanged" on a USDC path is unsound. Production code unaffected. Fix: snapshot/revert
around caught calls in the handler, and assert exact equality against tracked donations. My revision-1 hook fuzz asserts
exact equality on successful swaps and is not affected.

**TA-02 (Medium for assurance) — handler assertions are swallowed in the default configuration.** With
`fail_on_revert = false` (the `forge test` / CI default in `foundry.toml`) a failing assertion inside `Handler.sol` is just a
reverted call. I removed `$.balances[msg.sender] = 0` from `FeeManager.claim` (unlimited re-claim) in a scratch copy:
**all four invariants PASS** in the default configuration; with `FOUNDRY_INVARIANT_FAIL_ON_REVERT=true` all four FAIL
immediately. So the earlier 1,048,576-call `--stress` campaign was **not** blind to this — but the everyday suite and the
plain `check-contracts.sh` run are, and the unit test `test_claimPaysAndZeroes` is what actually guards it. Fix: record
violations in handler storage and assert them in the invariants (pattern in `critical-pass/adv-fee/AdvHandler.sol`), or make
`fail_on_revert = true` the default.

**TA-03 — mutation testing: 80 of 97 meaningful mutants killed (82%) by the existing suite.** Hook 15/18, curve 22/27,
graduation/locker 18/24, FeeManager/factory 25/28. Every kill in the hook slice came from integration tests; the invariant
suite killed nothing there on its own. Real survivors — i.e. production lines you could break today without any test failing:

| Contract (immutable?) | Surviving mutant | Why it matters |
| --- | --- | --- |
| LaunchHook (immutable) | exact-in fee `Ceil→Floor`; exact-out fee `Ceil→Floor` | rounding direction of every pool fee; existing tests only use divisible amounts |
| LaunchHook (immutable) | `HookFee` event emits ×1e12 amount | backend/indexer consumes this unit |
| BondingCurve (immutable) | `min(realUsdc, needed)` → either operand | tolerance-edge configs would never graduate / surplus configs would open the pool above curve price; every existing config sits exactly on the boundary |
| BondingCurve (immutable) | final-buy cap `>=`→`>`; deadline `>`→`>=`; OOG check removed | boundaries untested; the last is L-04 |
| LiquidityLocker (immutable) | drop `AlreadyRecorded`; drop `NotHeld`; `isLocked` ignores `ownerOf` | three of the locker's four checks are never exercised |
| GraduationManager | skip USDC dust accrual | value could strand silently |
| LaunchFactory | salt not scoped to deployer; `createToken` without `nonReentrant` | anti-squatting property has no test |
| FeeManager | `claim` without `nonReentrant` | near-equivalent (CEI holds) |

Killing tests for every survivor were written, pass on pristine source and fail on the mutant
(`critical-pass/adv-*/`); my revision-1 `AuditHook` fuzz already kills both rounding mutants. **Adopt them into the repository
before freezing** — this matters most if the hook is edited for M-01.

**TA-04 — a flaky existing test, hidden by fixed seeds.** `GraduationFuzz.t.sol::testFuzz_sqrtPriceX96_reconstructsRatio` fails
for inputs such as `(4e18, 591173564)`. I checked the arithmetic: the contract's price is correct to ~1e-24; the *test's* integer
reconstruction loses one unit (6.8e-9 relative) against a 1e-9 tolerance. Test bug, not contract bug — but "full suite passes at
the frozen commit" is a launch gate, and it only holds for the seeds in use.

### 9.5 Where revision 1 was wrong or too soft

- D-01 should have been graded **Medium**, not filed as a tradeoff.
- I computed the L-04 arithmetic in revision 1 and did not conclude the guard is dead.
- I did not find L-03; revision 1's "no permanent-DoS path" remains true, but "deferral only happens when graduation
  genuinely fails" was an unstated assumption and is false.
- I accepted the 1M-call invariant evidence at face value; TA-01/TA-02 show part of that suite is weaker than it looks.
- "Not a blocker" for the never-run-on-Arc gap was a lenient call given that the affected contract is the immutable hook.

### 9.6 Release recommendation (strict) — **further evidence required before mainnet**

No exploitable defect has been demonstrated by anyone, in either pass. On a strict scale that is necessary but not sufficient
for immutable contracts, because part of the supporting test evidence is weaker than reported and the changed immutable has
never run on the real chain. Before deployment:

1. **Owner decision on M-01** (clamp or documented acceptance). If the hook changes, everything below applies to the new bytecode.
2. **Owner decision on L-03/L-04/L-05** — I recommend accept-and-document for all three, plus correcting the curve NatSpec and
   the misleading test comment; L-04's dead branch can be deleted if the curve is being touched anyway. Ensure a keeper/UI path
   exists for both "Pending → `graduate()`" and "Trading with a sliver left → buy".
3. **Repair the evidence base:** fix TA-01 and TA-02, adopt the survivor-killing tests (TA-03), fix TA-04, then re-run
   `check-contracts.sh --stress`. None of this changes production code.
4. **Run the exact candidate hook and FeeManager on Arc testnet** (a local fork cannot execute Arc's USDC `transfer`, §5 #11):
   all four swap shapes × both orderings, a swap that reverts after `take` (confirm the chain, unlike the shim, leaves no
   trace), a graduation, a claim. This needs an owner-authorized way to record a second testnet deployment without touching
   `deployments/5042002.json`; the current wrappers refuse that.
5. Revision-1 items stand: post-deploy runtime-bytecode comparison (I-03), restart readiness (I-02); L-01/L-02 before the
   first upgrade.

Residual risks in §7 are unchanged, with two additions: **11.** graduation liveness depends on a fixed 1,000,000-gas floor
inside immutable curves against an upgradeable/external path (L-04); **12.** referral attribution is unreliable through
routers and `hookData` (L-05, D-02). None is accepted on the owner's behalf.

---

## 10. Review of the remediated candidate (manifest `227f3d9c…896d9`)

### 10.1 Identity

`docs/reports/2026-09-21-audit-remediation-candidate-manifest.json`: recomputed source-manifest hash ✔, archive SHA-256 ✔
(`.release-evidence/mainnet-2026-09-21/audit-remediation/candidate-sources.tar.gz`), all 3,122 files match the working tree
(**0 drift**); all 107 sources in `2026-09-21-audit-remediation-compiler-evidence.json` match. Production delta versus the
candidate I audited: **only `src/LaunchHook.sol`** (clamp + formatting + NatSpec); `foundry.toml` gains `ast = true`.
I built it from the verified archive in a fresh isolated workspace (`env -i`, offline, no `.env`).

### 10.2 M-01 fix — verified

```solidity
uint256 public constant MAX_POOL_FEE_BPS = 500;
function _fee(uint256 bps, uint256 amount, bool exactInput) private pure returns (uint256 fee) {
    if (bps > MAX_POOL_FEE_BPS) bps = MAX_POOL_FEE_BPS;
    if (bps == 0) return 0;
    ...
```

- Correct place: `_fee` is the single function behind all three call sites (`beforeSwap`, both `afterSwap` branches), so the
  charge and the `PartialFill` expectation cannot disagree. It also removes the hook's dependence on FeeManager keeping
  `bps < 10,000` (`BPS - bps ≥ 9,500` always). 500 equals the factory's existing cap, so no legitimately registered token
  changes behaviour. The constant is compiled into the immutable hook; governance cannot raise it.
- What it does **not** do (the remediation report says this too, and I agree): it does not guarantee liveness — an upgraded
  FeeManager can still revert `tradeFeeBps`/`notifyHookFee` and freeze swaps, or re-route accrued fees.
  Residual risk 1 in §7 shrinks from "tax up to ~100 % or freeze" to "tax up to 5 % or freeze".
- **Tests:** remediated suite + all my audit tests + all four reviewers' adversarial tests = **259 tests, 258 pass**; the one
  failure is explained in §10.3 and is not a contract fault. The 14 adversarial hook tests (protocol fee at maximum, ERC-6909
  settlement, multi-swap unlocks, third-party liquidity, extreme amounts) and my exact-settlement fuzz all pass on the new hook.
- **Mutation-tested by me:** removing the clamp, raising the constant to 501, and an off-by-one comparison are **all killed**
  by the remediation's own `LaunchHook.t.sol`.

### 10.3 The one failing test is the fixture artifact (TA-01), surfaced on this build

The fee reviewer's strict invariant (`feeManager.balance == totalOwed + tracked donations`) fails on the remediated build for
some seeds (2 of 4) and passed on the original for 10 of 10. I did not accept "probably the artifact" without checking:

1. **Trace of the failing sequence:** the last call is a pool swap that *fully reverts* (`ERC20InsufficientBalance` — the
   handler's actor tried to sell more tokens than it held) **after** the hook's `take` of 20 USDC-units. On a real chain
   that transaction leaves no trace. Under the shim, the `vm.deal` move survives the revert → 2e13 wei of phantom balance.
2. **Deterministic A/B** (`critical-pass/verify/PartialFillPhantom.t.sol`): a swap reverting with `PartialFill` after `take`
   leaves exactly 20e18 wei in the FeeManager and removes it from the PoolManager **on both the original and the
   remediated build**.
3. **Instrumented campaign:** with a counter for "reverted swap changed FeeManager balance", the campaign reports phantom
   events on **both** builds.

So the hook's accounting on successful swaps is exact on the new build, and reverted swaps are a test-fixture problem on
both. **Loose end, stated honestly:** I could not fully explain why the un-instrumented campaign never tripped on the original
across 10 seeds; invariant fuzz sequences depend on contract bytecode, so the two builds explore different sequences, but
I have not proven that is the whole explanation. It does not change the conclusion, because (2) and (3) show the artifact
directly on both builds. It is one more reason to fix TA-01 before relying on any balance-equality invariant.

### 10.4 Status of every item after remediation

| Item | Status |
| --- | --- |
| M-01 hook fee ceiling | **Fixed; verified by me (§10.2).** |
| L-01 storage guard, L-02 upgrade preflight, I-01 re-scheduled id, I-03 runtime comparison | Remediation report says fixed with tests. **Tooling changes not re-reviewed by me in this pass**; its claim that my `fm_mut.json` now exits 1 is consistent with what I would expect, but I did not re-run it. |
| I-02 CREATE2 griefing | Documented (inherent). |
| L-03 forced deferral, L-04 dead `g0/63` guard, L-05 referral bound to `msg.sender` | **Open — found after the remediation; the curve is unchanged and immutable.** Owner decision before deploy. |
| TA-01 shim leaks through reverts, TA-02 swallowed handler assertions, TA-03 surviving mutants, TA-04 flaky fuzz test | **Open.** The remediation added hook tests at/above the cap, but the rounding-direction, locker, `Math.min`, salt-scoping survivors and the fixture/handler defects are untouched. |
| Hook bytecode never executed on real Arc | **More true than before:** the hook changed again (runtime 3,390 → 3,448 bytes). |

**Recommendation is unchanged: further evidence required before mainnet** (§9.6 items 2–5; item 1 is done). The remediated
hook is, in my assessment, strictly safer than the one I audited. It is also new immutable bytecode that has never run on
Arc, supported by a test fixture with a known fidelity defect — which is exactly the case a live-testnet run is for.

