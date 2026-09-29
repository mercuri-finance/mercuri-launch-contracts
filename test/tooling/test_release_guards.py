"""Offline regression checks for the independent-audit tooling findings."""
import copy
import importlib.util
import json
import http.server
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'script'))
import check_storage_diff as guard
from extract_storage_snapshot import resolve_type
spec = importlib.util.spec_from_file_location('runtime', ROOT / 'script/verify-runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.old = json.loads((ROOT / 'storage-layouts/FeeManager.json').read_text())['members']
        self.new = copy.deepcopy(self.old)
        self.mapping = next(m['layout'] for m in self.new if m['label'] == 'tokens')
        self.struct = self.mapping['value']

    def test_mapping_member_reorder_rejected(self):
        members = self.struct['members']
        members[0], members[1] = members[1], members[0]
        with self.assertRaises(guard.Incompatible):
            guard.compare_members(self.old, self.new, 'FeeManager')

    def test_mapping_member_removal_rejected(self):
        self.struct['members'].pop()
        with self.assertRaises(guard.Incompatible):
            guard.compare_members(self.old, self.new, 'FeeManager')

    def test_mapping_member_retype_rejected(self):
        self.struct['members'][0]['type'] = 'uint160'
        with self.assertRaises(guard.Incompatible):
            guard.compare_members(self.old, self.new, 'FeeManager')

    def append_member(self):
        size = int(self.struct['numberOfBytes'])
        self.struct['members'].append({'label': 'appended', 'slot': str(size // 32), 'offset': 0,
            'type': 'uint256', 'layout': {'type': 'uint256', 'encoding': 'inplace', 'numberOfBytes': '32'}})
        self.struct['numberOfBytes'] = str(size + 32)

    def test_mapping_value_append_accepted(self):
        self.append_member()
        guard.validate_members(self.new)
        guard.compare_members(self.old, self.new, 'FeeManager')

    def test_array_element_growth_rejected_for_fixed_and_dynamic(self):
        before = copy.deepcopy(self.struct)
        self.append_member()
        for encoding, size in [('dynamic_array', '32'), ('inplace', before['numberOfBytes'])]:
            old = {'type': 'struct TokenInfo[]', 'encoding': encoding, 'numberOfBytes': size, 'base': before}
            new = dict(old, base=self.struct)
            with self.subTest(encoding=encoding), self.assertRaises(guard.Incompatible):
                guard.compare_type(old, new, 'nested.mapping.array', True)

    def test_missing_detail_rejected(self):
        for path in ('member', 'mapping', 'struct'):
            members = copy.deepcopy(self.old)
            mapping = next(m for m in members if m['label'] == 'tokens')
            if path == 'member':
                del mapping['layout']
            elif path == 'mapping':
                del mapping['layout']['value']
            else:
                del mapping['layout']['value']['members']
            with self.subTest(path=path), self.assertRaises((guard.Incompatible, KeyError)):
                guard.validate_members(members)

    def test_extraction_descends_through_mapping_and_array(self):
        types = {'uint': {'label': 'uint256', 'encoding': 'inplace', 'numberOfBytes': '32'},
            'struct': {'label': 'struct Info', 'encoding': 'inplace', 'numberOfBytes': '32',
                'members': [{'label': 'balance', 'slot': '0', 'offset': 0, 'type': 'uint'}]},
            'array': {'label': 'struct Info[]', 'encoding': 'dynamic_array', 'numberOfBytes': '32', 'base': 'struct'},
            'map': {'label': 'mapping(uint256 => struct Info[])', 'encoding': 'mapping', 'numberOfBytes': '32',
                'key': 'uint', 'value': 'array'}}
        resolved = resolve_type('map', types)
        self.assertEqual(resolved['value']['base']['members'][0]['layout']['type'], 'uint256')
        types['struct']['members'][0]['type'] = 'map'
        with self.assertRaises(ValueError):
            resolve_type('map', types)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.artifact = {'deployedBytecode': {'object': '0x60' + '00' * 32 + 'ff',
            'immutableReferences': {'123': [{'start': 1, 'length': 32}]}}}
        self.names = {'123': 'poolManager'}
        self.values = {'poolManager': '0x' + 'ab' * 20}

    def expected(self):
        return runtime.expected_runtime(self.artifact, self.names, self.values)

    def test_exact_address_reconstruction(self):
        expected = bytes.fromhex('60' + '00' * 12 + 'ab' * 20 + 'ff')
        runtime.verify_code(expected, self.expected(), 'hook')

    def test_tampered_immutable_and_opcode_rejected(self):
        expected = self.expected()
        for offset in (0, 20, len(expected) - 1):
            actual = bytearray(expected)
            actual[offset] ^= 1
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                runtime.verify_code(actual, expected, 'hook')

    def test_unknown_immutable_rejected(self):
        with self.assertRaises(ValueError):
            runtime.expected_runtime(self.artifact, {}, self.values)

    def test_invalid_ranges_rejected(self):
        for location in ({'start': 0, 'length': 32}, {'start': 1, 'length': 20}, {'start': 100, 'length': 32}):
            self.artifact['deployedBytecode']['immutableReferences']['123'] = [location]
            with self.subTest(location=location), self.assertRaises(ValueError):
                self.expected()


@unittest.skipUnless((ROOT / 'test-export/runtime-fixture.json').exists(),
                     'run ReleaseGuardsTest first to export actual deployed local code')
class RuntimeIntegrationTests(unittest.TestCase):
    def test_cli_matches_five_deployments_and_rejects_tampering(self):
        fixture = json.loads((ROOT / 'test-export/runtime-fixture.json').read_text())
        codes = {fixture[field].lower(): fixture[field + 'Code'] for field in runtime.TARGETS}
        requests = []

        class RPC(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                method = request['method']
                requests.append(method)
                if method == 'eth_chainId':
                    result = hex(fixture['chainId'])
                elif method == 'eth_blockNumber':
                    result = '0x64'
                elif method == 'eth_getBlockByNumber':
                    result = {'hash': '0x' + '11' * 32}
                elif method == 'eth_getCode':
                    result = codes[request['params'][0].lower()]
                else:
                    raise AssertionError('unexpected RPC method: ' + method)
                body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'result': result}).encode()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(('127.0.0.1', 0), RPC)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                record = Path(directory) / 'record.json'
                record.write_text(json.dumps({k: v for k, v in fixture.items() if not k.endswith('Code')}))
                env = {k: os.environ[k] for k in ('HOME', 'PATH')}
                env['ARC_RPC'] = f'http://127.0.0.1:{server.server_port}'
                command = [sys.executable, str(ROOT / 'script/verify-runtime.py'), '--record', str(record),
                           '--artifacts', str(ROOT / 'out')]
                result = subprocess.run(command, env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(json.loads(result.stdout)['exactRuntimeMatches']), 5)
                hook = fixture['launchHook'].lower()
                original = codes[hook]
                codes[hook] = '0x00' + original[4:]
                result = subprocess.run(command, env=env, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('LaunchHook: deployed runtime differs', result.stderr)
                self.assertNotIn('eth_sendRawTransaction', requests)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()


if __name__ == '__main__':
    unittest.main()
