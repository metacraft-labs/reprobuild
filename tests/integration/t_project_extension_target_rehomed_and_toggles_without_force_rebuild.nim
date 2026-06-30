## Workspace-Manifest-Optional MO-13 (correcting MO-6) — two follow-ups to the
## ``projectExtension`` DSL:
##
##   (a) TARGET RE-HOMING. MO-6 merged an extension's edges/targets into the
##       original project's GRAPH, but the target-export rows still carried the
##       EXTENSION's package name, so ``repro build <orig>:<ext-target>`` did
##       not resolve and ``--list-targets`` attributed the target to the
##       extension package. MO-13 re-homes the extension's exported targets
##       under ``originalProject``. We assert:
##         * ``--list-targets --json`` shows ``ext-aggregate`` with
##           ``"package": "originalProject"`` (re-homed), not ``extProj``;
##         * ``repro build <orig> originalProject:ext-aggregate`` RESOLVES
##           (exit 0). Without re-homing the qualified selector misses and the
##           build exits 2 (unknown_target).
##
##   (b) TOGGLE WITHOUT ``--force-rebuild``. The lowered-graph DISK cache was
##       keyed on the BASE snapshot only, so toggling an extension on/off
##       between two builds reused the STALE lowered graph (the deferral asked
##       for ``--force-rebuild``). MO-13 folds the active-extension SIGNATURE
##       into the cache key. We build the project with the extension ABSENT,
##       then add the extension and rebuild WITHOUT ``--force-rebuild``: the
##       extension's real ``ext-write`` action now runs (its marker file
##       appears and the action is named in the build log). Then we remove the
##       extension and rebuild WITHOUT ``--force-rebuild``: the graph reverts to
##       base-only (the marker is NOT regenerated — the key reverts).
##
## Falsifiable: revert the re-homing → the ``package`` is ``extProj`` and the
## qualified build exits 2. Revert the cache-key change → toggling the
## extension ON reuses the stale base-only lowered graph and ``ext-write`` does
## NOT run (no marker, not named in the log).
##
## Skip rule: ``./build/bin/repro`` absent.

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
import repro_dsl_stdlib

projectExtension extProj, originalProject:
  build:
    let w = fs.writeText(actionId = "ext-write",
      output = "ext-marker.txt", text = "ext\n")
    discard aggregate("ext-aggregate", actions = @[w])
"""

proc runRepro(args: seq[string]): tuple[code: int; output: string] =
  putEnv("REPROBUILD_NO_RUNQUOTA", "1")
  let res = execCmdEx(reproBinary & " " & args.join(" "))
  (code: res.exitCode, output: res.output)

proc listTargets(projectDir: string):
    tuple[entries: seq[tuple[name, package: string]]; rc: int; output: string] =
  let res = runRepro(@["build", quoteShell(projectDir),
    "--list-targets", "--json", "--tool-provisioning=path", "--no-runquota"])
  var entries: seq[tuple[name, package: string]] = @[]
  let firstBrace = res.output.find('{')
  let lastBrace = res.output.rfind('}')
  if res.code == 0 and firstBrace >= 0 and lastBrace > firstBrace:
    try:
      let node = parseJson(res.output[firstBrace .. lastBrace])
      let targets = node{"targets"}
      if not targets.isNil and targets.kind == JArray:
        for entry in targets:
          entries.add((name: entry{"name"}.getStr(),
                       package: entry{"package"}.getStr()))
    except CatchableError:
      discard
  (entries: entries, rc: res.code, output: res.output)

proc buildDefault(projectDir: string): tuple[code: int; output: string] =
  runRepro(@["build", quoteShell(projectDir),
    "--tool-provisioning=path", "--no-runquota", "--daemon=off"])

suite "MO-13: projectExtension target re-homing + toggle without force-rebuild":

  test "t_project_extension_target_rehomed_and_toggles_without_force_rebuild":
    if not fileExists(reproBinary):
      skip()
    else:
      let ws = getTempDir() / "mo13-rehome-" & $getCurrentProcessId()
      removeDir(ws)
      defer: removeDir(ws)

      let originalDir = ws / "original"
      let extDir = ws / "ext"
      createDir(originalDir)
      writeFile(originalDir / "repro.nim", originalRecipe)
      let markerPath = originalDir / "ext-marker.txt"

      # ---- (b) baseline: extension ABSENT -> base-only build, no marker -----
      removeFile(markerPath)
      let offBuild = buildDefault(originalDir)
      checkpoint("off build:\n" & offBuild.output)
      check offBuild.code == 0
      check not fileExists(markerPath)

      # ---- add the extension as a develop sibling --------------------------
      createDir(extDir)
      writeFile(extDir / "repro.nim", extensionRecipe)

      # ---- (a) re-homing: --list-targets attributes ext-aggregate to the
      #         ORIGINAL project, not the extension package -------------------
      let lt = listTargets(originalDir)
      checkpoint("list-targets:\n" & lt.output)
      check lt.rc == 0
      var sawOrig = false
      var extPackage = ""
      for e in lt.entries:
        if e.name == "orig-aggregate": sawOrig = true
        if e.name == "ext-aggregate": extPackage = e.package
      check sawOrig
      # Central re-homing assertion: the extension's target is now owned by the
      # ORIGINAL project (without re-homing this would be "extProj").
      check extPackage == "originalProject"

      # ---- (a) re-homing: the qualified <orig>:<ext-target> selector RESOLVES
      let qualified = runRepro(@["build", quoteShell(originalDir),
        "originalProject:ext-aggregate",
        "--tool-provisioning=path", "--no-runquota", "--daemon=off"])
      checkpoint("qualified build:\n" & qualified.output)
      # Without re-homing the qualified selector misses -> exit 2.
      check qualified.code == 0

      # ---- (b) toggle ON without --force-rebuild: the cache key now reflects
      #         the active extension set, so the STALE base-only lowered graph
      #         is invalidated and the extension's ext-write action RUNS -------
      removeFile(markerPath)
      let onBuild = buildDefault(originalDir)
      checkpoint("on build:\n" & onBuild.output)
      check onBuild.code == 0
      # THE load-bearing falsifiable cache-key assertion: the extension's real
      # action ran (marker present). Without the active-extension signature in
      # the disk-cache key the stale base-only lowered graph (0 actions) is
      # reused and the marker never appears.
      check fileExists(markerPath)
      check "actions=1" in onBuild.output      # one real action lowered + run

      # ---- (b) toggle OFF without --force-rebuild: the graph reverts to
      #         base-only (the key reverts), so ext-write does NOT run again ---
      removeDir(extDir)
      removeFile(markerPath)
      let offAgain = buildDefault(originalDir)
      checkpoint("off-again build:\n" & offAgain.output)
      check offAgain.code == 0
      check not fileExists(markerPath)
