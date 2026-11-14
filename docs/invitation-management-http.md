# Genuine bound-resend preparation proof

Run with Node 24, native Python 3, Docker, cached Supabase CLI dependencies and
all four cached images; no installation or image pull is authorized:

```sh
node --check scripts/invitation-management-bridge.mjs
python -B -m unittest discover -s scripts -p test_invitation_management_http_unit.py
python -B scripts/test-invitation-management-http.py --help
python -B scripts/test-invitation-management-http.py
node --test apps/backoffice/features/accounts/invitations/management.test.ts
```

The default invocation creates and removes one isolated synthetic project through
unchanged `DisposableStack`. It rejects inherited `HTTP_JWT_WORKDIR` and all
arguments except `--help`. CLI resolution uses the existing repository ROOT,
not a dependency copy. Setup failure stops without relaunch or test-success claims.
The bridge imports the actual management service and fixes its method; bounded
stdin carries credentials and the expected six-field payload, never arguments,
environment variables, files or output. Independent native-temp project/config/
context and exact `127.0.0.1` origin checks precede every forwarding request.

Twelve cases cover Owner/Admin role combinations, Seller/no-profile denial,
caller and native metadata role forgery, malformed printable JWT, explicit retry,
an issued JWT after routine Admin deactivation, and committed RPC reply loss
followed by explicit retry. The observer forwards genuine User GET and private
RPC POST only. It reports status/order and credential/actor/redirect/deadline
booleans; canonical equality and frozen preparation are checked inside Node.
No response, UUID or private payload is replaced with expected fixture data.

Each case compares all public tables, Auth users/identities and all public/Auth
sequence positions using unchanged `state.sql` and strict `state_matches(..., None)`.
Success permits only the journal table to change and separately requires exactly
one requested invitation/actual actor/`bound_resend` row and every old row unchanged.
Denied calls and retries preserve all protected state and counters. Sessions and
Auth audit rows are excluded; no equality claim covers them. All identities and
sessions exist before snapshots. Reply loss consumes the real HTTP 200 body
before throwing; it proves uncertainty, not delivery or automatic retry safety.

Observed owned run: 12/12 genuine cases, 60/60 behavior checks, 12 service calls,
12 User GETs, 11 private RPC POSTs and 12 strict protected comparisons passed.
Coverage was 27 tables and two sequences; four exact journal insertions were
observed, including reply loss. The owned resources and directory were removed.
Offline guards passed 3/3 after missing-interface RED; one first-GREEN failure
was the known Node module-type warning, corrected without suppressing warnings.
The unchanged management suite passed 57/57. No live correction was needed.

This supports S1–S5 preparation only. Existing SQL-role 216-assertion evidence is
separate. Full S4 delivery, mail/browser journeys and T5/S6–S7 remain unproved and
blocked/pending as tracked; this does not replay the closed onboarding proof.
