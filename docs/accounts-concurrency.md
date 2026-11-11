# Account lock regression checks

## Run only on an owned local stack

```text
python -B scripts/test-accounts-concurrency.py
```

Use the parent's authorized Python 3.13.7 executable and process-local PATH for
Docker 29.9.2 and pnpm 10.18.3. Node 24 and the repository's installed Supabase CLI
are prerequisites inherited from the existing HTTP harness. The writer performed
static checks only. Parent job-5 executed all three scenarios successfully in
1 minute 2 seconds; explicit wait/release markers and final-state assertions
passed, and the owned disposable resources were removed.

The default command owns **one** uniquely named disposable project. It reuses
unchanged `http_test_support.DisposableStack`, cached-image preflight, migration
copying, context-manager teardown, `owned_context` and `local_origin`. It never
selects the shared development stack. Child modes `--races` and `--http` require
the generated temporary project binding; they are private IPC, not operator modes.
Do not supply an existing workdir or credentials. No installs, remote targets,
email sending or Auth-internal writes occur.

The runner imports `Probes` and fixed-label assertions from
`scripts/test-accounts-http.py` instead of copying its Auth, `NoRedirect` HTTP,
SQL capture and protected-data snapshot implementation. Requests use the exact
owned loopback origin, disable proxies and reject redirects. Supported Auth admin
HTTP creates confirmed synthetic users; password grants and `/auth/v1/user`
verify real JWT identities. Secrets travel through private stdin/captured stdout,
never command-line arguments or printed provider diagnostics.

## Three bounded scenarios

1. **Competing initial Owner finalizations (T2, S1–S2).** Two exact, confirmed
   synthetic Auth identities concurrently call the service-only public
   `bootstrap_initial_owner` RPC with finalization enabled. Both must be observed
   waiting on the existing last-active-Owner advisory namespace before release.
   Exactly one response must be HTTP 200 `created`; the other must be HTTP 400,
   SQLSTATE `23514`, `owner bootstrap is unavailable`. The public profile response
   must contain exactly the winning active Owner and expected display name. The
   database must contain exactly one profile, no invitation intent/history, and
   unchanged complete Auth user/identity hashes and all other public tables.
   Both original passwords must still authenticate their original UUIDs.
   No Owner guard is disabled, no Owner is deleted and no reset is used.
2. **Admin deactivated while waiting (T3b, S2/S5).** The initial synthetic Admin
   profile is the only privileged fixture insert: there is no profile-creation
   public API. Auth supplies the verified actor UUID. Its service-only public
   invitation-intent RPC waits on the invitation advisory namespace. The genuine
   Owner JWT uses the existing direct PostgREST profile PATCH to deactivate that
   Admin, and a public read confirms the state. Only then is the protected-data
   snapshot taken, before explicit release. The RPC must return HTTP 403,
   SQLSTATE `42501`, `No tiene permiso para gestionar esta invitación.` All public
   rows and protected Auth rows must equal that post-deactivation snapshot;
   invitation and successful-request history counts remain zero.
3. **Admin demoted while waiting (T3b, S2/S5).** Only the Owner's existing public
   PATCH reactivates the same Admin. The same observed invitation wait is repeated
   with new request/intent IDs. Owner PATCH demotes the actor to Seller before the
   snapshot/release handshake. The exact same denial and zero-mutation assertions
   apply. The original actor JWT remains Auth-valid; the Owner remains active.

The invitation RPC intentionally uses service-role authorization, not the Admin
JWT: its existing grant is trusted-server-only. The runner derives the actor UUID
from supported Auth verification, then supplies it to that public command. Owner
profile changes use the actual Owner JWT. No grant is broadened and no internal
business helper is invoked to simulate the rule.

## Synchronization, deadlines and diagnostics

A controlled interactive Docker `psql` transaction takes the exact advisory lock
and emits a private ready marker/backend PID. A bounded SQL observer joins
`pg_stat_activity` and waiting/granted `pg_locks` entries, matches the single-bigint
namespace key, active RPC query and blocker PID, and requires one or two distinct
waiting backends as appropriate. Only observed waits authorize the explicit
COMMIT/release acknowledgement. Elapsed delay or an unrelated provider error is
never accepted as race evidence.

The observer has a six-second deadline, a ten-second statement timeout and a
20ms local synchronization polling interval; this is not background-job polling
or an arbitrary sleep used to manufacture overlap. The holder has a ten-second
statement timeout and 45-second idle-in-transaction failsafe. Holder ready/release
handshakes have 12-second process deadlines. Existing HTTP requests have 20-second
transport timeouts; HTTP subprocess capture has a 45-second deadline and response
collection is bounded to 50 seconds. Existing SQL/status probes retain their
60-second subprocess deadlines. The owned scenario child is bounded to 240
seconds; unchanged stack startup/teardown CLI calls retain 240-second deadlines.

Subprocess exit, stdout and stderr are captured privately. HTTP children must exit
zero, emit exactly one canonical JSON response and no stderr. Ready/release and
wait markers are asserted; SQL failures and timeouts are fatal. Only fixed
PASS/FAIL labels leave the scenario child. Provider bodies, credentials, emails,
SQL payloads and raw subprocess errors are never printed. Timeout paths stop and
drain owned children; the stack context manager still owns teardown. If teardown
fails, the printed generated project identity is the cleanup boundary; do not
inspect or stop unrelated projects.

## Evidence boundary

This verification-only increment adds no application behavior and has no meaningful
missing-behavior RED/GREEN cycle. Worker validation is compile-only plus whitespace
inspection; actual integration passed in parent job-5. S1–S5 coverage is
partial: these races strengthen S2/S5 and existing T2/T3b locking claims, not the
entire lifecycle. S3 activation/password proof and S4 verified pending-identity
reuse remain outside this intent-only slice. Same-email collisions, all other
possible races, mail, acceptance, UI, clock expiry and recovery are not tested
here. S6–S7/T5 session revocation stays deferred: no session writes, bans or
claims that JWTs were revoked. Risk item 2 is privileged credential isolation;
risk item 4 is the requirement for actual observed concurrency evidence.
