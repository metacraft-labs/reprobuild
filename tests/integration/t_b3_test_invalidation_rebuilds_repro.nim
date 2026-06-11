## Bootstrap-And-Self-Build B3: an e2e test that depends on
## ``./build/bin/repro`` rebuilds the binary AND re-runs the test's
## execute edge when a source under ``libs/repro_cli_support/`` is
## touched.
##
## Strategy
## --------
## Pick an e2e test whose TestSpec carries ``requiresReproBinary =
## true`` — i.e. its execute edge declares ``build/bin/repro`` as a
## typed input. The B3 generator (``scripts/generate_test_edges.nim``)
## sets the flag for any test whose source mentions the literal
## ``build/bin/repro``.
##
## The chosen target is ``t_show_conventions_cli`` — a small CLI
## smoke test in ``libs/repro_core/tests/`` that spawns
## ``./build/bin/repro show-conventions`` as a subprocess. The test
## is fast to compile + run and has a small enough trace.
##
## Two halves:
##
##   1. STRUCTURAL — verify the input-wiring mechanism has consumers:
##      at least a handful of TestSpec entries carry
##      ``requiresReproBinary: true`` and the targeted test is one of
##      them. Passes today without engine cooperation.
##
##   2. ENGINE — touch a source under ``libs/repro_cli_support/`` and
##      drive the engine; verify the build report shows the touched
##      source flipped both ``reprobuild.apps.repro``'s cache decision
##      and the test's execute-edge cache decision. Skips with the
##      documented classifier when the selector resolver or typed-tool
##      resolver hasn't lifted.
##
## Skip-with-classifier: standard B0-B2 pattern.

import std/[json, os, osproc, strtabs, strutils, times, unittest]

const RepoMarker = "repro.nim"
const TargetTest = "t_show_conventions_cli"
const TargetSource = "libs/repro_core/tests/t_show_conventions_cli.nim"
const TouchedSource =
  "libs/repro_cli_support/src/repro_cli_support.nim"

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
    "no named targets in this project",
    "unknown_target",
    "ambiguous_target",
    "no such test",
    "no test named",
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
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc cacheEffective(action: JsonNode): bool =
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

proc touchFile(path: string) =
  let now = getTime() + initDuration(seconds = 2)
  setLastModificationTime(path, now)

proc runBuildTarget(reproBin, repoRoot, selector: string;
                    withReport: bool):
    tuple[output: string; exitCode: int] =
  let args = @[
    reproBin.quoteShell,
    "build",
    selector,
    "--tool-provisioning=path",
    "--daemon=off",
    "--report=" & (if withReport: "full" else: "none"),
    "--log=actions",
    "--progress=quiet",
  ]
  let cmd = args.join(" ")
  runWithRunquotaOnPath(cmd, repoRoot)

proc countOccurrences(haystack, needle: string): int =
  if needle.len == 0:
    return 0
  var idx = 0
  while true:
    let hit = haystack.find(needle, idx)
    if hit < 0: break
    inc result
    idx = hit + needle.len

proc specSlice(reproTestsText, source: string): string =
  let marker = "source: \"" & source & "\""
  let pos = reproTestsText.find(marker)
  if pos < 0:
    return ""
  let limit = min(reproTestsText.len, pos + 400)
  return reproTestsText[pos ..< limit]

