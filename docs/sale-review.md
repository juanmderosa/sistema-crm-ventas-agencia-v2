# Sale reporting and administrative review

Status: T5a reporting is implemented and independently verified locally. Confirmation, rejection and reopening remain pending T5b/T5c. This is not a completed sales flow.

## Report a sale

Authenticated active staff call `report_inquiry_sale(p_inquiry_id uuid, p_vehicle_id uuid)`. Sellers require their own inquiry; Owner/Admin may report any inquiry. The response is `{ "review_id": "<uuid>" }`.

- The inquiry must be active and the selected vehicle must be one of its interests, not deleted and enabled for sale.
- With an active reservation, only that inquiry's reserved vehicle is valid. Without one, the interest must be Available, not reserved elsewhere or Sold.
- Reporting sets the inquiry to `sale_reported`, appends `inquiry_status_history` and creates one pending `sale_reviews` row with the selected vehicle, contact and reporter.
- Reporting does not change vehicle availability, cancel reservations or alter other inquiries. It does not count a confirmed sale.
- A matching pending retry returns the same review ID without another task or history row, even if another inquiry subsequently reserves the vehicle. Current authorization and explicit blocking/deletion checks still apply. A different selected vehicle on a closed/report-pending inquiry is rejected.

Reviews and status history follow the linked inquiry's read permissions. No client, including Owner/Admin, can mutate those tables directly. Resolution must use the controlled administrative operation when T5b is delivered.

## Approved remaining boundaries

Every confirmed sale must have an inquiry and explicit Owner/Admin confirmation. Direct inventory Sold entry will be blocked in T5b. Both reporting and confirmation reject internally blocked vehicles until explicitly unblocked.

Resolve a pending sale review before reopening its inquiry. T5 does not reverse confirmed sales: reopening resumes follow-up without changing Sold inventory or confirmed-sale history.

There is no payment, reservation expiry, notification delivery or reporting formula implementation in this slice.
