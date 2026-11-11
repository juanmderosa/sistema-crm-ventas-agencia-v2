# Initial Owner bootstrap

## Boundary

`scripts/bootstrap-owner.mjs` implements the initial Owner portion of accounts/access
S1–S2. It is a manual, trusted-environment tool, not a public route or invitation
flow. Approval of this mechanism does **not** authorize account creation, mail,
remote execution or deployment. Obtain separate authorization for the exact target
and intended account before running anything except `--help` or offline tests.

Requires Node 24 and migration
`supabase/migrations/20261107100000_owner_bootstrap.sql`. No packages or SDK are
needed. The tool uses Auth Admin HTTP and one bounded service-only PostgREST RPC;
it does not read profiles through REST or broaden table grants.

## Operator preparation

1. Confirm the target independently, the intended email and display name, and that
   this is initial provisioning, not replacement of a former Owner. An existing
   Owner profile, even inactive, requires separate exceptional resolution.
2. Use a trusted terminal without command tracing, HTTP debugging, session
   recording, credential-exporting crash reports or provider request-body logging.
   A service-role credential grants broad provider authority: the script's narrow
   requests do not reduce that credential's inherent permissions.
3. Supply the variables below through the trusted process environment or approved
   secret injection. Never put real values in command arguments, repository files,
   tickets, logs or shell history. Environment values are still visible to suitably
   privileged local processes. Clear them from the operator environment afterward.
4. Review help without contacting any provider:

   ```text
   node scripts/bootstrap-owner.mjs --help
   ```

| Environment variable | Requirement |
|---|---|
| `SUPABASE_URL` | Exact origin, without trailing slash, path, userinfo, query or fragment. HTTPS required except HTTP on `localhost` or `127.0.0.1`. |
| `OWNER_BOOTSTRAP_TARGET` | Independently confirmed origin, exactly equal to `SUPABASE_URL`. This guards accidental targeting, not authorization. |
| `SUPABASE_SERVICE_ROLE_KEY` | Target-specific privileged credential; never printed. |
| `OWNER_BOOTSTRAP_EMAIL` | Intended exact lowercase, trimmed email, maximum 254 characters. |
| `OWNER_BOOTSTRAP_NAME` | Nonblank display name, maximum 200 characters; surrounding whitespace trimmed. |
| `OWNER_BOOTSTRAP_PASSWORD` | New-account password, at least 12 characters; provider policy may require more. Not used or required in recovery. |
| `OWNER_BOOTSTRAP_USER_ID` | Required only for `--recover`: lowercase UUID independently verified against the intended Auth account. Must be absent for new provisioning. |

The commands below describe the workflow only; they are **not authorization to
execute it**. The no-option invocation is `node scripts/bootstrap-owner.mjs`.
Controlled recovery is `node scripts/bootstrap-owner.mjs --recover`.
No other options are accepted. `--help` must be used alone. Configuration errors
exit 1 before HTTP; help exits 0. All operational errors exit 1 with a fixed Spanish
message on stderr and empty stdout. Success exits 0 with exactly
`Dueño inicial aprovisionado correctamente.` and a newline on stdout, empty stderr.
No identity, email, password, credential or upstream error body is printed.

## New provisioning

Preflight rejects any Owner profile or conflicting intended profile/account. If the
email already exists, the tool refuses to adopt it implicitly. Otherwise it creates
one Auth identity using the explicit initial password and `email_confirm: true`
(no invitation or recovery email request), validates the returned identity, fetches
it again by UUID and finalizes its active Owner profile. This trusted manual flow
confirms email administratively; it does not claim mailbox-ownership verification.
The operator must independently establish the intended recipient before execution.

The final database check repeats all critical conditions under the **same**
`hashtext('public.profiles.last_active_owner')` transaction advisory lock as the
existing Owner guard, then inserts the profile in that transaction. Preflight is
not a reservation. Competing finalizations cannot both succeed. Existing role
policies, Auth links, timestamps and last-active-Owner triggers remain unchanged.
Only the narrow RPC is granted to `service_role`; anon/authenticated cannot call
it, and service-role profile REST reads and generic inserts remain denied.

## Auth-only partial recovery

Auth creation and PostgreSQL profile finalization are separate provider operations;
there is no distributed transaction. An interrupted request or failed finalization
can leave an Auth-only account. A concurrent losing bootstrap can also leave its
new identity without a profile. The script never retries automatically, deletes
identities, changes an existing password, reactivates staff or promotes an existing
profile. Never interpret failure as proof that Auth creation did not commit.

Before rerunning, independently inspect the provider's trusted administrative
interface and verify the **exact UUID and email** of the intended identity. Do not
choose a UUID just because an email looks familiar. If provenance is uncertain,
stop for manual resolution. Set `OWNER_BOOTSTRAP_USER_ID`, use `--recover`, and
leave the initial password unset. Recovery makes only preflight, exact UUID Auth
read and finalization RPC requests: no Auth creation/update/delete or mail action.

Both HTTP orchestration and database finalization reject mismatching identities.
Database finalization requires exactly one matching Auth user, exact canonical
email and explicit UUID, confirmed email, existing password, no pending email
change, deletion, active ban, anonymous/SSO account or linked/ambiguous identity.
There must be exactly one email-provider identity with the intended email and no
existing profile for the user. It rejects existing Owner profiles regardless of
activation; recovery after loss of all active Owners is a separate unresolved
operator decision, not an implied permission to take over an account.

If finalization fails or its response is lost, retain the identity and inspect
state before another authorized attempt. If an active Owner already exists, even
a retry for that same identity is refused rather than reported as a new success.
Do not delete accounts or disable guards to make a rerun pass. Credential rotation
and exceptional repair are outside this tool.

## Offline verification and remaining proof

```text
node --test scripts/bootstrap-owner.test.mjs
node scripts/bootstrap-owner.mjs --help
git diff --check
```

The Node suite injects synthetic HTTP responses and asserts exact public results,
request shapes/order, unchanged mock state on rejection, preserved Auth-only state
on partial failure, and absence of password updates, deletions and mail requests.
It cannot prove provider behavior, actual mail suppression, grants or concurrency.

`supabase/tests/0036_owner_bootstrap_test.sql` supplies rollback-only pgTAP fixtures
for a fresh isolated migrated database: actual function/table grants and denied
calls, exact identity conflicts, unchanged account-store hashes, read-only
preflight, active Owner finalization, routine retry rejection and preservation of
the last-Owner guard. It must not be pointed at a real dealership database.

The full isolated pgTAP suite, including this file, passed **1854/1854 across
37 files** after fixing fixture-query syntax. The initial run failed because
new fixture queries aborted before their TAP finish; that failure remains recorded
in `odd/tasks/accounts-access.md`. The shared database was not reset.
Genuine Auth/HTTP verification passed for fresh creation, explicit Auth-only
recovery, exact CLI outcomes, grants and rejection-state preservation in two owned
local stacks; see [account HTTP checks](accounts-http.md). Two real overlapping
finalizations also passed: both advisory waits were observed before explicit
release, exactly one Owner persisted, and the losing command preserved Auth and
unrelated public data; see [account races](accounts-concurrency.md).
Actual email suppression/delivery and the separate bootstrap-versus-Owner-management
race remain unverified. Sequential pgTAP fixtures and mocks do not prove those gaps.
