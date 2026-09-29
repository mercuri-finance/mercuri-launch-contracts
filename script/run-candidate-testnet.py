#!/usr/bin/env python3
"""Prepare an isolated copy, then sign the authorized Arc testnet validation locally.

--prepare-only needs no key and sends no transactions. --run prompts on a real
Terminal, never reads .env, and never accepts a key as an argument or writes it.
"""
import argparse
import datetime as dt
import fcntl
import getpass
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import sys
import tempfile
import warnings

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / '.release-evidence/mainnet-2026-09-21/live-candidate'
STATE = EVIDENCE / 'runner-status.json'
RPC = 'https://rpc.testnet.arc.io'
CHAIN = 5042002
MIN_BALANCE = 12 * 10**18  # Headroom, not an expected spend; testnet USDC only.
BLOCKED_SIGNERS = {
    '0x36e5f6ae800846dbf5ccd271f7fe47a9e056b595',
    '0x547868711d885b2e26f2c8d9d05ee599ea0b9be8',
    '0xe4fb7b7a045acbacdd50acaa36b3b9e7aa9cebe3',
    '0xbeae85e3f6a37d3add6f4744e5f41a9ef5f11c06',
}
COMPILER_REPORT = 'docs/reports/2026-09-21-critical-pass-compiler-evidence.json'
FROZEN_MANIFEST = 'docs/reports/2026-09-21-critical-pass-candidate-manifest.json'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def environment():
    # Do not inherit credentials, endpoint overrides, tracing or compiler overrides.
    return {**{k: os.environ[k] for k in ('HOME', 'PATH')}, 'FOUNDRY_OFFLINE': 'true',
            'FOUNDRY_NO_STORAGE_CACHING': 'true', 'NO_COLOR': '1', 'RUST_BACKTRACE': '0'}


def public_command(args, cwd, env=None):
    result = subprocess.run(args, cwd=cwd, env=env or environment(), capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'Public preflight command failed ({args[0]}): {result.stderr[-1500:]}')
    return result.stdout.strip()


def save(state):
    state['updatedAt'] = dt.datetime.now(dt.timezone.utc).isoformat()
    tmp = STATE.with_suffix('.tmp')
    tmp.write_text(json.dumps(state, indent=2) + '\n')
    tmp.replace(STATE)


def protected_files():
    paths = [p for p in (ROOT / 'contracts/deployments').rglob('*')
             if p.is_file() and 'candidates' not in p.relative_to(ROOT / 'contracts/deployments').parts
             and not any(part.startswith('.env') for part in p.parts)]
    paths += list((ROOT / 'tools/smoke/runs').glob('*.json'))
    paths += [ROOT / 'tools/smoke/last-run.json']
    return {str(p.relative_to(ROOT)): sha(p.read_bytes()) if p.exists() else None for p in paths}


def verify_sources(work):
    report = json.loads((ROOT / COMPILER_REPORT).read_text())
    for name, identity in report['sourceIdentities'].items():
        if sha((work / 'contracts' / name).read_bytes()) != identity['sha256']:
            raise RuntimeError('Production compiler source changed: ' + name)
    return report


