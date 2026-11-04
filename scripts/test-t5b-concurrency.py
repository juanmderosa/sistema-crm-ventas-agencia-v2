"""Retained sale-resolution races; requires a migrated disposable t5verify_* DB."""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

if len(sys.argv) != 2 or not re.fullmatch(r"t5verify_[a-zA-Z0-9_]+", sys.argv[1]):
    raise SystemExit("Usage: python scripts/test-t5b-concurrency.py t5verify_<disposable_database>")
DB = sys.argv[1]
ROOT = pathlib.Path(tempfile.mkdtemp(prefix="t5b-races.", dir=pathlib.Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"))
print("Scratch retained for caller cleanup:", ROOT, flush=True)
BASE = ["docker", "exec", "-i", "supabase_db_dealership-mvp", "psql", "-X", "-At", "-U", "postgres", "-v", "ON_ERROR_STOP=1", DB]
SOURCE = (pathlib.Path(__file__).resolve().parents[1] / "supabase" / "tests" /
          "0019_t5b_independent_completion_test.sql").read_text(encoding="utf-8")
prefix = "t5b-race-" + str(time.time_ns())
source = SOURCE.replace("completion-", prefix + "-").replace("+5491198776611", "+54911" + str(time.time_ns())[-8:])
fixture = source.split("insert into auth.users", 1)[1].split("-- Only this transaction", 1)[0]
fixture = "insert into auth.users" + fixture
state = "create function pg_temp.snapshot" + source.split("create function pg_temp.snapshot", 1)[1].split("create function pg_temp.call", 1)[0]
HASH = "select 'HASH|'||pg_temp.snapshot();"
processes = []
waits = []


def sql(text):
    result = subprocess.run(BASE, input=text, text=True, encoding="utf-8", capture_output=True, timeout=25)
    if result.returncode:
        raise RuntimeError((result.returncode, result.stdout, result.stderr))
    return result.stdout.strip()


def ident(kind, n):
    return "md5('%s-%s-%s')::uuid" % (prefix, kind, n)


def actor(n=1):
    return "set role authenticated;select set_config('request.jwt.claim.sub',%s::text,false);" % ident("actor", n)


def report(i):
    return "select public.report_inquiry_sale(%s,%s);" % (ident("inquiry", i), ident("vehicle", i))


def reserve(i, v):
    return "select public.reserve_inquiry_vehicle(%s,%s);" % (ident("inquiry", i), ident("vehicle", v))


def resolve(i, decision=True):
    return "select public.resolve_sale_review((select id from public.sale_reviews where inquiry_id=%s),%s);" % (
        ident("inquiry", i), "true" if decision else "false")


def block(i):
    return "select public.set_vehicle_sale_blocked(%s,true);" % ident("vehicle", i)


def cancel(i):
    return "select public.cancel_reservation((select id from public.reservations where inquiry_id=%s));" % ident("inquiry", i)


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def start(name, body):
    text = ("\\set VERBOSITY verbose\nset application_name='%s';set statement_timeout='15s';%s\nbegin;%s\n"
            % (name, state, body))
    (ROOT / (name + ".sql")).write_text(text, encoding="utf-8")
    process = subprocess.Popen(BASE, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding="utf-8")
    processes.append(process)
    process.stdin.write(text)
    process.stdin.flush()
    return process


def wait(name, predicate):
    for _ in range(150):
        if sql("select count(*) from pg_stat_activity where datname=current_database() and application_name='%s' and (%s);" % (name, predicate)) == "1":
            waits.append(name + "|" + predicate)
            return
        time.sleep(.04)
    raise AssertionError("Barrier missing: " + name)


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


def race(name, first_command, second_command, error=None, same=False):
    first = start(name + "_first", first_command + "reset role;" + HASH)
    wait(name + "_first", "state='idle in transaction'")
    second = start(name + "_second", second_command + "commit;")
    wait(name + "_second", "wait_event_type='Lock'")
    a, b = finish(first, "commit;"), finish(second)
    (ROOT / (name + ".json")).write_text(json.dumps([a, b], indent=2), encoding="utf-8")
    check(a["code"] == 0, "winner failed: " + str(a))
    check(b["code"] == (3 if error else 0), "unexpected loser: " + str(b))
    if error:
        check(error in b["err"], "wrong rejection: " + str(b))
    if error or same:
        before = [line for line in a["out"].splitlines() if line.startswith("HASH|")][-1]
        check(before == sql(state + HASH).splitlines()[-1], "rejected/duplicate command changed state")
    if same:
        responses = [[json.loads(line) for line in result["out"].splitlines() if line.startswith("{")][-1] for result in (a, b)]
        check(responses[0] == responses[1], "duplicate resolution returned different IDs")
    print("PASS|" + name + "|actual Lock wait|exit=" + str(a["code"]) + "/" + str(b["code"]), flush=True)


try:
    sql("begin;" + fixture + "commit;")
    for i in range(30, 38):
        sql(actor(3) + report(i))
    race("confirm_reserve", actor() + resolve(30), actor(3) + reserve(43, 30), "22023: vehicle must be Available and enabled for sale")
    race("reserve_confirm", actor(3) + reserve(44, 31), actor() + resolve(31), "22023: resolve the competing reservation before confirming the sale")
    race("double_confirm", actor() + resolve(32), actor(2) + resolve(32), same=True)
    race("confirm_reject", actor() + resolve(33), actor(2) + resolve(33, False), "22023: sale review is already resolved with a different decision")
    race("reject_confirm", actor() + resolve(34, False), actor(2) + resolve(34), "22023: sale review is already resolved with a different decision")
    race("block_confirm", actor() + block(35), actor(2) + resolve(35), "22023: vehicle must exist and be enabled for sale")
    race("confirm_block", actor() + resolve(36), actor(2) + block(36))
    for i in (45, 46):
        sql(actor(3) + reserve(i, i) + report(i))
    race("cancel_confirm", actor(3) + cancel(45), actor() + resolve(45))
    race("confirm_cancel", actor() + resolve(46), actor(3) + cancel(46), "22023: reservation is not active")
    race("deactivate_confirm", "select 1 from public.vehicles where id=%s for update;update public.profiles set is_active=false where id=%s;" % (
        ident("vehicle", 37), ident("actor", 2)), actor(2) + resolve(37), "42501: sale resolution access denied")
    checks = [
        "(select count(*)=1 from public.confirmed_sales where inquiry_id=%s)" % ident("inquiry", 32),
        "(select status='active' from public.reservations where inquiry_id=%s)" % ident("inquiry", 44),
        "(select status='pending' from public.sale_reviews where inquiry_id=%s)" % ident("inquiry", 31),
        "(select status='confirmed' from public.sale_reviews where inquiry_id=%s)" % ident("inquiry", 33),
        "(select status='rejected' from public.sale_reviews where inquiry_id=%s)" % ident("inquiry", 34),
        "(select status='pending' from public.sale_reviews where inquiry_id=%s)" % ident("inquiry", 35),
        "(select availability_status='sold' and not sale_enabled from public.vehicles where id=%s)" % ident("vehicle", 36),
        "(select status='cancelled' from public.reservations where inquiry_id=%s)" % ident("inquiry", 45),
        "(select status='completed' from public.reservations where inquiry_id=%s)" % ident("inquiry", 46),
        "(select count(*)=0 from public.confirmed_sales where inquiry_id=%s)" % ident("inquiry", 37),
        "(select status='pending' from public.sale_reviews where inquiry_id=%s)" % ident("inquiry", 37),
    ]
    invariants = json.loads(sql("select to_jsonb(array[" + ",".join(checks) + "]);"))
    check(all(value is True for value in invariants), "terminal invariants: " + str(invariants))
    (ROOT / "summary.json").write_text(json.dumps(dict(database=DB, waits=waits, invariants=invariants), indent=2), encoding="utf-8")
    print("PASS|ten races and terminal invariants", flush=True)
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
