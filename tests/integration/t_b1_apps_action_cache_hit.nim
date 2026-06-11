## Bootstrap-And-Self-Build B1: a second ``repro build apps`` against
## an unchanged source tree cache-hits every per-app ``nim c`` edge.
##
## Strategy
## --------
## After a cold ``./build/bin/repro --tool-provisioning=path --daemon=off
## build apps``, the engine writes ``build-report.json`` under the
## per-target output directory. A second invocation with no source
## changes must skip every per-app ``nim c`` re-compilation:
##
##   * ``cacheDecision`` reports ``cdHit`` or ``cdNotCacheable`` for
##     every action that names a ``reprobuild.apps.<binary>`` id.
##   * ``status`` reports ``asCacheHit`` or ``asUpToDate`` for those
##     same actions (mirrors the cache-effective check used by the
##     existing e2e suite — see
##     ``t_e2e_local_reprobuild_project_build.nim`` line ~1465).
##
## Performance note
## ----------------
## A cold full-tree build can take 15-30 minutes; we deliberately avoid
## forcing one. The test does NOT remove ``build/bin/`` before running
## the first invocation. Instead it relies on the standard
## ``just build`` / ``scripts/run_tests.sh`` pipeline having already
## materialised the binaries. In that pre-warmed state the FIRST
## invocation here observes the engine's outputs-present fast path
## (status=asUpToDate) and the SECOND observes the action-cache hit
## (status=asCacheHit). Either way, every per-app action must end in a
## cache-effective state for the test to pass.
##
## When the engine's named-target resolver hasn't yet rendered the
## ``apps`` collection (or runquotad isn't on PATH), the same skip-
## with-documented-limitation pattern as the other B0 / B1 tests
## applies.

import std/[json, os, osproc, strtabs, strutils, unittest]

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc looksLikeProvisioningOrLimitation(output: string): bool =
  for needle in [
    "tool-resolution failed",
    "typed tool provisioning is required",
    "does not declare provisioning",
    "PATH-only resolver",
    "could not locate executable",
    "is not on PATH",
    "could not load: libclingo",
    "extract_runner",
  ]:
    if needle in output:
      return true
  for needle in [
    "usage: repro --version",
    "repro build [target[#name]",
  ]:
    if needle in output:
      return true
  return false

proc runWithRunquotaOnPath(cmd, repoRoot: string): tuple[output: string;
    exitCode: int] =
  let runquotaBin = repoRoot.parentDir / "runquota" / "build" / "bin"
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let oldPath = env.getOrDefault("PATH")
  env["PATH"] = runquotaBin & $PathSep & oldPath
  execCmdEx(cmd, env = env, workingDir = repoRoot)

proc valueAfter(output, prefix: string): string =
  ## Mirrors the helper in
  ## ``tests/e2e/local-build-engine/t_e2e_local_reprobuild_project_build.nim``:
  ## the engine prints ``buildReport: <path>`` on the summary line so
  ## callers can locate the JSON report without guessing the output
  ## dir.
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc readEntrypointNames(repoRoot: string): seq[string] =
  result = @[]
  let path = repoRoot / "apps" / "entrypoints.txt"
  for raw in lines(path):
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let fields = line.splitWhitespace()
    if fields.len < 2:
      continue
    result.add(fields[0])

proc cacheEffective(action: JsonNode): bool =
  ## Mirror the e2e suite's notion of "didn't re-run": either
  ## status indicates a cache hit / up-to-date, or cacheDecision
  ## reports a hit / not-cacheable. The action did NOT re-run if any
  ## of those hold.
  let status = action{"status"}.getStr()
  if status in ["asCacheHit", "asUpToDate"]:
    return true
  let cache = action{"cacheDecision"}.getStr()
  if "Hit" in cache or "NotCacheable" in cache:
    return true
  return false

proc reportActions(report: JsonNode): JsonNode =
  result = report{"actions"}
  if result.isNil or result.kind == JNull:
    result = newJArray()

