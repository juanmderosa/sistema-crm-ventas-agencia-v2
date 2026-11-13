# Actual invitation service: owned local Auth proof

This NEW durable capability invokes `createInvitationOnboardingService` from
`apps/backoffice/features/accounts/invitations/invitations.ts`, not a Python
reimplementation. Scoped local proof passed after the single justified L100 test
correction:196 assertions,14 service calls,14 protected comparisons and11 old-refresh
rejections. Earlier failures are preserved below. Historical service22/32 and
independent two boundary probes are separate evidence, not these retained bytes.

## Safe checks

From the repository root, without Docker startup:

```bash
node --check scripts/invitation-onboarding-bridge.mjs
'/c/Users/juanm/AppData/Local/Programs/Python/Python313/python.exe' -B -m unittest discover -s scripts -p test_invitation_onboarding_http_unit.py
'/c/Users/juanm/AppData/Local/Programs/Python/Python313/python.exe' -B scripts/test-invitation-onboarding-http.py --help
node --test apps/backoffice/features/accounts/invitations/*.test.ts
pnpm --filter @dealership/backoffice test
pnpm --filter @dealership/backoffice typecheck --incremental false
```

## Bounded live invocation

Requires explicit authorization, Node24, Python3, existing pnpm/Docker, cached
Supabase images and at least 1GiB native temporary space. No installation, pull,
shared reset, existing-stack option or arbitrary API/module argument is supported.
This command is documentation, not permission to rerun:

```bash
export PATH='/c/Users/juanm/AppData/Local/pnpm:/c/Users/juanm/AppData/Local/Programs/DockerDesktop/resources/bin':"$PATH"; unset HTTP_JWT_WORKDIR; '/c/Users/juanm/AppData/Local/Programs/Python/Python313/python.exe' -B scripts/test-invitation-onboarding-http.py
```

The runner rejects inherited `HTTP_JWT_WORKDIR` even with child-like arguments.
It reuses unchanged `DisposableStack`, `owned_context`, `local_origin`, and
`test-accounts-http.py` primitives; only its freshly created context is bound.
The bridge independently checks the exact native-temp project/config/port and
imports a fixed repository module. Credentials, hashes and synthetic personal
fixtures travel only through private stdin/environment; subprocess output is
captured and never echoed. Node observes native fetch with redirect errors and
the service's finite timeouts. Python uses the existing no-proxy/no-redirect client.
No mail delivery or SQL Auth writes occur. Read-only protected inspection reuses
`scripts/staff_completion_probe/state.sql` unchanged.

## Cases and evidence boundary

| Group | Required observations |
|---|---|
| roles | Bound Seller/Admin, no prior profile, same UUID password login, permanent completion, consumed replay denial |
| invalid | Validation before credentials, invalid hash, invite hash rejected on recovery path, no password/completion request |
| denials | Genuine verified identity differs from binding, revoked pending intent; preflight400 before password, logout204, no application mutation |
| interruption | Explicit throw BEFORE completion fetch, after real password200/logout204; uncertainty, no profile, two real password sessions, same-UUID recovery, every observed old refresh rejected |
| lost_response | Explicit throw AFTER completion200 commits; uncertainty with existing profile; recovery exact retry preserves later Owner name update and single completion/identity |

No fake successful provider response is injected. The two faults are transport
uncertainty tests, not crashes or provider outages. Native responses, order and
status are checked exactly. Invalid/consumed hashes must yield403/otp_expired;
old refresh credentials must yield400/refresh_token_not_found or
400/refresh_token_already_used. Already-issued JWTs are not cryptographically
invalidated by this evidence.

Snapshots cover every public table, Auth users/identities and public/Auth sequence
positions. Rejections without verification preserve everything. Consuming genuine
tokens may change Auth bookkeeping; denied transitions must preserve all public
tables/counters. Success changes exactly profiles/completions, with Auth metadata
allowed separately. Recovery retries must leave every application table unchanged.
Auth session/audit bookkeeping is deliberately not equated with application state.

The retained `boundaries.test.ts` adapts the supplied independent equivalent with
repository import and a five-second per-test timeout. It proves captured config,
explicitly gated fifth-request cleanup, six original-origin/credential calls and
2048-character hash/200-Unicode-codepoint name limits for both methods. It is NEW
retained code, not historical source recovery. Business RED is inapplicable to
proof of the already implemented service; the new deterministic invocation guards
observe missing-runner RED before implementation.

