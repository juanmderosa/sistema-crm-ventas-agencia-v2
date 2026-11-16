# Private bound invitation resend preparation

`prepare_bound_staff_invitation_resend(p_request_id uuid, p_invitation_id uuid,
p_actor_id uuid) returns jsonb` is executable only by `service_role`.
A future trusted backend must derive the actor from verified authentication,
never a browser-supplied UUID. This is authorization/bookkeeping, not delivery.

## Contract (S1–S5)

- Match the existing invitation advisory namespace and actor SHARE lock order.
  Check current active management authority before disclosing invitation state:
  Owner may manage Admin/Seller; Admin may manage Seller only.
- Require an existing pending, non-revoked invitation with a non-null bound UUID
  and provenance. Reject permanent completion even without a remaining profile.
  Never reserve provenance or bind an identity implicitly.
- Derive provenance privately and reuse `prepare_staff_invitation_identity` for
  authoritative normalization, permissions, Auth markers and identity validation.
  Both returned UUIDs must equal the existing binding. Any existing profile,
  active or inactive, fails closed. Confirmed and unconfirmed passwordless pending
  identities qualify without changing UUID, invited role or activation state.
- Return exactly the helper's canonical private JSON: `invitation_id`, `email`,
  `role`, `provenance`, `user_id`, `candidate_user_id`. No confirmation timestamp,
  mutable confirmation flag or first/retry indicator is included.
- Record one `bound_resend` row in the existing request journal. Exact retries
  revalidate current authority and identity before returning, without writes.
  Changed actor, invitation or action under a shared request UUID is rejected
  across old/new commands. A journal failure rolls back the entire statement.

The action CHECK is extended additively; legacy management inputs and function
bodies remain unchanged. Legacy create/resend still reject an Auth match before
returning retries. Legacy revoke remains available for bound invitations.
Existing Spanish argument, authorization, collision, missing/revoked invitation
and identity-verification errors are reused, with SQLSTATE 22023/42501/23514.

## Evidence and limits

Durable SQL-role checks: `supabase/tests/0041_staff_invitation_bound_resend_test.sql`.
See [verification history](testing.md#bound-invitation-resend-preparation-t3b3a).
The private payload is not a public DTO or permission to create/send. SQL request
idempotency does not guarantee exactly-once email. No Auth/provider/HTTP/mail call,
password update, profile activation or role change is implemented here. Provider
delivery and actual transport proof remain separate work. T5 remains blocked;
S6/S7 and the full invitation journey are not completed or waived.

## Trusted current-actor service (T3b3b1, S1–S5)

Server-only `createInvitationManagementService(config, fetcher)` exposes only
`prepareBoundResend({ requestID, invitationID, actorAccessToken })`. The token must
come from trusted server-session integration. No caller actor UUID, role, email,
JWT decoding or metadata is authoritative. Configuration is captured at construction;
input primitives are captured before awaiting. Fixed origins and credentials use
onboarding's validation rules; each request rejects redirects and has a fresh,
cleared 10-second deadline covering fetch and response consumption.

1. GET `/auth/v1/user` uses the ordinary API key and caller bearer token. Only a
   successful User object's top-level UUID authenticates the actor.
2. POST `/rest/v1/rpc/prepare_bound_staff_invitation_resend` uses only service-role
   credentials, with exactly `p_request_id`, `p_invitation_id`, `p_actor_id`.
   SQL remains the current active-role authority after the namespace wait.
3. `{ ok: true, code: "prepared", preparation }` means private preparation only.
   Its frozen six-key payload validates invitation UUID, canonical email,
   Admin/Seller role, provenance UUID and equal non-null user/candidate UUIDs.
   This root-canonical reply is **not a public DTO**. A future public route needs
   a separate fixed acknowledgement, never serialization of this private result.

Failures return only `{ ok: false, code }`: `invalid_input`,
`authentication_failed`, `denied` (recognized SQLSTATE 22023/42501/23514 in a 4xx
response), or `preparation_uncertain`. After RPC dispatch, lost/invalid responses,
timeouts and unrecognized errors are uncertain: the journal **may have committed**.
There is no automatic retry, no no-effect promise, no delivered claim and no email
guarantee. Credentials and raw provider errors are never returned. Invalid input
and failed authentication make no privileged request. No Auth mutation, link,
recovery, mail, HTTP route or new session platform is added. S4's full resend and
T5/S6–S7 remain incomplete; existing SQL proof is not replayed by this unit.
