## Bootstrap-And-Self-Build B3: ``repro test <name>`` (or equivalently
## ``repro build .#test#<name>``) schedules + executes the test's
## execute edge through the engine, exit code is 0 on success, the
## build report records the execute action.
##
## Strategy
## --------
## Pick a small, fast DSL test as the target (per the B3 plan: "target
## ONE specific test, not the whole collection" — 30+ min cold cost is
## not acceptable). The fixture is
## ``t_dsl_outputs_statement_basic_accepted`` — a parse-only DSL test
## with no external dependencies and a quick wall time.
##
## Two halves:
##
##   1. STRUCTURAL — verify (by source-text inspection of
##      ``repro_tests.nim``) that the targeted ``TestSpec`` is present
##      in the data table and that its ``requiresReproBinary`` flag is
##      correctly set (false for DSL parse tests; true for e2e tests
##      that spawn ``./build/bin/repro``). This subtest passes today
##      without engine cooperation; it is the strong structural
##      counterpart to the engine arm below.
##
##   2. ENGINE — drive ``./build/bin/repro build .#test#<name>``
##      against the test's execute edge, and require the execute action
##      to appear in the build report.
##
## No failure classifier. This case used to run its non-zero exit past a
## ``looksLike…(output)`` predicate that matched the engine's own diagnostic
## against a needle list and reclassified the failure as a skip on a match.
## The list covered ordinary engine failures — tool resolution, provisioning,
## the CLI usage dump — so any NEW failure phrased in those terms disappeared
## silently, which is a way of manufacturing green rather than a record of an
## environment limitation. ``runquota`` is a declared workspace dependency;
## resolve its daemon through the workspace-aware fixture helper so linked
## reprobuild worktrees execute this arm. A missing daemon is a hard fixture
## error. ``./build/bin/repro`` remains a build-order gate checked before the
## engine work starts.
##
## The report check lost a classifier too. An absent execute action used to
## skip — with a long note about the bare-name selector routing to the BUILD
## edge — which meant the one outcome this case exists to rule out was also
## the one outcome it tolerated. It now fails, and prints which selector
## resolved and whether it was the bare-name form.
##
## Invocation
## ----------
## ``./build/bin/repro test t_dsl_outputs_statement_basic_accepted
## --daemon=off --tool-provisioning=path``
##
## ``repro test`` is the Spec-Implementation M0 verb alias for
## ``repro build test`` (with CI-sharding shim semantics on top).
## When the test-name resolution path lands the alias on the
## ``reprobuild.test_execute.<stem>`` action it built + ran in the
## current process tree.

