#!/usr/bin/env python3
"""Promotes pending deployment files written by the forge scripts. Called by deploy.sh and timelock.sh.

The forge scripts never write the tracked record `<chainId>.json` or the operation log `<chainId>-operations.json`:
forge runs a script to completion BEFORE it sends any transaction, so whatever a script writes describes something
that has not happened yet. A broadcasting run writes `<chainId>.pending.json` (a whole record) and/or
`<chainId>-operations.pending.json` (one log entry). The wrappers call this helper afterwards:

  promote-deploy DIR CHAIN --confirmed   archive the tracked record as archive/<chain>-<its deployBlock>.json and the
                                         operation log as archive/<chain>-<deployBlock>-operations.json, then move
                                         the pending record into place
  promote-sync DIR CHAIN --confirmed     replace the tracked record with the pending one (same deployment)
  append-op DIR CHAIN --confirmed        append the pending entry to the operation log (an entry whose
                                         (id, action, timelock) is already there is not appended twice)
  fail DIR CHAIN                         rename every pending file to *.failed-<UTC time>.json
  --selftest                             offline self-test of the failure diagnostics (temporary directories only)

`--confirmed` is the caller's statement that the step before succeeded: for promote-*, that the broadcast succeeded
AND Verify passed against the pending record; for append-op, that the forge run which wrote the entry succeeded.
The wrappers pass it only in that situation. Without it nothing is promoted.

Every command is safe to re-run: promote-deploy resumes where an interrupted run stopped (an archive copy that
already exists with identical content is accepted). When a command cannot complete, the diagnosis printed is
derived from the files actually present and from `--confirmed` — it never asserts anything it has not observed.
"""
import json
import os
import subprocess
import sys
import tempfile
import time


class Refused(Exception):
    """A command could not complete; the message is a statement of observed fact."""


def paths(d, chain):
    return {
        "dir": d,
        "record": os.path.join(d, f"{chain}.json"),
        "pending": os.path.join(d, f"{chain}.pending.json"),
        "ops": os.path.join(d, f"{chain}-operations.json"),
        "ops_pending": os.path.join(d, f"{chain}-operations.pending.json"),
        "archive": os.path.join(d, "archive"),
    }


def load(path):
    with open(path) as f:
        return json.load(f)


def read(path):
    with open(path) as f:
        return f.read()


def write_atomic(path, text):
    tmp = path + ".tmp"
    if os.path.exists(tmp):
        raise Refused(f"{tmp} exists (left by an interrupted run); inspect it and remove it")
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def copy_new(src, dst):
    """Copies src to dst atomically. An existing identical dst is accepted; a different one is refused."""
    data = read(src)
    if os.path.exists(dst):
        if read(dst) == data:
            print(f"  (already present, identical: {dst})")
            return
        raise Refused(f"{dst} already exists with DIFFERENT content than {src}")
    write_atomic(dst, data)


def record_block(p):
    try:
        return load(p["record"]).get("deployBlock")
    except (OSError, ValueError):
        return None


# ------------------------------------------------------------------------------------------------- commands


def promote_deploy(p, chain, confirmed):
    if not os.path.exists(p["pending"]):
        raise Refused("nothing-pending")
    if not confirmed:
        raise Refused("unconfirmed")
    pending = load(p["pending"])
    if str(pending.get("chainId")) != str(chain):
        raise Refused(f"the pending record's chainId {pending.get('chainId')} is not {chain}")
    if os.path.exists(p["record"]):
        block = record_block(p)
        if block is None:
            raise Refused(f"the tracked record {p['record']} has no readable deployBlock")
        os.makedirs(p["archive"], exist_ok=True)
        dst = os.path.join(p["archive"], f"{chain}-{block}.json")
        copy_new(p["record"], dst)
        print(f"archived previous record      -> {dst}")
        if os.path.exists(p["ops"]):
            ops_dst = os.path.join(p["archive"], f"{chain}-{block}-operations.json")
            copy_new(p["ops"], ops_dst)
            os.remove(p["ops"])
            print(f"archived previous operation log -> {ops_dst}")
    os.replace(p["pending"], p["record"])
    print(f"promoted {p['pending']} -> {p['record']}")


def promote_sync(p, chain, confirmed):
    if not os.path.exists(p["pending"]):
        raise Refused("nothing-pending")
    if not confirmed:
        raise Refused("unconfirmed")
    if not os.path.exists(p["record"]):
        raise Refused(f"there is no tracked record at {p['record']} to sync")
    pending, current = load(p["pending"]), load(p["record"])
    for key in ("chainId", "deployBlock", "timelock", "factory", "feeManager", "graduationManager"):
        if pending.get(key) != current.get(key):
            raise Refused(f"the pending sync record changes '{key}'; a sync may only change governed fields")
    os.replace(p["pending"], p["record"])
    print(f"promoted {p['pending']} -> {p['record']}")


