## The statically linked add-on ``repro``.
##
## This is the binary an operator fetches onto a distribution host to
## bootstrap add-on mode, and the one generation 0 installs into
## ``/repro/store`` and runs from afterwards. It is built separately from
## the full engine (``apps/repro``) because the engine cannot be linked
## statically -- it loads its solver library at start-up and links TLS --
## and an add-on host must keep working when a release upgrade replaces the
## distribution's libc underneath it. It carries the add-on's verbs and the
## system-scope apply path they run on, and nothing else:
##
##   repro system addon <command> …     (see repro_addon/cli)
##   repro system adopt <address> --profile <file>
##   repro infra plan --profile <file>  (the add-on's plan sections)
##   repro infra apply --profile <file> (an add-on generation)
##   repro --version
##
## Invoked under the name ``repro-addon-fingerprint`` it is the base
## fingerprint tool.
##
## Build it with ``scripts/build_addon_static.sh``, which also writes its
## published SHA-256.

import std/os

import repro_core
import repro_addon/cli

proc main(): int =
  let args = commandLineParams()
  if extractFilename(getAppFilename()) == "repro-addon-fingerprint":
    return runFingerprintCli(args)
  if args.len >= 1 and args[0] in ["--version", "version"]:
    echo "repro " & ReprobuildVersion & " (add-on, static)"
    return 0
  if args.len >= 2 and args[0] == "system" and args[1] == "addon":
    return runAddonCli(args[2 .. ^1])
  if args.len >= 2 and args[0] == "system" and args[1] == "adopt":
    return runAddonAdoptCli(args[2 .. ^1])
  if args.len >= 2 and args[0] == "infra" and args[1] == "apply":
    return runAddonInfraApplyCli(args[2 .. ^1])
  if args.len >= 2 and args[0] == "infra" and args[1] == "plan":
    return runAddonInfraPlanCli(args[2 .. ^1])
  stderr.write("usage: repro system addon <command> … | " &
               "repro system adopt <address> --profile <file> | " &
               "repro infra plan|apply --profile <file> | repro --version\n\n")
  stderr.write(AddonUsage)
  2

quit(main())