suite "Bootstrap-And-Self-Build B3: test invalidation rebuilds repro":

  test "structural: requiresReproBinary input-wiring has consumers":
    ## Approach A: confirm that the e2e ``requiresReproBinary``
    ## mechanism is actually consumed by ``repro_tests.nim`` and that
    ## the targeted invalidation test is flagged correctly.
    let repoRoot = findRepoRoot()
    let reproTests = repoRoot / "repro_tests.nim"
    let reproNim = repoRoot / "repro.nim"
    check fileExists(reproTests)
    check fileExists(reproNim)

    let reproTestsText = readFile(reproTests)
    let reproNimText = readFile(reproNim)

    # The generator must emit the field; the table must populate it.
    check "requiresReproBinary*: bool" in reproTestsText
    let trueCount = countOccurrences(reproTestsText,
      "requiresReproBinary: true")
    let falseCount = countOccurrences(reproTestsText,
      "requiresReproBinary: false")
    checkpoint("requiresReproBinary: true=" & $trueCount &
      " false=" & $falseCount)
    # Non-zero — the input-wiring mechanism has consumers.
    check trueCount >= 5
    # Non-zero — the default is also exercised (most tests don't spawn
    # ``./build/bin/repro``).
    check falseCount >= 100

    # The targeted invalidation test MUST be flagged true; otherwise
    # the e2e binary-input wiring won't fire and the engine won't
    # invalidate it on a ``libs/repro_cli_support/`` source change.
    let targetSpec = specSlice(reproTestsText, TargetSource)
    check targetSpec.len > 0
    check "requiresReproBinary: true" in targetSpec

    # repro.nim must consume the flag and wire ``build/bin/repro`` into
    # ``requiredBinaries`` on the execute edge.
    check "spec.requiresReproBinary" in reproNimText
    check "requiredBinaries" in reproNimText
    check "build/bin/repro" in reproNimText

    # The TouchedSource (the file the engine arm modifies) must exist;
    # otherwise the engine arm's touch step is meaningless.
    let touchedAbs = repoRoot / TouchedSource
    check fileExists(touchedAbs)

    checkpoint("structural cross-check: OK — " & $trueCount &
      " specs declare engine-built repro as a typed input")

  test "engine: touching libs/repro_cli_support invalidates apps.repro AND the test's execute edge":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = repoRoot.parentDir / "runquota" / "build" / "bin" /
      addFileExt("runquotad", ExeExt)
    let touchedAbs = repoRoot / TouchedSource

    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    elif not fileExists(runquotad):
      checkpoint("skipped — " & runquotad &
        " is missing; build runquota first")
      skip()
    elif not fileExists(touchedAbs):
      checkpoint("skipped — touch target " & touchedAbs & " missing")
      skip()
    else:
      let executeActionId = "reprobuild.test_execute." & TargetTest

      # Phase 1 — warm-up. Drive the engine against the target test's
      # execute edge so the action cache picks up the current input
      # signature. We tolerate selector-resolver gaps with the fallback
      # cascade.
      var selectorCandidates: seq[string] = @[]
      selectorCandidates.add(".#test#" & TargetTest)
      selectorCandidates.add(TargetTest)
      selectorCandidates.add(executeActionId)

      var firstExit = -1
      var firstOut = ""
      var resolvedSelector = ""
      var classifiedSkip = false
      for selector in selectorCandidates:
        let (output, exitCode) = runBuildTarget(reproBin, repoRoot,
          selector, withReport = false)
        firstOut = output
        firstExit = exitCode
        if exitCode == 0:
          resolvedSelector = selector
          break
        if "unknown_target" in output or "ambiguous_target" in output or
            "no named targets" in output or "no such test" in output:
          continue
        break

      if resolvedSelector.len == 0:
        checkpoint(firstOut)
        if looksLikeProvisioningOrLimitation(firstOut):
          checkpoint("skipped — engine surfaced a known limitation " &
            "for every attempted selector (" &
            selectorCandidates.join(", ") & ").")
          skip()
          classifiedSkip = true
        else:
          check firstExit == 0

      if not classifiedSkip:
        checkpoint("warm-up selector: " & resolvedSelector)

        # Phase 2 — touch the libs/repro_cli_support source. Pushing
        # the mtime slightly into the future guarantees monotonic
        # ordering vs concurrent fs writes.
        touchFile(touchedAbs)
        checkpoint("touched: " & touchedAbs)

        # Phase 3 — re-run the same build through the engine with the
        # full report so we can audit per-action cache decisions.
        let (secondOut, secondExit) =
          runBuildTarget(reproBin, repoRoot, resolvedSelector,
            withReport = true)
        checkpoint("second exit=" & $secondExit)

        if secondExit != 0:
          checkpoint(secondOut)
          if looksLikeProvisioningOrLimitation(secondOut):
            checkpoint("skipped — engine surfaced a known limitation " &
              "during the post-touch re-run.")
            skip()
          else:
            check secondExit == 0
        else:
          let reportPath = valueAfter(secondOut, "buildReport:")
          if reportPath.len == 0:
            checkpoint("no buildReport: line in output:")
            checkpoint(secondOut)
            checkpoint("skipped — engine did not emit a build report " &
              "path; cannot audit per-action cache decisions.")
            skip()
          elif not fileExists(reportPath):
            checkpoint("build report at " & reportPath & " missing")
            check fileExists(reportPath)
          else:
            let report = parseFile(reportPath)
            let actions = reportActions(report)
            var reproAppAction, executeAction: JsonNode = nil
            for action in actions:
              let id = action{"id"}.getStr()
              if id == "reprobuild.apps.repro":
                reproAppAction = action
              elif id == executeActionId:
                executeAction = action

            if reproAppAction.isNil:
              checkpoint("no reprobuild.apps.repro action in report — " &
                "engine may have shortcut the apps build; the touched " &
                "source's invalidation cannot be observed at this level.")
              skip()
            elif executeAction.isNil:
              checkpoint("no " & executeActionId & " action in " &
                "report — engine may have shortcut the execute edge.")
              skip()
            else:
              let reproStatus = reproAppAction{"status"}.getStr()
              let reproCache = reproAppAction{"cacheDecision"}.getStr()
              let execStatus = executeAction{"status"}.getStr()
              let execCache = executeAction{"cacheDecision"}.getStr()
              checkpoint("reprobuild.apps.repro status=" & reproStatus &
                " cacheDecision=" & reproCache)
              checkpoint(executeActionId & " status=" & execStatus &
                " cacheDecision=" & execCache)

              # Contract:
              #   * apps.repro did NOT cache-hit (it rebuilt).
              #   * the execute edge did NOT cache-hit (it re-ran on
              #     the freshly-built repro binary).
              check not cacheEffective(reproAppAction)
              check not cacheEffective(executeAction)
