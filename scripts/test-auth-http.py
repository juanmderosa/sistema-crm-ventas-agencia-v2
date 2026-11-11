"""Verify Auth/PostgREST/JWT enforcement in a disposable local stack.

Usage: python scripts/test-auth-http.py
Requires cached Supabase images, Docker, pnpm and Python 3.
Standard library only; no PowerShell scripts are executed.

The parent owns a fresh project and removes its entire stack in finally,
including when fixture creation or a probe fails. Development data is not used.
"""
import base64
import json
import os
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from http_test_support import error_matches, local_origin, NoRedirect, isolated_run, owned_context

if not os.environ.get('HTTP_JWT_WORKDIR'):
    sys.exit(isolated_run(Path(__file__).resolve()))
WORKDIR, CONTEXT = owned_context()

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:  # noqa: BLE001
    pass

Pnpm = 'pnpm.cmd' if os.name == 'nt' else 'pnpm'
PSQL = ['docker', 'exec', '-i', 'supabase_db_' + CONTEXT['project'], 'psql', '-X', '-A', '-t',
        '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres']
TAG = 'auth' + uuid.uuid4().hex[:8]
PASSWORD = secrets.token_urlsafe(18)
PHONE_A = '+54911%09d' % int(TAG[4:12], 16)
PHONE_B = '+54912%09d' % int(TAG[4:12], 16)
RESULTS = []
FAILURES = []
RETAINED = []


def check(name, ok, obs='', full=None):
    ok = bool(ok)
    if not ok:
        FAILURES.append(name)
    RESULTS.append((name, ok))
    # Never log payloads, JWTs, passwords or customer/profile fields.
    print('%s %s' % ('PASS' if ok else 'FAIL', name), flush=True)


def sql(query, fatal=True):
    run = subprocess.run(PSQL, input=query, text=True, capture_output=True,
                         encoding='utf-8', timeout=60)
    if run.returncode != 0:
        if fatal:
            raise SystemExit('SQL probe failed (%s); details suppressed' % run.returncode)
        RETAINED.append('SQL probe failed; details suppressed')
        return None
    return run.stdout.strip()


def has_column(table, column):
    return sql("select exists (select 1 from information_schema.columns where "
               "table_schema='public' and table_name='%s' and column_name='%s');"
               % (table, column)) == 't'


def state_hash():
    return sql('select public.http_probe_state_hash();')


def decode(token):
    payload = token.split('.')[1]
    payload += '=' * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def call(method, path, key=None, token=None, body=None, extra=None):
    headers = {'Accept': 'application/json'}
    if key:
        headers['apikey'] = key
    if token:
        headers['Authorization'] = 'Bearer ' + token
    data = None
    if body is not None:
        data = json.dumps(body).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    if extra:
        headers.update(extra)
    request = urllib.request.Request(API + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect).open(request, timeout=30) as response:
            code, raw = response.status, response.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as error:
        code, raw = error.code, error.read().decode('utf-8', 'replace')
    except Exception as error:  # noqa: BLE001
        return 0, repr(error)
    try:
        return code, json.loads(raw)
    except (ValueError, TypeError):
        return code, raw


def rpc(name, token, body, key=None):
    return call('POST', '/rest/v1/rpc/' + name, key=key or ANON, token=token, body=body)


def denied(name, code, body, statuses=(401, 403), codes=('42501',)):
    check(name, error_matches(code, body, statuses, codes))


# --- environment ------------------------------------------------------------
status = subprocess.run([Pnpm, 'exec', 'supabase', '--workdir', str(WORKDIR), 'status', '-o', 'env'], capture_output=True,
                        text=True, encoding='utf-8', timeout=180)
raw_env = status.stdout + '\n' + status.stderr


def var(name):
    match = re.search(r'^%s=(.+)$' % name, raw_env, re.M)
    if not match:
        raise SystemExit('missing %s in `pnpm db:status -o env` output' % name)
    return match.group(1).strip().strip('"')


