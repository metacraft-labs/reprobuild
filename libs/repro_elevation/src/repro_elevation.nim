## Reprobuild privileged-operation broker / elevation mechanism (M81).
##
## Implements Elevation-And-Privileged-Operations.md: a `repro` apply
## containing privileged (Administrator/root) operations performs
## them through a single short-lived privileged broker, so the whole
## apply raises AT MOST ONE OS elevation prompt regardless of how
## many privileged operations it contains — and ZERO prompts when the
## plan has no privileged operations or when `repro` is already
## elevated.
##
## This is a self-contained library. M69 (`repro infra apply`, not
## built yet) consumes it; it is deliberately NOT wired into
## `repro home apply` because home-scope apply is elevation-free by
## design.
##
## Public surface (the seven M81 deliverables):
##
##   * `operations`      — the closed, typed `PrivilegedOperation`
##     set, the `requiresElevation` predicate, and the closed-set
##     validation. M81 ships two FIXTURE kinds; M69 adds the real
##     system-scope catalog here.
##   * `partition`       — the planner partition splitting an apply
##     into a non-privileged set (parent) and a privileged set.
##   * `elevation_state` — the already-elevated fast-path detection
##     (`TokenElevation` on Windows, `geteuid()==0` on POSIX).
##   * `protocol`        — the framed, typed `RBEB` wire protocol
##     codec (`Hello`/`HelloAck`, `Operation`, `OperationResult`,
##     `ApplyLogRecord`, `Done`).
##   * `ipc`             — the authenticated IPC channel (Windows
##     named pipe + peer-SID + nonce; POSIX skeleton).
##   * `fixture_driver`  — the M81 fixture privileged-operation
##     drivers (sandboxed file prefix / isolated HKLM subkey).
##   * `dispatch`        — broker-side closed-set dispatch with the
##     mandated re-observe / drift-check before every mutation.
##   * `broker`          — broker launch (`ShellExecuteEx`+`runas`),
##     the `--privileged-broker` entrypoint session loop, the
##     parent-side driver, the already-elevated fast path, and the
##     `--no-elevate` skip path.
##   * `errors`          — the typed exception hierarchy.

import repro_elevation/errors
import repro_elevation/operations
import repro_elevation/partition
import repro_elevation/elevation_state
import repro_elevation/protocol
import repro_elevation/ipc
import repro_elevation/fixture_driver
import repro_elevation/dispatch
import repro_elevation/broker

export errors
export operations
export partition
export elevation_state
export protocol
export ipc
export fixture_driver
export dispatch
export broker
