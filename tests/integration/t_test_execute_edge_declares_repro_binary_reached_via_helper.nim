## A test that reaches ``build/bin/repro`` only through a SHARED HELPER
## must still get the binary declared on its EXECUTE edge.
##
## The hole this gate closes
## -------------------------
## ``scripts/generate_test_edges.nim`` decided ``requiresReproBinary`` by
## reading the test's own source and looking for the literal
## ``build/bin/repro``. That scan sees exactly one file. Roughly thirty
## tests in this repository reach the CLI through
## ``repro_test_support.prepareMonitorTools`` — which resolves the binary
## itself — and therefore contain no such literal. They were classified
## ``false``, so ``repro.nim`` passed an empty ``requiredBinaries`` to
## ``edge.testBinary.run(...)`` and the execute edge never named the CLI
## as an input.
##
## An execute edge that does not declare ``build/bin/repro`` cannot be
## invalidated by a change to ``build/bin/repro``. Two consequences, and
## the difference between them is worth stating precisely because only
## the first is observable on this branch today:
##
##   * OBSERVABLE NOW: the binary's producer edge
##     (``reprobuild.apps.repro``) is not in the execute edge's closure,
##     so ``repro build .#reprobuild.test_execute.<stem>`` does not build
##     the CLI and the test runs against whatever stale copy happens to
##     be on disk — or fails on a missing fixture.
##   * LATENT: once test execute edges are served from the content-keyed
##     action cache, an edge whose fingerprint does not cover the CLI is
##     served as up to date after the CLI is rebuilt. A real change to
##     ``repro`` then produces a green test that never ran against it.
##     Under-declaration is a stale-serve hole, and it gets strictly more
##     dangerous as execute-edge caching starts working.
##
## What each arm measures
## ----------------------
## ``anchor``   — the chosen test genuinely cannot be classified by any
##                single-file scan: its own source names neither the
##                joined literal nor the ``"build" / "bin"`` component
##                form, yet the helper it calls really does resolve the
##                CLI (checked by CALLING the helper's path resolver, not
##                by reading it).
## ``engine``   — the behavioural gate. The engine's own dry-run closure
##                for the anchor's execute edge must contain the action
##                that produces ``build/bin/repro``. This is the property
##                that makes a rebuild of the CLI reach the test.
## ``control``  — the same query for a pure-unit test must NOT contain
##                it, so the gate cannot be satisfied by declaring the
##                binary on every edge (which would pass this file and
##                destroy the action cache's selectivity).
## ``analysis`` — both directions of the classifier itself, against a
##                synthetic source tree on the real filesystem: calling a
##                helper that resolves the CLI is ``true``; merely
##                IMPORTING the module that defines that helper, without
##                calling it, stays ``false``.
##
## No mocks. The engine arms shell out to the real ``build/bin/repro``
## and read the real build report; the analysis arm runs the real
## analysis module against real files in a temp directory.

import std/[json, os, osproc, strtabs, strutils, tempfiles, unittest]
import repro_test_support
import "../../scripts/repro_binary_reachability"

const RepoMarker = "repro.nim"

const AnchorSource =
  "tests/integration/t_monitor_fault_fails_the_action_not_the_daemon.nim"
const AnchorStem = "t_monitor_fault_fails_the_action_not_the_daemon"
const AnchorExecuteId = "reprobuild.test_execute." & AnchorStem

## A pure-unit test: no subprocess, no CLI. Its execute edge must stay
## free of the ``build/bin/repro`` input.
const ControlStem = "t_dsl_outputs_statement_basic_accepted"
const ControlExecuteId = "reprobuild.test_execute." & ControlStem

const ReproProducerId = "reprobuild.apps.repro"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc singleFileScanSaysYes(source: string): bool =
  ## The exact per-file substring test the generator used before this
  ## gate existed, reproduced here so the anchor's honesty is checked
  ## against the rule it has to defeat rather than against a paraphrase.
  ("build/bin/repro" in source) or
    ("build\\bin\\repro" in source) or
    ("reproBin" in source and (
      "execCmdEx" in source or
      "runShell" in source or
      "runWithRunquotaOnPath" in source))

proc dryRunClosure(repoRoot, selector: string):
    tuple[actions: seq[string]; output: string; exitCode: int] =
  ## Ask the engine which actions it would schedule for ``selector``.
  ##
  ## ``--dry-run`` is what keeps this affordable: the engine lowers the
  ## graph and reports every action in the closure without launching any
  ## of them, so the arm costs seconds rather than a test run plus a
  ## compiler invocation. ``--no-runquota`` is safe for the same reason —
  ## nothing is launched, so there is nothing to meter.
  let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  let reportPath = repoRoot / ".repro" / "build" / "repro" /
    "dry-run-closure-report.json"
  discard tryRemoveFile(reportPath)
  let args = @[
    reproBin.quoteShell,
    "build",
    selector,
    "--dry-run",
    "--no-runquota",
    "--tool-provisioning=path",
    "--daemon=off",
    "--progress=quiet",
    "--log=actions",
    "--write-report=" & reportPath.quoteShell,
  ]
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let run = execCmdEx(args.join(" "), env = env, workingDir = repoRoot)
  result.output = run.output
  result.exitCode = run.exitCode
  result.actions = @[]
  if fileExists(reportPath):
    let report = parseFile(reportPath)
    let actions = report{"actions"}
    if not actions.isNil and actions.kind == JArray:
      for action in actions:
        result.actions.add(action{"id"}.getStr())

