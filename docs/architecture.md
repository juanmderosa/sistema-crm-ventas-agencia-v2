# Architecture baseline

Status: approved boundaries; implementation design and infrastructure validation pending.

## Applications and boundaries

| Boundary | Responsibility | Must not own |
|---|---|---|
| Public Next.js app | Public catalog, vehicle details, inquiry and visit forms, branding | Privileged keys, hidden prices, private CRM history |
| Private Next.js app | Authorized inventory, CRM, tasks, visits and reporting | Authorization enforced only through UI |
| Supabase PostgreSQL | Records, constraints, policies, transactional commercial operations | Public access to unrestricted internal records |
| Supabase Auth | Identity, session and invitation/recovery integration | Business permissions inferred from client-supplied role |
| Supabase Storage | Vehicle images and branding assets | Anonymous access to draft assets |

Proposed workspace layout: `apps/public`, `apps/panel`, narrowly scoped `packages/*`, and versioned Supabase migrations. These directories do not exist yet and this is not an installed scaffold.

Organize application behavior by dealership configuration, users, inventory, inquiries, CRM, visits and reporting. Share types, validation and UI primitives only when useful. Keep server-only and browser-safe exports separate. No general-purpose repository/service abstraction is required by this document.

Commercial rules and their acceptance scenarios must be expressed independently of Next.js and Supabase. Keep provider-specific Auth, persistence, image and email integration at narrow application boundaries where they are needed. This does not move authorization or transactional assignment into the browser: the backend must enforce both. A future backend change must preserve the observable business behavior, while database policies, transactional implementation and integrations require explicit migration and verification. Do not introduce generic provider interfaces without a concrete second implementation or demonstrated need.

Public pages should support server rendering; interactive components use client boundaries. Private caches must include user/authorization context and be cleared on session changes. URL owns catalog filters, sort and pagination; remote records are not duplicated into a global store.

## Data concepts, not an approved SQL schema

Dealership configuration; user profiles and roles; vehicles; images; per-vehicle optional Owner/Administrator commercial participation; contacts; inquiries with originating vehicle and multiple vehicles of interest; assignment history; rotation state; activities; tasks; visit requests; reservations and their optional inquiry links; exchange-rate history; audit records; pageview events or aggregates.

Vehicles have no seller owners, creator auto-assignment or per-vehicle seller exclusions in the MVP. Owner/Administrator manage general inventory mutations, including prices, publication, sale availability and soft delete. A seller's only approved vehicle-availability mutations are the restricted reservation from an active inquiry assigned to them and cancellation of their own active linked reservation. All active sellers are eligible for inquiries on every vehicle; newly activated sellers inherit that default without bulk assignments. Each inquiry has one responsible person and may record several vehicles of interest without creating new inquiries or reservations. Eligibility alone grants neither inventory writes nor access to coworkers' inquiries.

Future multiagency support must not require copies of the product. The exact choice of organization keys and migration path is pending schema design; do not claim a multi-tenant security model is already implemented.

Account changes must preserve at least one active Owner. Enforce this invariant server-side under concurrent deactivation or role changes; exceptional recovery remains to be specified.
Provision the initial Owner with a purpose-built script invoked manually from a trusted environment. Keep privileged credentials out of browser bundles, source control and logs. Reject a routine bootstrap when an active Owner already exists. If Auth identity creation succeeds but profile creation fails, a controlled rerun verifies the identity belongs to the intended account and completes the missing profile only if no active Owner exists; fail closed on ambiguity and never delete the identity automatically. Test this recovery before use. No remote account creation is authorized by this document.

## Inquiry transaction

1. Validate public input and submission identity; determine vehicle server-side.
   The client supplies a random submission ID, reused only for technical retries. Persist it uniquely with the inquiry for the lifetime of that inquiry, without a separate expiration window. Reject reuse with different submission data; return only a privacy-safe outcome for identical retries. A new intentional inquiry needs a fresh ID. Idempotency does not replace abuse protection.
