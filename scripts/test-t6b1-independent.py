"""Retained closure-attribution probes; creates NEW databases, never drops them.

Usage: python scripts/test-t6b1-independent.py t6bverify_BASE t6bverify_CAND baseline_migrations
Requires local Docker and caller-provided baseline migrations; never reads Git.
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
        re.fullmatch(r't6bverify_[a-zA-Z0-9_]+', name) for name in sys.argv[1:3]):
    raise SystemExit(__doc__)
B, C = sys.argv[1:3]
M = pathlib.Path(__file__).resolve().parents[1] / 'supabase/migrations'
BASELINE = pathlib.Path(sys.argv[3])
if not list(BASELINE.glob('*.sql')):
    raise SystemExit('Baseline migration directory must contain SQL files')
R = pathlib.Path(tempfile.mkdtemp(prefix='t6b1-probes_', dir=pathlib.Path(
    os.environ['LOCALAPPDATA']) / 'Temp/opencode'))
os.environ['HOME'] = os.environ['TMPDIR'] = str(R)
print('Scratch retained for parent cleanup:', R, flush=True)
P = ['docker', 'exec', '-i', 'supabase_db_dealership-mvp', 'psql', '-X', '-At',
     '-U', 'postgres', '-v', 'ON_ERROR_STOP=1']
log = []
processes = []


def run(sql, db=C, code=0):
    result = subprocess.run(P + [db], input=sql, text=True, encoding='utf-8',
                            capture_output=True, timeout=25)
    log.append(dict(db=db, sql=sql, code=result.returncode, out=result.stdout, err=result.stderr))
    (R / 'commands.json').write_text(json.dumps(log, indent=2), encoding='utf-8')
    assert result.returncode == code, log[-1]
    return result.returncode, result.stdout, result.stderr


def val(sql, db=C):
    return run(sql, db)[1].strip()


def u(identifier):
    return "md5('bounded-" + str(identifier) + "')::uuid"


def actor(n):
    return "set role authenticated;select set_config('request.jwt.claim.sub'," + u('actor' + str(n)) + '::text,false);'


def report(n=1, rev=1):
    return "select set_config('probe.review'," + u('review' + str(n) + '-' + str(rev)) + \
        '::text,false);select public.report_inquiry_sale(' + u('inquiry' + str(n)) + ',' + u('vehicle' + str(n)) + ');'


def resolve(n=1, rev=1):
    return 'select public.resolve_sale_review(' + u('review' + str(n) + '-' + str(rev)) + ',false);'


def reopen(n=1):
    return 'select public.reopen_inquiry(' + u('inquiry' + str(n)) + ');'


def snap():
    tables = val("select tablename from pg_tables where schemaname='public' order by tablename").splitlines()
    return val('select md5(' + '||'.join(
        "coalesce((select string_agg(j::text,'' order by j::text) from(select to_jsonb(t) j from public.\"" +
        table + "\" t)s),'')" for table in tables) + ');')


def check(sql):
    assert val(sql) == 't', sql


def start(name, sql):
    text = "set application_name='" + name + "';set statement_timeout='12s';begin;" + sql + '\n'
    process = subprocess.Popen(P + [C], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, encoding='utf-8')
    processes.append(process)
    process.stdin.write(text)
    process.stdin.flush()
    return process


def wait(name, predicate):
    for _ in range(150):
        if val("select count(*) from pg_stat_activity where datname=current_database() and application_name='" +
               name + "' and " + predicate) == '1':
            log.append(dict(barrier=name, predicate=predicate))
            return
        time.sleep(.04)
    raise AssertionError('Missing barrier ' + name)


def finish(process, tail):
    process.stdin.write(tail + '\n')
    process.stdin.close()
    process.stdin = None
    out, err = process.communicate(timeout=15)
    log.append(dict(race_code=process.returncode, out=out, err=err))
    assert process.returncode == 0, (out, err)
    return out


try:
    for db, directory in [(B, BASELINE), (C, M)]:
        run('create database ' + db, 'postgres')
        print('Owned disposable database:', db, flush=True)
        run("create schema auth;create table auth.users(id uuid primary key,email text);"
            "create function auth.uid() returns uuid language sql stable as $$select "
            "nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;"
            "grant usage on schema public,auth to anon,authenticated,service_role;", db)
        for migration in sorted(directory.glob('*.sql')):
            run(migration.read_text(encoding='utf-8'), db)
        # Identical deterministic fixture UUID allocation in BOTH scratch DBs.
        run("alter table public.sale_reviews alter column id set default current_setting('probe.review')::uuid;", db)
        identities = [('owner', True), ('admin', True), ('seller', True),
                      ('owner', False), ('admin', False), ('seller', False), ('seller', True)]
        for n, (role, active) in enumerate(identities, 1):
            run('insert into auth.users(id) values(' + u('actor' + str(n)) +
                ');insert into public.profiles(id,role,display_name,is_active) values(' + u('actor' + str(n)) +
                ", '" + role + "','Bounded verifier'," + str(active) + ');', db)
        for n in range(1, 5):
            run('insert into public.vehicles(id,brand,model,year,publication_status) values(' +
                u('vehicle' + str(n)) + ",'Test','Bounded',2024,'published');" +
                'insert into public.contacts(id,normalized_phone,display_name) values(' + u('contact' + str(n)) +
                ",'+549118123450" + str(n) + "','Bounded');" +
                'insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_phone,submitted_name) values(' +
                ','.join([u('inquiry' + str(n)), u('submit' + str(n)), u('contact' + str(n)),
                          u('vehicle' + str(n)), u('actor3')]) + ",'+549118123450" + str(n) + "','Bounded');" +
                'insert into public.inquiry_interests(inquiry_id,vehicle_id) values(' +
                u('inquiry' + str(n)) + ',' + u('vehicle' + str(n)) + ');', db)
    for n in [2, 4, 5, 6]:
        for operation in ['select * from public.inquiry_closure_attribution',
                          'insert into public.inquiry_closure_attribution(history_id) values(' + u('bad') + ')',
                          'update public.inquiry_closure_attribution set responsible_id=null',
                          'delete from public.inquiry_closure_attribution',
                          'truncate public.inquiry_closure_attribution', 'select public.capture_closure_attribution()']:
            before = snap()
            result = run(actor(n) + operation, code=3)
            assert 'permission denied' in result[2] and snap() == before
    print('PASS 24 admin/inactive raw denials; unchanged public hashes', flush=True)
    commands = [actor(3) + report(), actor(2) + resolve(), actor(2) + resolve(),
                actor(2) + reopen(), actor(2) + reopen()]
    for i, sql in enumerate(commands):
        code = 3 if i == 4 else 0
        baseline = run(sql, B, code)
        candidate = run(sql, C, code)
        assert baseline == candidate, (i, baseline, candidate)
    print('PASS five exact public API differentials', flush=True)
    run('update public.inquiries set assignee_id=' + u('actor7') + ' where id=' + u('inquiry1'))
    run(actor(7) + report(rev=2))
    run(actor(2) + resolve(rev=2))
    before = snap()
    run(actor(2) + resolve(rev=2))
    assert snap() == before
    check('select count(*)=2 and count(distinct responsible_id)=2 from public.inquiry_closure_attribution a '
          'join public.inquiry_status_history h on h.id=a.history_id where h.inquiry_id=' + u('inquiry1'))
    check('select count(*)=1 from public.inquiries where id=' + u('inquiry1'))
    print('PASS reopen/reassign/second closure/idempotent retry', flush=True)
    run(actor(3) + 'select public.reserve_inquiry_vehicle(' + u('inquiry2') + ',' + u('vehicle2') + ');' + report(2))
    run("create function public.bounded_snapshot_failure() returns trigger language plpgsql as $$begin "
        "raise exception 'bounded snapshot failure' using errcode='P0001';end$$;"
        'create trigger bounded_snapshot_failure before insert on public.inquiry_closure_attribution '
        'for each row execute function public.bounded_snapshot_failure();')
    before = snap()
    result = run(actor(2) + resolve(2), code=3)
    assert 'ERROR:  bounded snapshot failure' in result[2] and snap() == before
    run('drop trigger bounded_snapshot_failure on public.inquiry_closure_attribution;'
        'drop function public.bounded_snapshot_failure();')
    run(actor(2) + resolve(2))
    check("select status='cancelled' from public.reservations where inquiry_id=" + u('inquiry2'))
    print('PASS snapshot failure rolls back full public state; retry succeeds', flush=True)
    run(actor(3) + report(3))
    first = start('bounded_resolution', actor(2) + resolve(3))
    wait('bounded_resolution', "state='idle in transaction'")
    second = start('bounded_duplicate', actor(1) + resolve(3))
    wait('bounded_duplicate', "wait_event_type='Lock'")
    finish(first, 'commit;')
    finish(second, 'commit;')
    check('select count(*)=1 from public.inquiry_closure_attribution a join public.inquiry_status_history h '
          'on h.id=a.history_id where h.inquiry_id=' + u('inquiry3'))
    run(actor(3) + report(4))
    first = start('bounded_resolution', actor(2) + resolve(4))
    wait('bounded_resolution', "state='idle in transaction'")
    second = start('bounded_reassign', 'update public.inquiries set assignee_id=' + u('actor7') + ' where id=' + u('inquiry4') + ';')
    wait('bounded_reassign', "wait_event_type='Lock'")
    finish(first, 'commit;')
    finish(second, 'commit;')
    check('select count(*)=1 and bool_and(responsible_id=' + u('actor3') + ') from public.inquiry_closure_attribution a '
          'join public.inquiry_status_history h on h.id=a.history_id where h.inquiry_id=' + u('inquiry4'))
    check('select assignee_id=' + u('actor7') + ' from public.inquiries where id=' + u('inquiry4'))
    print('PASS two actual public API Lock waits; one snapshot each; no deadlock', flush=True)
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
    (R / 'commands.json').write_text(json.dumps(log, indent=2), encoding='utf-8')
