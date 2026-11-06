# Visit backend foundation

Status: T1–T3b are complete, including rescheduling and its native review.
T4 automatic cancellation is complete at commit `19dd7ee`, independently verified
and approved/acknowledged by native review. T5 reporting is complete at commit
`97efab6`, with functional/independent verification and native review approved/acknowledged.
Public form and internal agenda UI remain deferred.

## Visit reporting (T5)

Two additive, read-only RPCs accept `(p_kind text, p_start date, p_end date default null)`:

| RPC | Access | Output |
|---|---|---|
| `get_visit_reporting_summary` | Active Owner/Admin | `period`, `totals`, `by_vehicle`, `by_staff` |
| `get_my_visit_reporting_summary` | Active staff, own attribution only | `period`, `figures`, `scope: {subject: "self"}` |

Counts are `requests`, `attended`, `cancelled`, `no_show`. One visit contributes
one request by creation date and at most one current final result by scheduled
date. Requested/Confirmed visits contribute no final result. Corrections replace
the previous category, restoration removes the final result, and rescheduling
does not create a request. History rows never multiply counts. These are absolute
figures, not inquiry counts, conversion rates or evidence of who physically attended.

Periods reuse `reporting_period`: `month`, `quarter`, `semester`, `year` contain
the anchor date; `custom` includes both supplied local days. Fixed business zone:
`America/Argentina/Buenos_Aires`, regardless of session timezone. For example:

```sql
select public.get_my_visit_reporting_summary('month', date '2026-11-01');
select public.get_visit_reporting_summary('custom', date '2026-11-01', date '2026-11-30');
```

Request responsibility comes from creation; outcome responsibility comes from
the first recorded outcome, even after correction, reactivation or reassignment.
The administrative reader groups by the visit's concrete vehicle and historical
staff ID, retaining deactivated staff. Null staff is `attribution: "unassigned"`
(UI label: «Sin responsable»), never the recording administrator. Empty counts
are zero and empty breakdowns are `[]`. Comparing periods uses separate calls.

The own reader scopes each source to `auth.uid()`, including former assignments
without restoring visit/inquiry detail access. It returns no vehicle IDs, staff
IDs/comparisons, global totals, views, ratios, customer data or raw history.
There is no caller-provided staff selector. Existing reporting RPCs are unchanged.
Anonymous and service roles have no execution grant. Unauthorized authenticated
calls fail before date validation with `42501 visit reporting access denied` or
`42501 own visit reporting access denied`. Invalid/nonfinite dates, kinds and
custom ranges reuse the existing `22023` reporting-period errors.

## Automatic cancellation (T4)

| Event | Pending visits cancelled | History reason |
|---|---|---|
| Inquiry becomes Sale reported or Closed without sale | That inquiry, regardless of interest vehicle | `Consulta cerrada` |
| Vehicle becomes Sold | That vehicle across inquiries | `Vehículo vendido` |
| Vehicle first soft-deleted | That vehicle across inquiries | `Vehículo dado de baja` |
| Vehicle becomes internally blocked | That vehicle across inquiries | `Vehículo bloqueado` |

Sale reporting cancels immediately, before administrative confirmation. Other
inquiries remain open. Reservation, unrelated edits, reopening and unblocking do
not cancel or restore visits. Final visits are untouched. A combined vehicle edit
uses deletion, then Sold, then blocking reason precedence, with one history event.

Private AFTER UPDATE triggers reuse one private cancellation helper; application
roles cannot execute it or either trigger function directly. Existing operations
retain their grants, validation, return values and commercial effects. Cancellation
and history commit or roll back with the parent operation, including sale review.
No new general inquiry-close API is introduced.

The helper takes only visit-row locks in ID order, never upward vehicle, actor or
inquiry locks. Existing visit operations obtain parent locks before visit locks.
Read current inquiry responsibility after acquiring the visit lock; preserve the
first recorded outcome, including explicitly unassigned attribution. Appointment,
purpose, request attribution and immutable creation intent remain unchanged.
History records the parent's authenticated actor (or NULL for privileged system
maintenance), both states, unchanged appointment, reason and cancellation time.
READ COMMITTED is required. A future reassignment API must verify attribution
serialization with these automatic outcomes rather than assuming its lock order.

