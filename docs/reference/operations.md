---
type: reference
owner: docs
updated: 2026-11-06
---

# Operations

- **Recipe and source identity.** Recipe schema 0 is the only accepted contract; bump the schema on a
  semantic change and never silently reinterpret an old recipe. Source identity is the SHA-256 of the
  bytes: a re-export is a new id and a recipe for the old bytes is refused (409 `source_changed`),
  never paired silently.
- **Cache and invalidation.** mtime/size are insufficient; invalidate on a hash change even when
  size, mtime and inode are preserved. The intended key for a recipe-aware cache is
  `hash(source) + hash(recipe) + app build + output profile`. Two recipe-independent caches exist
  today: the base preview (key: source sha + `appVersion` + preview long edge + the PNG's recorded
  sha) and the filmstrip thumbnail `thumbnail-512-v1.heic` (key: target height + renderer tag, no
  `appVersion`); neither consumes `Recipe.renderKey()` — details in [wire.md](wire.md) and
  [ADR-0013](../decisions/0013-thumbnail-api.md); wiring a recipe-aware cache is unscheduled.
- **Atomic replacement.** Every replaceable artifact (preview, sidecars, deliverables) goes through
  `AtomicFile` — same-directory temp file + POSIX `rename(2)`. **Never remove-then-move:** the target
  does not exist between the two steps.
- **Source immutability.** TIFFs live in a read-only folder; do not write XMP into them (Capture One
  may rewrite or ignore it). All state lives in sidecars, and a SHA-256 manifest makes a re-export
  detectable even when size/mtime are preserved.
- **Folder layout (batch design, unscheduled).** `shoot/01_capture` (immutable) → `02_sdr` → `03_hdr` →
  `04_recipes` → `05_cache`; finals `{shoot}_{frame}_v{NNN}.heic`. The current flat `--out` set
  ([deliver.md](deliver.md)) stays the delivery format until the batch design replaces it.
- **Network.** Trusted LAN only, one iPad, per-session bearer token; plain HTTP today, TLS and Bonjour
  unscheduled. Never port-forward the server or run it on a
  public network.
- **Disconnects and restarts.** Jobs keyed by recipe hash, reconcile on reconnect, write temp +
  atomic rename so no half-written HEIC survives. A future delivery queue must survive a restart.
- **Backups.** 3-2-1 for originals, recipes and finals, excluding cache; periodically decode a random
  final on a clean machine — a backup that cannot decode is not a backup.
