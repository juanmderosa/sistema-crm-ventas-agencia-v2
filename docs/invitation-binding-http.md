# Invitation binding HTTP probe: observed Auth and permission verification

This persistent Python payload prepares bounded T3b/T4 checks for S1–S5
in `odd/tasks/accounts-access.md`. Following the L52-approved table-error hint
contract correction, the original independent verifier executed the same scenarios
successfully: **exit 0, 56 observed PASS assertion labels, zero FAIL labels**.
All stages, including authenticated denials and actor-wait, completed. The owned
stack was removed. Writers performed only offline checks; this live evidence
comes from the independent verifier, not mocks or inferred readiness.

## Evidence boundary

The earlier parent SQL result, **2149/2149 across 38 files**, is separate evidence.
The prior independent attempt failed during stdin/heredoc preparation before any
stack or probe: zero probes, no complete persisted payload. This script neither
repairs/retries that invocation nor accesses its scratch. It resets no correction,
verification or native-review budget. Static compilation/help do not prove Auth
compatibility, HTTP grants, provenance or current-actor behavior after a lock wait.

The later persisted-file execution failed with exit 1. Captured child observations
were swallowed, so readiness, probe count and failure stage remain unknown for
that attempt; no live pass or zero-probe claim follows. Owned removal was reported.
The diagnostic repair preserves both failures and the original scenarios.

The subsequent L47 run reached stack-ready with 35 observed PASS labels and one
FAIL: anonymous binding-table GET matched HTTP 401 but failed the exact error-body
comparison. At that checkpoint the differing field was unknown; authenticated
and post-wait checks were not reached. This was not a zero-probe run or a complete live pass.
L51 subsequently isolated only a non-null hint; its actual type/value stayed hidden.
It did not establish that the hint was text. Earlier attempts and budgets remain
separate; that checkpoint did not satisfy the newly approved live contract.
The later successful run does not retroactively pass any failed attempt.

Offline mocked-runner tests exercise diagnostic RED/GREEN only, not business or
integration RED/GREEN. Acceptance, password establishment, activation, delivery,
routes/browser journeys and feature closure remain pending. T5 and session
revocation remain explicitly deferred; the race checks operational authorization
only, not revocation semantics.

## Safe inspection now

From the repository root, the authorized preparation checks are:

```bash
C:/Users/juanm/AppData/Local/Programs/Python/Python313/python.exe -B scripts/test_invitation_binding_runner.py
C:/Users/juanm/AppData/Local/Programs/Python/Python313/python.exe -B -c "compile(open('scripts/test-invitation-binding-http.py', encoding='utf-8').read(), 'scripts/test-invitation-binding-http.py', 'exec')"
C:/Users/juanm/AppData/Local/Programs/Python/Python313/python.exe -B scripts/test-invitation-binding-http.py --help
```

Help exits before helper imports, environment inspection, Docker or Auth access.
These checks create no bytecode, stack or provider fixtures. Tests replace the
helper module, stack, subprocess, environment and streams with offline mocks.
The script accepts no
external URL, credential, email, user ID or other arbitrary target arguments.

## Observed same-scope live command

The original verifier ran this persisted file under L52 authorization after parent
validation and confirmation of tools/cached images on its process-local PATH.
This documented command grants no new execution, retry or cross-target authority:

```bash
C:/Users/juanm/AppData/Local/Programs/Python/Python313/python.exe -B scripts/test-invitation-binding-http.py
```

One default invocation owns exactly one generated disposable stack. It reuses
unchanged `http_test_support.py` ownership, exact loopback validation and cleanup;
dynamically imports existing `Races` and its existing HTTP `Probes`. The internal
`--owned-binding` mode requires the strict generated `owned_context`; it is not an
operator target mode. Startup uses cached images only. The child deadline is
240 seconds, HTTP calls 20 seconds, SQL 60 seconds, and existing lock observation
has a six-second deadline with explicit holder release and a 45-second idle
failsafe. Existing CLI startup/teardown bounds apply separately; 240 seconds is
not a total wall-clock guarantee. Cleanup touches only generated owned resources,
including after child timeout/failure; teardown failure reports its owned project.
Do not run against the shared development stack or launch another verifier as
part of this preparation.

The successful independent run exercised these child checks:

- Trusted initial Owner CLI and genuine session plus Auth `/user` verification;
  actor UUIDs derive from verified Auth, not submitted claims.
- Public service intent creation, stable provenance reservation/retry, supported
  Admin passwordless/unconfirmed creation with both app markers and exact UUID
  Admin re-read, candidate recovery, binding and unchanged-state same-UUID retry.
