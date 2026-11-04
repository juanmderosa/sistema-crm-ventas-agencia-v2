# Decisions and unresolved gates

Date: 2026-11-02. Product approval is recorded in the conversation and project memory. This log does not grant deployment authority.

## Approved baseline

Historical closure attribution approved on 2026-11-04: preserve missing historical responsibility as unknown; do not backfill from the current assignee or recording actor. New closure events capture the responsible person when recorded. Distinguish a known unassigned inquiry from unavailable historical attribution.

Reporting clarification approved on 2026-11-04: each closed-without-sale recording is a separate outcome event, including a later closure after reopening. Attribute each event to the responsible person when recorded. Reopening does not erase earlier closure events or increase the inquiry count. This does not change the once-only confirmed-sale rule.

| Decision | Reason | Consequence |
|---|---|---|
| Single dealership first | Reduce initial platform scope | Future multiagency requires design and migration work, not a feature toggle |
| Two Next.js apps, one repository | Separate public/private experiences and deployments without two frameworks | Two deployment configurations; shared code must preserve server/private boundaries |
| Editable shadcn/ui initially | Simplify delivery with future visual freedom | Maintain copied/customized components; replacement still requires work and regression checks |
| Supabase database/Auth/Storage | Keep the chosen backend integrated | Respect free quotas; auth email and storage capacity require proof |
| Cloudflare provisional | Candidate for zero-cost hosting | Must pass compatibility/runtime limits before functional implementation |
| Free provider addresses | Avoid domain expense | Branded domains deferred |
| Admin-managed inventory; inquiry-level seller assignment | Separate catalog control from commercial ownership | Owner/Admin control general inventory; sellers have only the later-approved, inquiry-linked reservation exception. All active sellers are eligible for every vehicle; no seller vehicle assignment or exclusion in MVP |
| Multi-vehicle interests per inquiry | Represent a customer considering several vehicles without duplicating conversations | An active inquiry has one responsible person and may record several available vehicles of interest; adding an interest does not create another inquiry or reservation. If another inquiry later reserves it, the interest remains but it cannot be reserved until available again. Count inquiries once for originating vehicle, not for every interest |
| Attribute multi-vehicle events without duplicating inquiry | Preserve meaningful vehicle reporting when a customer considers several units | Inquiry belongs to originating vehicle once; additional vehicles are interests. Visits, reservations and confirmed sales belong to the specific vehicle involved; formulas, period rules and reversals are still pending |
| Close multi-vehicle inquiry for the confirmed sale | Preserve one commercial outcome without treating every interested vehicle as sold | Upon Owner/Admin confirmation, inquiry remains Venta concretada for the specific Sold vehicle; other interests remain in history, no additional sales and no automatic closure of other inquiries |
| Allow reserving any Available interest from an inquiry | A customer can choose a vehicle different from the one that originated the conversation | Seller may reserve a listed Available interest from own active inquiry regardless of originating vehicle; reservation links that exact vehicle, inquiry and contact. One active reservation per vehicle and per linked inquiry remains enforced |
| Limit each inquiry to one active reservation | Avoid blocking several vehicles for the same customer's single inquiry | A second reservation for the same inquiry is rejected even if it targets a different Available vehicle; cancel the existing reservation first and retain its history. Enforce together with one active reservation per vehicle under concurrent requests |
| Bind each visit to one vehicle of interest | Preserve the vehicle being visited within a multi-vehicle conversation | Visit from existing active inquiry identifies one interest vehicle and reuses that inquiry without a new inquiry or automatic reservation; public vehicle-page visit still creates an inquiry through normal routing |
| Seller reservation from own inquiry (limited exception) | Give an assigned seller immediate, exclusive reservation without general inventory editing | Only from an active inquiry assigned to self for an Available vehicle; atomically link the reservation to inquiry/contact and mark vehicle Reserved, allowing at most one active reservation. Owner/Admin retain general inventory management and confirm Sold; this narrows the earlier no-inventory-writes rule |
| Seller cancellation of own active reservation | Let the seller who handles the linked inquiry release a fallen reservation without opening general inventory editing | Only if the active reservation links to an inquiry still assigned to that active seller; atomically end it, restore Available and retain history. Owner/Admin can cancel; seller deactivation does not automatically cancel |
| Block reassignment while inquiry holds an active reservation | Avoid transferring commercial responsibility while a vehicle remains reserved for that inquiry's contact | First cancel the reservation or resolve the sale through Owner/Admin; after cancellation apply normal active-inquiry eligibility or closed-inquiry reopening rules. Seller deactivation requires administrative resolution of the reservation |
| Preserve reservation when its seller is deactivated | Revoke unsafe access without promising the vehicle to another customer | Immediately deny inactive seller access and routing; keep vehicle Reserved and surface the reservation to Owner/Admin for explicit resolution before reassignment. Preserve history and reject cancellation from stale seller sessions |
| Conditional seller continuity | Preserve interlocutor when active and eligible for the originating vehicle | Most-recent eligible active inquiry has priority; all active sellers are eligible for every vehicle in MVP, while Owner/Admin require individual vehicle enablement; round robin remains fallback |
| Same-contact concurrent continuity | Prevent two simultaneous intentional submissions from bypassing the approved continuity rule | Order creation for the same normalized contact so the later inquiry considers the earlier committed active inquiry; keep distinct submissions distinct and retries idempotent. Locking and transaction implementation remain to be designed and tested |
| Retain submission ID with inquiry | Prevent late technical retries from creating duplicate inquiries without a separate cleanup mechanism | Client-generated random ID is unique and persists with the inquiry without its own expiry; same ID and changed data is rejected; repeated public response must be privacy-safe. Actual payload comparison and transactional enforcement remain to be designed and tested |
| Preserve an active Owner | Prevent administrative lockout | Backend rejects deactivation or role removal of the last active Owner, even under concurrent account changes. Exceptional recovery remains unresolved |
| Bootstrap the initial Owner with a manually run script | Make account setup controlled and reproducible without opening public registration | Run a purpose-built script from a trusted environment; keep privileged credentials out of browser/source/logs; reject routine reruns if an active Owner exists and design partial Auth/profile failure recovery. This does not authorize creating accounts or executing remotely |
| Recover partial initial Owner bootstrap without deletion | Avoid orphaning or accidentally deleting an Auth identity after profile creation fails | Controlled rerun verifies the intended identity and fills the missing Owner profile only if no active Owner exists; ambiguous/conflicting states require manual resolution, not automatic deletion |
| Optional administrative participation per vehicle | Let Owner/Admin handle commercial inquiries when enabled at vehicle creation | Select individual people with none preselected; active selected participants join the same round robin and continuity pool, not a backup route |
| Allow later removal of administrative commercial participation | Allow Owner/Admin to stop selecting an individual Owner/Administrator for one vehicle without changing their role | Removal blocks new assignments including continuity, but preserves existing inquiry responsibility/access until explicit reassignment |
| Allow later addition of administrative commercial participation | Permit Owner/Admin to opt an individual into commercial routing after vehicle creation | Addition affects future inquiries only, without transferring existing inquiries; administrative role and permissions remain unchanged |
| Allow explicit transfer of administratively handled inquiries | Let an Administrator change who handles a consultation already assigned to an Owner/Administrator | Reassignment changes commercial responsibility and preserves history, not the previous handler's global administrative access; this is distinct from removing future routing eligibility |
| Enforce current eligibility on manual reassignment | Keep active-user access and individual administrative participation meaningful for every new assignment | Reject transfer to an inactive seller or inactive/non-enabled Owner/Admin for the originating vehicle in the backend. Existing inquiry ownership is not revoked solely by eligibility changes; multi-vehicle interest edge cases remain to be defined |
| Reopen before transferring closed inquiries | Avoid rewriting responsibility for a completed commercial outcome without reopening work | Direct reassignment of either closed status is rejected; an authorized user first reopens it to En seguimiento, then Owner/Admin can reassign to an eligible person while preserving history and inventory availability |
| Create an administrative review task after seller sale | Give Owner/Admin an actionable handoff without granting inventory writes to sellers | Seller marking Venta concretada reports a sale and creates a pending Owner/Admin task, not a confirmed sale. For an active reservation, Owner/Admin ends it on explicit Sold confirmation or cancels it before correcting that inquiry to Cerrada sin venta with history; other inquiries remain unchanged. Sales count only on confirmed vehicle Sold transitions, without counting one unit twice; reporting attribution/reversals remain pending |
| Identify reported sale vehicle without mandatory reservation | A customer may purchase an interested vehicle directly without first reserving it | Seller reports Venta concretada for an explicit interest vehicle: reserved vehicle of that inquiry if active reservation exists, otherwise an Available interest. Reject a vehicle reserved by another inquiry or already Sold; administrative review task identifies the vehicle and confirmation rechecks its state |
| Honor competing reservation before confirming an unreserved sale | Avoid selling a vehicle promised to another customer after an unreserved sale report | If another inquiry reserves the reported vehicle before Owner/Admin confirms Sold, reject confirmation for the reporting inquiry until the reservation is explicitly resolved; do not auto-cancel or displace it, and leave sale review pending. Enforce under concurrent requests |
| Protect reserved inquiry from closure without sale | Keep vehicle availability and the linked inquiry consistent | Permit reporting Venta concretada while reserved, but reject Cerrada sin venta until the reservation is cancelled. An administrative rejection of a reported sale cancels the reservation and corrects the inquiry coherently |
| Own limited pageview measurement | Report vehicle performance directly in the panel | Define counting, abuse controls and temporal calculations; no unique-visitor claims |
| Soft delete only | Retain commercial references initially | Storage continues accumulating; later hard delete must preserve agreed statistics |
| Browser image compression initially | Reduce upload friction without a compression service | Device compatibility and output quality need tests; server validation remains mandatory |
| Provider-independent commercial rules | Keep the pilot infrastructure replaceable without changing commercial behavior | Define business behavior and acceptance tests independently of Supabase/Next.js; enforce authorization and atomic assignment in the backend. Replacing provider-specific policies, transactions or integrations still requires migration work; no speculative generic repository layer |