suite "test execute edges follow helpers to the repro binary":

  test "anchor: the anchor reaches the CLI only through a helper":
    let repoRoot = findRepoRoot()
    let anchorPath = repoRoot / AnchorSource
    check fileExists(anchorPath)
    let anchorText = readFile(anchorPath)

    # No single-file scan can classify this test correctly: it names
    # neither spelling of the binary's path.
    checkpoint("single-file scan on " & AnchorSource & " => " &
      $singleFileScanSaysYes(anchorText))
    check not singleFileScanSaysYes(anchorText)
    check "build/bin/repro" notin anchorText
    check "\"build\" / \"bin\"" notin anchorText

    # It does call the shared helper, and that helper really resolves the
    # CLI — established by CALLING the helper the anchor calls and
    # inspecting what it hands back, not by reading its source.
    check "prepareMonitorTools" in anchorText
    let scratch = createTempDir("repro-helper-probe-", "")
    defer: removeDir(scratch)
    let tools = prepareMonitorTools(repoRoot, scratch, "gate")
    checkpoint("prepareMonitorTools.monitorCliPath => " & tools.monitorCliPath)
    check tools.monitorCliPath ==
      repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    check fileExists(tools.monitorCliPath)

  test "engine: the anchor's execute-edge closure builds build/bin/repro":
    let repoRoot = findRepoRoot()
    check fileExists(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt))

    let closure = dryRunClosure(repoRoot, ".#" & AnchorExecuteId)
    checkpoint("exit=" & $closure.exitCode)
    checkpoint("actions=" & closure.actions.join(", "))
    if closure.exitCode != 0:
      checkpoint(closure.output)
    check closure.exitCode == 0
    check AnchorExecuteId in closure.actions

    # THE GATE. Absent this action, a rebuild of the CLI cannot reach
    # this test: the edge does not depend on the binary it executes.
    check ReproProducerId in closure.actions

  test "control: a pure-unit execute edge does not pull in the CLI":
    let repoRoot = findRepoRoot()
    let closure = dryRunClosure(repoRoot, ".#" & ControlExecuteId)
    checkpoint("exit=" & $closure.exitCode)
    checkpoint("actions=" & closure.actions.join(", "))
    if closure.exitCode != 0:
      checkpoint(closure.output)
    check closure.exitCode == 0
    check ControlExecuteId in closure.actions
    # Declaring the binary on every edge would satisfy the arm above and
    # destroy the action cache's selectivity. It must not be declared
    # here.
    check ReproProducerId notin closure.actions

  test "analysis: calling a helper taints, importing it alone does not":
    # A synthetic source tree on the real filesystem, laid out the way
    # this repo is: a library under ``libs/<name>/src`` reachable by bare
    # module name, and tests under ``tests/integration``.
    let root = createTempDir("repro-reachability-", "")
    defer: removeDir(root)

    createDir(root / "libs" / "fixture_support" / "src")
    createDir(root / "tests" / "integration")
    writeFile(root / "libs" / "fixture_support" / "src" / "fixture_support.nim",
      """
import std/os

const FixtureReproRelPath* = "build/bin/repro"

proc fixtureReproPath*(repoRoot: string): string =
  repoRoot / FixtureReproRelPath

proc runTheCli*(repoRoot: string): string =
  fixtureReproPath(repoRoot)

proc unrelatedHelper*(a, b: int): int =
  a + b
""")

    let caller = "tests/integration/t_fixture_calls_helper.nim"
    writeFile(root / caller, """
import fixture_support

let root = "/somewhere"
discard runTheCli(root)
""")

    let importer = "tests/integration/t_fixture_imports_only.nim"
    writeFile(root / importer, """
import fixture_support

discard unrelatedHelper(1, 2)
""")

    let mentioner = "tests/integration/t_fixture_mentions_in_prose.nim"
    writeFile(root / mentioner, """
## This test discusses ``runTheCli`` and even names build/bin/repro in
## prose, but never calls anything.
import fixture_support

discard unrelatedHelper(3, 4)
""")

    let reach = analyze(root, @[caller, importer, mentioner])

    # Reached through two hops (``runTheCli`` -> ``fixtureReproPath`` ->
    # the const) with no literal anywhere in the test itself.
    checkpoint("caller reached through: " &
      reach.taintedSymbolsFor(caller).join(", "))
    check reach.needsReproBinary(caller)
    check "runTheCli" in reach.taintedSymbolsFor(caller)

    # Importing the module is NOT enough. This is the direction that
    # keeps the action cache selective: 81 tests in this repository
    # import ``repro_test_support`` without calling anything that
    # resolves the CLI, and they must stay undeclared.
    checkpoint("importer reached through: " &
      reach.taintedSymbolsFor(importer).join(", "))
    check not reach.needsReproBinary(importer)

    # Naming a helper in a comment is not calling it.
    checkpoint("mentioner reached through: " &
      reach.taintedSymbolsFor(mentioner).join(", "))
    check not reach.needsReproBinary(mentioner)
