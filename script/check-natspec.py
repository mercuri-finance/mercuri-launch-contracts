#!/usr/bin/env python3
"""Check compiler-emitted NatSpec for the protocol's own public ABI after forge build.

Standard inherited ERC-20/UUPS/ownership methods use vendored documentation. Own
overrides are checked. Public-variable getters require notices; functions also
require named inputs and all outputs. This checks completeness, not semantic truth.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = (
    "BondingCurve", "FeeManager", "GraduationManager", "LaunchFactory",
    "LaunchHook", "LaunchToken", "LiquidityLocker",
)
INHERITED = {
    "UPGRADE_INTERFACE_VERSION", "acceptOwnership", "owner", "pendingOwner",
    "proxiableUUID", "transferOwnership", "upgradeToAndCall", "paused",
    "allowance", "approve", "balanceOf", "decimals", "name", "symbol",
    "totalSupply", "transfer", "transferFrom",
}


def abi_type(item):
    if item["type"].startswith("tuple"):
        return "(" + ",".join(abi_type(c) for c in item["components"]) + ")" + item["type"][5:]
    return item["type"]


failures = []
checked = 0
for contract in CONTRACTS:
    source = (ROOT / "src" / (contract + ".sol")).read_text()
    declarations = set(re.findall(r"\bfunction\s+(\w+)\s*\(", source))
    artifact = json.loads((ROOT / "out" / (contract + ".sol") / (contract + ".json")).read_text())
    metadata = artifact["metadata"]
    if isinstance(metadata, str):
        metadata = json.loads(metadata)
    user = metadata["output"]["userdoc"].get("methods", {})
    dev = metadata["output"]["devdoc"].get("methods", {})
    for item in artifact["abi"]:
        kind = item["type"]
        if kind not in ("function", "constructor"):
            continue
        name = item.get("name", "constructor")
        if name in INHERITED and name not in declarations:
            continue
        signature = ("constructor" if kind == "constructor" else name) + "(" + ",".join(
            abi_type(i) for i in item["inputs"]
        ) + ")"
        # Solidity keys constructor documentation by "constructor", without parameters.
        key = "constructor" if kind == "constructor" else signature
        label = contract + "." + signature
        checked += 1
        if not user.get(key, {}).get("notice", "").strip():
            failures.append(label + ": missing @notice")
        is_getter = kind == "function" and name not in declarations
        if is_getter:
            continue
        doc = dev.get(key, {})
        for parameter in item["inputs"]:
            if parameter["name"] and not doc.get("params", {}).get(parameter["name"], "").strip():
                failures.append(label + ": missing @param " + parameter["name"])
        if len(doc.get("returns", {})) < len(item.get("outputs", [])):
            failures.append(label + ": missing @return")

for failure in failures:
    print("FAIL " + failure)
print(f"NatSpec: {checked} ABI entries checked; {len(failures)} failures")
raise SystemExit(bool(failures))
