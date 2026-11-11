# Password recovery backend core

Status: recovery core implemented; offline tests, strict TypeScript and genuine
local Auth recovery/session checks passed. No HTTP route, browser completion screen
or captured-mail test is implemented or claimed. Do not describe this as
end-user-ready account recovery. See [observed Auth checks](accounts-http.md).

## Contract

`apps/backoffice/features/accounts/recovery/recovery.ts` exposes
`createRecoveryService({ authUrl, apiKey, callbackOrigin }, fetcher?)` for server use.
Use the project's public Auth API key; privileged credentials are not necessary.
Configuration is server-owned, never copied from request parameters or Host headers.
HTTPS is required outside exact loopback hosts. Origins cannot contain credentials,
paths, query strings or fragments. The fixed callback is `/acceso/recuperar` on the
configured backoffice origin (development: `http://localhost:3001`).

- `request(email)` returns the same Spanish message for malformed inputs, known or
  missing accounts, and provider/network failures. It does not claim email delivery.
- `complete(tokenHash, password)` first verifies a recovery token hash through Auth,
  then updates the password using the returned session, and finally requests global
  logout. It does not accept an arbitrary authenticated session as recovery proof.
- Passwords must satisfy the current six-character local minimum and all additional
  provider requirements. This is not a new approved production password policy.
- The verified session and provider payloads never appear in return values or logs.
  Provider HTTP redirects are refused and requests have a ten-second timeout.
- Even on password rejection/uncertain update, global logout is attempted for the
  consumed recovery session. `password_update_uncertain` means an update request
  failed without proving whether persistence occurred. `session_revocation_failed`
  means the requested session revocation was not confirmed; do not report success.
- Global logout revokes refresh sessions, not already-issued JWT signatures. Existing
  current-profile database checks remain necessary for immediate deactivation denial.

## Integration still required

Expose rate-limited HTTP handlers with fixed server configuration, security headers,
request-size limits and appropriate origin/CSRF controls. Configure Auth callback
allowlists and email templates so the completion endpoint receives a recovery token
hash without first consuming it. Do not log callback query strings. The current
local Auth callback configuration still targets the public app and is not fixed here.
The final browser flow must not expose recovery credentials in analytics or referrers.

An owned disposable Auth run verified admin-generated recovery-token consumption,
invalid/replayed token rejection, password sign-in changes and rejection of every
captured old refresh credential after global logout. No email was sent. Actual
mail consumption and clock-based expiry remain unverified; local captured mail
must not deliver to an external mailbox. Deactivation/session integration belongs to the invitation/account
lifecycle slice, not this recovery-only core.

## Checks

```sh
node --test apps/backoffice/features/accounts/recovery/recovery.test.ts
node node_modules/typescript/bin/tsc --project apps/backoffice/tsconfig.json --noEmit --incremental false
```

With pnpm available, the backoffice `test` script runs the same focused tests:
`pnpm --filter @dealership/backoffice test`. No new runtime dependency is required.
Node 24 can execute the tests' erasable TypeScript directly. The existing package
has no explicit ESM type; Node may print `MODULE_TYPELESS_PACKAGE_JSON`, a known
warning which is not suppressed and does not fail these tests.

Protocol reference: [Supabase Auth](https://github.com/supabase/auth), `/recover`,
`/verify` with `type: recovery` and `token_hash`, `/user`, and `/logout?scope=global`.
Current documentation was consulted; the core's completion flow passed against
local GoTrue v2.197.0. Recovery email requests and hosted-provider behavior remain
outside that executed proof.
