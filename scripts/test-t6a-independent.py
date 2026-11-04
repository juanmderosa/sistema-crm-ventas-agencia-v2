"""Run retained T6a probes in two NEW explicitly named disposable databases.

Usage: python scripts/test-t6a-independent.py t6verify_<base> t6verify_<candidate> <baseline-migrations-directory>
Requires local Docker, Python and baseline migration files exported by the caller.
Never reads git history, resets the shared database, or drops databases.
"""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

if (len(sys.argv) != 4 or any(not re.fullmatch(r"t6verify_[a-zA-Z0-9_]+", name)
                            for name in sys.argv[1:3]) or sys.argv[1] == sys.argv[2]):
    raise SystemExit(__doc__)
BASELINE, CANDIDATE = sys.argv[1:3]
BASELINE_MIGRATIONS = pathlib.Path(sys.argv[3]).resolve()
MIGRATIONS = pathlib.Path(__file__).resolve().parents[1] / "supabase" / "migrations"
if not list(BASELINE_MIGRATIONS.glob("*.sql")):
    raise SystemExit("Baseline migration directory must contain SQL files")
ROOT = pathlib.Path(tempfile.mkdtemp(prefix="t6a-probes.", dir=pathlib.Path(
    os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"))
print("Scratch retained for caller cleanup:", ROOT, flush=True)
os.environ["HOME"] = os.environ["TMPDIR"] = str(ROOT)
PSQL = ["docker", "exec", "-i", "supabase_db_dealership-mvp", "psql", "-X", "-At",
        "-U", "postgres", "-v", "ON_ERROR_STOP=1"]
LOG = []
PROCESSES = []


def run(query, database=CANDIDATE, expect_success=True):
    result = subprocess.run(PSQL + [database], input=query, text=True, encoding="utf-8",
                            capture_output=True, timeout=25)
    LOG.append(dict(db=database, sql=query, code=result.returncode,
                    out=result.stdout, err=result.stderr))
    if expect_success:
        assert result.returncode == 0, LOG[-1]
    return result.returncode, result.stdout, result.stderr


def value(query, database=CANDIDATE):
    return run(query, database)[1].strip()


def uid(identifier):
    return "md5('verify-%s')::uuid" % identifier


def call(vehicle=1, token=1):
    return "select public.record_vehicle_view(%s,%s);" % (uid("v" + str(vehicle)), uid("t" + str(token)))


def service(query):
    return "set role service_role;" + query


def hash_state(tables=None):
    tables = tables or value("select string_agg(quote_ident(tablename),',') from pg_tables where schemaname='public';").split(",")
    return value("select md5(" + "||".join(
        "coalesce((select string_agg(x::text,'' order by x::text) from(select to_jsonb(t)x from public."
        + table + " t)s),'')" for table in tables) + ");")


def start(name, query):
    process = subprocess.Popen(PSQL + [CANDIDATE], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, encoding="utf-8")
    PROCESSES.append(process)
    process.stdin.write("set statement_timeout='12s';set application_name='%s';begin;" % name + query + "\n")
    process.stdin.flush()
    return process


def barrier(name, predicate):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        if value("select count(*) from pg_stat_activity where datname=current_database() "
                 "and application_name='%s' and (%s);" % (name, predicate)) == "1":
            return
        time.sleep(.05)
    raise AssertionError("Missing barrier " + name + " " + predicate)


def finish(process, tail):
    process.stdin.write(tail + "\n")
    process.stdin.close()
    process.stdin = None
    out, err = process.communicate(timeout=16)
    assert process.returncode == 0, (out, err)
    return out


try:
    for database, directory in [(BASELINE, BASELINE_MIGRATIONS), (CANDIDATE, MIGRATIONS)]:
        run("create database " + database + ";", "postgres")
        print("Owned disposable database:", database, flush=True)
        run("create schema auth;create table auth.users(id uuid primary key);"
            "create function auth.uid() returns uuid language sql stable as $$select "
            "nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;"
            "grant usage on schema public,auth to anon,authenticated,service_role;"
            "grant execute on function auth.uid() to public;", database)
        for migration in sorted(directory.glob("*.sql")):
            run(migration.read_text(encoding="utf-8"), database)
        for index, (role, active) in enumerate([
                ("owner", True), ("admin", True), ("seller", True),
                ("owner", False), ("admin", False), ("seller", False)]):
            run("insert into auth.users values(%s);insert into public.profiles(id,role,display_name,is_active) "
                "values(%s,'%s','Verifier',%s);" % (uid(index), uid(index), role, str(active)), database)
        for index in range(1, 9):
            run("insert into public.vehicles(id,brand,model,year,publication_status,availability_status,sale_enabled,deleted_at) "
                "values(%s,'Verify','Fixture',2020,'%s','%s',%s,%s);" % (
                    uid("v" + str(index)), "draft" if index == 4 else "published",
                    "sold" if index == 2 else "reserved" if index == 3 else "available",
                    "false" if index == 5 else "true", "now()" if index == 6 else "null"), database)
    print("PASS|setup", flush=True)
    commercial = value("select string_agg(quote_ident(tablename),',') from pg_tables "
                       "where schemaname='public' and tablename not like 'vehicle_view_%';").split(",")
    original = hash_state(commercial)
    for role, identity in [("anon", None), ("service_role", None)] + [("authenticated", i) for i in range(6)]:
        prefix = "set role " + role + ";" + (
            "select set_config('request.jwt.claim.sub',%s::text,false);" % uid(identity) if identity is not None else "")
        operations = []
        if role != "service_role":
            operations.append((call(), "permission denied for function record_vehicle_view"))
        for table in ["vehicle_view_events", "vehicle_view_dedup"]:
            for operation in ["select * from " + table, "insert into " + table + " default values",
                              "update " + table + " set vehicle_id=vehicle_id", "delete from " + table,
                              "truncate " + table]:
                operations.append((operation + ";", "permission denied for table " + table))
        for operation, message in operations:
            before = hash_state()
            code, out, err = run("\\set VERBOSITY verbose\n" + prefix + operation, expect_success=False)
            assert code == 3 and "42501" in err and message in err, (operation, code, out, err)
            assert before == hash_state(), operation
    print("PASS|87 denied operations and unchanged state", flush=True)
    for vehicle in [1, 2, 3]:
        assert value(service(call(vehicle))).splitlines()[-1] == "t"
    for vehicle in [4, 5, 6, 99]:
        before = hash_state()
        result = run("\\set VERBOSITY verbose\n" + service(call(vehicle)), expect_success=False)
        assert result[0] == 3 and "22023: vehicle is not publicly visible" in result[2], result
        assert hash_state() == before
    for args in ["null," + uid("t1"), uid("v1") + ",null"]:
        before = hash_state()
        result = run("\\set VERBOSITY verbose\n" + service("select record_vehicle_view(" + args + ");"), expect_success=False)
        assert result[0] == 3 and "22023: vehicle and browser token are required" in result[2], result
        assert before == hash_state()
    before = hash_state()
    assert value(service(call())).splitlines()[-1] == "f"
    assert before == hash_state()
    assert value(service(call(1, 2))).splitlines()[-1] == "t"
    run("update vehicle_view_dedup set last_counted_at=clock_timestamp()-interval '24 hours 1 second' "
        "where vehicle_id=%s and browser_token=%s;" % (uid("v1"), uid("t1")))
    assert value(service(call())).splitlines()[-1] == "t"
    assert original == hash_state(commercial)
    assert value("select string_agg(column_name,',' order by ordinal_position) from information_schema.columns "
                 "where table_name='vehicle_view_events';") == "id,vehicle_id,counted_at"
    print("PASS|windows eligibility and preservation", flush=True)
    for query in [
            "set role anon;select id,brand,model,year,publication_status,availability_status,sale_enabled from vehicles order by id;",
            "set role service_role;select public.submit_inquiry(null,null,null,null,null);",
            "set role anon;select * from profiles;",
            "select has_table_privilege('service_role','vehicles','UPDATE'),has_table_privilege('authenticated','vehicles','SELECT');"]:
        assert run(query, BASELINE, False) == run(query, CANDIDATE, False)
    print("PASS|baseline differential stdout stderr exit", flush=True)
    for token, rollback in [(20, False), (21, True)]:
        first = start("vvfirst", service(call(1, token)))
        barrier("vvfirst", "state='idle in transaction'")
        second = start("vvsecond", service(call(1, token)))
        barrier("vvsecond", "wait_event_type='Lock'")
        assert value(service(call(8, token))).splitlines()[-1] == "t"
        first_out = finish(first, "rollback;" if rollback else "commit;")
        barrier("vvsecond", "state='idle in transaction'")
        second_out = finish(second, "commit;")
        assert "\nt\n" in first_out
        assert ("\nt\n" if rollback else "\nf\n") in second_out, (first_out, second_out)
        assert value("select count(*) from vehicle_view_events where vehicle_id=" + uid("v1") + ";") == str(4 if token == 20 else 5)
        print("PASS|actual Lock wait|rollback=" + str(rollback), flush=True)
    run("insert into vehicle_view_dedup values(%s,%s,clock_timestamp()-interval '24 hours'+interval '2 seconds');" % (uid("v7"), uid("t30")))
    key = "pg_catalog.hashtextextended('vehicle-view:'||%s::text||':'||%s::text,0)" % (uid("v7"), uid("t30"))
    first = start("vvclockfirst", "select pg_advisory_xact_lock(" + key + ");")
    barrier("vvclockfirst", "state='idle in transaction'")
    second = start("vvclocksecond", service(call(7, 30)))
    barrier("vvclocksecond", "wait_event_type='Lock'")
    time.sleep(2.3)
    finish(first, "commit;")
    barrier("vvclocksecond", "state='idle in transaction'")
    assert "\nt\n" in finish(second, "commit;")
    assert value("select e.counted_at=d.last_counted_at and e.counted_at>a.xact_start "
                 "from vehicle_view_events e join vehicle_view_dedup d using(vehicle_id) "
                 "cross join lateral(select now()-interval '1 hour' xact_start)a where e.vehicle_id=" + uid("v7") + ";") == "t"
    assert original == hash_state(commercial)
    print("PASS|post-wait clock and terminal invariants", flush=True)
finally:
    for process in PROCESSES:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
    (ROOT / "results.json").write_text(json.dumps(LOG, indent=2), encoding="utf-8")
