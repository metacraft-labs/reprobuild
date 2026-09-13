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
