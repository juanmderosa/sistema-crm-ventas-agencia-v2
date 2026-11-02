# Project instructions

## Authority and scope

- Treat `docs/product-plan.md` as the approved product baseline. Do not silently expand scope.
- Documentation approval does not authorize deployment, account creation, purchases or remote execution.
- Preserve zero-cost MVP constraints. Report an infeasible requirement instead of silently switching to a paid plan.
- Keep approved decisions separate from proposals and unresolved validation gates.

## Language and structure

- Code, identifiers, comments and technical documentation: English. The approved Spanish product plan and Spanish user-facing copy are intentional exceptions.
- User interface: professional Spanish.
- Use strict TypeScript. Separate UI, data access and business rules by feature.
- Keep dealership configuration outside hardcoded application behavior. Do not implement a multi-tenant platform in the MVP.
- Use shadcn/ui as editable starting code, not as the owner of business logic. Add only needed components; avoid speculative abstraction layers.

## Security and integrity

- Enforce authorization in the backend, including database policies where applicable; frontend visibility is not a security boundary.
- Never expose privileged keys, internal prices, draft images or unauthorized customer history through public responses.
- Use versioned database migrations and database constraints for integrity.
- Inquiry creation, continuity selection, rotation and assignment must form a coherent transactional operation with idempotent submission handling.
- Treat normalized phone matching as a routing aid, not proof of identity or authorization.
- Preserve commercial history when reassigning or deactivating users and soft-deleting vehicles.
- Do not log personal data or secrets. Validate external input and return explicit, actionable errors.

## Verification and delivery

- Follow `docs/testing.md`; run applicable checks and report failed, skipped, pending and unavailable proof.
- Use test-first development when a deterministic behavior and runnable test exist. Do not fabricate RED/GREEN evidence.
- Do not suppress errors to make checks pass, change schemas without migrations or claim mocks prove real backend permissions.
- Record meaningful design decisions and their consequences in `docs/decisions.md`.
- Do not mark the foundation stage complete until its infrastructure and tooling gates are verified.
- Use Conventional Commit messages without AI attribution. Do not commit, publish or push without applicable authorization.
