## What a bundle tells its maker about a project that pins the Nim compiler
## its recipe is compiled with.
##
## A project's committed lock may pin that compiler to an official Nim
## release (`packageSource "nim", "store"` with an exact `uses: "nim ==V"`;
## `repro lock refresh` records the release archive). An upstream Nim
## release starts the C compiler, the assembler and the linker it drives,
## and every compile-time `staticExec`, through `/bin/sh -c`. The monitor
## records what that shell loads as inputs of the project's recipe
## compiles, so those records hold only on a machine whose `/bin/sh` is the
## same program as the exporting machine's: restored on another, the recipe
## is compiled again. The Nim reprobuild ships runs those commands without
## a shell, so an unpinned project carries no such dependency.
##
## `repro bundle create`, `repro store closure` and `repro store export`
## cannot remove the dependency, so they say so, once per such project, on
## stderr: a warning, not a refusal, because the bundle is still correct
## (a record that does not hold is recompiled, never reused).

import repro_lock
import repro_selfhost

proc pinnedUpstreamNimNotes*(projectDirs: openArray[string]): seq[string] =
  ## One note for each of `projectDirs` whose committed lock pins the Nim
  ## compiler of its recipe, naming the lock, the version and, when the
  ## lock records one, the release archive. A directory with no lock, an
  ## unpinned or unreadable lock, or a tampered pin (which every engine
  ## entry refuses on its own) gets none.
  for dir in projectDirs:
    var pin: SelfPin
    try:
      pin = projectPinsFor(dir).providerNim
    except CatchableError:
      continue
    if pin.state != spsPinned:
      continue
    let source =
      if pin.archive.isPinned: " from " & pin.archive.url
      else: ""
    result.add(pin.lockPath & " pins Nim " & pin.version & source &
      " as the compiler of the recipe in " & dir & ". An upstream Nim " &
      "release starts the C compiler, the linker and compile-time " &
      "commands through /bin/sh, so the recipe compiles carried for this " &
      "project depend on this machine's /bin/sh: a machine whose /bin/sh " &
      "is a different program compiles that recipe again after restoring. " &
      "Without the pin, the recipe is compiled by the Nim reprobuild " &
      "ships, which starts those commands without a shell.")

proc warnPinnedUpstreamNim*(command: string; projectDirs: openArray[string]) =
  ## Print `pinnedUpstreamNimNotes` for `projectDirs` on stderr, each as a
  ## warning of `repro <command>`.
  for note in pinnedUpstreamNimNotes(projectDirs):
    try:
      stderr.writeLine("repro " & command & ": warning: " & note)
    except IOError:
      discard
