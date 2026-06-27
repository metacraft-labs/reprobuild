## Workspace-Manifest-Optional MO-6 — a ``projectExtension`` is INERT when
## its repo is absent, and AUTO-ACTIVATES by mere presence once checked out
## as a develop-mode sibling (no explicit enable step).
##
## Two phases against the SAME original project:
##
##   Phase A (absent).  Only ``<ws>/original/repro.nim`` exists. The build
##     resolves the standalone graph: ``orig-aggregate`` is present,
##     ``ext-aggregate`` is NOT, and the command succeeds (no error — the
##     missing extension is simply not discovered).
##
##   Phase B (present).  ``<ws>/ext/repro.nim`` (a ``projectExtension
##     extProj, originalProject:`` recipe) is checked out alongside. The
##     SAME ``repro build <ws>/original`` invocation now yields the
##     augmented graph: ``ext-aggregate`` appears — WITHOUT any enable
##     flag, ``uses:`` edit, or change to the original project.
##
## Falsifiability: if the extension LEAKED while absent (phase A shows
## ``ext-aggregate``) or ERRORED, phase A fails. If presence did NOT
## auto-activate (phase B still lacks ``ext-aggregate``), phase B fails.

import std/[json, os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

const originalRecipe = """
import repro_project_dsl

package originalProject:
  build:
    discard aggregate("orig-aggregate", actions = @[])
"""

const extensionRecipe = """
import repro_project_dsl

projectExtension extProj, originalProject:
  build:
    discard aggregate("ext-aggregate", actions = @[])
"""

proc listTargetNames(projectDir: string):
    tuple[names: seq[string]; rc: int; output: string] =
  putEnv("REPROBUILD_NO_RUNQUOTA", "1")
  let (output, rc) = execCmdEx(reproBinary & " build " &
    quoteShell(projectDir) &
    " --list-targets --json --tool-provisioning=path --no-runquota")
  var names: seq[string] = @[]
  let firstBrace = output.find('{')
  let lastBrace = output.rfind('}')
  if rc == 0 and firstBrace >= 0 and lastBrace > firstBrace:
    try:
      let node = parseJson(output[firstBrace .. lastBrace])
      let targets = node{"targets"}
      if not targets.isNil and targets.kind == JArray:
        for entry in targets:
          names.add(entry{"name"}.getStr())
    except CatchableError:
      discard
  (names: names, rc: rc, output: output)

suite "MO-6: projectExtension inert when absent, auto-activates when present":

  test "inert when absent, auto-activates by presence in the develop workspace":
    if not fileExists(reproBinary):
      skip()
    else:
      let ws = getTempDir() / "mo6-activate-" & $getCurrentProcessId()
      removeDir(ws)
      defer: removeDir(ws)

      let originalDir = ws / "original"
      let extDir = ws / "ext"
      createDir(originalDir)
      writeFile(originalDir / "repro.nim", originalRecipe)

      # ---- Phase A: extension ABSENT -> inert, standalone graph. ----
      let absent = listTargetNames(originalDir)
      checkpoint("absent exit=" & $absent.rc)
      checkpoint(absent.output)
      check absent.rc == 0                       # no error when absent
      check "orig-aggregate" in absent.names     # standalone graph intact
      check "ext-aggregate" notin absent.names   # extension contributes nothing

      # ---- Phase B: extension checked out -> auto-activates. ----
      # No enable flag, no edit to originalProject — presence alone.
      createDir(extDir)
      writeFile(extDir / "repro.nim", extensionRecipe)

      let present = listTargetNames(originalDir)
      checkpoint("present exit=" & $present.rc)
      checkpoint(present.output)
      check present.rc == 0
      check "orig-aggregate" in present.names    # base graph still present
      check "ext-aggregate" in present.names      # auto-activated by presence
