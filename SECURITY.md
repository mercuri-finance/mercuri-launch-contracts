# Security

## Reporting a vulnerability

Use GitHub's private reporting: **Security → Report a vulnerability** on this repository. The report is visible
only to the maintainers until a fix is deployed and disclosed. Please do not open a public issue for anything that
could be exploited.

Include the contract and function, the chain (mainnet 5042 or testnet 5042002), a transaction or a Foundry test that
shows the behaviour, and what you think the impact is. You will get an acknowledgement within 48 hours and updates as
the fix moves.

## Scope

The contracts in `src/` as deployed at the addresses in [`deployments/5042.json`](deployments/5042.json). The
vendored dependencies under `lib/` are upstream code; report defects in them upstream as well.

Out of scope: the web app, the read API and the hosting, which are not in this repository; and findings that require
a compromised governance signer, which the [security assumptions](audit/contract-security.md) already treat as a
trust boundary rather than a defect.

## What already exists

- Two AI-assisted review passes with published remediation, in [`audit/`](audit).
- Reproducible bytecode: `python3 script/verify-runtime.py` after `forge build`.
- Every configuration change goes through a 48-hour timelock; the only emergency lever is pausing new launches.

No professional third-party audit has been performed yet.
