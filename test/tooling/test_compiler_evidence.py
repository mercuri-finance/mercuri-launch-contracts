"""Release evidence must select Deploy's profile even when multiple artifacts exist."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'compiler_evidence', Path(__file__).resolve().parents[2] / 'script/prepare-release-evidence.py')
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class ArtifactProfileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.settings = {'optimizer': {'enabled': True, 'runs': 200}, 'viaIR': True,
                         'evmVersion': 'cancun'}
        self.compiler = {'version': '0.8.26+commit.8a97fa7a'}

    def write(self, suffix, runs=200, compiler=None):
        settings = copy.deepcopy(self.settings)
        settings['optimizer']['runs'] = runs
        settings['compilationTarget'] = {'TimelockController.sol': 'TimelockController'}
        artifact = {'profile': suffix, 'metadata': {'settings': settings,
                    'compiler': compiler or self.compiler}}
        (self.directory / ('TimelockController' + suffix + '.json')).write_text(json.dumps(artifact))

    def select(self):
        return evidence.matching_artifact(self.directory, 'TimelockController', self.settings, self.compiler)

    def test_chooses_deploy_settings_over_default_profile_name(self):
        self.write('.default', runs=44444444)
        self.write('.small')
        self.assertEqual(self.select()['profile'], '.small')

    def test_unsuffixed_artifact_remains_supported(self):
        self.write('')
        self.assertEqual(self.select()['profile'], '')

    def test_wrong_settings_or_compiler_are_rejected(self):
        self.write('.default', runs=44444444)
        self.write('.small', compiler={'version': 'different'})
        with self.assertRaises(ValueError):
            self.select()

    def test_ambiguous_matching_profiles_are_rejected(self):
        self.write('.small')
        self.write('')
        with self.assertRaises(ValueError):
            self.select()
