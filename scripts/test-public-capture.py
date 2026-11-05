#!/usr/bin/env python3
"""HTTP probe for the public vehicle-detail capture boundary (S21, T8).

Seeds published, draft and sale-blocked vehicle fixtures, spawns `next dev`
for apps/public on a free loopback port with the service-role key available
only to the server process, and asserts over real HTTP that:

  * a successful ficha load records exactly one view through an opaque
    httpOnly cookie token,
  * a repeat load inside the rolling 24-hour window records no second view,
  * a known bot User-Agent still receives the ficha but records no view,
  * draft, sale-blocked and unknown vehicles return 404 and record nothing,
  * the service-role key never appears in a response body.

Standard library only; no `.ps1` execution. The local stack must be running
(`pnpm db:start`). Fixtures and the spawned server are removed on exit.
"""

import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ROOT / "apps" / "public"
Pnpm = "pnpm.cmd" if os.name == "nt" else "pnpm"
PSQL = ["docker", "exec", "-i", "supabase_db_dealership-mvp", "psql", "-X", "-A", "-t",
        "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres"]

CHROME = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
GOOGLEBOT = ("Mozilla/5.0 (compatible; Googlebot/2.1; "
             "+http://www.google.com/bot.html)")

RESULTS = []
FAILURES = []


def check(name, ok, obs=""):
    line = "%s %s | %s" % ("PASS" if ok else "FAIL", name, obs)
    RESULTS.append(line)
    if not ok:
        FAILURES.append(line)
    print(line, flush=True)
    return ok


def sql(query):
    run = subprocess.run(PSQL, input=query, text=True, capture_output=True,
                         encoding="utf-8", timeout=60)
    if run.returncode != 0:
        raise SystemExit("SQL failed (%s)\n%s\n%s"
                         % (run.returncode, query[:300], run.stderr.strip()[:300]))
    return run.stdout.strip()


def events(vehicle_id):
    return int(sql("select count(*) from public.vehicle_view_events "
                   "where vehicle_id = '%s';" % vehicle_id))


def wait_for(predicate, timeout, interval=0.25):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def get(base, path, user_agent, cookie=None):
    request = urllib.request.Request(base + path, headers={"User-Agent": user_agent})
    if cookie:
        request.add_header("Cookie", cookie)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, response.headers, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, error.headers, error.read().decode("utf-8", "replace")


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def start_server(base, log_path, env_values):
    node = shutil.which("node")
    if not node:
        raise SystemExit("node not found on PATH")
    env = dict(os.environ)
    env.update(env_values)
    log = open(log_path, "w", encoding="utf-8")
    port = base.rsplit(":", 1)[1]
    process = subprocess.Popen(
        [node, str(PUBLIC / "node_modules" / "next" / "dist" / "bin" / "next"),
         "dev", "--hostname", "127.0.0.1", "--port", port],
        cwd=str(PUBLIC), env=env, stdout=log, stderr=subprocess.STDOUT)
    return process, log


def stop_server(process, log):
    if process is not None and process.poll() is None:
        if os.name == "nt":
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(process.pid)],
                           capture_output=True)
        else:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
    if log is not None:
        log.close()


