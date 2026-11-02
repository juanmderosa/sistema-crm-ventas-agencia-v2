# Dealership MVP

Planning baseline approved on 2026-11-02. Local-only application shells exist; business flows and backend security are not implemented.

## Read first

1. [Approved product plan](docs/product-plan.md): scope, business rules and delivery sequence (Spanish).
2. [Architecture](docs/architecture.md): application boundaries, data concepts and unresolved infrastructure checks.
3. [Permissions](docs/permissions.md): role matrix and enforcement requirements.
4. [Testing strategy](docs/testing.md): planned checks and acceptance scenarios.
5. [Decisions](docs/decisions.md): rationale, consequences and future work.
6. [Local development](docs/local-development.md): how to run and verify the two loopback-only application shells.

Project implementation rules are in [AGENTS.md](AGENTS.md).

## Current status

- Approved: product scope and technology choices.
- Prepared: documentation baseline, permission matrix, two local Next.js placeholder apps, a local Supabase stack and the first two schema migrations.
- Verified: pnpm installation, strict typechecks, builds, loopback HTTP responses, Supabase REST `200` and Auth health `200`, rejected public signup, 36 passing pgTAP database tests and real anon-key enforcement.
- Pending: inquiry, visit, reservation and sale schema with policies; Auth bootstrap for the first Owner; screen map; automated frontend tests and infrastructure validation.
- Not performed: account setup, real business-flow implementation or deployment.

The shell checks are `pnpm typecheck` and `pnpm build` (use `pnpm.cmd` if PowerShell blocks `.ps1` shims). pnpm 10.18.3 is the pinned package manager. No business-rule test runner or real backend checks exist yet.

## Next delivery

Enable a local Docker-compatible engine and set up local Supabase before building private or customer-data flows. Remote operations require explicit authorization for destination, operation and account/session. Free-tier suitability is not yet demonstrated.
