#!/usr/bin/env python3
"""Read-only candidate identity and compiler screen; never loads .env or uses RPC.

Recompile the existing Deploy artifact's exact source/settings with the installed
0.8.26 compiler. Fail on stale source metadata or changed protocol bytecode.
Archive output outside tracked artifacts. This is not audit approval or a deploy.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / 'contracts'
NAMES = ['LaunchFactory', 'BondingCurve', 'FeeManager', 'GraduationManager',
         'LaunchHook', 'LaunchToken', 'LiquidityLocker']
TARGETS = {name: 'src/' + name + '.sol' for name in NAMES}
TARGETS.update({
    'TimelockController': 'lib/openzeppelin-contracts/contracts/governance/TimelockController.sol',
    'ERC1967Proxy': 'lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol',
    'Deploy': 'script/Deploy.s.sol',
})


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tokens(source):
    pattern = r'/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[A-Za-z_$][A-Za-z0-9_$]*|[^\s]'
    return [t for t in re.findall(pattern, source) if not t.startswith(('//', '/*'))]


def brace_end(ts, start):
    depth = 0
    for i in range(start, len(ts)):
        depth += (ts[i] == '{') - (ts[i] == '}')
        if depth == 0:
            return i
    raise ValueError('unbalanced Yul block')


def yul_cycles(source):
    """Conservative named-function graph, separately for each Yul code block."""
    ts = tokens(source)
    results = []
    for pos in range(len(ts) - 1):
        if ts[pos:pos + 2] != ['code', '{']:
            continue
        end = brace_end(ts, pos + 1)
        functions = {}
        i = pos + 2
        while i < end:
            if ts[i] != 'function':
                i += 1
                continue
            name = ts[i + 1]
            begin = ts.index('{', i + 2, end)
            stop = brace_end(ts, begin)
            if name in functions:
                raise ValueError('duplicate function in code scope: ' + name)
            functions[name] = ts[begin + 1:stop]
            i = stop + 1
        graph = {name: {body[j] for j in range(len(body) - 1)
                        if body[j + 1] == '(' and body[j] in functions}
                 for name, body in functions.items()}
        # Tarjan strongly connected components distinguish self from mutual recursion.
        index, low, stack, active, components = {}, {}, [], set(), []

        def visit(v):
            index[v] = low[v] = len(index)
            stack.append(v)
            active.add(v)
            for w in graph[v]:
                if w not in index:
                    visit(w)
                    low[v] = min(low[v], low[w])
                elif w in active:
                    low[v] = min(low[v], index[w])
            if low[v] == index[v]:
                component = []
                while True:
                    w = stack.pop()
                    active.remove(w)
                    component.append(w)
                    if w == v:
                        break
                if len(component) > 1 or v in graph[v]:
                    components.append(sorted(component))

        for v in graph:
            if v not in index:
                visit(v)
        results.append({'functions': len(functions), 'recursiveComponents': components})
    return results


def matching_artifact(directory, name, settings, compiler):
    """Select the Deploy compilation settings, never infer a profile from its name."""
    expected = {k: v for k, v in settings.items() if k not in {'compilationTarget', 'outputSelection'}}
    paths = {directory / (name + '.json'), *directory.glob(name + '.*.json')}
    matches = []
    for path in sorted(paths):
        if not path.is_file():
            continue
        artifact = json.loads(path.read_text())
        metadata = artifact['metadata']
        actual = {k: v for k, v in metadata['settings'].items() if k != 'compilationTarget'}
        if actual == expected and metadata['compiler'] == compiler:
            matches.append(artifact)
    if len(matches) != 1:
        raise ValueError(f'{name}: expected one artifact matching Deploy settings/compiler; found {len(matches)}')
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--solc', required=True, type=pathlib.Path)
    parser.add_argument('--output', required=True, type=pathlib.Path)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    compiler_version = subprocess.check_output([str(args.solc), '--version'], text=True)
    if '0.8.26+commit.8a97fa7a' not in compiler_version:
        raise SystemExit('wrong compiler version')
    meta = json.loads((CONTRACTS / 'out/Deploy.s.sol/Deploy.json').read_text())['metadata']
    sources, identities = {}, {}
    for name, identity in sorted(meta['sources'].items()):
        path = (CONTRACTS / name).resolve()
        if not path.is_relative_to(CONTRACTS) or path.suffix != '.sol':
            raise ValueError('unexpected source path: ' + name)
        data = path.read_bytes()
        actual = subprocess.check_output(['cast', 'keccak', '0x' + data.hex()], text=True).strip()
        if actual.lower() != identity['keccak256'].lower():
            raise ValueError('stale artifact source: ' + name)
        sources[name] = {'content': data.decode()}
        identities[name] = {'sha256': sha(data), 'keccak256': actual}
    settings = dict(meta['settings'])
    settings.pop('compilationTarget', None)
    settings['outputSelection'] = {'*': {'': ['ast'], '*': ['ir', 'irOptimized',
        'evm.bytecode.object', 'evm.deployedBytecode.object']}}
    payload = {'language': 'Solidity', 'sources': sources, 'settings': settings}
    encoded = json.dumps(payload).encode()
    (out / 'compiler-input.json').write_bytes(encoded)
    result = subprocess.run([str(args.solc), '--standard-json'], input=encoded, capture_output=True)
    result.check_returncode()
    (out / 'compiler-output.json').write_bytes(result.stdout)
    compiled = json.loads(result.stdout)
    errors = [e for e in compiled.get('errors', []) if e['severity'] == 'error']
    if errors:
        raise ValueError(errors)
    report = {'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'status': 'candidate identity and compiler screen only; not release approval',
              'compilerVersion': compiler_version.strip(), 'compilerSha256': sha(args.solc.read_bytes()),
              'inputSha256': sha(encoded), 'sourceIdentities': identities,
              'settings': {k: v for k, v in settings.items() if k != 'outputSelection'},
              'contracts': {}, 'warnings': compiled.get('errors', [])}
    for name, file in TARGETS.items():
        current = compiled['contracts'][file][name]
        baseline = matching_artifact(CONTRACTS / 'out' / pathlib.Path(file).name, name,
                                     settings, meta['compiler'])
        entry = {}
        for key in ['bytecode', 'deployedBytecode']:
            code = current['evm'][key]['object']
            if code != baseline[key]['object'].removeprefix('0x'):
                raise ValueError('candidate bytecode differs: ' + name + ' ' + key)
            entry[key + 'Sha256'] = sha(bytes.fromhex(code))
            entry[key + 'Bytes'] = len(code) // 2
        for key in ['ir', 'irOptimized']:
            entry[key] = yul_cycles(current[key])
            (out / (name + '.' + key + '.yul')).write_text(current[key])
        report['contracts'][name] = entry
    # AST screen: named custom errors as the second argument of require.
    findings = []

    def walk(value, source):
        if isinstance(value, dict):
            if value.get('nodeType') == 'FunctionCall' and value.get('expression', {}).get('name') == 'require':
                arguments = value.get('arguments', [])
                if len(arguments) > 1 and arguments[1].get('names'):
                    findings.append({'source': source, 'src': value.get('src')})
            for child in value.values():
                walk(child, source)
        elif isinstance(value, list):
            for child in value:
                walk(child, source)

    for source, data in compiled['sources'].items():
        walk(data.get('ast'), source)
    report['namedCustomErrorsInRequire'] = findings
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'report': str(out / 'report.json'), 'sources': len(sources),
                      'bytecodeMatches': len(TARGETS), 'namedCustomErrorsInRequire': findings,
                      'recursiveComponents': {name: {key: [c for scope in entry[key]
                          for c in scope['recursiveComponents']] for key in ['ir', 'irOptimized']}
                          for name, entry in report['contracts'].items()}}, indent=2))


if __name__ == '__main__':
    main()
