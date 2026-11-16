# Private staff invitation completion regression contract

These are **NEW repository-resident tests**, not recovered historical probe bytes.
They exercise `20261107130000_staff_invitation_completion.sql` through the public
SQL-role interface. No product migration or shared harness changes are included.

## Safe syntax-only spot check

From the repository root (this mode cannot start Docker or a database):

```bash
'/c/Users/juanm/AppData/Local/Programs/Python/Python313/python.exe' -B scripts/staff_completion_probe/main.py --syntax-only
```

For the bounded live run, prerequisites are Python 3.13, existing Node/pnpm and
Docker, four cached Supabase images, and at least 1 GiB free system-temp space.
No installs, image pulls, shared reset or real users are authorized. The runner
rejects inherited `HTTP_JWT_WORKDIR`, compiles every module before setup, uses
source-relative SQL, and reuses `http_test_support.DisposableStack` ownership,
cached-image checks and cleanup unchanged. Run only with explicit authorization:

```bash
export PATH='/c/Users/juanm/AppData/Local/pnpm:/c/Users/juanm/AppData/Local/Programs/DockerDesktop/resources/bin':"$PATH"; unset HTTP_JWT_WORKDIR; '/c/Users/juanm/AppData/Local/Programs/Python/Python313/python.exe' -B scripts/staff_completion_probe/main.py
```

`--group functional` selects only functional cases in a fresh owned stack; the
other choices are `permissions`, `rollback`, and `races`. It is an optional focused
interface, not permission for another run. SQL and subprocess deadlines are finite.
No credentials, fixture identifiers or raw database diagnostics are printed.

## Four groups

1. Admin/Seller role retention, permanent completion, read-only exact retries,
   changed-name denial, demotion/deactivation preservation, nonblank/200/201 name
   boundaries, null/wrong UUIDs, revoked and missing-provenance rejection.
2. Actual anon/authenticated completion denials and all four completion-table
   operation denials for anon/authenticated/service_role, followed by trusted success.
3. Owned-database completion-insert failure injection, exact failure and atomic
   profile/completion rollback; injection removed before concurrency cases.
4. Four explicit PID/advisory-Lock hold/wait/release schedules: completion retry,
   revocation wins, completion wins, and deactivation before completed retry.

Every rejected/read-only command checks exact SQLSTATE/message/result, exit 0
for the error-capturing SQL transport, empty stderr, all public-table plus
`auth.users`/`auth.identities` row counts/hashes, and public/Auth sequence
`last_value`/`is_called`. Expected SQL exceptions are captured, not suppressed;
wrong messages or successful forbidden operations fail the test. Race baselines
include the winner's uncommitted final state before release. Polling observes an
actual named waiter, exact advisory namespace and blocking holder PID; elapsed
sleep is never evidence. Public intent/prepare/bind/revoke operations are reused;
profile updates and profile reads use the authenticated Owner SQL-role interface.
Synthetic Auth rows are fixtures, not genuine JWT/password proof.

## Trust boundary and evidence

Completion is a service-only primitive. A future trusted server must verify
invitation acceptance and successful password setup for the exact bound UUID
before invoking it. This probe cannot establish those preconditions. Actual
Auth/JWT, acceptance/password, mail/resend, browser and onboarding remain unclaimed;
T5 session revocation remains deferred and native review remains parent-owned.

No meaningful business RED applies: these new regressions target an existing
passing implementation. No RED/GREEN evidence is fabricated. The first authorized execution (L75) exited **1**
in top-level preflight: stdout was `PASS complete-source compile and entrypoint
gate`; stderr was `FAIL completion probe: RuntimeError`. It stopped before the
payload/dependencies/capacity success marker, cached-image checks, helper imports,
stack setup and fixtures. The generic diagnostic does not identify the precise
precondition that failed. No setup retry or relaunch was performed.

| First attempt (L75) | Assertions | Outcomes | Protected checks | Waits |
|---|---:|---:|---:|---:|
| Functional (not reached) | 0 | 0 | 0 | 0 |
| Permissions (not reached) | 0 | 0 | 0 | 0 |
| Rollback (not reached) | 0 | 0 | 0 | 0 |
| Races (not reached) | 0 | 0 | 0 | 0 |

