# Sale reporting and administrative review

Status: reporting, resolution and reopening are locally and independently verified; all three native reviews are approved and acknowledged. T5 database scope is complete. No UI or real Auth/PostgREST end-to-end completion is claimed.

## Report a sale

Authenticated active staff call `report_inquiry_sale(p_inquiry_id uuid, p_vehicle_id uuid)`. Sellers require their own inquiry; Owner/Admin may report any inquiry. The response is `{ "review_id": "<uuid>" }`.

- The inquiry must be active and the selected vehicle must be one of its interests, not deleted and enabled for sale.
- With an active reservation, only that inquiry's reserved vehicle is valid. Without one, the interest must be Available, not reserved elsewhere or Sold.
- Reporting sets the inquiry to `sale_reported`, appends `inquiry_status_history` and creates one pending `sale_reviews` row with the selected vehicle, contact and reporter.
- Reporting does not change vehicle availability, cancel reservations or alter other inquiries. It does not count a confirmed sale.
- A matching pending retry returns the same review ID without another task or history row, even if another inquiry subsequently reserves the vehicle. Current authorization and explicit blocking/deletion checks still apply. A different selected vehicle on a closed/report-pending inquiry is rejected.

Reviews and status history follow the linked inquiry's read permissions. No client, including Owner/Admin, can mutate those tables directly.

## Resolve a reported sale

An active Owner/Admin calls `resolve_sale_review(p_review_id uuid, p_confirm boolean)` with an explicit decision. The response is `{ "review_id": "<uuid>", "status": "confirmed|rejected", "sale_id": "<uuid>|null" }`.

- Confirmation rechecks current vehicle visibility/eligibility, interest linkage and active reservations. Another inquiry's reservation blocks confirmation and leaves the review pending; resolve that reservation explicitly first.
- Confirmation completes this inquiry's active reservation with `completed_by` and an end timestamp, rather than labelling it cancelled. It creates one durable `confirmed_sales` record per vehicle, preserving the contact, inquiry, responsible staff and confirming actor, then marks that vehicle Sold atomically.
- Rejection reuses the controlled cancellation operation for this inquiry's active reservation, then records the correction to `closed_without_sale` and resolves the review. It does not cancel another inquiry's reservation or change other inquiries or vehicles.
- A retry with the same resolved decision returns the original resolution and sale ID without another sale or history entry. A different decision is rejected; confirmed sales cannot be reversed.
- Confirmed-sale reads follow the linked inquiry's authorization. Application roles cannot mutate confirmed-sale history directly.

Direct Owner/Admin inventory insert/update cannot introduce Sold without a confirmed record. Confirmed inventory cannot return to Available/Reserved. Database-owner maintenance and test fixtures outside an application role are privileged SQL, not an application API; the trigger does not pretend to constrain the PostgreSQL owner. Application-role tests exercise the guard even when connected through a privileged disposable test connection. No new application caller receives that maintenance path.

Pending review blocks inquiry contact/responsibility changes and reopening, including trusted service-role updates. The resolution operation preserves vehicle → actor → inquiry lock order and resolves the review before correcting the inquiry status.

## Reopen an inquiry

Authenticated active staff call `reopen_inquiry(p_inquiry_id uuid)`. The response is `{ "inquiry_id": "<uuid>", "status": "following_up" }`.

- Sellers may reopen only their own `closed_without_sale` inquiries, including a sale explicitly rejected by Owner/Admin.
- Owner/Admin may reopen either closed result, regardless of assignee. A `sale_reported` inquiry requires its administrative review to be resolved first; a pending report cannot be reopened.
- Reopening appends an actor-attributed status-history row, preserves previous history and returns to `following_up`. It never changes availability, reservations, review decisions or confirmed-sale history; a confirmed vehicle stays Sold.
- Active inquiries, repeated reopening of an already active inquiry and unauthorized callers are rejected without changes.

## Scope boundaries

Every confirmed sale must have an inquiry and explicit Owner/Admin confirmation. Direct application inventory Sold entry is blocked. Both reporting and confirmation reject internally blocked vehicles until explicitly unblocked.

Resolve a pending sale review before reopening its inquiry. T5 does not reverse confirmed sales: reopening resumes follow-up without changing Sold inventory or confirmed-sale history.

There is no payment, reservation expiry, notification delivery or reporting formula implementation in this slice.