## Opening-hours configuration

Authenticated active Owner/Admin calls
`set_dealership_opening_hours(p_intervals jsonb)` to replace the complete weekly
schedule in one transaction. The result is void. Example payload:

```json
[
  {"weekday": 1, "opens_at": "09:00", "closes_at": "13:00"},
  {"weekday": 1, "opens_at": "16:00", "closes_at": "20:00"}
]
```

Weekdays use Sunday `0` through Saturday `6`; local times use
`America/Argentina/Buenos_Aires`. Intervals must have an opening time before
closing and must not overlap on the same day. Adjacent intervals are allowed.
An overnight opening period is represented as separate intervals on its two
days. No default schedule, fixed visit duration or capacity is created.

`[]` explicitly clears the schedule. Null/non-array payloads return `22023`;
invalid rows are rejected by PostgreSQL type, NOT NULL, CHECK or exclusion
constraints. Any failed replacement rolls back to the previous schedule.
Unauthorized authenticated callers receive `42501: opening hours access denied`
before input validation. Anonymous and service-role execution is not granted.

Whole-schedule replacement serializes on a dedicated transaction advisory lock;
the caller profile is locked first against concurrent deactivation. The command
does not lock or change any inquiry, vehicle, visit or visit-history row.
Active staff can read the schedule; raw anonymous schedule access is not granted.
A safe public schedule contract remains part of later visit-request work.

## Private storage and access

| Storage | Invariant |
|---|---|
| `visits` | Concrete inquiry-interest vehicle; one Requested/Confirmed visit per inquiry across all vehicles; finalized visits remain alongside a later visit |
| `visit_history` | Stores old/new state, old/new appointment time, actor, event time and reason for later controlled operations |
| Attribution fields | Request assignee separate from first-result assignee and audit actor; first-result timestamp distinguishes no result yet from an unassigned first result |

Authenticated readers see visits through existing inquiry RLS. Current responsible
staff and active Owner/Admin retain their existing inquiry scope. History follows
visit visibility, not past metric attribution. Reassignment and deactivation
therefore remove former staff access without removing history.

Direct application-role writes and broad service-role access are denied. The SQL
database owner can create test fixtures; that is not an exposed application API.
Private creation records its initial history atomically. Subsequent lifecycle
transitions and automatic cancellation remain unavailable to application callers.

## Create a visit from an existing inquiry

`create_inquiry_visit(p_submission_id uuid, p_inquiry_id uuid, p_vehicle_id uuid,
p_scheduled_at timestamptz, p_purpose text default null)` is authenticated-only.
The active responsible staff member or Owner/Admin may call it. It returns
`{"visit_id":"<uuid>"}` for the new tentative visit and creates no inquiry,
reservation or assignment/rotation change. The vehicle must already be an
interest of the active inquiry; unpublished and Reserved vehicles are allowed,
but Sold, blocked and soft-deleted vehicles are not.

Generate one submission UUID per intentional creation, retaining it for technical
retries. Exact original intent is stored in private `visit_creation_requests`;
identical authorized retries return the original ID without adding history.
Changed input returns `22023: visit submission ID already used with different input`.
Every retry checks current access first: former assignees cannot recover visit
details through an old key. Later schedule, availability or inquiry-status changes
do not invalidate an otherwise authorized matching retry.

New appointments must be future and within local opening-inclusive,
closing-exclusive intervals. All lock waits precede the wall-clock check. Lock
order is submission advisory, vehicle, actor profile, inquiry, schedule advisory.
No additional profile lock is acquired after schedule locking. Times are compared
as epoch values for retry intent, independently of the caller's session timezone.
The internal schedule helper is not executable by application roles.

