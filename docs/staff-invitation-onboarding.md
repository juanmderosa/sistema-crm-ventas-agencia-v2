# Server-only invitation onboarding

`apps/backoffice/features/accounts/invitations/invitations.ts` orchestrates verified
password setup before private SQL completion. It does not expose an HTTP handler,
create identities, send email, or implement browser login.

## API and trusted configuration

Export: `createInvitationOnboardingService(config, fetcher = fetch)`.
`InvitationOnboardingConfig` contains `supabaseUrl` (fixed trusted HTTPS origin,
or HTTP loopback), `apiKey` (ordinary Auth key), and `serviceRoleKey` (separate
privileged secret). Origins cannot contain credentials, paths, queries or fragments.
Keys must be nonempty printable ASCII without whitespace. Invalid configuration
throws `Configuración de invitaciones inválida.`; browser execution throws
`El servicio requiere ejecución del lado del servidor.` Config values are captured
privately, never obtained from requests. Do not import this module into client code.
The runtime browser guard is defense in depth, not a bundler secret boundary.

Methods `acceptInvite(input)` and `recoverInterrupted(input)` return
`Promise<InvitationOnboardingResult>`. Both take `InvitationOnboardingInput`:
`{ invitationID, hash, displayName, password }`. They hardcode token types `invite`
and `recovery`, respectively. There is no caller identity, role, JWT or token-type
parameter. Extra properties confer no authority. Exported types also include
`InvitationOnboardingFailure` and `InvitationOnboardingResult`.

Validation happens before token consumption: UUID invitation, nonempty hash of at
most 2048 characters with no whitespace, nonblank name of at most 200 Unicode code
points, and the existing recovery minimum of six JavaScript password code units.
Names retain original whitespace; NUL and lone surrogates cannot enter PostgreSQL
text and are rejected. No stronger password policy is invented.

## Ordering, cleanup and retries

1. Auth `POST /verify` yields the session and structurally valid provider UUID.
2. Authenticated `GET /user` must corroborate that exact UUID using that bearer.
3. Service-only `check_staff_invitation_acceptance` must return that scalar UUID.
4. `PUT /user` sets the password with the same bearer. Only a successful response
   containing the matching user UUID confirms the update.
5. Await `POST /logout?scope=global` before completion, on **both** token paths.
6. Service-only `complete_staff_invitation` must return the same scalar UUID.

Both RPCs receive exactly `p_invitation_id`, `p_user_id`, `p_display_name`.
Only RPC requests carry service-role apikey/bearer; Auth uses the ordinary key
and verified session bearer (no bearer on verification). Every request forbids
redirects and uses a 10-second abort timeout. No provider payload, credential,
identity, session or raw exception is returned or logged.

Any usable consumed bearer is globally logged out, including identity/preflight
failure and rejected, malformed or uncertain password updates. Logout failure
always blocks completion and overrides earlier failure. Global logout revokes
sessions/refresh credentials; it does not cryptographically invalidate issued JWTs.
Preflight is not a reservation: completion rechecks current SQL state/provenance.
No direct profile creation, promotion, reactivation or role change occurs here.

A crash after password update but before completion leaves no operational profile.
Resume with recovery for the same bound identity and original name, verify again,
repeat password update and cleanup, then await atomic completion. A completion
transport/payload failure may mean the transaction committed: do not promise no
profile exists. SQL's permanent exact retry does not restore later profile changes.
No password-proof ledger or caller assertion substitutes for confirmed update.

## Fixed results and proof boundary

Success is exactly `{ ok: true }`; failure is exactly `{ ok: false, code }`.
Codes are private integration contracts, not new user-facing copy:

| Code | Meaning |
|---|---|
| `invalid_input` | No token consumed |
| `invalid_token` | Rejected/replayed/malformed verification or unusable bearer |
| `invalid_identity` | Missing/malformed or uncorroborated provider UUID |
| `preflight_rejected` | Eligibility response rejected, mismatched or unavailable |
| `password_rejected` | Auth explicitly rejected password update |
| `password_update_uncertain` | Transport, malformed or mismatched update response; password may have changed |
| `session_revocation_failed` | Required cleanup unconfirmed; no completion attempted |
| `completion_rejected` | Private completion explicitly rejected |
| `completion_uncertain` | Transport or invalid scalar result; transaction may have committed |

Run focused tests with `node --test apps/backoffice/features/accounts/invitations/invitations.test.ts`.
The backoffice `test` script retains unchanged recovery tests and includes these
new tests. Mocks prove request ordering, validation, credential routing and redacted
results only, not actual Auth sessions/password persistence, JWT permissions, SQL
atomicity or deployed secret isolation. T3b2c real-Auth service integration remains
pending, as do public handlers, delivery/resend, mail, UI and deferred T5. This
unit is neither complete onboarding nor native approval.
