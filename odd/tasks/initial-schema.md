# Feature: Initial database schema and security policies

Objective: build the local PostgreSQL schema with versioned migrations and row-level security, verifying every authorization rule with pgTAP instead of trusting configuration.
Branch: `main` (repository has no commits yet). Delivery strategy: `ask-on-risk`.
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

## Tasks

| ID | Specs | Route | Status | Evidence |
|---|---|---|---|---|
| T1 | S1-S6 | inline | done | `20261102120000_identity_and_roles.sql`; `0001_identity_test.sql` 21/21 passing |
| T2 | S7 | inline | done | `20261102130000_vehicles.sql`; `0002_vehicles_test.sql` 15/15 passing |
| T3 | S8 | inline | pending | inquiries, interests and rotation |
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
