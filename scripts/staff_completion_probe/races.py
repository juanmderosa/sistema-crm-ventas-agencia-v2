"""Four finite hold/wait/release schedules, using actual public operations."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import json
import uuid

from db import (LOCK, OWNER, REVOKED, STATE, complete, finish, fixture,
                literal, persisted, revoke, wrapped)


@contextmanager
def holder(db, sql, value, role='service_role', explicit_lock=False):
    process = db.launch()
    try:
        setup = ("set statement_timeout='12s'; "
                 "set idle_in_transaction_session_timeout='35s'; begin; "
                 "do $$ begin perform set_config('request.jwt.claim.sub',%s,false); end $$; "
                 % literal(OWNER))
        if explicit_lock:
            setup += "do $$ begin perform pg_advisory_xact_lock(hashtext('%s')); end $$;" % LOCK
        process.stdin.write(setup + wrapped(sql,role) + STATE +
                            "select 'HELD|' || pg_backend_pid();\n")
        process.stdin.flush()
        def ready():
            return [process.stdout.readline() for _ in range(3)]
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(ready)
            try:
                reply, state, marker = future.result(timeout=16)
            except Exception:
                process.kill()
                raise
        db.require('holder exact SQLSTATE message and result',
                   json.loads(reply) == {'code':'00000','message':'','value':value})
        db.outcomes += 1  # Real holder exit/stderr are checked on explicit release.
        db.require('holder explicitly ready with backend PID',
                   marker.startswith('HELD|') and marker.strip()[5:].isdigit())
        yield int(marker.strip()[5:]), json.loads(state)
    finally:
        if process.poll() is None:
            result = finish(process,"commit; select 'RELEASED';\n",timeout=15)
            db.require('explicit commit/release exact channels',result == (0,'RELEASED\n',''))
        else:
            finish(process)
            raise RuntimeError('holder exited before release')


def wait(db, pid, tag):
    # Read the exact waiter PID, Lock event, advisory key and blocking holder PID.
    result = db.sql("""
    do $$ declare deadline timestamptz := clock_timestamp()+interval '6 seconds';
    begin loop
      perform pg_stat_clear_snapshot();
      exit when exists (
        select 1 from pg_stat_activity a join pg_locks l on l.pid=a.pid
        where a.application_name=%s and a.state='active'
          and a.wait_event_type='Lock' and a.wait_event='advisory'
          and l.locktype='advisory' and not l.granted and l.objsubid=1
          and l.classid=((hashtext(%s)::bigint >> 32)&4294967295)::oid
          and l.objid=(hashtext(%s)::bigint&4294967295)::oid
          and %d=any(pg_blocking_pids(a.pid)));
      if clock_timestamp()>=deadline then raise exception 'wait deadline'; end if;
      perform pg_sleep(0.02);
    end loop; end $$; select 'WAIT_OBSERVED';
    """ % (literal(tag),literal(LOCK),literal(LOCK),pid))
    db.require('exact PID and namespace advisory Lock wait observed',result == 'WAIT_OBSERVED')
    db.waits += 1
    print('PASS observed wait ' + str(db.waits),flush=True)


def schedule(db, winner, winner_value, loser, expected, role='service_role', lock=False):
    process = None
    with ThreadPoolExecutor(max_workers=1) as pool:
        try:
            with holder(db,winner,winner_value,role,lock) as (pid,state):
                process = db.launch()
                tag = 'completion-probe-' + uuid.uuid4().hex
                payload = ("set statement_timeout='12s'; set lock_timeout='10s'; "
                           'set application_name=%s; ' % literal(tag)) + wrapped(loser)
                future = pool.submit(finish,process,payload)
                wait(db,pid,tag)
            db.reply(future.result(timeout=18),expected)
            return state
        finally:
            if process is not None and process.poll() is None:
                process.kill()


def races(db):
    ok = lambda value: {'code':'00000','message':'','value':value}
    f = fixture(db)
    state = schedule(db,complete(f),f[1],complete(f),ok(f[1]))
    db.unchanged(state,db.snapshot())
    persisted(db,f)

    f = fixture(db)
    state = schedule(db,revoke(f),f[0],complete(f),
                     {'code':'23514','message':REVOKED,'value':None})
    db.unchanged(state,db.snapshot())
    db.require('revocation winner leaves no profile or completion',db.sql(
        'select not exists(select 1 from public.profiles where id=%s) and '
        'not exists(select 1 from public.staff_invitation_completions where invitation_id=%s);'
        % (literal(f[1]),literal(f[0]))) == 't')

    f = fixture(db)
    state = schedule(db,complete(f),f[1],revoke(f),ok(f[0]))
    after = db.snapshot()
    changed = {'public.staff_invitation_intents','public.staff_invitation_requests'}
    db.require('winning completion then revoke changes only intent/request tables',
        {k:v for k,v in state['tables'].items() if k not in changed} ==
        {k:v for k,v in after['tables'].items() if k not in changed})
    db.require('completion/revoke preserves every sequence',state['sequences'] == after['sequences'])
    db.require('revoke persisted after completion',db.sql(
        'select revoked_at is not null from public.staff_invitation_intents where id=%s;'
        % literal(f[0])) == 't')
    db.check(complete(f),f[1],readonly=True)
    persisted(db,f)

    f = fixture(db)
    db.check(complete(f),f[1])
    update = 'update public.profiles set is_active=false where id=%s returning id' % literal(f[1])
    state = schedule(db,update,f[1],complete(f),ok(f[1]),role='authenticated',lock=True)
    db.unchanged(state,db.snapshot())
    persisted(db,f,active=False)