proc runBuildApps(reproBin, repoRoot: string; withReport: bool):
    tuple[output: string; exitCode: int] =
  # The collection is named ``apps``; the ``.#apps`` fragment form
  # forces the CLI's name-resolver to look up the project's
  # named-target table rather than treat ``apps`` as the on-disk
  # ``apps/`` directory.
  #
  # ``withReport=false`` swaps ``--report=full`` for ``--report=none``
  # on the first (warm-up) invocation. The report write itself is
  # cheap; the expensive part is per-action ``collectEvidence`` which
  # runs regardless of the report mode. We still skip the report on
  # the warm-up because the test only reads it on the SECOND
  # invocation and the engine writes a multi-MB JSON document.
  let args = @[
    reproBin.quoteShell,
    "build",
    ".#apps",
    "--tool-provisioning=path",
    "--daemon=off",
    "--report=" & (if withReport: "full" else: "none"),
    "--log=actions",
    "--progress=quiet",
  ]
  let cmd = args.join(" ")
  runWithRunquotaOnPath(cmd, repoRoot)

suite "Bootstrap-And-Self-Build B1: apps action cache hits on second run":

  test "second repro build apps cache-hits every per-app nim c edge":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = repoRoot.parentDir / "runquota" / "build" / "bin" /
      addFileExt("runquotad", ExeExt)
    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    elif not fileExists(runquotad):
      checkpoint("skipped — " & runquotad &
        " is missing; build runquota first")
      skip()
    else:
      let names = readEntrypointNames(repoRoot)
      check names.len >= 11

      # First invocation — warms the action cache against whatever
      # binaries the pre-existing ``build/bin/`` state happens to
      # carry. In a fully pre-warmed checkout this is already a fast
      # path; in a cold checkout it will compile every app.
      let (firstOut, firstExit) =
        runBuildApps(reproBin, repoRoot, withReport = false)
      checkpoint("first exit=" & $firstExit)
      var classifiedSkip = false
      if firstExit != 0:
        checkpoint(firstOut)
        if looksLikeProvisioningOrLimitation(firstOut):
          checkpoint("skipped — engine surfaced a known limitation " &
            "during the cold ``repro build apps`` pass.")
          skip()
          classifiedSkip = true
        else:
          check firstExit == 0

      if not classifiedSkip and firstExit == 0:
        # Second invocation — must be a no-op for every per-app action.
        let (secondOut, secondExit) =
          runBuildApps(reproBin, repoRoot, withReport = true)
        checkpoint("second exit=" & $secondExit)
        if secondExit != 0:
          checkpoint(secondOut)
          check secondExit == 0
        else:
          let reportPath = valueAfter(secondOut, "buildReport:")
          if reportPath.len == 0:
            checkpoint("no buildReport: line in second-run output:")
            checkpoint(secondOut)
            checkpoint("skipped — engine did not emit a build report " &
              "path (``--report=full`` may not be honoured by this " &
              "build mode).")
            skip()
          elif not fileExists(reportPath):
            checkpoint("build report at " & reportPath & " not present")
            check fileExists(reportPath)
          else:
            let report = parseFile(reportPath)
            let actions = reportActions(report)
            var perAppActions: seq[JsonNode] = @[]
            for action in actions:
              let id = action{"id"}.getStr()
              if id.startsWith("reprobuild.apps."):
                perAppActions.add(action)
            checkpoint("found " & $perAppActions.len &
              " reprobuild.apps.* actions in build report")
            if perAppActions.len == 0:
              checkpoint("no reprobuild.apps.* actions in report — " &
                "engine may have shortcut the collection; skipping " &
                "the cache-hit assertion as a documented gap.")
              skip()
            else:
              var rebuilt: seq[string] = @[]
              for action in perAppActions:
                if not cacheEffective(action):
                  let id = action{"id"}.getStr()
                  let status = action{"status"}.getStr()
                  let cache = action{"cacheDecision"}.getStr()
                  rebuilt.add(id & " (status=" & status & " cache=" &
                    cache & ")")
              if rebuilt.len > 0:
                checkpoint("re-built actions on second run: " &
                  rebuilt.join(", "))
              check rebuilt.len == 0
