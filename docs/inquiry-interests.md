# Add vehicle interests without duplicating inquiries

`add_inquiry_interest(p_inquiry_id uuid, p_vehicle_id uuid)` adds one Available,
non-deleted vehicle to an active inquiry. It returns `{"accepted":true}` without
creating an inquiry, reservation or assignment event. This implements T3c1,
S8 and the interest-addition portion of S16; contact changes are a separate unit.

## Call contract

Call the RPC as `authenticated` in a READ COMMITTED transaction. The actor comes
from `auth.uid()`, never a supplied staff identifier. PUBLIC and anonymous
execution are revoked. No direct table write privileges are added.

| Caller or input | Result |
|---|---|
| Active Owner or Admin | Any active inquiry, including unassigned inquiries |
| Active seller | Currently assigned own active inquiry only |
| Inactive or missing staff profile | Denied |
| New, Contacted, Following up | Active |
| Sale reported or Closed without sale | Rejected for every role |
| Available published or draft vehicle | Accepted |
| Reserved, Sold, soft-deleted or missing vehicle | Rejected |
| Existing interest | Same acknowledgement, no duplicate or timestamp update |

Retries recheck current permissions, inquiry status and availability. An interest
remains historical when its vehicle later becomes Reserved or Sold, but that does
not permit a new addition or bypass validation on retry. Draft selection is
intentional: staff inventory access is broader than public catalog access.

## Errors and preservation

- `42501`: `inquiry interest access denied` for unauthorized staff or missing inquiry.
- `22023`: `inquiry is not active` for either closed status.
- `22023`: `vehicle must be Available and not deleted` for invalid inventory.
- Anonymous execution fails at the PostgreSQL function privilege boundary.

The operation preserves the originating vehicle, assignee, status, submitted
snapshots, contact, rotation cursor, assignment history and vehicle availability.
Existing read policies are unchanged. No removal, reassignment, reservation or
status API is included.

## Locking and verification

Locks are acquired on the selected vehicle (UPDATE), actor profile (SHARE), then
inquiry (UPDATE). Vehicle-before-profile ordering matches `submit_inquiry`.
The profile lock blocks deactivation/role changes; the inquiry lock blocks closure
and reassignment; the vehicle lock blocks availability changes and soft deletion.
All persist until transaction end. Future workflow APIs must preserve compatible
lock ordering rather than holding an inquiry and then requesting these locks.

Focused regression: `pnpm exec supabase test db supabase/tests/0007_inquiry_interest_operations_test.sql`.
The suite uses synthetic JWT subjects and database roles, checks exact errors,
and hashes all commercial rows plus the inquiry allocation counter on rejection.
Success checks the requested link and unchanged non-interest state. Disposable
database scaffolding does not prove real Auth sessions or overlapping races;
parent integration and independent concurrency/security verification remain required.
