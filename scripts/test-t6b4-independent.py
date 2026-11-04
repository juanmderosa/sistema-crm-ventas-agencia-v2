"""Probe the administrative reader in NEW disposable DBs; never drops resources.

Usage: python scripts/test-t6b4-independent.py t6b4verify_BASE t6b4verify_CAND BASELINE_MIGRATIONS
Requires local Docker. Baseline files supplied by caller; never reads Git.
"""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

if len(sys.argv) != 4 or sys.argv[1] == sys.argv[2] or not all(
        re.fullmatch(r't6b4verify_[a-z0-9_]+', name) for name in sys.argv[1:3]):
    raise SystemExit(__doc__)
B, C = sys.argv[1:3]
ROOT = pathlib.Path(tempfile.mkdtemp(prefix='t6b4-probes_', dir=pathlib.Path(
    os.environ['LOCALAPPDATA']) / 'Temp/opencode'))
print('Owned scratch:', ROOT, flush=True)
os.environ['HOME'] = os.environ['TMPDIR'] = str(ROOT)
# Freeze caller-provided baseline and current migrations before database setup.
for name, source in [('baseline', pathlib.Path(sys.argv[3])),
                     ('candidate', pathlib.Path(__file__).resolve().parents[1] / 'supabase/migrations')]:
    destination = ROOT / name
    destination.mkdir()
    files = sorted(source.glob('*.sql'))
    assert files, source
    for file in files:
        (destination / file.name).write_bytes(file.read_bytes())
PSQL = ['docker', 'exec', '-i', 'supabase_db_dealership-mvp', 'psql', '-X', '-At',
        '-U', 'postgres', '-v', 'ON_ERROR_STOP=1']
LOG = []


def run(sql, db=C, code=0):
    result = subprocess.run(PSQL + [db], input=sql, text=True, encoding='utf-8',
                            capture_output=True, timeout=30)
    LOG.append(dict(db=db, sql=sql, code=result.returncode, out=result.stdout, err=result.stderr))
    (ROOT / 'evidence.json').write_text(json.dumps(LOG, indent=2), encoding='utf-8')
    assert result.returncode == code, LOG[-1]
    return result.stdout.strip()


def uid(n):
    return "md5('reportverify" + str(n) + "')::uuid"


def auth(n=1, role='authenticated'):
    return 'set role ' + role + ";set request.jwt.claim.sub='" + run('select ' + uid(n)) + "';"


def snapshot():
    tables = run("select tablename from pg_tables where schemaname='public' order by tablename").splitlines()
    return run('select md5(' + '||'.join(
        "coalesce((select string_agg(j::text,'' order by j::text) from(select to_jsonb(t) j from public." +
        table + " t)s),'')" for table in tables) + ')')


def rpc(n=1, kind='custom', start='2026-01-01', end='2026-01-31', prefix=''):
    before = snapshot()
    output = run(auth(n) + prefix + "select public.get_reporting_summary('" + kind + "','" +
                 start + "'," + ('null' if end is None else "'" + end + "'") + ');')
    assert snapshot() == before
    return json.loads(output.splitlines()[-1])


def call(sql, n=3):
    output = run(auth(n) + sql).splitlines()[-1]
    return json.loads(output)['review_id'] if output.startswith('{') and 'review_id' in output else output


for db, folder in [(B, 'baseline'), (C, 'candidate')]:
    run('create database ' + db, 'postgres')
    print('Owned DB:', db, flush=True)
    run("create schema auth;create table auth.users(id uuid primary key,email text);"
        "create function auth.uid() returns uuid language sql stable as $$select "
        "nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;"
        'grant usage on schema public,auth to anon,authenticated,service_role;', db)
    for migration in sorted((ROOT / folder).glob('*.sql')):
        run(migration.read_text(encoding='utf-8-sig'), db)
    for n, role, active in [(1, 'owner', True), (2, 'admin', True), (3, 'seller', True),
                            (4, 'owner', False), (5, 'admin', False), (6, 'seller', False)]:
        run('insert into auth.users values(' + uid(n) + ',null);'
            'insert into public.profiles(id,role,display_name,is_active) values(' +
            uid(n) + ",'" + role + "','Verifier'," + str(active) + ');', db)

