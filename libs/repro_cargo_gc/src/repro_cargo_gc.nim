## Target-directory janitor for cargo projects.
##
## Cargo never removes build units it no longer needs. This library records
## which units each cargo invocation used (`record.recordLiveSet`,
## `record.recordLiveSetFromStream`) and deletes the ones outside the last K
## invocations that are also older than T (`gc.collectGarbage`). The
## `repro cargo` verbs are thin wrappers over it, and a cargo wrapper or build
## edge can call the same entry points.
##
## Design notes: docs/cargo-gc.md.

import repro_cargo_gc/[types, layout, store, record, gc, cargo_home, config]
export types, layout, store, record, gc, cargo_home, config
