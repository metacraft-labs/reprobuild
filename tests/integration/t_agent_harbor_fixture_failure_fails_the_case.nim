## When the Agent Harbor end-to-end gates cannot install their fixture, the
## suite runner still gets a catalog from every gate binary, and the failure
## arrives as the FAIL of a case, with a result document that says why.
##
## THE DEFECT THIS GUARDS. The four ``tests/e2e/agent-harbor/`` gates share a
## fixture (``agent_harbor_fixture``) whose acquisition is a full
## ``repro build`` of a C package, plus ``repro home apply`` for three of
## them. They acquired it in the ``suite`` body, outside any case, and every
## process the runner starts executes that code (Test-Suite-Architecture-
## Guidelines, "Fixture Lifetime Under One Process Per Case"):
##
##   * the ``--list-json`` probe performed the whole install, minutes on a
##     loaded host against the runner's 300 s probe timeout;
##   * an install that failed raised out of module scope: the probe exited 1
##     and a ``--run`` process exited 1 having written NO result document,
##     so the runner reported each binary as a whole-binary failure with
##     nothing naming a case or a cause (reprobuild-pm issue
##     2026-11-05-agent-harbor-e2e-binaries-write-no-result-document-in-run-39);
##   * the fixture's ``agent-<name>-XXXX`` scratch tree was left in
##     ``TMPDIR`` by every such process.
##
## HOW. Each gate binary is driven through ``repro_test_support/per_case_runs``
## the way the runner drives it, with a ``cc`` that always fails first on
## ``PATH`` and ``TMPDIR`` / ``HOME`` pointed at a directory of this case's
## own. It asserts that:
##
##   1. the probe exits 0, lists the gate's cases, and leaves ``TMPDIR``
##      empty: it acquired nothing;
##   2. the first listed case (every case of these gates needs the fixture,
##      so any one of them exercises the acquisition) writes a result
##      document with status ``FAIL`` that carries the fixture's own error,
##      ``installing the fixture failed``, and the injected ``cc``'s message,
##      so the failure is the one this test caused;
##   3. once every process has exited, ``TMPDIR`` holds nothing but the
##      engine's shared, content-keyed compiler caches (``repro-nimcache-*``,
##      which ``repro build`` keeps there by design, as the per-case fixture
##      gate's header explains): in particular no fixture scratch tree.
##
## Only the first case runs: each failing install still costs a provider
## compile and a graph build, about a minute on a loaded host, and the other
## cases would check the same acquisition path again.
##
## NO MOCKS, ONE FAULT INJECTION. The subjects are the real gate binaries,
## running the real ``repro build`` against the real filesystem. The ``cc``
## put first on ``PATH`` is a two-line shell script that prints a message and
## exits 1. It is not a stand-in for a compiler whose behaviour the test
## relies on; it is the fault being injected, the simplest one that makes
## the fixture's install fail deterministically inside the engine (the
## fixture's recipe resolves ``cc`` from ``PATH``,
## ``defaultToolProvisioning "path"``, and ``fixtureRunnable`` asks only
## whether a ``cc`` exists). Making a real compiler fail on demand would need
## a broken source in the fixture, which this test does not own.
##
## SUBJECTS are the four gates (``AgentHarborFixtureFailureGateSubjects`` in
## ``repro.nim``): their binaries are inputs of this file's execute edge, so
## a change to any of them re-runs this test; the last case checks that the
## two lists agree.
##
## Skip rule: the gates run their cases only on Linux with
## ``./build/bin/repro`` built (``agent_harbor_fixture.fixtureRunnable``);
## elsewhere they register no case, and this test skips with that reason.