## Foundation work still pending

Local-first implementation begins with separate loopback-only public and backoffice application shells. This does not approve deployment or mark the foundation complete: authentication, backend authorization and real data flows still require implementation and verification. Advanced reporting definitions can wait until the reporting flow, without weakening the integrity requirements of earlier flows.

pnpm is the approved package manager for the local workspace; use its pinned version and `pnpm-lock.yaml` rather than npm's lockfile. This changes dependency management only, not hosting, backend security or product scope.

| Item | Status / required resolution |
|---|---|
| Local documentation baseline | Prepared; seven nonempty UTF-8 files checked, local links resolve, no conflict markers |
| Git repository | Initialized locally on branch `main`; no commits or remote configured as of 2026-11-02 |
| Application manifests and dependencies | Two Next.js workspace shells and local dependency lockfile created; no business-flow implementation |
| Screen map and SQL schema | Versioned schema started: `profiles` (roles, owner guard, RLS) and `vehicles` (publication, availability, soft delete, RLS), both covered by pgTAP suites. Screen map, inquiries, visits, reservations, sales and reporting still missing |
| Local Supabase stack | Started and verified with the pinned CLI: REST `200`, Auth health `200`, signup rejected `422`, real anon-key enforcement observed. Ports moved out of the Windows reserved range; new tables require explicit grants |
| Auth email and initial Owner | Provider delivery/quota not verified; bootstrap script and controlled partial-failure recovery approved but not implemented or executed |
| Cloudflare proof | Not executed; deployment adapter and free runtime envelope unresolved |
| Storage/transfer budget | Not measured; maximum planned photos can exceed quota |
| Analytics definitions | View counting, 24h dedup window, known-bot filter, temporal/person attribution, conversion denominators and visibility approved 2026-11-04; retention policy and visit results/cancellations still unresolved |
| Contact updates | Retain existing fields, store discrepant public name/email on inquiry for review; reject phone-change collisions without data changes; shared-phone identities and merging excluded from MVP |
| CI and local checks | Local typecheck/build and loopback HTTP smoke checks verified for shells; CI and real backend tests not configured |
| Recovery | Backup/export/image recovery process and free-tier feasibility not validated |

