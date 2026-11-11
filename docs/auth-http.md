# Auth / PostgREST / JWT HTTP verification

Status: verified against a disposable local Supabase stack with genuine GoTrue
users and password-grant JWTs, not simulated `set role` or forged claims. The
latest run passed 203 HTTP/JWT checks, including visit permissions, lifecycle,
reporting, and idempotency. This documents observed HTTP behavior only; it
claims no UI, remote deployment, or foundation completion.

## Runner

```
python scripts/test-auth-http.py
```

Requires Docker, Python 3 (standard library only), the local Supabase CLI, and
the service images already cached locally. The runner creates a uniquely named
temporary project with its own ports, database, Auth, Kong, and PostgREST; it
copies the current migrations and database tests, disables unrelated services,
and removes its containers, volumes, networks, and temporary files in teardown.
It does not start, reset, or seed the shared local project, and does not connect
to a hosted project. HTTP requests are restricted to the exact loopback origin;
proxy inheritance and redirects are disabled. Output omits credentials and
response payloads.

## How a role is selected

| Header | Effect |
| --- | --- |
| `apikey: <key>` | Identifies the project key; required by Kong on every `/rest/v1` and `/auth/v1` request. Missing key → `401`. |
| `Authorization: Bearer <jwt>` | Selects the PostgREST role. This is what PostgREST reads. The `apikey` alone never authenticates. |
| No `Authorization` | The request runs as `anon`. |
| `Authorization: Bearer <user access token>` | The request runs as `authenticated`, with `sub` = the GoTrue user id. |
| `Authorization: Bearer <service role key>` | The request runs as `service_role`. Both headers are required; trusted server code must send both. |

Anon and service keys are JWTs whose `role` claim is `anon` and `service_role`.
A malformed bearer token returns `401` with `PGRST301`.

## RPC parameters (PostgREST)

PostgREST matches JSON body keys to the SQL parameter names. The DDL uses the
`p_` prefix convention, so callers must send `p_` names. Sending the bare name
(`kind`, `start`, `vehicle_id`) returns `404` with `PGRST202` — the function is
found but the parameters do not match.

| Function | Body keys |
| --- | --- |
| `get_reporting_summary` | `p_kind`, `p_start`, `p_end` (optional) |
| `get_my_reporting_summary` | `p_kind`, `p_start`, `p_end` (optional) |
| `reporting_period` | `p_kind`, `p_start`, `p_end` (optional) |
| `record_vehicle_view` | `p_vehicle_id`, `p_browser_token` |
| `submit_inquiry` | `p_submission_id`, `p_vehicle_id`, `p_phone`, `p_name`, `p_email` |
| `create_manual_inquiry` | `p_phone`, `p_name`, `p_email`, `p_vehicle_id`, `p_origin` |
| `add_inquiry_interest` | `p_inquiry_id`, `p_vehicle_id` |
| `update_contact_details` | `p_contact_id`, `p_expected_revision`, `p_name`, `p_email` |
| `update_contact_phone` | `p_contact_id`, `p_expected_revision`, `p_phone` |
| `reserve_inquiry_vehicle` | `p_inquiry_id`, `p_vehicle_id` |
| `cancel_reservation` | `p_reservation_id` |
| `set_vehicle_sale_blocked` | `p_vehicle_id`, `p_blocked` |
| `report_inquiry_sale` | `p_inquiry_id`, `p_vehicle_id` |
| `resolve_sale_review` | `p_review_id`, `p_confirm` |
| `reopen_inquiry` | `p_inquiry_id` |
| `set_dealership_opening_hours` | `p_intervals` |
| `create_inquiry_visit` | `p_submission_id`, `p_inquiry_id`, `p_vehicle_id`, `p_scheduled_at`, `p_purpose` (optional) |
| `submit_visit_request` | `p_submission_id`, `p_vehicle_id`, `p_phone`, `p_name`, `p_email`, `p_scheduled_at`, `p_purpose` (optional) |
| `set_visit_status` | `p_visit_id`, `p_status`, `p_reason` (optional) |
| `reschedule_visit` | `p_visit_id`, `p_scheduled_at`, `p_agreed` |
| `get_visit_reporting_summary` | `p_kind`, `p_start`, `p_end` (optional) |
| `get_my_visit_reporting_summary` | `p_kind`, `p_start`, `p_end` (optional) |

