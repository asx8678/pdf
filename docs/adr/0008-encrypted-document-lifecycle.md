# ADR 0008 — Encrypted-document lifecycle

- **Status:** accepted
- **Date:** 2026-07-29
- **Spec:** plan3.md §4.1, §5.2, §10.3

## Context

plan3.md §10.3 step 2 prompts for the open password of an encrypted PDF but
never says where the password lives after that. Steps 3, 5, 7 all touch
still-encrypted bytes. §4.1 forbids exposing passwords to client JS. §5.2
stores only `encrypted boolean` and `security_policies` — no key storage.

The workers that need document bytes — render (thumbnails, page previews),
OCR, text extraction — receive `Storage.Ref` values, not session state.
Storing ciphertext and requiring every job to carry a session identifier and
fetch the key from a GenServer would make those workers stateful, adding
complexity and a new coordination point.

## Decision

Decrypt at ingest, store plaintext bytes, re-encrypt on every export/save.

### Option (a): Decrypt at ingest, store plaintext — selected

1. On open, the user provides the password → PDFium decrypts the document
   → the plaintext bytes are stored via `Storage.put` → the password is
   **discarded from the process state** after the session stores it.
2. The `encrypted` boolean in the `documents` table remains `true` — it is a
   signal to the UI that the *original* was encrypted, not a statement about
   the stored bytes.
3. On export or save, the session-held password and the `security_policies`
   permission flags are used to re-encrypt the plaintext bytes before serving
   the ciphertext to the user.

### Why the alternatives were rejected

- **Store ciphertext + session key in a GenServer** — every worker would need
  the session identifier to fetch the key. Workers are stateless by design
  and receive only a `Storage.Ref`. This would require plumbing session
  context through every job or making workers stateful.
- **Store ciphertext + key in the revision row** — equivalent to storing
  plaintext in terms of confidentiality, but adds indirection and a
  key-management problem without benefit.
- **Re-encrypt on every read** — adds overhead to every range request from
  the viewer (step 7 in §10.3). The viewer fetches progressive chunks; a
  re-encrypt-on-read model would require decrypting and re-encrypting on
  every chunk or maintaining a streaming decrypt state.
- **Store the password in the DB** — violates §4.1's principle and creates
  a persisted credential that must be protected, without adding value over
  the session-only approach.

## Consequences

1. **Ingest flow:** user provides password → PDFium opens document → decrypt
   → store plaintext bytes via `Storage.put` → discard password (retain in
   session only).
2. **Export flow:** read plaintext bytes → PDFium open → apply
   `security_policies` → encrypt with saved policy flags → save ciphertext →
   serve to user.
3. The `encrypted` boolean in the document record is set to `true` when the
   original was encrypted; it stays `true` even though the stored bytes are
   plaintext — the UI uses it to show the padlock icon and to know that
   re-encryption is required on export.
4. Save must re-encrypt with the same permission flags from the document's
   `security_policies`.
5. Re-encrypting uses the same password that was provided at open — store it
   in the **session** (memory, not DB). The session is already scoped to the
   user and the LiveView lifecycle; when the document tab closes, the
   password is gone.
6. §4.1's "Never expose passwords to client JS" stands — the password never
   leaves the server.
7. The `security_policies` table (§5.4) stores permission flags and key
   length but **never the password itself** — the schema is unchanged.
