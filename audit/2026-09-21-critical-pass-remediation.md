# Critical-pass test assurance remediation — 2026-09-21

This follows authoritative sections 9–10 of the
[independent critical-pass review](2026-09-21-independent-contract-audit-critical-pass.md)
and its implementation handoff (internal).
The original independent report and the preceding remediation evidence remain unchanged.
No production Solidity source, live deployment, frontend repository, remote resource or DNS is changed.

## Owner decisions

The owner explicitly confirmed: **“Accept and document all three; retain current contracts.”**
This accepts the following specific behaviors, not every other release risk or a broadcast:

- **L-03:** a final buy inside an existing PoolManager unlock can deliberately defer graduation.
  A nonzero-proceeds dust sell can then reopen Trading just short of sell-out. Recovery is permissionless:
  call `graduate()` while Pending, or make an ordinary direct buy while Trading. The attacker must win the
  final buy again and pays fees; holder exits remain available before graduation. Do not describe deferral
  as solely an external failure outside the caller's control.
- **L-04:** the `g0/63` catch heuristic does not detect the demonstrated nested out-of-gas case. The fixed
  1,000,000 gas floor and the measured graduation budget are the relevant protections. A future manager
  upgrade or gas-schedule change can outgrow that floor; the curve cannot be patched. No comment or code
  in `BondingCurve.sol` was changed; this document corrects the operational interpretation.
- **L-05:** curve referrals bind to `msg.sender`; a shared router's first referrer can capture later routing
  activity. Router referral attribution is unreliable, and hookData is unauthenticated. This affects the
  referral/platform share, not traded principal. No new authenticated-trader interface is introduced.

### Existing recovery integration (read-only review)

The current launch frontend commit is `ce890a76f871f7706fcf8f0d6740162e6d26711a`.
`TradePanel/index.tsx` renders a Pending retry button bound to `actions.graduate`;
`useArcTradeActions.ts` simulates and submits `graduate()` directly to the curve. `arcTradePlan.ts`
permits buys in Trading and sells until Graduated. The buy action reads current supply/sold and
quotes, then applies the sell-out gas allowance. Thus the two recovery paths already exist in source;
this is not a new browser or live-chain smoke test. No frontend files were edited.

Operationally, re-read on-chain phase before acting. Pending requires a direct `graduate()` retry;
Trading requires a quote and normal direct buy sufficient to finish the remaining supply, with normal
slippage/deadline checks. Do not blindly retry `graduate()` in Trading, or route the completing buy
inside an existing PoolManager unlock. Re-read phase after a race/revert and re-evaluate the branch.
Any live transaction remains subject to the existing authorization boundary.

## Changes and validation

### Test and tooling changes

- **TA-01:** replaced the shim's `vm.deal` balance moves with EVM-journaled value transfer through
  a helper created and destroyed in the same call. Native value now rolls back with the enclosing
  reverted frame, even when a handler catches the revert. Nested caller impersonation preserves
  Foundry's active single/recurrent prank mode. The raw `PartialFillPhantom` test checks FeeManager,
  PoolManager, trader and owed balances without a compensating outer snapshot; the minimal revert
  regression also checks both sender and recipient. The existing fee invariant now requires exact
  backing including an explicit donation counter. The adopted independent model separately tracks
  real donation actions and sweeps.
- **TA-02:** `fail_on_revert = true` is the repository default. Unexpected handler reverts now fail
  ordinary tests. The adopted adversarial handler additionally records violations in storage and
  checks them from its invariant, against an independent fee/referral model.
- **TA-03:** adopted focused tests from all four critical-pass slices plus the revision-1 curve/hook
  suite and the two fixture proofs. Added deterministic non-divisible hook fees/event units across
  all four swap shapes and both orderings, buy-deadline equality, the locker's explicit `NotHeld`
  branch and graduation with a known nonzero USDC remainder. Mutation testing found that the supplied
  tolerance-edge test's fee gross-up could add one wei and hide the `Math.min(..., needed)` survivor;
  the adopted test disables fees and checks the exact rounded available reserve. Both forced-deferral
  proofs are retained. The supplied re-entry test also survived guard removal because it reused the
  outer CREATE2 salt. It now attempts a separately valid fresh-salt creation and asserts the exact
  reentrancy error; the nested call cannot fail merely because its address already exists.
  `AdvSwallowedAssert` is excluded; `AdvInvariants` is adopted after repairing rollback and has no
  inline override of the default/stress runner settings. The separate exploratory arithmetic and
  configuration-space campaigns were not copied; this is focused regression coverage, not a claim
  to reproduce all 97 original audit mutations.
- **TA-04:** the price reconstruction assertion combines a two-unit absolute allowance with the
  existing relative tolerance at every magnitude. The reported `(4e18, 591173564)` counterexample
  has its own deterministic test. `GraduationManager._sqrtPriceX96` is unchanged.
- **Graduation budget:** both currency orderings must complete `executeGraduation` with a 900,000 gas
  cap after cooling dependencies. This is the same self-call used by the final buy, below the fixed
  1,000,000 floor, and includes the artificial shim overhead. It is a regression guard for the default
  configuration, not an Arc gas measurement or a proof about every future manager/configuration.
- **Evidence reader:** selects artifacts by the exact Deploy compiler/settings when the expanded suite
  creates multiple profiles for a dependency. Profile names are not release identities: the protocol and
  Deploy use the `small` restriction (200 optimizer runs), while general test artifacts use 44,444,444.
  Wrong compiler/settings or ambiguous matches fail closed; four Python regressions cover selection.
  Exact recompilation and bytecode comparison remain mandatory.

