# Feature: Initial database schema and security policies

Objective: build the local PostgreSQL schema with versioned migrations and row-level security, verifying every authorization rule with pgTAP instead of trusting configuration.
Branch: `feat/inquiries` from `develop` at `3ad0a5d`. Delivery strategy: `auto-chain`, feature-branch-chain into `feat/inquiries`, then `develop`; publication requires authorization.
Test runner: `pnpm db:test` (`supabase test db`, pgTAP).

## Specs

- S1 Roles are exactly `owner`, `admin`, `seller`; no other staff role exists in the MVP.
- S2 Every staff account has exactly one profile row, keyed by its `auth.users` id, with a display name and an active flag.
- S3 Authorization is enforced by the database: a seller can only read its own profile, while Owner/Admin can read every profile.
- S4 A seller cannot create, update or delete profiles through the API; only Owner/Admin may mutate staff profiles.
- S5 The last active Owner can never be demoted or deactivated, including concurrent attempts.
- S6 No public registration path exists: `anon` and `authenticated` have no insert policy on staff profiles.
- S7 The customer-facing schema never exposes internal prices or draft vehicles to anonymous callers (applies to the inventory slice).
- S8 An inquiry keeps one responsible person and can record several vehicle interests without creating extra inquiries or reservations (inquiry slice).
- S9 A vehicle can hold at most one active reservation and an inquiry can hold at most one active reservation (reservation slice).
- S10 Only an explicit Owner/Admin confirmation marks a vehicle Sold and counts a sale (sale slice).
- S11 Approved phone criterion: "Si, usemos ese criterio" — international phone input with a country selector defaulting to Argentina; persist normalized numbers without guessing ambiguous prefixes. Phone matching is not authentication.
- S12 Approved rotation criterion: "Usemos esa regla" — round robin per originating vehicle among currently eligible participants; continuity does not advance rotation.
- S13 Approved timestamp tie-break: "lo aplicamos" — equal creation timestamps are resolved by sequential creation order, latest first.
- S14 Delivery: "Prefiero que se unan primero en feat/inquiries" — accumulate reviewable deliveries on `feat/inquiries` before integration into `develop`.

## Tasks

| ID | Specs | Route | Status | Evidence |
|---|---|---|---|---|
| T1 | S1-S6 | inline | done | `20261102120000_identity_and_roles.sql`; `0001_identity_test.sql` 21/21 passing; commit `4ea16a3` |
| T2 | S7 | inline | done | `20261102130000_vehicles.sql`; `0002_vehicles_test.sql` 15/15 passing; commit `2ffef59` |
| T3 | S8 | inline | pending | inquiries, interests and rotation |
| T3a | S8, S11, S13 | inline; dependent units cannot run in parallel | done | commit `0a11d78`; RED missing contacts; focused 33/33; suite 71/71; independent privacy probes pass; native review granted, no findings, acknowledged; Risk: item 2 (customer privacy) |
| T3b | S8, S11-S13 | inline; depends on T3a | checking | focused 27/27 plus 20/20 independent regressions; full suite 118/118; four overlapping races pass; native review pending; Risk: items 2 and 4 |
| T3c | S8 | inline; depends on T3b | pending | authorized interest additions and supported contact operations; no generic status/reassignment grants |
| T4 | S9 | inline | pending | reservations with unique constraints |
| T5 | S10 | inline | pending | sale review and confirmation |
| T6 | reporting | inline | pending | deferred metrics definitions |

## Log

