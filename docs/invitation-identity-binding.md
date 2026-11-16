# Pending invitation identity binding

**SQL implementation ready; functional GREEN is still pending.**
This T3b sub-unit covers S1–S5 of `odd/tasks/accounts-access.md`: reserve trusted
creation provenance, recover a verified pending Auth candidate, and bind its exact
UUID without creating a staff profile. Migration
`20261107120000_staff_invitation_identity.sql` adds the private binding table and
two service-only RPCs. It does not implement an invitation journey.

## Trusted server sequence (orchestration not implemented)

1. Authenticate the actor through Auth; derive the actor UUID server-side. Create
   an intent through the existing `manage_staff_invitation_intent` command.
2. Generate a fresh UUID provenance server-side, never from browser input. Call
   `prepare_staff_invitation_identity` before creating Auth. Persist/reuse that
   exact provenance on retries; it cannot change or belong to another intent.
3. If no candidate exists, use the supported Admin create operation, rejecting an
   existing email rather than updating/adopting it. Set both `raw_app_meta_data`
   keys `staff_invitation_id` and `staff_invitation_provenance` atomically in that
   create call, as canonical UUID strings. Never use user metadata as provenance.
4. On a lost create response, prepare may return a verified `candidate_user_id`
   privately. Re-read the exact UUID through the Admin API before calling bind;
   neither an email search nor the marker alone proves acceptance or authority.
5. Bind that UUID with the reserved provenance. No activation, password reset,
   email delivery, operational access or assignment eligibility follows.

The marker correlates creation; it is not a password, role authority or acceptance
proof. The future server must keep service credentials and all returned fields
private. These RPCs trust their service caller to authenticate the actor and perform
the Admin re-read; SQL cannot prove that HTTP call occurred.

## SQL surface

| RPC | Return |
|---|---|
| `prepare_staff_invitation_identity(p_invitation_id uuid, p_actor_id uuid, p_provenance uuid)` | `jsonb` with exactly the six keys below |
| `bind_staff_invitation_identity(p_invitation_id uuid, p_actor_id uuid, p_user_id uuid, p_provenance uuid)` | Bound UUID |

Prepare returns `invitation_id`, canonical `email`, intent `role`, reserved
`provenance`, nullable `user_id`, and nullable `candidate_user_id`. UUIDs are JSON
strings; absent UUIDs are explicit JSON nulls. Before Auth creation both user fields
are null. Verified candidate recovery sets only `candidate_user_id`; after binding
both fields contain the same UUID. Preparing/recovering never sets `bound_at`.
An exact prepare or bind retry performs no writes.

The additive private table is `public.staff_invitation_identity_bindings`, keyed
by `invitation_id`, with unique non-null `provenance`, nullable unique `user_id`
and nullable `bound_at`. The latter two are set together only after verification.
Binding is immutable: same UUID/provenance may retry; replacement is forbidden.
Revocation retains this row and all intent/request history. No API role, including
`service_role`, receives direct table access; only service gets RPC execution.
No existing function, Auth table, profile privilege or policy is changed.

## Verification and authorization rules

Both RPCs acquire the existing transaction advisory lock
`hashtext('public.staff_invitation_intents')`, then read/hold the actor profile
`FOR SHARE`. Recheck current authorization after waits, including retries. Active
Owner may bind Admin/Seller; active Admin may bind Seller. Seller, inactive and
absent actors are denied. There is no Owner invitation. No bootstrap/last-Owner
namespace is acquired; use short READ COMMITTED transactions. The intent is also
held `FOR SHARE`. Prepare locks related Auth users in UUID order `FOR UPDATE`,
then their identities and conflicting email identities in UUID order `FOR SHARE`,
and validates fresh reads after waits. The user lock blocks FK-backed insertion
of profiles/identities for that UUID through finalization. Bind reuses prepare's
verification and held locks rather than implementing a second verification path.
These row locks do not reserve an absent Auth email or serialize independent
Auth writers creating other UUIDs; the trusted creation protocol is still required.

