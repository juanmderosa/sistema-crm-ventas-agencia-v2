"""Run retained overlapping-session probes on an explicit disposable database."""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

if len(sys.argv) != 2 or not re.fullmatch(r"t5verify_[a-zA-Z0-9_]+", sys.argv[1]):
    raise SystemExit("Usage: python scripts/test-t5a-concurrency.py t5verify_<disposable_database>")
DB = sys.argv[1]
TEMP = pathlib.Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"
ROOT = pathlib.Path(tempfile.mkdtemp(prefix="t5a-races.", dir=TEMP))
print("Scratch retained for caller cleanup:", ROOT, flush=True)
BASE = ["docker", "exec", "-i", "supabase_db_dealership-mvp", "psql", "-X", "-At",
        "-U", "postgres", "-v", "ON_ERROR_STOP=1", DB]
SOURCE = (pathlib.Path(__file__).resolve().parents[1] / "supabase" / "tests" /
          "0016_sale_reporting_permissions_test.sql").read_text(encoding="utf-8")
prefix = "race-" + str(time.time_ns())
fixture = SOURCE.split("create function pg_temp.bounded_state")[0]
fixture = fixture.replace("begin;", "", 1).replace("select no_plan();", "")
fixture = fixture.replace("bounded-", prefix + "-").replace("+5491199988877", "+54911" + str(time.time_ns())[-8:])
state = "create function pg_temp.bounded_state" + SOURCE.split(
    "create function pg_temp.bounded_state", 1)[1].split("create function pg_temp.check_call", 1)[0]
processes = []
waits = []


def sql(text):
    result = subprocess.run(BASE, input=text, text=True, encoding="utf-8", capture_output=True, timeout=25)
    if result.returncode:
        raise RuntimeError((result.returncode, result.stdout, result.stderr))
    return result.stdout.strip()


def ident(kind, n):
    return "md5('%s-%s-%s')::uuid" % (prefix, kind, n)


def actor():
    return "set role authenticated; select set_config('request.jwt.claim.sub',%s::text,false);" % ident("actor", 3)


def report(i, v):
    return "select public.report_inquiry_sale(%s,%s);" % (ident("inquiry", i), ident("vehicle", v))


def reserve(i, v):
    return "select public.reserve_inquiry_vehicle(%s,%s);" % (ident("inquiry", i), ident("vehicle", v))


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def start(name, body):
    text = ("\\set VERBOSITY verbose\nset statement_timeout='15s';set application_name='%s';\n%s\nbegin;\n%s\n"
            % (name, state, body))
    (ROOT / (name + ".sql")).write_text(text, encoding="utf-8")
    process = subprocess.Popen(BASE, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding="utf-8")
    processes.append(process)
    process.stdin.write(text)
    process.stdin.flush()
    return process


def wait(name, predicate):
    for _ in range(120):
        value = sql("select count(*) from pg_stat_activity where datname=current_database() "
                    "and application_name='%s' and (%s);" % (name, predicate))
        if value == "1":
            waits.append(name + "|" + predicate)
            return
        time.sleep(.05)
    raise RuntimeError("Barrier not observed: " + name + " " + predicate)


def finish(process, tail=""):
    try:
        if tail:
            process.stdin.write(tail + "\n")
            process.stdin.flush()
        process.stdin.close()
    except OSError:
        pass
    process.stdin = None
    out, err = process.communicate(timeout=25)
    return dict(code=process.returncode, out=out, err=err)


HASH = "select 'HASH|'||pg_temp.bounded_state();"


