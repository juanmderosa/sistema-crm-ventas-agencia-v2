"""Run first-responsibility probes in NEW disposable databases; never drop them.

Usage: python scripts/test-t6b3-independent.py t6b3verify_BASE t6b3verify_CAND BASELINE_MIGRATIONS
Requires local Docker; baseline files supplied by caller. Never reads Git.
"""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

if len(sys.argv) != 4 or sys.argv[1] == sys.argv[2] or not all(
        re.fullmatch(r't6b3verify_[A-Za-z0-9_]+', name) for name in sys.argv[1:3]):
    raise SystemExit(__doc__)
B, C = sys.argv[1:3]
BASE = pathlib.Path(sys.argv[3])
CANDIDATE = pathlib.Path(__file__).resolve().parents[1] / 'supabase/migrations'
if not list(BASE.glob('*.sql')):
    raise SystemExit('Baseline directory must contain migration SQL')
ROOT = pathlib.Path(tempfile.mkdtemp(prefix='t6b3-probes_', dir=pathlib.Path(
    os.environ['LOCALAPPDATA']) / 'Temp/opencode'))
os.environ['HOME'] = os.environ['TMPDIR'] = str(ROOT)
print('Owned scratch:', ROOT, flush=True)
PSQL = ['docker', 'exec', '-i', 'supabase_db_dealership-mvp', 'psql', '-X', '-At',
        '-U', 'postgres', '-v', 'ON_ERROR_STOP=1']
LOG = []
PROCESSES = []


def run(sql, db=C, code=0):
    result = subprocess.run(PSQL + [db], input=sql, text=True, encoding='utf-8',
                            capture_output=True, timeout=25)
    observed = result.returncode, result.stdout, result.stderr
    LOG.append(dict(db=db, sql=sql, code=observed[0], out=observed[1], err=observed[2]))
    (ROOT / 'evidence.json').write_text(json.dumps(LOG, indent=2), encoding='utf-8')
    assert result.returncode == code, LOG[-1]
    return observed


def val(sql, db=C):
    return run(sql, db)[1].strip()


def uid(n):
    return "md5('missing" + str(n) + "')::uuid"


def actor(n=3):
    return "set role authenticated;select set_config('request.jwt.claim.sub'," + uid(n) + '::text,false);'


def check(sql):
    assert val(sql) == 't', sql


def snapshot():
    tables = val("select tablename from pg_tables where schemaname='public' order by tablename").splitlines()
    return val('select md5(' + '||'.join(
        "coalesce((select string_agg(j::text,'' order by j::text) from(select to_jsonb(t) j from public." +
        table + " t)s),'')" for table in tables) + ')')


def manual(n):
    return actor() + "select public.create_manual_inquiry('+5491180000" + str(n) + \
        "','Verifier',null," + uid(10) + ",'phone');"


def web(n):
    return 'set role service_role;select public.submit_inquiry(' + uid(100 + n) + ',' + uid(10) + \
        ",'+5491190000" + str(n) + "','Web','web@example.invalid');"


def diff(sql, code=0):
    baseline = run(sql, B, code)
    candidate = run(sql, C, code)
    assert baseline == candidate, (baseline, candidate)


def start(name, sql):
    process = subprocess.Popen(PSQL + [C], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, encoding='utf-8')
    PROCESSES.append(process)
    process.stdin.write("set application_name='" + name + "';set statement_timeout='12s';begin;" + sql + '\n')
    process.stdin.flush()
    return process


def wait(name, predicate):
    for _ in range(150):
        if val("select count(*) from pg_stat_activity where datname=current_database() and application_name='" +
               name + "' and " + predicate) == '1':
            LOG.append(dict(barrier=name, predicate=predicate))
            return
        time.sleep(.04)
    raise AssertionError('Missing Lock/transaction barrier: ' + name)


def finish(process, decision='commit'):
    process.stdin.write(decision + ';\n')
    process.stdin.close()
    process.stdin = None
    out, err = process.communicate(timeout=15)
    LOG.append(dict(race_code=process.returncode, out=out, err=err))
    assert process.returncode == 0, (out, err)


