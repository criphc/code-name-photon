---
type: reference
owner: contract
updated: 2026-11-09
---

# Wire Contract

HTTP JSON payloads are defined only in `ContractKit/Wire`; the wire types, golden bytes and the M2 HTTP API live here in one place. `appctl` command lines are in [cli.md](cli.md); the stdout readiness protocol is in [ipc.md](ipc.md).

## Wire contract — one home, one set of golden bytes

The HTTP JSON payloads are defined **only** in `Wire/`; the server and the client both import this
type set (there is no mirrored DTO file). The schema-0 bytes are frozen as a package resource:

```
Tests/ContractKitTests/Fixtures/schema-0/
  server/{health,items,preview-meta,recipe}.json    # real server responses
  client/{prepare-response,recipe-post-response,api-error}.json
```

- `server/*` are byte copies of the archived server output; the two envelope fixtures are
  composed from the same real payloads (item + meta + recipe, with the archived `renderKey`).
- The contract tests decode these bytes with the unified types and assert decode→encode→decode is
  lossless with the same JSON shape; the server/client tests read the **same files** instead of
  keeping their own copies.
- The archived `source.path` values are the old absolute paths and are kept as-is (provenance only);
  `docs-check` excludes `Fixtures/`.
- **Schema 0 is the frozen contract.** New queue states (rendered/encoded/verified) are unscheduled
  schema work and must bump/version the schema deliberately, never change these bytes in place.

## M2 server (LAN API for the iPad)

Every route except `/api/health` needs `Authorization: Bearer <token>` (or `X-Photon-Token`).
An empty or whitespace-containing `--token` is a usage error; an empty env token is treated as
unset and a generated token is printed; `ServerConfig` refuses an invalid token, so the server never
starts open.
`/api/health` reports `authRequired` (`true` iff a token is configured) and a cached, non-blocking
item count, so it answers while a cold `prepare` is still rendering. The 10 s receive timeout only
bounds how long the *client* may take to deliver a request (it resets on every received chunk and is
cancelled once the request parses), so a queued or slow `prepare` is never answered with 400; a
handler that never returns is answered with 500 after 600 s. Framing errors are decided from the
headers: a declared body over 4 MiB gets 413 immediately, LF-only framing gets 400 immediately, and
every `Transfer-Encoding` value must be `identity` (else 501).

## The M2.1 wire contract

The iPad receives the **SDR base**, never a rendered
HDR HEIC: a gain map is a ratio with one recipe baked in, and `mask`/`gain` are pure functions of the
base luma and the three controls, so a baked map can neither be re-modulated nor serve the judging
loop. The Mac transports a 16-bit Display P3 PNG of the base plus `PreviewMetadata` (source identity,
base facts, recipe defaults); the iPad computes HDR in-shader and only the recipe travels back. The
delivered gain-map HEIC is produced at full resolution by `appctl deliver`; the default-recipe HEIC
that `appctl prep` writes is a development/regression artifact and is **not** part of this API.

| endpoint | meaning |
|---|---|
| `GET /api/health` | reachability + item count (no auth); `authRequired` reflects whether a token is configured; the count is a cached file count that does not take the store lock |
| `GET /api/items` | the batch: `{items:[ItemSummary]}` sorted by name |
| `GET /api/items/{id}` / `.../status` | one item (same shape) |
| `POST /api/items/{id}/prepare` | idempotent render of the **SDR base preview**; returns `{item, meta, cached}` |
| `GET /api/items/{id}/preview` | 16-bit Display P3 PNG base bytes (prepares on a cold cache) |
| `GET /api/items/{id}/thumbnail` | 512-high Display P3 HEIC bytes for the filmstrip; on-demand, never prepares |
| `GET /api/items/{id}/meta` | `PreviewMetadata` JSON (prepares on a cold cache) |
| `GET /api/items/{id}/recipe` | stored recipe, 404 when none |
| `POST /api/items/{id}/recipe` | validate + store a recipe; returns `{item, recipe, renderKey}` |

