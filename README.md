# mercurifi — launch contracts

The Solidity source of [launch.mercuri.finance](https://launch.mercuri.finance), a token launchpad on Arc, exactly as
deployed to mainnet on 21 Sep 2026 (v1.0.0). This repository holds the contracts, the vendored dependencies they were
compiled against, the deployment records and the contract review reports. The backend and the web app are separate
and not published.

A launch is one transaction. The token trades on a bonding curve in USDC, so every price, fee and market cap is a
dollar figure from the first block. The buy that sells the curve out opens a Uniswap v4 pool at the curve's last
price in the same transaction, and the pool position goes to a locker contract with no withdraw function.

## Mainnet addresses (chain 5042)

| Contract | Address | Upgradeable |
| --- | --- | --- |
| LaunchFactory | `0x8f5DfA0c48E14cCD03AE01795B8a95759BA859EB` | yes — proxy; implementation `0xecE7FD8F52F8114032AB08f72628B4B4CF489711` |
| FeeManager | `0x31D1bfe59B783f4c077F853f962D1355AfB52580` | yes — proxy; implementation `0xD2d7865b351C1902F5ECFA6187B6B60542027A52` |
| GraduationManager | `0x5E82a03a30a1627Cb0Fa860dBe708e262e5124e4` | yes — proxy; implementation `0x033aDa8dA6db7b141382DA9Ab0784659deCE3A44` |
| LaunchHook | `0xe6D50A6e12f3883605A4456dCDEe50EE05fAE0Cc` | no |
| LiquidityLocker | `0x278e5162074BC4fc98e91E90857FDbc374d1f391` | no |
| Timelock (48 h) | `0x94aFdf4cF8fD025E8421C936f5647a175515eb40` | — |
| Treasury | `0x34E3321e97BBa4F5c7A0aCc6b09C50bE9173912D` | — |

Each launch deploys its own `LaunchToken` and `BondingCurve` (immutable, one per token), announced by the factory's
`TokenCreated` event. Uniswap v4 on Arc: PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, PositionManager
`0x6049c9a0e26405C0985f9E3685C87d0aE917f82B`. USDC is the gas token, `0x3600000000000000000000000000000000000000`.

Full records, including the governance roles: [`deployments/5042.json`](deployments/5042.json) (mainnet) and
[`deployments/5042002.json`](deployments/5042002.json) (testnet, same version).

## What each contract does

| File | Role |
| --- | --- |
| `src/LaunchFactory.sol` | Creates a token and its curve in one transaction. Holds the launch configuration (fees, curve shape, snipe schedule); every change goes through the timelock and applies to future launches only. The owner or a guardian can pause new launches, nothing else. |
| `src/LaunchToken.sol` | Plain ERC-20, 1,000,000,000 supply, minted once to the curve. |
| `src/BondingCurve.sol` | Constant-product curve over virtual reserves, priced in USDC. Charges the trade fee and the snipe tax (buys only, falling to zero over the first blocks). When the curve sells out it hands its reserve to the GraduationManager. |
| `src/GraduationManager.sol` | Creates the Uniswap v4 pool at the curve's last price, mints a full-range position and transfers it to the locker. If any step fails the token is left pending: sells stay open, anyone can retry. |
| `src/LiquidityLocker.sol` | Owns every graduated position. It has no function that withdraws liquidity. |
| `src/LaunchHook.sol` | Uniswap v4 hook on every graduated pool. Charges the same trade fee in the pool that the curve charged; the rate is read from the FeeManager and capped at 5% in this immutable code. |
| `src/FeeManager.sol` | Receives every fee. Splits trade fees between creator, referrer and platform, records claimable balances, binds referrers on chain. |

Defaults at deployment: trade fee 1% of the USDC side of every trade (0.50% to the creator, 0.20% to a bound
referrer, the rest to the platform); launch fee 1 USDC; snipe tax 99% in the launch block falling in a straight line
to zero over 120 blocks (about a minute at Arc's block time); graduation at about 18,000 USDC collected, market cap about $5,600 → $90,000. All of these are
read live from the contracts; the numbers here are what the code was deployed with.

## Events (for indexers)

```
LaunchFactory     TokenCreated(address indexed token, address indexed curve, address indexed creator, address deployer,
                               string name, string symbol, string metadataURI, bytes32 configHash, LaunchConfig config)
BondingCurve      Buy(address indexed trader, uint256 usdcIn, uint256 tokensOut, uint256 fee, uint256 tax, uint256 realUsdc, uint256 sold)
                  Sell(address indexed trader, uint256 tokensIn, uint256 usdcOut, uint256 fee, uint256 realUsdc, uint256 sold)
                  CurveCompleted(uint256 usdcForPool, uint256 tokensForPool)
GraduationManager Graduated(address indexed token, bytes32 indexed poolId, uint160 sqrtPriceX96, uint256 usdcAmount, uint256 tokenAmount)
                  LiquidityLocked(address indexed token, bytes32 indexed poolId, uint256 indexed tokenId, uint128 liquidity)
LaunchHook        HookFee(address indexed token, address indexed trader, uint256 usdcAmount)
FeeManager        FeeAccrued(address indexed token, address indexed trader, address creator, address referrer,
                             uint256 creatorAmount, uint256 referrerAmount, uint256 platformAmount, uint8 source)   // 0 curve, 1 hook
                  PlatformAccrued(address indexed token, address indexed from, uint256 amount)                     // launch fee or snipe tax
                  FeeClaimed(address indexed account, address indexed to, uint256 amount)
                  ReferralBound(address indexed trader, address indexed referrer)
```

USDC amounts in events are native 18-decimal wei. A public read API mirrors the chain:
`https://launch-api.mercuri.finance/v1/stats`, `/v1/tokens`, `/v1/trades`.

## Build and verify

```
forge build
python3 script/verify-runtime.py
```

`forge build` uses the pinned settings in `foundry.toml` (Solidity 0.8.26, Cancun, via-IR, per-path optimizer runs,
no metadata hash) and the vendored `lib/` tree, which is committed as plain files so that the source every test,
deployment and review used is the source you compile. `lib-versions.md` records the package versions and tree hashes.

`script/verify-runtime.py` fetches the runtime code of the five protocol contracts from a public Arc RPC and compares
it with the freshly compiled artifacts, masking only the immutable-variable slots that are filled at deployment.
Run on 22 Sep 2026 against `https://rpc.mainnet.arc.io`, all five matched exactly.

## Security

- [`audit/2026-09-21-independent-contract-audit.md`](audit/2026-09-21-independent-contract-audit.md) — independent
  review of the release candidate, with the remediation and the second (critical) pass alongside it in `audit/`.
- [`audit/contract-security.md`](audit/contract-security.md) — the assumptions the contracts rely on and the
  governance model: three 2-of-3 Safes (owner, canceller, guardian) and a 172,800-second timelock on every change.
- `storage-layouts/` — the storage layout of each upgradeable contract at v1.0.0, the baseline any upgrade is
  checked against.

The reports were written inside the private working repository and reference some evidence folders and tooling that
live there (`.release-evidence/…`, `contracts/script/…`, `backend/…`). Those references are left as written; the
findings, the reasoning and the remediation diffs are complete in the reports themselves.

No professional third-party audit has been performed yet. The review published here is what exists; read it before
relying on the contracts.

## License

MIT for the contracts in `src/`. Dependencies under `lib/` keep their own licenses.

mercurifi is an independent product. It is not affiliated with, sponsored by or endorsed by Circle Internet Group,
Inc. Arc and USDC are trademarks of Circle Internet Group, Inc. and/or its affiliates, named here only to say which
network and asset the contracts work with. Uniswap is a trademark of Uniswap Labs.
