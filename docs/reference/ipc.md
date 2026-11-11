---
type: reference
owner: contract
updated: 2026-11-06
---

# IPC Contract

## IPC contract — appctl → GUI

`IPC/` contains only the serializable stdout events, not HTTP types:

- `{"schema":0,"event":"ready","port":8787,"pid":123}` — exactly one line after the server starts
  serving; `stderr` is never parsed; `port` is authoritative (1…65535).
- `{"schema":0,"event":"error","message":"…"}` — a pre-ready failure; the supervisor stops the
  process and reports a protocol failure.
- Any other stdout line is a log line. The argv/env contract (token via `PHOTON_APPCTL_TOKEN`,
  never argv, in the GUI launch shape; the CLI still accepts `--token` for manual use) and the
  SIGTERM→SIGKILL state machine live in `ServerControl`
  ([ADR-0010](../decisions/0010-appctl-process-contract.md)); `StatusEvent` is deferred until
  a real GUI need exists.

## Process contract (ADR-0010)

`appctl serve` writes **exactly one** JSON line to stdout
after it starts serving, and nothing else:

```json
{"schema":0,"event":"ready","port":8787,"pid":12345}
```

Everything human (batch/work/listen/token/auth/Ctrl-C) goes to **stderr**. `port` is the actual
bound port; the current CLI only accepts a fixed 1…65535 port (`--port 0` follows with the macOS
GUI, which is deferred). The token is read from `--token`, then `$PHOTON_APPCTL_TOKEN`, then
`$PHOTON_TOKEN`, else generated; a generated token is printed to stderr only. SIGTERM stops the
server and exits 0.
