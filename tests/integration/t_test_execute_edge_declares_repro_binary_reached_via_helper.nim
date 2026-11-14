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
## ``overlap``  — force the control query to finish between the anchor's
##                report write and read. Each invocation must read its own
##                closure even under this otherwise timing-dependent overlap.
## ``analysis`` — both directions of the classifier itself, against a
##                synthetic source tree on the real filesystem: calling a
##                helper that resolves the CLI is ``true``; merely
##                IMPORTING the module that defines that helper, without
##                calling it, stays ``false``. ``include`` is followed as
##                pasting: an included fixture's PRIVATE helper is the
##                includer's own, while importing the includer still sees
##                only what it exports.
##
## ``precondition`` — the engine arms run against the REAL workspace, so
##                their answer depends on its siblings as well as on this
##                tree. Cross-Repo-Source-Consumption §5.2 makes the engine
##                refuse a lock-pinned producer whose placed sibling checkout
##                is not at the commit ``repro.lock`` pins, and that refusal
##                says nothing about execute-edge closures. When the engine
##                refuses for exactly that reason, and the sibling it names
##                really is off its pin, each engine arm is SKIPPED with the
##                unmet precondition named — the sibling, its HEAD, the pin
##                and the remedy — rather than reported as closure
##                assertions failing. A skip is not a pass. Any other failure,
##                including the same refusal about a sibling that is in fact
##                at its pin, stays a failure. This arm pins both directions
##                of that classification against real git checkouts.
##
## No mocks in the engine and analysis arms. The engine arms shell out to
## the real ``build/bin/repro`` and read the real build report; the analysis
## arm runs the real analysis module against real files in a temp directory.
##
## The ``precondition`` arm feeds the classifier refusal TEXT it writes
## itself, beside real git checkouts it creates. That is the one synthetic
## input in this file, and it is justified: the real refusal can only be
## produced by a workspace whose sibling has drifted, which a test must not
## arrange by moving a checkout it does not own, and which the engine arms
## then consume for real whenever it occurs. What the arm has to prove is the
## classifier's rule — refused AND really off the pin — so it supplies both
## halves explicitly and checks each one alone keeps the arm red.

import std/[json, os, osproc, sequtils, streams, strtabs, strutils, tempfiles, unittest]
import repro_lock
import repro_test_support
import repro_test_support/reasoned_skip
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

proc dryRunClosure(repoRoot, selector: string;
    beforeRead: proc() {.closure.} = nil):
    tuple[actions: seq[string]; output: string; exitCode: int] =
  ## Ask the engine which actions it would schedule for ``selector``.
  ##
  ## ``--dry-run`` is what keeps this affordable: the engine lowers the
  ## graph and reports every action in the closure without launching any
  ## of them, so the arm costs seconds rather than a test run plus a
  ## compiler invocation. ``--no-runquota`` is safe for the same reason —
  ## nothing is launched, so there is nothing to meter.
  let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  # Cases run concurrently, so every query owns its report until parsing is
  # complete. Another query must neither overwrite nor remove this report.
  let scratch = createTempDir("repro-helper-closure-", "")
  defer: removeDir(scratch)
  let reportPath = scratch / "report.json"
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
  # Force an overlapping query at the report boundary without replacing the
  # real engine or relying on subprocess timing to reproduce interference.
  if beforeRead != nil:
    beforeRead()
  result.actions = @[]
  if fileExists(reportPath):
    let report = parseFile(reportPath)
    let actions = report{"actions"}
    if not actions.isNil and actions.kind == JArray:
      for action in actions:
        result.actions.add(action{"id"}.getStr())

type
  SiblingPinDrift = object
    ## A sibling checkout the consumer lock pins, which is not at its pin.
    name: string      ## the dependency's name in ``repro.lock``.
    checkout: string  ## where the sibling is checked out.
    pinned: string    ## the commit ``repro.lock`` pins.
    head: string      ## the checkout's actual ``HEAD`` commit.

