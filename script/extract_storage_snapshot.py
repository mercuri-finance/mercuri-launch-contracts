#!/usr/bin/env python3
"""Turns forge's raw `storageLayout --json` output for a layout-probe contract (see
test/utils/upgrade/StorageLayoutProbe.sol) into the normalized snapshot schema `check_storage_diff.py` compares:

    {"contract": "<name>", "members": [
        {"label": ..., "slot": "<n>", "offset": <n>, "type": "<human label>",
         "layout": {"encoding": ..., "numberOfBytes": "<n>", ...}} # includes mapping values and array bases
    ]}

`type` is solc's "types" entry LABEL (e.g. "address", "contract ILaunchFactory", "mapping(address => uint256)",
"struct LaunchConfig"), never the raw type key: the raw key embeds a compiler-internal AST id
(`t_struct(LaunchConfig)14721_storage`) that can shift between builds with no actual layout change, so comparing
it directly would make the guard flag false positives.

Usage: extract_storage_snapshot.py <contract-name> < raw-storageLayout.json
"""
import json
import sys


def resolve_type(key, types, trail=()):
    if key in trail:
        raise ValueError("recursive storage types require manual layout review")
    t = types[key]
    out = {"type": t["label"], "encoding": t["encoding"], "numberOfBytes": t["numberOfBytes"]}
    trail = (*trail, key)
    for child in ("key", "value", "base"):
        if child in t:
            out[child] = resolve_type(t[child], types, trail)
    if "members" in t:
        out["members"] = [resolve_member(m, types, trail) for m in t["members"]]
    return out


def resolve_member(m, types, trail=()):
    return {"label": m["label"], "slot": str(m["slot"]), "offset": m["offset"],
            "type": types[m["type"]]["label"], "layout": resolve_type(m["type"], types, trail)}


def main(argv):
    if len(argv) != 2:
        print("usage: extract_storage_snapshot.py <contract-name> < raw-storageLayout.json", file=sys.stderr)
        return 2
    contract = argv[1]
    raw = json.load(sys.stdin)
    storage = raw.get("storage") or []
    if len(storage) != 1:
        print(
            f"expected exactly one probe state variable in the layout, found {len(storage)} "
            "(is test/utils/upgrade/StorageLayoutProbe.sol still a single-field probe per contract?)",
            file=sys.stderr,
        )
        return 1
    top = storage[0]
    types = raw["types"]
    members = resolve_type(top["type"], types).get("members")
    if members is None:
        print("probe variable does not resolve to a struct", file=sys.stderr)
        return 1
    json.dump({"schemaVersion": 2, "contract": contract, "members": members}, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