# The only allowed function/ACL addition is the administrative reader.
queries = [
    "select p.oid::regprocedure::text,pg_get_functiondef(p.oid),p.proacl::text from pg_proc p "
    "join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f' "
    "and p.proname<>'get_reporting_summary' order by 1",
    "select schemaname,tablename,policyname,roles::text,cmd,qual,with_check from pg_policies "
    "where schemaname='public' order by tablename,policyname",
    "select table_name,grantee,privilege_type from information_schema.role_table_grants "
    "where table_schema='public' order by 1,2,3",
]
for query in queries:
    assert run(query, B) == run(query, C)
for sql, code in [("set role anon;select id,brand,model from public.vehicles order by id;", 0),
                  ("set role authenticated;select public.create_manual_inquiry(null,null,null,null,'phone');", 3)]:
    start_index = len(LOG)
    run(sql, B, code)
    run(sql, C, code)
    baseline, candidate = [(row['code'], row['out'], row['err']) for row in LOG[start_index:]]
    assert baseline == candidate
assert run("select prosecdef and provolatile='s' and array_to_string(proconfig,',') like '%TimeZone=UTC%' "
           "from pg_proc where oid='public.get_reporting_summary(text,date,date)'::regprocedure") == 't'
for n, role in [(3, 'authenticated'), (4, 'authenticated'), (5, 'authenticated'),
                (6, 'authenticated'), (7, 'authenticated'), (1, 'anon'), (1, 'service_role')]:
    for args in ["'custom','2026-01-01','2026-01-31'", "'invalid',null,null"]:
        before = snapshot()
        run(auth(n, role) + 'select public.get_reporting_summary(' + args + ');', code=3)
        expected = 'reporting access denied' if role == 'authenticated' else 'permission denied for function get_reporting_summary'
        assert expected in LOG[-1]['err'] and snapshot() == before
print('PASS authorization/hash preservation and existing definitions/ACL/policy/output differentials', flush=True)

empty = rpc()
assert empty == rpc(2) and all(value == 0 for value in empty['totals'].values())
assert empty['by_staff'] == empty['by_vehicle'] == [] and empty['web_relation']['value'] is None
for kind in ['month', 'quarter', 'semester', 'year']:
    rpc(kind=kind, end=None)
run('insert into public.vehicles(id,brand,model,year,publication_status) values(' +
    uid(10) + ",'Verifier','Fixture',2024,'published');")
for n, origin, vehicle in [(20, 'phone', 'null'), (21, 'in_person', uid(10))]:
    run(auth(3) + "select public.create_manual_inquiry('+549117654" + str(n) +
        "','PRIVATE_SENTINEL',null," + vehicle + ",'" + origin + "');")
run('set role service_role;select public.submit_inquiry(' + uid(30) + ',' + uid(10) +
    ",'+54911765422','PRIVATE_SENTINEL','secret@example.invalid');")
run("update public.inquiries set created_at='2026-01-01 03:00:00+00';"
    "update public.inquiry_first_responsibilities set first_observed_at='2026-02-01 03:00:00+00';")
summary = rpc()
assert summary['totals']['inquiries'] == 3 and summary['web_relation']['numerator'] == 1
assert summary['web_relation']['denominator'] == 0 and summary['web_relation']['value'] is None
assert any(row['vehicle_id'] is None and row['inquiries'] == 1 for row in summary['by_vehicle'])
assert not summary['by_staff'] and summary['inquiry_history_coverage']['complete'] == 3
february = rpc(start='2026-02-01', end='2026-02-28')
assert february['totals']['inquiries'] == 0
assert sum(row['inquiries_first_assigned'] for row in february['by_staff']) == 3
run('update public.inquiry_responsibility_tracking set complete_from_creation=false;')
summary = rpc()
assert summary['totals']['inquiries'] == 3 and summary['inquiry_history_coverage']['incomplete'] == 3
assert rpc(start='2026-02-01', end='2026-02-28')['by_staff'] == []
assert summary == rpc(prefix="set timezone='Pacific/Auckland';create temp table inquiries(secret text);"
                      'create temp table vehicle_view_events(secret text);')