The intent must exist and remain pending. Reserve before binding. An existing Auth
match before reservation fails closed even if it already carries matching markers;
a reservation must precede trusted creation. Verify the exact canonical Auth
UUID/email and BOTH exact app markers, not email or user metadata alone. Reject deleted, currently banned, anonymous, SSO or pending-email-change
users. Require exactly one identity, an email-provider identity with exact email,
provider UUID and subject UUID matching the user. Reject linked providers,
ambiguous email matches, conflicting identity emails, reused markers on other
users and any existing profile, active or inactive. Unconfirmed/passwordless Auth
is allowed because this unit does not activate anyone. Revalidate on every call,
including after binding; reject conflicts without changing any stored rows.

## Stable errors

Application errors use these exact SQLSTATE/message pairs. Validate null required
arguments first; after acquiring locks authorize before disclosing identity data.
Then check missing/revoked intent, reserved provenance, immutable bound UUID, and
Auth verification. Thus replacing a bound UUID is rejected before inspecting the
replacement Auth user. A reused provenance on another intent is a provenance error.

| SQLSTATE | Message | Condition |
|---|---|---|
| `22023` | `Datos de vinculación inválidos.` | Null required UUID argument |
| `42501` | `No tiene permiso para gestionar esta invitación.` | Current actor/target-role denial |
| `23514` | `La invitación no existe.` | Unknown intent |
| `23514` | `La invitación fue revocada. Cree una nueva invitación.` | Revoked intent, even on exact retry |
| `23514` | `Prepare la identidad de la invitación antes de vincularla.` | Bind without reservation |
| `23514` | `La procedencia no coincide con la invitación.` | Changed or cross-intent reused provenance |
| `23514` | `La identidad vinculada no coincide con la solicitud.` | Attempt to replace a bound UUID |
| `23514` | `La identidad de la invitación requiere verificación.` | Any Auth/profile/identity/marker conflict |

PostgreSQL grant denials retain their native `42501` function/table messages.
Neither RPC returns candidate details on rejection.

## Proof boundary and next step

`supabase/tests/0038_staff_invitation_identity_test.sql` uses synthetic Auth fixture
writes, actual SQL roles, public RPC calls, exact JSON/UUID/error assertions,
full-public/Auth-row rejection hashes and final retained-history counts. All state
rolls back. Tests were authored before migration and remain unchanged. Parent
observed genuine missing-function RED in disposable job-7: all 37 prior files
passed 1854 assertions, then 0038 passed four prerequisite intent assertions and
aborted at line 88 because `public.prepare_staff_invitation_identity(uuid,uuid,uuid)`
did not exist. The overall run failed with no final TAP plan for 0038; owned
resources were removed. `public.bind_staff_invitation_identity(uuid,uuid,uuid,uuid)`
was also absent. Parent-owned GREEN job-8 then passed **2149/2149 assertions across
38 files**, including unchanged 0038, with exit0 in43 seconds and owned resources
removed. Static source inspection alone is not that executed SQL evidence.

These tests do not prove supported Admin create semantics, Admin UUID re-read,
real JWT/HTTP permissions, overlapping lock waits or concurrent Auth mutations.
Independent owned-stack verification subsequently passed with **56 observed PASS
assertion labels and zero FAIL labels**. It exercised supported Admin creation and
UUID re-read, candidate recovery/binding/retry, real anon/authenticated denials,
rejection hashes and current authorization after an observed advisory wait. The
owned stack was removed. Concurrent unrelated Auth mutations remain untested;
these live checks do not turn SQL fixtures into provider evidence. See the following
proof unit's `docs/invitation-binding-http.md` for exact boundaries and preserved
failed attempts. Existing intent/profile tests remain untouched.
`manage_staff_invitation_intent` stays unchanged: even a bound Auth identity still
causes conservative create/resend rejection. A later explicit bound-identity
delivery operation is required; this is not a complete reinvitation flow.

Acceptance sessions, password establishment, activation, authentication routes,
real email and browser flows remain unimplemented. S3 is protected negatively by
absence of profiles/access; S4 gains only the identity binding/reuse primitive, not
end-to-end delivery. S6/S7 and T5 deactivation/session revocation remain deferred.
