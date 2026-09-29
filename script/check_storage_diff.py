#!/usr/bin/env python3
"""Compares two ERC-7201 namespaced-struct storage layouts (see script/check-storage.sh for how the input is
produced) and enforces: a snapshot member may never be removed, reordered or retyped; new members may only be
appended at the end. Traverse mapping values and array elements recursively. Mapping-value structs may
grow; array element stride must remain unchanged. Direct struct growth is allowed only at the tail.

Usage:
    check_storage_diff.py <old.json> <new.json>
    check_storage_diff.py --self-test

Exit code 0 = compatible (or appended-only). Non-zero = incompatible, with a message on stderr.
"""
import json
import sys


class Incompatible(Exception):
    pass


def _member_sig(m):
    """The fields that must never change for an EXISTING member: its name, its physical position, and its
    type's human-readable label (not solc's raw type key, which embeds an AST id that can shift between
    compiler runs even with no layout change)."""
    return (m["label"], str(m["slot"]), m["offset"], m["type"])


def compare_type(old, new, path, allow_growth):
    for key in ("type", "encoding"):
        if old[key] != new[key]:
            raise Incompatible(f"{path}: {key} changed")
    old_size, new_size = int(old["numberOfBytes"]), int(new["numberOfBytes"])
    if new_size < old_size or (new_size != old_size and not allow_growth):
        raise Incompatible(f"{path}: storage size/array stride changed")
    if ("members" in old) != ("members" in new):
        raise Incompatible(f"{path}: struct shape changed")
    if "members" in old:
        if "members" not in new:
            raise Incompatible(f"{path}: struct definition disappeared")
        compare_members(old["members"], new["members"], path)
    for key in ("key", "value", "base"):
        if (key in old) != (key in new):
            raise Incompatible(f"{path}: {key} definition changed")
        if key in old:
            # Mapping values have independent hashed roots. Array element growth
            # changes the stride even if the array is dynamic or the last field.
            compare_type(old[key], new[key], f"{path}.{key}", key == "value")


def compare_members(old_members, new_members, path):
    if len(new_members) < len(old_members):
        raise Incompatible(f"{path}: member(s) removed")
    for i, old in enumerate(old_members):
        new = new_members[i]
        if _member_sig(old) != _member_sig(new):
            raise Incompatible(f"{path}.{old['label']}: member removed, reordered, retyped or moved")
        if "layout" in old:
            if "layout" not in new:
                raise Incompatible(f"{path}: detailed layout disappeared")
            compare_type(old["layout"], new["layout"], f"{path}.{old['label']}", i == len(old_members) - 1)
        elif "nested" in old:  # Legacy synthetic comparator self-tests only.
            if "nested" not in new:
                raise Incompatible(f"{path}: nested struct disappeared")
            compare_members(old["nested"]["members"], new["nested"]["members"], path)
            if int(new["nested"]["numberOfBytes"]) != int(old["nested"]["numberOfBytes"]) and i != len(old_members) - 1:
                raise Incompatible(f"{path}: non-last nested struct grew")
    return True


def validate_members(members):
    for member in members:
        layout = member["layout"]
        if layout["type"] != member["type"]:
            raise Incompatible("inconsistent member type")
        validate_type(layout)


def validate_type(layout):
    if int(layout["numberOfBytes"]) <= 0:
        raise Incompatible("invalid storage width")
    encoding = layout["encoding"]
    if encoding == "mapping" and not {"key", "value"} <= layout.keys():
        raise Incompatible("mapping detail missing")
    if encoding == "dynamic_array" and "base" not in layout:
        raise Incompatible("array detail missing")
    if layout["type"].startswith("struct ") and "members" not in layout:
        raise Incompatible("struct detail missing")
    if layout["type"].endswith("]") and "base" not in layout:
        raise Incompatible("fixed array detail missing")
    for key in ("key", "value", "base"):
        if key in layout:
            validate_type(layout[key])
    if "members" in layout:
        validate_members(layout["members"])