2. Resolve normalized-phone contact without exposing prior records to the caller. Keep existing contact name/email unchanged on discrepant public input; retain submitted values on the new inquiry for authorized review instead of overwriting shared data.
3. Resolve eligible assignees as all active sellers plus active Owner/Administrator participants individually enabled for the originating vehicle. Select the owner of the most recent eligible active contact inquiry for continuity; otherwise use one shared single-assignee/round-robin/unassigned path without role-based fallback priority.
4. Persist inquiry, assignment history and optional visit coherently; retries return the existing submission outcome.
5. Return a minimal confirmation and authorized commercial contact, not internal CRM data.

Administrative eligibility is an explicit per-person choice at vehicle creation, with no preselected administrative users and no role-wide automatic inclusion. Owner/Administrator may enable another individual after creation for future inquiries only, with no automatic transfer of existing inquiries. Removing an individual later blocks new assignments for that vehicle, including continuity, while already assigned inquiries and access remain until explicit reassignment; the administrative role is unchanged.

Maintain one contact per normalized phone within the dealership. An authorized phone correction to an unused number is allowed; reject a collision with a different contact without changing either record or their inquiries. Enforce uniqueness transactionally, not just with a prior client check. Shared-phone identities and contact merging are outside this MVP.

Distinct concurrent submissions for the same normalized contact must be ordered so the later submission sees the earlier committed active inquiry and applies continuity when its assignee remains eligible for the later vehicle. Each intentional submission still creates its own inquiry; a retry of the same submission does not. Concurrent submissions must not corrupt rotation. Exact transaction, locking, payload comparison and equal-timestamp tie-break implementation remain pending; the submission ID has no separate expiry while its inquiry is retained.
Adding a vehicle of interest to an active inquiry requires that vehicle to be Available at the time of addition; this is not a reservation. If another inquiry later reserves it, retain the historical interest and show its changed availability. Any listed interest, not only the originating vehicle, can be reserved while Available; the reservation must identify the specific vehicle, inquiry and contact. At most one linked reservation may be active per inquiry: changing vehicles requires cancellation first and preserves reservation history. Each visit identifies a specific interest vehicle and an existing inquiry when initiated from its CRM record; a public vehicle-page visit still creates a new inquiry. Neither visit path creates a reservation. Count each inquiry once for its originating vehicle; store other vehicles as interests and attribute visits, reservations and confirmed sales to their specific vehicles without duplicating inquiries. Temporal metric formulas remain pending.

## Storage and public delivery

Client image optimization is a convenience, not a trust boundary. Validate actual server-received content, dimensions and size. Keep uploads private until accepted; derive public visibility from publication rules. Publication changes and retained URLs/caches need explicit tests.

Do not include hidden prices in public payloads, metadata or filter/sort calculations. Authenticated sellers may read all inventory and internal prices, independently of public publication/price visibility or inquiry ownership. Keep that read-only access separate from inventory writes and inquiry-level authorization. A seller reporting a sale cannot mark the vehicle Sold; that action belongs to Owner/Administrator. Preserve inquiry-level scope and reassignment history.
Reserve from inquiry is a dedicated backend operation, not general vehicle editing: verify the actor owns an active inquiry with no active reservation and that the selected vehicle is among its interests and still Available, regardless of originating vehicle; in one transaction create the reservation linked to that exact vehicle, inquiry and contact and transition the vehicle to Reserved, with database guards against more than one active reservation per vehicle or per linked inquiry. A losing concurrent request must not leave a partial reservation or availability update. Seller cancellation is likewise a dedicated atomic operation restricted to the active reservation linked to an inquiry currently assigned to that seller: end the reservation, restore Available and preserve history. Owner/Administrator retain general reservation management. Reject reassignment of the inquiry while its reservation is active, checking consistently with concurrent cancellation and reservation changes; after cancellation, normal active/closed inquiry rules apply. Deactivating its seller revokes operational access immediately without releasing the reservation; Owner/Administrator must resolve it before reassignment. CRM restrictions for other inquiry assignees remain open.
Reporting Venta concretada identifies a specific interest vehicle: with an active inquiry reservation it must be that reserved vehicle; without a reservation it must be Available. Reject reporting a vehicle reserved by another inquiry or already Sold. An inquiry anchoring an active reservation cannot transition to Cerrada sin venta until the reservation is cancelled. Persist an Owner/Administrator review task with the reported vehicle as part of the seller's report; this is not a confirmed vehicle sale. Owner/Administrator resolves the task by atomically ending any active reservation and marking the reported vehicle Sold, or by cancelling any active reservation and correcting the inquiry to Cerrada sin venta with history; other inquiries remain unchanged. Recheck vehicle state on confirmation to avoid competing claims. Count a vehicle sale only on the authorized Sold confirmation, not on the seller's CRM status. Prevent duplicate counting of the same unit; temporal attribution and reversal rules remain for reporting design.
After confirmation, the reporting inquiry remains closed as Venta concretada for the specific Sold vehicle. Preserve other interest vehicles in its history without additional sales or changes to other inquiries. A seller's report alone still does not count as a confirmed sale.
For an unreserved reported sale, a reservation made by another inquiry before administrative confirmation blocks the vehicle's Sold transition for the reporting inquiry. Resolve the other reservation explicitly first; do not automatically cancel or transfer it. Keep the sale-review task pending until an authorized, valid decision. Enforce this under concurrent reservation and confirmation requests.

