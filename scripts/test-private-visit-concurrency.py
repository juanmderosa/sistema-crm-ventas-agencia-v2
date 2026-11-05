"""Retain private-visit concurrency probes on an owned migrated empty database.

Usage: python scripts/test-private-visit-concurrency.py verify_visits_<name>
Fixtures remain in that disposable database for parent cleanup.
"""

import concurrent.futures
import hashlib
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
                              capture_output=True, timeout=30)

    def sql(source):
        result = run(source)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()

    def ident(number):
        return "'" + str(uuid.UUID(hashlib.md5(('visit-create-' + str(number)).encode()).hexdigest())) + "'::uuid"

    def actor(number=3):
        return "set role authenticated;set request.jwt.claim.sub='" + str(
            uuid.UUID(hashlib.md5(('visit-create-' + str(number)).encode()).hexdigest())) + "';"

    slot = sql("select (((clock_timestamp() at time zone 'America/Argentina/Buenos_Aires')::date+7)"
               "+time '10:00') at time zone 'America/Argentina/Buenos_Aires';")

    def create(key, inquiry, vehicle, scheduled=slot):
        return ('select public.create_inquiry_visit(' + ','.join(map(ident, [key, inquiry, vehicle])) +
                ",'" + scheduled + "'::timestamptz,null);")

    # Reuse the deterministic focused-test fixtures, not git history or a fixed commit.
    root = pathlib.Path(__file__).resolve().parents[1]
    fixture = (root / 'supabase/tests/0029_visit_creation_test.sql').read_text(encoding='utf-8')
    sql(fixture.split('set local role authenticated;')[0] + 'commit;')

    def wait(predicate):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if sql('select ' + predicate + ';') == 't':
                return
            time.sleep(0.03)
        raise AssertionError('Expected observable condition: ' + predicate)

    def race(label, hold, attempt, error=None, expiry=None):
        tag = 'private_visit_' + uuid.uuid4().hex
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
                print('PASS observed lock wait: ' + label, flush=True)
                if expiry:
                    wait("clock_timestamp()>'" + expiry + "'::timestamptz")
                holder.stdin.write('commit;\n')
                holder.stdin.close()
                holder.wait(timeout=10)
                result = contender.result()
            if holder.returncode or (result.returncode != (3 if error else 0)):
                raise AssertionError((label, holder.stderr.read(), result.stderr))
            if error and error not in result.stderr:
                raise AssertionError((label, result.stderr))
            print('PASS released result: ' + label)
        finally:
            if holder.poll() is None:
                holder.kill()
                holder.wait()

    race('different interest vehicles', actor() + create(301,31,21), actor() + create(302,31,22),
         'inquiry already has a pending visit')
    race('identical request retries', actor() + create(303,33,22), actor() + create(303,33,22))
    sql("delete from public.dealership_opening_hours;insert into public.dealership_opening_hours "
        "select n,'00:00','24:00' from generate_series(0,6)n;")
    expiry = sql("select clock_timestamp()+interval '3 seconds'")
    race('expired during schedule wait',
         "select pg_advisory_xact_lock(hashtextextended('dealership.opening_hours',0));",
         actor(4) + create(304,32,21,expiry), 'visit time must be future and within opening hours', expiry)
    race('deactivated actor', 'update public.vehicles set model=model where id=' + ident(21) +
         ';update public.profiles set is_active=false where id=' + ident(4) + ';',
         actor(4) + create(305,32,21), 'visit access denied')
    sql('update public.profiles set is_active=true where id=' + ident(4))
    race('reassigned inquiry', 'update public.inquiries set assignee_id=' + ident(3) +
         ' where id=' + ident(32) + ';', actor(4) + create(306,32,21), 'visit access denied')
    if sql('select (select count(*) from public.visits)=2 and '
           '(select count(*) from public.visit_history)=2 and '
           '(select count(*) from public.visit_creation_requests)=2 and '
           'not exists(select 1 from public.reservations) and '
           'not exists(select 1 from public.vehicle_inquiry_rotation)') != 't':
        raise AssertionError('Expected two visits, histories and intents without reservation/routing')
    print('PASS two visits; disposable database retained: ' + database)


if __name__ == '__main__':
    main()
