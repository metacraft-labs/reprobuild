## A stand-in for a reprobuild image, for the resolving launcher's
## end-to-end test.
##
## WHY A STUB AND NOT A REAL REPROBUILD. The launcher's contract is "exec the
## image the committed lock addresses, with the caller's argv unchanged". To
## observe it you need SEVERAL images that are distinguishable from each other
## at runtime, resident in one store at the same time, plus a bootstrap that
## is a fourth. Building four real reprobuilds from one tree takes a
## `{.strdefine.}` and four minutes of compiler; what the assertion needs is
## only that each one says who it is. Nothing here stands in for the code
## under test -- the launcher, the lock writer, the store and the pin-root
## machinery are all the real ones.
##
## HOW IT KNOWS WHICH IMAGE IT IS. From its own location, not from a
## compile-time define or an environment variable: `<prefix>/bin/repro` reads
## `<prefix>/VERSION`. That matters, because the launcher's whole job is to
## pick a DIRECTORY, and an image that took its identity from the environment
## would report the same string from whichever directory it was exec'd out of
## -- which is precisely the bug the test exists to catch.

import std/[os, strutils]

proc versionLabel(): string =
  ## `<prefix>/bin/<exe>` -> the contents of `<prefix>/VERSION`.
  let marker = parentDir(parentDir(getAppFilename())) / "VERSION"
  if fileExists(marker): readFile(marker).strip()
  else: "unlabelled"

when isMainModule:
  let args = commandLineParams()
  let label = versionLabel()

  # Used by the BOOTSTRAP hand-over test as well
  # (`tests/integration/t_the_bootstrap_hands_over_to_the_pinned_reprobuild`),
  # where the bootstrap is the real engine and this stub is the pinned image
  # -- or, installed as `bin/nim`, the pinned provider compiler.
  #
  # `M5_STUB_RECORD` names a file to append one line per invocation to: this
  # image's path and its argv. It is how that test observes that the
  # provider compile ran THIS file as `nim`, which nothing else can show
  # without compiling a real provider.
  let record = getEnv("M5_STUB_RECORD")
  if record.len > 0:
    let f = open(record, fmAppend)
    f.writeLine(getAppFilename() & "	" & args.join(" "))
    f.close()

  # `print-handover` is not a reprobuild verb, which is the point: an engine
  # that answered it itself would print its usage error, so seeing these
  # lines at all means the argv reached this image. Each argument and each
  # variable a hand-over is specified to set or clear is printed verbatim.
  if args.len >= 1 and args[0] == "print-handover":
    echo "stub-repro " & label & ": handed over"
    for i, a in args:
      echo "argv[" & $i & "]=" & a
    for name in ["REPRO_SELFHOST_RESOLVED", "REPRO_PUBLIC_CLI_PATH",
                 "REPRO_FULL_CLI", "REPRO_NIM_COMPILER", "M5_HANDOVER_PROBE"]:
      echo "env " & name & "=" & (if existsEnv(name): getEnv(name)
                                  else: "<unset>")
    quit(0)

  # `self provision` is the one verb the launcher calls whose FAILURE is part
  # of the contract under test: a pin naming a version the store has not got
  # must end as a refusal, not as a fallback. A stub that succeeded here
  # would send the launcher down the "provisioned but left no binary" arm
  # instead, which is a different sentence for a different defect.
  if args.len >= 2 and args[0] == "self" and args[1] == "provision":
    stderr.writeLine("stub-repro " & label & ": self provision: the " &
      "requested version is not resident and no local image was offered")
    quit(1)

  # `self hold` is a bookkeeping call the launcher makes FOR ITSELF. It
  # answers on stdout deliberately: if the launcher ever hands a bookkeeping
  # child the real stdout again, this line lands in the output the user's
  # command owns and the test sees it.
  if args.len >= 2 and args[0] == "self" and args[1] == "hold":
    echo "stub-repro " & label & ": self hold: ok"
    quit(0)

  echo "repro " & label
  quit(0)
