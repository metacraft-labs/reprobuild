## The statically linked add-on ``repro``.
##
## This is the binary an operator fetches onto a distribution host to
## bootstrap add-on mode, and the one generation 0 installs into
## ``/repro/store`` and runs from afterwards. It is built separately from
## the full engine (``apps/repro``) because the engine cannot be linked
## statically -- it loads its solver library at start-up and links TLS --
## and an add-on host must keep working when a release upgrade replaces the
## distribution's libc underneath it. It carries the add-on's verbs and the
## system-scope apply path they run on, and nothing else: `repro system
## addon …`, `repro system state …` (which the first-boot restore unit it
## writes runs), `repro system adopt|rollback`, `repro infra plan|apply` (an
## add-on generation), `repro store gc|recover|roots|list` (the system-scope
## store) and `repro --version`. Its command line is declared in
## ``repro_infra/addon_command_line`` and parsed by the parser generated
## from it (``repro_addon/cli``); `repro --help` prints it.
##
## Invoked under the name ``repro-addon-fingerprint`` it is the base
## fingerprint tool, whose command line is declared there too.
##
## Build it with ``scripts/build_addon_static.sh``, which also writes its
## published SHA-256.

import std/os

import repro_core
import repro_addon/cli

proc main(): int =
  let args = commandLineParams()
  if extractFilename(getAppFilename()) == "repro-addon-fingerprint":
    return runFingerprintToolArgs(args)
  runAddonArgs(args, version = "repro " & ReprobuildVersion &
    " (add-on, static)")

quit(main())
