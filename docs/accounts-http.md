# Disposable account HTTP verification

Status: parent executed the runner successfully against genuine local Auth; exit 0
in 1 minute 52 seconds. Both owned disposable projects were removed. The writer
performed static checks only; observed integration evidence comes from parent job-4. This is a
verification-only unit for accounts/access T2 and T3a, S1–S2 and recovery S6.
It changes no application behavior, grants, Auth internals or shared harness.
There is no meaningful new business-behavior RED/GREEN cycle: static compilation
and whitespace checks validate authoring, not actual provider compatibility.
Risk: item 2, credentials and authorization.

## Run after review

From the repository root, with the parent-authorized process-local tool PATH:

```text
C:/Users/juanm/AppData/Local/Programs/Python/Python313/python.exe -B scripts/test-accounts-http.py
```

Requires Node 24, installed repository pnpm/Supabase tooling, Docker and cached
images. The approved local versions are Python 3.13.7, pnpm 10.18.3, Docker 29.9.2,
Postgres 17.11.0.011, GoTrue v2.197.0, PostgREST v16.5 and Kong 2.8.1. The runner
uses the existing helper's CLI-version/cached-image preflight, not a hardcoded
alternate image installation. No network fetch, dependency installation, system
PATH modification, shared reset or remote target is part of this command.

Run without `HTTP_JWT_WORKDIR`. The default owns **two sequential independent
stacks**, never two concurrently: Auth-only recovery first, fresh provisioning
second. Bootstrap intentionally refuses any existing Owner, so deleting an Owner
to reuse a stack would give dishonest coverage. No identity/profile is deleted.
Each scenario starts with zero Auth users and zero profiles and fails otherwise.
Expect two full stack startups/migration applications; the observed run took
1 minute 52 seconds including teardown.
Each child has a 600-second timeout, startup uses the helper's 240-second timeout,
and helper teardown has its own finite timeout. Do not impose a shorter external
kill timeout that prevents the parent process from running owned teardown.

`DisposableStack` copies only the existing migrations/tests and patched local
config into a generated system-temp `http-jwt-<16 hex>` project. It checks cached
images and removes only that project's containers, volumes, network and generated
temporary directory in its context-manager teardown, including failed children.
The bounded child launch follows `isolated_run`'s environment/cwd/ownership
convention but adds a finite subprocess timeout (the unchanged convenience
function has none). Child mode accepts only the scenario arguments plus the
strict `owned_context` workdir/project/config/context binding. It is an internal
protocol, not an option for selecting an existing stack or arbitrary URL.

The generated project name is printed for cleanup diagnosis; it is not a secret.
If teardown fails or the controlling process is forcibly killed, the parent must
inspect and resolve **only that reported owned project** using the established
helper conventions. Never reset/stop an unrelated project to recover a test.

## Observed assertions (successful isolated run)

| Scenario | Observable checks |
|---|---|
| Auth-only partial state | Supported Auth admin user creation and password grant; implicit adoption exits 1 with exact fixed stderr and empty stdout; unchanged all-public/Auth-identity digest; original UUID/password still work. |
| Explicit conflict | A second synthetic Auth identity supplies a genuinely conflicting UUID. Service RPC must return HTTP 400, SQLSTATE `23514`, exact `conflicting bootstrap identity`; CLI must reject with exact output and unchanged protected digest. |
| Controlled repair | Service-only read-only preflight returns `auth_only`; `--recover` uses the explicit verified UUID without an initial password; exact success exit/stdout/stderr; exactly one active Owner profile with expected UUID/name. |
| Independent fresh creation | Preflight returns `missing`; actual no-option bootstrap creates one genuine Auth identity and its matching active Owner profile; password grant succeeds. |
| Routine reruns, both stacks | Service preflight specifically reports `owner bootstrap is unavailable`; no-option and explicit recovery CLI invocations fail with exact exit/stdout/stderr; protected data/identity counts stay unchanged; original password works and attempted replacement fails with `invalid_credentials`. |
| HTTP grants, both stacks | Anon and genuine authenticated JWT cannot execute bootstrap RPC; service cannot read or generically insert profiles. Exact 401/403 + `42501`, never an unrelated network/provider error, and unchanged protected digest. Successful service preflights/finalizations prove the narrow allowed path. |
| Recovery token and password | Supported admin `POST /auth/v1/admin/generate_link`, type `recovery`, yields a privately captured `hashed_token`. Node 24 invokes the unchanged TS service over real HTTP; an observing native-fetch wrapper verifies actual `/verify` recovery type, successful `/user` update and `/logout?scope=global` 204. |
| Session revocation | Every password session issued earlier in the scenario is retained, including two explicitly distinct pre-recovery sessions, plus the consumed recovery session. Every issued old refresh credential must fail refresh after global logout with HTTP 400 and `refresh_token_not_found` or `refresh_token_already_used`. Old password fails specifically with `invalid_credentials`; new password signs in to the same UUID. |
| Invalid and replayed recovery | Random hash before recovery, consumed hash after recovery, and another random hash must return service `invalid_recovery` with an actual Auth 403 `otp_expired`, no update/logout requests, and unchanged public/Auth-identity digest. New password still signs in afterward. |

