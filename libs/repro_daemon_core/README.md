# repro_daemon_core

Core lifecycle, discovery, and protocol support for the per-user
`repro-daemon` control-plane daemon.

This library is intentionally separate from the store daemon (`reprostored`).
M1 exposes only lifecycle/status/logs/handshake messages; build and watch
execution continue to use the existing direct CLI paths.

## Daemon log

Structured diagnostics use a 16 MiB current log and one previous generation
(`<log>.1`), also limited to 16 MiB. An OS lock serializes writers; oversized
messages are marked and truncated, and older oversized logs are reduced to
their most recent 16 MiB on the next append. `repro daemon logs` prints the
previous generation followed by the current file. Writes are best effort:
lock contention lasting one second or filesystem errors drop the diagnostic.
Detached launches send raw stdout/stderr to the null device (systemd may keep
raw output in its journal); foreground invocations retain their caller's
streams. Raw output is not included in the structured log retention contract.
