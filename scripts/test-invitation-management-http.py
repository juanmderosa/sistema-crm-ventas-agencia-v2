"""Genuine current-actor service -> Auth User -> private preparation RPC proof."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
HELP = ('Usage: python -B scripts/test-invitation-management-http.py [--help]\n'
        'Default creates one owned cached-image local stack; synthetic identities, no mail.\n'
        'No existing stack, target or credential arguments accepted.\n'
        'See docs/invitation-management-http.md.\n')


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def preflight():
    for filename in ('test-invitation-management-http.py', 'test_invitation_management_http_unit.py'):
        compile((ROOT / 'scripts' / filename).read_text(encoding='utf-8'), filename, 'exec')
    for executable in ('node', 'pnpm.cmd' if os.name == 'nt' else 'pnpm', 'docker'):
        if not shutil.which(executable):
            raise RuntimeError('required executable unavailable')
    version = subprocess.run(['node', '--version'], capture_output=True, text=True, timeout=10)
    syntax = subprocess.run(['node', '--check', str(ROOT / 'scripts/invitation-management-bridge.mjs')],
        capture_output=True, text=True, timeout=10)
    sources = [ROOT / 'scripts/invitation-management-bridge.mjs',
               ROOT / 'apps/backoffice/features/accounts/invitations/management.ts']
    payload = sum(p.stat().st_size for p in sources)
    free = shutil.disk_usage(tempfile.gettempdir()).free
    if version.returncode or not version.stdout.startswith('v24.') or syntax.returncode or free < 1024**3:
        raise RuntimeError('native preparation gate failed')
    print('PREFLIGHT Node24 syntax tools source_bytes=%d native_free=%d' % (payload, free), flush=True)


def run(p, reusable):
    proof = reusable.Proof(p)  # Counter initialization only; no historical flows.
    actors = {}
    for role in ('owner', 'admin', 'seller', 'ghost', 'inactive'):
        email = 'management-' + role + '@example.invalid'
        uid = p.create_user(email)
        if role != 'ghost':
            p.sql("insert into public.profiles(id,role,display_name,is_active) values ('%s','%s','Synthetic Management',true);"
                  % (uid, 'admin' if role == 'inactive' else role))
        if role == 'seller':
            status, metadata = p.call('PUT', '/auth/v1/admin/users/' + uid,
                {'app_metadata': {'role': 'owner'}, 'user_metadata': {'role': 'owner'}}, p.service, p.service)
            proof.check('native metadata fixture accepted before password grant', status == 200
                and metadata['app_metadata']['role'] == metadata['user_metadata']['role'] == 'owner')
        status, session = p.signin(p.password, email)
        proof.check('genuine password session exact subject', status == 200
                    and session.get('user', {}).get('id') == uid and bool(session.get('access_token')))
        actors[role] = (uid, session['access_token'])
    proof.owner, proof.owner_token = actors['owner']
    targets = [proof.pending(810 + n, role) for n, role in enumerate(('admin', 'seller', 'seller'))]
    expected = {}
    for target in targets:
        status, user = p.call('GET', '/auth/v1/admin/users/' + target['uid'], key=p.service, token=p.service)
        proof.check('canonical fixture independently corroborated', status == 200 and user['id'] == target['uid'])
        expected[target['invitation']] = {'invitation_id': target['invitation'], 'email': target['email'],
            'role': target['role'], 'provenance': user['app_metadata']['staff_invitation_provenance'],
            'user_id': target['uid'], 'candidate_user_id': target['uid']}
    proof.check('Owner deactivates routine Admin after JWT issuance', p.call('PATCH',
        '/rest/v1/profiles?id=eq.' + actors['inactive'][0], {'is_active': False}, token=proof.owner_token) == (204, None))
    inventory = proof.snapshot()
    print('COVERAGE tables=%d sequences=%d sessions_audits_excluded=1' %
          (len(inventory['tables']), len(inventory['sequences'])), flush=True)
    counts = {'cases': 0, 'service_calls': 0, 'user_calls': 0, 'rpc_calls': 0, 'protected_checks': 0, 'checks': 0}
    journal_sql = "select coalesce(json_agg(t order by id),'[]') from public.staff_invitation_requests t;"

    def case(label, actor, target, code, request=None, insert=False, fault='none', extras=None, invalid=False):
        uid, token = actors[actor]
        request = request or str(uuid.uuid4())
        before, rows = proof.snapshot(), json.loads(p.sql(journal_sql))
        payload = {'workdir': str(p.workdir), 'api': p.api, 'key': p.anon, 'service': p.service,
            'actor': uid, 'expected': expected[target['invitation']], 'fault': fault,
            'input': dict({'requestID': request, 'invitationID': target['invitation'],
                          'actorAccessToken': 'invalid-printable-token' if invalid else token}, **(extras or {}))}
        env = dict(os.environ)
        for key in ('NODE_OPTIONS', 'NODE_USE_ENV_PROXY', 'NODE_EXTRA_CA_CERTS'):
            env.pop(key, None)
        child = subprocess.run(['node', str(ROOT / 'scripts/invitation-management-bridge.mjs')],
            input=json.dumps(payload), cwd=ROOT, env=env, capture_output=True, text=True, timeout=45)
        start = proof.assertions
        proof.check('private bridge process succeeds', child.returncode == 0)
        result = json.loads(child.stdout)
        proof.check('exact sanitized outcome', set(result) == {'code', 'canonical', 'frozen', 'privateOmitted', 'injected', 'trace'}
            and {k: v for k, v in result.items() if k != 'trace'} == {'code': code,
                'canonical': code == 'prepared', 'frozen': code == 'prepared', 'privateOmitted': True,
                'injected': fault == 'afterRPC'})
        trace = result['trace']
        native = [(t['path'], t['method'], t['status']) for t in trace]
        print('TRACE %s code=%s statuses=%s' % (label, result['code'],
              ','.join(str(t['status']) for t in trace)), flush=True)
        wanted = [('/auth/v1/user', 'GET', 403 if invalid else 200)]
        if not invalid:
            wanted.append(('/rest/v1/rpc/prepare_bound_staff_invitation_resend', 'POST', 200 if code != 'denied' else 403))
        proof.check('exact genuine transport order count status and credential actor boundaries', native == wanted
            and all(set(t) == {'path', 'method', 'status', 'headersMatch', 'actorMatch', 'redirect', 'signal'}
                    and all(t[k] is True for k in ('headersMatch', 'actorMatch', 'redirect', 'signal')) for t in trace))
        after_rows = json.loads(p.sql(journal_sql))
        added = [row for row in after_rows if row not in rows]
        proof.check('exact journal insertion and every old row unchanged',
            all(row in after_rows for row in rows) and len(after_rows) == len(rows) + int(insert)
            and (not added if not insert else len(added) == 1 and
                {k: v for k, v in added[0].items() if k != 'created_at'} == {
                    'id': request, 'invitation_id': target['invitation'], 'actor_id': uid, 'action': 'bound_resend'}))
        proof.preserved(before, ('public.staff_invitation_requests',) if insert else (), None)
        counts['cases'] += 1
        counts['service_calls'] += 1
        counts['user_calls'] += len(trace[:1])
        counts['rpc_calls'] += len(trace[1:])
        counts['protected_checks'] += 1
        counts['checks'] += proof.assertions - start
        print('CASE %s code=%s calls=%d statuses=%s' % (label, code, len(trace),
              ','.join(str(t['status']) for t in trace)), flush=True)
        return request

    admin, seller, lost = targets
    first = case('OwnerAdmin', 'owner', admin, 'prepared', insert=True)
    case('OwnerSeller', 'owner', seller, 'prepared', insert=True)
    case('AdminSeller', 'admin', seller, 'prepared', insert=True)
    case('ExplicitRetry', 'owner', admin, 'prepared', request=first)
    for actor, target in (('admin', admin), ('seller', seller), ('ghost', seller)):
        case('Denied-' + actor, actor, target, 'denied')
    case('ForgedOwnerExtrasAndMetadata', 'seller', seller, 'denied',
         extras={'actorID': proof.owner, 'actorUUID': proof.owner, 'role': 'owner'})
    case('InvalidPrintableJWT', 'owner', seller, 'authentication_failed', invalid=True)
    case('IssuedJWTInactiveAdmin', 'inactive', seller, 'denied')
    lost_request = case('LostCommittedRPCReply', 'owner', lost, 'preparation_uncertain', insert=True, fault='afterRPC')
    case('ExplicitLostReplyRetry', 'owner', lost, 'prepared', request=lost_request)
    print('GENUINE_TOTAL ' + json.dumps(counts, sort_keys=True), flush=True)


def main():
    if sys.argv[1:] == ['--help']:
        print(HELP, end='')
        return 0
    if sys.argv[1:] or 'HTTP_JWT_WORKDIR' in os.environ:
        raise ValueError('unsupported invocation')
    preflight()
    from http_test_support import DisposableStack, owned_context
    http = load('management_accounts', 'test-accounts-http.py')
    reusable = load('management_state', 'test-invitation-onboarding-http.py')
    with DisposableStack() as path:
        os.environ['HTTP_JWT_WORKDIR'] = str(path)
        try:
            owned_context()
            run(http.Probes(), reusable)
        finally:
            os.environ.pop('HTTP_JWT_WORKDIR', None)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print('FAIL management proof; private diagnostics suppressed.', file=sys.stderr)
        sys.exit(1)