At that stop, all new live proof remained missing. Compile/entrypoint checks
passed separately and again in the failed runtime command. No stack, Docker resource, scratch
project or fixture was created, so there was no owned cleanup to perform.
**Zero test-code corrections were used.** No product change or repeated
independent verification occurred. L76 separately authorizes preparation correction and one new bounded functional
execution, with at most one subsequent test-code correction. The Bash invocation
above now uses POSIX `/c/...` PATH entries rather than drive-letter components.
Only fixed prerequisite categories are exposed by preflight diagnostics. The prior
generic failure does not establish which prerequisite failed; its evidence is
preserved, not retroactively diagnosed. New execution results follow below.

## New observed execution (L76)

The corrected full invocation above exited **0**, with **258 assertions / 76
checked command outcomes**. Counts include checked public fixture operations;
they are not comparable one-for-one with the historical independent probe.

| Group | Assertions | Outcomes | Protected checks | Waits |
|---|---:|---:|---:|---:|
| Functional | 107 | 31 | 16 | 0 |
| Permissions | 66 | 18 | 14 | 0 |
| Rollback | 15 | 5 | 1 | 0 |
| Races | 70 | 22 | 4 | 4 |
| Total | 258 | 76 | 35 | 4 |

All 35 rejected/read-only state comparisons preserved counts/hashes for **27
tables (25 public plus two Auth)** and both public/Auth sequences, including
`last_value` and `is_called`. No sequence gap was observed. All fourteen actual
42501 permission denials passed. The injected P0001 failure rolled back profile
and completion; its trigger/function were removed before the race group.

Four advisory Lock waits were observed in order: completion/exact retry,
revocation-winning denial, completion-winning revocation, and deactivation before
completed retry. Each required the named waiter's PID, exact namespace and
blocking holder PID before explicit commit/release. Numeric PIDs were checked
inside SQL but not printed or retained. Every release and process outcome passed;
no timeout or deadlock occurred. The completion-winning revocation changed only
the permitted intent/request tables and preserved every sequence.

Preparation was verified separately, without database startup:

```bash
export PATH='/c/Users/juanm/AppData/Local/pnpm:/c/Users/juanm/AppData/Local/Programs/DockerDesktop/resources/bin':"$PATH"; unset HTTP_JWT_WORKDIR; '/c/Users/juanm/AppData/Local/Programs/Python/Python313/python.exe' -B -c "import sys; sys.path.insert(0, 'scripts/staff_completion_probe'); import main; main.preflight(); main.cached_preflight()"
```

That command exited 0: payload 519150 bytes, free scratch 140760907776 bytes,
required executables resolved and all four cached images inspected. The full
run rechecked preparation (140758503424 free bytes), compiled complete sources,
and used only owned project `http-jwt-ef00da30b8ed44aa`. DisposableStack confirmed
owned container/volume/network removal and removed its scratch project. No new
scratch or cache remains. **Zero subsequent test-code corrections were used.**
Only main.py preparation diagnostics and this document changed in L76; public
operation assertions and shared helper/product bytes were not modified.

S1–S5 evidence is limited to T3b1: S2 permissions/integrity, S3 private completion
boundary, S4 permanent exact retries/revocation and S5 Admin/Seller retention.
This is not proof of actual acceptance/password setup or full S3 onboarding.
The syntax-only command remains the safe parent spot check; no functional repeat
is implied. `git diff --check` passed with only the existing tracker LF/CRLF
warning. The first L75 exit-1 command used the incorrect Bash PATH form:

```bash
env -u HTTP_JWT_WORKDIR PATH="C:/Users/juanm/AppData/Local/pnpm:C:/Users/juanm/AppData/Local/Programs/DockerDesktop/resources/bin:$PATH" "C:/Users/juanm/AppData/Local/Programs/Python/Python313/python.exe" -B scripts/staff_completion_probe/main.py
```

Historical parent SQL **2164 assertions / 39 files** and independent **109
assertions / 42 outcomes** are separate reported evidence, not execution of these
new source bytes. The earlier missing scratch and failed attempts remain in
`odd/tasks/accounts-access.md`; nothing here recovers or supersedes them.