The Node wrapper observes real responses, not mocked successes. It captures the
recovery session's refresh credential privately so even that session is checked.
Refresh assertions cover every credential issued by this scenario, not arbitrary
unobserved sessions. Public tables and `auth.users`/`auth.identities`
are digested read-only through Docker psql; provider session/audit bookkeeping is
excluded. No SQL writes, Auth-schema mutation or grant bypass occurs. Profile
attributes are checked through the genuine Owner JWT. Password preservation and
change are checked through actual password grants, not password-hash inspection.

## Secret handling and failure behavior

All requests target the helper-validated **exact** `http://127.0.0.1:<owned port>`
origin. Python disables proxy discovery and redirects with `NoRedirect`; Node
uses the existing service's redirect refusal and finite request timeout. Python
HTTP requests have a 20-second timeout; SQL has 60 seconds, bootstrap subprocess
90 seconds, recovery subprocess 60 seconds. Unexpected transport failures abort;
they never count as expected rejection.

Supabase status JSON, subprocess output, admin responses, generated links,
credentials, emails, passwords and token payloads are captured and never printed.
Synthetic bootstrap inputs are supplied through a private child environment with
explicit target equal to the owned API origin. Inherited bootstrap variables are
removed before constructing that environment. Recovery inputs go through private
stdin, not command-line arguments or temporary files. The small static Node
program on the command line contains no credential values. Only fixed assertion
labels, counts implicit in scenario completion, project identity and fixed failure
messages are logged. Subprocess warnings/errors are captured, not forwarded;
local privileged processes can still inspect environment/IPC. Avoid command
tracing, HTTP debugging and provider request-body logging while running this test.
Exceptions are redacted, so the last failed fixed assertion is the primary failure
location; do not print raw provider diagnostics to investigate.

## Deliberate limits

- No actual email is sent: never invoke `/recover` or the service's `request`.
  Admin-generated local links test token consumption, **not** mailbox delivery,
  mailbox ownership, callback allowlists, templates, UI, HTTP handlers or routes.
- Provider field/status/error expectations passed against local GoTrue v2.197.0.
  This establishes observed compatibility for these checks, not hosted delivery
  or compatibility with every future Auth release. No provider source was fetched
  by this verification writer.
- Expired-by-clock tokens, SMTP suppression observation, recovery network/update/
  logout failure injection, full linked/ban/SSO conflict matrix and actual
  overlapping bootstrap finalizations are not covered by this runner. Existing
  offline/pgTAP evidence is separate; it cannot fill missing live proof.
- No invitation behavior or T5 deactivation/session integration. Global logout
  revokes refresh sessions; it does not cryptographically invalidate issued JWTs.
- This runner does not repeat the SQL suite, builds or independent verification.
  This successful run does not close the entire accounts/access feature.

Operator/core contracts: [Owner bootstrap](owner-bootstrap.md),
[password recovery](password-recovery.md), [permissions](permissions.md).
