---
type: reference
owner: server
updated: 2026-11-09
---

# appctl CLI

## CLI (`appctl`)

`make cli` / `make appctl` builds the CLI at `.build/server/release/appctl` (or run `swift build`
inside `server/` and use `server/.build/release/appctl`). Run examples from the repo root:

```bash
.build/server/release/appctl prep fixtures/media/sources/R0003777-P3.tif \
    [--out work/<sha>/] [--recipe recipe.json] \
    [--encoder tools/toGainMapHDR/bin/toGainMapHDR] [--preview-edge 2560]
# -> sdr.tif, hdr.tif, preview.heic, meta.json
# `--encoder` is the external oracle; the default is the in-process Core Image writer.
```

`appctl serve` is different from the other subcommands: it is the process the macOS GUI supervises
and its **stdout is a protocol** — exactly one ready line, then nothing. Human logs (batch/work/
listen/token/Ctrl-C) go to stderr. See [ipc.md](ipc.md) for the readiness protocol and
[wire.md](wire.md) for the API.

Verify the result with `tools/verify-heic/bin/verify-heic` (never `sips`). See
[verification.md](verification.md).

## `appctl serve`

```bash
.build/server/release/appctl serve \
    --batch fixtures/media/sources --work work \
    --bind 0.0.0.0 --port 8787 [--token secret] [--preview-edge 2560]
```

## `appctl deliver`

```bash
.build/server/release/appctl deliver <id | --source PATH> \
    [--recipe FILE] [--out DIR] [--batch DIR] [--work DIR] \
    [--profile 10/half/rgb] [--profile 8/full/mono] [--preview-edge 2560]
# -> {stem}-hdr-{profile}.heic per profile, {stem}-sdr.heic, {stem}.recipe.json, {stem}.report.json

.build/server/release/appctl deliver --batch DIR \
    [--out DIR] [--work DIR] [--profile 10/half/rgb] [--preview-edge 2560]
# -> the same four files per delivered item; stdout is one line per item plus a result summary
```

`--profile` is repeatable (`8|10` / `full|half` / `rgb|mono`); with no `--profile` the recipe's
`encoder` block is the profile. `--encoder PATH` selects the external tool as the migration oracle;
the default is the in-process Core Image writer. The delivery contract, outputs, report schema 1 and
idempotence rules are in [deliver.md](deliver.md).

`--batch DIR` with no `<id>` and no `--source` is a **batch delivery**: every item of the folder that
has a stored recipe is delivered, one at a time, and a failed item does not stop the batch. `--recipe`
is a usage error here (each item uses its own stored recipe). Exit 0 when every deliverable item
passed, 1 when any item failed or none was deliverable, 2 for a usage error. The rules are in
[deliver.md](deliver.md#batch-delivery).
