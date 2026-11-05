# S21a visits
Objective: implement the approved backend incrementally; branch `feat/visits`, baseline `1bbefb353290df583e19938317b9c49c258c8497`.
Delivery: ask-on-risk / feature-branch-chain, approved 2026-11-05; dependent slices integrate in `feat/visits` before `develop`, with no remote publication authorized. Runner: pgTAP (`pnpm db:test`), targeted SQL suites, isolated concurrency/HTTP probes where applicable.

## Specs

- S1 — User authorization: "Si, comencemos la implementación." In context, begin the first proposed block: "horarios, estructura de visitas, historial y permisos". Approved product requirements are in `docs/product-plan.md` sections 6–7 and `docs/decisions.md` S21a tables. Public form and internal agenda are deferred; no deployment or remote work.
- S2 — Approved configuration: "Dueño/Admin configura días e intervalos de atención, sin duración fija ni cupos." Only active Owner/Admin may change opening hours; staff may read them. Validate weekday and ordered, nonempty same-day intervals. No invented default business hours. Changes preserve existing visits.
- S3 — Approved cardinality: "En principio dejemos una, y la posibilidad de crear nuevas." At most one Requested/Confirmed visit per inquiry, not per vehicle. Each visit references a concrete interest vehicle. Keep completed visits and allow later visits; optional free-text purpose. Foundation introduces the private storage and constraints, not creation or lifecycle RPCs.
- S4 — Approved permissions: current responsible seller sees their inquiry visits and history; active Owner/Admin sees all. Former assignees, inactive users, anonymous callers and unrelated sellers must not gain detail access. Mutations go through controlled operations, not direct application-role table writes. Keep attribution distinct from recording actors, including first-result unassigned versus never recorded.
- S5 — Approved history: "Si se cargó un resultado erroneo, el vendedor también puede cambiarla. Es decir, puede editar el estaod." Preserve old/new state, actor, timestamp and correction reason. Later lifecycle work supplies operations enforcing the approved transition/correction rules; no lifecycle completeness claim for the foundation.

## Tasks

- T1 | S1–S5 | inline (one coherent foundation; no writer trigger) | checks complete; native review pending | commit pending; RED missing tables, GREEN 52/52; suite 1400/1400 | Risk: items 2 (private RLS and administrative configuration) and 4 (serialized interval replacement).
- T2 | later planning only | atomic creation and existing-inquiry requests | not started; implementation authorization limited to T1.
- T3 | later planning only | lifecycle/corrections | not started.
- T4 | later planning only | cross-flow cancellation | not started.
- T5 | later planning only | reporting | not started.

## Log

- L1 — Original request: "Si, comencemos la implementación."
- L2 — 2026-11-05: Read approved product decisions, current inquiry RLS and pgTAP fixture patterns. Local Supabase running; existing baseline documented at 1348 assertions / 27 SQL suites. No reset authorized or needed. Existing documentation changes are approved S21a definition, retained without overwriting.
- L3 — Plan: T1 adds versioned migration, focused regression tests and backend contract documentation. Observe missing-schema/function RED first, apply only new migration, then focused GREEN and full suite. Independent verifier required for item 2 after own checks. Native review mode/assessment determines candidate review. No existing API changes intended in T1.
- L4 — Implemented foundation migration and contract `docs/visits.md`. RED observed missing tables, then 47/47 and full 1395/1395. Independent verifier found no reproduced blocker on isolated baseline/candidate/suite databases: role boundaries, all-public-data rejection hashes, actual advisory-lock wait, last-complete-schedule result and existing RPC/function-definition parity. Not real JWT transport; inactive administrative actor and actor-deactivation race not independently exercised.
- L5 — Retained missing-field, malformed-time and missing-profile regressions plus `scripts/test-visit-hours-concurrency.py`; parent observed its real waits and final exact schedule, then focused 52/52 and full 1400/1400. No existing helper or RPC implementation changed, so no shared-command new-input differential applies. Typecheck/build not applicable to SQL/Python/docs change. Three owned verifier databases and external scratch removed, confirmed. Native mode on; assessment requires explicit untracked inventory and did not assess candidate yet. Final candidate review pending after delivery-strategy decision/commit. No approval claimed.
- L6 — Forecast now exceeds 400 authored lines including tests/docs; ask-on-risk requires the user's chain strategy before the next commit. No source work outside T1 authorized; no commit or publication performed.
- L7 — User strategy confirmation: "Si, hagamoslo así". Use feature-branch-chain into `feat/visits`, then `develop`; no push, PR or merge authorized. Local slices: approved passive definition/task specification, then T1 foundation with its tests and contract (about 386 authored lines); later blocks remain unimplemented.
