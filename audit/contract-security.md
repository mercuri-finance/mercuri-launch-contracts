# Contract security and integration assumptions

Status: release candidate under internal review; not mainnet approval. Updated 2026-09-21.

## Trust and immutability

| Component | Fixed properties | Governed or external dependencies |
| --- | --- | --- |
| LaunchToken | One-billion-token supply, ERC-20 code, metadata reference, no owner/mint/pause | Off-chain metadata availability and hash verification |
| BondingCurve | Bytecode, config snapshot, peer addresses, per-launch reserve accounting | FeeManager can change fee accounting or revert calls; GraduationManager can change how existing curves graduate |
| LaunchHook | Callback code, permission bits, peer addresses, fee formula and 500 bps rate ceiling | FeeManager supplies rates and processes fees for existing pools; accounting/liveness remain governed |
| LiquidityLocker | No owner, approval, withdrawal, position modification, delegatecall or upgrade path | Canonical PositionManager owns the NFT ledger; GraduationManager is trusted to record the correct token/position association |
| LaunchFactory proxy | Proxy address | Timelock can upgrade logic, including the registry used to authenticate graduations, and change future config, treasury and guardian |
| FeeManager proxy | Proxy address | Timelock can change implementation, including accrued balances, claims and pool rates |
| GraduationManager proxy | Proxy address | Timelock can change implementation for every not-yet-graduated curve |

The current owner methods constrain the current implementation; they do not constrain arbitrary future implementation
code. A malicious or faulty governed upgrade can disrupt existing curve trades, redirect graduation funds or affect
existing pool fee behavior. A 48-hour timelock gives notice and an exit opportunity where exits remain available; it is
not a technical guarantee that an upgrade is harmless.

The 48-hour minimum is enforced by the deployment tooling, not permanently hard-coded into
OpenZeppelin TimelockController. Its self-administered `updateDelay` can lower the delay after an operation
waits the existing delay. Likewise, authorized ownership/role changes and upgrades can change future control.
Monitor delay, role, ownership and implementation changes; do not describe this as an immutable 48-hour floor.
Safe owner/threshold changes are Safe self-calls, not protocol-timelock operations. The Safes have no on-chain
requirement to wait 48 hours before replacing an owner or moving Treasury funds.

The owner selected software-wallet multisig signers on 2026-09-21. Hardware wallets are not required by the current
plan. The owner approved the same three signer addresses for all three separate 2-of-3 Safes and a 48-hour protocol
timelock. This setup still needs separate keys, devices and recovery backups; a shared compromise affecting
two signers defeats the threshold. Software signing does not remove device/phishing risk. The project owner confirmed
control of all three signers and creation of new wallets with separate recovery phrases on different MacBooks. This
supersedes the earlier proposed MacBook/iPhone/second-computer allocation and is device/key separation, not independent
human approval. Generation provenance is owner-attested. All three signers have participated in verified live
Safe threshold transactions. Device-security verification, ongoing backup separation and private backup restoration
remain separate checks; follow the signer recovery runbook (internal).

Factory upgrades change the curve creation code for future launches only, but can also alter the registry that
GraduationManager consults for existing launches. They cannot patch already deployed curves,
tokens, hooks or lockers. Existing pools encode their hook in the pool key. The system has no mechanism to move the
permanently locked position to a replacement pool. A new deployment therefore does not automatically recover or migrate
old liquidity.

Guardian pause applies only to new token creation. Existing buys, sells, graduations, pool swaps and claims have no
guardian pause. This is an intentional DeFi tradeoff and must be stated in incident communications.

## Units, rounding and transaction behavior

Native USDC, curve accounting and FeeManager liabilities use 18 decimals. Arc's USDC ERC-20 interface uses 6 decimals
over the same balance: one ERC-20 base unit equals 10^12 native wei. Launch tokens have 18 decimals. Never add quantities
from the two USDC interfaces without conversion.

Curve buy output and sale proceeds round down; the cost of a requested token amount rounds up. Curve fees round down.
Buy tax is charged on value remaining after the trade fee, decays by elapsed blocks, and is disabled when snipeBlocks
is zero. The default 120-block window is approximately 60 seconds, not a wall-clock guarantee. The initial factory buy
is tax-exempt and capped at 50 million tokens. The final buy refunds unused value before graduation.

The pool hook rounds fees up in 6-decimal units. Exact-input fees use gross * bps / 10,000; exact-output fees use
net * bps / (10,000 - bps). FeeManager registration requires bps < 10,000; current Factory policy is stricter at <= 500.
The mainnet candidate hook clamps every returned rate to 500 bps (5%) before fee calculation, including
exact-output denominators. DefaultConfig remains 100 bps (1%). This caps the formula rate, subject to the existing
6-decimal ceiling rounding; a one-unit dust fee can exceed 5% of a tiny trade. It does not cap arbitrary
future FeeManager accounting or prevent that proxy from reverting and freezing trades. The live testnet hook
remains the previous deployment without this new ceiling.
Specified-USDC partial fills revert; token-specified swaps may fill partially and pay on the realized USDC leg.

