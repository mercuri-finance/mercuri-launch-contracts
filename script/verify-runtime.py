#!/usr/bin/env python3
"""Read-only comparison of deployed code with this release's compiled artifacts.

ARC_RPC is read from the secured process environment, never printed. No .env is
loaded and no transactions are sent. Immutable address words are reconstructed,
not masked, so every deployed byte must match. Run before record promotion.
"""
import argparse
import json
import os
from pathlib import Path
import urllib.request

TARGETS = {
    'factoryImplementation': 'LaunchFactory',
    'feeManagerImplementation': 'FeeManager',
    'graduationManagerImplementation': 'GraduationManager',
    'launchHook': 'LaunchHook', 'liquidityLocker': 'LiquidityLocker',
}


def immutable_names(node, result):
    if isinstance(node, dict):
        if node.get('nodeType') == 'VariableDeclaration' and node.get('mutability') == 'immutable':
            result[str(node['id'])] = node['name']
        for value in node.values():
            immutable_names(value, result)
    elif isinstance(node, list):
        for value in node:
            immutable_names(value, result)


def expected_runtime(artifact, names, values):
    runtime = bytearray.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    refs = artifact['deployedBytecode'].get('immutableReferences', {})
    covered = set()
    for key, locations in refs.items():
        name = names.get(key)
        if name not in values:
            raise ValueError('unreviewed immutable: ' + str(name))
        value = bytes.fromhex(values[name].removeprefix('0x'))
        if len(value) != 20:
            raise ValueError('immutable must be an address')
        for ref in locations:
            start, length = ref['start'], ref['length']
            if length != 32 or start < 0 or start + length > len(runtime):
                raise ValueError('invalid immutable range')
            region = set(range(start, start + length))
            if region & covered or any(runtime[start:start + length]):
                raise ValueError('overlapping or nonzero immutable placeholder')
            covered.update(region)
            runtime[start:start + length] = value.rjust(32, b'\0')
    if not runtime:
        raise ValueError('empty compiled runtime')
    return bytes(runtime)


def verify_code(actual, expected, name):
    if actual != expected:
        raise ValueError(name + ': deployed runtime differs from reviewed artifact')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record', type=Path, required=True)
    parser.add_argument('--artifacts', type=Path, default=Path('out'))
    args = parser.parse_args()
    record = json.loads(args.record.read_text())
    url = os.environ['ARC_RPC']

    def rpc(method, params):
        assert method in ('eth_chainId', 'eth_blockNumber', 'eth_getCode', 'eth_getBlockByNumber')
        data = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
        req = urllib.request.Request(url, data, {'Content-Type': 'application/json', 'User-Agent': 'mercuri-runtime-verifier'})
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                result = json.load(response)
        except Exception:
            raise RuntimeError('RPC transport failed; endpoint details suppressed') from None
        if 'error' in result or 'result' not in result:
            raise RuntimeError('RPC verification read failed; inspect secured provider logs')
        return result['result']

    if int(rpc('eth_chainId', []), 16) != int(record['chainId']):
        raise ValueError('RPC chain does not match record')
    block = rpc('eth_blockNumber', [])
    block_hash = rpc('eth_getBlockByNumber', [block, False])['hash']
    artifacts = {}
    for name in TARGETS.values():
        artifact = json.loads((args.artifacts / (name + '.sol') / (name + '.json')).read_text())
        artifacts[name] = artifact
    checked = []
    for field, name in TARGETS.items():
        address = record[field]
        values = {'__self': address, 'poolManager': record['poolManager'],
                  'feeManager': record['feeManager'], 'graduationManager': record['graduationManager'],
                  'positionManager': record['positionManager'], 'usdc': record['usdc']}
        names = {}
        immutable_names(artifacts[name].get('ast'), names)
        if name in ('LaunchFactory', 'FeeManager', 'GraduationManager'):
            refs = artifacts[name]['deployedBytecode'].get('immutableReferences', {})
            if len(refs) != 1:
                raise ValueError('UUPS implementation must have exactly one reviewed immutable: __self')
            names = {next(iter(refs)): '__self'}
        expected = expected_runtime(artifacts[name], names, values)
        actual = bytes.fromhex(rpc('eth_getCode', [address, block]).removeprefix('0x'))
        verify_code(actual, expected, name)
        checked.append({'contract': name, 'address': address, 'bytes': len(actual)})
    if rpc('eth_getBlockByNumber', [block, False])['hash'] != block_hash:
        raise ValueError('block hash changed during verification')
    print(json.dumps({'chainId': record['chainId'], 'block': int(block, 16),
                      'blockHash': block_hash, 'exactRuntimeMatches': checked}, indent=2))


if __name__ == '__main__':
    main()