## Original execution record (L98, preserved failure)

The documented live invocation exited **1** on its first protected-state
comparison, after a genuine Seller acceptance returned `{ok:true}`. No live
correction or second stack was attempted. Setup itself succeeded. Native temp
capacity was140545941504 bytes; copied migration/test payload was538353 bytes.
Node24, tools, compile gate and cached-image preparation passed before probes.

| Group | Attempted assertions | Passed | Failed | Service calls | Protected checks passed | Refresh rejections |
|---|---:|---:|---:|---:|---:|---:|
| roles (stopped during Seller) | 15 | 14 | 1 | 1 | 0 | 1 |
| invalid (unrun) | 0 | 0 | 0 | 0 | 0 | 0 |
| denials (unrun) | 0 | 0 | 0 | 0 | 0 | 0 |
| interruption (unrun) | 0 | 0 | 0 | 0 | 0 | 0 |
| lost_response (unrun) | 0 | 0 | 0 | 0 | 0 | 0 |

The reused harness separately passed three setup assertions: initially empty
accounts/profiles, exact bootstrap exit/stdout/stderr, and genuine Owner session.
Snapshot coverage was27 tables (25 public and two Auth) and two sequences.
Observed actual-service order was verify200, user GET200, preflight200, password
PUT200, global logout204, completion200. The consumed verification session's old
refresh credential then failed with400/refresh_token_not_found. Fault injection
was **not** used in this executed call. Bridge exit0 had captured stderr present;
its private contents were not forwarded. Known offline Node module-type warnings
remain visible separately; captured bridge stderr was not classified.

Failure label: `FAIL protected tables and counters match allowed effects`.
The initial run did not emit safe changed-table/counter indicators, so the exact
mismatched component is **not established**. Do not infer a product defect or
claim protected-state success for that run. The then-current check compared Auth sequences too;
genuine provider bookkeeping is a possible diagnostic avenue, not a proven root
cause. One post-run diagnostic-only edit adds fixed numeric difference flags;
it does not relax the assertion and has not been live-executed. No product,
service, SQL or shared-helper correction was made.

Final Seller profile/password-login/permanent-record assertions, Admin acceptance,
replay, denials, interruption/recovery and lost-response cases are **unrun**.
Their source presence is not evidence. S1–S5/S6 live proof remains partial; in
particular no same-UUID password login or recovery-session guarantee is claimed
from this run. The observed refresh rejection is limited to the single consumed
invite session, not all recovery credentials or JWT invalidation.

Owned project `http-jwt-6b76976550704fba` was stopped with the unchanged helper;
container/volume/network label checks found none, and its native-temp project
folder was removed. `Disposable HTTP/JWT resources removed.` was observed. No
scratch/cache was left in the working tree; pre-existing `.worktrees/` and the
parent's task-document changes were preserved untouched.

Offline evidence: guard missing-runner RED (FileNotFoundError, exit1), then guards
4/4 GREEN; compile(), bridge `node --check` and harmless help all exit0. Retained
invitation tests24/24 and combined backoffice34/34 passed with existing Node
module-type warnings. Initial bare `pnpm --filter @dealership/backoffice test`
exited127 (`pnpm: command not found`); prepending the documented authorized PATH
made that check pass. With the same PATH, strict typecheck using
`pnpm --filter @dealership/backoffice typecheck --incremental false` exited0.
No production build, full SQL suite, old proof cycle or independent review reran.
The guards and compile gate were checked again after the diagnostic-only edit.

L100 separately authorizes the same writer on failed/incomplete and unrun cases,
maximum ONE justified test-correction batch and up to TWO new owned stacks only
as needed to diagnose and revalidate it. This does not reset the original failed
attempt or authorize product/helper/SQL changes, closed proof sweeps or dropped
invariants. Setup failure, product finding, a second distinct test defect or spent
limits require stopping. Diagnostic instrumentation is part of this bounded effort.
The safe parent spot check is bridge syntax plus offline guards; the live command
above is a bounded contract, not open-ended permission for further attempts.

### L100 continuation preparation

Before the first new stack, diagnostics now print exact sanitized schema/table/
sequence names with changed/equality/direction flags only. Assertions are unchanged.
A genuine Owner password grant provides a separate provider-operation control;
read-only `pg_get_serial_sequence` checks the refresh counter's ownership. Neither
observation was assumed to justify a correction before actual evidence.