- L1 (user, verbatim): "Si, arrancá por ahí."
- L2: Earlier approved direction: everything starts local, as a safe testing environment; Docker-backed Supabase is now running.
- L3: Slice T1 chosen first because every later policy depends on a trustworthy identity and role source.
- L4: RED observed before each migration: identity suite failed with `relation "public.profiles" does not exist`; both suites now pass after `db:reset`. Real API checked with the anon key: `/rest/v1/vehicles` returns `200 []`, `/rest/v1/profiles` returns `401`.
- L5: Pricing, currency conversion and image columns are deliberately absent. Their rules (conversion, rate history, limits) are still unresolved, so adding columns now would invent business rules.
- L6: `vehicles` keeps sold rows readable by anonymous callers because the approved plan keeps a sold vehicle's informational page; catalog filtering is a query concern, not a row-level one. Seller mutations will go through transactional functions when reservations arrive, not through broad update grants.
- L7 (user): "Arranca". Resume T3 on `feat/inquiries` from `develop`. Prior mirror was an architecture summary, not a full task document; current local document is authoritative after reconciliation. T1/T2 committed; T3-T6 remain unfinished.
- L8 (user): "Si, usemos ese criterio"; "Usemos esa regla"; "lo aplicamos". Decisions are recorded as S11-S13 and in `docs/decisions.md`.
- L9 (user): "Prefiero que se unan primero en feat/inquiries". Forecast for T3: 900–1400 authored changed lines, split by coherent behavior with tests/docs together; child deliveries accumulate in the feature before develop. No push, PR, or merge authorized here.
- L10: T3a intentionally exposes private read models only; no inquiry creation endpoint, direct writes, reservation, sale or contact-edit API. Reuse existing active-staff predicates and timestamp trigger. Focused proof: `pnpm exec supabase test db supabase/tests/0003_inquiries_test.sql`; suite: `pnpm db:test`; isolated independent security verification after own checks. Baseline: `3ad0a5d`.
- L11: Observed RED: `public.contacts` missing, exit 1. Applied only pending local migration with `pnpm exec supabase migration up`, exit 0; no reset. Focused 33/33, suite 69/69, then 71/71 after retaining independent probes as pgTAP. Independent verifier found no reproduced T3a privacy blocker: seven identities and 63 denied writes with unchanged hashes. Scratch pnpm runner failed (incomplete dependencies); SQL suites/probes passed via local `psql`; no baseline-only database or concurrency proof claimed. Typecheck/build not rerun for SQL-only change. Native assessment requires an explicit untracked inventory or tracked candidate; stage the authored files before final assessment. No source-mutating normalizer applies to SQL here; `git diff --check` passes. Rollback boundary: new inquiry migration and its two test files only; do not remove existing identity/inventory migrations. Full task mirror must be refreshed after this evidence update.
- L12: T3a commit `0a11d78`, 325 authored changed lines; native risk high (item 2), consent granted, three lenses without findings; `gentle-ai.review-acknowledged/v1` confirms authority burned for target `sha256:6e9098d39d76a6fe754348088f867bc8b7b3e2bb472a0140d62ba95c87d995d3`. Reviewed boundary advances to `0a11d78`. Independent scratch deleted. T3b remains local and service-only: no public RPC grants, no invented WhatsApp configuration or abuse policy. Rotation uses stable participant UUID order as an implementation detail, not as the continuity tie-break. Canonical phone parsing and public endpoint stay pending.
- L13: T3b RED observed: missing `submit_inquiry`, exit 1. Applied local pending migration; initial function failed because service role lacked vehicle row-lock privileges. Changed only this controlled function to SECURITY DEFINER with empty search path, executable only by service role; corresponding local ALTER applied. Focused suite now 27/27; full suite 98/98. Independent isolated fresh database applied actual migration files and passed four genuinely overlapping races (observed advisory/transaction lock waits). Denied anon/auth calls and draft/deleted/Sold rejections preserve row hashes. Verification returned partial: independent admin removal/inactive continuity/Owner-Admin parity/no-eligible/timestamp tie-break/Reserved acceptance and complete concurrent changed-payload rejection snapshot not all executed. No reproduced code blocker. No more verification or source implementation before the missing-proof decision. No T3b commit, review or integration yet. Retained uncommitted source and regression tests; independent probe scripts/database retained for the decision, not committed or claimed as ready-to-run regression tests. Parent must clean those temporary resources after extracting needed artifacts. Typecheck/build skipped (SQL-only). No push, PR or merge.
- L14 (user, verbatim): "Completemos con las comprobaciones pendientes". Authorized only the seven missing checks, not another full independent sweep. All seven passed with 20 pgTAP assertions in the isolated database; parent retained them as `0006_inquiry_submission_regression_test.sql`, observed 20/20 focused and 118/118 full suite. Independent checks now cover removed Admin/inactive continuity, Owner/Admin parity, no eligible pending/history/cursor, opposite-UUID timestamp tie-break, unchanged Reserved vehicle and full seven-table hash after changed-payload rejection. Real phone parsing, public abuse/contact delivery, T3c and later slices stay pending. Rollback boundary for this unit: `20261102150000_inquiry_submission.sql` plus tests `0005` and `0006`, preserving accepted T3a. Source normalization: no SQL formatter configured; `git diff --check` passes. Native review remains pending; no push/PR/merge.