try:
    for db in [B, C]:
        run('create database ' + db, 'postgres')
        print('Owned DB:', db, flush=True)
        run("create schema auth;create table auth.users(id uuid primary key,email text);"
            "create function auth.uid() returns uuid language sql stable as $$select "
            "nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;"
            'grant usage on schema public,auth to anon,authenticated,service_role;', db)
        for migration in sorted(BASE.glob('*.sql')):
            run(migration.read_text(encoding='utf-8'), db)
        for n, role, active in [(1, 'owner', True), (2, 'admin', True), (3, 'seller', True),
                                (4, 'seller', True), (5, 'owner', False),
                                (6, 'admin', False), (7, 'seller', False)]:
            run('insert into auth.users(id) values(' + uid(n) + ');'
                'insert into public.profiles(id,role,display_name,is_active) values(' +
                uid(n) + ",'" + role + "','Verifier'," + str(active) + ');', db)
        run('insert into public.vehicles(id,brand,model,year,publication_status) values(' +
            uid(10) + ",'Verifier','Test',2024,'published');", db)
        # Create legacy inquiry BEFORE enabling the candidate trigger.
        run('insert into public.contacts(id,normalized_phone,display_name) values(' +
            uid(900) + ",'+5491170000001','Legacy');"
            'insert into public.inquiries(id,submission_id,contact_id,assignee_id,submitted_phone,submitted_name) values(' +
            ','.join([uid(900), uid(901), uid(900), uid(3)]) + ",'+5491170000001','Legacy');", db)
        if db == C:
            for migration in sorted(CANDIDATE.glob('*.sql')):
                if not (BASE / migration.name).exists():
                    run(migration.read_text(encoding='utf-8'), db)
        # Matching UUID/time defaults in isolated fixtures; no output rewriting.
        for table in ['contacts', 'inquiries', 'inquiry_assignment_history', 'sale_reviews',
                      'inquiry_status_history', 'reservations']:
            columns = val("select column_name from information_schema.columns where table_schema='public' "
                          "and table_name='" + table + "' and column_name in ('id','created_at','updated_at')", db).splitlines()
            for column in columns:
                default = "current_setting('probe.id')::uuid" if column == 'id' else "'2026-11-04T12:00:00Z'::timestamptz"
                run('alter table public.' + table + ' alter column ' + column + ' set default ' + default, db)
    check('select count(*)=0 from public.inquiry_responsibility_tracking')
    run('update public.inquiries set assignee_id=' + uid(2) + ' where id=' + uid(900))
    check('select not complete_from_creation from public.inquiry_responsibility_tracking where inquiry_id=' + uid(900))
    print('PASS no legacy backfill; observed legacy assignment remains incomplete', flush=True)

    identities = [('anon', 0), ('service_role', 0)] + [('authenticated', n) for n in range(1, 9)]
    for role, n in identities:
        prefix = 'set role ' + role + ";set request.jwt.claim.sub='" + val('select ' + uid(n)) + "';"
        operations = ['select public.capture_inquiry_responsibility()']
        for table in ['inquiry_responsibility_tracking', 'inquiry_first_responsibilities']:
            operations += ['select * from public.' + table, 'insert into public.' + table + '(inquiry_id) values(' + uid(900) + ')',
                           'update public.' + table + ' set inquiry_id=inquiry_id',
                           'delete from public.' + table, 'truncate public.' + table]
        for operation in operations:
            before = snapshot()
            observed = run(prefix + operation, code=3)
            assert 'permission denied' in observed[2] and snapshot() == before
    print('PASS 110 real role denials with unchanged public state', flush=True)

    for n, sql in [(201, manual(11)), (202, web(12)), (202, web(12))]:
        diff("set probe.id='" + val('select ' + uid(n)) + "';" + sql)
    check('select count(*)=2 from public.inquiry_responsibility_tracking where complete_from_creation')
    check('select count(*)=2 from public.inquiry_first_responsibilities where inquiry_id in (' + uid(201) + ',' + uid(202) + ')')
    for n, sql in [(203, actor() + 'select public.report_inquiry_sale(' + uid(201) + ',' + uid(10) + ');'),
                   (204, actor(2) + 'select public.resolve_sale_review(' + uid(203) + ',false);'),
                   (205, actor() + 'select public.reopen_inquiry(' + uid(201) + ');')]:
        diff("set probe.id='" + val('select ' + uid(n)) + "';" + sql)
    diff(actor(4) + 'update public.inquiries set assignee_id=' + uid(4) + ' where id=' + uid(201), 3)
    print('PASS exact public creation/retry/report/reject/reopen/denied-update differentials', flush=True)

    run("create function public.probe_failure() returns trigger language plpgsql as $$begin "
        "raise exception 'probe failure';end$$;create trigger probe_failure before insert "
        'on public.inquiry_first_responsibilities for each row execute function public.probe_failure();')
    for n, sql in [(210, manual(21)), (211, web(22))]:
        before = snapshot()
        observed = run("set probe.id='" + val('select ' + uid(n)) + "';" + sql, code=3)
        assert 'probe failure' in observed[2] and snapshot() == before
    run('drop trigger probe_failure on public.inquiry_first_responsibilities;drop function public.probe_failure()')
    print('PASS public creation failure rolls back contacts/rotation/history/observations', flush=True)
    before = val('select jsonb_agg(to_jsonb(t) order by inquiry_id,responsible_id) from public.inquiry_first_responsibilities t')
    run('update public.profiles set is_active=false where id=' + uid(4))
    assert before == val('select jsonb_agg(to_jsonb(t) order by inquiry_id,responsible_id) from public.inquiry_first_responsibilities t')
    run('update public.profiles set is_active=true where id=' + uid(4))
    for db in [B, C]:
        run("set probe.id='" + val('select ' + uid(220)) + "';" + actor() +
            'select public.reserve_inquiry_vehicle(' + uid(201) + ',' + uid(10) + ');', db)
    for state in ['reserved', 'pending']:
        before = snapshot()
        diff('set role service_role;update public.inquiries set assignee_id=' + uid(4) + ' where id=' + uid(201), 3)
        assert snapshot() == before
        if state == 'reserved':
            for db in [B, C]:
                run("set probe.id='" + val('select ' + uid(221)) + "';" + actor() +
                    'select public.report_inquiry_sale(' + uid(201) + ',' + uid(10) + ');', db)
                run(actor() + 'select public.cancel_reservation(' + uid(220) + ');', db)
    print('PASS deactivation and distinct reservation/pending-review guard preservation', flush=True)

    run('update public.inquiries set assignee_id=' + uid(3) + ' where id=' + uid(202))
    first = val('select first_observed_at from public.inquiry_first_responsibilities where inquiry_id=' + uid(202) + ' and responsible_id=' + uid(3))
    races = [('assignee_id=' + uid(4), 'assignee_id=' + uid(3)),
             ("status='contacted'", 'assignee_id=' + uid(4)),
             ('assignee_id=' + uid(3), "status='following_up'")]
    for first_update, second_update in races:
        holder = start('responsibility_holder', 'update public.inquiries set ' + first_update + ' where id=' + uid(202) + ';')
        wait('responsibility_holder', "state='idle in transaction'")
        waiter = start('responsibility_waiter', 'update public.inquiries set ' + second_update + ' where id=' + uid(202) + ';')
        wait('responsibility_waiter', "wait_event_type='Lock'")
        finish(holder)
        wait('responsibility_waiter', "state='idle in transaction'")
        finish(waiter)
    assert first == val('select first_observed_at from public.inquiry_first_responsibilities where inquiry_id=' + uid(202) + ' and responsible_id=' + uid(3))
    check('select count(*)=2 from public.inquiry_first_responsibilities where inquiry_id=' + uid(202))
    print('PASS three actual assignment/status Lock races; first timestamp preserved', flush=True)

    # New responsibility on legacy inquiry: test honest post-wait observation,
    # without claiming this timestamp is its historical first assignment.
    for responsible, decision in [(1, 'commit'), (4, 'rollback')]:
        holder = start('responsibility_holder', 'select id from public.inquiries where id=' + uid(900) + ' for update;')
        wait('responsibility_holder', "state='idle in transaction'")
        waiter = start('responsibility_waiter', 'update public.inquiries set assignee_id=' + uid(responsible) + ' where id=' + uid(900) + ';')
        wait('responsibility_waiter', "wait_event_type='Lock'")
        began = val("select xact_start from pg_stat_activity where datname=current_database() and application_name='responsibility_waiter'")
        release = val('select clock_timestamp()')
        check("select '" + release + "'::timestamptz > '" + began + "'::timestamptz")
        finish(holder, decision)
        wait('responsibility_waiter', "state='idle in transaction'")
        finish(waiter)
        check("select first_observed_at > '" + release + "'::timestamptz and first_observed_at > '" +
              began + "'::timestamptz from public.inquiry_first_responsibilities where inquiry_id=" +
              uid(900) + ' and responsible_id=' + uid(responsible))
    print('PASS commit/rollback holder progress and clock after verified pre-release boundary', flush=True)
finally:
    for process in PROCESSES:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
    (ROOT / 'evidence.json').write_text(json.dumps(LOG, indent=2), encoding='utf-8')
