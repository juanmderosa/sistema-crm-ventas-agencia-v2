# Verification strategy

Status: strategy for business flows. The local stack now applies two versioned migrations and runs pgTAP suites. Verified: 36/36 database tests passing (21 identity, 15 inventory), pnpm frozen-lockfile installation, typechecks, production builds, loopback HTTP smoke checks, Supabase REST `200`, Auth health `200`, rejected public signup `422`, and real API enforcement (`/rest/v1/vehicles` `200 []` and `/rest/v1/profiles` `401` with the anon key).

## Verified database checks

| Command | Scope |
|---|---|
| `pnpm db:reset` | Reapply migrations and seed from scratch |
| `pnpm db:test` | pgTAP suites under `supabase/tests` |

Current coverage: staff roles and profile isolation, seller mutation denial, anonymous signup rejection, last active Owner protection (demote, deactivate, delete), profile/auth-user foreign key, vehicle visibility for anonymous/active/inactive callers, draft and soft-delete isolation, inventory write denial for sellers, Owner/Admin inventory writes and the year constraint.

No test yet covers inquiries, visits, reservations, sales or reporting, because those tables do not exist.

On Windows, PowerShell resolves a `.ps1` shim before `.cmd`, so a disabled script-execution policy breaks `npm` but not pnpm when only the `.cmd` shim is installed. Use `pnpm.cmd` only as the fallback when a `.ps1` shim is present and blocked.

## Planned layers

| Layer | Planned tool | Purpose |
|---|---|---|
| Unit | Vitest | Input normalization, domain decisions, pricing and metric calculations |
| Component | Testing Library | Forms, validation, interactive states and accessible behavior |
| Database | pgTAP | Policies, constraints and transactional functions |
| Integration | Local Supabase | Real Auth, API, Storage, role enforcement and concurrency |
| End-to-end | Playwright | Public inquiry, visit and private commercial journeys |

Tools above retain the original plan's testing proposals; exact versions and commands await setup and compatibility verification. Do not invent runnable commands before a manifest exists.

## Acceptance scenarios