API = local_origin(var('API_URL'), CONTEXT['port'])
ANON = var('ANON_KEY')
SERVICE = var('SERVICE_ROLE_KEY')
sql("""create function public.http_probe_state_hash() returns text language plpgsql as $$
declare r record; h text=''; value text;
begin
 for r in select tablename from pg_tables where schemaname='public' order by tablename loop
  execute format('select coalesce(string_agg(row_to_json(t)::text,''|'' order by row_to_json(t)::text),'''') from public.%I t',r.tablename) into value;
  h:=h||r.tablename||value;
 end loop;
 return md5(h);
end$$;
revoke all on function public.http_probe_state_hash() from public,anon,authenticated,service_role;
""")

# The reporting calendar runs on America/Argentina/Buenos_Aires (docs/reporting.md).
# Anchor on the database's own clock in that zone: the previous UTC date falls in
# the wrong month on the first day of a month after 03:00 UTC, which would put a
# just-created inquiry outside the requested period.
START = sql("select to_char(current_timestamp at time zone "
            "'America/Argentina/Buenos_Aires', 'YYYY-MM-DD');")

# --- fixtures ---------------------------------------------------------------
users = {}
for role in ('owner', 'admin', 'seller1', 'seller2', 'ghost', 'inactive'):
    code, body = call('POST', '/auth/v1/admin/users', key=SERVICE, token=SERVICE,
                      body={'email': '%s_%s@example.com' % (TAG, role),
                            'password': PASSWORD, 'email_confirm': True})
    check('fixture GoTrue user %s' % role, code in (200, 201), '%s %s' % (code, str(body)[:120]))
    users[role] = body.get('id') if isinstance(body, dict) else None
    if not users[role]:
        raise SystemExit('cannot continue without the %s fixture' % role)

V_PUB, V_DRAFT, V_DELETED, V_OWNER, V_ATTEMPT = (str(uuid.uuid4()) for _ in range(5))
sql("""
insert into public.profiles (id, display_name, role, is_active) values
  ('%(owner)s', '%(tag)s_owner', 'owner', true),
  ('%(seller1)s', '%(tag)s_seller1', 'seller', true),
  ('%(seller2)s', '%(tag)s_seller2', 'seller', true),
  ('%(inactive)s', '%(tag)s_inactive', 'seller', false);
insert into public.vehicles
  (id, brand, model, year, publication_status, availability_status, created_by) values
  ('%(vpub)s', 'Probe', 'AuthPublished', 2024, 'published', 'available', '%(seller1)s'),
  ('%(vdraft)s', 'Probe', 'AuthDraft', 2024, 'draft', 'available', '%(seller1)s'),
  ('%(vdel)s', 'Probe', 'AuthDeleted', 2024, 'published', 'available', '%(seller1)s');
update public.vehicles set deleted_at = now() where id = '%(vdel)s';
insert into public.vehicle_inquiry_participants (vehicle_id, profile_id) values
  ('%(vpub)s', '%(seller1)s'), ('%(vpub)s', '%(seller2)s');
""" % {'owner': users['owner'], 'seller1': users['seller1'], 'seller2': users['seller2'],
       'inactive': users['inactive'], 'tag': TAG, 'vpub': V_PUB, 'vdraft': V_DRAFT,
       'vdel': V_DELETED})

sql("insert into public.profiles(id,role,display_name) values ('%s','admin','HTTP Admin');" % users['admin'])
tokens = {}
for role in ('owner', 'admin', 'seller1', 'seller2', 'ghost', 'inactive'):
    code, body = call('POST', '/auth/v1/token?grant_type=password', key=ANON,
                      body={'email': '%s_%s@example.com' % (TAG, role), 'password': PASSWORD})
    check('fixture sign-in %s' % role, code == 200, '%s %s' % (code, str(body)[:140]))
    if code != 200:
        raise SystemExit('cannot continue without the %s token' % role)
    tokens[role] = body['access_token']
    claims = decode(tokens[role])
    check('fixture JWT claims %s' % role,
          claims.get('role') == 'authenticated' and claims.get('sub') == users[role],
          '%s / %s' % (claims.get('role'), claims.get('sub')))

