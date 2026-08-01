## Bootstrap-And-Self-Build B2: helper build edges are present in the
## graph and execute as explicit non-cacheable actions.
##
## The helper binaries are compiled by ``nim.c`` edges in ``repro.nim``.
## Current Linux io-mon evidence for self-hosted compiler executions is
## intentionally not published to the action cache, so these edges are
## marked ``cacheable = false`` and must report ``cdNotCacheable`` rather
## than pretending to cache-hit. This test drives the real
## ``.#test-helpers`` collection and verifies that contract from the build
## report.

import std/[json, os, osproc, sequtils, strtabs, strutils, unittest]
import repro_test_support

const RepoMarker = "repro.nim"

const RequiredHelperNames = [
  "live_endpoint_helper",
  "fake_protocol_daemon_helper",
  "harness_apply_lock_holder",
]

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

proc runWithRunquotaOnPath(cmd, repoRoot: string): tuple[output: string;
    exitCode: int] =
  let runquota = requireRunQuotaCliBin(repoRoot)
  let runquotad = requireRunQuotaDaemonBin(repoRoot)
  let runquotaBin = runquota.parentDir
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let oldPath = env.getOrDefault("PATH")
  env["RUNQUOTA_BIN"] = runquota
  env["RUNQUOTAD_BIN"] = runquotad
  env["PATH"] = runquotaBin & $PathSep & oldPath
  execCmdEx(cmd, env = env, workingDir = repoRoot)

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc reportActions(report: JsonNode): JsonNode =
  result = report{"actions"}
  if result.isNil or result.kind == JNull:
    result = newJArray()

proc runBuildHelpers(reproBin, repoRoot: string):
    tuple[output: string; exitCode: int] =
  let args = @[
    reproBin.quoteShell,
    "build",
    ".#test-helpers",
    "--tool-provisioning=path",
    "--daemon=off",
    "--write-report",
    "--log=actions",
    "--progress=quiet",
  ]
  runWithRunquotaOnPath(args.join(" "), repoRoot)

suite "Bootstrap-And-Self-Build B2: helper build edges":

  test "test helper edges execute as non-cacheable graph actions":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = requireRunQuotaDaemonBin(repoRoot)

    check fileExists(reproBin)
    check fileExists(runquotad)

    if fileExists(reproBin) and fileExists(runquotad):
      let (output, exitCode) = runBuildHelpers(reproBin, repoRoot)
      checkpoint("exit=" & $exitCode)
      if exitCode != 0:
        checkpoint(output)
      check exitCode == 0

      let reportPath = valueAfter(output, "buildReport:")
      check reportPath.len > 0
      check fileExists(reportPath)

      if reportPath.len > 0 and fileExists(reportPath):
        let report = parseFile(reportPath)
        let actions = reportActions(report)
        var helperActions: seq[JsonNode] = @[]
        for action in actions:
          let id = action{"id"}.getStr()
          if id.startsWith(ActionIdPrefix):
            helperActions.add(action)

        checkpoint("found " & $helperActions.len &
          " " & ActionIdPrefix & "* actions in build report")
        check helperActions.len >= RequiredHelperNames.len

        let helperIds = helperActions.mapIt(it{"id"}.getStr())
        for name in RequiredHelperNames:
          check ActionIdPrefix & name in helperIds

        for action in helperActions:
          let id = action{"id"}.getStr()
          let status = action{"status"}.getStr()
          let launched = action{"launched"}.getBool()
          let cache = action{"cacheDecision"}.getStr()
          let reason = action{"reason"}.getStr()
          checkpoint(id & " status=" & status &
            " launched=" & $launched &
            " cacheDecision=" & cache &
            " reason=" & reason)
          check status == "asSucceeded"
          check launched
          check cache == "cdNotCacheable"
          check "exit=0" in reason
