"""Synthetic local verification of existing bootstrap and recovery behavior.

Usage: python -B scripts/test-accounts-http.py
Requires Node 24, Python 3, Docker, pnpm and cached Supabase images.
Never targets the development stack or sends recovery email. See docs/accounts-http.md.
"""
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import urllib.error
import urllib.request
import uuid

from http_test_support import (
    ROOT, DisposableStack, NoRedirect, cli, error_matches, local_origin, owned_context,
)

EMAIL = 'accounts-owner@example.com'
NAME = 'Synthetic Accounts Owner'
SUCCESS = 'Dueño inicial aprovisionado correctamente.\n'
INITIAL_ERROR = ('No se pudo verificar el estado inicial. '
                 'No se modificó ninguna identidad.\n')
EXISTS_ERROR = ('La identidad ya existe. Use recuperación explícita con el '
                'identificador verificado; no se modificó la cuenta.\n')

# Executed by Node 24 directly; no generated JS/TS files or command-line secrets.
# The fetch wrapper observes real transport, never replaces provider responses.
RECOVERY_PROBE = r"""
import { pathToFileURL } from 'node:url';
let input = '';
for await (const chunk of process.stdin) input += chunk;
const p = JSON.parse(input);
const { createRecoveryService } = await import(pathToFileURL(p.module).href);
const trace = [];
let refresh = null;
const observe = async (url, init) => {
  const path = new URL(url).pathname + new URL(url).search;
  if (!['/auth/v1/verify', '/auth/v1/user', '/auth/v1/logout?scope=global'].includes(path)) {
    throw new Error('Unexpected recovery request');
  }
  const response = await fetch(url, init);
  const entry = { path, status: response.status, method: init.method };
  if (path === '/auth/v1/verify') {
    entry.type = JSON.parse(init.body).type;
    const body = await response.clone().json();
    if (response.ok) refresh = body.refresh_token;
    else entry.code = body.error_code ?? body.code;
  }
  trace.push(entry);
  return response;
};
const service = createRecoveryService({
  authUrl: p.api, apiKey: p.key, callbackOrigin: p.api,
}, observe);
const result = await service.complete(p.hash, p.password);
process.stdout.write(JSON.stringify({ result, trace, refresh }));
"""


def require(name, condition):
    print(('PASS ' if condition else 'FAIL ') + name, flush=True)
    if not condition:
        raise RuntimeError('account verification assertion failed; details suppressed')


