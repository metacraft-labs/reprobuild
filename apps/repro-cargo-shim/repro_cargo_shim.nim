## `repro-cargo-shim`: installed as a file named `cargo` ahead of the real one
## on `PATH`, it records a live set (docs/cargo-gc.md, "The cargo shim") from
## every compiling cargo invocation and is otherwise invisible: the same
## standard output, standard error and exit status as bare cargo.
##
## Its own small binary, not a `repro` subcommand, because it runs once per
## cargo command and its start-up is a cost every one of them pays: it links
## `repro_cargo_gc` and the standard library, and nothing of the engine. The
## behaviour is `repro_cargo_gc/shim` (library first, so a consumer can embed
## or test it); this file only hands it the command line.
import std/os
import repro_cargo_gc/shim

proc cExit(status: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}

when isMainModule:
  # The C `exit` keeps the low eight bits of a status above 127; Nim's `quit`
  # narrows it to a signed byte.
  stdout.flushFile()
  stderr.flushFile()
  cExit(cint(runShim(commandLineParams())))
