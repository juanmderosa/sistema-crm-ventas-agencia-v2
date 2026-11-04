"""Retained reopening races against an explicitly selected disposable database."""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

if len(sys.argv) != 2 or not re.fullmatch(r"t5verify_[a-zA-Z0-9_]+", sys.argv[1]):
    raise SystemExit("Usage: python scripts/test-t5c-concurrency.py t5verify_<disposable_database>")
DB = sys.argv[1]
ROOT = pathlib.Path(tempfile.mkdtemp(prefix="t5c-races.", dir=pathlib.Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"))
print("Scratch retained for caller cleanup:", ROOT, flush=True)
BASE = ["docker", "exec", "-i", "supabase_db_dealership-mvp", "psql", "-X", "-At", "-U", "postgres", "-v", "ON_ERROR_STOP=1", DB]
SOURCE = (pathlib.Path(__file__).resolve().parents[1] / "supabase" / "tests" /
          "0021_reopening_independent_test.sql").read_text(encoding="utf-8")
prefix = "t5c-race-" + str(time.time_ns())
source = SOURCE.replace("independent-", prefix + "-").replace("+5491176762345", "+54911" + str(time.time_ns())[-8:])
fixture = source.split("create function pg_temp.snap", 1)[0].replace("begin;", "", 1).replace("select no_plan();", "")
helpers = "create function pg_temp.snap" + source.split("create function pg_temp.snap", 1)[1].split("create function pg_temp.probe", 1)[0]
processes = []
waits = []


def run(text):
    result = subprocess.run(BASE, input=text, text=True, encoding="utf-8", capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError((result.returncode, result.stdout, result.stderr))
    return result.stdout.strip()


def ident(kind, n):
    return "md5('%s-%s-%s')::uuid" % (prefix, kind, n)


def actor(n):
    return "set role authenticated;select set_config('request.jwt.claim.sub',%s::text,false);" % ident("actor", n)


def reopen(n):
    return "select public.reopen_inquiry(%s);" % ident("inquiry", n)


def resolve(n, decision):
    return "select public.resolve_sale_review((select id from public.sale_reviews where inquiry_id=%s),%s);" % (
        ident("inquiry", n), "true" if decision else "false")


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def start(name, body):
    text = ("\\set VERBOSITY verbose\nset application_name='%s';set statement_timeout='15s';%s\nbegin;%s\n"
            % (name, helpers, body))
    (ROOT / (name + ".sql")).write_text(text, encoding="utf-8")
    process = subprocess.Popen(BASE, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding="utf-8")
    processes.append(process)
    process.stdin.write(text)
    process.stdin.flush()
    return process


def wait(name, predicate):
    for _ in range(150):
        if run("select count(*) from pg_stat_activity where datname=current_database() and application_name='%s' and (%s);" % (name, predicate)) == "1":
            waits.append(name + "|" + predicate)
            return
        time.sleep(.04)
    raise AssertionError("Missing barrier: " + name)


def finish(process, tail=""):
    if tail:
        process.stdin.write(tail + "\n")
        process.stdin.flush()
    process.stdin.close()
    process.stdin = None
    out, err = process.communicate(timeout=30)
    return dict(code=process.returncode, out=out, err=err)


def race(name, first_command, second_command, error=None, skip=None):
    hash_sql = "select 'HASH|'||pg_temp.snap(%s);" % (ident("inquiry", skip) if skip else "null")
    first = start(name + "_first", first_command + "reset role;" + hash_sql)
    wait(name + "_first", "state='idle in transaction'")
    second = start(name + "_second", second_command + "reset role;" + hash_sql + "commit;")
    wait(name + "_second", "wait_event_type='Lock'")
    a, b = finish(first, "commit;"), finish(second)
    (ROOT / (name + ".json")).write_text(json.dumps([a, b], indent=2), encoding="utf-8")
    check(a["code"] == 0 and b["code"] == (3 if error else 0), "unexpected results: " + str([a, b]))
    if error:
        check(error in b["err"], "unexpected error: " + b["err"])
    before = [line for line in a["out"].splitlines() if line.startswith("HASH|")][-1]
    after = run(helpers + hash_sql).splitlines()[-1]
    check(before == after, "reopening changed protected state")
    if skip:
        response = [json.loads(line) for line in b["out"].splitlines() if line.startswith("{")][-1]
        check(response == dict(inquiry_id=run("select %s;" % ident("inquiry", skip)), status="following_up"),
              "wrong reopening response")
    print("PASS|" + name + "|actual Lock wait|exit=" + str(a["code"]) + "/" + str(b["code"]), flush=True)


try:
    run("begin;" + fixture + "commit;")
    race("double_reopen", actor(3) + reopen(4), actor(3) + reopen(4), "22023: inquiry is not closed")
    race("reject_reopen", actor(1) + resolve(17, False), actor(2) + reopen(17), skip=17)
    race("confirm_reopen", actor(1) + resolve(18, True), actor(2) + reopen(18), skip=18)
    race("deactivate_reopen", "update public.profiles set is_active=false where id=%s;" % ident("actor", 2),
         actor(2) + reopen(5), "42501: inquiry reopening access denied")
    check(run("select count(*) from public.inquiry_status_history where inquiry_id=%s and to_status='following_up';" % ident("inquiry", 4)) == "1", "duplicate history")
    check(run("select status from public.inquiries where id=%s;" % ident("inquiry", 5)) == "closed_without_sale", "deactivated actor reopened inquiry")
    inquiry_ids = ",".join(ident("inquiry", i) for i in range(1, 21))
    vehicle_ids = ",".join(ident("vehicle", i) for i in range(1, 21))
    check(run("select count(*) from public.confirmed_sales where inquiry_id in(%s);" % inquiry_ids) == "3", "confirmed ledger changed")
    check(run("select count(*) from public.vehicles where availability_status='sold' and id in(%s);" % vehicle_ids) == "3", "Sold inventory changed")
    (ROOT / "summary.json").write_text(json.dumps(dict(database=DB, waits=waits), indent=2), encoding="utf-8")
    print("PASS|four races and terminal invariants", flush=True)
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
