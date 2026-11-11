"""Owned local HTTP races for existing account locks; see docs/accounts-concurrency.md."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

from http_test_support import ROOT, DisposableStack, local_origin, owned_context

# Reuse genuine Auth/HTTP, SQL capture and private snapshot conventions unchanged.
SPEC = importlib.util.spec_from_file_location('accounts_http', ROOT / 'scripts/test-accounts-http.py')
HTTP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HTTP)
require = HTTP.require
OWNER_LOCK = 'public.profiles.last_active_owner'
INVITE_LOCK = 'public.staff_invitation_intents'
BOOTSTRAP = '/rest/v1/rpc/bootstrap_initial_owner'
INVITE = '/rest/v1/rpc/manage_staff_invitation_intent'
SCRIPT = str(Path(__file__).resolve())


def finish(process, payload=None, timeout=45):
    """Capture all three subprocess channels, including on a deadline failure."""
    try:
        out, err = process.communicate(payload, timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()  # Drain privately; never print subprocess diagnostics.
        raise RuntimeError('local subprocess deadline exceeded') from None
    return process.returncode, out, err


class Races(HTTP.Probes):
    def auth(self, email):
        user_id = self.create_user(email)
        status, session = self.signin(self.password, email)
        require('synthetic password grant identifies exact user', status == 200
                and session.get('user', {}).get('id') == user_id
                and bool(session.get('access_token')) and bool(session.get('refresh_token')))
        # Trusted orchestration must derive actor identity from supported Auth,
        # not trust caller-supplied actor IDs or mutable token role claims.
        status, user = self.call('GET', '/auth/v1/user', token=session['access_token'])
        require('supported Auth verifies exact actor', status == 200
                and user.get('id') == user_id and user.get('email') == email
                and bool(user.get('email_confirmed_at')))
        return user_id, session['access_token']

    def launch(self, path, body):
        process = subprocess.Popen([sys.executable, '-B', SCRIPT, '--http'], cwd=ROOT,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, encoding='utf-8')
        payload = json.dumps({'api': self.api, 'key': self.service,
                              'path': path, 'body': body})
        return process, payload

    def response(self, future):
        code, out, err = future.result(timeout=50)
        require('HTTP subprocess exact successful exit and empty stderr', code == 0 and err == '')
        value = json.loads(out)
        require('HTTP subprocess emits only canonical private response',
                out == json.dumps(value) + '\n' and set(value) == {'status', 'body'})
        return value['status'], value['body']

    @contextmanager
    def blocker(self, namespace):
        # Inputs are fixed labels, never external SQL. The idle timeout is a
        # failsafe; release is always the explicit COMMIT handshake below.
        process = subprocess.Popen(self.psql, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, encoding='utf-8')
        try:
            process.stdin.write("set statement_timeout='10s';\n"
                                "set idle_in_transaction_session_timeout='45s';\nbegin;\n"
                                "select pg_advisory_xact_lock(hashtext('%s'));\n"
                                "select 'LOCKED|' || pg_backend_pid();\n" % namespace)
            process.stdin.flush()
            # The void lock SELECT emits a blank line before the ready marker.
            def ready():
                first = process.stdout.readline()
                return process.stdout.readline() if first == '\n' else first
            with ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(ready)
                try:
                    line = pending.result(timeout=12)
                except Exception:
                    process.kill()
                    raise
            require('controlled advisory holder explicitly ready',
                    line.startswith('LOCKED|') and line.rstrip().split('|')[-1].isdigit())
            yield int(line.rstrip().split('|')[-1])
        finally:
            if process.poll() is None:
                code, out, err = finish(process, "commit;\nselect 'RELEASED';\n\\q\n", timeout=12)
                require('controlled holder exact release acknowledgement',
                        (code, out, err) == (0, 'RELEASED\n', ''))
            else:
                finish(process, timeout=12)
                raise RuntimeError('controlled holder exited before explicit release')

    def wait(self, holder, namespace, function, count):
        # Bounded local synchronization, NOT background-job/provider polling.
        # Match the exact single-bigint advisory key, holder, RPC and wait state.
        observed = self.sql("""
        set statement_timeout='10s';
        do $$ declare deadline timestamptz := clock_timestamp()+interval '6 seconds';
          n integer;
        begin
          loop
            perform pg_stat_clear_snapshot();
            select count(distinct a.pid) into n
            from pg_stat_activity a join pg_locks l on l.pid=a.pid
            join pg_locks h on h.pid=%d and h.granted and h.locktype=l.locktype
              and h.database=l.database and h.classid=l.classid
              and h.objid=l.objid and h.objsubid=l.objsubid
            where a.wait_event_type='Lock' and a.wait_event='advisory'
              and a.state='active' and a.query like '%%%s%%'
              and l.locktype='advisory' and not l.granted and l.objsubid=1
              and l.classid=((hashtext('%s')::bigint >> 32) & 4294967295)::oid
              and l.objid=(hashtext('%s')::bigint & 4294967295)::oid
              and %d=any(pg_blocking_pids(a.pid));
            exit when n=%d;
            if clock_timestamp()>=deadline then
              raise exception 'expected advisory wait not observed';
            end if;
            perform pg_sleep(0.02);
          end loop;
        end $$;
        select 'WAIT_OBSERVED';
        """ % (holder, function, namespace, namespace, holder, count))
        require('exact RPC advisory wait observed before release', observed == 'WAIT_OBSERVED')

    def owner_race(self):
        emails = ['race-owner-one@example.com', 'race-owner-two@example.com']
        identities = [self.auth(email) for email in emails]
        auth_before = self.auth_hash()
        other_before = self.other_public_hash()
        bodies = [{'p_email': email, 'p_user_id': identity[0],
                   'p_display_name': 'Synthetic Race Owner', 'p_finalize': True}
                  for email, identity in zip(emails, identities)]
        # communicate() runs concurrently: stdin cannot serialize the requests.
        with ThreadPoolExecutor(max_workers=2) as pool:
            children = []
            with self.blocker(OWNER_LOCK) as holder:
                try:
                    for body in bodies:
                        process, payload = self.launch(BOOTSTRAP, body)
                        children.append((process, pool.submit(finish, process, payload)))
                    self.wait(holder, OWNER_LOCK, 'bootstrap_initial_owner', 2)
                except Exception:
                    for process, _ in children:
                        if process.poll() is None:
                            process.kill()
                    raise
            results = [self.response(future) for _, future in children]
            winner = [i for i, result in enumerate(results) if result == (200, 'created')]
            require('exactly one public finalization returns created', len(winner) == 1)
            winner = winner[0]
            status, body = results[1-winner]
            require('losing finalization has exact unavailable error', status == 400
                    and body.get('code') == '23514'
                    and body.get('message') == 'owner bootstrap is unavailable')
            owner_id, token = identities[winner]
            status, profiles = self.call('GET', '/rest/v1/profiles?select=id,role,display_name,is_active',
                                         token=token)
            require('exactly one active Owner persisted through public API', status == 200
                    and profiles == [{'id': owner_id, 'role': 'owner',
                                      'display_name': 'Synthetic Race Owner', 'is_active': True}])
            require('only one profile and no invitation history exists', self.sql(
                "select (select count(*) from public.profiles)=1 and "
                "(select count(*) from public.staff_invitation_intents)=0 and "
                "(select count(*) from public.staff_invitation_requests)=0;") == 't')
            # Compare protected Auth rows separately from the intentional profile insert.
            require('finalization preserves both complete Auth identities',
                    auth_before == self.auth_hash())
            for email, identity in zip(emails, identities):
                status, session = self.signin(self.password, email)
                require('both original passwords and UUIDs survive finalization', status == 200
                        and session.get('user', {}).get('id') == identity[0])
            require('Owner finalization preserves every other public table',
                    self.other_public_hash() == other_before)
            return owner_id, token

    def auth_hash(self):
        return self.sql("select md5((select coalesce(jsonb_agg(to_jsonb(u) order by id)::text,'') "
                        "from auth.users u) || (select coalesce(jsonb_agg(to_jsonb(i) order by id)::text,'') "
                        "from auth.identities i));")

    def other_public_hash(self):
        return self.sql("""
        do $$ declare r record; v text; h text=''; begin
          for r in select schemaname, tablename from pg_tables
            where schemaname='public' and tablename<>'profiles'
            order by tablename loop
            execute format('select coalesce(string_agg(row_to_json(t)::text,''|'' order by row_to_json(t)::text),'''') from %I.%I t',
              r.schemaname,r.tablename) into v;
            h := h || r.tablename || v;
          end loop;
          perform set_config('accounts_race.digest',md5(h),false);
        end $$;
        select current_setting('accounts_race.digest');
        """)

    def patch(self, actor_id, owner_token, fields):
        # Use the unchanged direct profile-update public API, never fixture SQL.
        status, body = self.call('PATCH', '/rest/v1/profiles?id=eq.' + actor_id,
                                 fields, token=owner_token)
        require('Owner direct profile update succeeds exactly', (status, body) == (204, None))
        status, body = self.call('GET', '/rest/v1/profiles?id=eq.' + actor_id
                                 + '&select=id,role,is_active', token=owner_token)
        require('Owner public read confirms exact actor state', status == 200
                and body == [{'id': actor_id, 'role': fields.get('role', 'admin'),
                              'is_active': fields.get('is_active', True)}])

    def invitation_race(self, owner_token, actor_id, actor_token, demote=False):
        status, user = self.call('GET', '/auth/v1/user', token=actor_token)
        require('original genuine actor JWT remains Auth-valid', status == 200
                and user.get('id') == actor_id)
        invitation_id = str(uuid.uuid4())
        body = {'p_request_id': str(uuid.uuid4()), 'p_invitation_id': invitation_id,
                'p_actor_id': user['id'], 'p_action': 'create',
                'p_email': 'race-pending@example.com', 'p_role': 'seller'}
        with ThreadPoolExecutor(max_workers=1) as pool:
            with self.blocker(INVITE_LOCK) as holder:
                process, payload = self.launch(INVITE, body)
                future = pool.submit(finish, process, payload)
                try:
                    self.wait(holder, INVITE_LOCK, 'manage_staff_invitation_intent', 1)
                    self.patch(actor_id, owner_token,
                               {'role': 'seller'} if demote else {'is_active': False})
                    # Snapshot AFTER the deliberate Owner change and BEFORE release.
                    before = self.snapshot()
                except Exception:
                    process.kill()
                    raise
            status, denied = self.response(future)
        require('invitation denies current unauthorized actor after wait', status == 403
                and denied.get('code') == '42501'
                and denied.get('message') == 'No tiene permiso para gestionar esta invitación.')
        require('rejected invitation preserves all public and protected Auth data',
                self.snapshot() == before)
        require('denial creates no pending intent or request history', self.sql(
            'select (select count(*) from public.staff_invitation_intents)=0 and '
            '(select count(*) from public.staff_invitation_requests)=0;') == 't')

    def run_races(self):
        owner_id, owner_token = self.owner_race()
        actor_id, actor_token = self.auth('race-admin@example.com')
        # No profile-creation public API exists for this synthetic Admin fixture.
        self.sql("insert into public.profiles(id,role,display_name,is_active) "
                 "values ('%s','admin','Synthetic Race Admin',true);" % actor_id)
        require('initial Admin fixture visible through Owner API', self.call(
            'GET', '/rest/v1/profiles?id=eq.' + actor_id + '&select=id,role,is_active',
            token=owner_token) == (200, [{'id': actor_id, 'role': 'admin', 'is_active': True}]))
        self.invitation_race(owner_token, actor_id, actor_token)
        self.patch(actor_id, owner_token, {'is_active': True})
        self.invitation_race(owner_token, actor_id, actor_token, demote=True)
        require('Owner remains active after all races', self.call(
            'GET', '/rest/v1/profiles?id=eq.' + owner_id + '&select=id,role,is_active',
            token=owner_token) == (200, [{'id': owner_id, 'role': 'owner', 'is_active': True}]))


def main():
    if os.environ.get('HTTP_JWT_WORKDIR'):
        _, context = owned_context()
        if sys.argv[1:] == ['--http']:
            payload = json.load(sys.stdin)
            probe = object.__new__(HTTP.Probes)
            probe.api = local_origin(payload['api'], context['port'])
            probe.anon = payload['key']
            if payload['path'] not in (BOOTSTRAP, INVITE):
                raise RuntimeError('unsupported private HTTP child request')
            status, body = probe.call('POST', payload['path'], payload['body'],
                                      payload['key'], payload['key'])
            print(json.dumps({'status': status, 'body': body}))
            return 0
        if sys.argv[1:] != ['--races']:
            raise RuntimeError('invalid owned child invocation')
        Races().run_races()
        return 0
    if sys.argv[1:]:
        raise RuntimeError('default invocation takes no arguments')
    stack = DisposableStack()
    try:
        with stack as workdir:
            print('Owned temporary project: ' + workdir.name, flush=True)
            env = dict(os.environ, HTTP_JWT_WORKDIR=str(workdir), PYTHONDONTWRITEBYTECODE='1')
            child = subprocess.Popen([sys.executable, '-B', SCRIPT, '--races'], cwd=ROOT,
                                     env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, encoding='utf-8')
            code, out, err = finish(child, timeout=240)
            # Only fixed assertion labels may leave private child output.
            for line in out.splitlines():
                if line.startswith(('PASS ', 'FAIL ')):
                    print(line, flush=True)
            require('owned concurrency child exits cleanly', code == 0 and err == '')
    except Exception:
        print('Inspect only owned project: ' + stack.project, file=sys.stderr)
        raise
    print('Accounts concurrency verification passed; session revocation not tested.', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print('Accounts concurrency verification failed; sensitive diagnostics suppressed.', file=sys.stderr)
        sys.exit(1)
