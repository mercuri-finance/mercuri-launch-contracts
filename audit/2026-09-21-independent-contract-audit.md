# Mercuri Launch — independent contract review, 2026-09-21

**Reviewer:** fresh AI agent session (Claude), no involvement in the earlier review or remediation.
**Nature of this document:** additional assurance from an independent agent review. It is **not** a professional
external audit certification, not risk acceptance and not release approval; those belong to the owner.

## Summary

- **No exploitable defect was found** in the seven protocol contracts that lets an unprivileged attacker lose user
  funds, break curve/fee accounting, strand or withdraw locked liquidity, bypass authorization, or block exits.
  I say this explicitly rather than padding the report: the immutable pieces (token, curve, hook, locker) are small,
  conservative and well tested, and my own targeted tests (7, up to 2,000 fuzz runs each) passed.
- **One proven defect in release tooling** (not in deployed code): the storage-layout guard cannot see inside
  `FeeManager`'s `TokenInfo` struct, so a layout-corrupting FeeManager upgrade would pass it (L-01). It does not affect
  the v1.0 deployment; fix it before the first FeeManager upgrade.
- **One design decision worth making before the immutable hook ships** (D-01): the hook reads its fee rate from the
  upgradeable FeeManager with no hook-side ceiling, whereas the curve pins its fee immutably. This is a governance-trust
  tradeoff, not a bug; a one-line clamp would remove it. Owner's call.
- **Recommendation:** *no demonstrated blocker within the stated scope.* Residual risks that need explicit owner
  acceptance are listed in §7. Remaining uncertainty is stated in §6.

I was asked to be impartial and to weigh tradeoffs in the context of a launchpad. Where the design follows normal
launchpad practice (upgradeable fee/graduation logic behind a timelock, pause only for new launches, permanently
locked LP), I record it as a tradeoff to accept, not as a finding.

---

## 1. Reviewed identity, tools, scope

| Item | Value |
| --- | --- |
| Repository / baseline | `<workspace>`, commit `8e902eb6b83e3c61d9af6ad8fbb4efe1431177af`, **working tree** (uncommitted candidate) |
| Candidate manifest | `docs/reports/2026-09-21-release-candidate-manifest.json`; `sourceManifestSha256` recomputed = `0c0bbc009d1038c4e93d85bbfa7b3cc27aec7483fcb07e6285f42e36bea88c53` ✔ |
| Source archive | `.release-evidence/mainnet-2026-09-21/candidate-sources.tar.gz`, SHA-256 `ffc7804e…278f3` ✔; all 3,119 members match the manifest; **working tree vs manifest: 0 drifted, 0 missing** |
| Compiler evidence | `docs/reports/2026-09-21-release-compiler-evidence.json`: all 107 source hashes match the working tree (**no drift**) |
| Bytecode reproduction | My isolated build reproduced creation **and** runtime SHA-256 for all 10 targets (7 protocol contracts, `TimelockController` [`small` profile], `ERC1967Proxy`, `Deploy`) |
| Toolchain | Foundry `forge/cast 1.4.3-Homebrew` (binary SHA-256 `7a91e6ef…020c6`, matches `lib-versions.md`), solc `0.8.26+commit.8a97fa7a`, Cancun, via-IR, per-path optimizer profiles from `foundry.toml` (src = 200 runs), Python 3.13.7. **Slither is not installed in this environment and was not re-run**; I reviewed the retained 0.11.6 triage instead (§4). |
| Executable delta vs baseline commit | Exactly two executable lines: `FeeManager.registerToken` `tradeFeeBps_ >= BPS` rejection, and `LaunchHook.afterSwap` widen-before-negate. Everything else in `src/` is NatSpec/formatting. |

**In scope (read in full by me):** `src/{LaunchFactory,LaunchToken,BondingCurve,FeeManager,GraduationManager,LaunchHook,LiquidityLocker}.sol`,
`src/libraries/*`, `src/interfaces/*`, `script/{DefaultConfig,Deploy.s,Verify.s}.sol`, `script/utils/{HookMiner,Deployments}.sol`,
`script/{deploy,common}.sh`, test fixtures/shim/mocks, and the reachable parts of vendored v4-core (`Hooks`, `PoolManager`
swap/sync/settle/take, `Pool.swap` zero-amount path) and v4-periphery `PositionManager` (mint, payer mapping, Permit2 pull).

**Delegated to a sub-reviewer, claims I relied on re-verified by me:** `Timelock.s.sol`, `timelock.sh`, `TimelockHistory.sol`,
`records.py`, storage-layout guard, upgrade tests. Compiler/dependency advisory research (web, primary sources).

**Omitted / not re-done:** backend, frontend, infrastructure; Safe contracts and the completed Safe/recovery tests;
long invariant/capacity campaigns (I ran the default 64×64 campaigns once); coverage measurement; Slither;
bytecode-level audit of the canonical on-chain Uniswap/Permit2/USDC deployments (I compared code hashes only, §5);
Arc node internals.

---

## 2. Findings

Severity reflects impact on **user funds and the immutable contracts**. None is Critical/High/Medium.

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

### D-01 — Immutable hook and curves depend on the upgradeable FeeManager for liveness; hook also for its **rate**

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

## 6. Release recommendation

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
