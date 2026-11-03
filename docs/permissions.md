# Permission matrix

Status: baseline derived from approved roles, not implemented policies. Owner and Administrator differ only in administrator management.

| Operation | Owner | Administrator | Seller |
|---|---|---|---|
| Manage administrator accounts | Yes | No | No |
| Invite/manage sellers | Yes | Yes | No |
| Manage dealership configuration and exchange rate | Yes | Yes | No |
| Create, publish and edit a vehicle | Yes | Yes | No |
| Edit internal price and vehicle details | All vehicles | All vehicles | No |
| Read inventory, vehicle details and internal prices | All vehicles | All vehicles | All vehicles, read-only; includes public price-on-request listings |
| Reserve an Available vehicle listed as an interest on an active inquiry assigned to self | Yes | Yes | Yes, own inquiry only |
| Cancel an active reservation linked to an inquiry currently assigned to self | Yes | Yes | Yes, own linked reservation only |
| Mark sold and soft-delete a vehicle | Yes | Yes | No |
| Configure optional Owner/Administrator participation when creating a vehicle | Yes | Yes | No |
| Remove a selected Owner/Administrator from a vehicle's commercial participation after creation | Yes | Yes | No |
| Enable a specific Owner/Administrator for a vehicle's future inquiries after creation | Yes | Yes | No |
| Handle commercial inquiries, notes and tasks | All | All | Assigned inquiries only |
| Add an Available vehicle as an interest on an active inquiry | Yes | Yes | Own assigned active inquiries only |
| Correct contact name and email | Yes | Yes | Contacts linked to own assigned inquiries only |
| Change contact phone | Yes | Yes | No |
| Reopen an inquiry closed without sale | Yes | Yes | Own assigned inquiries only; preserve history |
| Reopen a completed-sale inquiry | Yes | Yes | No |
| Confirm/reprogram visit requests | All | All | Assigned inquiries only |
| Request a visit for a vehicle of interest on an existing active inquiry | Yes | Yes | Own assigned active inquiries only |
| Reassign inquiries / assign unassigned inbox | Yes | Yes | No |
| View statistics | Global and seller breakdown | Global and seller breakdown | Authorized own activity |
| Hard-delete vehicle | Not in MVP | Not in MVP | Not in MVP |

## Public access

- No panel registration and no anonymous access to private records.
- Provision the first Owner through a purpose-built script run manually in a trusted environment, not through public signup. Its privileged credential must not enter the browser, repository or logs; account creation and remote execution require separate authorization.
- If Auth identity creation succeeds but Owner profile creation fails, a controlled rerun must verify the identity against the intended account and complete the profile only while no active Owner exists. Never automatically delete an identity as recovery; fail closed on ambiguous or conflicting state.
- Public vehicle data must exclude hidden prices and all internal commercial information.
- Published reserved vehicles accept inquiries and visits; sold pages only link to a similar-vehicle search.
- Draft vehicle details and images remain private.
- Public inquiry/visit submission does not grant access to the matched contact or previous inquiries.

## Enforcement invariants