### L100 new stack 1: component diagnosis (preserved failure)

Project `http-jwt-cf49786fa97246af`, exit1: roles14PASS/1FAIL, one service call,
one consumed-refresh rejection, zero passed protected comparisons. Other groups
remained unrun. Native temporary free space140558102528 bytes; payload538353.
Setup passed; all owned Docker resources and the temporary project were removed.

Sanitized evidence at the failed comparison:

| Component | Observed flags |
|---|---|
| auth.identities | changed1, allowed1, count_equal1 |
| auth.users | changed1, allowed1, count_equal1 |
| public.profiles | changed1, allowed1, count_equal0 |
| public.staff_invitation_completions | changed1, allowed1, count_equal0 |
| auth.refresh_tokens_id_seq | equal0, direction=forward, called_equal1 |
| public.inquiries_creation_sequence_seq | equal1, direction=equal, called_equal1 |

Exactly two expected public tables and two allowed Auth tables changed; unexpected
tables0. The sole failing conjunct was sequence equality. Supported Owner password
grant control changed auth.users without changing its count and initialized the
same Auth sequence (`equal0/direction=other/called_equal0`); public sequence stayed
equal. Read-only `pg_get_serial_sequence('auth.refresh_tokens','id')` confirmed
ownership of `auth.refresh_tokens_id_seq` (ownership_matches1). The Seller service
again observed verify200/user200/preflight200/password200/logout204/completion200,
with consumed refresh400/refresh_token_not_found. This demonstrates a test-model
issue: a real Auth session allocates its provider-owned refresh counter.

### Single justified correction

Old expectation required every public/Auth sequence unchanged even after genuine
provider session issuance. New expectation retains all table allowances and exact
public-table effects and checks every sequence. Only auth.refresh_tokens_id_seq
must advance strictly with both is_called flags true **when that specific service
observation contains verify200 plus confirmed consumed-refresh400 rejection**.
All other counters remain equal. Without that observed provider context (including
invalid input/token and replay), the Auth counter must remain equal too. Sequence
ownership is rechecked and enforced on each stack. No global ignored counters,
product change or dropped application invariant is introduced.

Deterministic guard RED: missing state_matches, AttributeError, exit1. GREEN6/6
checks contextual forward-only behavior, invalid/no-provider strict equality,
backward/is_called rejection, unchanged public counters and table restrictions.
This is the ONE authorized logical correction batch; diagnostic instrumentation
belongs to the same bounded effort. No second correction was used.

### L100 new stack 2: corrected incomplete and pending cases

Project `http-jwt-8252851aaaf3413c`, **exit0**. Node24/tool/syntax/cached-image
preparation passed; native temp free140552396800 bytes, payload538353 bytes.
The independent provider-operation control and sequence-ownership check repeated
with the same flags. Complete-source compile and offline guards6/6 passed before
setup. No full application tests, typecheck/build or closed SQL proof reran.

| Group | Assertions passed | Failed | Service calls | Protected comparisons | Old-refresh rejections |
|---|---:|---:|---:|---:|---:|
| roles | 52 | 0 | 4 | 4 | 2 |
| invalid | 30 | 0 | 3 | 3 | 0 |
| denials | 40 | 0 | 2 | 2 | 2 |
| interruption | 42 | 0 | 3 | 3 | 4 |
| lost_response | 32 | 0 | 2 | 2 | 3 |
| Total | 196 | 0 | 14 | 14 | 11 |

Three reused setup assertions passed separately; they are not included in196.
All five originally incomplete/unrun groups now executed. No runtime assertion
failed in this stack and no further test-code correction was made. The two newly
authorized stacks and ONE correction allowance are spent; no further run is
implied. The L98 original failure and L100 diagnosis remain failed attempts,
not retroactive passes.

Both Seller/Admin invitations had no prior profile, completed on the bound UUID,
retained their authorized role and exact submitted name, and supported genuine
password login on that same UUID. Read-only inspection found one permanent
completion/profile/Auth user/email identity per completed fixture. Consumed invite
replays returned exact invalid_token with403/otp_expired and no password/completion.
Invalid input returned exact invalid_input with zero service requests. Invalid
hash and invite hash on recovery path returned invalid_token with403/otp_expired;
all protected state/counters remained equal in those no-provider-effect cases.

