#!/usr/bin/env python3
"""Run the mainnet deployment simulation through the supported wrapper only.

The RPC credential and deployer key are entered in an interactive Terminal and
held only in this process environment. The default mode never broadcasts;
the explicit --broadcast mode is reserved for the separately approved release.
The launcher never reads .env or puts the key in argv.
"""
import getpass
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "contracts"
CHAIN_ID = "5042"
DEPLOYER = "0x36E5f6AE800846DBf5cCd271f7fe47a9e056b595"
POOL_MANAGER = "0x8366a39CC670B4001A1121B8F6A443A643e40951"
POSITION_MANAGER = "0x6049c9a0e26405c0985f9e3685c87d0ae917f82b"
PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3"
PROPOSER = "0xF768e819E7B5AB54aF7561a73092C5E0C1A45b4F"
GUARDIAN = "0xbcD634D133Ec05abFAB018e78138b370c4f912B0"
TREASURY = "0x34E3321e97BBa4F5c7A0aCc6b09C50bE9173912D"


def clean_env(rpc, key):
    env = {k: os.environ[k] for k in ("HOME", "PATH") if k in os.environ}
    env.update({
        "ARC_RPC": rpc,
        "EXPECTED_CHAIN_ID": CHAIN_ID,
        "DEPLOYER_PRIVATE_KEY": key,
        "POOL_MANAGER": POOL_MANAGER,
        "POSITION_MANAGER": POSITION_MANAGER,
        "PERMIT2": PERMIT2,
        "PROPOSER": PROPOSER,
        "EXECUTOR": PROPOSER,
        "GUARDIAN": GUARDIAN,
        "TREASURY": TREASURY,
        "TIMELOCK_DELAY": "172800",
        "NO_COLOR": "1",
    })
    return env


def derive_address(key):
    result = subprocess.run(
        ["node", "--input-type=module", "-e",
         "import {privateKeyToAccount} from 'viem/accounts'; let k=''; for await (const c of process.stdin) k+=c; try { console.log(privateKeyToAccount(k.trim()).address) } catch { process.exit(1) }"],
        input=key, text=True, capture_output=True, cwd=ROOT / "tools/smoke",
        env={k: os.environ[k] for k in ("HOME", "PATH") if k in os.environ},
    )
    if result.returncode or not re.fullmatch(r"0x[0-9a-fA-F]{40}", result.stdout.strip()):
        raise RuntimeError("could not derive the deployer address; the key was not saved")
    return result.stdout.strip()


def cast(rpc, *args):
    result = subprocess.run(["cast", *args, "--rpc-url", rpc], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("read-only mainnet preflight failed; RPC details suppressed")
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--broadcast", action="store_true",
                        help="broadcast the approved mainnet deployment; omitted means simulation only")
    args = parser.parse_args()
    if not sys.stdin.isatty():
        raise RuntimeError("run this command directly in a local Terminal")
    rpc = getpass.getpass("Mainnet RPC URL (hidden; never saved): ").strip()
    if not rpc.startswith("https://"):
        raise RuntimeError("mainnet RPC must use HTTPS")
    key = getpass.getpass("Mainnet deployer private key (hidden; never saved): ").strip()
    if not re.fullmatch(r"(?:0x)?[0-9a-fA-F]{64}", key):
        raise RuntimeError("expected a 32-byte private key; input was not saved")
    key = key if key.startswith("0x") else "0x" + key
    address = derive_address(key)
    if address.lower() != DEPLOYER.lower():
        raise RuntimeError("the supplied key does not control the approved mainnet deployer")
    if cast(rpc, "chain-id") != CHAIN_ID:
        raise RuntimeError("RPC is not Arc mainnet chain 5042")
    if cast(rpc, "nonce", address, "--block", "pending") != "0":
        raise RuntimeError("mainnet deployer nonce is no longer zero; stop and review before retrying")
    if cast(rpc, "code", address) != "0x":
        raise RuntimeError("approved deployer is not a plain EOA")
    for name, target in (("PoolManager", POOL_MANAGER), ("PositionManager", POSITION_MANAGER),
                         ("Permit2", PERMIT2)):
        if cast(rpc, "code", target) == "0x":
            raise RuntimeError(name + " has no code on mainnet")
    print("Mainnet chain 5042 and approved deployer verified:", address)
    if args.broadcast:
        print("APPROVED MAINNET BROADCAST: starting the supported wrapper now.", flush=True)
        command = ["bash", "script/deploy.sh", "--no-env"]
    else:
        print("Starting supported deployment dry-run. No broadcast and no record write will occur.", flush=True)
        command = ["bash", "script/deploy.sh", "--dry-run", "--no-env"]
    result = subprocess.run(command, cwd=CONTRACTS, env=clean_env(rpc, key), text=True)
    key = None
    # Forge writes a separate sensitive cache file even when the wrapper itself writes only a
    # pending record. Keep the public broadcast log, but remove this exact generated secret cache.
    sensitive = CONTRACTS / "cache/Deploy.s.sol/5042/run-latest.json"
    if sensitive.exists():
        sensitive.unlink()
    if result.returncode:
        raise RuntimeError("mainnet deployment wrapper failed; inspect the public wrapper output and pending record")
    if args.broadcast:
        print("Mainnet deployment broadcast and verification completed.")
    else:
        print("Mainnet deployment dry-run passed. No transaction was sent.")


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print("STOP:", str(error) or "interrupted", file=sys.stderr)
        raise SystemExit(1)