run("update public.inquiries set created_at='2026-02-01 03:00:00+00';")
assert rpc()['totals']['inquiries'] == 0
run("update public.inquiries set created_at='2026-02-01 02:59:59.999999+00';")
assert rpc()['totals']['inquiries'] == 3
print('PASS mixed origins/no vehicle/zero views/assignment periods/coverage/UTC/temp spoof/microsecond bounds', flush=True)

inquiry = run("select id from public.inquiries where origin='in_person'")
call("select public.reserve_inquiry_vehicle('" + inquiry + "'," + uid(10) + ');')
review = call("select public.report_inquiry_sale('" + inquiry + "'," + uid(10) + ');')
call("select public.resolve_sale_review('" + review + "',false);", 1)
call("select public.reopen_inquiry('" + inquiry + "');")
review = call("select public.report_inquiry_sale('" + inquiry + "'," + uid(10) + ');')
call("select public.resolve_sale_review('" + review + "',false);", 2)
call("select public.reopen_inquiry('" + inquiry + "');")
review = call("select public.report_inquiry_sale('" + inquiry + "'," + uid(10) + ');')
call("select public.resolve_sale_review('" + review + "',true);", 1)
run("update public.reservations set started_at='2026-01-15';update public.sale_reviews set reported_at='2026-01-15';"
    "update public.confirmed_sales set confirmed_at='2026-01-15';update public.inquiry_status_history set occurred_at='2026-01-15';")
summary = rpc()
assert summary['totals']['reservations'] == 1 and summary['totals']['sale_reports'] == 3
assert summary['totals']['confirmed_sales'] == 1 and summary['totals']['closures_without_sale'] == 2
seller = run('select ' + uid(3))
staff = next(row for row in summary['by_staff'] if row['staff_id'] == seller)
assert staff['reservations_created'] == 1 and staff['sale_reports'] == 3
assert staff['confirmed_sales'] == 1 and staff['closures_without_sale'] == 2
run('update public.inquiries set assignee_id=' + uid(2) + " where id='" + inquiry + "';"
    'update public.profiles set is_active=false where id=' + uid(3) + ';')
assert rpc()['by_staff'] == summary['by_staff']
run("delete from public.inquiry_closure_attribution where history_id=(select id from public.inquiry_status_history "
    "where to_status='closed_without_sale' order by id limit 1);"
    'update public.inquiry_closure_attribution set responsible_id=null;')
summary = rpc()
assert summary['totals']['closures_without_sale'] == 2
assert {row['attribution'] for row in summary['by_staff'] if row['staff_id'] is None} == {'unknown', 'unassigned'}
print('PASS public commercial chain, repeated closures, snapshots/deactivation and unknown/unassigned separation', flush=True)

run('insert into public.vehicle_view_events(vehicle_id,counted_at) values(' + uid(10) +
    ",'2026-01-01 03:00:00+00'),(" + uid(10) + ",'2026-02-01 02:59:59.999999+00'),(" +
    uid(10) + ",'2026-02-01 03:00:00+00');")
summary = rpc()
assert summary['totals']['views'] == 2 and summary['web_relation']['value'] == .5
assert summary['web_relation']['interpretation'] == 'relation_not_causality'
print('PASS same-period web relation and view boundaries', flush=True)

