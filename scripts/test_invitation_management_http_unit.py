"""Offline public-process guards; no stack or provider responses mocked."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid
import shutil
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'scripts/invitation-management-bridge.mjs'
RUNNER = ROOT / 'scripts/test-invitation-management-http.py'
ERROR = 'Bridge failed; private diagnostics suppressed.\n'


class Guards(unittest.TestCase):
    def bridge(self, payload, args=()):
        env = dict(os.environ)
        for key in ('NODE_OPTIONS', 'NODE_USE_ENV_PROXY', 'NODE_EXTRA_CA_CERTS'):
            env.pop(key, None)
        return subprocess.run(['node', str(BRIDGE), *args], input=payload,
            capture_output=True, text=True, env=env, timeout=15)

    def rejected(self, payload, args=()):
        result = self.bridge(payload, args)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (1, '', ERROR))

    def test_bounded_private_ipc(self):
        for payload, args in [('private-secret', ()), ('x' * 32769, ()), ('{}', ('private-secret',))]:
            self.rejected(payload, args)

    def test_owned_binding_endpoint_and_fault_guards_have_zero_requests(self):
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(True)
                self.send_error(500)
            do_POST = do_GET
            def log_message(self, *args):
                pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = Thread(target=server.serve_forever)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix='http-jwt-') as wrong:
                self.rejected(json.dumps({'workdir': wrong, 'api': 'http://127.0.0.1'}))
            path = Path(tempfile.gettempdir()) / ('http-jwt-' + uuid.uuid4().hex[:16])
            path.mkdir()
            try:
                (path / 'supabase').mkdir()
                (path / 'supabase/config.toml').write_text('project_id = "%s"' % path.name)
                port = server.server_port
                context = path / 'context.json'
                context.write_text(json.dumps({'project': path.name, 'port': port}))
                payload = {'workdir': str(path), 'api': 'http://127.0.0.1:%d' % port,
                    'key': 'private-key', 'service': 'private-service', 'fault': 'none',
                    'input': {}, 'expected': None, 'actor': None}
                for changes in ({'api': payload['api'] + '/'}, {'fault': 'unknown'},
                                {'api': 'http://localhost:%d' % port}):
                    self.rejected(json.dumps(dict(payload, **changes)))
                result = self.bridge(json.dumps(payload))
                self.assertEqual(result.returncode, 0)
                if result.stderr:
                    self.assertRegex(result.stderr, r'^\(node:\d+\) \[MODULE_TYPELESS_PACKAGE_JSON\] Warning:')
                    self.assertNotIn('private-', result.stderr)
                self.assertEqual(json.loads(result.stdout), {'code': 'invalid_input',
                    'canonical': False, 'frozen': False, 'privateOmitted': True,
                    'injected': False, 'trace': []})
                context.write_text(json.dumps({'project': 'wrong', 'port': port}))
                self.rejected(json.dumps(payload))
            finally:
                shutil.rmtree(path)
            self.assertEqual(requests, [])
        finally:
            server.shutdown()
            thread.join()
            server.server_close()

    def test_runner_rejects_external_context_and_arguments(self):
        for args, extra in [([], {'HTTP_JWT_WORKDIR': 'private-secret'}),
                            (['--target', 'private-secret'], {})]:
            result = subprocess.run([os.sys.executable, '-B', str(RUNNER), *args],
                capture_output=True, text=True, env=dict(os.environ, **extra), timeout=15)
            self.assertEqual((result.returncode, result.stdout, result.stderr),
                (1, '', 'FAIL management proof; private diagnostics suppressed.\n'))


if __name__ == '__main__':
    unittest.main()
