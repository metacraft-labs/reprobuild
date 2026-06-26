## Workspace-Manifest-Optional MO-6 — a ``projectExtension`` recipe present
## as a develop-mode sibling ADDS its edges / targets onto the original
## project's build graph.
##
## Fixture layout (a develop workspace):
##
##   <ws>/original/repro.nim   ->  ``package originalProject:`` with one
##                                  ``aggregate("orig-aggregate", ...)``.
##   <ws>/ext/repro.nim        ->  ``projectExtension extProj,
##                                  originalProject:`` with one
##                                  ``aggregate("ext-aggregate", ...)``.
##
## With the extension PRESENT, ``repro build <ws>/original --list-targets
## --json`` (the no-build graph-surface that compiles + evaluates the
## provider and aggregates the cross-fragment target-export table) MUST
## show the extension's ``ext-aggregate`` target merged into
## ``originalProject``'s graph — alongside the base ``orig-aggregate``.
##
## Falsifiability: if ``projectExtension`` is ignored when present (no
## snapshot merge), ``ext-aggregate`` is absent from the augmented graph
## and the central assertion FAILS.

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
  ## Run ``repro build <dir> --list-targets --json`` and parse the
  ## ``targets`` array into a flat name list. RunQuota is bypassed so the
  ## provider-compile edge runs inline (no daemon needed for a graph-only
  ## inspection).
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

suite "MO-6: projectExtension adds edges to original when present":

  test "present extension contributes its target into originalProject's graph":
    if not fileExists(reproBinary):
      skip()
    else:
      let ws = getTempDir() / "mo6-present-" & $getCurrentProcessId()
      removeDir(ws)
      defer: removeDir(ws)

      let originalDir = ws / "original"
      let extDir = ws / "ext"
      createDir(originalDir)
      createDir(extDir)
      writeFile(originalDir / "repro.nim", originalRecipe)
      writeFile(extDir / "repro.nim", extensionRecipe)

      let res = listTargetNames(originalDir)
      checkpoint("exit=" & $res.rc)
      checkpoint(res.output)
      check res.rc == 0

      # Baseline: the original project's own target is present.
      check "orig-aggregate" in res.names

      # Central MO-6 assertion: the PRESENT extension's target was merged
      # into originalProject's augmented graph.
      check "ext-aggregate" in res.names