Common errors: unauthorized access `42501: visit access denied`; inactive inquiry,
missing interest, ineligible vehicle, existing pending visit or invalid time
return explicit `22023` errors. Failures roll back visit, history and intent
together. READ COMMITTED transactions are required, as for existing inquiry RPCs.

## Submit a public visit request through a trusted backend

`submit_visit_request(p_submission_id uuid, p_vehicle_id uuid, p_phone text,
p_name text, p_email text, p_scheduled_at timestamptz, p_purpose text default null)`
is service-role-only and returns exactly `{"accepted":true}`. It does not expose
inquiry, contact, assignee or visit identifiers. It reuses `submit_inquiry` for
canonical input validation, contact preservation, continuity and round robin,
then records the visit and initial history in the same transaction. Failure of
visit validation or insertion rolls back all inquiry/contact/routing writes.
Public requests require a published, sale-enabled, not Sold/deleted vehicle and
a future appointment within opening hours; Reserved remains eligible.

Retain the submission UUID and exact payload across retries. Stored original
intent includes canonical contact fields, vehicle, timestamp and optional purpose.
Matching retries remain accepted after subsequent changes of inventory, inquiry,
schedule or visit state. Different data returns `22023`; an ordinary-inquiry UUID
cannot be reused for a visit request or vice versa, even with identical contact
fields. The ordinary RPC otherwise retains its existing behavior and grants;
in particular, its preexisting treatment of blocked vehicles is not changed by
the stricter eligibility rules for visits.

The public history actor is null; request attribution is the routed assignee,
including a known unassigned result when no staff member is eligible. This SQL
contract is not a public HTTP endpoint: real phone validation, abuse protection,
safe schedule delivery and the deferred form must precede browser exposure.

## State management

Authenticated current responsible staff or active Owner/Admin calls
`set_visit_status(p_visit_id uuid, p_status visit_status, p_reason text default null)`.
It returns `{ "visit_id": "..." }`; no customer or inquiry details are returned.
Anonymous/service execution and direct table writes remain denied.

| Current state | Allowed target | Condition |
|---|---|---|
| Requested | Confirmed, Cancelled | Confirmation may be late |
| Confirmed | Attended, No-show | Appointment time reached |
| Confirmed | Cancelled | No time restriction |
| Final | Any different state | Nonblank correction reason |
| Any | Same state | Authorized no-op; no history or timestamps changed |

Final means Attended, Cancelled or No-show. Restoring Requested/Confirmed also
requires an active inquiry, an eligible vehicle (Reserved/private unpublished
allowed; Sold/blocked/deleted denied), and no other pending visit in the inquiry.
Final-to-final historical corrections remain possible after closure or vehicle
unavailability. State-only changes never move or revalidate the appointment
against changed opening hours. Confirmed-to-Requested belongs to rescheduling,
not this operation.

Every actual transition atomically appends previous/new state and appointment,
actor, reason and wall-clock timestamp. First finalization snapshots the inquiry
assignee, not the actor; its timestamp and nullable assignee survive all later
corrections and reactivation. A recorded unassigned result stays unassigned.
Purpose, request attribution and original public/private creation intent remain
unchanged. Normal transitions do not require a correction reason.

The internal, non-executable-by-client `lock_managed_visit(uuid)` acquires vehicle,
actor, inquiry, then visit locks and rechecks authorization after waiting. Inquiry
locking serializes restoration against creation even across different vehicles.
Use READ COMMITTED, as with existing creation operations. No automatic cross-flow
cancellation, metrics, rescheduling or UI is included in this slice.

Errors: `42501 visit access denied` for missing/inaccessible visits;
`22023 invalid visit transition`, `correction reason is required`,
`visit time has not been reached`, `inquiry is not active`,
`vehicle does not accept visits`, or `inquiry already has a pending visit`.
An invalid enum literal is rejected by PostgreSQL before the function executes.

Rollback boundary: only the new `20261105140000_visit_states.sql` functions,
their test and this state-management contract. Existing storage, data, RLS and
creation functions are unchanged; never remove historical visit data to roll back.