| Area | Required observable proof |
|---|---|
| Roles | Owner/Admin parity except administrator management; Seller cannot read/edit unauthorized records through direct backend calls |
| Invitations | No public registration path; valid invitation and recovery journeys; expired sessions and deactivated users denied |
| Initial Owner | Manually invoked bootstrap script creates the initial Owner without public signup, refuses routine reruns when an active Owner exists, protects privileged credentials; controlled rerun verifies the intended Auth identity before filling a missing Owner profile only when no active Owner exists; ambiguous states fail closed and no identity is deleted automatically; no remote execution without separate authorization |
| Inventory authorization | Seller cannot create, publish, edit price/details, mark sold or soft-delete through direct backend calls; seller may only reserve an Available vehicle through an active inquiry assigned to self, never by generic vehicle update or coworker inquiry; Owner/Admin retain general inventory access |
| Inventory read access | Active seller can read every vehicle and internal price, including unpublished and price-on-request vehicles; no general inventory writes or access to coworkers' inquiries is granted; anonymous draft/hidden-price access stays denied |
| Inquiry eligibility | All active sellers eligible for every vehicle, including newly activated sellers; no per-vehicle seller exclusions, vehicle ownership or creator auto-assignment |
| Administrative participation | New vehicle form preselects no Owner/Admin; individual selection enables only those people, not their whole role; active enabled participants join the same rotation and continuity rules without fallback priority or changing administrative permissions |
| Administrative participation removal | Owner/Admin may remove a selected individual from a vehicle's commercial participation after creation; no new assignment including continuity; existing inquiries remain assigned and accessible until explicit reassignment; administrative permissions are unchanged |
| Administrative participation addition | Owner/Admin may enable a specific active Owner/Admin after vehicle creation for future inquiries without automatically transferring any existing inquiry; role-wide eligibility remains disabled |
| Administrative participation lifecycle | Removing a commercial Owner/Admin participant blocks new assignments including continuity, but preserves existing inquiry responsibility/access until explicit reassignment; deactivation denies operational access and leaves open inquiries pending handling |
| Publication | Draft data/images inaccessible anonymously; reserved visible; sold excluded from catalog with informative page |
| Sold alternatives | Action opens editable category/type search and creates no inquiry; no sold visit request |
| Pricing | Base/currency conversion, rate history, all display modes; hidden price absent from public payloads and excluded from price ranges |
| Images | Client optimization and preview; server rejects invalid content, dimensions, animation and oversize result; order/cover preserved |
| Routing | Single eligible assignee, shared round robin among eligible sellers and enabled active administrative participants, active-contact continuity with priority, most-recent eligible inquiry, no-eligible-assignee inbox and general WhatsApp; seller inquiry privacy remains enforced |
| Submission integrity | Distinct concurrent submissions from the same normalized contact produce separate inquiries in a consistent order; the later one sees the earlier active inquiry and keeps its assignee when eligible, otherwise follows the normal fallback; concurrent submissions preserve rotation; duplicate submission ID produces one inquiry even on late retry; reuse with changed data is rejected; retry response reveals no private data; distinct intended submissions use distinct IDs |
| Contact privacy | Normalized international phone matching; no public disclosure of previous data; discrepant public name/email never overwrites existing contact fields and is retained on the new inquiry for authorized review; manual authorized corrections remain available |
| Contact corrections | Seller may correct name/email only for contacts linked to own inquiries; backend denies seller phone changes; Owner/Admin may change phone to an unused normalized number; collision is rejected with explicit message and unchanged contacts/inquiries, including concurrent collisions; no merging; shared contact access never exposes coworkers' inquiries |
| Visits | Inquiry linkage and same routing; requested time is tentative; confirmation/reprogramming and attention hours handled correctly |
| CRM | Correct active states; WhatsApp click alone does not mark contact; seller can report a sale on own inquiry but cannot mark vehicle Sold; the only seller availability change is a linked reservation from own active inquiry; Owner/Admin explicitly confirms vehicle sale without closing other inquiries |
| Sale review handoff | Seller reporting Venta concretada on a reserved inquiry creates a pending Owner/Admin task but no counted vehicle sale; cannot mark the reserved inquiry Cerrada sin venta while reservation is active; Owner/Admin ends the active reservation and marks vehicle Sold, or cancels it and corrects the inquiry to Cerrada sin venta with history, resolving the task coherently; other inquiries remain unchanged |
| Reported sale vehicle | Sale report selects a vehicle listed as interest on the inquiry; if it has an active reservation only that vehicle is valid, otherwise an Available interest can be reported without prior reservation; backend rejects vehicle reserved by another inquiry or Sold; review task carries selected vehicle; Owner/Admin rechecks vehicle state before confirming Sold |
| Sale confirmation versus competing reservation | Another inquiry reserves an Available vehicle after a sale is reported without reservation: backend rejects confirming Sold for the reporting inquiry while that reservation remains active; it is not cancelled automatically, review remains pending, and Owner/Admin must explicitly resolve it; concurrent reserve/confirm attempts cannot both succeed |
| Sale metric source | Count confirmed vehicle Sold transitions, not seller-reported CRM statuses or duplicate review tasks; exact period attribution and reversal behavior are defined before reporting implementation |
| Multi-vehicle sale outcome | Confirming one interested vehicle Sold leaves its inquiry in Venta concretada for that vehicle, retains other interests as historical context and does not count or close them as sales or mutate other customers' inquiries |
| Reopening | Seller may reopen own closed-without-sale inquiry but cannot reopen a completed sale; Owner/Admin may reopen either result; destination is En seguimiento, history preserved, coworkers' inquiries protected and vehicle availability unchanged |
| Reassignment | Previous seller loses inquiry-detail access through direct backend calls and private UI/cache refresh; historical activity attribution remains in authorized statistics without detail leakage; new assignee gains authorized inquiry access and Owner/Admin retain global access |
| Administrative assignee transfer | Owner/Admin can explicitly reassign an inquiry already handled by Owner/Admin; prior handler loses commercial responsibility but retains global administrative access, and assignment history remains intact |
| Reassignment eligibility | Backend rejects manual transfer to an inactive seller or an inactive/non-enabled Owner/Admin for the originating vehicle; restoring eligibility allows a later explicit transfer; failed attempts leave assignment and history unchanged |
| Multi-vehicle interest | Seller may add Available vehicles only to own active inquiry; one inquiry records several interests without new inquiry/automatic reservation; later reservation elsewhere leaves interest recorded but disables new reservation until available again; any currently Available listed interest, even one other than originating vehicle, may be reserved from own active inquiry; direct backend requests cannot add interest to coworker's inquiry; at most one active reservation per inquiry |
| Multi-vehicle visits | Visit from an existing active inquiry identifies exactly one of its vehicles of interest and reuses that inquiry without creating another or reserving the vehicle; public vehicle-page visit still creates a new inquiry using regular assignment; seller cannot request a visit from coworker's inquiry |
| Reserved inquiry transfer | Backend rejects reassignment while the inquiry has an active reservation, including concurrent attempts to cancel/reassign; after cancellation, active inquiry transfer follows normal eligibility rules, while a closed inquiry still needs authorized reopening |
| Closed-inquiry transfer | Backend rejects direct reassignment of either closed result without changing assignment/history; authorized reopening moves to En seguimiento, then Owner/Admin may reassign to an eligible person; prior result remains in history and vehicle availability is unchanged |
| Reservations | Seller can reserve only an Available vehicle listed as interest on own active inquiry, whether original or added later; reservation and Reserved state are atomic and linked to the specific vehicle/inquiry/contact; competing attempts permit only one active reservation per vehicle and per linked inquiry and leave no partial changes; switching vehicles requires prior cancellation, retaining history; seller can cancel only active reservation linked to currently assigned own inquiry, atomically returning that vehicle to Available; Owner/Admin retain general management with optional inquiry link; no automatic expiry or payment processing |
| Tasks | Due/pending/overdue behavior, authorized visibility and no email/WhatsApp reminders |
| Lifecycle | Deactivation and soft delete preserve history and remove operational/public eligibility as specified; deactivating seller with an active reservation revokes access immediately but leaves vehicle Reserved and alerts Owner/Admin to resolve it before reassignment; inactive seller cannot cancel through an old session; backend rejects deactivation or role removal of last active Owner, including concurrent attempts |
| Reporting | Views not unique people; vehicle views not multiplied by eligible seller count; multi-vehicle inquiry counted once for originating vehicle, other vehicles recorded as interests without duplicating inquiries; visits, reservations and confirmed sales attributed to their actual vehicle; separate linked goals and historical attribution; authorized periods |
| Failure | Network loss, retry, expired session and backend rejection produce explicit states without duplicate or partial critical records |

Do not add destructive cross-agency runtime tests before multiagency scope exists; schema design must still account for future evolution. Do not claim aggregate traffic proves causal conversion. Specify period/cohort rules and zero-denominator behavior before asserting metric expectations.

## Test-first and closure

For deterministic behavior with a runnable harness: observe a meaningful failing test, implement the change, then refactor while green. Test the public interface and persisted effects, not merely helper implementation details. Real backend permission tests cannot be replaced with mocks.

Each functional delivery must pass applicable formatting, lint, strict types, focused tests, relevant suites and build. Document exact commands and outcomes when tooling exists. Review mobile/desktop, keyboard access, empty/loading/error states and actual optimized image quality. No global coverage percentage is required.

For the current local shell, typecheck and build both workspaces and verify each loopback-only placeholder responds with HTTP 200. No deterministic business behavior or runnable business tests exist yet; RED/GREEN and backend permission proof remain pending. Never infer infrastructure readiness from shell builds.
