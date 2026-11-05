# Auth / PostgREST / JWT HTTP verification

Status: verified against the running local stack (Kong on `127.0.0.1:55321`,
GoTrue and PostgREST), using genuine GoTrue users and JWTs issued by password
grant, not simulated `set role` or forged `request.jwt.claim.sub` claims.
This documents observed HTTP behavior only; it claims no UI, no remote
deployment and no foundation completion.

## Runner

```
python scripts/test-auth-http.py
```

Requires the local stack (`pnpm db:start`), Docker and Python 3 (standard
library only). The runner creates tagged fixtures (GoTrue users, profile rows,
vehicles, rotation participants), probes the HTTP surface and removes what it
created. `protect_last_active_owner` keeps one owner fixture by design; the
runner reports it and `pnpm db:reset` clears it. The last captured run reported
`110 checks, 0 failures`.

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
- Denied calls left the database state hash unchanged in every section of the
  run: anon, non-staff identities and `service_role` denials wrote nothing.
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
- `pnpm db:test` (pgTAP suite, unchanged by this slice)