- No pending operational profile; unrelated and user-metadata-only identities
  rejected with exact SQLSTATE/message and unchanged protected-data hashes.
- Anonymous and genuine authenticated callers denied both RPCs and binding-table
  reads with exact HTTP status, SQLSTATE, message, details and key set; only the
  table error permits a present null-or-text hint. Rejection hashes were unchanged.
- A new prepare request through `ThreadPoolExecutor` and `p.call` directly, held
  in the shared invitation namespace until the matching waiter is observed.
  Owner PATCH deactivates the verified synthetic Admin before snapshot/release;
  prepare must return exact `403`/`42501` denial and preserve the post-PATCH hash.

Only the synthetic Admin profile fixture uses public-table SQL setup because no
profile creation API exists. Auth identities use supported Admin operations only;
SQL hashes/synchronization were confined to the same owned stack. No Auth-schema
DML, SMTP, external mail, real accounts, reset, acceptance or activation is used.
Provider JSON, keys, passwords, tokens and emails remain in private memory,
environment/stdin or captured subprocess channels. Transport failures fail the run
rather than counting as denials. The successful run reported child exit 0 and
stderr absent; its 56/0 counts are recognized assertion labels, not a total probe
count or evidence for unexecuted acceptance/activation/delivery scenarios.

## Safe diagnostic contract

The wrapper emits `STAGE stack-startup` before entering the existing stack and
`STAGE stack-ready` only after readiness. Child markers identify `probe-init`,
`owner-bootstrap`, `binding`, `identity-rejections`, `api-boundaries`, `actor-wait`
and `complete`. They change no provider request or assertion. Captured output is
forwarded only when the entire line equals a fixed stage, a fixed trusted harness
`PASS`/`FAIL` assertion label, or a fixed HTTP category plus integer status 100–599.
Unknown text and raw stderr are never forwarded. Categories never include URLs,
UUIDs, emails or provider messages; the call observer returns the original response
and forwards identical call arguments exactly once.

`DIAGNOSTIC child exit=<integer> stderr=present|absent` reports process metadata;
`DIAGNOSTIC failure=startup|child|child-timeout|teardown` classifies wrapper failure.
Timeouts report `timeout=240 exit=unavailable` and stderr presence without command,
exception text or private output. Recognized partial timeout output is filtered
through the same exact vocabulary. Existing cleanup and success/failure criteria
remain unchanged, including rejection of exit-zero children with nonempty stderr.

`OBSERVED assertion-labels pass=<integer> fail=<integer>` counts only recognized
captured labels, not executed probes or completed scenarios. Zero observed labels
does not prove zero executed probes; absence of a stage does not prove that phase
never began. Captured child records become visible when the child exits or times
out, not as a live stream. Existing owned project diagnostics remain available.
Help still exits before helper/provider initialization.

On a failed exact denial comparison only, `ENVELOPE` reports these fixed ordered
0/1 flags: `status_match`, `body_object`, `keys_match`, `code_match`,
`details_present`, `details_match`, `hint_present`, `hint_match`, `message_present`,
`message_match`. Presence distinguishes an absent field from explicit JSON null;
value matches require presence. The key-set flag compares against the entire
expected object without exposing actual key names. No actual values or provider
text are emitted. Forwarding requires a full-line match of this exact field order
and boolean grammar, rejecting appended text and malformed flags. Diagnostics
neither normalize responses nor continue after assertion failure. No calls are added.

## Approved private-table hint expectation

L52 explicitly permits only the private binding-table denial call to accept a
present `hint` of JSON null or text (including empty text). Both anonymous and
authenticated checks retain exact status, SQLSTATE, details, message and complete
key-set expectations, followed by unchanged protected-state hashes. Missing hints,
numbers, booleans, arrays, objects, extra keys or row data remain failures. RPC
denials retain the default exact response comparison, including `hint: null`.
No requests, roles, headers, scenarios, deadlines, cleanup or business SQL changed.
On table failures, `hint_match` reports this nullable-text predicate rather than
incorrectly blaming permitted text when a different field mismatches. Hint content
is never logged. The offline suite passed **13/13** and proves test-contract
behavior, not Auth behavior. The original verifier subsequently passed the complete
live permission and post-wait checks: both anon 401 and authenticated 403 table/RPC
denials preserved protected hashes; a real prepare waiter rejected the Admin after
the Owner's direct deactivation PATCH and explicit lock release. This checks
current authorization, not deferred session revocation. Acceptance, activation,
delivery, browser flows and complete account-feature closure remain pending.
