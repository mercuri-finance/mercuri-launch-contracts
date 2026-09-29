"""The opt-in live testnet path must not weaken canonical/mainnet protections."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('candidate', ROOT / 'script/candidate_path.py')
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)


class CandidateIsolationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name) / 'deployments'
        self.base.mkdir()
        self.directory = self.base / 'candidates' / 'audit-2026-09-21'
        self.directory.mkdir(parents=True)

    def test_candidate_child_is_allowed(self):
        self.assertEqual(candidate.candidate_dir(self.directory, self.base), self.directory.resolve())

    def test_default_traversal_outside_and_symlinks_are_rejected(self):
        (self.base / 'candidates' / 'alias').symlink_to(self.directory, target_is_directory=True)
        for value in (self.base, self.base / 'candidates', self.base / 'candidates/../other',
                      Path(self.tmp.name) / 'other', self.base / 'candidates/alias'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                candidate.candidate_dir(value, self.base)

    def test_record_rejects_any_live_address_alias_and_wrong_chain(self):
        live = {k: '0x' + format(i + 1, '040x') for i, k in enumerate(candidate.PROTOCOL_KEYS)}
        record = {k: '0x' + format(i + 100, '040x') for i, k in enumerate(candidate.PROTOCOL_KEYS)}
        record['chainId'] = 5042002
        (self.base / '5042002.json').write_text(json.dumps(live))
        target = self.directory / '5042002.json'
        target.write_text(json.dumps(record))
        candidate.check_record(self.directory, self.base)
        record['launchHook'] = live['feeManager']
        target.write_text(json.dumps(record))
        with self.assertRaises(ValueError): candidate.check_record(self.directory, self.base)
        record['launchHook'] = '0x' + 'f' * 40
        record['chainId'] = 5042
        target.write_text(json.dumps(record))
        with self.assertRaises(ValueError): candidate.check_record(self.directory, self.base)

    def guard(self, chain, url, directory, flag):
        env = {k: os.environ[k] for k in ('HOME', 'PATH')}
        env.update(RPC_CHAIN_ID=str(chain), EXPECTED_CHAIN_ID=str(chain), ARC_RPC=url,
                   DEPLOYMENTS_DIR=directory, ISOLATED_TESTNET_FLAG=str(flag))
        return subprocess.run(['bash', '-ec', 'source script/common.sh; rehearsal_guard'],
                              cwd=ROOT, env=env, capture_output=True, text=True)

    def test_shell_exception_is_testnet_https_opt_in_only(self):
        directory = './deployments/candidates/test-guard'
        self.assertEqual(self.guard(5042002, 'https://rpc.testnet.arc.io', directory, 1).returncode, 0)
        for chain, rpc, folder, flag in (
            (5042, 'https://rpc.mainnet.arc.io', directory, 1),
            (5042002, 'http://127.0.0.1:8545', directory, 1),
            (5042002, 'http://rpc.testnet.arc.io', directory, 1),
            (5042002, 'https://rpc.testnet.arc.io', './deployments', 1),
            (5042002, 'https://rpc.testnet.arc.io', directory, 0),
        ):
            with self.subTest(chain=chain, rpc=rpc, folder=folder, flag=flag):
                self.assertNotEqual(self.guard(chain, rpc, folder, flag).returncode, 0)

    def test_isolated_wrappers_reject_env_loading_before_network_or_signing(self):
        for name in ('deploy.sh', 'timelock.sh'):
            env = {k: os.environ[k] for k in ('HOME', 'PATH')}
            result = subprocess.run(['bash', 'script/' + name, '--isolated-testnet'],
                                    cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('requires --no-env', result.stderr)
