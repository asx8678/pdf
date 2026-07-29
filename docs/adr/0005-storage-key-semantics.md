# ADR 0005 — Storage key semantics: UUID-keyed, not content-addressed

- **Status:** accepted
- **Date:** 2026-07-29
- **Tasks:** pdf-52u (decision). T-172 (prune) carries matching preconditions.
- **Spec:** plan3.md §7.1, §5.2

## Context

§7.1 describes the Storage adapter's key in two contradictory ways.
[Line 1218][l1218] says the filesystem backend uses "a content-addressed
relative path under the data root", while [line 1234][l1234] says keys are
`<first2>/<next2>/<uuid>` two-level fan-out — a UUID key, not a content
hash. [Line 850][l850] describes `document_revisions` as
"append-only, content-addressed", but the actual `storage_ref` column stores
an opaque `Storage.Ref` whose Web-adapter key is UUID-based (see
`Quire.Storage.Web.Filesystem.generate_key/0`).

If the key were truly content-addressed (e.g. `<first2>/<next2>/<sha256>`),
two document revisions holding identical bytes would share one blob.
T-172's retention/prune job could then delete those bytes while a *different*
revision of the same document still references them — silent data loss —
because nowhere in the plan (nor in T-172's one-line spec at line 2891) is
refcounting specified.

If the key is UUID-based, the blob is uniquely owned by its revision row.
T-172 deletes a row's storage blob only when no `document_revisions` row
references that `storage_ref`. Integrity is provided by the separate `sha256`
column (§5.2 line 853), which also enables optional deduplication reporting
without risking data loss.

Both schemes were in the air in the original draft; this ADR resolves the
ambiguity.

## Decision

**Storage keys are UUID v7 identifiers, not content-addressed hashes.**

- `Quire.Storage.Web.Filesystem.generate_key/0` produces a UUID v7 key with
  `<first2>/<next2>/<uuid>` two-level fan-out. This is already the
  implementation — this ADR confirms it as deliberate.
- `Ref.key` remains opaque to callers (§7.1). Its structure is an
  **adapter-internal concern**.
- The `sha256` column on `document_revisions` is retained for **integrity
  verification and optional dedup reporting only**. It is never part of the
  storage path.

## Consequences

### Positive

1. **Safe deletes with no refcounting.** T-172 can determine whether a blob
   is live by checking `document_revisions.storage_ref` — a SQL query, not a
   reference-count field that could drift. Content-addressing would require
   refcounting (or a "delete only when zero refs remain" subquery), which
   neither the plan nor T-172 specifies.

2. **Already implemented.** `Quire.Storage.Web.Filesystem.generate_key/0`,
   `put/2`, `get/2`, and `delete/1` all assume UUID keys. The code needs no
   change.

3. **UUID v7 index locality preserved.** Time-ordered UUIDs keep B-tree
   inserts on the right-hand edge, matching the rationale in §3.7 that
   matters most for `document_revisions` and `edit_operations`.

4. **Simple migration path.** The two contradicting phrases in plan3.md can
   be corrected independently of code.

### Negative

1. **No storage-level deduplication.** Identical content stored under two
   revision IDs occupies physical storage twice. Mitigation:
   - The `sha256` column enables a background dedup reporting query.
   - A future pass could add a hash-index table with refcounting once the
     prune contract is settled and tested.

2. **Slightly larger keys.** `uuid` is 36 chars vs 64 for `sha256`, but the
   difference is negligible at the filesystem and database level.

### Actions required

- plan3.md line 850: strike "content-addressed" — `document_revisions` is
  append-only; the hash is an integrity column, not a storage key.
- plan3.md line 1218: change "content-addressed relative path" to
  "relative path" — the path structure is `<first2>/<next2>/<uuid>`.
- `StorageCase` should assert that Web-adapter keys match the UUID fan-out
  pattern and that Local-adapter keys are absolute paths.
- T-172's precondition: "delete a storage blob only when no
  `document_revisions.storage_ref` references it."

[l850]: https://github.com/asx8678/pdf/blob/main/plan3.md#L850
[l1218]: https://github.com/asx8678/pdf/blob/main/plan3.md#L1218
[l1234]: https://github.com/asx8678/pdf/blob/main/plan3.md#L1234