SNAP0 = state_hash()

# --- A. transport identity --------------------------------------------------
code, body = call('GET', '/auth/v1/health', key=ANON)
check('A1 auth health responds', code == 200, code)
check('A2 anon key carries role anon', decode(ANON).get('role') == 'anon',
      decode(ANON).get('role'))
check('A3 service key carries role service_role',
      decode(SERVICE).get('role') == 'service_role', decode(SERVICE).get('role'))
code, body = call('GET', '/rest/v1/profiles')
denied('A4 request without apikey rejected', code, body)
code, body = call('GET', '/rest/v1/profiles', key=ANON, token='not-a-jwt')
denied('A5 malformed bearer token rejected', code, body, (401,), ('PGRST301',))
code, body = call('POST', '/auth/v1/signup', key=ANON,
                  body={'email': '%s_intruder@example.com' % TAG, 'password': PASSWORD})
denied('A6 public signup rejected', code, body, (422,), ('signup_disabled',))
code, body = call('POST', '/auth/v1/admin/users', key=ANON, token=ANON,
                  body={'email': '%s_intruder@example.com' % TAG,
                        'password': PASSWORD, 'email_confirm': True})
denied('A7 anon cannot create Auth users', code, body, (403,), ('not_admin',))

# --- B. anonymous table exposure -------------------------------------------
for table in ('profiles', 'inquiries', 'contacts', 'reservations', 'sale_reviews',
              'confirmed_sales', 'inquiry_status_history', 'vehicle_view_events',
              'vehicle_view_dedup', 'inquiry_assignment_history',
              'vehicle_inquiry_participants', 'vehicle_inquiry_rotation'):
    code, body = call('GET', '/rest/v1/%s?limit=1' % table, key=ANON)
    denied('B anon cannot read %s' % table, code, body)

code, body = call('GET', '/rest/v1/vehicles?select=id,publication_status,deleted_at', key=ANON)
rows = body if isinstance(body, list) else []
check('B anon reads only published, undeleted vehicles',
      code == 200 and V_PUB in [r['id'] for r in rows] and V_DRAFT not in [r['id'] for r in rows]
      and V_DELETED not in [r['id'] for r in rows]
      and all(r['publication_status'] == 'published' and r['deleted_at'] is None for r in rows),
      '%s %s' % (code, str(body)[:140]))

# --- C. anonymous RPC exposure ---------------------------------------------
ANON_RPCS = [
    ('get_reporting_summary', {'p_kind': 'month', 'p_start': START}),
    ('get_my_reporting_summary', {'p_kind': 'month', 'p_start': START}),
    ('record_vehicle_view', {'p_vehicle_id': V_PUB, 'p_browser_token': str(uuid.uuid4())}),
    ('submit_inquiry', {'p_submission_id': str(uuid.uuid4()), 'p_vehicle_id': V_PUB,
                        'p_phone': PHONE_A, 'p_name': 'Anon Probe',
                        'p_email': 'anon@example.com'}),
    ('reporting_period', {'p_kind': 'month', 'p_start': START}),
    ('create_manual_inquiry', {'p_phone': PHONE_B, 'p_name': 'Anon Probe',
                               'p_email': 'anon@example.com', 'p_vehicle_id': V_PUB,
                               'p_origin': 'in_person'}),
    ('add_inquiry_interest', {'p_inquiry_id': str(uuid.uuid4()), 'p_vehicle_id': V_PUB}),
    ('update_contact_details', {'p_contact_id': str(uuid.uuid4()), 'p_expected_revision': 1,
                                'p_name': 'Anon Probe', 'p_email': 'anon@example.com'}),
    ('update_contact_phone', {'p_contact_id': str(uuid.uuid4()), 'p_expected_revision': 1,
                              'p_phone': PHONE_B}),
    ('reserve_inquiry_vehicle', {'p_inquiry_id': str(uuid.uuid4()), 'p_vehicle_id': V_PUB}),
    ('cancel_reservation', {'p_reservation_id': str(uuid.uuid4())}),
    ('set_vehicle_sale_blocked', {'p_vehicle_id': V_PUB, 'p_blocked': True}),
    ('report_inquiry_sale', {'p_inquiry_id': str(uuid.uuid4()), 'p_vehicle_id': V_PUB}),
    ('resolve_sale_review', {'p_review_id': str(uuid.uuid4()), 'p_confirm': True}),
    ('reopen_inquiry', {'p_inquiry_id': str(uuid.uuid4())}),
]
for name, payload in ANON_RPCS:
    code, body = rpc(name, None, payload)
    denied('C anon cannot execute %s' % name, code, body)

