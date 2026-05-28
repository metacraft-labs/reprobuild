# repro_daemon_core

Core lifecycle, discovery, and protocol support for the per-user
`repro-daemon` control-plane daemon.

This library is intentionally separate from the store daemon (`reprostored`).
M1 exposes only lifecycle/status/logs/handshake messages; build and watch
execution continue to use the existing direct CLI paths.
