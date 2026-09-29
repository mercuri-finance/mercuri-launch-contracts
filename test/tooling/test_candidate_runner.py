"""Runner tests never use a real secret, RPC, or signer."""
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('runner', ROOT / 'script/run-candidate-testnet.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class CandidateRunnerTests(unittest.TestCase):
    def test_signer_rejects_all_known_mainnet_and_governance_addresses(self):
        for address in runner.BLOCKED_SIGNERS:
            with self.subTest(address=address), self.assertRaises(ValueError):
                runner.validate_signer(address)
        runner.validate_signer('0x' + '11' * 20)
        with self.assertRaises(ValueError): runner.validate_signer('bad address')

    def test_environment_drops_credentials_tracing_and_compiler_overrides(self):
        with patch.dict(os.environ, {'HOME': '/test', 'PATH': '/test/bin',
            'DEPLOYER_PRIVATE_KEY': 'sentinel', 'ARC_RPC': 'https://wrong.invalid',
            'FOUNDRY_OPTIMIZER_RUNS': '1', 'BASH_ENV': '/must-not-source', 'SHELLOPTS': 'xtrace'}, clear=True):
            env = runner.environment()
            self.assertEqual(set(env), {'HOME', 'PATH', 'FOUNDRY_OFFLINE', 'FOUNDRY_NO_STORAGE_CACHING', 'NO_COLOR', 'RUST_BACKTRACE'})

    def test_private_prompt_requires_interactive_terminal(self):
        with patch('sys.stdin.isatty', return_value=False), patch.object(runner.getpass, 'getpass') as prompt:
            with self.assertRaisesRegex(RuntimeError, 'local Terminal'):
                runner.run()
            prompt.assert_not_called()

    def test_bad_key_message_does_not_echo_input(self):
        value = 'invalid-secret-sentinel'
        with self.assertRaises(ValueError) as caught: runner.normalize_key(value)
        self.assertNotIn(value, str(caught.exception))
