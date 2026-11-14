# Resend SMTP readiness

**Provider selected; configuration prepared, disabled and not live-tested.**
No credentials, provider account, verified domain or external email was created.
This is Supabase Auth's native SMTP transport, not a separate application mailer.

## Prepared configuration

`supabase/config.toml` contains an entirely commented `[auth.email.smtp]` example:

| Setting | Prepared value |
| --- | --- |
| Host | `smtp.resend.com` |
| Port | `465` — implicit SSL/TLS |
| Username | `resend` |
| Password | `env(RESEND_API_KEY)` |
| Sender address | `env(RESEND_FROM_EMAIL)` |
| Sender name | `env(RESEND_FROM_NAME)` |
| Enabled | `false`, also commented |

Documentation-only placeholders for later secure server/runtime configuration:

```dotenv
RESEND_API_KEY=
RESEND_FROM_EMAIL=
RESEND_FROM_NAME=
```

Do not use `NEXT_PUBLIC_*`, commit credentials, paste keys in conversation or log
them. No environment file is created by this change. Next app environment files
are not proof that Supabase CLI or hosted Auth receives these values.
Adding a key alone does not activate the commented, disabled SMTP example.

## Later activation — still pending

1. Confirm the Resend sender/domain is verified and the available free quota is
   suitable. No paid fallback or purchase is approved.
2. Supply credentials securely to the intended Supabase runtime. For a local
   project, deliberately configure/uncomment the example and enable SMTP only
   after activation is authorized. Sender-field environment substitution and
   TLS/authentication have not been exercised against a live server here.
3. For hosted Supabase, use **Authentication → Email (Notifications) → SMTP
   Settings** and configure sender name/address plus the settings above.
   Local TOML does not configure the hosted project. Do not connect accounts,
   generate keys or save Dashboard changes as part of this readiness change.
4. Review Spanish email templates, callback routes and the redirect allowlist
   before enabling real messages. The current local site/redirect settings do
   not establish that the invitation or recovery browser journey is ready.
5. Separately authorize a controlled delivery test; verify provider acceptance,
   mailbox delivery and callback behavior. None has been performed here.

Existing recovery requests already call native Auth `/recover`; no application
source, SDK or dependency change is needed to prepare its SMTP provider.
The existing Auth rate limit of two emails per hour is unchanged and is separate
from Resend's quota. The local email-capture configuration is also unchanged.

## Evidence and limits

Only comments changed in TOML. An offline comparison checks that the complete
parsed baseline and candidate configurations are identical; there is no
behavioral RED/GREEN or SMTP success claim for this passive change.

SMTP readiness does not implement bound-resend link issuance, guarantee an exact
Auth identity under email changes, or complete public HTTP/browser/mail flows.
Those boundaries remain pending; see [bound-resend preparation](staff-invitation-bound-resend.md).
T5 session revocation remains explicitly blocked, not completed or resumed.

Official provider references:
- https://resend.com/docs/send-with-supabase-smtp
- https://resend.com/docs/send-with-smtp
- https://resend.com/docs/knowledge-base/getting-started-with-resend-and-supabase
