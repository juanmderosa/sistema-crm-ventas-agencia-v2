"""Public visit races on an owned migrated empty verify_visits_* database.

Uses explicit release handshakes; leaves synthetic fixtures for caller cleanup.
"""

import concurrent.futures
import hashlib
import json
import pathlib
import subprocess
import sys
import time
import uuid


def main():
    if len(sys.argv) != 2 or not sys.argv[1].startswith('verify_visits_'):
        raise SystemExit('Pass an owned migrated empty verify_visits_* database')
    database = sys.argv[1]
    command = ['docker', 'exec', '-i', 'supabase_db_dealership-mvp', 'psql',
               '-X', '-qAt', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-d', database]

    def run(source):
        return subprocess.run(command, input=source, text=True, encoding='utf-8',
                              capture_output=True, timeout=35)

    def sql(source):
        result = run(source)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()

    def ident(number):
        value = uuid.UUID(hashlib.md5(('public-visit-' + str(number)).encode()).hexdigest())
        return "'" + str(value) + "'::uuid"

    root = pathlib.Path(__file__).resolve().parents[1]
    fixture = (root / 'supabase/tests/0030_public_visit_request_test.sql').read_text(encoding='utf-8')
    sql(fixture.split('set local role service_role;')[0] + 'commit;')
    slot = sql("select (((clock_timestamp() at time zone 'America/Argentina/Buenos_Aires')::date+7)"
               "+time '10:00') at time zone 'America/Argentina/Buenos_Aires';")

    def submit(key, visit=True, scheduled=slot):
        arguments = ident(key) + ',' + ident(21) + ",'+5491177000030','Customer','c@example.invalid'"
        if visit:
            arguments += ",'" + scheduled + "'::timestamptz,null"
        name = 'submit_visit_request' if visit else 'submit_inquiry'
        return 'set role service_role;select public.' + name + '(' + arguments + ');'

    def wait(predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if sql('select ' + predicate + ';') == 't':
                return
            time.sleep(0.03)
        raise AssertionError('Expected observed condition: ' + predicate)

    def race(label, hold, attempt, error=None, expiry=None):
        tag = 'public_visit_' + uuid.uuid4().hex
        holder = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, encoding='utf-8')
        try:
            holder.stdin.write("begin;set application_name='" + tag + "_a';" + hold + '\n')
            holder.stdin.flush()
            wait("exists(select 1 from pg_stat_activity where application_name='" + tag +
                 "_a' and state='idle in transaction')")
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                contender = pool.submit(run, "set application_name='" + tag + "_b';" + attempt)
                wait("exists(select 1 from pg_stat_activity where application_name='" + tag +
                     "_b' and wait_event_type='Lock' and cardinality(pg_blocking_pids(pid))>0)")
                print('PASS observed wait: ' + label, flush=True)
                if expiry:
                    wait("clock_timestamp()>'" + expiry + "'::timestamptz")
                holder.stdin.write('commit;\n')
                holder.stdin.close()
                holder.wait(timeout=10)
                result = contender.result()
            if holder.returncode or result.returncode != (3 if error else 0):
                raise AssertionError((label, holder.stderr.read(), result.stderr))
            if error and error not in result.stderr:
                raise AssertionError((label, result.stderr))
            if not error and json.loads(result.stdout) != {'accepted': True}:
                raise AssertionError('Expected accepted-only retry/submission response')
            print('PASS release and result: ' + label)
        finally:
            if holder.poll() is None:
                holder.kill()
                holder.wait()

    race('identical retries', submit(230), submit(230))
    race('same-phone continuity', submit(231), submit(232))
    race('ordinary then visit', submit(233, False), submit(233), 'submission ID already used with different input')
    race('visit then ordinary', submit(234), submit(234, False), 'submission ID already used with different input')
    race('vehicle blocked', 'update public.vehicles set sale_enabled=false where id=' + ident(21) + ';',
         submit(235), 'vehicle does not accept visits')
    sql('update public.vehicles set sale_enabled=true where id=' + ident(21) + ';'
        "delete from public.dealership_opening_hours;insert into public.dealership_opening_hours "
        "select n,'00:00','24:00' from generate_series(0,6)n;")
    expiry = sql("select clock_timestamp()+interval '3 seconds'")
    race('expired during schedule wait', "select pg_advisory_xact_lock(hashtextextended('dealership.opening_hours',0));",
         submit(236, scheduled=expiry), 'visit time must be future and within opening hours', expiry)
    if sql('select (select count(*) from public.inquiries)=5 and '
           '(select count(*) from public.visits)=4 and (select count(*) from public.visit_history)=4 and '
           '(select count(*) from public.visit_creation_requests)=4 and '
           '(select count(distinct assignee_id) from public.inquiries where submission_id in (' +
           ident(231) + ',' + ident(232) + '))=1') != 't':
        raise AssertionError('Expected exact terminal creation counts and continuity')
    print('PASS exact terminal state; disposable database retained: ' + database)


if __name__ == '__main__':
    main()