## Later stages, not current implementation

Approved T5 boundaries (2026-11-03): confirmed-sale reversal is excluded. Reopening resumes follow-up without changing Sold inventory or the confirmed-sale history. An inquiry with a pending sale review cannot reopen until Owner/Admin explicitly confirms or rejects that review. These decisions do not define statistical reversal formulas or authorize sales implementation beyond the approved baseline.

Approved sale entry (2026-11-03): every sale, including a manually registered in-person sale, requires an inquiry and explicit Owner/Admin confirmation. Direct inventory creation or updates must not introduce Sold vehicles without that confirmation. This narrows the previously approved generic administrative availability editing; existing confirmed-sale history remains immutable. User confirmation: "Si, hagamoslo así."

Approved blocked-sale eligibility (2026-11-03): internal blocking rejects both reporting and confirming a sale until Owner/Admin explicitly unblocks the vehicle. Recheck current eligibility during confirmation, even if it was enabled when reported. User confirmation: "Si, debe impedir hasta que se desbloquee."

T5b implementation (functional/independent verification complete; native review approved and acknowledged): confirmed sales use a private, one-record-per-vehicle ledger and explicit `resolve_sale_review(uuid,boolean)`. Successful reservations end as `completed`, with a confirming actor distinct from cancellation attribution; the enum extension is a separate migration before its first use. Rejection reuses `cancel_reservation` to preserve existing availability and historical behavior. Generic application-role Sold entry is rejected; database-owner maintenance/fixtures remain privileged SQL outside the API, not a new customer-facing import mechanism. No statistical formulas or reversal workflow are introduced.