## Pending visit rescheduling

`reschedule_visit(p_visit_id uuid, p_scheduled_at timestamptz, p_agreed boolean)`
returns `{ "visit_id": "..." }` for the same visit. Current responsible active
sellers and active Owner/Admin may reschedule Requested or Confirmed visits.
`true` records an agreed Confirmed appointment; `false` records a Requested
proposal, including a downgrade from Confirmed. There is no rescheduling limit.

The new time must be finite, future and inside current local opening intervals
(opening inclusive, closing exclusive). Managed row locks precede the existing
opening-time helper, so validation uses the clock and schedule after waits.
Exact valid retries add no history; they still require authorization and a valid
future appointment. Other changes append old/new appointment and status, actor
and timestamp atomically. Identity, purpose, creation intent, request attribution
and any first-outcome attribution survive. No inquiry, reservation or routing
operation is performed. Final visits must first use authorized state correction;
rescheduling never reactivates them.

Errors: `42501 visit access denied`; `22023 only pending visits can be rescheduled`,
`visit agreement is required`, or `visit time must be future and within opening hours`.
Use READ COMMITTED. Anonymous and service-role execution are not granted.
Rollback boundary: only the new rescheduling function, regression suite and
contract; do not remove historical visit data or existing helpers.

Observed RED: missing RPC. Focused suite `0032_visit_rescheduling_test.sql` passed
35/35; full database suite passed 1548/1548 across 32 files. Independent proof
passed 58 assertions and seven observed lock-wait races, repeated by the parent
with `python scripts/test-visit-rescheduling-concurrency.py`. Native review pending. Local `migration up` encountered an already-existing
T3a function absent from its migration ledger; only the new T3b migration was
applied directly with `psql`, without reset or ledger changes.

## Verification

State transitions: `pnpm exec supabase test db supabase/tests/0031_visit_state_test.sql`
(45/45); full database regression 1513/1513 across 31 files. Missing-function RED
was observed before applying only the new migration; no shared reset was used.
Independent authorization/concurrency proof passed: 31 assertions, five real
lock-wait/release races, private retry and supplemental accepted-only public retry
with exact intent preservation. Parent repeated the retained runner successfully:
`python scripts/test-visit-state-concurrency.py`. It creates a new owned local
`verify_visits_states_*` database from the current schema and leaves it plus its
external scratch for caller cleanup. It never resets the shared database.
User-granted four-lens native review approved commit `e957e9e` without findings;
exact acknowledgement consumed the review authority for `review-26b7bf31a3d343e8`.
This is SQL-role proof, not real Auth/JWT HTTP.

Public creation: `pnpm exec supabase test db supabase/tests/0030_public_visit_request_test.sql`
(32/32); full database regression 1468/1468 across 30 files. Retained races:
`python scripts/test-public-visit-concurrency.py verify_visits_<owned_empty_migrated_db>`.
The disposable database must be empty and migrated; fixtures remain for caller cleanup.

Focused command: `pnpm exec supabase test db supabase/tests/0028_visit_foundation_test.sql`.
Full regression command: `pnpm db:test`.
Observed final results: focused 52/52; full 1400/1400 across 28 files.
Retained concurrency probe:
`python scripts/test-visit-hours-concurrency.py verify_visits_<owned_disposable_database>`.
Provision that isolated database with current migrations first. The runner rejects
the shared database name, observes both live sessions and an actual advisory-lock
wait, then asserts the exact final complete schedule. It leaves synthetic fixtures
for the caller to remove with the owned disposable database.
These database tests exercise actual role grants and RLS, not real Auth JWT HTTP
transport. No browser workflow or public submission endpoint is claimed.

Rollback boundary: the new visit-foundation migration, its focused test and this
contract; existing function signatures and table policies are unchanged. Once
real visit data exists, removal requires an explicit preservation/migration plan,
not a destructive rollback of stored commercial history.