- Authenticate and authorize every privileged operation server-side. Never trust submitted roles, seller IDs or publication flags.
- Vehicles are not assigned to sellers. Every active seller is eligible for inquiry routing on every vehicle in the MVP; no per-vehicle seller exclusions exist.
- Owner/Administrator may receive inquiries when optionally enabled for the vehicle at creation and active. They join the same round robin and continuity eligibility as sellers, not a fallback pool. Commercial participation never changes their existing administrative permissions.
- Administrative participation selects individual people, never an entire role automatically. No Owner/Administrator is preselected in a new vehicle form.
- Sellers can read all inventory and internal prices, not just published vehicles or those linked to their inquiries. Public price-on-request visibility never hides the internal price from sellers. This grants no general inventory writes or access to coworkers' inquiries.
- Seller availability mutations are limited to an atomic reservation of an Available vehicle listed as an interest on an active inquiry currently assigned to that seller and without another active reservation, and cancellation of their still-active reservation while the linked inquiry remains assigned to them. Reserving links the specific vehicle, inquiry and contact while setting Reserved, rejecting competing attempts for either vehicle or inquiry. Cancellation atomically ends the reservation, restores Available and preserves history; to switch vehicles, cancel first and then reserve another Available interest. Sellers cannot use general vehicle updates or mark Sold.
- Each inquiry has its own assignee; different inquiries for one vehicle can have different sellers. Routing eligibility never grants inventory mutation or access to another seller's inquiries/history.
- Preserve approved active-contact continuity before round robin: active sellers are eligible for all vehicles; an Owner/Administrator is eligible only if individually enabled for the originating vehicle.
- An active inquiry may record several vehicles of interest without creating additional inquiries or reservations. A seller may add one only to an active inquiry assigned to them; the vehicle must be Available at that moment. Later reservation elsewhere leaves the interest visible but prevents reserving that vehicle until availability returns. Any currently Available listed interest, including a vehicle other than the originating one, may be reserved from that inquiry, but at most one reservation can be active per linked inquiry. Count the inquiry once for its originating vehicle; record other vehicles as interests rather than new inquiries.
- A visit created from an existing active inquiry identifies one of its vehicles of interest and links to that inquiry, without creating another inquiry or reserving the vehicle. Public visit requests from a vehicle page still create a new inquiry through the standard routing flow. Attribute each visit, reservation and confirmed vehicle sale to its own identified vehicle rather than multiplying the originating inquiry.
- Removing an Owner/Administrator from a vehicle's commercial participation likewise blocks new assignments for that vehicle, including continuity, without revoking their existing inquiry ownership/access or administrative role. Explicit reassignment changes existing inquiry ownership.
- A seller closing an inquiry as a sale cannot change the vehicle's availability; only Owner/Administrator may confirm that inventory action.
- Reporting Venta concretada must identify a vehicle listed among that inquiry's interests. With an active reservation on the inquiry, only its reserved vehicle may be reported; without one, reporting an Available interest is allowed. Reject a report for a vehicle Reserved by another inquiry or already Sold. An inquiry anchoring an active reservation may not be closed as Cerrada sin venta while that reservation remains active. Seller reporting a sale creates a pending Owner/Administrator review task without confirming a vehicle sale. Owner/Administrator resolves it by ending any active reservation and explicitly marking the reported vehicle Sold, or by cancelling the reservation if any and correcting that inquiry to Cerrada sin venta with history. Other inquiries remain unchanged. Keep each resolution coherent under concurrent requests.
- Confirming a sale of one interested vehicle leaves that inquiry closed as Venta concretada for the confirmed vehicle; all other interests remain historical only, without additional sales or changes to other customers' inquiries.
- If another inquiry reserves the reported vehicle before an unreserved sale is confirmed, backend must reject marking it Sold for the reporting inquiry while that reservation is active. Only Owner/Administrator may explicitly resolve that reservation first; neither the seller's report nor confirmation may silently cancel or displace it. Keep the review pending until a valid resolution.
- Authorized reopening always returns the inquiry to En seguimiento, preserving history without changing vehicle availability.
- Manual reassignment is allowed only for active inquiries. To transfer a closed inquiry, an authorized user must first reopen it under the approved status-specific permissions; Owner/Administrator may then assign it to a currently eligible person. Reject direct closed-inquiry reassignment without changing assignment or history.
- Phone matching is not authentication; never reveal or overwrite private contact data based solely on an anonymous match.
- Owner/Administrator phone corrections are allowed only when the normalized target number does not identify a different contact. Reject a collision with an explicit message and unchanged records; no merging or distinct contacts sharing one phone in the MVP.
- Deactivation removes operational access and assignment eligibility while preserving historical attribution. Existing session revocation must be tested.
- Deactivating a seller with an active reservation revokes access immediately but does not cancel or release that reservation. Surface it for Owner/Administrator review; they must resolve the reservation before reassigning its linked inquiry. Do not allow the inactive seller to cancel it through an old session.
- Reject deactivation or role removal of the last active Owner in the backend, including concurrent account changes; do not rely on a UI check alone.
- Administrative reassignment revokes the previous seller's inquiry detail access while preserving historical activity attribution in statistics. Statistical reports must not expose the reassigned inquiry's detail or offer a drill-through that bypasses authorization. Owner/Administrator retain global access.
- Owner/Administrator may explicitly transfer an already assigned inquiry from an Owner/Administrator to another assignee at any time; this changes commercial responsibility but not either administrator's global administrative permissions. A previous seller still loses inquiry-detail access as specified above.
- A manual reassignment may target only someone currently eligible for the inquiry's originating vehicle: an active seller or an active, individually enabled Owner/Administrator. Reject reassignment to an ineligible person server-side; existing ownership is unaffected until an explicit reassignment succeeds. Multi-vehicle interest edge cases require explicit rules before implementation.
- Reject reassignment of an inquiry while it anchors an active vehicle reservation. Cancel the reservation first or have Owner/Administrator resolve the sale; only then apply normal active-inquiry reassignment or closed-inquiry reopening rules. The check and any reassignment must be protected against concurrent reservation changes.
- Owner/Administrator access parity applies to all ordinary dealership operations, not just rows listed here.
- Shared contact edits use mandatory optimistic revision checks: reject a stale edit without changes and request reload. Owner/Admin phone collisions are rejected without merging. Real phone parsing and UI conflict handling remain pending.

## Open decisions before policy implementation

- Exact bootstrap script implementation and exceptional recovery if no active Owner remains due to an external failure; ambiguous or conflicting partial states require manual resolution.
- Other corrections to closed inquiries outside the approved Owner/Administrator sale-review correction; reopening never changes inventory availability automatically.
- Permitted CRM actions of other inquiry assignees while a vehicle is reserved.
- Asset visibility transitions and retention; exact statistics projections must preserve the approved detail-access revocation after reassignment.

These gaps must not be interpreted as permission grants. This document does not implement authentication or RLS.
