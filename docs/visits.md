# Visit backend foundation

Status: S21a T1 foundation only. Visit creation, lifecycle, automatic cancellation,
reporting integration and UI are not implemented by this migration.

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
This foundation does not yet capture history automatically or enforce lifecycle
transitions: those operations remain unavailable to application callers.

## Verification

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