class Probes:
    def __init__(self):
        self.workdir, self.context = owned_context()
        status = cli(self.workdir, 'status', '-o', 'json', timeout=60)
        if status.returncode:
            raise RuntimeError('owned stack status failed; output suppressed')
        # Status contains privileged keys: parse privately, never forward output.
        data = json.loads(status.stdout)
        self.api = local_origin(data['API_URL'], self.context['port'])
        self.anon = data['ANON_KEY']
        self.service = data['SERVICE_ROLE_KEY']
        self.password = secrets.token_urlsafe(32) + 'aA1!'
        self.replacement = secrets.token_urlsafe(32) + 'bB2!'
        self.refresh_credentials = []
        self.psql = ['docker', 'exec', '-i', 'supabase_db_' + self.context['project'],
                     'psql', '-X', '-A', '-t', '-q', '-v', 'ON_ERROR_STOP=1',
                     '-U', 'postgres']
        require('owned database starts without accounts or profiles',
                self.sql('select (select count(*) from auth.users)::text || '
                         "'|' || (select count(*) from public.profiles)::text;") == '0|0')

    def sql(self, query):
        result = subprocess.run(self.psql, input=query, capture_output=True, text=True,
                                encoding='utf-8', timeout=60)
        if result.returncode:
            raise RuntimeError('owned SQL probe failed; output suppressed')
        return result.stdout.strip()

    def call(self, method, path, body=None, key=None, token=None):
        key = key or self.anon
        headers = {'apikey': key, 'Accept': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        data = None
        if body is not None:
            headers['Content-Type'] = 'application/json'
            data = json.dumps(body).encode('utf-8')
        request = urllib.request.Request(self.api + path, method=method,
                                         headers=headers, data=data)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)
        try:
            with opener.open(request, timeout=20) as response:
                code, raw = response.status, response.read()
        except urllib.error.HTTPError as error:
            code, raw = error.code, error.read()
        # Network failures are fatal, never accepted as authorization denials.
        return code, json.loads(raw) if raw else None

    def create_user(self, email=EMAIL):
        code, body = self.call('POST', '/auth/v1/admin/users',
                               {'email': email, 'password': self.password,
                                'email_confirm': True}, self.service, self.service)
        require('supported Auth admin creates confirmed synthetic identity',
                code in (200, 201) and isinstance(body, dict) and body.get('email') == email
                and bool(body.get('email_confirmed_at')))
        return str(uuid.UUID(body['id']))

    def signin(self, password, email=EMAIL):
        return self.call('POST', '/auth/v1/token?grant_type=password',
                         {'email': email, 'password': password})

    def session(self, password):
        code, body = self.signin(password)
        require('password grant returns genuine session', code == 200
                and bool(body.get('access_token')) and bool(body.get('refresh_token'))
                and body.get('user', {}).get('email') == EMAIL)
        self.refresh_credentials.append(body['refresh_token'])
        return body

    def bootstrap(self, recover=False, user_id=None, expected_error=None):
        env = dict(os.environ)
        # Do not inherit operator bootstrap settings into synthetic scenarios.
        for name in list(env):
            if name.startswith('OWNER_BOOTSTRAP_'):
                env.pop(name)
        env.update(SUPABASE_URL=self.api, OWNER_BOOTSTRAP_TARGET=self.api,
                   SUPABASE_SERVICE_ROLE_KEY=self.service, OWNER_BOOTSTRAP_EMAIL=EMAIL,
                   OWNER_BOOTSTRAP_NAME=NAME)
        if recover:
            env['OWNER_BOOTSTRAP_USER_ID'] = user_id
        else:
            env['OWNER_BOOTSTRAP_PASSWORD'] = self.replacement if expected_error else self.password
        result = subprocess.run(['node', str(ROOT / 'scripts/bootstrap-owner.mjs')]
                                + (['--recover'] if recover else []), cwd=ROOT, env=env,
                                capture_output=True, text=True, encoding='utf-8', timeout=90)
        require('bootstrap exact exit/stdout/stderr',
                (result.returncode, result.stdout, result.stderr) ==
                ((1, '', expected_error) if expected_error else (0, SUCCESS, '')))

    def snapshot(self):
        # Read-only, private digest of all public tables and protected Auth identity
        # data; exclude provider sessions/audit logs which legitimate login changes.
        return self.sql("""
        do $$ declare r record; v text; h text=''; begin
          for r in select schemaname, tablename from pg_tables
            where schemaname='public' or
              (schemaname='auth' and tablename in ('users','identities'))
            order by schemaname, tablename loop
            execute format('select coalesce(string_agg(row_to_json(t)::text,''|'' order by row_to_json(t)::text),'''') from %I.%I t',
              r.schemaname,r.tablename) into v;
            h := h || r.schemaname || r.tablename || v;
          end loop;
          perform set_config('accounts_probe.digest',md5(h),false);
        end $$;
        select current_setting('accounts_probe.digest');
        """)

    def profile(self, user_id, token):
        code, body = self.call('GET', '/rest/v1/profiles?select=id,role,display_name,is_active',
                               token=token)
        require('one active Owner profile matches exact identity and fixture',
                code == 200 and body == [{'id': user_id, 'role': 'owner',
                                         'display_name': NAME, 'is_active': True}])

    def rpc(self, key, token, user_id=None):
        return self.call('POST', '/rest/v1/rpc/bootstrap_initial_owner',
                         {'p_email': EMAIL, 'p_user_id': user_id,
                          'p_display_name': None, 'p_finalize': False}, key, token)

    def boundaries(self, session):
        before = self.snapshot()
        for label, token in [('anon', None), ('authenticated', session['access_token'])]:
            code, body = self.rpc(self.anon, token)
            require(label + ' cannot execute bootstrap RPC', error_matches(code, body))
        for method, path, payload in [
            ('GET', '/rest/v1/profiles?select=id', None),
            ('POST', '/rest/v1/profiles', {'id': str(uuid.uuid4()), 'role': 'owner',
                                         'display_name': NAME, 'is_active': True}),
        ]:
            code, body = self.call(method, path, payload, self.service, self.service)
            require('service has no generic profile grant', error_matches(code, body))
        require('denied HTTP operations preserve protected data', self.snapshot() == before)

    def complete(self, token_hash, password, success):
        payload = {'module': str(ROOT / 'apps/backoffice/features/accounts/recovery/recovery.ts'),
                   'api': self.api, 'key': self.anon, 'hash': token_hash, 'password': password}
        result = subprocess.run(['node', '--input-type=module', '-e', RECOVERY_PROBE],
                                input=json.dumps(payload), cwd=ROOT, capture_output=True,
                                text=True, encoding='utf-8', timeout=60)
        require('real recovery subprocess completed', result.returncode == 0)
        observed = json.loads(result.stdout)  # Never print this private IPC payload.
        trace = observed['trace']
        require('actual token verification uses recovery type', bool(trace)
                and trace[0]['path'] == '/auth/v1/verify'
                and trace[0]['method'] == 'POST' and trace[0]['type'] == 'recovery')
        if success:
            require('real password update and global logout both succeed',
                    observed['result'] == {'ok': True}
                    and [(t['path'], t['method'], t['status']) for t in trace] == [
                        ('/auth/v1/verify', 'POST', 200),
                        ('/auth/v1/user', 'PUT', 200),
                        ('/auth/v1/logout?scope=global', 'POST', 204)]
                    and bool(observed['refresh']))
        else:
            require('invalid/replayed token is specifically rejected by Auth',
                    observed['result'] == {'ok': False, 'code': 'invalid_recovery'}
                    and len(trace) == 1 and trace[0]['status'] == 403
                    and trace[0].get('code') == 'otp_expired'
                    and observed['refresh'] is None)
        return observed['refresh']

    def recovery(self, user_id):
        sessions = [self.session(self.password), self.session(self.password)]
        require('two distinct pre-recovery refresh credentials exist',
                sessions[0]['refresh_token'] != sessions[1]['refresh_token'])
        before = self.snapshot()
        self.complete(secrets.token_hex(32), self.replacement, False)
        require('invalid hash preserves identity and all public data', self.snapshot() == before)
        code, body = self.call('POST', '/auth/v1/admin/generate_link',
                               {'type': 'recovery', 'email': EMAIL}, self.service, self.service)
        require('supported admin recovery link generated without sending email',
                code == 200 and isinstance(body, dict) and body.get('verification_type') == 'recovery'
                and isinstance(body.get('hashed_token'), str) and bool(body['hashed_token']))
        token_hash = body['hashed_token']
        public_before = self.sql("select md5(coalesce(jsonb_agg(to_jsonb(p) order by id)::text,'')) "
                                 'from public.profiles p;')
        recovery_refresh = self.complete(token_hash, self.replacement, True)
        # Include every earlier scenario login, not just the two explicit sessions.
        for refresh in self.refresh_credentials + [recovery_refresh]:
            code, body = self.call('POST', '/auth/v1/token?grant_type=refresh_token',
                                   {'refresh_token': refresh})
            require('old refresh credential rejected after global logout',
                    error_matches(code, body, (400,), ('refresh_token_not_found',
                                                       'refresh_token_already_used')))
        code, body = self.signin(self.password)
        require('old password specifically rejected',
                error_matches(code, body, (400,), ('invalid_credentials',)))
        current = self.session(self.replacement)
        require('recovery preserves Auth UUID', current['user']['id'] == user_id)
        require('recovery preserves profile history and attributes', public_before == self.sql(
            "select md5(coalesce(jsonb_agg(to_jsonb(p) order by id)::text,'')) from public.profiles p;"))
        before = self.snapshot()
        for invalid in (token_hash, secrets.token_hex(32)):
            self.complete(invalid, self.password, False)
            require('replay/invalid hash preserves all protected data', self.snapshot() == before)
        self.profile(user_id, self.session(self.replacement)['access_token'])

    def run(self, scenario):
        if scenario == 'recover':
            user_id = self.create_user()
            session = self.session(self.password)
            before = self.snapshot()
            self.bootstrap(expected_error=EXISTS_ERROR)
            require('implicit adoption rejected without identity/password changes', self.snapshot() == before)
            require('original password still authenticates same identity',
                    self.session(self.password)['user']['id'] == user_id)
            # Separate Auth-only identity makes explicit UUID/email disagreement real.
            other_id = self.create_user('accounts-conflict@example.com')
            before = self.snapshot()
            code, body = self.rpc(self.service, self.service, other_id)
            require('conflicting UUID/email has exact database rejection',
                    error_matches(code, body, (400,), ('23514',))
                    and body.get('message') == 'conflicting bootstrap identity')
            self.bootstrap(True, other_id, INITIAL_ERROR)
            require('conflicting explicit identity fails closed', self.snapshot() == before)
            code, body = self.rpc(self.service, self.service, user_id)
            require('service-only preflight recognizes Auth-only account',
                    code == 200 and body == 'auth_only')
            require('preflight is read-only', self.snapshot() == before)
            self.bootstrap(True, user_id)
        else:
            code, body = self.rpc(self.service, self.service)
            require('service-only fresh preflight returns missing', code == 200 and body == 'missing')
            self.bootstrap()
            session = self.session(self.password)
            user_id = str(uuid.UUID(session['user']['id']))
        session = self.session(self.password)
        require('exactly expected synthetic Auth identities remain', self.sql(
            'select count(*) from auth.users;') == ('2' if scenario == 'recover' else '1'))
        self.profile(user_id, session['access_token'])
        self.boundaries(session)
        before = self.snapshot()
        code, body = self.rpc(self.service, self.service, user_id)
        require('existing Owner has exact database rejection',
                error_matches(code, body, (400,), ('23514',))
                and body.get('message') == 'owner bootstrap is unavailable')
        self.bootstrap(expected_error=INITIAL_ERROR)
        self.bootstrap(True, user_id, INITIAL_ERROR)
        require('both existing-Owner reruns preserve protected data', self.snapshot() == before)
        require('reruns preserve original identity and password',
                self.session(self.password)['user']['id'] == user_id)
        code, body = self.signin(self.replacement)
        require('rejected rerun did not replace password',
                error_matches(code, body, (400,), ('invalid_credentials',)))
        if scenario == 'recover':
            self.recovery(user_id)