check('C anon denials changed no data', state_hash() == SNAP0, state_hash())

# --- D. real public submission path (service role only) ---------------------
SUBMISSION = str(uuid.uuid4())
code, body = rpc('submit_inquiry', SERVICE, {
    'p_submission_id': SUBMISSION, 'p_vehicle_id': V_PUB, 'p_phone': PHONE_A,
    'p_name': 'Auth Probe', 'p_email': 'authprobe@example.com'}, key=SERVICE)
check('D service role submits a web inquiry', 200 <= code < 300, '%s %s' % (code, str(body)[:160]))
row = sql("select id::text||'|'||coalesce(assignee_id::text,'none') from public.inquiries "
          "where submission_id = '%s';" % SUBMISSION)
inquiry_id, assignee = (row.split('|') + [''])[:2] if row else ('', '')
check('D web inquiry stored once and assigned to staff',
      bool(row) and assignee in (users['seller1'], users['seller2']), row)
# Re-anchor on the stored inquiry's own local date: the figure checks below assert
# that this inquiry falls inside the requested month, so its month must hold by
# construction instead of depending on the wall clock while the runner executes.
START = sql("select to_char(created_at at time zone 'America/Argentina/Buenos_Aires', "
            "'YYYY-MM-DD') from public.inquiries where submission_id = '%s';" % SUBMISSION)
code, body = rpc('submit_inquiry', SERVICE, {
    'p_submission_id': SUBMISSION, 'p_vehicle_id': V_PUB, 'p_phone': PHONE_A,
    'p_name': 'Auth Probe', 'p_email': 'authprobe@example.com'}, key=SERVICE)
count = sql("select count(*) from public.inquiries where submission_id = '%s';" % SUBMISSION)
check('D repeated submission is idempotent over HTTP', 200 <= code < 300 and count == '1',
      '%s / rows=%s' % (code, count))
SNAP1 = state_hash()
assignee_role = 'seller1' if assignee == users['seller1'] else 'seller2'

