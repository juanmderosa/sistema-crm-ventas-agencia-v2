"""Prepared, not live-verified: owned invitation binding probes; see the run contract."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid
from concurrent.futures import ThreadPoolExecutor

HELP = """Usage: python -B scripts/test-invitation-binding-http.py [--help]

Default: one disposable local stack, synthetic identities, no email delivery.
Requires fresh explicit live-verification authorization; preparation is static-only.
No target, credential or account arguments are accepted. See docs/invitation-binding-http.md.
"""
PREPARE = 'prepare_staff_invitation_identity'
BIND = 'bind_staff_invitation_identity'
CONFLICT = 'La identidad de la invitación requiere verificación.'
FORBIDDEN = 'No tiene permiso para gestionar esta invitación.'
SCRIPT = str(Path(__file__).resolve())

# Exact trusted harness vocabulary, never prefix-based forwarding of child text.
STAGES = frozenset(('probe-init', 'owner-bootstrap', 'binding', 'identity-rejections',
                    'api-boundaries', 'actor-wait', 'complete'))
ASSERTIONS = frozenset((
    'public intent command returns exact invitation UUID',
    'prepare returns exact private candidate JSON',
    'supported Admin creates unconfirmed passwordless pending user',
    'supported Admin re-read identifies exact pending UUID',
    'Auth verifies bootstrapped Owner actor identity',
    'stable provenance preparation retry preserves protected state',
    'candidate recovery is read-only', 'bind returns exact Admin-verified UUID',
    'bind retry returns same immutable UUID',
    'bound retries preserve all protected state including timestamps',
    'pending bound user has no operational profile',
    'untrusted identity prepare has exact conflict error',
    'rejected candidate leaves all protected rows unchanged',
    'user metadata cannot authorize binding',
    'spoofed bind leaves all protected rows unchanged',
    'ordinary API caller cannot execute private binding RPC',
    'denied RPC preserves all protected state',
    'ordinary API caller cannot read private binding table',
    'denied table read preserves all protected state',
    'synthetic Admin fixture is confirmed through Owner API',
    'Auth verifies race actor before trusted orchestration',
    'prepare rechecks current actor after observed advisory wait',
    'after-wait rejection preserves all protected rows and counters',
    'owned database starts without accounts or profiles',
    'bootstrap exact exit/stdout/stderr', 'password grant returns genuine session',
    'one active Owner profile matches exact identity and fixture',
    'supported Auth admin creates confirmed synthetic identity',
    'synthetic password grant identifies exact user', 'supported Auth verifies exact actor',
    'controlled advisory holder explicitly ready',
    'controlled holder exact release acknowledgement',
    'exact RPC advisory wait observed before release',
    'Owner direct profile update succeeds exactly',
    'Owner public read confirms exact actor state',
))
HTTP_CATEGORIES = frozenset(('prepare', 'bind', 'intent', 'auth-admin-create',
                            'auth-admin-read', 'auth-user', 'auth-token',
                            'profiles', 'binding-table'))


ENVELOPE_FIELDS = ('status_match', 'body_object', 'keys_match', 'code_match',
                   'details_present', 'details_match', 'hint_present', 'hint_match',
                   'message_present', 'message_match')
ENVELOPE_PATTERN = re.compile('ENVELOPE ' + ' '.join(name + '=[01]' for name in ENVELOPE_FIELDS))


def hint_matches(actual, expected, allow_text_hint=False):
    return (actual is None or isinstance(actual, str)) if allow_text_hint else actual == expected


def denial_matches(response, expected, allow_text_hint=False):
    if not allow_text_hint:
        return response == expected
    body = response[1]
    return (response[0] == expected[0] and isinstance(body, dict)
            and body.keys() == expected[1].keys()
            and all(body[field] == value for field, value in expected[1].items() if field != 'hint')
            and hint_matches(body['hint'], expected[1]['hint'], True))


def envelope_flags(response, expected, allow_text_hint=False):
    """Return fixed structural indicators only; never stringify provider data."""
    body = response[1]
    is_object = isinstance(body, dict)
    flags = [response[0] == expected[0], is_object,
             is_object and body.keys() == expected[1].keys(),
             is_object and body.get('code') == expected[1]['code']]
    for field in ('details', 'hint', 'message'):
        present = is_object and field in body
        matches = present and (hint_matches(body[field], expected[1][field], allow_text_hint)
                               if field == 'hint' else body[field] == expected[1][field])
        flags.extend((present, matches))
    return 'ENVELOPE ' + ' '.join(name + '=' + str(int(flag))
                                 for name, flag in zip(ENVELOPE_FIELDS, flags))


def stage(name):
    if name not in STAGES:
        raise RuntimeError('unknown diagnostic stage')
    print('STAGE ' + name, flush=True)


def observe_http(call):
    """Observe the existing call exactly once; never inspect/print its body."""
    def observed(method, path, *args, **kwargs):
        response = call(method, path, *args, **kwargs)
        categories = {
            '/rest/v1/rpc/' + PREPARE: 'prepare',
            '/rest/v1/rpc/' + BIND: 'bind',
            '/rest/v1/rpc/manage_staff_invitation_intent': 'intent',
            '/auth/v1/admin/users': 'auth-admin-create',
            '/auth/v1/user': 'auth-user',
        }
        category = categories.get(path)
        for prefix, label in (('/auth/v1/admin/users/', 'auth-admin-read'),
                              ('/auth/v1/token?', 'auth-token'),
                              ('/rest/v1/profiles?', 'profiles'),
                              ('/rest/v1/staff_invitation_identity_bindings?', 'binding-table')):
            if path.startswith(prefix):
                category = label
        status = response[0]
        if category and type(status) is int and 100 <= status <= 599:
            print('HTTP %s status=%d' % (category, status), flush=True)
        return response
    return observed


def forward_observations(output):
    if isinstance(output, bytes):
        output = output.decode('utf-8', errors='replace')
    passes = failures = 0
    for line in (output or '').splitlines():
        if ENVELOPE_PATTERN.fullmatch(line):
            print(line, flush=True)
        elif line in {'STAGE ' + name for name in STAGES}:
            print(line, flush=True)
        elif line in {prefix + label for prefix in ('PASS ', 'FAIL ') for label in ASSERTIONS}:
            print(line, flush=True)
            passes += line.startswith('PASS ')
            failures += line.startswith('FAIL ')
        elif line in {'HTTP %s status=%d' % (category, status)
                      for category in HTTP_CATEGORIES for status in range(100, 600)}:
            print(line, flush=True)
    print('OBSERVED assertion-labels pass=%d fail=%d' % (passes, failures), flush=True)


def load_races(root):
    spec = importlib.util.spec_from_file_location(
        'binding_races', root / 'scripts/test-accounts-concurrency.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_owned(root):
    # Races already dynamically imports the existing HTTP Probes. Reuse both,
    # including SQL snapshots, supported Auth verification and lock handshakes.
    stage('probe-init')
    races = load_races(root)
    p = races.Races()
    p.call = observe_http(p.call)
    require = races.require

    def service(function, body):
        return p.call('POST', '/rest/v1/rpc/' + function, body, p.service, p.service)

    def denied(label, response, status, code, message, allow_text_hint=False):
        expected = (status, {
            'code': code, 'details': None, 'hint': None, 'message': message})
        matches = denial_matches(response, expected, allow_text_hint)
        if not matches:
            print(envelope_flags(response, expected, allow_text_hint), flush=True)
        require(label, matches)

    def intent(actor, email, role='seller'):
        invitation = str(uuid.uuid4())
        require('public intent command returns exact invitation UUID', service(
            'manage_staff_invitation_intent', {
                'p_request_id': str(uuid.uuid4()), 'p_invitation_id': invitation,
                'p_actor_id': actor, 'p_action': 'create', 'p_email': email,
                'p_role': role}) == (200, invitation))
        return {'p_invitation_id': invitation, 'p_actor_id': actor,
                'p_provenance': str(uuid.uuid4())}

    def prepared(body, email, role, bound=None, candidate=None):
        require('prepare returns exact private candidate JSON', service(PREPARE, body) == (200, {
            'invitation_id': body['p_invitation_id'], 'email': email, 'role': role,
            'provenance': body['p_provenance'], 'user_id': bound,
            'candidate_user_id': candidate}))

    def pending_user(email, metadata_key=None, reservation=None):
        payload = {'email': email, 'email_confirm': False}
        markers = {} if metadata_key is None else {
            'staff_invitation_id': reservation['p_invitation_id'],
            'staff_invitation_provenance': reservation['p_provenance']}
        if metadata_key:
            payload[metadata_key] = markers
        # Intentionally omit password. Admin create does not send invitation mail.
        status, user = p.call('POST', '/auth/v1/admin/users', payload, p.service, p.service)
        require('supported Admin creates unconfirmed passwordless pending user',
                status in (200, 201) and isinstance(user, dict)
                and user.get('email') == email and not user.get('email_confirmed_at'))
        user_id = str(uuid.UUID(user['id']))
        status, exact = p.call('GET', '/auth/v1/admin/users/' + user_id,
                               key=p.service, token=p.service)
        require('supported Admin re-read identifies exact pending UUID',
                status == 200 and isinstance(exact, dict) and exact.get('id') == user_id
                and exact.get('email') == email and not exact.get('email_confirmed_at')
                and all(exact.get(metadata_key, {}).get(k) == v for k, v in markers.items()))
        return user_id

    # Bootstrap only through the existing trusted CLI, then derive the actor UUID
    # from a genuine session and supported Auth /user verification.
    stage('owner-bootstrap')
    p.bootstrap()
    session = p.session(p.password)
    status, owner = p.call('GET', '/auth/v1/user', token=session['access_token'])
    require('Auth verifies bootstrapped Owner actor identity', status == 200
            and owner.get('id') == session['user']['id']
            and owner.get('email') == races.HTTP.EMAIL and bool(owner.get('email_confirmed_at')))
    owner_id = str(uuid.UUID(owner['id']))
    owner_token = session['access_token']
    p.profile(owner_id, owner_token)

    stage('binding')
    email = 'binding-pending@example.invalid'
    reservation = intent(owner_id, email, 'admin')
    prepared(reservation, email, 'admin')
    before = p.snapshot()
    prepared(reservation, email, 'admin')
    require('stable provenance preparation retry preserves protected state', p.snapshot() == before)
    user_id = pending_user(email, 'app_metadata', reservation)
    before = p.snapshot()
    prepared(reservation, email, 'admin', candidate=user_id)
    require('candidate recovery is read-only', p.snapshot() == before)
    binding = dict(reservation, p_user_id=user_id)
    require('bind returns exact Admin-verified UUID', service(BIND, binding) == (200, user_id))
    before = p.snapshot()
    require('bind retry returns same immutable UUID', service(BIND, binding) == (200, user_id))
    prepared(reservation, email, 'admin', user_id, user_id)
    require('bound retries preserve all protected state including timestamps', p.snapshot() == before)
    require('pending bound user has no operational profile', p.call(
        'GET', '/rest/v1/profiles?id=eq.' + user_id + '&select=id,role,is_active',
        token=owner_token) == (200, []))

    stage('identity-rejections')
    for spoof in (False, True):
        other_email = 'binding-spoof@example.invalid' if spoof else 'binding-unrelated@example.invalid'
        other = intent(owner_id, other_email)
        if spoof:
            prepared(other, other_email, 'seller')
        other_id = pending_user(other_email, 'user_metadata' if spoof else None, other)
        before = p.snapshot()
        denied('untrusted identity prepare has exact conflict error', service(PREPARE, other),
               400, '23514', CONFLICT)
        require('rejected candidate leaves all protected rows unchanged', p.snapshot() == before)
        if spoof:
            denied('user metadata cannot authorize binding',
                   service(BIND, dict(other, p_user_id=other_id)), 400, '23514', CONFLICT)
            require('spoofed bind leaves all protected rows unchanged', p.snapshot() == before)

    stage('api-boundaries')
    for token in (None, owner_token):
        status = 401 if token is None else 403
        for function, body in ((PREPARE, reservation), (BIND, binding)):
            before = p.snapshot()
            denied('ordinary API caller cannot execute private binding RPC', p.call(
                'POST', '/rest/v1/rpc/' + function, body, token=token), status, '42501',
                'permission denied for function ' + function)
            require('denied RPC preserves all protected state', p.snapshot() == before)
        before = p.snapshot()
        denied('ordinary API caller cannot read private binding table', p.call(
            'GET', '/rest/v1/staff_invitation_identity_bindings?select=*', token=token),
            status, '42501', 'permission denied for table staff_invitation_identity_bindings',
            allow_text_hint=True)
        require('denied table read preserves all protected state', p.snapshot() == before)

    stage('actor-wait')
    admin_id, admin_token = p.auth('binding-race-admin@example.invalid')
    # No profile creation API exists. Only this public-table synthetic fixture
    # uses SQL writes; Auth users always come from supported Admin operations.
    p.sql("insert into public.profiles(id,role,display_name,is_active) "
          "values ('%s','admin','Synthetic Binding Admin',true);" % admin_id)
    require('synthetic Admin fixture is confirmed through Owner API', p.call(
        'GET', '/rest/v1/profiles?id=eq.' + admin_id + '&select=id,role,is_active',
        token=owner_token) == (200, [{'id': admin_id, 'role': 'admin', 'is_active': True}]))
    status, actor = p.call('GET', '/auth/v1/user', token=admin_token)
    require('Auth verifies race actor before trusted orchestration', status == 200
            and actor.get('id') == admin_id and bool(actor.get('email_confirmed_at')))
    waiting = intent(str(uuid.UUID(actor['id'])), 'binding-wait@example.invalid')
    with ThreadPoolExecutor(max_workers=1) as pool:
        with p.blocker(races.INVITE_LOCK) as holder:
            # The older --http guard intentionally does not support this RPC.
            future = pool.submit(p.call, 'POST', '/rest/v1/rpc/' + PREPARE,
                                 waiting, p.service, p.service)
            p.wait(holder, races.INVITE_LOCK, PREPARE, 1)
            p.patch(admin_id, owner_token, {'is_active': False})
            before = p.snapshot()  # AFTER deliberate PATCH, BEFORE explicit release.
        denied('prepare rechecks current actor after observed advisory wait',
               future.result(timeout=25), 403, '42501', FORBIDDEN)
    require('after-wait rejection preserves all protected rows and counters', p.snapshot() == before)
    stage('complete')


def main():
    # Harmless help exits before helper imports, environment reads or provider work.
    if sys.argv[1:] == ['--help']:
        print(HELP, end='')
        return 0
    from http_test_support import ROOT, DisposableStack, local_origin, owned_context
    if sys.argv[1:] == ['--owned-binding']:
        _, context = owned_context()
        local_origin('http://127.0.0.1:%d' % context['port'], context['port'])
        run_owned(ROOT)
        return 0
    if sys.argv[1:] or os.environ.get('HTTP_JWT_WORKDIR'):
        raise RuntimeError('unsupported invocation')
    phase = 'startup'
    print('STAGE stack-startup', flush=True)
    stack = DisposableStack()
    try:
        with stack as workdir:
            print('STAGE stack-ready', flush=True)
            phase = 'child'
            env = dict(os.environ, HTTP_JWT_WORKDIR=str(workdir), PYTHONDONTWRITEBYTECODE='1')
            try:
                child = subprocess.run([sys.executable, '-B', SCRIPT, '--owned-binding'],
                                       cwd=ROOT, env=env, capture_output=True, text=True,
                                       encoding='utf-8', timeout=240)
            except subprocess.TimeoutExpired as error:
                phase = 'child-timeout'
                forward_observations(error.output)
                print('DIAGNOSTIC child timeout=240 exit=unavailable stderr=' +
                      ('present' if error.stderr else 'absent'), flush=True)
                raise
            forward_observations(child.stdout)
            print('DIAGNOSTIC child exit=%d stderr=%s' %
                  (child.returncode, 'present' if child.stderr else 'absent'), flush=True)
            if child.returncode != 0 or child.stderr != '':
                raise RuntimeError('owned binding child failed')
            phase = 'teardown'
    except Exception:
        print('DIAGNOSTIC failure=' + phase, flush=True)
        print('Inspect only owned project: ' + stack.project, file=sys.stderr)
        raise
    print('Invitation binding probes passed; acceptance/activation/delivery not tested.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print('Invitation binding probe failed; sensitive diagnostics suppressed.', file=sys.stderr)
        sys.exit(1)