All RPCs are `POST /rest/v1/rpc/<name>`.

## Verified exposure matrix

Observed status codes from the captured run. `401` with `42501` means the
current role has no grant on the function or table; `403` with `42501` means
the grant exists but RLS or an explicit denial inside the function rejected the
call.

### Transport

| Case | Result |
| --- | --- |
| Request without `apikey` | `401` `42501` |
| Malformed bearer token | `401` `PGRST301` |
| Public signup (`/auth/v1/signup`) | `422` `signup_disabled` |
| Anon creating Auth users (`/auth/v1/admin/users`) | `403` `not_admin` |

### Anonymous (`anon`)

| Surface | Result |
| --- | --- |
| `GET /rest/v1/profiles`, `inquiries`, `contacts`, `reservations`, `sale_reviews`, `confirmed_sales`, `inquiry_status_history`, `vehicle_view_events`, `vehicle_view_dedup`, `inquiry_assignment_history`, `vehicle_inquiry_participants`, `vehicle_inquiry_rotation` | `401` `42501` |
| `GET /rest/v1/vehicles` | `200`, only `publication_status = 'published'` and `deleted_at is null` rows |
| All 15 RPCs above | `401` `42501` |

### Authenticated, active staff (`Seller` JWT)

| Surface | Result |
| --- | --- |
| `GET /rest/v1/profiles?select=...` | `200`, only its own row |
| `GET /rest/v1/inquiries` | `200`, only rows where it is the current assignee |
| `GET /rest/v1/vehicles` | `200`, every row including drafts and soft-deleted (staff inventory view) |
| `PATCH /rest/v1/profiles?id=eq.<own>` | `200` with an empty representation; nothing persisted (no update policy for staff) |
| `DELETE /rest/v1/profiles?id=eq.<own>` | `403` |
| `POST /rest/v1/profiles` | `403` `42501` (no insert grant) |
| `POST /rest/v1/vehicles` | `403` `42501`, RLS insert policy |
| `PATCH /rest/v1/vehicles?id=eq.<draft>` | `200` with an empty representation; year unchanged |
| `GET /rest/v1/vehicle_inquiry_participants`, `inquiry_assignment_history` | `200` with `[]` (grant exists, admin-only policy filters everything) |
| `GET /rest/v1/vehicle_view_events` | `403` `42501` |
| `get_my_reporting_summary` | `200` with exactly `period`, `figures`, `by_origin`, `scope`; `scope.subject = 'self'`; only own attributed figures |
| `get_reporting_summary` | `403` `42501` `reporting access denied` |
| `record_vehicle_view` | `403` `42501` |
| `submit_inquiry`, `create_manual_inquiry`, `add_inquiry_interest`, `update_contact_details`, `update_contact_phone`, `reserve_inquiry_vehicle`, `cancel_reservation`, `set_vehicle_sale_blocked`, `report_inquiry_sale`, `resolve_sale_review`, `reopen_inquiry` | `401` or `403` `42501` (no anon-equivalent grant, or in-function staff check rejects) |

### Authenticated, `Owner`/`Admin` JWT

| Surface | Result |
| --- | --- |
| `GET /rest/v1/profiles` | `200`, every profile row |
| `GET /rest/v1/vehicle_inquiry_participants` | `200`, rows for the vehicle |
| `GET /rest/v1/inquiry_assignment_history` | `200`, rows for the inquiry |
| `get_reporting_summary` | `200` with `period`, `totals`, `by_origin`, `by_vehicle`, `by_staff`, `inquiry_history_coverage`; first assignment attributed to the responsible staff id; web relations labelled `relation_not_causality` |
| `get_my_reporting_summary` | `200` with the same restricted four-key set as a seller |
| `POST /rest/v1/vehicles` | `201`, row stored as `published` |
| `create_manual_inquiry` | `200`, inquiry stored once |

### Visit and reporting HTTP checks

The runner exercises visit endpoints with actual JWTs for Owner, Admin, assigned
and unassigned Sellers, inactive staff, an identity without a profile, anon,
and `service_role`:

