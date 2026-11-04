# Closure responsibility snapshots

Each new closed-without-sale history event captures its responsible person in
the private `inquiry_closure_attribution` table. Reopening preserves earlier
events; a later closure adds another event without adding an inquiry.

## Historical interpretation

| State | Meaning |
| --- | --- |
| No snapshot row | Historical responsibility is unknown; never infer it from the current assignee or recording actor |
| Snapshot with NULL responsible | Known unassigned at recording time |
| Snapshot with a staff UUID | Responsible at recording time, even after reassignment or deactivation |

No historical backfill runs. An AFTER INSERT trigger captures new closure events
in the same transaction as resolution, including reservation cancellation. A
failed snapshot rolls back the operation. Resolution retries do not insert a new
history event, so do not create another snapshot. Other statuses are unaffected.

The trigger uses a SHARE lock on the inquiry; existing resolution already holds
its UPDATE lock. This serializes capture with reassignment without locking staff
rows. Snapshot data has RLS and no application-role grants, including service role.
Existing history shapes, actor fields and public RPC outputs are unchanged.

## Checks and limits

- `pnpm exec supabase test db supabase/tests/0023_closure_attribution_test.sql`
- `pnpm db:test`
- `python scripts/test-t6b1-independent.py t6bverify_<base> t6bverify_<candidate> <baseline-migrations-directory>`

The retained probe requires two new disposable database names. It uses a minimal
Auth scaffold, deterministic review UUID defaults in both scratch databases for
exact output comparison, and a temporary failure trigger for rollback proof.
It prints owned database and scratch names for caller cleanup and never reads
Git or deletes resources. Do not use existing databases.

This is the T6b attribution-source slice, not a reporting reader or UI. Periods,
aggregates and the unknown-responsibility display remain pending. Tests do not
prove Auth HTTP behavior or an exhaustive concurrent lock graph.