def main():
    if os.environ.get('HTTP_JWT_WORKDIR'):
        # Only the generated temporary binding accepted by unchanged owned_context.
        owned_context()
        if sys.argv[1:] not in (['--scenario', 'recover'], ['--scenario', 'fresh']):
            raise RuntimeError('invalid owned child invocation')
        Probes().run(sys.argv[2])
        return 0
    if sys.argv[1:]:
        raise RuntimeError('default invocation takes no arguments')
    # Same ownership/child protocol as isolated_run, with a finite child timeout.
    # Sequential stacks avoid retaining two database/Auth sets simultaneously.
    for scenario in ('recover', 'fresh'):
        print('Scenario: ' + scenario, flush=True)
        stack = DisposableStack()
        try:
            with stack as workdir:
                print('Owned temporary project: ' + workdir.name, flush=True)
                env = dict(os.environ, HTTP_JWT_WORKDIR=str(workdir), PYTHONDONTWRITEBYTECODE='1')
                child = subprocess.run([sys.executable, '-B', str(Path(__file__).resolve()),
                                        '--scenario', scenario], cwd=ROOT, env=env, timeout=600)
                if child.returncode:
                    return 1
        except Exception:
            # Also identify ownership if startup or teardown itself failed.
            print('Inspect only owned project: ' + stack.project, file=sys.stderr)
            raise
    print('Accounts HTTP verification passed; mailbox/UI/concurrency not tested.', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        # Exceptions can contain provider bodies, credentials or subprocess input.
        print('Accounts HTTP verification failed; sensitive diagnostics suppressed.', file=sys.stderr)
        sys.exit(1)
