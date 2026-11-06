"""Exercise whole-schedule replacement on an explicitly owned disposable DB.

Requires local Docker, the migrated Supabase DB container and Python 3.
Never targets the shared postgres database or removes scratch/fixture data.
"""

import concurrent.futures
import json
import subprocess
import sys
import time
import uuid


def main():
    if len(sys.argv) != 2 or not sys.argv[1].startswith("verify_visits_"):
        raise SystemExit("Pass an owned migrated disposable verify_visits_* database")
    database = sys.argv[1]
    owner = str(uuid.uuid4())
    tag = "visit_hours_" + uuid.uuid4().hex
    command = ["docker", "exec", "-i", "supabase_db_dealership-mvp", "psql",
               "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", database]

    def sql(source):
        result = subprocess.run(command, input=source, capture_output=True,
                                text=True, encoding="utf-8", timeout=30)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()

    def auth():
        return ("set local role authenticated;set local request.jwt.claims='" +
                json.dumps({"sub": owner}) + "';")

    def payload(day):
        return json.dumps([dict(weekday=day, opens_at="09:00", closes_at="12:00"),
                           dict(weekday=day, opens_at="16:00", closes_at="19:00")])

    def replace(day):
        return "select public.set_dealership_opening_hours('" + payload(day) + "');"

    def wait_for(label, condition):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if sql(condition) == "t":
                print("PASS " + label, flush=True)
                return
            time.sleep(0.05)
        raise AssertionError("Expected observed wait: " + label)

    sql("insert into auth.users(id,email) values('" + owner + "','" + owner +
        "@example.invalid');insert into public.profiles(id,role,display_name) " +
        "values('" + owner + "','owner','Hours concurrency fixture');")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(sql, "begin;set local application_name='" + tag +
                            "_a';" + auth() + replace(1) + "select pg_sleep(5);commit;")
        wait_for("first replacement holding transaction", "select exists(select 1 from "
                 "pg_stat_activity where application_name='" + tag +
                 "_a' and wait_event='PgSleep');")
        second = pool.submit(sql, "begin;set local application_name='" + tag +
                             "_b';" + auth() + replace(2) + "commit;")
        wait_for("second replacement blocked on advisory lock", "select exists(select 1 "
                 "from pg_stat_activity where application_name='" + tag +
                 "_b' and wait_event_type='Lock' and wait_event='advisory' "
                 "and cardinality(pg_blocking_pids(pid))>0);")
        first.result()
        second.result()
    actual = json.loads(sql("select jsonb_agg(to_jsonb(h) order by opens_at) "
                            "from public.dealership_opening_hours h;"))
    expected = [dict(weekday=2, opens_at="09:00:00", closes_at="12:00:00"),
                dict(weekday=2, opens_at="16:00:00", closes_at="19:00:00")]
    if actual != expected:
        raise AssertionError((actual, expected))
    print("PASS exact last complete schedule; no mixed intervals")
    print("Disposable database retained for caller cleanup: " + database)


if __name__ == "__main__":
    main()