def verify_artifacts(work):
    report = verify_sources(work)
    file = work / 'contracts/script/prepare-release-evidence.py'
    spec = importlib.util.spec_from_file_location('release_evidence', file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    deploy = json.loads((work / 'contracts/out/Deploy.s.sol/Deploy.json').read_text())
    for name, source in module.TARGETS.items():
        artifact = module.matching_artifact(work / 'contracts/out' / Path(source).name,
                                            name, report['settings'], deploy['metadata']['compiler'])
        for kind in ('bytecode', 'deployedBytecode'):
            if sha(bytes.fromhex(artifact[kind]['object'].removeprefix('0x'))) != report['contracts'][name][kind + 'Sha256']:
                raise RuntimeError('Artifact differs from audited candidate: ' + name + ' ' + kind)
    return {'sourceMatches': len(report['sourceIdentities']), 'artifactPairsMatched': len(module.TARGETS)}


def preflight_network(work, deployment):
    def cast(*args):
        return public_command(['cast', *args, '--rpc-url', RPC], work / 'contracts')
    if int(cast('chain-id')) != CHAIN:
        raise RuntimeError('RPC is not Arc testnet')
    codes = {}
    for key in ('poolManager', 'positionManager', 'permit2', 'usdc'):
        code = cast('code', deployment[key])
        # USDC is a native precompile, so its getCode may be empty.
        if key != 'usdc' and len(code) <= 2:
            raise RuntimeError('Missing external dependency: ' + key)
        codes[key] = sha(bytes.fromhex(code.removeprefix('0x')))
    for signature, key in [('poolManager()(address)', 'poolManager'), ('permit2()(address)', 'permit2')]:
        if cast('call', deployment['positionManager'], signature).lower() != deployment[key].lower():
            raise RuntimeError('PositionManager dependency mismatch: ' + key)
    if int(cast('call', deployment['usdc'], 'decimals()(uint8)')) != 6:
        raise RuntimeError('Unexpected USDC decimals')
    # The exact runtime verifier must be able to use this endpoint after broadcast.
    probe = "import json,urllib.request; r=urllib.request.Request('" + RPC + "',json.dumps({'jsonrpc':'2.0','id':1,'method':'eth_chainId','params':[]}).encode(),{'Content-Type':'application/json','User-Agent':'mercuri-runtime-verifier'}); print(json.load(urllib.request.urlopen(r,timeout=30))['result'])"
    if int(public_command(['python3', '-c', probe], work), 16) != CHAIN:
        raise RuntimeError('Runtime verification transport is unavailable')
    return {'chainId': CHAIN, 'block': int(cast('block-number')), 'dependencyCodeSha256': codes}


def prepare():
    previous = json.loads(STATE.read_text()) if STATE.exists() else {}
    if previous.get('phase') in ('signing', 'deploying', 'smoke', 'failed'):
        raise RuntimeError('Inspect the existing run before preparing another; no blind deployment retries')
    frozen = json.loads((ROOT / FROZEN_MANIFEST).read_text())
    names = {name for name in frozen['files'] if name.startswith('contracts/')}
    names |= {str(p.relative_to(ROOT)) for glob in ('*.py', '*.sh') for p in (ROOT / 'contracts/script').glob(glob)}
    names |= {str(p.relative_to(ROOT)) for p in (ROOT / 'contracts/test/tooling').glob('*.py')}
    names |= {str(p.relative_to(ROOT)) for glob in ('*.mjs', 'package*.json') for p in (ROOT / 'tools/smoke').glob(glob)}
    names |= {COMPILER_REPORT, FROZEN_MANIFEST}
    # /tmp is outside the checkout: Foundry cannot auto-discover the repository .env.
    prior_work = Path(previous.get('workspace', '/nonexistent'))
    if (previous.get('phase') in ('preparing', 'prepared') and prior_work.is_dir()
            and prior_work.parent == Path(tempfile.gettempdir()).resolve()
            and prior_work.name.startswith('mercuri-live-candidate-')):
        work = prior_work  # Reuse only an unbroadcast build cache, never a failed live run.
    else:
        work = Path(tempfile.mkdtemp(prefix='mercuri-live-candidate-')).resolve()
    if any((parent / '.env').exists() for parent in [work, *work.parents]):
        raise RuntimeError('Isolated workspace has a .env ancestor; choose a clean temporary directory')
    inputs = {}
    for name in sorted(names):
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or any(part.startswith('.env') for part in path.parts):
            raise RuntimeError('Unsafe manifest path')
        data = (ROOT / name).read_bytes()
        target = work / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        inputs[name] = sha(data)
    if inputs['contracts/foundry.toml'] != frozen['files']['contracts/foundry.toml']['sha256']:
        raise RuntimeError('Foundry settings changed since reviewed candidate')
    verify_sources(work)
    modules = work / 'tools/smoke/node_modules'
    if not modules.exists():
        modules.symlink_to(ROOT / 'tools/smoke/node_modules', target_is_directory=True)
    elif modules.resolve() != (ROOT / 'tools/smoke/node_modules').resolve():
        raise RuntimeError('Unexpected dependency directory in prepared workspace')
    run_id = dt.datetime.now(dt.timezone.utc).strftime('audit-%Y%m%dT%H%M%SZ')
    directory = work / 'contracts/deployments/candidates' / run_id
    directory.mkdir(parents=True)
    state = {'phase': 'preparing', 'workspace': str(work), 'candidateDirectory': str(directory),
             'runId': run_id, 'inputs': inputs, 'protectedFiles': protected_files(),
             'rpc': RPC, 'chainId': CHAIN, 'keyHandling': 'Terminal getpass; signer child environment only'}
    save(state)
    print('Building and checking the isolated copy. No key or transaction is involved.', flush=True)
    # Build from the reviewed sources in a directory with no .env.
    output = public_command(['forge', 'build'], work / 'contracts')
    (EVIDENCE / (run_id + '-build.log')).write_text(output + '\n')
    state['compilerIdentity'] = verify_artifacts(work)
    checks = public_command(['node', 'smoke.mjs', '--check'], work / 'tools/smoke')
    (EVIDENCE / (run_id + '-smoke-check.log')).write_text(checks + '\n')
    deployment = json.loads((work / 'contracts/deployments/5042002.json').read_text())
    state['network'] = preflight_network(work, deployment)
    state['phase'] = 'prepared'
    save(state)
    print('Prepared: 107 compiler sources and 10 artifact pairs matched. No transactions sent.')


def normalize_key(value):
    value = value.strip().removeprefix('0x')
    if not re.fullmatch('[0-9a-fA-F]{64}', value):
        raise ValueError('Expected a 32-byte testnet private key; input was not saved')
    return '0x' + value


def validate_signer(address):
    if not re.fullmatch('0x[0-9a-fA-F]{40}', address):
        raise ValueError('Signer derivation failed')
    if address.lower() in BLOCKED_SIGNERS:
        raise ValueError('Refusing a mainnet deployer or governance signer; use a testnet-only wallet')


def run():
    if not sys.stdin.isatty():
        raise RuntimeError('Run this command directly in your local Terminal for the private prompt')
    state = json.loads(STATE.read_text())
    if state['phase'] != 'prepared':
        raise RuntimeError('This run is not fresh/prepared. Inspect status; do not blindly retry broadcasts')
    work = Path(state['workspace'])
    for name, digest in state['inputs'].items():
        if sha((ROOT / name).read_bytes()) != digest or sha((work / name).read_bytes()) != digest:
            raise RuntimeError('Prepared input changed; prepare again before signing: ' + name)
    if protected_files() != state['protectedFiles']:
        raise RuntimeError('Canonical testnet records changed since preparation')
    verify_artifacts(work)
    deployment = json.loads((work / 'contracts/deployments/5042002.json').read_text())
    preflight_network(work, deployment)
    print('Arc TESTNET only (5042002). Use an otherwise idle testnet-only wallet with at least 12 testnet USDC.')
    with warnings.catch_warnings():
        warnings.simplefilter('error', getpass.GetPassWarning)
        key = normalize_key(getpass.getpass('Testnet-only private key (hidden; never saved): '))
    derived = subprocess.run(['node', '--input-type=module', '-e',
        "import {privateKeyToAccount} from 'viem/accounts'; let k=''; for await(const c of process.stdin) k+=c; try {console.log(privateKeyToAccount(k.trim()).address)} catch {process.exit(1)}"],
        input=key, cwd=work / 'tools/smoke', env=environment(), capture_output=True, text=True)
    if derived.returncode:
        raise ValueError('Invalid signing key; input was not saved')
    address = derived.stdout.strip()
    validate_signer(address)
    print('Testnet signer:', address, flush=True)
    def cast(*args):
        return public_command(['cast', *args, '--rpc-url', RPC], work / 'contracts')
    starting_nonce = cast('nonce', address, '--block', 'latest')
    if cast('nonce', address, '--block', 'pending') != starting_nonce:
        raise RuntimeError('Signer has pending transactions; leave it idle and settle those first')
    if cast('code', address) != '0x':
        raise RuntimeError('Use a plain testnet EOA without delegated code')
    balance = int(cast('balance', address))
    if balance < MIN_BALANCE:
        raise RuntimeError(f'Fund TESTNET address {address} to at least 12 testnet USDC, then run again; nothing was sent')
    state.update(phase='signing', signer=address, balanceBeforeWei=str(balance))
    save(state)
    directory = state['candidateDirectory']
    env = environment()
    env.update(DEPLOYER_PRIVATE_KEY=key, ARC_RPC=RPC, EXPECTED_CHAIN_ID=str(CHAIN),
               DEPLOYMENTS_DIR=directory, SMOKE_DEPLOYMENTS_DIR=directory, TIMELOCK_DELAY='60',
               **{k.upper(): deployment[v] for k, v in [('pool_manager', 'poolManager'),
                  ('position_manager', 'positionManager'), ('permit2', 'permit2')]})
    redact = re.compile(re.escape(key[2:]), re.IGNORECASE)
    log_path = EVIDENCE / (state['runId'] + '-runner.log')
    def signing_command(args, cwd):
        with log_path.open('a') as log:
            child = subprocess.Popen(args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True)
            try:
                for line in child.stdout:
                    safe = redact.sub('[REDACTED]', line)
                    print(safe, end='', flush=True)
                    log.write(safe)
                    log.flush()
                if child.wait():
                    raise RuntimeError('Candidate step failed. Inspect the public log; do not repeat deployment blindly')
            except BaseException:
                if child.poll() is None:
                    child.terminate()
                    child.wait()
                raise
    try:
        signing_command(['bash', 'script/deploy.sh', '--dry-run', '--no-env', '--isolated-testnet'], work / 'contracts')
        if (cast('nonce', address, '--block', 'latest') != starting_nonce
                or cast('nonce', address, '--block', 'pending') != starting_nonce):
            raise RuntimeError('Signer nonce changed during dry-run; inspect activity before broadcasting')
        state['phase'] = 'deploying'
        save(state)
        signing_command(['bash', 'script/deploy.sh', '--no-env', '--isolated-testnet'], work / 'contracts')
        state['phase'] = 'smoke'
        save(state)
        signing_command(['node', 'smoke.mjs', '--no-env', '--isolated-testnet'], work / 'tools/smoke')
        result = json.loads((Path(directory) / 'last-run.json').read_text())
        if result.get('verdict') != 'pass':
            raise RuntimeError('Smoke did not record a passing verdict')
        state['phase'] = 'passed'
    except BaseException:
        state['phase'] = 'failed'
        raise
    finally:
        # Only public record files are copied back; signing caches remain in the isolated workspace.
        destination = ROOT / 'contracts/deployments/candidates' / state['runId']
        if destination.exists():
            state['phase'] = 'failed'
        else:
            shutil.copytree(directory, destination)
        state['publicRecords'] = str(destination)
        state['canonicalRecordsUnchanged'] = protected_files() == state['protectedFiles']
        if not state['canonicalRecordsUnchanged']:
            state['phase'] = 'failed'
        save(state)
        env.pop('DEPLOYER_PRIVATE_KEY', None)
        key = None
    if state['phase'] != 'passed':
        raise RuntimeError('Candidate preservation checks failed; inspect runner-status.json')
    print('Candidate validation passed. Mainnet remains unapproved and unchanged.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--prepare-only', action='store_true')
    mode.add_argument('--run', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    with (EVIDENCE / 'runner.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        prepare() if args.prepare_only else run()


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print('STOP:', str(error) or 'Interrupted; inspect status before retrying', file=sys.stderr)
        sys.exit(1)
