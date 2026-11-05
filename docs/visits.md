# Visit backend foundation

Status: T1 foundation, T2a private creation, T2b service-only public creation and
T3a state/correction operations. Rescheduling, automatic cancellation, reporting
integration and UI remain pending. T3a native review is pending.

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
Native review remains pending. This is SQL-role proof, not real Auth/JWT HTTP.

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
