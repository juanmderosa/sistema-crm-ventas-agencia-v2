"""Offline invocation guards; never starts a stack."""
import importlib.util
from pathlib import Path
import unittest
import contextlib
import io
import copy

PATH = Path(__file__).with_name('test-invitation-onboarding-http.py')
spec = importlib.util.spec_from_file_location('onboarding', PATH)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class Guards(unittest.TestCase):
    def test_diagnostics_expose_only_names_and_flags(self):
        before = {'tables': {'auth.users': [1, 'private-before']},
                  'sequences': {'auth.refresh_tokens_id_seq': [1, True]}}
        after = {'tables': {'auth.users': [1, 'private-after']},
                 'sequences': {'auth.refresh_tokens_id_seq': [2, True]}}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            runner.state_diagnostics(before, after, ('auth.users',))
        self.assertEqual(output.getvalue(),
            'STATE_TABLE name=auth.users changed=1 allowed=1 count_equal=1\n'
            'STATE_SEQUENCE name=auth.refresh_tokens_id_seq equal=0 direction=forward called_equal=1\n')

    def test_refresh_counter_requires_verified_provider_context(self):
        before = {'tables': {'public.profiles': [1, 'a'], 'auth.users': [1, 'b']},
                  'sequences': {'auth.refresh_tokens_id_seq': [2, True],
                                'public.inquiries_creation_sequence_seq': [1, False]}}
        after = copy.deepcopy(before)
        after['sequences']['auth.refresh_tokens_id_seq'] = [3, True]
        verified = {'trace': [{'path': '/auth/v1/verify', 'status': 200}],
                    'revoked': {'status': 400, 'code': 'refresh_token_not_found'}}
        self.assertFalse(runner.state_matches(before, after, (), None))
        self.assertFalse(runner.state_matches(before, after, (), {'trace': [], 'revoked': None}))
        self.assertTrue(runner.state_matches(before, after, (), verified))
        for position in ([1, True], [3, False], [2, False]):
            bad = copy.deepcopy(after)
            bad['sequences']['auth.refresh_tokens_id_seq'] = position
            self.assertFalse(runner.state_matches(before, bad, (), verified))
        for section, name in (('tables', 'public.profiles'), ('tables', 'auth.users'),
                              ('sequences', 'public.inquiries_creation_sequence_seq')):
            bad = copy.deepcopy(after)
            bad[section][name] = [9, True]
            self.assertFalse(runner.state_matches(before, bad, (), verified))
        self.assertTrue(runner.state_matches(before, before, (), None))
        invalid = copy.deepcopy(verified)
        invalid['trace'][0]['status'] = 403
        self.assertFalse(runner.state_matches(before, after, (), invalid))

    def test_default_is_only_live_entry(self):
        self.assertEqual(runner.invocation([], {}), 'live')

    def test_help_ignores_inherited_context(self):
        self.assertEqual(runner.invocation(['--help'], {'HTTP_JWT_WORKDIR': 'secret'}), 'help')

    def test_child_environment_never_authorizes_entry(self):
        for args in ([], ['--owned'], ['--owned-binding'], ['--api', 'http://127.0.0.1']):
            with self.subTest(args=args):
                with self.assertRaisesRegex(ValueError, '^unsupported invocation$'):
                    runner.invocation(args, {'HTTP_JWT_WORKDIR': 'secret'})

    def test_all_other_arguments_rejected(self):
        for args in (['.'], ['--target'], ['--help', 'extra'], ['--owned']):
            with self.assertRaisesRegex(ValueError, '^unsupported invocation$'):
                runner.invocation(args, {})


if __name__ == '__main__':
    unittest.main()