def _run_self_test():
    """A synthetic before/after pair with a reordered field. Must be rejected. No Solidity compile involved:
    this pins the comparator's own logic, independent of the toolchain."""
    before = [
        {"label": "a", "slot": "0", "offset": 0, "type": "uint256"},
        {"label": "b", "slot": "1", "offset": 0, "type": "address"},
        {"label": "c", "slot": "2", "offset": 0, "type": "bool"},
    ]
    reordered = [
        {"label": "b", "slot": "0", "offset": 0, "type": "address"},
        {"label": "a", "slot": "1", "offset": 0, "type": "uint256"},
        {"label": "c", "slot": "2", "offset": 0, "type": "bool"},
    ]
    try:
        compare_members(before, reordered, "SelfTest")
    except Incompatible as e:
        print(f"self-test PASS (reordered field correctly rejected): {e}")
    else:
        print("self-test FAIL: a reordered field was NOT rejected", file=sys.stderr)
        sys.exit(1)

    # A same-shape append must be accepted.
    appended = before + [{"label": "d", "slot": "3", "offset": 0, "type": "uint256"}]
    compare_members(before, appended, "SelfTest")
    print("self-test PASS (a plain append is accepted)")

    # A nested struct growing while NOT last must be rejected.
    nested_before = [
        {
            "label": "cfg",
            "slot": "0",
            "offset": 0,
            "type": "struct Config",
            "nested": {"numberOfBytes": "32", "members": [{"label": "x", "slot": "0", "offset": 0, "type": "uint256"}]},
        },
        {"label": "tail", "slot": "1", "offset": 0, "type": "address"},
    ]
    nested_grew_not_last = [
        {
            "label": "cfg",
            "slot": "0",
            "offset": 0,
            "type": "struct Config",
            "nested": {
                "numberOfBytes": "64",
                "members": [
                    {"label": "x", "slot": "0", "offset": 0, "type": "uint256"},
                    {"label": "y", "slot": "1", "offset": 0, "type": "uint256"},
                ],
            },
        },
        {"label": "tail", "slot": "2", "offset": 0, "type": "address"},
    ]
    try:
        compare_members(nested_before, nested_grew_not_last, "SelfTest")
    except Incompatible as e:
        print(f"self-test PASS (non-last nested struct growth correctly rejected): {e}")
    else:
        print("self-test FAIL: non-last nested struct growth was NOT rejected", file=sys.stderr)
        sys.exit(1)

    # The same growth IS allowed when the nested struct is the last member.
    nested_last_before = [
        {"label": "tail", "slot": "0", "offset": 0, "type": "address"},
        {
            "label": "cfg",
            "slot": "1",
            "offset": 0,
            "type": "struct Config",
            "nested": {"numberOfBytes": "32", "members": [{"label": "x", "slot": "0", "offset": 0, "type": "uint256"}]},
        },
    ]
    nested_last_grew = [
        {"label": "tail", "slot": "0", "offset": 0, "type": "address"},
        {
            "label": "cfg",
            "slot": "1",
            "offset": 0,
            "type": "struct Config",
            "nested": {
                "numberOfBytes": "64",
                "members": [
                    {"label": "x", "slot": "0", "offset": 0, "type": "uint256"},
                    {"label": "y", "slot": "1", "offset": 0, "type": "uint256"},
                ],
            },
        },
    ]
    compare_members(nested_last_before, nested_last_grew, "SelfTest")
    print("self-test PASS (last-member nested struct growth is accepted)")
    print("ALL SELF-TESTS PASSED")


def main(argv):
    if argv[1:] == ["--self-test"]:
        _run_self_test()
        return 0

    if len(argv) != 3:
        print("usage: check_storage_diff.py <old.json> <new.json> | --self-test", file=sys.stderr)
        return 2

    with open(argv[1]) as f:
        old = json.load(f)
    with open(argv[2]) as f:
        new = json.load(f)

    try:
        if old.get("schemaVersion") != 2 or new.get("schemaVersion") != 2:
            raise Incompatible("schema v2 snapshots required; regenerate from reviewed original layouts")
        if old.get("contract") != new.get("contract"):
            raise Incompatible("contract identity changed")
        validate_members(old["members"])
        validate_members(new["members"])
        compare_members(old["members"], new["members"], old.get("contract", "storage"))
    except (Incompatible, KeyError, TypeError, ValueError) as e:
        print(f"INCOMPATIBLE STORAGE LAYOUT: {e}", file=sys.stderr)
        return 1

    print(f"OK: {old.get('contract', 'storage')} storage layout is a valid append-only evolution")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
