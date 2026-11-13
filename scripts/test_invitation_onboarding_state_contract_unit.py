"""Retained independent pure-data checks; no provider or stack execution."""
import copy
import unittest
from test_invitation_onboarding_http_unit import runner


class IndependentStateContract(unittest.TestCase):
    def setUp(self):
        self.b = {
            'tables': {
                'public.profiles': [0, 'a'],
                'auth.users': [1, 'b'],
            },
            'sequences': {
                'auth.refresh_tokens_id_seq': [5, True],
                'public.counter': [1, False],
            },
        }

    def test_exact_public_effects_not_merely_allowlisted(self):
        allowed = ('public.profiles', 'auth.users')
        self.assertFalse(
            runner.state_matches(self.b, self.b, allowed, None))
        a = copy.deepcopy(self.b)
        a['tables']['public.profiles'] = [1, 'c']
        self.assertTrue(runner.state_matches(self.b, a, allowed, None))
        self.assertFalse(runner.state_matches(self.b, a, (), None))

    def test_schema_inventory_cannot_disappear_or_expand(self):
        for section in self.b:
            for operation in ('remove', 'add'):
                a = copy.deepcopy(self.b)
                if operation == 'remove':
                    a[section].pop(next(iter(a[section])))
                else:
                    a[section]['public.unexpected'] = [1, 'x']
                self.assertFalse(
                    runner.state_matches(self.b, a, (), None))

    def test_counter_needs_both_specific_observations(self):
        a = copy.deepcopy(self.b)
        a['sequences']['auth.refresh_tokens_id_seq'] = [6, True]
        verified = {
            'trace': [{'path': '/auth/v1/verify', 'status': 200}],
            'revoked': {
                'status': 400, 'code': 'refresh_token_not_found'},
        }
        self.assertTrue(runner.state_matches(self.b, a, (), verified))
        for field, value in (
            ('status', 200), ('code', 'invalid_credentials'),
        ):
            bad = copy.deepcopy(verified)
            bad['revoked'][field] = value
            self.assertFalse(runner.state_matches(self.b, a, (), bad))
        bad = copy.deepcopy(verified)
        bad['trace'][0]['path'] = '/auth/v1/user'
        self.assertFalse(runner.state_matches(self.b, a, (), bad))
        a['sequences']['public.counter'] = [2, True]
        self.assertFalse(runner.state_matches(self.b, a, (), verified))