T5c implementation (functional/independent verification complete; native review approved and acknowledged): `reopen_inquiry(uuid)` uses the existing actor-profile → inquiry lock-order suffix and performs no inventory access or mutation. Seller reopening is limited to their own closed-without-sale inquiry; Owner/Admin may also reopen a resolved sale. Every successful reopening appends history and returns to follow-up, preserving the confirmed-sale ledger and Sold availability. Pending review must resolve first. No reassignment API or reversal operation is introduced.

Approved reassignment clarification (2026-11-02): previous sellers lose inquiry-detail access after reassignment, but retain historical activity attribution in authorized statistics without a detail-access bypass. Administrative global access is unchanged.

Approved CRM clarification (2026-11-02): sellers may reopen their own inquiries closed without sale; completed-sale inquiry reopening is Owner/Administrator-only. Every reopening returns to En seguimiento, preserves history and never changes vehicle availability as a side effect.

- Manual inquiry entry and origin attribution moved into the approved MVP on 2026-11-03; T4 creation/reservations/blocking and T5 sales are verified in the database layer. Public integration, visits and reporting remain pending.
- Hard delete with preserved statistics; detailed retention/aggregation policy.
- Multiagency operation and reconsideration of exclusive customer ownership.
- Deeper UI customization and reconsideration of browser compression.

Subscriptions, invoicing, payments, WhatsApp conversation integration and a visual site editor remain excluded. Future-work listing is not approval to implement those features.

## Approved statistics definitions (2026-11-04)

Implementation boundary approved during T6 continuation: user selected "Base de datos primero". T6a first implements server-only database ingestion and rolling deduplication. Successful public-detail loading and known-bot filtering remain integration-pending; neither an anonymous role nor a supplied page/UA claim proves provenance. See [database contract](vehicle-views.md). This delivery does not complete S21 or expand into the public site.

T6 reporting definitions were resolved before any implementation, with no formulas invented:

- View event: successful load of the public vehicle-detail page, never catalog appearance; only the public site emits views, the private panel never.
- Deduplication: one count per vehicle per opaque random browser token (no personal data) in a rolling 24-hour window; no visitor identity verification of any kind.
- Automated traffic: server-side filter for known bot User-Agents, accepted as an imperfect MVP-scoped filter without forensic precision.
- Temporal attribution: fixed timezone `America/Argentina/Buenos_Aires`; cuts at local midnight for month/quarter/semester/year; custom ranges inclusive by days in the same zone.
- Person attribution: activities stay with whoever performed them and never move on reassignment; the inquiry outcome (confirmed sale or closed without sale) is attributed to the responsible person at the moment the outcome is recorded.
- Conversion relations: same period on both sides; per-vehicle relation = originating web inquiries / deduplicated views of that vehicle; global relation = web inquiries / total views; labeled as relation, never causality. Manual, in-person and phone inquiries are shown as separate counts and never enter the numerator. Reservations, visits and confirmed sales are shown as absolute counts.
- Visit metrics: visit requests count as their own event attributed to the concrete visit vehicle. User selected "Diferir al flujo de visitas (Recomendado)": implementation of this metric is deferred from T6 to the visit-flow feature because no visit source exists yet. The counting definition remains approved; results and cancellations stay pending until the visit flow is designed.
- Visibility: sellers see only their own figures and never dealership totals, other sellers' figures, comparisons or per-vehicle views; reassigned inquiries keep historical attribution in figures but never detail access. Owner/Admin see global, per-vehicle (views included), per-seller and comparisons.
- Reversals: a sale counts once at Owner/Admin confirmation; the MVP has no sale reversal, and any future reversal requires a prior definition.

User confirmations (verbatim): "Si, cuando la ficha pública se carga correctamente."; "Si, estoy de acuerdo con la venta de 24hs móviles."; "El panel privado no requiere generación de métricas por vistas, eso es solo para el sitio público."; "No quiero verificiar identidad de visitantes"; "Está perfecta"; "Si, está bien". Full Spanish definitions: `docs/product-plan.md` section 7.

## Approved correction: inventory versus inquiry ownership (2026-11-02)

The user explicitly replaced seller vehicle assignments and direct inventory management: sellers receive and handle assigned inquiries only; Owner/Administrator control inventory creation, publication, prices, sale availability and archival. A later limited exception allows sellers to reserve from their own active inquiries and cancel their own active reservations. All active sellers are eligible for every vehicle in the MVP; the previously approved seller exclusion mechanism is now superseded. Several inquiries for a vehicle may have different assignees; this is not a requirement to force a different seller on each submission. Existing active-contact continuity remains applicable using the new eligibility definition.

The earlier broad seller permissions to reserve, mark sold and archive were superseded. A later narrow exception allows sellers to reserve only from an active inquiry assigned to them and cancel their own linked reservation, without general vehicle-edit permissions. No runtime policies have been implemented. Sellers may read all vehicles and internal prices independently of public visibility or inquiry ownership; coworkers' inquiries remain private and Owner/Administrator control all other inventory writes.

## Superseded clarification: prospective routing exclusions (2026-11-02)

Excluding a seller means no new inquiries for that vehicle, including continuity-based assignments. Existing inquiries retain their assignee and authorized access until Owner/Administrator explicitly reassigns them. This avoids interrupting ongoing customer conversations. Use clear UI copy such as “No recibir nuevas consultas de este vehículo”. Exclusion does not revoke historical access; user deactivation remains a separate workflow that removes operational access and leaves open inquiries pending reassignment.

This historical rule is superseded for the MVP: no per-vehicle seller exclusion is implemented. All active sellers are eligible for every vehicle; optional Owner/Administrator participation remains individually configured by vehicle.

## Approved inquiry phone input (2026-11-02)

Require international phone input with a country selector defaulting to Argentina, and store the normalized number. Do not infer ambiguous prefixes. This number is a routing aid, not proof of identity or authorization.

User confirmation: "Si, usemos ese criterio".

## Approved inquiry rotation scope (2026-11-02)

Use round robin per originating vehicle among its currently eligible participants. Assignments resolved through contact continuity do not advance that vehicle's rotation cursor.

User confirmation: "Usemos esa regla".

## Approved continuity timestamp tie-break (2026-11-02)

When eligible active inquiries have identical creation timestamps, use their sequential creation order: the last created inquiry wins. Do not use random UUID ordering to resolve continuity.

User confirmation: "lo aplicamos".

## Inquiry delivery boundaries (2026-11-02)

The user chose: "Prefiero que se unan primero en feat/inquiries". Keep dependent deliveries together on `feat/inquiries` before integrating into `develop`; each delivery includes its own tests and documentation. No remote publication or integration is authorized by this choice.