def main():
    status = subprocess.run([Pnpm, "db:status", "-o", "env"], capture_output=True,
                            text=True, encoding="utf-8", timeout=180)
    raw_env = status.stdout + "\n" + status.stderr

    def var(name):
        match = re.search(r"^%s=(.+)$" % name, raw_env, re.M)
        if not match:
            raise SystemExit("missing %s in `pnpm db:status -o env` output" % name)
        return match.group(1).strip().strip('"')

    api, anon, service = var("API_URL"), var("ANON_KEY"), var("SERVICE_ROLE_KEY")

    published = sql("insert into public.vehicles "
                    "(brand, model, year, publication_status) "
                    "values ('CaptureProbe', 'Publica', 2024, 'published') returning id;")
    draft = sql("insert into public.vehicles "
                "(brand, model, year, publication_status) "
                "values ('CaptureProbe', 'Oculta', 2024, 'draft') returning id;")
    blocked = sql("insert into public.vehicles "
                  "(brand, model, year, publication_status, sale_enabled) "
                  "values ('CaptureProbe', 'Bloqueada', 2024, 'published', false) returning id;")
    ids = [published, draft, blocked]

    scratch = Path(tempfile.mkdtemp(prefix="public-capture-"))
    log_path = scratch / "next-dev.log"
    base = "http://127.0.0.1:%d" % free_port()
    process, log = None, None
    try:
        process, log = start_server(base, log_path, {
            "SUPABASE_URL": api,
            "SUPABASE_ANON_KEY": anon,
            "SUPABASE_SERVICE_ROLE_KEY": service,
        })
        ready = wait_for(lambda: probe_alive(base, "/"), timeout=120)
        check("dev server answers on a free loopback port", ready, base)
        if not ready:
            return 1

        # R1: a real browser load of a published ficha counts exactly one view.
        code, headers, body = get(base, "/vehiculo/" + published, CHROME)
        r1_body = body
        check("R1 successful ficha load returns 200", code == 200, code)
        check("R1 body renders the vehicle",
              "CaptureProbe" in body and "Publica" in body,
              " ".join(body.split())[:120])
        set_cookies = headers.get_all("Set-Cookie") or []
        token_cookie = next((c for c in set_cookies if c.startswith("bv_token=")), "")
        check("R1 mints an httpOnly opaque cookie token",
              bool(re.search(r"bv_token=[0-9a-f-]{36}", token_cookie))
              and "HttpOnly" in token_cookie,
              token_cookie[:90])
        check("R1 records exactly one view",
              wait_for(lambda: events(published) == 1, 15), events(published))

        # R2: the same token inside the rolling 24-hour window stays deduplicated.
        cookie = token_cookie.split(";")[0]
        code, _, _ = get(base, "/vehiculo/" + published, CHROME, cookie=cookie)
        check("R2 repeat load returns 200", code == 200, code)
        time.sleep(3)
        check("R2 duplicate load stays deduplicated", events(published) == 1,
              events(published))

        # R3: a known bot receives the ficha (the filter touches only the metric)
        # with a fresh token, so a missing filter would record a second view.
        code, _, body = get(base, "/vehiculo/" + published, GOOGLEBOT)
        check("R3 known bot still receives the ficha",
              code == 200 and "CaptureProbe" in body, code)
        time.sleep(3)
        check("R3 known bot records no view", events(published) == 1, events(published))

        # R4-R6: nothing outside a successful public load is captured.
        code, _, _ = get(base, "/vehiculo/" + draft, CHROME)
        check("R4 draft vehicle returns 404", code == 404, code)
        code, _, _ = get(base, "/vehiculo/" + blocked, CHROME)
        check("R5 sale-blocked vehicle returns 404", code == 404, code)
        code, _, _ = get(base, "/vehiculo/" + str(uuid.uuid4()), CHROME)
        check("R6 unknown vehicle returns 404", code == 404, code)
        time.sleep(1)
        check("404 loads recorded no views",
              events(draft) == 0 and events(blocked) == 0 and events(published) == 1,
              "draft=%d blocked=%d published=%d"
              % (events(draft), events(blocked), events(published)))

        # R7: the privileged credential stays server-side.
        check("R7 service-role key never appears in a response body",
              service not in r1_body and service not in body,
              "absent from browser and bot ficha responses")
        return 1 if FAILURES else 0
    finally:
        stop_server(process, log)
        if ids:
            quoted = ",".join("'%s'" % value for value in ids)
            sql("delete from public.vehicle_view_dedup where vehicle_id in (%s);" % quoted)
            sql("delete from public.vehicle_view_events where vehicle_id in (%s);" % quoted)
            sql("delete from public.vehicles where id in (%s);" % quoted)
        if FAILURES:
            print("scratch kept for diagnosis: %s" % scratch, flush=True)
        else:
            shutil.rmtree(scratch, ignore_errors=True)


def probe_alive(base, path):
    try:
        get(base, path, "public-capture-probe")
        return True
    except (urllib.error.URLError, ConnectionError, OSError, TimeoutError):
        return False


if __name__ == "__main__":
    code = main()
    print("%d checks, %d failures" % (len(RESULTS), len(FAILURES)), flush=True)
    if FAILURES:
        print("Public capture verification failed.", flush=True)
    else:
        print("Public capture verification passed.", flush=True)
    sys.exit(code)
