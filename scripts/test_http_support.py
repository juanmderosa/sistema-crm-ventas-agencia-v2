import unittest
from unittest.mock import patch

from http_test_support import error_matches, local_origin, NoRedirect, isolated_run


class HttpSupportTests(unittest.TestCase):
    def test_permission_requires_transport_and_sqlstate(self):
        self.assertTrue(error_matches(403, {'code': '42501'}))
        self.assertTrue(error_matches(401, {'code': '42501'}))
        for status, body in [(404, {'code': 'PGRST202'}), (400, {'code': '22023'}),
                             (409, {'code': '23505'}), (403, {}), (0, 'offline')]:
            self.assertFalse(error_matches(status, body))

    def test_explicit_auth_error_is_not_generic_permission(self):
        self.assertFalse(error_matches(401, {'code': 'PGRST301'}))
        self.assertTrue(error_matches(401, {'code': 'PGRST301'}, (401,), ('PGRST301',)))
        self.assertTrue(error_matches(422, {'code': 422, 'error_code': 'signup_disabled'}, (422,), ('signup_disabled',)))

    def test_origin_is_exact_plain_loopback(self):
        self.assertEqual(local_origin('http://127.0.0.1:54321', 54321), 'http://127.0.0.1:54321')
        for url in ['https://127.0.0.1:54321', 'http://localhost:54321', 'http://example.com:54321',
                    'http://127.0.0.1:54322', 'http://user:password@127.0.0.1:54321',
                    'http://127.0.0.1:54321/path', 'http://127.0.0.1:54321?token=secret',
                    'http://127.0.0.1:54321#fragment']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                local_origin(url, 54321)

    def test_redirect_never_forwards_credentials(self):
        self.assertIsNone(NoRedirect().redirect_request(None, None, 302, '', {}, 'https://example.com'))

    def test_teardown_runs_when_child_fails(self):
        with patch('http_test_support.DisposableStack') as stack, \
             patch('http_test_support.subprocess.run') as run:
            run.side_effect = RuntimeError('child failed')
            with self.assertRaises(RuntimeError):
                isolated_run('unused.py')
            stack.return_value.__exit__.assert_called_once()


if __name__ == '__main__':
    unittest.main()