# --- E. seller and non-staff enforcement with real JWTs ---------------------
for role in ('seller1', 'seller2'):
    token = tokens[role]
    code, body = call('GET', '/rest/v1/profiles?select=id,display_name,role,is_active',
                      key=ANON, token=token)
    check('E %s reads only its own profile' % role,
          code == 200 and [r['id'] for r in body] == [users[role]], str(body)[:140])
    code, body = call('GET', '/rest/v1/inquiries?select=id,assignee_id', key=ANON, token=token)
    ids = [r['id'] for r in body] if isinstance(body, list) else []
    isolated = isinstance(body, list) and all(r['assignee_id'] == users[role] for r in body)
    owns_own = (inquiry_id in ids) if role == assignee_role else (inquiry_id not in ids)
    check('E %s reads only its assigned inquiries' % role,
          code == 200 and isolated and owns_own, str(body)[:140])
    code, body = call('GET', '/rest/v1/vehicles?select=id,publication_status', key=ANON, token=token)
    ids = [r['id'] for r in body] if isinstance(body, list) else []
    check('E %s sees every inventory row including drafts' % role,
          code == 200 and V_PUB in ids and V_DRAFT in ids and V_DELETED in ids, str(body)[:140])
    code, body = call('GET', '/rest/v1/vehicle_inquiry_participants?vehicle_id=eq.%s' % V_PUB,
                      key=ANON, token=token)
    check('E %s cannot read rotation participants' % role, code == 200 and body == [],
          '%s %s' % (code, str(body)[:120]))
    code, body = call('GET', '/rest/v1/inquiry_assignment_history?inquiry_id=in.(%s)' % inquiry_id,
                      key=ANON, token=token)
    check('E %s cannot read assignment history' % role, code == 200 and body == [],
          '%s %s' % (code, str(body)[:120]))
    code, body = call('GET', '/rest/v1/vehicle_view_events?limit=1', key=ANON, token=token)
    denied('E %s cannot read view events' % role, code, body)
    code, body = rpc('get_reporting_summary', token,
                     {'p_kind': 'month', 'p_start': START})
    denied('E %s denied administrative summary' % role, code, body)
    code, body = rpc('record_vehicle_view', token,
                     {'p_vehicle_id': V_PUB, 'p_browser_token': str(uuid.uuid4())})
    denied('E %s cannot record a vehicle view' % role, code, body)
    code, body = rpc('get_my_reporting_summary', token,
                     {'p_kind': 'month', 'p_start': START})
    expected = 1 if role == assignee_role else 0
    keys_ok = isinstance(body, dict) and set(body) == {'period', 'figures', 'by_origin', 'scope'}
    figure_ok = keys_ok and body['figures'].get('inquiries_first_assigned') == expected
    scope_ok = keys_ok and body['scope'].get('subject') == 'self'
    check('E %s own summary has only own keys and own figures' % role,
          code == 200 and keys_ok and figure_ok and scope_ok,
          '%s %s' % (code, str(body)[:160]), full=body)
    code, body = call('PATCH', '/rest/v1/profiles?id=eq.%s' % users[role], key=ANON,
                      token=token, body={'display_name': 'hijacked'},
                      extra={'Prefer': 'return=representation'})
    kept = sql("select display_name from public.profiles where id = '%s';" % users[role])
    check('E %s cannot rewrite its own profile row' % role,
          ((code == 200 and body == []) or error_matches(code, body)) and kept == '%s_%s' % (TAG, role),
          '%s / display_name=%s' % (code, kept))
    code, body = call('POST', '/rest/v1/profiles', key=ANON, token=token,
                      body={'id': str(uuid.uuid4()), 'display_name': 'intruder',
                            'role': 'owner', 'is_active': True})
    denied('E %s cannot insert a profile' % role, code, body)
    code, body = call('DELETE', '/rest/v1/profiles?id=eq.%s' % users[role], key=ANON, token=token)
    gone = sql("select count(*) from public.profiles where id = '%s';" % users[role])
    check('E %s cannot delete its own profile' % role, error_matches(code, body) and gone == '1',
          '%s / rows=%s' % (code, gone))
    code, body = call('POST', '/rest/v1/vehicles', key=ANON, token=token,
                      body={'id': V_ATTEMPT, 'brand': 'Intruder', 'model': 'Probe',
                            'year': 2020})
    denied('E %s cannot insert inventory' % role, code, body)
    code, body = call('PATCH', '/rest/v1/vehicles?id=eq.%s' % V_DRAFT, key=ANON, token=token,
                      body={'year': 1999}, extra={'Prefer': 'return=representation'})
    year = sql("select year::text from public.vehicles where id = '%s';" % V_DRAFT)
    check('E %s cannot rewrite inventory rows' % role,
          ((code == 200 and body == []) or error_matches(code, body)) and year == '2024',
          '%s / year=%s' % (code, year))