def append_op(p, chain, confirmed):
    if not os.path.exists(p["ops_pending"]):
        raise Refused("nothing-pending")
    if not confirmed:
        raise Refused("unconfirmed")
    entry = load(p["ops_pending"])
    log = load(p["ops"]) if os.path.exists(p["ops"]) else {"operations": []}
    if not isinstance(log.get("operations"), list):
        raise Refused(f"{p['ops']} is not an operation log")

    def key(e):
        return (str(e.get("id")).lower(), e.get("action"), str(e.get("timelock")).lower())

    if any(key(e) == key(entry) for e in log["operations"]):
        os.remove(p["ops_pending"])
        print(f"'{entry.get('action')}' {entry.get('id')} is already in {p['ops']}; not appended twice")
        return
    log["operations"].append(entry)
    write_atomic(p["ops"], json.dumps(log, indent=2) + "\n")
    os.remove(p["ops_pending"])
    print(f"appended '{entry.get('action')}' {entry.get('id')} to {p['ops']}")


def fail(p, chain, confirmed):
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    for key in ("pending", "ops_pending"):
        src = p[key]
        if os.path.exists(src):
            dst = src[: -len(".pending.json")] + f".failed-{stamp}.json"
            os.replace(src, dst)
            print(f"kept the unpromoted file as {dst}")


COMMANDS = {"promote-deploy": promote_deploy, "promote-sync": promote_sync, "append-op": append_op, "fail": fail}


# ------------------------------------------------------------------------------------------------- diagnosis


def diagnose(cmd, p, chain, confirmed, reason):
    """Only statements that are true for the observed files and for what the caller passed."""
    has = {k: os.path.exists(p[k]) for k in ("record", "pending", "ops", "ops_pending")}
    out = [f"records.py {cmd} DID NOT COMPLETE: " + ("nothing to do" if reason == "nothing-pending" else reason)]
    out.append("Files observed now:")
    for k in ("record", "pending", "ops", "ops_pending"):
        out.append(f"    {'present' if has[k] else 'absent '}  {p[k]}")
    if os.path.isdir(p["archive"]):
        names = sorted(n for n in os.listdir(p["archive"]) if n.startswith(f"{chain}-"))
        out += [f"    present  {os.path.join(p['archive'], n)}" for n in names] or [f"    (no archive entries for {chain})"]
    rerun = f"python3 script/records.py {cmd} {p['dir']} {chain} --confirmed"

    if reason == "nothing-pending":
        pending_kind = "operation entry" if cmd == "append-op" else "record"
        out.append(f"Nothing to promote: there is no pending {pending_kind} in {p['dir']}.")
        out.append("This command performs no chain action and implies none; nothing was changed.")
        if cmd == "promote-deploy" and has["record"]:
            out.append(
                f"A tracked record exists (deployBlock {record_block(p)}). If you were resuming an interrupted promotion, "
                "it has already completed; confirm with Verify (forge script script/Verify.s.sol --rpc-url <rpc>)."
            )
        return out
    if reason == "unconfirmed":
        out.append(
            "Nothing was changed: --confirmed was not given, so this invocation has no statement that the step "
            "before (broadcast + Verify for a record; the forge run for a log entry) succeeded."
        )
        if cmd in ("promote-deploy", "promote-sync"):
            out.append(
                "Check the pending record first: VERIFY_PENDING=true forge script script/Verify.s.sol --rpc-url <rpc>; "
                f"only if that passes, run: {rerun}"
            )
        else:
            out.append(f"Only if the forge run that wrote the entry succeeded, run: {rerun}")
        return out

    # A real obstacle while --confirmed was given.
    if confirmed and cmd == "promote-deploy":
        out.append("The caller stated (--confirmed) that the broadcast succeeded and Verify passed against the pending "
                   "record. Do NOT re-run deploy.sh for this deployment: only the file promotion is left.")
    elif confirmed and cmd == "promote-sync":
        out.append("The caller stated (--confirmed) that Verify passed against the pending (synced) record.")
    elif confirmed and cmd == "append-op":
        out.append("The caller stated (--confirmed) that the forge run which wrote this entry succeeded.")
    if "DIFFERENT content" in reason:
        out.append("Compare the named archive file with the tracked record; rename the stray archive file (do not delete "
                   "a record you have not read), then re-run the command.")
    else:
        out.append("Fix the cause stated above, then re-run the command.")
    out.append(f"Re-run (resumes safely): {rerun}")
    return out


