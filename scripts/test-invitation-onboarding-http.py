"""Actual TypeScript onboarding over one owned local Auth/PostgREST stack."""
import importlib.util
import json
import os
from pathlib import Path
import secrets
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
HELP = ('Usage: python -B scripts/test-invitation-onboarding-http.py [--help]\n'
        'Default creates one owned disposable local stack; synthetic users, no mail.\n'
        'No target, credential, child-mode or existing-stack arguments accepted.\n'
        'See docs/invitation-onboarding-http.md.\n')


def invocation(args, env):
    if args == ['--help']:
        return 'help'
    if args or 'HTTP_JWT_WORKDIR' in env:
        raise ValueError('unsupported invocation')
    return 'live'


def load_http():
    spec = importlib.util.spec_from_file_location('onboarding_http', ROOT / 'scripts/test-accounts-http.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def state_diagnostics(before, after, allowed=()):
    """Names and boolean/direction flags only; never row values or hashes."""
    for kind in ('tables', 'sequences'):
        for name in sorted(before[kind].keys() | after[kind].keys()):
            if not re.fullmatch(r'(public|auth)\.[a-z_][a-z_0-9]*', name):
                raise RuntimeError('unsafe diagnostic identifier')
            left, right = before[kind].get(name), after[kind].get(name)
            equal = left == right
            if kind == 'sequences':
                direction = 'equal' if equal else ('forward' if left and right and right[0] > left[0] else 'other')
                print('STATE_SEQUENCE name=%s equal=%d direction=%s called_equal=%d' % (
                    name, equal, direction, bool(left and right and left[1] == right[1])), flush=True)
            elif not equal or name in allowed:
                print('STATE_TABLE name=%s changed=%d allowed=%d count_equal=%d' % (
                    name, not equal, name in allowed, bool(left and right and left[0] == right[0])), flush=True)


def state_matches(before, after, allowed, observed):
    if before['tables'].keys() != after['tables'].keys() or before['sequences'].keys() != after['sequences'].keys():
        return False
    changed = {key for key in before['tables'] if before['tables'][key] != after['tables'][key]}
    expected = set(allowed)
    if ({k for k in changed if k.startswith('public.')} != {k for k in expected if k.startswith('public.')}
            or not changed <= expected):
        return False
    trace = observed.get('trace', []) if observed else []
    revoked = observed.get('revoked') if observed else None
    consumed = (bool(trace) and trace[0].get('path') == '/auth/v1/verify'
                and trace[0].get('status') == 200 and isinstance(revoked, dict)
                and revoked.get('status') == 400 and revoked.get('code') in (
                    'refresh_token_not_found', 'refresh_token_already_used'))
    for name, left in before['sequences'].items():
        right = after['sequences'][name]
        if name == 'auth.refresh_tokens_id_seq' and consumed:
            # Only the observed, schema-owned provider session counter may advance.
            if not (left[1] is True and right[1] is True and right[0] > left[0]):
                return False
        elif left != right:
            return False
    return True


class Proof:
    def __init__(self, p):
        self.p = p
        self.assertions = self.calls = self.protected = self.refreshes = 0
        self.groups = {}
        self.owner = None
        self.owner_token = None

    def check(self, label, condition):
        self.assertions += 1
        print(('PASS ' if condition else 'FAIL ') + label, flush=True)
        if not condition:
            raise RuntimeError('proof assertion failed')

    def rpc(self, function, body):
        return self.p.call('POST', '/rest/v1/rpc/' + function, body, self.p.service, self.p.service)

    def snapshot(self):
        # Reuse the retained complete-table/counter read-only inspection unchanged.
        return json.loads(self.p.sql((ROOT / 'scripts/staff_completion_probe/state.sql').read_text()))

    def preserved(self, before, allowed=(), observed=None):
        after = self.snapshot()
        changed = {key for key in before['tables'] if before['tables'][key] != after['tables'][key]}
        expected = set(allowed)
        matches = state_matches(before, after, allowed, observed)
        if not matches:
            state_diagnostics(before, after, expected)
            print('STATE_DIFF public_changed=%d auth_changed=%d unexpected_tables=%d sequences_equal=%d' % (
                len([k for k in changed if k.startswith('public.')]),
                len([k for k in changed if k.startswith('auth.')]), len(changed - expected),
                before['sequences'] == after['sequences']), flush=True)
        self.check('protected tables and counters match allowed effects', matches)
        self.protected += 1

    def pending(self, number, role='seller'):
        email = 'onboarding-%d@example.invalid' % number
        invitation = str(uuid.uuid4())
        body = {'p_request_id': str(uuid.uuid4()), 'p_invitation_id': invitation,
                'p_actor_id': self.owner, 'p_action': 'create', 'p_email': email, 'p_role': role}
        self.check('intent created through supported RPC', self.rpc('manage_staff_invitation_intent', body) == (200, invitation))
        reservation = {'p_invitation_id': invitation, 'p_actor_id': self.owner, 'p_provenance': str(uuid.uuid4())}
        self.check('prepare reserves exact pending candidate', self.rpc('prepare_staff_invitation_identity', reservation) == (200, {
            'invitation_id': invitation, 'email': email, 'role': role,
            'provenance': reservation['p_provenance'], 'user_id': None, 'candidate_user_id': None}))
        status, user = self.p.call('POST', '/auth/v1/admin/users', {
            'email': email, 'email_confirm': False, 'app_metadata': {
                'staff_invitation_id': invitation,
                'staff_invitation_provenance': reservation['p_provenance']}}, self.p.service, self.p.service)
        self.check('Admin creates genuine passwordless unconfirmed identity', status in (200, 201)
                   and user.get('email') == email and not user.get('email_confirmed_at'))
        uid = str(uuid.UUID(user['id']))
        status, exact = self.p.call('GET', '/auth/v1/admin/users/' + uid, key=self.p.service, token=self.p.service)
        self.check('Admin corroborates pending identity and provenance', status == 200 and exact['id'] == uid
                   and exact['email'] == email and all(exact['app_metadata'].get(k) == v for k, v in user['app_metadata'].items()))
        self.check('binding returns exact Admin verified identity', self.rpc('bind_staff_invitation_identity',
                   dict(reservation, p_user_id=uid)) == (200, uid))
        fixture = {'email': email, 'uid': uid, 'invitation': invitation, 'role': role,
                   'name': 'Synthetic Onboarding %d' % number, 'intent': body}
        self.profile(fixture, absent=True)
        return fixture

    def profile(self, f, absent=False, name=None):
        self.check('Owner observes exact operational profile boundary', self.p.call('GET',
            '/rest/v1/profiles?id=eq.' + f['uid'] + '&select=id,role,display_name,is_active',
            token=self.owner_token) == (200, [] if absent else [{
                'id': f['uid'], 'role': f['role'], 'display_name': name or f['name'], 'is_active': True}]))

    def link(self, f, kind):
        status, body = self.p.call('POST', '/auth/v1/admin/generate_link',
            {'type': kind, 'email': f['email']}, self.p.service, self.p.service)
        self.check('Admin generates genuine token without mail', status == 200
                   and body.get('verification_type') == kind and bool(body.get('hashed_token'))
                   and body.get('id') == f['uid'])
        return body['hashed_token']

    def login(self, f, password):
        status, body = self.p.signin(password, f['email'])
        self.check('password grant returns same genuine identity', status == 200
                   and body.get('user', {}).get('id') == f['uid']
                   and bool(body.get('access_token')) and bool(body.get('refresh_token')))
        return body

    def reject_refresh(self, refresh):
        status, body = self.p.call('POST', '/auth/v1/token?grant_type=refresh_token', {'refresh_token': refresh})
        self.check('every observed old refresh credential has exact Auth rejection', status == 400
                   and body.get('error_code', body.get('code')) in ('refresh_token_not_found', 'refresh_token_already_used'))
        print('AUTH refresh status=400 code=' + body.get('error_code', body.get('code')), flush=True)
        self.refreshes += 1

    def complete(self, f, token, password, method='acceptInvite', fault='none', invalid=False):
        payload = {'workdir': str(self.p.workdir), 'api': self.p.api, 'key': self.p.anon,
                   'service': self.p.service, 'method': method, 'fault': fault, 'input': {
                       'invitationID': f['invitation'], 'hash': token, 'displayName': f['name'],
                       'password': password if not invalid else '12345', 'type': 'signup'}}
        env = dict(os.environ)
        for key in ('NODE_OPTIONS', 'NODE_USE_ENV_PROXY', 'NODE_EXTRA_CA_CERTS'):
            env.pop(key, None)
        child = subprocess.run(['node', str(ROOT / 'scripts/invitation-onboarding-bridge.mjs')],
            input=json.dumps(payload), cwd=ROOT, env=env, capture_output=True, text=True,
            encoding='utf-8', timeout=100)
        print('BRIDGE exit=%d stderr=%s' % (child.returncode, 'present' if child.stderr else 'absent'), flush=True)
        self.check('actual service bridge exits cleanly over private pipes', child.returncode == 0)
        observed = json.loads(child.stdout)
        self.check('bridge returns fixed protocol fields', set(observed) == {
            'protocol', 'result', 'trace', 'injected', 'revoked'} and observed['protocol'] == 1)
        self.calls += 1
        categories = {'/auth/v1/verify': 'verify', '/auth/v1/user': 'user',
            '/auth/v1/logout?scope=global': 'logout',
            '/rest/v1/rpc/check_staff_invitation_acceptance': 'preflight',
            '/rest/v1/rpc/complete_staff_invitation': 'completion'}
        for entry in observed['trace']:
            category, status = categories[entry['path']], entry['status']
            if type(status) is not int or not 100 <= status <= 599:
                raise RuntimeError('invalid bridge status')
            print('HTTP %s status=%d' % (category, status), flush=True)
        if observed['revoked']:
            self.check('consumed real session refresh rejected after logout',
                observed['revoked']['status'] == 400 and observed['revoked']['code'] in (
                    'refresh_token_not_found', 'refresh_token_already_used'))
            print('AUTH refresh status=400 code=' + observed['revoked']['code'], flush=True)
            self.refreshes += 1
        self.check('fault injection matches requested transport boundary', observed['injected'] == (fault != 'none'))
        return observed

    def outcome(self, observed, code=None, stages=6, token_type='invite', preflight=200):
        self.check('exact redacted public service result', observed['result'] == (
            {'ok': True} if code is None else {'ok': False, 'code': code}))
        print('RESULT ' + ('ok' if code is None else code), flush=True)
        sequence = [('/auth/v1/verify', 'POST', 200), ('/auth/v1/user', 'GET', 200),
            ('/rest/v1/rpc/check_staff_invitation_acceptance', 'POST', preflight),
            ('/auth/v1/user', 'PUT', 200), ('/auth/v1/logout?scope=global', 'POST', 204),
            ('/rest/v1/rpc/complete_staff_invitation', 'POST', 200)]
        expected = sequence[:stages] if stages != 4 else [sequence[i] for i in (0, 1, 2, 4)]
        if stages == 1:
            expected = [('/auth/v1/verify', 'POST', 403)]
        self.check('exact actual request order methods and native statuses',
            [(t['path'], t['method'], t['status']) for t in observed['trace']] == expected)
        if stages:
            self.check('service fixes token type regardless of extra input', observed['trace'][0]['type'] == token_type)
        if stages == 1:
            self.check('provider specifically rejects consumed or invalid token', observed['trace'][0].get('code') == 'otp_expired')

    def group(self, name, action):
        before = (self.assertions, self.calls, self.protected, self.refreshes)
        try:
            action()
        finally:
            counts = tuple(a - b for a, b in zip((self.assertions, self.calls, self.protected, self.refreshes), before))
            self.groups[name] = dict(zip(('assertions', 'service_calls', 'protected_checks', 'refresh_rejections'), counts))
            print('GROUP ' + name + ' ' + json.dumps(self.groups[name], sort_keys=True), flush=True)

    def successes(self):
        for number, role in ((1, 'seller'), (2, 'admin')):
            f = self.pending(number, role)
            token = self.link(f, 'invite')
            before = self.snapshot()
            observed = self.complete(f, token, self.p.replacement)
            self.outcome(observed)
            self.preserved(before, ('auth.users', 'auth.identities', 'public.profiles',
                                    'public.staff_invitation_completions'), observed)
            self.profile(f)
            self.login(f, self.p.replacement)
            self.completion_record(f)
            before = self.snapshot()
            self.outcome(self.complete(f, token, self.p.password), 'invalid_token', 1)
            self.preserved(before)

    def completion_record(self, f):
        # Read-only inspection, never SQL-created authentication evidence.
        self.check('one permanent completion profile and Auth identity', self.p.sql(
            "select (select count(*) from public.staff_invitation_completions where invitation_id='%s' and user_id='%s' and initial_display_name='%s')::text || '|' || "
            "(select count(*) from public.profiles where id='%s')::text || '|' || "
            "(select count(*) from auth.users where id='%s')::text || '|' || "
            "(select count(*) from auth.identities where user_id='%s')::text;" % (
                f['invitation'], f['uid'], f['name'], f['uid'], f['uid'], f['uid'])) == '1|1|1|1')

    def invalids(self):
        f = self.pending(3)
        token = self.link(f, 'invite')
        before = self.snapshot()
        self.outcome(self.complete(f, token, self.p.password, invalid=True), 'invalid_input', 0)
        self.preserved(before)
        self.outcome(self.complete(f, secrets.token_hex(32), self.p.password), 'invalid_token', 1)
        self.preserved(before)
        self.outcome(self.complete(f, token, self.p.password, 'recoverInterrupted'), 'invalid_token', 1, 'recovery')
        self.preserved(before)
        self.profile(f, absent=True)

    def denials(self):
        first, second = self.pending(4), self.pending(5)
        token = self.link(first, 'invite')
        wrong = dict(first, invitation=second['invitation'])
        before = self.snapshot()
        observed = self.complete(wrong, token, self.p.password)
        self.outcome(observed, 'preflight_rejected', 4, preflight=400)
        self.preserved(before, ('auth.users', 'auth.identities'), observed)
        self.profile(first, absent=True)
        self.profile(second, absent=True)
        revoked = self.pending(6)
        token = self.link(revoked, 'invite')
        body = dict(revoked['intent'], p_request_id=str(uuid.uuid4()), p_action='revoke')
        self.check('pending invitation revoked through supported command',
            self.rpc('manage_staff_invitation_intent', body) == (200, revoked['invitation']))
        before = self.snapshot()
        observed = self.complete(revoked, token, self.p.password)
        self.outcome(observed, 'preflight_rejected', 4, preflight=400)
        self.preserved(before, ('auth.users', 'auth.identities'), observed)
        self.profile(revoked, absent=True)

    def interruption(self):
        f = self.pending(7)
        token = self.link(f, 'invite')
        before = self.snapshot()
        observed = self.complete(f, token, self.p.password, fault='beforeCompletion')
        self.outcome(observed, 'completion_uncertain', 5)
        self.preserved(before, ('auth.users', 'auth.identities'), observed)
        self.profile(f, absent=True)
        sessions = [self.login(f, self.p.password), self.login(f, self.p.password)]
        self.check('two distinct genuine pre recovery sessions exist',
                   sessions[0]['refresh_token'] != sessions[1]['refresh_token'])
        recovery = self.link(f, 'recovery')
        before = self.snapshot()
        observed = self.complete(f, recovery, self.p.replacement, 'recoverInterrupted')
        self.outcome(observed, token_type='recovery')
        self.preserved(before, ('auth.users', 'auth.identities', 'public.profiles', 'public.staff_invitation_completions'), observed)
        for session in sessions:
            self.reject_refresh(session['refresh_token'])
        self.login(f, self.p.replacement)
        status, body = self.p.signin(self.p.password, f['email'])
        self.check('previous password has exact invalid credentials rejection', status == 400
                   and body.get('error_code', body.get('code')) == 'invalid_credentials')
        self.profile(f)
        self.completion_record(f)
        before = self.snapshot()
        self.outcome(self.complete(f, recovery, self.p.password, 'recoverInterrupted'), 'invalid_token', 1, 'recovery')
        self.preserved(before)

    def lost_response(self):
        f = self.pending(8)
        token = self.link(f, 'invite')
        before = self.snapshot()
        observed = self.complete(f, token, self.p.password, fault='afterCompletion')
        self.outcome(observed, 'completion_uncertain')
        self.preserved(before, ('auth.users', 'auth.identities', 'public.profiles', 'public.staff_invitation_completions'), observed)
        self.profile(f)
        self.completion_record(f)
        session = self.login(f, self.p.password)
        later_name = 'Later Owner Name'
        self.check('Owner changes display name through existing profile interface', self.p.call('PATCH',
            '/rest/v1/profiles?id=eq.' + f['uid'], {'display_name': later_name}, token=self.owner_token) == (204, None))
        recovery = self.link(f, 'recovery')
        before = self.snapshot()
        observed = self.complete(f, recovery, self.p.replacement, 'recoverInterrupted')
        self.outcome(observed, token_type='recovery')
        self.preserved(before, ('auth.users', 'auth.identities'), observed)
        self.reject_refresh(session['refresh_token'])
        self.profile(f, name=later_name)
        self.completion_record(f)
        self.login(f, self.p.replacement)


def preflight():
    for name in ('test-invitation-onboarding-http.py', 'test_invitation_onboarding_http_unit.py'):
        source = (ROOT / 'scripts' / name).read_text(encoding='utf-8')
        compile(source, name, 'exec')
    for executable in ('node', 'pnpm.cmd' if os.name == 'nt' else 'pnpm', 'docker'):
        if not shutil.which(executable):
            raise RuntimeError('required executable unavailable')
    version = subprocess.run(['node', '--version'], capture_output=True, text=True, timeout=10)
    if version.returncode or not version.stdout.startswith('v24.'):
        raise RuntimeError('Node 24 required')
    check = subprocess.run(['node', '--check', str(ROOT / 'scripts/invitation-onboarding-bridge.mjs')],
                           capture_output=True, text=True, timeout=10)
    if check.returncode:
        raise RuntimeError('bridge syntax gate failed')
    native = Path(tempfile.gettempdir()).resolve()
    free = shutil.disk_usage(native).free
    payload = sum(p.stat().st_size for folder in ('migrations', 'tests')
                  for p in (ROOT / 'supabase' / folder).iterdir() if p.is_file())
    if not native.is_dir() or free < max(1024**3, payload * 4):
        raise RuntimeError('native temporary capacity unavailable')
    print('PREFLIGHT Node24 syntax tools payload_bytes=%d native_temp_free=%d' % (payload, free), flush=True)


def main():
    if invocation(sys.argv[1:], os.environ) == 'help':
        print(HELP, end='')
        return 0
    preflight()
    from http_test_support import DisposableStack, owned_context, local_origin
    http = load_http()
    stack = DisposableStack()
    proof = None
    try:
        with stack as path:
            print('OWNED project=' + path.name, flush=True)
            # No child-mode CLI exists. Only this freshly created binding is used.
            os.environ['HTTP_JWT_WORKDIR'] = str(path)
            try:
                _, context = owned_context()
                local_origin('http://127.0.0.1:%d' % context['port'], context['port'])
                p = http.Probes()
                p.bootstrap()
                proof = Proof(p)
                # Supported genuine password grant is a diagnostic control, not SQL Auth evidence.
                control = proof.snapshot()
                owner = p.session(p.password)
                print('DIAGNOSTIC supported Owner password grant effects', flush=True)
                state_diagnostics(control, proof.snapshot())
                provider_counter = p.sql("select pg_get_serial_sequence('auth.refresh_tokens','id') = 'auth.refresh_tokens_id_seq';")
                print('DIAGNOSTIC auth.refresh_tokens_id_seq ownership_matches=%d' % (provider_counter == 't'), flush=True)
                if provider_counter != 't':
                    raise RuntimeError('provider sequence ownership mismatch')
                status, verified = p.call('GET', '/auth/v1/user', token=owner['access_token'])
                if status != 200 or verified.get('id') != owner['user']['id']:
                    raise RuntimeError('Owner verification failed')
                proof.owner = str(uuid.UUID(verified['id']))
                proof.owner_token = owner['access_token']
                coverage = proof.snapshot()
                print('COVERAGE tables=%d sequences=%d' % (len(coverage['tables']), len(coverage['sequences'])), flush=True)
                for name, action in (('roles', proof.successes), ('invalid', proof.invalids),
                                     ('denials', proof.denials), ('interruption', proof.interruption),
                                     ('lost_response', proof.lost_response)):
                    proof.group(name, action)
            finally:
                os.environ.pop('HTTP_JWT_WORKDIR', None)
    finally:
        if proof:
            print('TOTAL ' + json.dumps(proof.groups, sort_keys=True), flush=True)
        print('OWNED lifecycle project=' + stack.project, flush=True)
    print('PASS actual service local Auth proof; handlers mail resend UI and T5 untested.', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print('FAIL onboarding proof; private diagnostics suppressed.', file=sys.stderr)
        sys.exit(1)
