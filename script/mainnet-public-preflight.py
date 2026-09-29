#!/usr/bin/env python3
"""Read-only Arc mainnet prerequisites. No .env, private keys or transactions.

Writes a public evidence report, never a canonical deployment record. Requires
curl and cast. Re-run immediately before the separately approved deployment.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import subprocess

RPC = 'https://rpc.mainnet.arc.io'
REGISTRY = 'https://raw.githubusercontent.com/Uniswap/contracts/main/deployments/json/5042.json'
DEPLOYER = '0x36E5f6AE800846DBf5cCd271f7fe47a9e056b595'
EXTERNALS = {
    'PoolManager': '0x8366a39CC670B4001A1121B8F6A443A643e40951',
    'PositionManager': '0x6049c9a0e26405c0985f9e3685c87d0ae917f82b',
    'Permit2': '0x000000000022D473030F116dDEE9F6B43aC78BA3',
    'Create2Deployer': '0x4e59b44847b379578588920cA78FbF26c0B4956C',
    'USDC': '0x3600000000000000000000000000000000000000',
}
SAFES = {
    'governance': '0xF768e819E7B5AB54aF7561a73092C5E0C1A45b4F',
    'guardian': '0xbcD634D133Ec05abFAB018e78138b370c4f912B0',
    'treasury': '0x34E3321e97BBa4F5c7A0aCc6b09C50bE9173912D',
}
OWNERS = {
    '0x547868711d885B2E26F2C8D9D05Ee599Ea0b9be8'.lower(),
    '0xe4FB7b7A045ACBACdd50AcAA36b3B9E7Aa9cebE3'.lower(),
    '0xBEae85E3F6A37d3ADD6f4744E5f41A9EF5f11c06'.lower(),
}


def command(*args, data=None):
    return subprocess.run(args, input=data, text=True, capture_output=True,
                          check=True, timeout=45).stdout.strip()


def rpc(method, params):
    assert method in {'eth_chainId', 'eth_blockNumber', 'eth_getBlockByNumber',
                      'eth_getBalance', 'eth_getTransactionCount', 'eth_getCode', 'eth_call'}
    payload = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
    result = json.loads(command('curl', '--silent', '--show-error', '--fail',
                               '--max-time', '30', '-H', 'Content-Type: application/json',
                               '--data-binary', '@-', RPC, data=payload))
    if 'error' in result:
        raise ValueError(result['error'])
    return result['result']


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=pathlib.Path, required=True)
    args = p.parse_args()
    if args.output.exists():
        raise SystemExit('refusing to overwrite existing evidence')
    registry_raw = command('curl', '--silent', '--show-error', '--fail', '--max-time', '30', REGISTRY)
    registry = json.loads(registry_raw)
    if int(registry['chainId']) != 5042 or int(rpc('eth_chainId', []), 16) != 5042:
        raise ValueError('wrong chain')
    block = rpc('eth_blockNumber', [])
    header = rpc('eth_getBlockByNumber', [block, False])
    checks = {}
    for name in ('PoolManager', 'PositionManager', 'Permit2'):
        checks['registry:' + name] = registry['latest'][name]['address'].lower() == EXTERNALS[name].lower()
    codes = {}
    for name, address in {**EXTERNALS, **SAFES}.items():
        code = rpc('eth_getCode', [address, block])
        codes[name] = {'address': address, 'bytes': (len(code) - 2) // 2,
                       'keccak256': command('cast', 'keccak', code)}
        checks['code:' + name] = code != '0x'

    def call(address, signature):
        return rpc('eth_call', [{'to': address, 'data': command('cast', 'calldata', signature)}, block])

    wiring = {}
    for getter, name in [('poolManager()', 'PoolManager'), ('permit2()', 'Permit2')]:
        value = '0x' + call(EXTERNALS['PositionManager'], getter)[-40:]
        wiring[getter] = value
        checks['wiring:' + getter] = value.lower() == EXTERNALS[name].lower()
    checks['usdcDecimals'] = int(call(EXTERNALS['USDC'], 'decimals()'), 16) == 6
    safes = {}
    for name, address in SAFES.items():
        threshold = int(call(address, 'getThreshold()'), 16)
        owners_raw = bytes.fromhex(call(address, 'getOwners()')[2:])
        offset = int.from_bytes(owners_raw[:32], 'big')
        count = int.from_bytes(owners_raw[offset:offset+32], 'big')
        owners = ['0x' + owners_raw[offset+32+i*32+12:offset+64+i*32].hex() for i in range(count)]
        safes[name] = {'threshold': threshold, 'owners': owners}
        checks['safeConfig:' + name] = threshold == 2 and len(owners) == 3 and set(owners) == OWNERS
    balance = int(rpc('eth_getBalance', [DEPLOYER, block]), 16)
    nonce = int(rpc('eth_getTransactionCount', [DEPLOYER, block]), 16)
    pending = int(rpc('eth_getTransactionCount', [DEPLOYER, 'pending']), 16)
    checks['deployerEOA'] = rpc('eth_getCode', [DEPLOYER, block]) == '0x'
    checks['deployerNoPendingNonce'] = nonce == pending
    checks['deployerExcludedFromRoles'] = DEPLOYER.lower() not in OWNERS | {x.lower() for x in SAFES.values()}
    checks['deployerMinimumBalance'] = balance >= 10**18
    # Re-read the pinned header to detect a reorg during collection.
    checks['sameBlockHash'] = rpc('eth_getBlockByNumber', [block, False])['hash'] == header['hash']
    report = {
        'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'status': 'public prerequisite snapshot only; not deployment or release approval',
        'chainId': 5042, 'block': int(block, 16), 'blockHash': header['hash'], 'rpc': RPC,
        'registryUrl': REGISTRY, 'registryResponseSha256': hashlib.sha256(registry_raw.encode()).hexdigest(),
        'externalsAndSafeCode': codes, 'positionManagerWiring': wiring, 'safes': safes,
        'deployer': {'address': DEPLOYER, 'balanceWei': str(balance), 'nonce': nonce,
                     'pendingNonce': pending, 'minimumBalanceWei': str(10**18), 'ownershipVerified': False},
        'checks': checks, 'failedChecks': [k for k, v in checks.items() if not v],
        'limitations': ['Code hashes are observations, not local bytecode reproductions of external deployments.',
                        'No signature, Safe execution, recovery test or mainnet broadcast performed.',
                        'Minimum balance is the wrapper floor, not an estimate of total deployment cost.',
                        'Recheck immediately before deployment; this snapshot does not reserve a nonce.'],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'report': str(args.output), 'block': report['block'], 'failedChecks': report['failedChecks']}))
    raise SystemExit(1 if report['failedChecks'] else 0)


if __name__ == '__main__':
    main()
