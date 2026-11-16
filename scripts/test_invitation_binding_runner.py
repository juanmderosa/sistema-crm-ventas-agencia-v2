"""Offline diagnostic contract; every stack and subprocess is mocked."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import types
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location(
    'binding_runner', Path(__file__).with_name('test-invitation-binding-http.py'))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
PRIVATE = 'PRIVATE email@example.invalid password token body /users/secret-uuid'


class Diagnostics(unittest.TestCase):
    def invoke(self, result=None, startup=None, args=(), child_error=None):
        stack = Mock()
        stack.project = 'http-jwt-0123456789abcdef'
        stack.__enter__ = Mock(return_value=Path('/unused-owned-fixture'), side_effect=startup)
        stack.__exit__ = Mock(return_value=False)
        constructor = Mock(return_value=stack)
        helper = types.ModuleType('http_test_support')
        helper.ROOT = Path(__file__).resolve().parents[1]
        helper.DisposableStack = constructor
        helper.local_origin = Mock(side_effect=AssertionError('provider forbidden'))
        helper.owned_context = Mock(side_effect=AssertionError('provider forbidden'))
        out, err = io.StringIO(), io.StringIO()
        call = Mock(return_value=result, side_effect=child_error)
        caught = None
        with patch.dict(sys.modules, {'http_test_support': helper}), \
                patch.dict(os.environ, {}, clear=True), \
                patch.object(sys, 'argv', ['runner', *args]), \
                patch.object(RUNNER.subprocess, 'run', call), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = RUNNER.main()
            except Exception as error:
                caught, code = error, None
        self.assertNotIn(PRIVATE, out.getvalue() + err.getvalue())
        helper.local_origin.assert_not_called()
        helper.owned_context.assert_not_called()
        return code, out.getvalue(), err.getvalue(), caught, constructor, stack, call

    def test_failed_child_forwards_only_contract_records(self):
        safe = ('STAGE owner-bootstrap\nPASS candidate recovery is read-only\n'
                'FAIL bind returns exact Admin-verified UUID\nHTTP prepare status=400\n')
        injected = safe + PRIVATE + '\nPASS ' + PRIVATE + '\nHTTP ' + PRIVATE + '\n'
        result = subprocess.CompletedProcess([], 7, injected, PRIVATE)
        code, out, err, caught, _, stack, call = self.invoke(result)
        self.assertIsNone(code)
        self.assertIsInstance(caught, RuntimeError)
        for line in safe.splitlines():
            self.assertIn(line + '\n', out)
        self.assertIn('STAGE stack-startup\nSTAGE stack-ready\n', out)
        self.assertIn('DIAGNOSTIC child exit=7 stderr=present\n', out)
        self.assertIn('OBSERVED assertion-labels pass=1 fail=1\n', out)
        self.assertIn('DIAGNOSTIC failure=child\n', out)
        stack.__exit__.assert_called_once()
        self.assertEqual(call.call_args.kwargs['timeout'], 240)

    def test_startup_failure_has_safe_pre_ready_classification(self):
        _, out, _, caught, _, _, call = self.invoke(startup=RuntimeError(PRIVATE))
        self.assertIsInstance(caught, RuntimeError)
        self.assertEqual(out, 'STAGE stack-startup\nDIAGNOSTIC failure=startup\n')
        self.assertNotIn('stack-ready', out)
        call.assert_not_called()

    def test_success_preserves_message_and_owned_cleanup(self):
        result = subprocess.CompletedProcess([], 0, 'PASS candidate recovery is read-only\n', '')
        code, out, err, caught, constructor, stack, _ = self.invoke(result)
        self.assertEqual((code, err, caught), (0, '', None))
        self.assertTrue(out.endswith(
            'Invitation binding probes passed; acceptance/activation/delivery not tested.\n'))
        self.assertIn('DIAGNOSTIC child exit=0 stderr=absent\n', out)
        constructor.assert_called_once()
        stack.__exit__.assert_called_once_with(None, None, None)

    def test_help_never_initializes_helper_or_provider(self):
        code, out, err, caught, constructor, _, call = self.invoke(args=['--help'])
        self.assertEqual((code, out, err, caught), (0, RUNNER.HELP, '', None))
        constructor.assert_not_called()
        call.assert_not_called()

    def test_arbitrary_target_still_rejected(self):
        _, out, _, caught, constructor, _, call = self.invoke(args=['--target', PRIVATE])
        self.assertIsInstance(caught, RuntimeError)
        self.assertEqual(out, '')
        constructor.assert_not_called()
        call.assert_not_called()

    def test_timeout_metadata_never_exposes_command_or_private_channels(self):
        timeout = subprocess.TimeoutExpired(PRIVATE, 240,
            output=('STAGE binding\nPASS candidate recovery is read-only\n' + PRIVATE).encode(),
            stderr=PRIVATE.encode())
        _, out, _, caught, _, stack, _ = self.invoke(child_error=timeout)
        self.assertIsInstance(caught, subprocess.TimeoutExpired)
        self.assertEqual(out, 'STAGE stack-startup\nSTAGE stack-ready\n'
            'STAGE binding\nPASS candidate recovery is read-only\n'
            'OBSERVED assertion-labels pass=1 fail=0\n'
            'DIAGNOSTIC child timeout=240 exit=unavailable stderr=present\n'
            'DIAGNOSTIC failure=child-timeout\n')
        stack.__exit__.assert_called_once()

    def test_http_observer_preserves_exact_call_and_response(self):
        response = (422, {'message': PRIVATE, 'token': PRIVATE})
        call = Mock(return_value=response)
        observed = RUNNER.observe_http(call)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            actual = observed('GET', '/auth/v1/admin/users/private-uuid', token=PRIVATE)
        self.assertIs(actual, response)
        call.assert_called_once_with('GET', '/auth/v1/admin/users/private-uuid', token=PRIVATE)
        self.assertEqual(out.getvalue(), 'HTTP auth-admin-read status=422\n')

    def test_forwarder_rejects_forged_labels_and_status_metadata(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            RUNNER.forward_observations('\n'.join((
                'PASS candidate recovery is read-only ' + PRIVATE,
                'STAGE ' + PRIVATE, 'HTTP prepare status=400 ' + PRIVATE,
                'HTTP prepare status=999', 'HTTP ' + PRIVATE,
                'DIAGNOSTIC child exit=0 stderr=absent')))
        self.assertEqual(out.getvalue(), 'OBSERVED assertion-labels pass=0 fail=0\n')

    def test_envelope_flags_disclose_only_structural_boolean_differences(self):
        expected = (401, {'code': '42501', 'details': None, 'hint': None, 'message': 'denied'})
        body = expected[1]
        cases = (
            ((401, dict(body, message=PRIVATE)), '1111111110'),
            ((401, {k: v for k, v in body.items() if k != 'details'}), '1101001111'),
            ((401, dict(body, details=PRIVATE)), '1111101111'),
            ((401, dict(body, **{PRIVATE: PRIVATE})), '1101111111'),
            ((401, None), '1000000000'),
            ((401, [PRIVATE]), '1000000000'),
            ((403, dict(body, code=PRIVATE)), '0110111111'),
        )
        fields = ('status_match', 'body_object', 'keys_match', 'code_match',
                  'details_present', 'details_match', 'hint_present', 'hint_match',
                  'message_present', 'message_match')
        for response, bits in cases:
            with self.subTest(bits=bits):
                line = RUNNER.envelope_flags(response, expected)
                self.assertEqual(line, 'ENVELOPE ' + ' '.join(
                    name + '=' + bit for name, bit in zip(fields, bits)))
                self.assertNotIn(PRIVATE, line)

    def test_envelope_forwarding_requires_exact_order_and_boolean_grammar(self):
        line = ('ENVELOPE status_match=1 body_object=1 keys_match=1 code_match=1 '
                'details_present=1 details_match=1 hint_present=1 hint_match=1 '
                'message_present=1 message_match=0')
        invalid = (line + PRIVATE, line.replace('=0', '=2'),
                   line.replace('status_match=1 body_object=1', 'body_object=1 status_match=1'),
                   line.replace('=0', '=True'), line + ' extra=1')
        result = subprocess.CompletedProcess([], 1, '\n'.join((line, *invalid)), PRIVATE)
        _, out, _, caught, _, _, _ = self.invoke(result)
        self.assertIsInstance(caught, RuntimeError)
        self.assertEqual(out.count('ENVELOPE '), 1)
        self.assertIn(line + '\n', out)
        self.assertNotIn('probes passed', out)

    def test_table_denial_accepts_only_present_nullable_text_hint(self):
        expected = (401, {'code': '42501', 'details': None, 'hint': None, 'message': 'denied'})
        for hint in (None, '', PRIVATE):
            with self.subTest(accepted_hint_type=type(hint).__name__):
                self.assertTrue(RUNNER.denial_matches(
                    (401, dict(expected[1], hint=hint)), expected, allow_text_hint=True))
        rejected = [(401, dict(expected[1], hint=hint))
                    for hint in (0, 1.5, True, False, [], {}, [PRIVATE])]
        rejected.extend(((401, {k: v for k, v in expected[1].items() if k != 'hint'}),
                         (401, dict(expected[1], hint=PRIVATE, rows=[PRIVATE])),
                         (403, dict(expected[1], hint=PRIVATE)), (401, None)))
        for field in ('code', 'details', 'message'):
            rejected.append((401, dict(expected[1], hint=PRIVATE, **{field: PRIVATE})))
        for response in rejected:
            with self.subTest(rejected_case=rejected.index(response)):
                self.assertFalse(RUNNER.denial_matches(response, expected, allow_text_hint=True))

    def test_rpc_stays_strict_and_table_diagnostics_use_permitted_hint_contract(self):
        expected = (403, {'code': '42501', 'details': None, 'hint': None, 'message': 'denied'})
        self.assertTrue(RUNNER.denial_matches(expected, expected))
        text_hint = (403, dict(expected[1], hint=PRIVATE))
        self.assertFalse(RUNNER.denial_matches(text_hint, expected))
        wrong_message = (403, dict(expected[1], hint=PRIVATE, message=PRIVATE))
        line = RUNNER.envelope_flags(wrong_message, expected, allow_text_hint=True)
        self.assertIn('hint_present=1 hint_match=1', line)
        self.assertTrue(line.endswith('message_present=1 message_match=0'))
        self.assertIn('hint_match=0', RUNNER.envelope_flags(wrong_message, expected))
        self.assertNotIn(PRIVATE, line)

    def test_zero_exit_with_stderr_remains_failure(self):
        result = subprocess.CompletedProcess([], 0, '', PRIVATE)
        _, out, _, caught, _, _, _ = self.invoke(result)
        self.assertIsInstance(caught, RuntimeError)
        self.assertIn('DIAGNOSTIC child exit=0 stderr=present\n', out)
        self.assertNotIn('probes passed', out)
        self.assertIn('OBSERVED assertion-labels pass=0 fail=0\n', out)


if __name__ == '__main__':
    unittest.main()
