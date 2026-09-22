#!/usr/bin/env python3
"""Compare the compiled runtime bytecode of the five protocol contracts with the code deployed on Arc mainnet.

Run `forge build` first. Immutable-variable slots (filled at deployment) are masked on both sides; everything else
must match byte for byte. Usage: python3 script/verify-runtime.py [RPC_URL]
"""
import json
import sys
import urllib.request

RPC = sys.argv[1] if len(sys.argv) > 1 else "https://rpc.mainnet.arc.io"
RECORD = json.load(open("deployments/5042.json"))
CONTRACTS = {
    "LaunchFactory": RECORD["factoryImplementation"],
    "FeeManager": RECORD["feeManagerImplementation"],
    "GraduationManager": RECORD["graduationManagerImplementation"],
    "LaunchHook": RECORD["launchHook"],
    "LiquidityLocker": RECORD["liquidityLocker"],
}


def get_code(address):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [address, "latest"]}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"content-type": "application/json", "user-agent": "curl/8.0"})
    return bytearray(bytes.fromhex(json.load(urllib.request.urlopen(req, timeout=30))["result"][2:]))


ok = True
for name, address in CONTRACTS.items():
    artifact = json.load(open(f"out/{name}.sol/{name}.json"))["deployedBytecode"]
    local = bytearray(bytes.fromhex(artifact["object"][2:]))
    onchain = get_code(address)
    masked = 0
    for refs in artifact.get("immutableReferences", {}).values():
        for ref in refs:
            start, length = ref["start"], ref["length"]
            local[start:start + length] = b"\0" * length
            onchain[start:start + length] = b"\0" * length
            masked += 1
    match = local == onchain
    ok &= match
    print(f"{name:18} {address}  {'EXACT' if match else 'DIFFERS'} ({len(onchain)} bytes, {masked} immutable slots masked)")

sys.exit(0 if ok else 1)
