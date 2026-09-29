"""Fail-closed record isolation for explicitly requested live Arc testnet candidates."""
import argparse
import json
import pathlib
import re

PROTOCOL_KEYS = ('factory', 'feeManager', 'graduationManager', 'liquidityLocker', 'launchHook',
                 'timelock', 'factoryImplementation', 'feeManagerImplementation', 'graduationManagerImplementation')


def candidate_dir(value, base):
    base = pathlib.Path(base).resolve()
    raw = pathlib.Path(value)
    root = base / 'candidates'
    if '..' in raw.parts or root.is_symlink() or raw.is_symlink():
        raise ValueError('candidate directory must not traverse or use symlinks')
    result = raw.resolve()
    if result.parent != root or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,79}', result.name):
        raise ValueError('use deployments/candidates/<unique-run-id>; canonical records are forbidden')
    if result.exists() and not result.is_dir():
        raise ValueError('candidate path is not a directory')
    return result


def check_record(directory, base):
    record = json.loads((directory / '5042002.json').read_text())
    live = json.loads((pathlib.Path(base) / '5042002.json').read_text())
    if record.get('chainId') != 5042002:
        raise ValueError('candidate record must be Arc testnet')
    live_addresses = {live[k].lower() for k in PROTOCOL_KEYS}
    for key in PROTOCOL_KEYS:
        address = record.get(key, '')
        if not re.fullmatch(r'0x[0-9a-fA-F]{40}', address) or int(address, 16) == 0:
            raise ValueError('invalid candidate address: ' + key)
        if address.lower() in live_addresses:
            raise ValueError('candidate aliases the live deployment: ' + key)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dir', required=True)
    parser.add_argument('--base', default='./deployments')
    parser.add_argument('--check-record', action='store_true')
    args = parser.parse_args()
    directory = candidate_dir(args.dir, args.base)
    if args.check_record:
        check_record(directory, args.base)
    print(directory)


if __name__ == '__main__':
    main()