code, body = rpc('get_my_reporting_summary', tokens['ghost'],
                 {'p_kind': 'month', 'p_start': START})
denied('E identity without profile denied own summary', code, body)
code, body = rpc('get_reporting_summary', tokens['ghost'],
                 {'p_kind': 'month', 'p_start': START})
denied('E identity without profile denied admin summary', code, body)
code, body = call('GET', '/rest/v1/profiles', key=ANON, token=tokens['ghost'])
check('E identity without profile reads no profiles', code == 200 and body == [],
      '%s %s' % (code, str(body)[:120]))
code, body = call('GET', '/rest/v1/vehicles?select=id,publication_status',
                  key=ANON, token=tokens['ghost'])
ids = [r['id'] for r in body] if isinstance(body, list) else []
check('E identity without profile sees only published vehicles',
      code == 200 and V_PUB in ids and V_DRAFT not in ids and V_DELETED not in ids,
      str(body)[:140])
code, body = call('POST', '/rest/v1/vehicles', key=ANON, token=tokens['ghost'],
                  body={'id': V_ATTEMPT, 'brand': 'Ghost', 'model': 'Probe', 'year': 2020})
denied('E identity without profile cannot insert inventory', code, body)

code, body = rpc('get_my_reporting_summary', tokens['inactive'],
                 {'p_kind': 'month', 'p_start': START})
denied('E inactive staff denied own summary', code, body)
code, body = rpc('get_reporting_summary', tokens['inactive'],
                 {'p_kind': 'month', 'p_start': START})
denied('E inactive staff denied admin summary', code, body)
code, body = call('GET', '/rest/v1/vehicles?select=id,publication_status',
                  key=ANON, token=tokens['inactive'])
ids = [r['id'] for r in body] if isinstance(body, list) else []
check('E inactive staff sees only published vehicles',
      code == 200 and V_PUB in ids and V_DRAFT not in ids and V_DELETED not in ids,
      str(body)[:140])
code, body = call('GET', '/rest/v1/profiles?select=id,is_active',
                  key=ANON, token=tokens['inactive'])
check('E inactive staff still reads its own profile row',
      code == 200 and [r['id'] for r in body] == [users['inactive']], str(body)[:140])

check('E denied identities changed no data', state_hash() == SNAP1, state_hash())

# --- F. owner/admin enforcement --------------------------------------------
token = tokens['owner']
code, body = call('GET', '/rest/v1/profiles?select=id,role', key=ANON, token=token)
ids = [r['id'] for r in body] if isinstance(body, list) else []
check('F owner reads every profile row',
      code == 200 and set(users.values()) - {users['ghost']} <= set(ids), str(body)[:140])
code, body = call('GET', '/rest/v1/vehicle_inquiry_participants?vehicle_id=eq.%s' % V_PUB,
                  key=ANON, token=token)
check('F owner reads rotation participants',
      code == 200 and isinstance(body, list) and len(body) == 2, '%s %s' % (code, str(body)[:140]))
code, body = call('GET', '/rest/v1/inquiry_assignment_history?inquiry_id=in.(%s)' % inquiry_id,
                  key=ANON, token=token)
check('F owner reads assignment history', code == 200 and isinstance(body, list) and len(body) >= 1,
      '%s %s' % (code, str(body)[:140]))
code, body = rpc('get_reporting_summary', token, {'p_kind': 'month', 'p_start': START})
required = {'period', 'totals', 'by_origin', 'by_vehicle', 'by_staff',
            'inquiry_history_coverage'}
raw_body = body if isinstance(body, str) else json.dumps(body)
check('F owner administrative summary returns its documented sections',
      code == 200 and required <= set(body), '%s %s' % (code, str(body)[:160]))
check('F owner summary attributes the first assignment to its responsible person',
      code == 200 and assignee in raw_body, 'assignee present: %s' % (assignee in raw_body),
      full=body)
check('F owner summary labels web relations as relation, not causality',
      code == 200 and 'relation_not_causality' in raw_body,
      'label present: %s' % ('relation_not_causality' in raw_body))