import std/[json, os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_test_support/per_case_runs

const
  Subjects = [
    "tests/e2e/agent-harbor/t_e2e_agent_harbor_change_to_generation_and_remix.nim",
    "tests/e2e/agent-harbor/t_e2e_agent_harbor_combines_and_augments_remixes.nim",
    "tests/e2e/agent-harbor/t_e2e_agent_harbor_modifies_installed_source_package.nim",
    "tests/e2e/agent-harbor/t_e2e_agent_harbor_preview_accept_reject.nim",
  ]
    ## Repo-relative sources; each one's binary is the graph-built
    ## ``build/test-bin/<stem>``.

  FixtureError = "installing the fixture failed"
    ## What ``agent_harbor_fixture.newFixture`` raises when the install fails.

  InjectedFault = "cc: refused by the fault injection"
    ## What the injected ``cc`` prints. Required in the result document, so
    ## an install that failed for some other reason (an unreachable
    ## ``runquotad``, a missing tool) cannot pass for the fault this test
    ## injects.

  FailingCc = "#!/bin/sh\necho \"" & InjectedFault & "\" >&2\nexit 1\n"

  SharedEngineCachePrefix = "repro-nimcache-"
    ## The engine's compiler caches under ``TMPDIR``: shared between builds
    ## and content-keyed by design, so not a fixture this test can blame.

proc binaryOf(source: string): string =
  graphArtifactPath("build/test-bin" /
    source.extractFilename.changeFileExt("").addFileExt(ExeExt))

proc gatesRunHere(): bool =
  ## The half of ``fixtureRunnable`` this test does not supply itself (it
  ## supplies ``cc``).
  when defined(linux):
    fileExists(graphArtifactPath("build/bin/repro"))
  else:
    false

proc entriesUnder(dir: string): seq[string] =
  if not dirExists(dir):
    return
  for _, path in walkDir(dir):
    result.add(path.extractFilename)

proc tail(text: string; n: int): string =
  let t = text.strip()
  if t.len <= n: t else: "..." & t[^n .. ^1]

template probeAndRunFirstCase(source: string) =
  ## Steps 1 to 3 of the header for ``source``'s gate binary.
  let binary = requireBinary(binaryOf(source),
    "the test-builds edge for " & source)
  let root = createTempDir("repro-ah-fixture-failure-", "")
  defer:
    # A fixture tree a subject leaked may hold published, read-only store
    # prefixes.
    discard execCmd("chmod -R u+w " & quoteShell(root))
    removeDirEventually(root)
  let tmpRoot = root / "tmp"
  let homeRoot = root / "home"
  let injected = root / "fault"
  let resultDir = root / "results"       # ours, never inspected for leftovers
  for dir in [tmpRoot, homeRoot, injected]:
    createDir(dir)
  writeFile(injected / "cc", FailingCc)
  setFilePermissions(injected / "cc", {fpUserRead, fpUserWrite, fpUserExec})
  let env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  for k in ["TMPDIR", "TMP", "TEMP"]:
    env[k] = tmpRoot
  env["HOME"] = homeRoot
  env["PATH"] = injected & PathSep & getEnv("PATH")

  # 1. The probe alone.
  var probe: seq[CaseProcess]
  try:
    probe = runEveryCaseInItsOwnProcess(binary, env, resultDir / "probe",
                                        maxCases = 0)
  except OSError as err:
    # The defect: the probe performed the install, which raised out of
    # module scope.
    checkpoint("the --list-json probe failed: " & tail(err.msg, 1500))
    fail()
  if probe.len == 1:
    let names = catalogCaseNames(probe[0].output)
    checkpoint("probe catalog: " & $names)
    check entriesUnder(tmpRoot).len == 0
    if names.len == 0:
      skip(source & " registers no case on this host (its fixtureRunnable " &
        "is false)")
    else:
      # 2. The first case, in a process of its own.
      let runs = runEveryCaseInItsOwnProcess(binary, env, resultDir / "cases",
                                             maxCases = 1)
      check runs.len == 2
      if runs.len == 2:
        let run = runs[1]
        checkpoint(run.name & " exited " & $run.exitCode & ": " &
          tail(run.output & "\n" & run.errorOutput, 1500))
        let document = resultDir / "cases" / "case-0.json"
        check fileExists(document)
        if fileExists(document):
          let doc = parseJson(readFile(document))
          check doc{"status"}.getStr() == "FAIL"
          check FixtureError in $doc
          check InjectedFault in $doc
      # 3. Every process has exited: only the engine's shared caches remain.
      for leftover in entriesUnder(tmpRoot):
        if not leftover.startsWith(SharedEngineCachePrefix):
          checkpoint("left in the redirected TMPDIR: " & leftover)
          fail()

template checkSubject(source: string) =
  ## The body of every subject case. A template so ``skip``, ``check`` and
  ## ``fail`` act on the case that expands it.
  doAssert source in Subjects, source & " is not in Subjects"
  if not gatesRunHere():
    skip("the Agent Harbor gates run their cases only on Linux with " &
      graphArtifactPath("build/bin/repro") & " built")
  else:
    probeAndRunFirstCase(source)

suite "an Agent Harbor gate whose fixture cannot install fails a case":
  test "t_e2e_agent_harbor_change_to_generation_and_remix":
    checkSubject(
      "tests/e2e/agent-harbor/t_e2e_agent_harbor_change_to_generation_and_remix.nim")
  test "t_e2e_agent_harbor_combines_and_augments_remixes":
    checkSubject(
      "tests/e2e/agent-harbor/t_e2e_agent_harbor_combines_and_augments_remixes.nim")
  test "t_e2e_agent_harbor_modifies_installed_source_package":
    checkSubject(
      "tests/e2e/agent-harbor/t_e2e_agent_harbor_modifies_installed_source_package.nim")
  test "t_e2e_agent_harbor_preview_accept_reject":
    checkSubject(
      "tests/e2e/agent-harbor/t_e2e_agent_harbor_preview_accept_reject.nim")

suite "the subject list":
  test "every subject has a case, and every case a subject":
    let own = readFile(currentSourcePath()).multiReplace(("\n", ""), (" ", ""))
    for s in Subjects:
      check ("checkSubject(\"" & s & "\")") in own

  test "every subject is an input of this test's execute edge":
    # Listed twice, here and in ``repro.nim``, because a build-edge id is
    # content-derived and only ``repro.nim`` can collect it. A subject missing
    # THERE runs against whatever binary is on disk.
    let project = nimSourceCommentsBlanked(
      readFile(ReprobuildRepoRoot / "repro.nim"))
    let at = project.find("AgentHarborFixtureFailureGateSubjects* =")
    check at >= 0
    let tail = project[max(at, 0) .. ^1]
    let listEnd = tail.find("]")
    let declared = if listEnd > 0: tail[0 .. listEnd] else: ""
    for subject in Subjects:
      if ("\"" & subject & "\"") notin declared:
        echo subject, " is not in repro.nim's AgentHarborFixtureFailureGateSubjects"
      check ("\"" & subject & "\"") in declared
