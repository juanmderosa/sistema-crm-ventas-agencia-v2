"""Probe own-only staff reporting in NEW disposable DBs; never drops resources.

Usage: python scripts/test-t6c-independent.py t6cverify_BASE t6cverify_CAND BASELINE_MIGRATIONS
Requires local Docker and caller-provided baseline migrations; never reads Git.
"""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

if len(sys.argv) != 4 or sys.argv[1] == sys.argv[2] or not all(
        re.fullmatch(r't6cverify_[a-z0-9_]+', name) for name in sys.argv[1:3]):
    raise SystemExit(__doc__)
B, C = sys.argv[1:3]
ROOT = pathlib.Path(tempfile.mkdtemp(prefix='t6c-probes_', dir=pathlib.Path(
    os.environ['LOCALAPPDATA']) / 'Temp/opencode'))
print('Owned scratch:', ROOT, flush=True)
os.environ['HOME'] = os.environ['TMPDIR'] = str(ROOT)
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
    with (ROOT / ('evidence_%05d.json' % len(LOG))).open('x', encoding='utf-8') as evidence:
        evidence.write(json.dumps(LOG[-1], indent=2))
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
    output = run(auth(n) + prefix + "select public.get_my_reporting_summary('" + kind + "','" +
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

queries = [
    "select p.oid::regprocedure::text,pg_get_functiondef(p.oid),p.proacl::text from pg_proc p "
    "join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f' "
    "and p.proname<>'get_my_reporting_summary' order by 1",
    "select tablename,policyname,roles,cmd,qual,with_check from pg_policies where schemaname='public' order by 1,2",
    "select table_name,grantee,privilege_type from information_schema.role_table_grants where table_schema='public' order by 1,2,3",
]
for query in queries:
    assert run(query, B) == run(query, C)
for sql, code in [("set role anon;select id,brand,model from public.vehicles order by id", 0),
                  ("set role authenticated;select public.create_manual_inquiry(null,null,null,null,'phone')", 3),
                  (auth(3) + "select public.get_reporting_summary('invalid',null,null)", 3)]:
    index = len(LOG)
    run(sql, B, code)
    run(sql, C, code)
    before, after = [(row['code'], row['out'], row['err']) for row in LOG[index:]]
    assert before == after
for n, role in [(4, 'authenticated'), (5, 'authenticated'), (6, 'authenticated'),
                (7, 'authenticated'), (1, 'anon'), (1, 'service_role')]:
    for args in ["'custom','2026-01-01','2026-01-31'", "'invalid',null,null"]:
        before = snapshot()
        run('\\set VERBOSITY verbose\n' + auth(n, role) + 'select public.get_my_reporting_summary(' + args + ');', code=3)
        expected = 'own reporting access denied' if role == 'authenticated' else 'permission denied for function get_my_reporting_summary'
        assert '42501' in LOG[-1]['err'] and expected in LOG[-1]['err'] and snapshot() == before
metrics = {'inquiries_first_assigned', 'reservations_created', 'sale_reports', 'confirmed_sales', 'closures_without_sale'}
schema = {
    (): {'period', 'figures', 'by_origin', 'scope'},
    ('period',): {'kind', 'local_start', 'local_end', 'start_at', 'end_at', 'timezone_name'},
    ('figures',): metrics,
    ('by_origin', '[]'): metrics | {'origin'},
    ('scope',): {'subject', 'inquiry_history'},
}


def strict(value, path=()):
    if isinstance(value, dict):
        assert set(value) == schema[path], (path, value)
        for key, child in value.items():
            strict(child, path + (key,))
    elif isinstance(value, list):
        for child in value:
            strict(child, path + ('[]',))


for n in (1, 2, 3):
    summary = rpc(n)
    strict(summary)
    assert all(value == 0 for value in summary['figures'].values())
    assert summary['scope'] == {'subject': 'self', 'inquiry_history': 'complete_from_creation_only'}
for table in ['vehicle_view_events', 'vehicle_view_dedup', 'inquiry_closure_attribution',
              'inquiry_first_responsibilities', 'inquiry_responsibility_tracking']:
    before = snapshot()
    run(auth(3) + 'select * from public.' + table, code=3)
    assert 'permission denied' in LOG[-1]['err'] and snapshot() == before
print('PASS roles/raw privacy/exact denials/hashes and baseline definitions/ACL/policies/differentials', flush=True)
run('insert into public.vehicles(id,brand,model,year,publication_status) values(' + uid(10) + ",'Verifier','Fixture',2024,'published')")
for n, origin, vehicle in [(20, 'phone', 'null'), (21, 'in_person', uid(10))]:
    run(auth(3) + "select public.create_manual_inquiry('+549117654" + str(n) +
        "','PRIVATE_SENTINEL',null," + vehicle + ",'" + origin + "')")
run('set role service_role;select public.submit_inquiry(' + uid(30) + ',' + uid(10) +
    ",'+54911765422','PRIVATE_SENTINEL','secret@example.invalid')")
run("update public.inquiries set created_at='2026-01-01 03:00+00';"
    "update public.inquiry_first_responsibilities set first_observed_at='2026-02-01 03:00+00'")
assert rpc()['figures']['inquiries_first_assigned'] == 0
assert rpc(3, start='2026-02-01', end='2026-02-28')['figures']['inquiries_first_assigned'] == 3
run('update public.inquiry_responsibility_tracking set complete_from_creation=false')
assert rpc(3, start='2026-02-01', end='2026-02-28')['figures']['inquiries_first_assigned'] == 0
inquiry = run("select id from public.inquiries where origin='in_person'")
call("select public.reserve_inquiry_vehicle('" + inquiry + "'," + uid(10) + ')')
for confirm, confirmer in [(False, 1), (False, 2), (True, 1)]:
    review = call("select public.report_inquiry_sale('" + inquiry + "'," + uid(10) + ')')
    call("select public.resolve_sale_review('" + review + "'," + str(confirm).lower() + ')', confirmer)
    if not confirm:
        call("select public.reopen_inquiry('" + inquiry + "')")
run("update public.reservations set started_at='2026-01-15';update public.sale_reviews set reported_at='2026-01-15';"
    "update public.confirmed_sales set confirmed_at='2026-01-15';update public.inquiry_status_history set occurred_at='2026-01-15'")
summary = rpc(3)
assert summary['figures'] == dict(inquiries_first_assigned=0, reservations_created=1, sale_reports=3,
                                  confirmed_sales=1, closures_without_sale=2)
strict(summary)
run('update public.inquiries set assignee_id=' + uid(2) + " where id='" + inquiry + "'")
assert rpc(3) == summary
assert run(auth(3) + "select count(*) from public.inquiries where id='" + inquiry + "'").splitlines()[-1] == '0'
assert rpc(2)['figures']['confirmed_sales'] == rpc(2)['figures']['closures_without_sale'] == 0
assert rpc(3, prefix="set timezone='Pacific/Auckland';set search_path=pg_temp,public;"
           'create temp table inquiries(secret text);create temp table sale_reviews(secret text);') == summary
run('insert into public.vehicles(id,brand,model,year,publication_status) values(' + uid(11) + ",'Other','Fixture',2024,'published')")
other = json.loads(run(auth(1) + "select public.create_manual_inquiry('+54911765498','OTHER_SENTINEL',null," +
                       uid(11) + ",'phone')").splitlines()[-1])['inquiry_id']
call("select public.reserve_inquiry_vehicle('" + other + "'," + uid(11) + ')', 1)
review = call("select public.report_inquiry_sale('" + other + "'," + uid(11) + ')', 1)
call("select public.resolve_sale_review('" + review + "',false)", 2)
run("update public.reservations set started_at='2026-01-16' where inquiry_id='" + other + "';"
    "update public.sale_reviews set reported_at='2026-01-16' where inquiry_id='" + other + "';"
    "update public.inquiry_status_history set occurred_at='2026-01-16' where inquiry_id='" + other + "';"
    "update public.inquiry_first_responsibilities set first_observed_at='2026-01-16' where inquiry_id='" + other + "';"
    'insert into public.vehicle_view_events(vehicle_id,counted_at) values(' + uid(11) + ",'2026-01-16')")
assert rpc(3) == summary
run("update public.inquiry_closure_attribution set responsible_id=null where history_id in"
    "(select id from public.inquiry_status_history where inquiry_id='" + other + "')")
assert rpc(3) == summary
run("delete from public.inquiry_closure_attribution where history_id in"
    "(select id from public.inquiry_status_history where inquiry_id='" + other + "')")
assert rpc(3) == summary
run("update public.inquiry_responsibility_tracking set complete_from_creation=true where inquiry_id='" + other + "'")
source = run("select responsible_id,first_observed_at from public.inquiry_first_responsibilities where inquiry_id='" + other + "' order by 1")
run('update public.inquiries set assignee_id=' + uid(2) + " where id='" + other + "'")
second = run("select responsible_id,first_observed_at from public.inquiry_first_responsibilities where inquiry_id='" + other + "' order by 1")
run('update public.inquiries set assignee_id=' + uid(1) + " where id='" + other + "'")
assert run("select responsible_id,first_observed_at from public.inquiry_first_responsibilities where inquiry_id='" + other + "' order by 1") == second
assert source in second and rpc(1)['figures']['inquiries_first_assigned'] == 1
run("update public.inquiry_first_responsibilities set first_observed_at='2026-02-01 03:00+00' where responsible_id=" + uid(1))
assert rpc(1)['figures']['inquiries_first_assigned'] == 0
run("update public.inquiry_first_responsibilities set first_observed_at='2026-02-01 02:59:59.999999+00' where responsible_id=" + uid(1))
assert rpc(1)['figures']['inquiries_first_assigned'] == 1
for n in (1, 2, 3):
    strict(rpc(n))
assert not any(value in json.dumps(summary) for value in ['PRIVATE_SENTINEL', inquiry, 'secret@example.invalid'])
print('PASS snapshots/repeated closures/former RLS, origins/period/history and entire-response isolation', flush=True)
for args, message in [("'invalid',null,null", 'reporting period must be month, quarter, semester, year or custom'),
                      ("'custom','2026-02-01','2026-01-01'", 'custom reporting end must be finite and not precede start')]:
    before = snapshot()
    run(auth(3) + 'select public.get_my_reporting_summary(' + args + ')', code=3)
    assert message in LOG[-1]['err'] and snapshot() == before


def figures(first=0, reservations=0, reports=0, sales=0, closures=0):
    return dict(inquiries_first_assigned=first, reservations_created=reservations,
                sale_reports=reports, confirmed_sales=sales, closures_without_sale=closures)


def origins(response, expected):
    rows = response['by_origin']
    assert len(rows) == 3
    assert {row['origin']: {key: value for key, value in row.items() if key != 'origin'} for row in rows} == expected


seller_before = rpc(3)
assert seller_before['figures'] == figures(0, 1, 3, 1, 2)
origins(seller_before, {'web': figures(), 'phone': figures(), 'in_person': figures(0, 1, 3, 1, 2)})
run('insert into public.vehicles(id,brand,model,year,publication_status) values(' + uid(90) + ",'Admin','Completion',2024,'published')")
admin_inquiry = json.loads(run(auth(2) + "select public.create_manual_inquiry('+54911765590','ADMIN_PRIVATE_SENTINEL',null," +
                               uid(90) + ",'phone')").splitlines()[-1])['inquiry_id']
call("select public.reserve_inquiry_vehicle('" + admin_inquiry + "'," + uid(90) + ')', 2)
review = call("select public.report_inquiry_sale('" + admin_inquiry + "'," + uid(90) + ')', 2)
call("select public.resolve_sale_review('" + review + "',false)", 1)
call("select public.reopen_inquiry('" + admin_inquiry + "')", 2)
review = call("select public.report_inquiry_sale('" + admin_inquiry + "'," + uid(90) + ')', 2)
call("select public.resolve_sale_review('" + review + "',true)", 1)
for table, column in [('inquiries', 'created_at'), ('inquiry_first_responsibilities', 'first_observed_at'),
                      ('reservations', 'started_at'), ('sale_reviews', 'reported_at'),
                      ('confirmed_sales', 'confirmed_at'), ('inquiry_status_history', 'occurred_at')]:
    key = 'id' if table == 'inquiries' else 'inquiry_id'
    run('update public.' + table + ' set ' + column + "='2026-01-20 03:00+00' where " + key + "='" + admin_inquiry + "'")
admin = rpc(2)
strict(admin)
assert admin['figures'] == figures(1, 1, 2, 1, 1)
origins(admin, {'web': figures(), 'in_person': figures(), 'phone': figures(1, 1, 2, 1, 1)})
assert rpc(3) == seller_before
print('PASS populated Admin and exact Admin/Seller origin numbers', flush=True)
seller_id = run('select ' + uid(3))
closures = run('select a.history_id from public.inquiry_closure_attribution a join public.inquiry_status_history h '
               "on h.id=a.history_id where a.responsible_id='" + seller_id +
               "' and h.to_status='closed_without_sale' order by a.history_id").splitlines()
assert len(closures) == 2
run("delete from public.inquiry_closure_attribution where history_id='" + closures[0] + "'")
after_absent = rpc(3)
assert after_absent['figures'] == figures(0, 1, 3, 1, 1)
origins(after_absent, {'web': figures(), 'phone': figures(), 'in_person': figures(0, 1, 3, 1, 1)})
run("update public.inquiry_closure_attribution set responsible_id=null where history_id='" + closures[1] + "'")
after_both = rpc(3)
assert after_both['figures'] == figures(0, 1, 3, 1, 0)
origins(after_both, {'web': figures(), 'phone': figures(), 'in_person': figures(0, 1, 3, 1, 0)})
assert {key: value for key, value in after_both.items() if key not in ('figures', 'by_origin')} == {
    key: value for key, value in seller_before.items() if key not in ('figures', 'by_origin')}
assert rpc(2) == admin
strict(after_both)
spoof = "set search_path=pg_temp,public;create function pg_temp.is_active_staff() returns boolean language sql as $$select false$$;" \
        "create function pg_temp.reporting_period(text,date,date) returns text language sql as $$select 'SPOOF_SENTINEL'::text$$;"
assert rpc(3, prefix=spoof) == after_both
assert rpc(2, prefix=spoof) == admin
print('PASS absent/NULL own attribution exclusion and temp-function spoof resistance', flush=True)
