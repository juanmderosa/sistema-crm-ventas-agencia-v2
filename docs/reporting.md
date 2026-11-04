# Reporting backend

Status: periods, source events and Owner/Admin summary functionally verified;
native candidate review and seller access pending. Public view capture and bot
filtering are integration-pending.

## Owner/Admin summary

`public.get_reporting_summary(kind text, start date, end date default null)`
returns JSON for active Owner/Admin only. It uses the calendar contract below;
authorization is checked before dates or data. Only `authenticated` has function
execution, with the internal role check rejecting sellers, inactive staff and
identities without profiles. No new raw-table grants or policies are added.

| Section | Counting grain |
| --- | --- |
| `totals` | Views, inquiry creations, reservation creations, sale reports, confirmed sales, closure events in the selected period |
| `by_origin` | Web, in-person and phone counts shown separately, including zero rows |
| `by_vehicle` | Views and inquiry origins; reservations/sales use their actual vehicle, not all interests; NULL vehicle retains manual inquiries without a vehicle |
| `by_staff` | First assignments for complete histories, reservation/report performers, sale/closure responsible snapshots; no current-role or active-state filtering of history |
| `inquiry_history_coverage` | Complete/incomplete responsibility history for inquiries **created** in the selected period |

Global inquiry counts use creation time. Staff inquiry counts use each person's
first-assignment time and exclude incomplete histories; their totals are not an
additive breakdown of global inquiry creations. An older inquiry's incomplete
assignment history does not suppress its independently reliable sale or closure.
Unknown closure responsibility and known unassigned responsibility have distinct
`attribution` buckets, both with NULL staff ID. Repeated closure events remain
separate; reopening does not erase them. Cancellation/completion does not remove
a reservation's creation count. Pending reports do not count as confirmed sales.

`web_relation` globally and per vehicle returns numerator, denominator and value:
web-origin inquiry creations divided by deduplicated view events in the same
period. Zero views produce JSON NULL, not a fabricated zero relation. No-vehicle
buckets have no per-ficha relation. `interpretation = relation_not_causality`
is explicit. Staff comparisons are available only through this administrative
reader; seller statistics will have a separate restricted contract.

The response contains aggregates and staff/vehicle IDs, never contact fields,
inquiry IDs, submitted snapshots, browser tokens, raw history or internal prices.
It returns stable UTC period strings regardless of caller timezone. Empty staff
and vehicle sections are arrays; empty totals are zero. Views represent stored
events only: public capture integration is not claimed by this database reader.
Visit metrics, contact clicks, UI charts and HTTP/Auth integration remain outside
this slice. No arbitrary date-range caps or new commercial rules are introduced.

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

## Inquiry responsibility source

`inquiry_responsibility_tracking` records whether first-assignment observation
has covered an inquiry from creation. `inquiry_first_responsibilities` stores
one first-observed assignment per inquiry/person. Both are private, with RLS
and no application-role table grants or direct trigger execution grants.

New inquiry INSERTs start complete coverage, including initially unassigned
inquiries. Actual assignee changes are observed atomically by an AFTER trigger;
no-op or status-only updates do not create observations. Returning to a previous
person never advances their timestamp or creates another row. The database uses
wall time after the inquiry write lock, not transaction-start time.

There is no historical backfill. An older inquiry with no tracking row, or with
`complete_from_creation = false`, lacks complete first-assignment evidence.
Its first observed assignment after tracking starts is not necessarily its
historical first assignment. Readers must not present those timestamps as the
approved first-assignment-period metric. Legacy reporting treatment is not
silently inferred from the separate historical-closure policy.

For complete histories, the approved count is one inquiry per distinct person,
in their first-assignment period. Ana January → Bruno February → Ana March
counts Ana once in January and Bruno once in February, not Ana again in March.
Global count remains one; staff counts are not additive. Assignment is not
evidence of a performed activity. This capture adds no reassignment RPC or
changes to eligibility, RLS or existing pending-review/reservation guards.

Invalid kind, missing dates, reversed custom ranges, ignored calendar end dates,
infinite dates and unrepresentable timestamp boundaries return SQLSTATE `22023`
with an actionable message. PostgreSQL rejects malformed typed dates before
calling the helper. There is no public reporting endpoint in this slice.

## Verification

- `pnpm exec supabase test db supabase/tests/0024_reporting_period_test.sql`
- `pnpm db:test`
- `pnpm exec supabase test db supabase/tests/0025_inquiry_responsibility_test.sql`
- `pnpm exec supabase test db supabase/tests/0026_reporting_summary_test.sql`
- `python scripts/test-t6b4-independent.py t6b4verify_<base> t6b4verify_<candidate> <baseline-migrations-directory>`

The administrative-reader probe freezes caller-provided baseline migrations and
current migration bytes before creating two new disposable databases. It uses
public commercial operations, synthetic fixtures, full data hashes, baseline
function/ACL/policy comparisons and a recursive response-key allowlist. It never
reads Git or deletes resources; the caller cleans up printed DB/scratch names.
The Auth scaffold is not proof of deployed Auth or HTTP authorization.
- `python scripts/test-t6b3-independent.py t6b3verify_<base> t6b3verify_<candidate> <baseline-migrations-directory>`

The responsibility runner requires new disposable DB names and baseline migration
files supplied by the caller; it never reads Git or drops resources. It applies
baseline migrations and creates legacy fixtures before enabling the candidate
capture, checks real role denials with unchanged public-data hashes, compares
public RPC outputs without rewriting them, injects observation failures, and
uses real Lock barriers for assignment/status and commit/rollback clock probes.
The latter verifies the pre-release clock is later than waiter transaction start,
then asserts the stored observation exceeds both boundaries. Printed database
and scratch names are owned by the caller for cleanup. Minimal Auth scaffolding
and deterministic scratch UUID defaults are not real Auth HTTP proof.

The calendar tests cover all five kinds, leap days, a single-day custom interval,
cross-year ranges, microsecond event boundaries, historical offsets, session
timezone independence, invalid inputs and absence of helper RPC grants.
