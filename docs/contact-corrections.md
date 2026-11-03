# Version-checked contact corrections

Contact edits require the revision read with the contact. Both RPCs return only
the new `bigint` revision. A stale form must reload before retrying; it must not
silently resubmit against the new revision.

## RPC contract

| Operation | Arguments | Authorized callers |
|---|---|---|
| `update_contact_details` | `p_contact_id uuid`, `p_expected_revision bigint`, `p_name text`, `p_email text` | Active Owner/Admin, or active seller with a currently assigned linked inquiry, including closed inquiries |
| `update_contact_phone` | `p_contact_id uuid`, `p_expected_revision bigint`, `p_phone text` | Active Owner/Admin only |

No revision argument has a default. Name/email must be nonblank. Phone must match
`^\+[1-9][0-9]{1,14}$`; this is canonical international **shape**, not real phone
parsing. Country selection and application-level parsing remain pending.
Identity comes solely from `auth.uid()` and the current active profile. No actor
parameter, generic table update grant, public operation, merge, status change or
reassignment is introduced. Shared contacts never grant access to coworkers'
inquiries. Submitted snapshots and assignment history are unchanged.

## Errors and atomicity

| SQLSTATE | Meaning |
|---|---|
| `42501` | Unauthorized caller/contact; absent and inaccessible contacts disclose no details |
| `22023` | Invalid input, including null/negative expected revision |
| `40001` | `contact changed; reload the contact and retry` |
| `23505` | `phone already belongs to another contact; no contacts were merged` |

Rejected operations persist no contact changes, including timestamps and revision.
Every successful contact UPDATE, even a no-op or trusted direct update, increments
revision exactly once. The existing `set_updated_at` trigger owns timestamps.
The version comparison is in the UPDATE predicate, not a blind write after a read.

Details corrections acquire the current `inquiry-contact:` advisory key before
actor/inquiry/contact row locks and revalidate the phone after waiting. This also
prevents the reproduced details-then-submission transaction from reversing the
phone-correction lock order.

Phone corrections lock both old/new `inquiry-contact:` advisory keys in numeric
order before locking the actor/contact. This coordinates with `submit_inquiry`;
its vehicle-then-profile lock ordering is unchanged. A phone changed while waiting
causes a stale rejection rather than acquiring a third key out of order. Actor
locks protect authorization against deactivation; seller details also lock the
qualifying inquiry against reassignment. Use READ COMMITTED transactions, as for
submission. Trusted maintenance that changes phones must respect the same phone
lock protocol; direct updates still invalidate all old edit revisions.

## Verification boundary

`supabase/tests/0008_contact_corrections_test.sql` covers RPC authorization,
optimistic conflicts, canonical shape, collisions, complete rejection-row hashes,
revision invalidation, snapshots and history. Disposable PostgreSQL scaffolding
with a minimal Auth stub is not real Supabase Auth integration. Parent integration
passed on the real local Supabase stack. Independent overlapping sessions verified
stale edits, phone collisions and submission coordination; a reproduced composed
transaction deadlock was corrected and passed its targeted independent recheck.

The reusable runner is `scripts/test-t3c-concurrency.ps1`. It creates a unique
disposable local database, applies the actual migrations and observes lock waits
before releasing the winning transaction. It never targets the application DB.
Run it with the host's approved PowerShell script policy; do not weaken policies
automatically. The user authorized a process-only exception for this verification.
`-CombinedOnly` runs just the corrected interlock regression; `-KeepDatabase`
retains generated resources for inspection and requires explicit cleanup.