proc gitCommitOf(checkout, rev: string): string =
  ## The commit ``rev`` names in ``checkout``, or "" when it names none.
  ## Repository-selecting variables are dropped so the answer is about the
  ## checkout on disk, as the engine's own check is
  ## (``verifyLockPinnedProducerSource``).
  let gitBin = findExe("git")
  if gitBin.len == 0:
    return ""
  var env = newStringTable()
  for k, v in envPairs():
    if k notin ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_CEILING_DIRECTORIES"]:
      env[k] = v
  try:
    let p = startProcess(gitBin, args = ["-C", checkout, "rev-parse",
        "--verify", "--quiet", "--end-of-options", rev & "^{commit}"],
      env = env, options = {})
    defer: p.close()
    let output = p.outputStream.readAll()
    if p.waitForExit() != 0:
      return ""
    output.strip()
  except OSError:
    ""

proc placedSiblingCheckout(name, consumerRoot: string): string =
  ## Where the engine finds ``name`` checked out beside ``consumerRoot``:
  ## the nearest ancestor's ``<name>`` directory that holds a project file.
  ## Mirrors ``repro_cli_support.findSiblingProjectFile``, which is what
  ## places a lock-pinned producer's source (``producerSourceRoot``); "" when
  ## the engine would fetch the pin instead.
  var dir = consumerRoot
  for _ in 0 ..< 16:
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir:
      break
    let candidate = parent / name
    if fileExists(candidate / "repro.nim") or
        fileExists(candidate / "reprobuild.nim"):
      return candidate
    dir = parent
  ""

proc siblingPinDrift(consumerRoot: string;
    deps: openArray[LockedDep]): seq[SiblingPinDrift] =
  ## Every VCS dependency in ``deps`` that is checked out beside
  ## ``consumerRoot`` at a commit other than the one it pins. Commit identity,
  ## not tree identity, is what the engine compares (§5.2), so a
  ## tree-identical merge on top of the pin is drift too.
  for dep in deps:
    if dep.coordinates.kind != ckVcs or dep.isSelfLockedDep or
        dep.coordinates.revision.len == 0:
      continue
    let checkout = placedSiblingCheckout(dep.name, consumerRoot)
    if checkout.len == 0:
      continue
    let head = gitCommitOf(checkout, "HEAD")
    let pinned = gitCommitOf(checkout, dep.coordinates.revision)
    if head.len == 0 or head != pinned:
      result.add(SiblingPinDrift(name: dep.name, checkout: checkout,
        pinned: dep.coordinates.revision,
        head: (if head.len > 0: head else: "<unresolvable>")))

proc siblingPinDrift(repoRoot: string): seq[SiblingPinDrift] =
  ## ``siblingPinDrift`` against this tree's committed ``repro.lock``.
  siblingPinDrift(repoRoot,
    parseLockedDependencies(readFile(repoRoot / "repro.lock")).deps)

proc unmetSiblingPin(drift: openArray[SiblingPinDrift]; exitCode: int;
    output: string): string =
  ## The unmet precondition behind a failed dry run, or "" when the failure
  ## is not one. BOTH halves are required: the engine refused naming a
  ## producer's source revision, AND that producer's checkout really is off
  ## the pin. A refusal about a sibling that is at its pin is an engine
  ## defect and stays a failure; so does every other non-zero exit.
  if exitCode == 0:
    return ""
  for d in drift:
    if ("cross-repo producer \"" & d.name & "\" source revision mismatch") in
        output:
      return "precondition unmet: workspace sibling " & d.name & " at " &
        d.checkout & " is at " & d.head & ", but repro.lock pins " &
        d.pinned & ", and the engine refuses a lock-pinned producer whose " &
        "checkout is not at its pin (Cross-Repo-Source-Consumption §5.2), " &
        "so no closure can be measured. Check out the pin in the sibling, " &
        "or move the pin with `repro lock update " & d.name & " --to=" &
        d.head & "`."
  ""

proc unmetSiblingPin(drift: openArray[SiblingPinDrift];
    closure: tuple[actions: seq[string]; output: string; exitCode: int]):
    string =
  unmetSiblingPin(drift, closure.exitCode, closure.output)

