# Local Daemons M0 Direct-Mode Parity Fixture

This fixture captures the M0 starting point for the local daemon/control-plane
track.

Current behavior:

- `apps/repro-daemon` is an entrypoint, but it delegates to the shared thin-app
  dispatcher and is not yet a daemon server.
- `repro build` runs the build graph in the invoking CLI process. It lowers the
  project provider, schedules actions, uses RunQuota when available, and can
  fall back to the direct bypass path for path-provisioned local builds.
- `repro watch` runs an in-process loop in the invoking CLI process. Each cycle
  calls the same direct build path and then waits on the platform filesystem
  watcher unless `--max-cycles` ends the loop first.
- `repro daemon`, `repro build --daemon=auto|require|off`,
  `repro build --stats-capture=...`, and `repro stats` are intentionally absent
  in M0.
- `repro store daemon` / `reprostored` are a separate store-daemon lifecycle
  surface from the user/watch daemon surface owned by `repro daemon`.

The `project/` directory is deliberately small and uses built-in filesystem
actions only. M0 runs it through the current direct path. Later milestones
should run the same fixture through both explicit direct mode
(`--daemon=off`) and daemon mode once those controls exist.
