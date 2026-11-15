## `repro-rustc-wrapper`: the `RUSTC_WRAPPER` of a leased cargo action.
##
## Cargo runs `repro-rustc-wrapper rustc <args>` for each unit it compiles. The
## wrapper runs the compiler unchanged and reports the unit's totals to
## RunQuota under a per-crate key; see `libs/repro_cargo_edge` for the
## contract (it never changes the command line, falls back to running rustc
## when it cannot report, and ends the way the compiler did).
##
## Its own binary, not a `repro` subcommand, because it runs once per rustc
## and its start-up is a cost every compile pays: it links the RunQuota
## client and nothing of the engine.
import std/os
import repro_cargo_edge/rustc_wrapper

proc cExit(status: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}

when isMainModule:
  # The C `exit` keeps the low eight bits of a status above 127; Nim's `quit`
  # narrows it to a signed byte.
  stdout.flushFile()
  stderr.flushFile()
  cExit(cint(runWrapper(commandLineParams())))