Buy/sell quotes do not check every execution condition. Integrators must check phase, deadline, balances/allowances,
and slippage. Factory address predictions depend on current configuration and implementation. Pin configHash on creation.
Metadata references are permanent, but contracts do not verify metadata content or ensure that a host remains available.

## Fees and external calls

Claimable fees are pull payments. A recipient's failed claim reverts its own transaction and restores accounting.
Anyone may trigger claimPlatform, but payment always goes to the current factory treasury. Unaccounted donations may be
swept into platform accounting. accruePlatform is intentionally permissionless and permits zero-value events: neither its
token label nor event existence authenticates launch activity.

Referral binding occurs once, through self-service before the first curve trade or during that first trade.
Pool hookData is unauthenticated and only selects an existing referral; it never binds a wallet or marks it as traded.
Do not present hookData trader attribution as authenticated identity.

Graduation relies on the registered curve, a standard LaunchToken, canonical PoolManager, PositionManager and Permit2,
and Arc's native/ERC-20 balance behavior. It grants persistent unlimited allowances to Permit2 and PositionManager.
The deployment procedure must verify their addresses, bytecode and wiring. This implementation has no arbitrary-token
callback path; reassess reentrancy and allowance assumptions if future upgrades add one.

Arc USDC issuer controls and network rules remain external risks. Blocklisting, unavailable RPC, or changes in
underlying system behavior can interrupt activity. Local integration tests use a shim for Arc's shared balance model;
they supplement, rather than replace, live-chain and release-fork rehearsal.

Graduation failures may leave a sold-out curve pending. Anyone may retry; a sale with nonzero proceeds reopens trading.
The immutable gas floor was calibrated against the present graduation implementation. Upgrades must exercise the
smallest successful gas limit and nested failure paths again; an out-of-gas in a nested dependency can resemble an
ordinary revert. Tiny sales with nonzero proceeds can reopen trading; there is no economic minimum beyond rounding.

## Accepted critical-pass behaviors (2026-09-21)

The owner accepted L-03/L-04/L-05 and directed that current contracts be retained. A completing buy
inside PoolManager.unlock can force a retryable deferral; a nonzero-proceeds dust sell can reopen Trading.
Recovery therefore branches on current phase: Pending → direct graduate(); Trading → ordinary completing
buy. The existing frontend exposes both actions. The nested-OOG g0/63 heuristic does not reliably catch
that failure; the fixed gas floor needs renewed budget checks for upgrades. The curve sees a shared router
as msg.sender, so that router's first referrer applies to later users and attribution is unreliable.
See the [critical-pass remediation and precise acceptance](2026-09-21-critical-pass-remediation.md).
These decisions do not accept all remaining risks or authorize deployment.

## Documentation and release checks

Own public/external functions and constructors carry NatSpec, including units, authorization and meaningful edge cases.
Inherited standard ERC-20/UUPS/ownership documentation remains in the vendored dependencies; use @inheritdoc on the
protocol interfaces. Generated userdoc/devdoc must be checked against compiled ABI and source declarations.

From `contracts/`, run `bash script/check-contracts.sh --stress`. Without `--stress`, it runs the regular suite,
NatSpec and storage checks, and the deterministic unit/integration/upgrade gas snapshot. The stress option adds
10,000 global fuzz runs (individual test settings may override this) and 1,024 invariant runs at depth 256 with
uncaught handler reverts forbidden. Invariant handlers intentionally catch some protocol reverts and skip inapplicable
actions; handler-call counts are not counts of successful trades. The check never loads `.env` or broadcasts.

The gas baseline is a regression signal for these exact tests/toolchain, not a mainnet fee estimate. It includes
fixture/cheatcode and intentional-revert costs. Review any change before regenerating `.gas-snapshot`; do not blindly
update the baseline to make a failing check pass. Neither these checks nor NatSpec completeness prove security.

Run the full build before targeted integration tests; the pinned Foundry version otherwise may not build the
PositionManager artifact loaded by the fixture. Preserve testnet deployment records. A candidate with changed FeeManager
or hook runtime intentionally differs from the live testnet release and needs fresh deployment/rehearsal evidence.

The [independent agent review](2026-09-21-independent-contract-audit.md) and
[remediation record](2026-09-21-independent-audit-remediation.md) distinguish reviewed findings from
owner risk acceptance. The storage guard now traverses mapped structs and array elements. Upgrade preflight
checks ownership, wiring, selected accounting/configuration state, locked implementation initialization and
a second upgrade; these checks do not enumerate every mapping entry or prove future logic safe. Intentional
state/wiring migrations require a separate reviewed procedure. Fresh deployment record promotion also requires
exact hook, locker and implementation runtime matches, with immutable addresses reconstructed from the record.

The release gate remains the mainnet handover launch gate (internal), including independent audit or
explicitly accepted residual risks, verified Safes and the full deployment rehearsal. Dependency source identity is in
[lib-versions.md](../lib-versions.md). Internal tests alone do not close that gate.