| Behavior | Observed result |
| --- | --- |
| Owner configures opening hours; assigned Seller creates a private visit | Accepted; one visit and one creation record persist |
| Repeated private creation request | Returns the original visit without adding data or changing the original intent |
| Anon/service-role visit operations; Seller opening-hours configuration; unauthorized Seller/ghost/inactive private create, transition, and reschedule | Strict expected HTTP/auth errors; all-public-table hash is unchanged after each rejected write |
| Anon reads visit, history, creation-ledger, or opening-hours tables | Denied; public table hash unchanged |
| Assigned Seller, Owner and Admin read authorized visit details | Allowed; other, ghost and inactive users see no private details |
| Assigned Seller confirms/cancels; Admin reschedules; Owner corrects the final result | Accepted through the documented operations and exact resulting state |
| Owner/Admin global and Seller historical reporting | Correct scopes and attribution; former assignee retains historical figures but cannot inspect visit details |
| Trusted service role submits public visit request | Accepted-only response; repeat is idempotent; exactly one new visit persists |
| Owner blocks a vehicle with a pending visit | Only the pending visit is cancelled; the existing final result remains unchanged |

The HTTP run exposed an opening-hours RPC failure (`400`, SQLSTATE `21000`,
`DELETE requires a WHERE clause`) that pgTAP alone had not caught. Additive
migration `20261106210000_visit_opening_hours_safe_update.sql` supplies the
constraint-equivalent weekday predicate `weekday between 0 and 6`; this includes
all rows permitted by the table constraint and preserves atomic whole-schedule
replacement. The historical migration and authorization/locking rules are
unchanged. The complete pgTAP suite then passed **1679/1679 across 35 files**
on a separate disposable stack.

### Authenticated identity without a profile ("ghost")

| Surface | Result |
| --- | --- |
| `GET /rest/v1/profiles` | `200` with `[]` |
| `GET /rest/v1/vehicles` | `200`, published/undeleted only (no staff view) |
| `POST /rest/v1/vehicles` | `403` `42501`, RLS insert policy |
| `get_my_reporting_summary` | `403` `42501` `own reporting access denied` |
| `get_reporting_summary` | `403` `42501` `reporting access denied` |

### Authenticated, inactive staff

| Surface | Result |
| --- | --- |
| `GET /rest/v1/vehicles` | `200`, published/undeleted only |
| `GET /rest/v1/profiles?select=id,is_active` | `200`, its own row with `is_active = false` |
| `get_my_reporting_summary` | `403` `42501` `own reporting access denied` |
| `get_reporting_summary` | `403` `42501` `reporting access denied` |

### `service_role`

| Surface | Result |
| --- | --- |
| `record_vehicle_view` | `200` with `true` on first count, `200` with `false` for the same pair inside the rolling 24-hour window (deduplicated) |
| `GET /rest/v1/vehicle_view_events`, `vehicle_view_dedup`, `profiles` | `403` `42501` (no select grant) |
| `get_reporting_summary`, `get_my_reporting_summary` | `403` `42501` (execute revoked from `service_role`) |
| `POST /rest/v1/vehicles` | `403` `42501` (no insert grant) |

## Behavioral notes

- A `PATCH` that matches zero rows (RLS filters the target away) returns `200`
  with an empty representation, not `403`. Authorization is proven by the
  unchanged stored value, not by the status code alone.
- Denied calls left the all-public-table database state hash unchanged in every
  tested section: anon, unauthorized staff identities and `service_role`.
- `submit_inquiry` through `service_role` returns `{"accepted": true}` and is
  idempotent on `p_submission_id` over HTTP: a repeat returns `200` and stores
  no second row.
- The `service_role` key works only when both `apikey` and `Authorization`
  carry it; PostgREST derives the role from `Authorization`.
- Wrong parameter names fail closed with `404` `PGRST202`, never with a
  partial execution.

## Not verified here

- No claim about the public detail-page capture point or the known-bot
  User-Agent filter; that integration is a separate slice.
- No UI or backoffice behavior: every statement above is HTTP/PostgREST only.
- No remote environment: the runner targets the local stack and creates and
  removes its own fixtures.

## Verification

- `python scripts/test-auth-http.py`
- `python -m unittest discover -s scripts -p test_http_support.py` (5/5)
- `python scripts/test-http-db.py` (1679/1679 across 35 files, disposable project)