metrics = {'views', 'inquiries', 'reservations', 'sale_reports', 'confirmed_sales', 'closures_without_sale'}
relation = {'numerator', 'denominator', 'value', 'interpretation'}
schema = {
    (): {'period', 'totals', 'web_relation', 'by_origin', 'by_vehicle', 'by_staff', 'inquiry_history_coverage'},
    ('period',): {'local_start', 'local_end', 'start_at', 'end_at', 'timezone_name', 'kind'},
    ('totals',): metrics,
    ('web_relation',): relation,
    ('by_origin', '[]'): {'origin', 'inquiries', 'reservations', 'sale_reports', 'confirmed_sales', 'closures_without_sale'},
    ('by_vehicle', '[]'): {'vehicle_id', 'views', 'inquiries', 'web_inquiries', 'reservations', 'confirmed_sales', 'web_relation'},
    ('by_vehicle', '[]', 'web_relation'): relation,
    ('by_staff', '[]'): {'staff_id', 'attribution', 'inquiries_first_assigned', 'reservations_created', 'sale_reports',
                         'confirmed_sales', 'closures_without_sale'},
    ('inquiry_history_coverage',): {'basis', 'complete', 'incomplete', 'staff_first_assignment_excludes_incomplete', 'staff_counts_nonadditive'},
}
seen = set()


def strict(value, path=()):
    if isinstance(value, dict):
        assert path in schema and set(value) == schema[path], (path, value)
        seen.add(path)
        for key, child in value.items():
            strict(child, path + (key,))
    elif isinstance(value, list):
        for child in value:
            strict(child, path + ('[]',))
    else:
        assert path[:-1] in schema, (path, value)


strict(rpc())
for n in (41, 42):
    run('insert into public.vehicles(id,brand,model,year,publication_status) values(' +
        uid(n) + ",'Verifier','Extra',2024,'published');")
created = run(auth(1) + "select public.create_manual_inquiry('+54911765499','INTEREST_PRIVATE_SENTINEL',null,null,'phone');").splitlines()[-1]
new = json.loads(created)['inquiry_id']
run("update public.inquiries set created_at='2026-01-10 03:00:00+00' where id='" + new + "';"
    "update public.inquiry_first_responsibilities set first_observed_at='2026-01-10 03:00:00+00' where inquiry_id='" + new + "';")
before = rpc()
for n in (41, 42):
    run(auth(1) + "select public.add_inquiry_interest('" + new + "'," + uid(n) + ');')
assert rpc() == before
assert run("select count(*) from public.inquiry_interests where inquiry_id='" + new + "'") == '2'
first_source = run("select responsible_id,first_observed_at from public.inquiry_first_responsibilities where inquiry_id='" + new + "' order by responsible_id")
run('update public.inquiries set assignee_id=' + uid(2) + " where id='" + new + "';")
second_source = run("select responsible_id,first_observed_at from public.inquiry_first_responsibilities where inquiry_id='" + new + "' order by responsible_id")
january, year = rpc(), rpc(kind='year', end=None)
run('update public.inquiries set assignee_id=' + uid(1) + " where id='" + new + "';")
assert run("select responsible_id,first_observed_at from public.inquiry_first_responsibilities where inquiry_id='" + new + "' order by responsible_id") == second_source
assert first_source in second_source and rpc() == january and rpc(kind='year', end=None) == year
strict(rpc())
strict(rpc(kind='year', end=None))
assert seen == set(schema)
raw = json.dumps(rpc())
assert not any(value in raw for value in ['PRIVATE_SENTINEL', 'INTEREST_PRIVATE_SENTINEL',
                                        'secret@example.invalid', '+54911765499', new])
print('PASS public interests nonmultiplication, return responsibility and exact recursive schema privacy', flush=True)

invalid = [
    (1, "'invalid',null,null", '22023', 'reporting period must be month, quarter, semester, year or custom'),
    (1, "'month','infinity',null", '22023', 'a finite reporting start or anchor date is required'),
    (1, "'custom','2026-02-01','2026-01-01'", '22023', 'custom reporting end must be finite and not precede start'),
    (1, "'year','294276-12-31',null", '22023', 'reporting dates exceed supported timestamp boundaries'),
    (7, "'invalid',null,null", '42501', 'reporting access denied'),
]
for n, args, state, message in invalid:
    before = snapshot()
    run('\\set VERBOSITY verbose\n' + auth(n) + 'select public.get_reporting_summary(' + args + ');', code=3)
    assert 'ERROR:  ' + state + ': ' + message in LOG[-1]['err'], LOG[-1]
    assert snapshot() == before
print('PASS exact invalid-input SQLSTATE/messages and authorization-before-validation', flush=True)
