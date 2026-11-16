# Staff invitation intents

## Delivery boundary

This is an **intent-only database contract**, not a usable invitation journey.
Migration `20261107110000_staff_invitation_intents.sql` creates private intent and
successful-request history with one service-only command. No HTTP endpoint, mail,
Auth account creation, password changes, identity binding or activation exists.
There is deliberately no activation RPC. No profile is created, including inactive
profiles: pending intents cannot enter existing staff authorization or routing.

Coverage against `odd/tasks/accounts-access.md`:

| Spec | Delivered here | Still pending |
|---|---|---|
| S1 | Invitation persistence/security sub-slice | HTTP, Auth and mail orchestration |
| S2 | No existing function, policy or profile changes; private service boundary | Live permissions and concurrency proof |
| S3 | Pending intents grant no operational profile/access | Accepted identity plus durable password proof and verified completion |
| S4 | Same intent on resend, exact retries, pending uniqueness, explicit new action after revocation, existing-identity conflict | Verified binding/reuse of the same pending Auth identity and partial-state recovery |
| S5 | Current active Owner invites Admin/Seller; active Admin invites Seller; no Owner invitations | Server authentication and endpoint integration |

S6/S7 deactivation/session revocation remains explicitly deferred, not weakened.

## Trusted command

`manage_staff_invitation_intent(p_request_id uuid, p_invitation_id uuid,
p_actor_id uuid, p_action text, p_email text, p_role public.user_role) -> uuid`

Only `service_role` has execution permission. None of the three API roles has
invitation table grants. There are no invitation RLS policies. The definer has an
empty search path and uses schema-qualified application relations.

The future server must verify the actor through Auth and derive `p_actor_id` from
that authenticated result, **never from a submitted actor ID**. Possessing the
service credential is the trust boundary; this RPC cannot authenticate that ID.
Do not expose the RPC as an arbitrary browser-to-service proxy.

Email must already be trimmed lowercase, at most 254 characters, with the same
basic email shape used by bootstrap. IDs are explicit UUIDs; no counters exist.
Every call, including a retry, checks the current actor's DB role and active flag.

| Action | Contract |
|---|---|
| `create` | New invitation ID and request ID; reject another pending intent for that email. Never silently reuse it or change its role. |
| `resend` | Existing pending invitation ID, exact email/role, new request ID. Records intent only; sends nothing. |
| `revoke` | Existing pending invitation ID, exact email/role, new request ID. Retains the intent and successful command history. Does not deactivate any account. |
| exact retry | Same request, invitation, actor, action, email and role returns the invitation UUID without additional writes, subject to current authorization and state checks. |

A revoked intent cannot be retried as create or resend. Only the exact previous
revoke request can repeat successfully. A new explicit `create` uses **both new
IDs** and leaves the revoked record intact. Changing the requested role through a
resend or retry is rejected; a separate explicit action is required.

Create/resend reject any matching `auth.users.email` or Auth identity email,
including active profiles, inactive profiles, linked identities and Auth-only
orphans. This is deliberately conservative: an email match is not provenance.
If Auth is created after an intent, even its original create/resend retry fails
closed. Revocation is still available. This slice therefore MUST NOT be used to
create Auth users yet; it cannot safely recover that partial state. No Auth row is
written, deleted, repassworded or adopted.

## Serialization and future completion

All commands acquire `hashtext('public.staff_invitation_intents')` as a transaction
advisory lock before reading invitation/request state, then lock the actor profile
`FOR SHARE`. This intentionally serializes all intents, including cross-email ID
collisions, rather than introducing multiple lock orders. Actor authorization is
read after waits and held until commit. Use short READ COMMITTED transactions.
The existing last-Owner/bootstrap namespace is untouched: this flow writes no
profiles and must not acquire that lock before actor rows. Existing profile-update
RLS and last-active-Owner protection remain unchanged.

The advisory lock does **not** reserve an Auth email or coordinate independent Auth
operations. A future privileged Auth phase must recheck actor authorization after
waits, prove exact intended user and email identity ownership, record immutable
provenance and reuse that identity on verified retries. Never adopt an unrelated
or ambiguous Auth-only account. Do not automatically delete or reset identities.
Completion needs a trusted authenticated acceptance session and durable evidence
that a password was established for that intended identity. Mutable user metadata,
a caller boolean, an arbitrary user ID or a nonempty password hash alone is not
that evidence. Until that contract is implemented and proven against the actual
Auth version, activation must remain unavailable. Future profile creation must
reuse existing Owner/bootstrap/profile invariants and appropriate lock ordering.

## Private completion primitive (T3b1)

`complete_staff_invitation(p_invitation_id uuid, p_user_id uuid,
p_display_name text)` is service-only. It uses the existing invitation advisory
namespace and immutable pending-identity binding, checks confirmed email and
server provenance, and atomically inserts the active invitation-role profile and
permanent completion marker. Names must be nonblank and at most 200 characters.
No direct API-role grants expose the completion table.

Exact retries preserve the original name and identity without restoring later
profile role/activation changes. Changed-name retries reject. A revoked pending
invitation cannot create a profile; accepted completions are not undone by later
revocation. Failed completion-marker insertion rolls back profile creation.

This primitive trusts the server to verify the acceptance session and successful
password update for the bound UUID before calling it. The approved sequence is
confirmed password update followed by awaited private completion; interruptions
resume through recovery without an operational profile. Neither a password hash
nor caller assertions establish that evidence. No browser endpoint currently
exposes completion; actual acceptance/password/resend/mail remain separate work.
T5 session revocation remains deferred.

The parent isolated suite passed 2164 assertions across 39 files. Independent
private-primitive probes passed 109 assertions / 42 outcomes, and separately NEW
durable regressions passed 258 assertions / 76 outcomes, including rollback and
four observed-lock races. These are SQL-role/synthetic checks, not genuine
Auth/JWT onboarding proof. Earlier failures remain in the feature task log.

## Verification status (original intent slice)

`supabase/tests/0037_staff_invitation_intents_test.sql` uses synthetic fixtures and
transaction rollback, public RPC calls, exact SQLSTATE/message assertions and
rejection hashes of public/Auth tables. It covers role permissions, collisions,
retries, revoked history, partial-state denial, pending staff predicates and the
existing direct profile-update/last-Owner contracts. Successful intent operations
also preserve all non-invitation public/Auth rows.

The full isolated database suite, including this file, passed **1854/1854 across
37 files**. An earlier run failed on invalid fixture-query syntax; three queries
across the two new test files were corrected without changing business behavior.
Both disposable projects were removed; the shared development stack was untouched.
Independent source inspection found no concrete blocker, but it did not execute SQL.
Genuine Auth/PostgREST permission checks, actor deactivation/demotion during lock
waits, competing same-email/ID commands and rollback races remain unverified.
Actual acceptance, password establishment, identity reuse, mail and activation
remain unimplemented and require the next slice. Passing intent tests does not
establish an end-to-end invitation journey.