# ------------------------------------------------------------------------------------------------- self-test


def selftest():
    me = os.path.abspath(__file__)

    def run(d, *args):
        r = subprocess.run([sys.executable, me, *args[:1], d, *args[1:]], capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    rec = lambda block: json.dumps({"chainId": 999, "deployBlock": block, "timelock": "0xaa"}) + "\n"
    cases = []

    def case(name, setup, args, rc, must, must_not=()):
        with tempfile.TemporaryDirectory() as d:
            setup(d)
            code, text = run(d, *args)
            ok = code == rc and all(m in text for m in must) and not any(m in text for m in must_not)
            cases.append((name, ok, code, text))

    def w(d, name, text):
        os.makedirs(os.path.dirname(os.path.join(d, name)), exist_ok=True)
        with open(os.path.join(d, name), "w") as f:
            f.write(text)

    false_claims = ("Verify PASSED", "Do NOT re-run deploy.sh", "broadcast landed", "The caller stated")
    case("empty dir, promote-deploy", lambda d: None, ("promote-deploy", "999", "--confirmed"), 1,
         ["Nothing to promote: there is no pending record", "performs no chain action and implies none"], false_claims)
    case("empty dir, promote-sync", lambda d: None, ("promote-sync", "999", "--confirmed"), 1,
         ["Nothing to promote", "implies none"], false_claims)
    case("empty dir, append-op", lambda d: None, ("append-op", "999", "--confirmed"), 1,
         ["no pending operation entry", "implies none"], false_claims)
    case("pending only, without --confirmed", lambda d: w(d, "999.pending.json", rec(2)),
         ("promote-deploy", "999"), 1, ["--confirmed was not given", "Nothing was changed", "VERIFY_PENDING=true"],
         false_claims)
    case("pending only, confirmed", lambda d: w(d, "999.pending.json", rec(2)),
         ("promote-deploy", "999", "--confirmed"), 0, ["promoted"], ("DID NOT COMPLETE",))
    case("pending + archive already copied (identical)",
         lambda d: (w(d, "999.json", rec(1)), w(d, "999.pending.json", rec(2)), w(d, "archive/999-1.json", rec(1))),
         ("promote-deploy", "999", "--confirmed"), 0, ["already present, identical", "promoted"], ("DID NOT COMPLETE",))
    case("pending + different archive file",
         lambda d: (w(d, "999.json", rec(1)), w(d, "999.pending.json", rec(2)), w(d, "archive/999-1.json", "stray\n")),
         ("promote-deploy", "999", "--confirmed"), 1,
         ["DIFFERENT content", "The caller stated (--confirmed)", "Do NOT re-run deploy.sh", "rename the stray", "--confirmed"])
    case("final already promoted (record, no pending)", lambda d: w(d, "999.json", rec(2)),
         ("promote-deploy", "999", "--confirmed"), 1,
         ["Nothing to promote", "implies none", "A tracked record exists (deployBlock 2)", "already completed"],
         false_claims)
    entry = json.dumps({"action": "schedule", "id": "0x01", "timelock": "0xAA"}) + "\n"
    case("duplicate append",
         lambda d: (w(d, "999-operations.json", json.dumps({"operations": [json.loads(entry.lower())]})),
                    w(d, "999-operations.pending.json", entry)),
         ("append-op", "999", "--confirmed"), 0, ["already in", "not appended twice"], ("DID NOT COMPLETE",))

    failed = 0
    for name, ok, code, text in cases:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}")
        if not ok:
            failed += 1
            print(f"        exit {code}; output:\n" + "\n".join("        | " + l for l in text.splitlines()))
    print(f"records.py self-test: {len(cases) - failed}/{len(cases)} passed")
    sys.exit(1 if failed else 0)


def main():
    if sys.argv[1:] == ["--selftest"]:
        selftest()
    args = sys.argv[1:]
    confirmed = "--confirmed" in args
    args = [a for a in args if a != "--confirmed"]
    if len(args) != 3 or args[0] not in COMMANDS:
        print("usage: records.py promote-deploy|promote-sync|append-op|fail DIR CHAIN [--confirmed] | --selftest",
              file=sys.stderr)
        sys.exit(2)
    cmd, d, chain = args
    p = paths(d, chain)
    try:
        COMMANDS[cmd](p, chain, confirmed)
    except (Refused, OSError, ValueError) as exc:
        print("\n".join(diagnose(cmd, p, chain, confirmed, str(exc))), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