Mismatched verified identity and revoked pending invitation each observed
verify200/user GET200/preflight400/logout204; exact preflight_rejected, no password
or completion request, no profile, and every public table/counter unchanged.
Auth users/identities metadata changes and the specifically verified provider
session counter were permitted separately, not reported as unchanged Auth state.

Before-request interruption observed real verify200/user200/preflight200/password
PUT200/logout204, then an explicit throw before completion fetch. Exact result was
completion_uncertain; no profile or application mutation existed. Two distinct
genuine password sessions proved password persistence while still nonoperational.
A generated recovery token (without mail) completed on the same UUID with a new
password; the old password then failed400/invalid_credentials. Both pre-recovery
refresh credentials and the consumed recovery credential failed400/
refresh_token_not_found. Consumed recovery replay failed403/otp_expired without
password/completion or protected-state mutation.

Lost-response injection forwarded a real completion200 before discarding its
response and throwing; exact completion_uncertain coexisted with an active profile
and permanent completion. The Owner then changed the profile name through its
existing PATCH interface (204). A genuine recovery token with the ORIGINAL name
completed the exact retry, preserved the later name and every application row,
and retained exactly one completion/profile/Auth identity. Its previous password
session and consumed recovery session refresh credentials failed400/
refresh_token_not_found. No mocked provider successes or SQL Auth writes supplied
any of these observations; SQL was read-only protected-state inspection.

Successful full service calls checked native order/status exactly:
verify200, user GET200, preflight200, password PUT200, logout204, completion200.
All11 old-refresh checks returned400/refresh_token_not_found (eight consumed
verification sessions, two interrupted pre-recovery sessions, one lost-response
password session). No refresh_token_already_used outcome was observed. Issued JWTs
were not claimed cryptographically invalidated. Every bridge returned exit0 with
captured stderr present; private stderr remained unclassified and unforwarded.

All14 protected comparisons covered27 tables and two counters. First completion
changed exactly profiles/completions among public tables; interruption and denied
transitions changed no public tables; the completed retry preserved all public
rows including the later profile name. Every public inquiry sequence comparison
was equal. Only a real verify200/confirmed-refresh-rejection context permitted the
schema-owned Auth refresh counter to advance; invalid/replay/input cases required
its equality. Auth user/identity tables stayed within each operation's explicit
allowlist; no session/audit rows were misrepresented as application state.

Unchanged DisposableStack stopped project `http-jwt-8252851aaaf3413c`, confirmed no
owned containers/volumes/networks, removed its native-temp folder, and printed
`Disposable HTTP/JWT resources removed.` No scratch/cache remains in the worktree.
No runtime checks in the bounded five groups remain unrun. Historical failed
commands remain separately recorded; full application tests/typecheck/build were
not rerun because source service, recovery and boundary tests were unchanged.

Scoped S1/S2 proof now links real provider operations to authoritative SQL without
unrelated public mutation. S3 proves no pending/interrupted profile and activation
after confirmed password/cleanup. S4 proves same-UUID recovery, replay/revoked
denial and permanent exact retry preserving later profile changes. S5 proves
Seller/Admin role retention, not a new exhaustive actor-permission cycle. S6 proof
covers observed recovery refresh revocation only; T5 direct-deactivation effects
remain separately pending. Handlers, resend, mail and UI remain unimplemented here.
Native review/commit/feature-wide completion are not inferred from these checks.

Handlers, resend, external mail, browser/UI and separately reactivated T5 remain
out of scope. Native review/candidate disposition remain parent-owned; no native
approval is claimed here. This cohesive proof capability exceeds the advisory
400-line review budget; it was not compressed or split by file type to hide load.

## Independent offline verification and retained contracts

Independent verification passed bridge syntax, six runner guards, 24 invitation
mocks, 34 combined mocks, 32 baseline mocks and three pure-data invariant probes.
No live runner, provider request, database stack or repository write occurred;
196 live assertions remain the separately recorded writer execution above.
No concrete blocker or correction request was found. Service/helper/snapshot/SQL
identity checks passed before and after the offline inspection.

The supplied pure-data probes are now retained as
`scripts/test_invitation_onboarding_state_contract_unit.py`: exact public effects,
unchanged schema inventory and both specific observations for the provider-counter
exception. They add regression coverage, not a second expectation correction.
Parent bridge syntax and all nine offline guards passed on retained sources. No
live attempt, old suite replay or budget replenishment is implied. Native candidate
assessment and acknowledgement remain parent-owned.