template skipForUnmetPrecondition(reason: string) =
  ## Skip, naming the unmet precondition on the run's own output as well.
  ## The fork's ``skip(reason)`` records the reason only in the protocol
  ## result document, so a direct run would print a bare ``[SKIPPED]``; the
  ## stock arm of ``reasoned_skip`` already prints it.
  when UnittestSkipTakesReason:
    echo "    [SKIPPED] ", reason
  skip(reason)

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
    #
    # OVER CODE, AND AS A CALL. The two negatives above are computed over the
    # RAW text on purpose — a comment naming `build/bin/repro` reddens them,
    # which is the conservative direction for a `notin`. This one is a
    # positive, so the same raw text is the permissive direction: the anchor
    # explaining in a comment that it reaches the CLI through
    # `prepareMonitorTools` would satisfy the audit for a version that no
    # longer calls it, and the whole point of the anchor is that it CALLS the
    # helper. Blanking literals as well as comments matters here too, because
    # the name is exactly the kind of thing a `checkpoint` string spells out.
    let anchorCode = nimSourceCodeOnly(anchorText)
    check "prepareMonitorTools(" in anchorCode
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
    let unmet = unmetSiblingPin(siblingPinDrift(repoRoot), closure)
    if unmet.len > 0:
      skipForUnmetPrecondition(unmet)
    else:
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
    let unmet = unmetSiblingPin(siblingPinDrift(repoRoot), closure)
    if unmet.len > 0:
      skipForUnmetPrecondition(unmet)
    else:
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

  test "overlap: each dry-run reads its own closure report":
    let repoRoot = findRepoRoot()
    var control: tuple[actions: seq[string]; output: string; exitCode: int]
    var controlRan = false
    let anchor = dryRunClosure(repoRoot, ".#" & AnchorExecuteId,
      beforeRead = proc() =
        control = dryRunClosure(repoRoot, ".#" & ControlExecuteId)
        controlRan = true)

    # Both queries must be measurable; either one refused for a drifted
    # sibling leaves nothing to compare.
    let drift = siblingPinDrift(repoRoot)
    var unmet = unmetSiblingPin(drift, anchor)
    if unmet.len == 0 and controlRan:
      unmet = unmetSiblingPin(drift, control)
    if unmet.len > 0:
      skipForUnmetPrecondition(unmet)
    else:
      checkpoint("anchor exit=" & $anchor.exitCode & " actions=" &
        anchor.actions.join(", "))
      checkpoint("control exit=" & $control.exitCode & " actions=" &
        control.actions.join(", "))
      if anchor.exitCode != 0:
        checkpoint(anchor.output)
      if control.exitCode != 0:
        checkpoint(control.output)
      check controlRan
      check anchor.exitCode == 0
      check control.exitCode == 0
      check AnchorExecuteId in anchor.actions
      check ReproProducerId in anchor.actions
      check ControlExecuteId notin anchor.actions
      check ControlExecuteId in control.actions
      check AnchorExecuteId notin control.actions
      check ReproProducerId notin control.actions

  test "precondition: a drifted sibling is named only when it is the refusal":
    # Real git checkouts on the real filesystem, laid out as a workspace: a
    # consumer, a sibling one commit past its pin (an empty commit, so the
    # tree is identical — the case §5.2 still refuses), a sibling at its pin,
    # and a pinned dependency with no checkout beside the consumer.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the sibling checkouts this arm classifies " &
        "are real git repositories")
    else:
      let root = createTempDir("repro-sibling-pin-", "")
      defer: removeDir(root)
      proc git(dir: string; args: varargs[string]) =
        let cmd = @[gitBin.quoteShell, "-C", dir.quoteShell] &
          @args.mapIt(it.quoteShell)
        let run = execCmdEx(cmd.join(" "))
        doAssert run.exitCode == 0, cmd.join(" ") & "\n" & run.output
      proc makeSibling(name: string): string =
        let dir = root / name
        createDir(dir)
        writeFile(dir / "repro.nim", "# " & name & "\n")
        git(dir, "init", "-q")
        git(dir, "add", "repro.nim")
        git(dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
          "commit", "-q", "-m", "pin")
        gitCommitOf(dir, "HEAD")
      let consumer = root / "consumer"
      createDir(consumer)
      writeFile(consumer / "repro.nim", "# consumer\n")
      let driftedPin = makeSibling("drifted")
      git(root / "drifted", "-c", "user.name=t",
        "-c", "user.email=t@example.invalid",
        "commit", "-q", "--allow-empty", "-m", "tree-identical")
      let driftedHead = gitCommitOf(root / "drifted", "HEAD")
      let onPin = makeSibling("onpin")
      proc vcsDep(name, rev: string): LockedDep =
        LockedDep(name: name, path: "../" & name,
          coordinates: Coordinates(kind: ckVcs,
            url: "https://example.invalid/" & name, revision: rev))
      let deps = @[vcsDep("drifted", driftedPin), vcsDep("onpin", onPin),
        vcsDep("absent", driftedPin)]

      # Only the checkout that is off its pin is drift; one with no checkout
      # is the engine's to fetch, and is not.
      let drift = siblingPinDrift(consumer, deps)
      checkpoint("drift=" & $drift)
      check drift.len == 1
      check drift.len == 1 and drift[0].name == "drifted" and
        drift[0].head == driftedHead and drift[0].pinned == driftedPin and
        drift[0].checkout == root / "drifted"
      check driftedHead != driftedPin

      proc refusal(name: string): string =
        "repro build: error: cross-repo producer \"" & name &
          "\" source revision mismatch at " & (root / name) & ": ..."

      # The engine refused for the drifted sibling: named, with the remedy.
      let named = unmetSiblingPin(drift, 1, refusal("drifted"))
      checkpoint("named=" & named)
      check named.startsWith("precondition unmet: workspace sibling drifted")
      check driftedHead in named and driftedPin in named
      check "repro lock update drifted --to=" & driftedHead in named

      # Each half alone stays a failure: a run that exited 0, a refusal
      # about a sibling that is at its pin, and any unrelated failure.
      check unmetSiblingPin(drift, 0, refusal("drifted")) == ""
      check unmetSiblingPin(drift, 1, refusal("onpin")) == ""
      check unmetSiblingPin(drift, 1, "Error: unhandled exception") == ""
      check unmetSiblingPin(@[], 1, refusal("drifted")) == ""

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

  test "analysis: an included file's private helper is the includer's own":
    # ``include`` pastes a file into the including module, so a symbol the
    # included file does not export is still visible to the includer. A
    # fixture that keeps its CLI-resolving helper private must not hide
    # the binary from the tests that include it and call that helper.
    let root = createTempDir("repro-reachability-include-", "")
    defer: removeDir(root)

    createDir(root / "tests" / "integration")
    writeFile(root / "tests" / "integration" / "cli_fixture.nim", """
import std/os

proc fixtureReproPath(repoRoot: string): string =
  repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc setupCliFixture(repoRoot: string): string =
  fixtureReproPath(repoRoot)

proc fixtureArithmetic(a, b: int): int =
  a + b
""")
    # A fixture that only re-includes the first: include is transitive.
    writeFile(root / "tests" / "integration" / "outer_fixture.nim", """
include cli_fixture

proc setupOuterFixture(repoRoot: string): string =
  setupCliFixture(repoRoot)
""")
    let caller = "tests/integration/t_includer_calls_private_helper.nim"
    writeFile(root / caller, """
include cli_fixture

discard setupCliFixture("/somewhere")
""")

    let nested = "tests/integration/t_includer_calls_through_nested_include.nim"
    writeFile(root / nested, """
include outer_fixture

discard setupOuterFixture("/somewhere")
""")

    let bystander = "tests/integration/t_includer_calls_nothing_tainted.nim"
    writeFile(root / bystander, """
include cli_fixture

discard fixtureArithmetic(1, 2)
""")

    let importer = "tests/integration/t_imports_an_includer.nim"
    writeFile(root / importer, """
import outer_fixture

when false:
  discard setupOuterFixture("/somewhere")
""")

    let reach = analyze(root,
      @[caller, nested, bystander, importer])

    checkpoint("caller reached through: " &
      reach.taintedSymbolsFor(caller).join(", "))
    check reach.needsReproBinary(caller)
    check "setupCliFixture" in reach.taintedSymbolsFor(caller)

    checkpoint("nested reached through: " &
      reach.taintedSymbolsFor(nested).join(", "))
    check reach.needsReproBinary(nested)
    check "setupOuterFixture" in reach.taintedSymbolsFor(nested)

    # Including the fixture is not calling it: the action cache stays
    # selective for includers that use only its untainted helpers.
    checkpoint("bystander reached through: " &
      reach.taintedSymbolsFor(bystander).join(", "))
    check not reach.needsReproBinary(bystander)

    # Private symbols of an included file are the includer's own, so they
    # stay private to anything that IMPORTS the includer: naming one there
    # does not resolve to it.
    checkpoint("importer reached through: " &
      reach.taintedSymbolsFor(importer).join(", "))
    check not reach.needsReproBinary(importer)
