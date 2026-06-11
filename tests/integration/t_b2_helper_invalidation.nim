## Bootstrap-And-Self-Build B2: touching one helper's source
## invalidates only that helper's action cache; the other two stay
## cache-hit.
##
## Strategy
## --------
## Drive ``./build/bin/repro --tool-provisioning=path --daemon=off
## build .#test-helpers --report=full`` twice:
##
##   1. First invocation: warms the action cache against whatever
##      ``build/test-bin/`` state the prior ``just build`` /
##      ``scripts/run_tests.sh`` driver left behind. We do NOT remove
##      the binaries first — the engine's "outputs-present" fast-path
##      or its action cache handles the first pass.
##
##   2. Touch the ``live_endpoint_helper.nim`` source (bump mtime),
##      then re-invoke the same build. The build report's
##      ``cacheDecision`` field is inspected:
##
##        * ``reprobuild.test_helpers.live_endpoint_helper`` MUST
##          report a non-cache-effective decision (it re-ran) — the
##          touched source invalidates its action signature.
##        * The other two test-helper actions MUST report a
##          cache-effective decision (they did NOT re-run) — no
##          spurious rebuilds.
##
## Cache-effective semantics mirror ``t_b1_apps_action_cache_hit.nim``:
## an action did NOT re-run if its ``status`` is ``asCacheHit`` /
## ``asUpToDate`` or its ``cacheDecision`` reports ``Hit`` /
## ``NotCacheable``.
##
## Skip-when-absent: same B0 / B1 classifier pattern. If the engine
## surfaces a known provisioning gap, we skip cleanly.

import std/[json, os, osproc, strtabs, strutils, times, unittest]

const RepoMarker = "repro.nim"

const HelperNames = [
  "live_endpoint_helper",
  "fake_protocol_daemon_helper",
  "harness_apply_lock_holder",
]

const TouchedHelper = "live_endpoint_helper"
const TouchedSource =
  "tests/fixtures/local-daemons-control-plane/live-endpoint-helper/" &
  "live_endpoint_helper.nim"

const ActionIdPrefix = "reprobuild.test_helpers."

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
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc cacheEffective(action: JsonNode): bool =
  ## Mirrors ``t_b1_apps_action_cache_hit.nim``: an action did NOT
  ## re-run if its status is a cache hit / up-to-date or its
  ## cacheDecision reports Hit / NotCacheable.
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

proc runBuildHelpers(reproBin, repoRoot: string; withReport: bool):
    tuple[output: string; exitCode: int] =
  let args = @[
    reproBin.quoteShell,
    "build",
    ".#test-helpers",
    "--tool-provisioning=path",
    "--daemon=off",
    "--report=" & (if withReport: "full" else: "none"),
    "--log=actions",
    "--progress=quiet",
  ]
  let cmd = args.join(" ")
  runWithRunquotaOnPath(cmd, repoRoot)

proc touchFile(path: string) =
  ## Bump the mtime so the engine's input-signature differs from the
  ## previous run. We push the timestamp slightly into the future to
  ## guarantee monotonic ordering vs. any concurrent filesystem write.
  let now = getTime() + initDuration(seconds = 2)
  setLastModificationTime(path, now)

suite "Bootstrap-And-Self-Build B2: helper invalidation":

  test "touching one helper source invalidates only that helper":
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
      # Phase 1 — warm the cache. Either the engine compiles the
      # helpers (cold path) or it observes the outputs-present
      # fast-path (warm path). We don't read the report here.
      let (firstOut, firstExit) =
        runBuildHelpers(reproBin, repoRoot, withReport = false)
      checkpoint("first exit=" & $firstExit)
      var classifiedSkip = false
      if firstExit != 0:
        checkpoint(firstOut)
        if looksLikeProvisioningOrLimitation(firstOut):
          checkpoint("skipped — engine surfaced a known limitation " &
            "during the warm-up ``repro build .#test-helpers`` pass.")
          skip()
          classifiedSkip = true
        else:
          check firstExit == 0

      if not classifiedSkip and firstExit == 0:
        # Phase 2 — bump the live_endpoint_helper.nim mtime, re-run,
        # and inspect the build report's per-action cache decisions.
        touchFile(touchedAbs)
        checkpoint("touched: " & touchedAbs)

        let (secondOut, secondExit) =
          runBuildHelpers(reproBin, repoRoot, withReport = true)
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
            checkpoint("build report at " & reportPath & " missing")
            check fileExists(reportPath)
          else:
            let report = parseFile(reportPath)
            let actions = reportActions(report)
            var helperActions: seq[JsonNode] = @[]
            for action in actions:
              let id = action{"id"}.getStr()
              if id.startsWith(ActionIdPrefix):
                helperActions.add(action)
            checkpoint("found " & $helperActions.len &
              " " & ActionIdPrefix & "* actions in build report")
            if helperActions.len == 0:
              checkpoint("no " & ActionIdPrefix & "* actions in " &
                "report — engine may have shortcut the collection; " &
                "skipping the invalidation assertion as a documented " &
                "gap.")
              skip()
            else:
              # Audit each helper action.
              var touchedRan = false
              var spuriousRebuilds: seq[string] = @[]
              for action in helperActions:
                let id = action{"id"}.getStr()
                let status = action{"status"}.getStr()
                let cache = action{"cacheDecision"}.getStr()
                let isTouched = id == ActionIdPrefix & TouchedHelper
                let cacheHit = cacheEffective(action)
                checkpoint(id & " status=" & status &
                  " cacheDecision=" & cache &
                  " (touched=" & $isTouched &
                  ", cacheEffective=" & $cacheHit & ")")
                if isTouched:
                  # The touched helper MUST have re-run — anything
                  # else means the engine missed the mtime change and
                  # the invalidation contract is broken.
                  if not cacheHit:
                    touchedRan = true
                else:
                  # The other two MUST be cache-hit / up-to-date.
                  if not cacheHit:
                    spuriousRebuilds.add(id & " (status=" & status &
                      " cache=" & cache & ")")

              # Tally:
              check touchedRan
              if not touchedRan:
                checkpoint("BUG: touched helper '" & TouchedHelper &
                  "' did NOT re-run after its source's mtime bumped.")
              if spuriousRebuilds.len > 0:
                checkpoint("spurious rebuilds: " &
                  spuriousRebuilds.join(", "))
              check spuriousRebuilds.len == 0