Changes to optional Owner/Administrator participation block new assignments, including continuity selection, without changing existing inquiry ownership or authorized access. Do not use present routing eligibility as the authorization predicate for an existing inquiry. Only explicit administrative reassignment changes that ownership; user deactivation remains a separate access and reassignment workflow.

Reassignment revokes inquiry-detail access for the previous seller. Historical activity attribution remains available in authorized statistical aggregates, not a backdoor to inquiry details. Owner/Administrator global permissions remain unchanged. Private caches and direct backend requests must respect the changed ownership.
Explicit administrative reassignment can also transfer an inquiry previously handled by an Owner/Administrator. The former administrator stops being its commercial assignee but retains global administrative access; assignment history and the new assignee's authorized access must remain consistent.
For every manual reassignment, validate the destination against current eligibility for the originating vehicle in the backend as part of the ownership change. Inactive sellers and inactive or non-enabled administrators cannot be selected as new assignees even when an administrator initiates the transfer; previously assigned inquiries remain intact unless explicitly reassigned. Multi-vehicle interest exceptions remain to be specified.
Closed inquiries cannot be reassigned directly: an authorized actor must first reopen the inquiry to En seguimiento under the existing status-specific rule, then Owner/Administrator can reassign it. Preserve the closed result and reopening in history; reopening does not change vehicle availability.

## Infrastructure validation gates

| Gate | Required evidence | Current status |
|---|---|---|
| Two Next.js deployments | Builds, runtime compatibility, routes and free addresses | Not run |
| Free hosting envelope | CPU, bundle, requests, assets and caching fit actual build | Not run |
| Storage envelope | Measured photo sizes, retained inventory, storage and bandwidth headroom | Not run |
| Authentication email | Real invitation and recovery delivery, redirect allowlist and free quota | Not run |
| Backend security | Local real-backend authorization and private asset tests | Not run |
| Recovery | Reproducible schema and documented data/image recovery procedure | Not run |

No remote probe, account use or deployment is authorized by this design document.

## Source checks performed on 2026-11-02

- [Supabase Storage pricing](https://supabase.com/docs/guides/storage/pricing): Free storage quota was 1 GB. 100 × 12 × 1 MB is approximately 1.2 GB, before retained assets and variants; capacity is not guaranteed.
- [Cloudflare Workers limits](https://developers.cloudflare.com/workers/platform/limits/): validate free CPU and bundle limits against the real build; no adapter chosen.
- [Cloudflare Next.js guide](https://developers.cloudflare.com/workers/framework-guides/web-apps/nextjs/): recheck supported deployment path when conducting the compatibility test.
- [Vercel Hobby](https://vercel.com/docs/plans/hobby): restricted to personal noncommercial use; not selected for dealership hosting.
- [shadcn/ui](https://ui.shadcn.com/docs): source-based editable components; local customization entails maintenance responsibility.

Reverify changing quotas and terms before account setup or deployment. Research is not production proof.