Implement creation as a service-only database operation first. Anonymous and authenticated clients receive no direct mutation access. A future public endpoint must validate real phone numbers, apply abuse protection and return only approved commercial contact details; those boundaries are not proved by a successful internal database call.

## Approved shared-contact conflict protection (2026-11-03)

User confirmation: "Si, usemos esa protección contra sobreescrituras." Contact details and authorized phone corrections require the revision read by the caller. A stale edit is rejected atomically with a reload instruction; it never silently overwrites the winning edit. Every successful contact update increments the revision, including trusted direct updates. Existing role restrictions, submitted snapshots and phone-collision rejection remain unchanged. UI conflict handling and real phone parsing are separate pending work.

## Approved unified CRM and reservation scope (2026-11-03)

- A commercial inquiry is a shared follow-up entry with web, in-person or telephone origin. This supersedes the earlier exclusion of external inquiries.
- Seller, Owner and Admin may create manual inquiries. The registering active staff member is the initial assignee; manual creation does not invoke or advance web rotation. User confirmation: "Si, quien la registra".
- Manual entry requires name and phone, with optional email. User confirmation: "Me parece bien." The public web form keeps its existing required email. Reuse a matching contact without silently overwriting it; otherwise create the contact. Phone matching is not authorization to inspect unrelated history.
- Every commercial reservation requires a linked inquiry and contact, including administrative manual entry. This supersedes the earlier optional inquiry link. Existing customers need not already have a contact record.
- Internal vehicle blocking is separate from reservation and restricted to Owner/Admin. Reject blocking while an active reservation exists; resolve the reservation explicitly first. User confirmation: "Si, bloquiemos eso." Blocked inventory must not appear on the public site, while retaining private information and history. User confirmation: "Correcto, no debe mostrarse en el sitio."
- Vehicle availability stays an independent administrative field (Available, Reserved, Sold). No rule requires Reserved to originate from a reservation: the approved baseline permits Owner/Admin inventory editing and never defines availability transitions, so that guard was deliberately not added. Reservation and blocking integrity is enforced in the other direction: reserving requires Available and sale-enabled inventory, and leaving Reserved, selling, soft-deleting or blocking a reserved vehicle is rejected until the reservation is resolved.
- Existing T3 web behavior remains covered by regression checks. T4a manual inquiry creation, T4b reservations, T4c internal blocking and T5 sales are implemented and verified in the database layer; public UI, visits and reporting remain pending. Product approval alone is not implementation evidence; observed proof is recorded in docs/testing.md.

## Branching and integration workflow (2026-11-02)

| Decision | Reason | Consequence |
|---|---|---|
| `develop` is the integration branch; `main` receives only integrated, verified work | Keep an always-releasable line separate from in-progress integration | Peer branches start from `develop`, never from `main`. Feature work reaches `main` only through `develop` |
| Every feature gets its own short-lived branch off `develop` | Isolate a reviewable unit of behavior and keep integration history legible | A feature branch is merged back into `develop` and then deleted. Long-lived feature branches are not kept |
| Commit messages follow Conventional Commits, without AI attribution | Keep the history machine-readable and attribution honest | Each work unit lands as a reviewable slice with its tests and docs |
| Every published branch carries a written summary of what was added, changed and removed | A reviewer (or the future you) must understand the change without reconstructing it from the diff | The pull request description states the change explicitly, with the verification actually run and any known limitation. A vague or empty summary blocks review |

Every branch that reaches `origin` with a pull request carries that summary, not only a title. At minimum it states what was added, what was changed, and what was removed or deliberately left out — plus the verification that was really executed and any open limitation. The summary describes the change; it never claims proof that was not observed, and it never hides a failed, skipped or pending check.

The model was reviewed and confirmed by the user (2026-11-02), with explicit reasons: `main` is the production line and must never receive half-tested work, continuous integration will be added on top of `develop`, and local experimentation stays away from production code.

Reviewed tradeoff: with a single developer, `develop` adds one integration hop that `main` alone would not need, and it only returns its full value once automated checks and a deployment from `main` exist. The rule that keeps it safe in the meantime is that feature branches stay short and always return to `develop`; a branch that never comes back is dead work.