The shim adds helper-creation gas and nonce effects and does not model issuer controls. It is only a
local fixture; its repair does not replace the live Arc test. No new production contract is introduced.
The external hook-log assertion helper avoids a test-only Solidity Yul inlining/stack limit without
changing the pinned compiler or optimizer. Imported auditor files were restored from their originals
when Foundry 1.4.3 formatting damaged two blocks; the accepted files are compiler-checked.

### Gas baseline review

The complete diff was reviewed before updating `.gas-snapshot`: 157 → 160 entries, none removed,
65 existing values changed. Added entries are deadline equality, the reconstruction counterexample
and the graduation budget. Most integration deltas reflect roughly 37,273 gas per shim transfer;
new selectors also move test dispatch by about 22 gas. The adaptive graduation gas-search test's
aggregate fell by 1,543,907 gas because the fixture changes its sampled caps/paths, not because
production was optimized. The eight-way repeated fee matrix rose by 2,459,970 gas due to repeated
fixture transfers. These are test gas baselines, not mainnet fee estimates.

### Validation

All commands ran in isolated public-source workspaces with a reduced environment, offline Foundry
and the pinned compiler. No `.env` was loaded and no RPC or broadcast was involved.

| Check | Result |
| --- | --- |
| `bash script/check-contracts.sh --stress` | Exit 0: storage guards/self-tests, full build, NatSpec, 257 regular Solidity tests, 12 then-existing tooling tests, 160 gas checks, 252 non-invariant tests with global fuzz runs 10,000, and all five stress invariants |
| Stress invariants | 1,024 runs × depth 256 each: 1,310,720 calls in total, zero unexpected handler reverts; existing per-test fuzz overrides remain effective outside this stage |
| Final regular suite after the last test/tool adjustments | 257 passed, zero failed, seed `0x5042`; default invariants 64 × 64 with zero unexpected handler reverts |
| Final Python tooling suite | 16 passed, including all four new compiler-profile selection regressions |
| Final deterministic gas baseline check | All 160 entries match |
| Raw revert-after-take trace | `PoolManager.take(..., 20_000_000)` executes, then `PartialFill()` reverts; FeeManager gained **0 wei**, PoolManager lost **0 wei** |
| Focused isolated mutants | **14/14 killed by assertion failures**, not compiler failures or empty test selection |
| Exact compiler reproduction | All 107 production closure source hashes and all ten creation/runtime bytecode pairs match the preceding reviewed candidate |

Validation order is explicit: the wrapper stress run completed using the final production sources,
shim, invariant handlers and configuration. The fresh-salt factory regression and artifact-reader
selection fixes were finalized separately; the complete regular suite, tooling suite and gas check
then passed on the final tree. `stress-inputs.json` confirms the factory regression is the only
Solidity/configuration input changed after that campaign. It is deterministic and passes unmutated
and fails without the guard. The million-call invariant inputs did not change, so that campaign was
not repeated merely for these independent test/tool edits.

Mutation results cover: missing claim balance clear (the **default**
`forge test --match-path 'test/invariant/*'` fails in all five invariants); hook exact-in/exact-out
rounding and event units; each operand of the curve minimum; final-buy cap and buy deadline equality;
locker AlreadyRecorded, NotHeld and ownership; graduation USDC dust; deployer-scoped salt; and factory
re-entry. Every mutation was made only in the scratch copy and restored afterward. Initial surviving
minimum/re-entry tests were corrected as described above, then proven against pristine and mutated
code. This is not a rerun of the auditor's entire 97-mutant experiment.

The gas-limited graduation test passes for both orderings. The original independent audit remains
unchanged at SHA-256 `6b7bd72f19d1c35898d19358649eb60241a7930dda3bba330aaafded53375d9f`.
The seven protocol contracts, deployment script, proxy and timelock still reproduce exactly; neither
this follow-up nor its test changes require new production bytecode or hook mining.

Local evidence: `.release-evidence/mainnet-2026-09-21/critical-pass-remediation/` contains `stress.log`,
`final-checks.log`, `phantom-trace.log`, `mutation-results.json`, individual mutant logs, the local
mutation runner, gas review, compiler inputs/outputs and preserved diagnostics from resolved failures.
Failed intermediate attempts are retained; they are not counted as passing evidence.

### Frozen identity and preservation

Code checkpoint: `2c782aca1353d01e8d260dd1276c1b9693c40996`, local branch `release/mainnet-preparation-2026-09-21`.
The candidate manifest (internal release evidence) covers **3,137 selected inputs**;
source-manifest SHA-256: `fac6812c7eb939da72c1d2a12a3e559ea8162cace2c0a6332c659469c5625026`.
Archive SHA-256: `6c449d4b2fa6b6d0b5371b993da2d98a14f535bc18d5a0c8f5a4e0b84089dce0`.
See the compiler evidence (internal release evidence) for the ten exact bytecode
comparisons and unchanged 107-source closure.

All earlier commits and live testnet records remain intact. No source in `contracts/src/` changed.
The launch frontend remains at `ce890a76f871f7706fcf8f0d6740162e6d26711a`; documentation frontend edits
and the landing frontend's five untracked Yield Yeti images were preserved outside this parent-repo
checkpoint. The manifest records their final Git status without archiving those assets. No mainnet
canonical deployment records were fabricated, and no push or remote write occurred.

## Remaining gate

The new hook/FeeManager still require an explicitly authorized, separately recorded live Arc testnet
run: all four swap shapes in both orderings, a revert after `take`, graduation and claim. This task does
not change remote deployment-directory guards or authorize a second deployment. Existing testnet
records and completed Safe/recovery tests are preserved. The prior storage/preflight/runtime/history
tooling fixes remain outside the critical auditor's re-review; review them before the first upgrade.

No mainnet go-live approval follows from these local tests. Migration 0014 then 0015 must precede the
candidate API rollout, and dedicated backend-admin software wallets remain separate from governance.
