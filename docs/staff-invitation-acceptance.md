# Check the verified invitee before changing a password

`public.check_staff_invitation_acceptance` is a **service-only, read-only
preflight**, not an acceptance endpoint. It checks the exact bound UUID and
submitted name before future trusted server code changes a password. No Auth,
profile, invitation, history or counter data is written. Transaction locks are
not a reservation across HTTP calls.

## Required future server sequence

1. Verify the invitation or recovery token with the provider. Derive the UUID
   from that verified provider session, never a caller-submitted UUID. Supplying
   `p_user_id` to this RPC is **not proof of authentication**.
2. Validate the name/password and call the preflight for that exact invitation,
   verified UUID and name. Do not change a password if it fails.
3. Await a confirmed successful provider password update for the same identity.
4. Call the private `complete_staff_invitation` with the same UUID/name.
   Completion remains authoritative and revalidates current state transactionally;
   a successful preflight does not guarantee that later completion succeeds.

An interrupted attempt stays non-operational until completion. Resume through
recovery using the same identity, not a duplicate Auth account or temporary staff
profile. This unit implements none of these server/provider operations.

## RPC contract

`public.check_staff_invitation_acceptance(p_invitation_id uuid, p_user_id uuid,
p_display_name text) returns uuid`

| Parameter | Meaning |
|---|---|
| `p_invitation_id` | Exact existing invitation ID |
| `p_user_id` | Exact immutable bound ID, derived by the server from verified Auth |
| `p_display_name` | Non-null, nonblank, at most 200 characters; retained exactly, not trimmed |

Only `service_role` can execute. PUBLIC, `anon` and `authenticated` have no
execution grant; no table grants are added. There is no role parameter: final
completion uses the role already authorized in the invitation (Admin or Seller).
It does not require the original inviter to remain authorized.

## Eligibility and error boundary

Input validation precedes locks. Pending first completion requires a non-revoked
invitation, its exact binding and server-owned provenance, confirmed canonical
intended Auth email, one exact email-provider identity, no conflicting normalized
email/provenance matches and no existing active or inactive profile. Deleted,
banned, anonymous, SSO and email-changing identities fail as in final completion.
Email matching detects conflicts case-insensitively; the accepted stored email
and email identity must exactly equal the normalized invitation email.

A completed exact UUID/original-name retry returns the original bound UUID even
if later profile role, activation, name, Auth state or revocation changed. It
never reactivates, demotes or renames that profile. A changed original name
(including whitespace changes) or UUID fails. These are eligibility results,
not authorization to resume an operational session or reset a password.

| SQLSTATE | Exact message / boundary |
|---|---|
| `22023` | `Datos de finalización inválidos.` — null UUID/name, blank name or over 200 characters |
| `23514` | `La identidad de la invitación requiere verificación.` — missing/wrong/unbound or inconsistent identity; completed retry changed original name |
| `23514` | `La invitación fue revocada. Cree una nueva invitación.` — revoked pending invitation |
| `42501` | `permission denied for function check_staff_invitation_acceptance` — direct anon/authenticated SQL execution |

Keep these diagnostics private to trusted orchestration. Future HTTP code must
provide redacted outcomes, not expose identity/provenance details or translate a
caller-supplied UUID into authentication. No HTTP response contract is added here.

## Review and verification

Review the new migration against the existing completion invariant checks and
lock order: invitation advisory namespace, invitation/binding SHARE locks,
related Auth users in UUID order (UPDATE), then identities in UUID order (SHARE).
The narrow mirrored checks are intentional; no shared validator or existing
function is changed. Neither RPC reserves absent Auth emails across transactions.

The rolled-back `0040_staff_invitation_acceptance_test.sql` uses public calls as
actual SQL roles and compares every public table, Auth users/identities and
public/Auth sequence state before and after each rejected or read-only outcome.
It is not real acceptance/password/JWT, onboarding, mail or concurrency proof.

Observed for this unit: interface RED exited 1 (`42883`, missing function;
prior 39 files passed). Focused GREEN passed **201/201**; full isolated GREEN
passed **2365/2365 across 40 files**, both exit 0. The focused tests cover
46 preflight outcomes with unchanged-state comparisons plus the existing
completion's read-only retry. All owned disposable resources were removed.
No product/test correction was needed after the first GREEN execution.
Independent security verification passed the existing focused suite separately:
**201/201**, exit 0, one owned disposable stack removed. All 33 baseline
migrations and the shared helper remain unchanged; the validation/lock block
matches completion after comments are removed. No concrete blocker or advisory
was found. No new race, actual Auth/JWT/password or full-suite replay was claimed.
Native assessment and local delivery remain parent-owned.