import std/[json, os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support

const RepoMarker = "repro.nim"
const TargetTest = "t_dsl_outputs_statement_basic_accepted"

# A second known-e2e test used for the structural cross check below.
# It SHOULD carry ``requiresReproBinary: true`` because its source
# spawns ``./build/bin/repro``.
const E2eCrossCheckTest =
  "libs/repro_core/tests/t_show_conventions_cli.nim"

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
  let runquotaBin = requireRunQuotaDaemonBin(repoRoot).parentDir
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

proc specSlice(reproTestsText, source: string): string =
  ## Return up to ~400 chars starting at the ``source: "..."`` marker
  ## for ``source`` (one TestSpec entry). Empty string if the marker
  ## isn't found.
  let marker = "source: \"" & source & "\""
  let pos = reproTestsText.find(marker)
  if pos < 0:
    return ""
  let limit = min(reproTestsText.len, pos + 400)
  return reproTestsText[pos ..< limit]

suite "Bootstrap-And-Self-Build B3: repro test runs through engine":

  test "structural: targeted test is in repro_tests.nim with correct requiresReproBinary":
    ## Approach A: verify (without engine cooperation) that the
    ## targeted execute-edge fixture is correctly wired in
    ## ``repro_tests.nim``. Together with the engine arm below this
    ## confirms the EXECUTE-edge plumbing is in place even when the
    ## engine cannot yet execute it.
    let repoRoot = findRepoRoot()
    let reproTests = repoRoot / "repro_tests.nim"
    check fileExists(reproTests)

    let reproTestsText = readFile(reproTests)

    # The targeted test must be present in the data table.
    let dslSpec = specSlice(reproTestsText,
      "libs/repro_project_dsl/tests/" & TargetTest & ".nim")
    if dslSpec.len == 0:
      # Fallback path — the test may live in tests/ instead.
      let altSpec = specSlice(reproTestsText,
        "tests/" & TargetTest & ".nim")
      check altSpec.len > 0
      # DSL parse test does NOT spawn ``./build/bin/repro``.
      check "requiresReproBinary: false" in altSpec
    else:
      # DSL parse test does NOT spawn ``./build/bin/repro``.
      check "requiresReproBinary: false" in dslSpec

    # Cross-check: an e2e test that DOES spawn ``./build/bin/repro``
    # must carry the flag. (The generator detects this by greping for
    # the literal ``build/bin/repro`` in the source.)
    let e2eSpec = specSlice(reproTestsText, E2eCrossCheckTest)
    check e2eSpec.len > 0
    check "requiresReproBinary: true" in e2eSpec

    checkpoint("structural cross-check: OK — DSL parse test flag=false," &
      " e2e CLI test flag=true")

  test "engine: small test runs end-to-end through repro build .#test#<name>":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)

    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    else:
      discard requireRunQuotaDaemonBin(repoRoot)
      # Prefer the fragment selector form ``.#test#<name>`` (Named-
      # Targets M3 nested-fragment shape: the outer ``test`` selects
      # the collection, the inner ``<name>`` resolves a single member).
      # If the engine's collection-member resolver doesn't recognise
      # the form, fall back to the bare target name which the implicit-
      # target-name pathway should accept.
      let executeStem = TargetTest
      var attempts: seq[seq[string]] = @[]
      attempts.add(@[
        reproBin.quoteShell, "build", ".#test#" & executeStem,
        "--tool-provisioning=path", "--daemon=off",
        "--write-report", "--log=actions", "--progress=quiet"])
      attempts.add(@[
        reproBin.quoteShell, "build", executeStem,
        "--tool-provisioning=path", "--daemon=off",
        "--write-report", "--log=actions", "--progress=quiet"])
      attempts.add(@[
        reproBin.quoteShell, "build",
        "reprobuild.test_execute." & executeStem,
        "--tool-provisioning=path", "--daemon=off",
        "--write-report", "--log=actions", "--progress=quiet"])

      var lastOutput = ""
      var lastExit = -1
      var resolved = false
      var resolvedSelector = ""
      var triedSelectors: seq[string] = @[]
      for args in attempts:
        triedSelectors.add(args[2])
        let cmd = args.join(" ")
        checkpoint("running: " & cmd)
        let (output, exitCode) = runWithRunquotaOnPath(cmd, repoRoot)
        checkpoint("exit=" & $exitCode)
        lastOutput = output
        lastExit = exitCode
        if exitCode == 0:
          resolved = true
          resolvedSelector = args[2]
          break
        # Every selector form is tried. This used to stop early unless
        # the diagnostic text matched one of three known strings, which
        # made "which selectors were tried" depend on how the engine
        # happened to word a failure.
        continue

      if not resolved:
        checkpoint(lastOutput)
        checkpoint("no selector resolved: " & triedSelectors.join(", "))
        check lastExit == 0
      else:
        # A selector resolved with exit 0, but exit 0 alone does not say
        # the EXECUTE edge ran: the bare-name selector (the engine's
        # implicit-target-name path) routes to the BUILD edge, so the
        # binary compiles and the run exits 0 with no execute action at
        # all. That is why the build report is read below and the execute
        # action required by id — and `routedViaBuildEdge` is carried only
        # so the failure can SAY which selector was taken, never to excuse
        # the absence.
        let routedViaBuildEdge = (resolvedSelector == executeStem)
        let executeActionId = "reprobuild.test_execute." & executeStem
        let reportPath = valueAfter(lastOutput, "buildReport:")
        var executeAction: JsonNode = nil
        if reportPath.len > 0 and fileExists(reportPath):
          let report = parseFile(reportPath)
          let actions = reportActions(report)
          for action in actions:
            if action{"id"}.getStr() == executeActionId:
              executeAction = action
              break

        if executeAction.isNil:
          # This case's whole subject is that the EXECUTE edge runs
          # through the engine. Without the execute action in the report
          # there is nothing to assert, so an absent action fails —
          # whichever selector resolved, and whatever the reason.
          checkpoint("no " & executeActionId & " action in the build " &
            "report; the execute edge did not run through the engine")
          checkpoint("resolved selector: " & resolvedSelector)
          checkpoint("routed via the bare-name (build) selector: " &
            $routedViaBuildEdge)
          check not executeAction.isNil
        else:
          let status = executeAction{"status"}.getStr()
          let cache = executeAction{"cacheDecision"}.getStr()
          checkpoint(executeActionId & " status=" & status &
            " cacheDecision=" & cache)
          # On a cold run we expect the execute edge to run (NOT
          # cache-hit). On a warm run it may legitimately cache-hit —
          # both shapes are valid evidence that the engine drove the
          # execute edge through its scheduler.
          check status.len > 0

  test "alias forwards ordinary build flags to the test collection":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)

    if not fileExists(reproBin):
      checkpoint("skipped - " & reproBin &
        " is missing; run `repro build apps` first")
      skip()
    else:
      let scratch = createTempDir("repro-test-build-flags-", "")
      defer: removeDir(scratch)
      let reportPath = scratch / "report.json"
      let diagnosticsPath = scratch / "diagnostics"
      let selector = ".#test#" & TargetTest
      let args = @[
        reproBin.quoteShell,
        "test",
        selector,
        "--no-certify",
        "--tool-provisioning=path",
        "--daemon=off",
        "--no-runquota",
        "--progress=quiet",
        "--log=summary",
        "--measure=all",
        "--write-report=" & reportPath.quoteShell,
        "--write-diagnostics=" & diagnosticsPath.quoteShell,
      ]
      let (output, exitCode) = runWithRunquotaOnPath(args.join(" "), repoRoot)

      if exitCode != 0:
        checkpoint(output)
      check exitCode == 0
      check "unsupported repro test flag" notin output
      check fileExists(reportPath)
