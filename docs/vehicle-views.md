# Vehicle-view database ingestion

Status: T6a database plus T8 public integration. The vehicle-detail page in
`apps/public` now records a view only after a successful public load, behind a
server-side known-bot User-Agent filter, with the opaque browser token minted at
the server boundary. This is capture proof, not complete S21: visits, contact
clicks, retention and UI-panel claims remain out of scope.

## Trusted-server contract

`public.record_vehicle_view(p_vehicle_id uuid, p_browser_token uuid) -> boolean`
is executable only by `service_role`. Neither anonymous callers nor authenticated
staff can invoke it. The public vehicle-detail page
(`apps/public/app/vehiculo/[id]/page.tsx`) calls it through `lib/capture.ts`
only after a successful public detail-page load and behind the server-side
known-bot filter (`lib/bots.ts`); the call runs in `after()` once the response
has been sent. Never expose privileged keys in the
browser. No private-panel emitter is added by this slice.

- The browser token is a random opaque UUID, not a phone, identity or fingerprint.
- `true` means one counted event was stored; `false` means the pair was already
  counted within the last rolling 24 hours. A duplicate changes no stored state.
- Different vehicles or tokens have independent windows. Exactly 24 elapsed
  hours permits another count; the window is not a calendar-day bucket.
- The database supplies the timestamp after acquiring the per-pair transaction
  advisory lock. Callers cannot submit a time or an eligibility/bot assertion.
- Public eligibility matches published, not soft-deleted, sale-enabled inventory.
  Reserved and Sold detail pages are eligible. Missing, draft, blocked and deleted
  rows return `22023 vehicle is not publicly visible`. Null arguments return
  `22023 vehicle and browser token are required`. Unauthorized execution returns
  PostgreSQL permission denial (`42501`) before inventory checks.

## Storage and concurrency

`vehicle_view_events` stores vehicle/timestamp events without browser tokens or
seller attribution. `vehicle_view_dedup` stores the last counted timestamp for
each vehicle/token pair. Both enable RLS and deny raw access to application roles,
including `service_role`; only the controlled function writes. Reporting readers
will be implemented separately. No personal data, User-Agents or IPs are stored.

Event insertion and dedup advancement form one transaction. Under the supported
READ COMMITTED isolation, simultaneous same-pair calls serialize and only one
counts; a rolled-back call leaves no count. Hash collisions only serialize
unrelated pairs, never combine their data. No explicit vehicle row lock is added
to existing commercial lock ordering. Eligibility is checked at ingestion's read
snapshot, not guaranteed through commit against concurrent publication changes.

Retention and cleanup are not defined. Clock rollback can suppress counting until
wall time catches up; no speculative recovery or identity verification is added.

## Verification

- `pnpm exec supabase test db supabase/tests/0022_vehicle_views_test.sql`
- `pnpm db:test`
- `python scripts/test-t6a-independent.py t6verify_<base> t6verify_<candidate> <baseline-migrations-directory>`
- `python scripts/test-auth-http.py` — real PostgREST calls: `service_role` records
  and deduplicates a view over HTTP, while `anon` and `authenticated` receive
  permission denial; see [auth-http](auth-http.md).
- `pnpm --filter @dealership/public test` — unit tests for the known-bot filter.
- `python scripts/test-public-capture.py` — end-to-end HTTP proof: successful
  load records one view with an httpOnly opaque cookie, 24h dedup, known bot
  receives the ficha but records nothing, draft/blocked/unknown return `404`
  with no capture, and the service-role key never appears in a response body.

The focused test rolls back synthetic fixtures. The retained independent runner
creates two new explicitly named disposable databases, applies caller-provided
baseline migrations and the current migrations using a minimal Auth scaffold,
and reports its external scratch path for caller cleanup. Never point it at an
existing database. Parent cleanup owns the reported databases and scratch files.
It proves 87 real permission denials with unchanged state, commercial-state
preservation, baseline output/error/exit equivalence, overlapping commit/rollback
deduplication and independent-key progress, and expiry across an actual lock wait.
The runner does not prove Auth HTTP behavior. Bot filtering and successful-load
HTTP proof are covered by T8 above (`scripts/test-public-capture.py`). UI and
reporting readers remain pending separately.
