# Reporting backend

Status: periods and source events implemented; aggregate readers and seller
access pending. Public view capture and bot filtering are integration-pending.

## Internal calendar normalizer

`public.reporting_period(kind text, start date, end date default null)` is an
internal, data-free helper with no application-role execution grants.

| Kind | Arguments | Result |
| --- | --- | --- |
| `month`, `quarter`, `semester`, `year` | Required anchor in `start`; `end` must be NULL | Calendar period containing the anchor |
| `custom` | Required inclusive `start` and `end` | Both local days included |

Returns one row: inclusive `local_start`/`local_end` dates, `start_at` inclusive,
`end_at` exclusive and `timezone_name = America/Argentina/Buenos_Aires`.
Readers must filter `event_time >= start_at AND event_time < end_at`.
Both local midnights are converted independently, preserving historical timezone
offsets and ignoring the database session timezone. No current-date default,
maximum range, future-date ban or business-day calendar is imposed.

Invalid kind, missing dates, reversed custom ranges, ignored calendar end dates,
infinite dates and unrepresentable timestamp boundaries return SQLSTATE `22023`
with an actionable message. PostgreSQL rejects malformed typed dates before
calling the helper. There is no public reporting endpoint in this slice.

## Verification

- `pnpm exec supabase test db supabase/tests/0024_reporting_period_test.sql`
- `pnpm db:test`

The calendar tests cover all five kinds, leap days, a single-day custom interval,
cross-year ranges, microsecond event boundaries, historical offsets, session
timezone independence, invalid inputs and absence of helper RPC grants.