def race(name, winner, loser, error=None, preserve=False, same_id=False):
    first = start(name + "_first", winner + " reset role;" + HASH)
    wait(name + "_first", "state='idle in transaction'")
    second = start(name + "_second", loser + " reset role;" + HASH + " commit;")
    wait(name + "_second", "wait_event_type='Lock'")
    a, b = finish(first, "commit;"), finish(second)
    (ROOT / (name + ".json")).write_text(json.dumps(dict(first=a, second=b), indent=2), encoding="utf-8")
    check(a["code"] == 0, "winner failed: " + str(a))
    check("40P01" not in b["err"], "deadlock")
    check((b["code"] == 3 and error in b["err"]) if error else b["code"] == 0,
          "unexpected second result: " + str(b))
    before = [line for line in a["out"].splitlines() if line.startswith("HASH|")][-1]
    if preserve:
        check(before == sql(state + HASH).splitlines()[-1], "rejection/retry changed persisted state")
    if same_id:
        ids = [[json.loads(line)["review_id"] for line in r["out"].splitlines()
                if line.startswith('{"review_id"')] for r in (a, b)]
        check(ids[0] == ids[1] and len(ids[0]) == 1, "different retry IDs")
    print("PASS|" + name + "|actual Lock wait|exit=" + str(a["code"]) + "/" + str(b["code"]), flush=True)


try:
    # Fixture changes occur only in the caller-selected disposable database.
    extra = ("insert into public.inquiry_interests(inquiry_id,vehicle_id) select "
             "md5('%s-inquiry-'||i)::uuid,md5('%s-vehicle-'||v)::uuid "
             "from (values(11,11),(12,12),(12,13),(14,14),(15,14),(16,16),(17,16),(18,18))p(i,v);"
             % (prefix, prefix))
    sql("begin;" + fixture + extra + "commit;")
    race("same_report", actor() + report(11, 11), actor() + report(11, 11), preserve=True, same_id=True)
    race("different_target", actor() + report(12, 12), actor() + report(12, 13),
         "22023: inquiry is not active", preserve=True)
    race("report_then_reserve", actor() + report(14, 14), actor() + reserve(15, 14))
    race("reserve_then_report", actor() + reserve(16, 16), actor() + report(17, 16),
         "22023: vehicle must be Available or reserved by this inquiry", preserve=True)
    race("deactivate_then_report", "update public.profiles set is_active=false where id=%s;" % ident("actor", 3),
         actor() + report(18, 18), "42501: sale access denied", preserve=True)
    query = """select jsonb_build_object(
      'same_reviews',(select count(*) from public.sale_reviews where inquiry_id=%s),
      'same_history',(select count(*) from public.inquiry_status_history where inquiry_id=%s),
      'different_reviews',(select count(*) from public.sale_reviews where inquiry_id=%s),
      'different_history',(select count(*) from public.inquiry_status_history where inquiry_id=%s),
      'report_pending',(select status='pending' from public.sale_reviews where inquiry_id=%s and vehicle_id=%s),
      'competing_active',(select status='active' from public.reservations where inquiry_id=%s and vehicle_id=%s),
      'vehicle_reserved',(select availability_status='reserved' from public.vehicles where id=%s),
      'reserve_first_active',(select status='active' from public.reservations where inquiry_id=%s),
      'rejected_no_review',(select count(*)=0 from public.sale_reviews where inquiry_id in(%s,%s)),
      'not_cancelled',(select count(*)=0 from public.reservations where created_by=%s and status<>'active'));
    """ % (ident("inquiry", 11), ident("inquiry", 11), ident("inquiry", 12), ident("inquiry", 12),
           ident("inquiry", 14), ident("vehicle", 14), ident("inquiry", 15), ident("vehicle", 14),
           ident("vehicle", 14), ident("inquiry", 16), ident("inquiry", 17), ident("inquiry", 18), ident("actor", 3))
    result = json.loads(sql(query))
    check(all(v is True or (type(v) is int and v == 1) for v in result.values()), "terminal invariants: " + str(result))
    (ROOT / "summary.json").write_text(json.dumps(dict(database=DB, waits=waits, invariants=result), indent=2), encoding="utf-8")
    print("PASS|terminal invariants|" + json.dumps(result), flush=True)
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
