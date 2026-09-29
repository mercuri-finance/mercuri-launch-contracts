#!/usr/bin/env python3
"""Archive selected public release inputs without changing Git or reading .env.

This is an evidence snapshot, not a deployable image or approved release commit.
Run from any directory; all paths are resolved relative to this repository.
"""
import argparse
import datetime
import hashlib
import io
import json
import pathlib
import subprocess
import tarfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
EXTENSIONS = {'.sol', '.go', '.sql', '.sh', '.py', '.mjs', '.toml', '.json', '.yaml', '.yml'}
NAMES = {'Dockerfile', 'Makefile', 'go.mod', 'go.sum', 'remappings.txt', '.gas-snapshot', '.dockerignore'}


def git(*args, directory=ROOT):
    return subprocess.check_output(['git', '-C', str(directory), *args]).decode().strip()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=pathlib.Path, required=True)
    parser.add_argument('--manifest', type=pathlib.Path, required=True)
    parser.add_argument('--include-smoke', action='store_true', help='also freeze the live candidate validation scripts')
    args = parser.parse_args()
    if args.archive.exists() or args.manifest.exists():
        raise SystemExit('refusing to overwrite evidence')
    paths = ['contracts', 'backend', 'render-mainnet.yaml']
    if args.include_smoke:
        paths.append('tools/smoke')
    listing = git('ls-files', '-z', '--cached', '--others', '--exclude-standard', *paths).split('\0')
    contents = {}
    for name in sorted(set(listing)):
        if not name:
            continue
        path = ROOT / name
        if any(part.startswith('.env') or part in {'__pycache__', 'node_modules'} for part in path.parts):
            continue
        if path.suffix not in EXTENSIONS and path.name not in NAMES:
            continue
        if path.is_symlink() or not path.resolve().is_relative_to(ROOT):
            raise ValueError('refusing symlink/outside input: ' + name)
        if not path.is_file():
            raise ValueError('missing input: ' + name)
        contents[name] = path.read_bytes()
    frontend = {}
    for name in ['mercuri-launch-webui', 'mercuri-documentation-webui', 'mercuri-landing-webui']:
        path = ROOT / name
        frontend[name] = {'commit': git('rev-parse', 'HEAD', directory=path),
                          'status': git('status', '--short', directory=path),
                          'archived': False}
    files = {name: {'sha256': digest(data), 'bytes': len(data)} for name, data in contents.items()}
    args.archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(args.archive, 'w:gz') as archive:
        for name, data in contents.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))
    manifest = {
        'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'status': 'local selected-source snapshot; uncommitted, not approved or deployed',
        'baseCommit': git('rev-parse', 'HEAD'),
        'scope': 'tracked and nonignored contract/backend files with explicit source/config extensions, plus render-mainnet.yaml; frontend Git identities only'
                 + ('; includes tools/smoke source and dependency lockfile' if args.include_smoke else ''),
        'exclusions': ['all .env files', 'private credentials', 'generated Foundry output/broadcast/cache',
                       'dependency non-source assets', 'frontend working-tree assets', 'release reports'],
        'archive': str(args.archive), 'archiveSha256': digest(args.archive.read_bytes()),
        'sourceManifestSha256': digest(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()),
        'files': files, 'frontendRepositories': frontend,
        'missingCanonicalMainnetRecords': [p for p in ['contracts/deployments/5042.json',
            'contracts/deployments/5042-operations.json', 'backend/config/mainnet/deployment.json',
            'backend/config/mainnet/implementations.json'] if not (ROOT / p).exists()],
    }
    # Refuse a misleading snapshot if an input changed during collection.
    for name, data in contents.items():
        if (ROOT / name).read_bytes() != data:
            raise ValueError('input changed during snapshot: ' + name)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'files': len(files), 'archiveBytes': args.archive.stat().st_size,
                      'sourceManifestSha256': manifest['sourceManifestSha256'],
                      'manifest': str(args.manifest)}))


if __name__ == '__main__':
    main()
