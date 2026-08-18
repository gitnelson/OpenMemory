# OpenMemory Tech Debt Catalog

Items discovered during code reviews that fall outside the scope of active work. Each entry includes location, description, severity, and discovery context so a future session can pick it up without re-investigating.

Severity: **P0** (security/critical), **P1** (should fix), **P2** (nice to have)

> Scope note: this is Corey's fork (`gitnelson/OpenMemory`, branch `aesir/local-patches`), running as the memory backend for the Kai/Venn agent system via `~/kai-memory-system/`. Items below are **upstream defects**, not local regressions.

---

## P0 — `DELETE /memory/:id` fails for every id, so bad records can never be removed

**Discovered:** 2026-08-17, while root-causing silent memory-write loss (manual API probing during the dedupe investigation)

**What:** Every `DELETE /memory/:id` returns `500 {"err":"internal"}` — verified against four different valid ids, including ones read back seconds earlier from `/memory/all`. No stack trace or error line appears in the container logs, so the server swallows its own exception. There is no working deletion path at all: `DELETE /memory/delete/:id` and `POST /memory/delete` both 404, and `DELETE /memory/all` 404s. `PATCH /memory/:id` works (200), so **overwriting a record's content is currently the only way to neutralize it**.

This is P0 because it is unrecoverable data accumulation: any record written in error — a bad import, a diagnostic probe, leaked content, a wrong-user write — is permanent. It also silently disables the dedupe cleanup in the client: `sync-notion-to-openmemory.js --force` calls `deleteFromOpenMemory()` before re-adding, that helper counts only `delResponse.ok`, so a forced re-sync deletes nothing and appends duplicates instead of replacing.

**Locations:**
- `backend/src/server.ts` — the `DELETE /memory/:id` route (returns `{"err":"internal"}`; the throwing call is not logged)
- `~/kai-memory-system/sync-notion-to-openmemory.js` — `deleteFromOpenMemory()`, whose return value silently becomes 0

**Fix:** Log the caught exception in the delete handler before returning `err: internal` — the cause is currently invisible, which is the first thing to fix. Likely candidates given the insert path: the row has dependent vector-store rows and graph edges that are not being cleaned up in the same transaction, or the delete opens a transaction that collides with the background decay pass (see P1 below). Add a route test that inserts, deletes, and asserts the record is gone.

---

## P1 — Insert transactions collide with the background decay pass and kill writes

**Discovered:** 2026-08-17, surfaced immediately after the dedupe fix let real writes reach the insert path for the first time

**What:** `add_hsg_memory()` opens a transaction around the insert, embedding, and vector-store writes. The background HSG decay process opens its own transaction on a timer. When they overlap the insert dies with `SQLITE_ERROR: cannot start a transaction within a transaction` and the write is lost. This is not an edge case under load — on the first post-fix sync run it killed **6 of 9 writes**, and an identical retry moments later succeeded for all of them.

It was invisible until now only because the dedupe bug (fixed) was discarding those same writes before they ever reached the transaction. Embedding happens *inside* the transaction and makes network calls to Gemini with a configured `OM_EMBED_DELAY_MS=200` per sector, so the transaction is held open for seconds at a time — which is why the collision is easy to hit rather than rare.

**Locations:**
- `backend/src/memory/hsg.ts` — `add_hsg_memory()`, `transaction.begin()` wrapping `ins_mem` + `embedMultiSector` + `storeVector`
- `backend/src/memory/decay.ts` (decay pass) — opens a transaction on a timer
- Worked around at `~/kai-memory-system/om-fetch.js` — `addMemory()` retries this specific error with backoff

**Fix:** Serialize transactions (a mutex/queue around `transaction.begin()`), or — better — move the slow embedding network calls *outside* the transaction so it only wraps the actual DB writes. The client-side retry is a bandage: it makes the loss visible and recoverable, but concurrent writers will still collide.

---

## P1 — `compute_simhash` yields 32 bits of entropy, not 64, and is frequency-blind

**Discovered:** 2026-08-17, reading the dedupe path after unrelated sessions were found merging into each other

**What:** Two independent weaknesses in the same function.

1. **Half the hash is a copy of the other half.** The function accumulates a 64-slot vector, but the per-token hash `h` is a 32-bit JS integer (`h = h & h`), and JavaScript takes the shift count mod 32 — so `1 << i` for `i >= 32` wraps and tests the *same* bit as `1 << (i-32)`. Slots 32–63 are therefore exact duplicates of slots 0–31. The "64-bit" simhash carries **32 bits of real entropy**, and any hamming-distance threshold over it is effectively doubled.

2. **It hashes a frequency-blind token SET.** `canonical_token_set(content)` discards term frequency and document length entirely, so two long documents that share a vocabulary produce near-identical hashes regardless of subject matter. Observed live: a fixed-price RFP audit and a three-month-old system-brainstorm note collided.

Impact is now contained for dedupe specifically — that path was patched to require a SHA-256 content match — but the hash is still weak for **any other consumer**, and the collision rate grows with corpus size.

**Locations:**
- `backend/src/memory/hsg.ts:285` — `compute_simhash()`; the `1 << i` wrap is in the `for (let i = 0; i < 64; i++)` loop
- `sdk-js/src/memory/hsg.ts` — carries the same implementation (patched backend only; **the SDK copy is unpatched**)

**Fix:** Use two independent 32-bit hashes (or a 64-bit hash via `BigInt`) so all 64 slots carry real signal, and weight tokens by frequency rather than using a set. Verify by hashing two known-distinct long documents and asserting the hamming distance exceeds the dedupe threshold.

---

## P2 — Dedupe lookup ignores `user_id`, letting one agent's memory absorb another's

**Discovered:** 2026-08-17, same read-through of the dedupe path

**What:** `get_mem_by_simhash` selects on `simhash` alone with no `user_id` predicate, so a **Venn** memory can be returned as the duplicate match for a **Kai** write (and vice versa). With the multi-tenant `user_id` column otherwise respected throughout the API, this is a cross-tenant leak in the one place it matters most — the returned id is handed back to the caller as if it were theirs.

Also in the same block: the guard reads `hamming_dist(simhash, existing.simhash) <= 3`, but the lookup is `where simhash=$1` (**exact match**), so the distance can only ever evaluate to 0. The tolerance is dead code that reads as a deliberate fuzzy threshold.

**Locations:**
- `backend/src/core/db.ts:268` — `get_mem_by_simhash`, `select * from ${m} where simhash=$1 order by salience desc limit 1`
- `backend/src/memory/hsg.ts` — the `hamming_dist(...) <= 3` guard in `add_hsg_memory()`

**Fix:** Add `and user_id=$2` to the query and pass the caller's `user_id`. Either delete the `hamming_dist` guard or make the lookup actually fuzzy (bucketed prefix probe) so the threshold means something. The local patch already checks `user_id` equality client-of-the-query-side, which mitigates but does not fix the query itself.