**Thumbnails.** `GET /api/items/{id}/thumbnail` returns the filmstrip's 512-high 10-bit Display P3
HEIC, rendered on demand from the source TIFF and cached as `work/<sha>/thumbnail-512-v1.heic`. Sizing
is by height (a 3:2 landscape is 768×512); a source shorter than 512 is not upscaled, and a panorama is
capped at 2560 px wide. The cache key is the file name (target height + renderer tag) and deliberately
excludes `appVersion`. The route never runs `prepare` and never changes `state`: an item with only a
thumbnail is still `pending`. Failures reuse the `prepare` mapping (non-P3 → 422 `source_unreadable`,
orientation ≠ 1 → 500 `prepare_failed`) and do not mark the item `failed`.

**Identity and state.** Item id = SHA-256 of the source bytes, never a path. `work/<sha>/` holds
`preview-base.png`, `preview-meta.json`, `state.json` and a posted `recipe.json`. Lifecycle
`pending → preview_ready → recipe_received` (or `failed` + `lastError`). The reported state is
**derived from the artifacts**, never from a hand-written flag: a valid preview pair plus a decodable
`recipe.json` → `recipe_received`; a preview pair alone → `preview_ready`; neither and a recorded
failure → `failed`; otherwise `pending`. A POSTed recipe therefore does not by itself claim
`preview_ready` (recipe-before-prepare reads `pending` with `hasRecipe: true`); deleting or corrupting
`recipe.json` falls back to `preview_ready`. A re-export is a new id, and a recipe for the old bytes is
refused with **409 `source_changed`** — enforced by re-hashing the source in **both** `prepare` and
`POST …/recipe` before any cache or recipe decision.

**Errors.** JSON `{"error":{"code":"…","message":"…"}}`, `code` one of `unauthorized`, `not_found`,
`method_not_allowed`, `bad_request`, `invalid_recipe`, `source_changed`, `source_unreadable`,
`prepare_failed`, `internal_error`; status mapping 401 / 404 / 405 / 400 / 409 / 422 / 500, with
`bad_request` also the protocol-layer code (malformed request 400, oversized headers/body 413,
unsupported transfer coding 501). `source_unreadable` (422) also covers "readable but unsupported": a
non-Display-P3 source is refused at decode with an actionable message, not clamped and reported as a
500 `prepare_failed`.

**Cache.** The base preview is recipe-independent and hits only when the source sha, `appVersion`
(`0.3.0-m21`), the preview long edge and the PNG's recorded sha all still match; `prepare` re-hashes
the source before serving a cache hit and `POST …/recipe` re-hashes before accepting a recipe — an
in-place rewrite that preserved size, mtime and inode still produces 409 `source_changed` and a
refreshed id. The recipe half of the key, `Recipe.renderKey()`, is defined in
[recipe.md](recipe.md) (SHA-256 over the canonical render JSON; `created` and
the provenance-only `source.path` excluded). Since M4 the delivery report and the recipe echo record
and consume `renderKey`; the preview cache still does not. `/api/health`'s `itemCount` is an advisory
cached count refreshed by list/prepare scans and never takes the store lock, so it may lag a folder
change until the next scan. Every sidecar, the base PNG and `preview.heic` are replaced with temp file
+ `rename(2)` (`AtomicFile`).

```bash
# from the repo root, with the server started as above
TOKEN=secret
curl -sS http://127.0.0.1:8787/api/health
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/api/items
ID=$(curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/api/items \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["id"])')
curl -sS -H "Authorization: Bearer $TOKEN" -o preview-base.png "http://127.0.0.1:8787/api/items/$ID/preview"
curl -sS -H "Authorization: Bearer $TOKEN" --data-binary @recipe.json \
     "http://127.0.0.1:8787/api/items/$ID/recipe"
```

Gaps by design: plain HTTP (no TLS), no Bonjour discovery, no folder watcher, no automatic delivery
on recipe receipt (recipes are applied by an explicit `appctl deliver`). `verify-heic` is for the M1
dev artifact and the M4/M5 delivered file — the M2 base PNG is a plain 16-bit PNG and is not gain-map
content. Do not expose the server beyond the trusted LAN.