code, body = rpc('get_my_reporting_summary', token, {'p_kind': 'month', 'p_start': START})
check('F owner own summary keeps the restricted key set',
      code == 200 and isinstance(body, dict) and set(body) == {'period', 'figures', 'by_origin', 'scope'}
      and body['scope'].get('subject') == 'self',
      '%s %s' % (code, str(body)[:160]))
code, body = call('POST', '/rest/v1/vehicles', key=ANON, token=token,
                  body={'id': V_OWNER, 'brand': 'Probe', 'model': 'AuthOwner',
                        'year': 2024, 'publication_status': 'published'},
                  extra={'Prefer': 'return=representation'})
stored = sql("select publication_status from public.vehicles where id = '%s';" % V_OWNER)
check('F owner inserts inventory through the API', 200 <= code < 300 and stored == 'published',
      '%s / stored=%s' % (code, stored))
code, body = rpc('create_manual_inquiry', token, {'p_phone': PHONE_B, 'p_name': 'Owner Probe',
                                                  'p_email': 'ownerprobe@example.com',
                                                  'p_vehicle_id': V_PUB, 'p_origin': 'in_person'})
manual = sql("select count(*) from public.inquiries where submitted_phone = '%s';" % PHONE_B)
check('F owner creates a manual inquiry through the API',
      200 <= code < 300 and manual == '1', '%s / rows=%s' % (code, manual))
SNAP2 = state_hash()

# --- G. service role boundary ----------------------------------------------
code, body = rpc('record_vehicle_view', SERVICE,
                 {'p_vehicle_id': V_PUB, 'p_browser_token': str(uuid.uuid4())}, key=SERVICE)
check('G service role records a public vehicle view', code == 200 and body is True,
      '%s %s' % (code, str(body)[:120]))
token_browser = str(uuid.uuid4())
code, body = rpc('record_vehicle_view', SERVICE,
                 {'p_vehicle_id': V_PUB, 'p_browser_token': token_browser}, key=SERVICE)
second = rpc('record_vehicle_view', SERVICE,
             {'p_vehicle_id': V_PUB, 'p_browser_token': token_browser}, key=SERVICE)
check('G repeated view from the same browser token is deduplicated',
      code == 200 and body is True and second == (200, False),
      '%s %s / repeat %s %s' % (code, str(body)[:40], second[0], str(second[1])[:40]))
SNAP2 = state_hash()  # Successful view writes precede the rejected-call baseline.
for table in ('vehicle_view_events', 'vehicle_view_dedup', 'profiles'):
    code, body = call('GET', '/rest/v1/%s?limit=1' % table, key=SERVICE, token=SERVICE)
    denied('G service role cannot read %s directly' % table, code, body)
for name, payload in (('get_reporting_summary',
                       {'p_kind': 'month', 'p_start': START}),
                      ('get_my_reporting_summary',
                       {'p_kind': 'month', 'p_start': START})):
    code, body = rpc(name, SERVICE, payload, key=SERVICE)
    denied('G service role cannot execute %s' % name, code, body)
code, body = call('POST', '/rest/v1/vehicles', key=SERVICE, token=SERVICE,
                  body={'brand': 'Service', 'model': 'Probe', 'year': 2024})
denied('G service role has no inventory insert grant', code, body)
check('G denied service-role calls changed no data', state_hash() == SNAP2, state_hash())

from http_visit_cases import run_visit_probes
run_visit_probes(globals())

# Parent context removes this entire owned stack even after an exception.

# --- summary ----------------------------------------------------------------
print('\n%d checks, %d failures' % (len(RESULTS), len(FAILURES)))
for failure in FAILURES:
    print('  FAIL %s' % failure)
for note in RETAINED:
    print('  NOTE %s' % note)
if FAILURES:
    sys.exit(1)
print('Auth/PostgREST/JWT verification passed.')
