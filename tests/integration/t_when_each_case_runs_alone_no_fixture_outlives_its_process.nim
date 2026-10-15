## When every case runs in a process of its own — the way the suite runner
## runs them — no fixture a test file acquires outlives the process that
## acquired it.
##
## THE DEFECT THIS GUARDS. The runner (``tools/test-runner``) probes each test
## binary with ``--list-json`` and then runs ``--run "<suite>::<test>"`` once
## per case, each in a fresh process. Several files acquired fixtures at module
## scope and released them only in a final "teardown" CASE. That case ran in
## one process and released what that one process had acquired; every other
## case process and the probe left theirs behind for good. Measured at
## reprobuild 6aa91f75: one runner-alone run of ``t_fs_facts_conformance``
## (36 cases) left 144 ``repro-f2-<pid>-vol<N>`` directories across ``$TMPDIR``,
## ``/var/tmp``, ``/dev/shm`` and ``$HOME``, and a dev host had accumulated
## dozens of ``runquotad`` daemons re-parented to init from the launch-path
## gates. The file-level fix is ``repro_test_support/process_fixtures``:
## acquire lazily, release at process exit. This file checks the outcome the
## way the runner would produce it, which no case inside the subject can do —
## a case sees only its own process.
##
## HOW. Each subject binary is driven through
## ``repro_test_support/per_case_runs`` (probe + one process per case) with
## ``TMPDIR`` and ``HOME`` pointed at a directory created for that subject,
## so that whatever is found there afterwards belongs to that subject and not
## to anything else on a shared host. After every process has exited:
##
##   1. the redirected ``TMPDIR`` and ``HOME`` are EMPTY;
##   2. no entry that was not there before has appeared in the parents a
##      subject may use regardless of ``TMPDIR`` (``/tmp``, ``/var/tmp``,
##      ``/dev/shm``, the subject's own source directory) with a NAME that
##      carries the pid of one of the subject's processes — the
##      ``repro-f2-<pid>-vol<N>`` shape;
##   3. (Linux) no live process mentions the subject's directory in its
##      command line or working directory — a daemon whose socket is under it.
##
## Every case must also have passed or skipped: a subject that crashed before
## acquiring anything would otherwise "release everything" vacuously.
##
## THE DETECTOR IS SHOWN TO FIRE. The first suite drives two miniature
## subjects through the same machinery: one with exactly the defect's shape
## (acquire at module scope, release in a "teardown" case) and one that
## releases at exit. The first must be reported, with the processes that
## leaked named; the second must not. Without that pair, an empty report
## would not distinguish "nothing leaked" from "nothing was looked at".
##
## SUBJECTS are the files that had the teardown-as-a-case shape. Each is an
## input of this file's execute edge (``PerCaseFixtureGateSubjects`` in
## ``repro.nim``), so a change to any of them re-runs this gate; the last case
## below checks that the two lists agree. Two files of that shape are fixed
## the same way but are NOT subjects, because this file cannot judge them
## soundly:
##
##   * ``t_every_launch_path_is_monitored`` puts its scratch tree in a literal
##     ``/tmp`` (its socket must fit ``sun_path`` under any TMPDIR) with a
##     random name, so nothing here could tell its leftovers from those of a
##     concurrent run of the same file;
##   * ``t_m4_publisher_path_stores_output_blobs`` keys its scratch root on
##     the CASE NAME (``testCaseScratchSlug``), so running its cases here, while
##     the suite runs the same cases, would make two processes share one root.
##
## NO MOCKS: the real subject binaries, real processes, the real filesystem.
## The miniature subjects of the first suite are shell scripts, not mocks of
## a subject: they ARE subjects, written to have a known answer.

import std/[os, sequtils, sets, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_test_support/per_case_runs

type
  LeakReport = object
    processes: seq[CaseProcess]
    caseFailures: seq[string]
    leftInRoot: seq[string]
    pidNamedLeftovers: seq[string]
    liveProcesses: seq[string]

const Subjects = [
  "libs/repro_fs_facts/tests/t_fs_facts_conformance.nim",
  "libs/repro_cas_store/tests/t_link_capability_probe.nim",
  "libs/repro_cas_store/tests/t_cas_store_occupancy_cost.nim",
  "libs/repro_cas_store/tests/t_cas_materialize_link.nim",
  "libs/repro_cas_store/tests/t_cas_link_mutation_safety.nim",
  "libs/repro_cas_store/tests/t_link_capability_facts.nim",
  "libs/repro_cas_store/tests/t_cas_ingest_link.nim",
  "tests/integration/t_cloud_adapter_launches_nothing_in_ci.nim",
  "tests/integration/t_inline_launch_refuses_unhostable_monitor_hosting.nim",
  "tests/integration/t_leaked_instance_is_reaped.nim",
  "tests/integration/t_measurement_manifest_cross_check.nim",
  "tests/integration/t_monitor_fault_fails_the_action_not_the_daemon.nim",
  "tests/integration/t_snp_expectation_reaches_the_manifest.nim",
  "tests/integration/t_teardown_runs_on_failure_path.nim",
  "tests/integration/t_verify_e2e_mock.nim",
]
  ## Repo-relative sources; each one's binary is the graph-built
  ## ``build/test-bin/<stem>``.

proc binaryOf(source: string): string =
  graphArtifactPath("build/test-bin" /
    source.extractFilename.changeFileExt("").addFileExt(ExeExt))

proc fixedParents(subjectDir: string): seq[string] =
  ## Where a subject may put a pid-named fixture whatever ``TMPDIR`` says.
  when defined(windows):
    for letter in 'A' .. 'Z':
      let root = $letter & ":\\"
      if dirExists(root): result.add(root)
  else:
    for p in ["/tmp", "/var/tmp", "/dev/shm"]:
      if dirExists(p): result.add(p)
  if subjectDir.len > 0 and dirExists(subjectDir):
    result.add(subjectDir)

proc snapshot(parents: seq[string]): HashSet[string] =
  for parent in parents:
    try:
      for _, path in walkDir(parent):
        result.incl(path)
    except OSError:
      discard

proc namesPid(name: string; pid: int): bool =
  ## ``name`` carries ``pid`` as a whole run of digits: ``repro-f2-123-vol0``
  ## names 123, ``repro-f2-1234-vol0`` does not.
  let token = $pid
  var at = name.find(token)
  while at >= 0:
    let before = at == 0 or name[at - 1] notin Digits
    let afterIdx = at + token.len
    let after = afterIdx >= name.len or name[afterIdx] notin Digits
    if before and after:
      return true
    at = name.find(token, at + 1)
  false

proc entriesUnder(dir: string): seq[string] =
  if not dirExists(dir):
    return
  for _, path in walkDir(dir):
    result.add(path)

proc tail(text: string; n: int): string =
  let t = text.strip()
  if t.len <= n: t else: "..." & t[^n .. ^1]

proc runAndInspect(binary, subjectDir: string): LeakReport =
  ## Drive ``binary`` the way the runner does and report what survived it.
  # SHORT, and deliberately not under ``$TMPDIR``: a subject binds a unix
  # socket under the TMPDIR it is given (``<TMPDIR>/repro-p3-refusal<8>/ep/
  # runquota.sock`` is 40 characters below it), and ``sun_path`` holds 108
  # bytes. Under the suite's own TMPDIR that path measured over the limit,
  # runquotad refused to bind, and the subject's cases failed.
  let root = createTempDir("rfg-", "",
    when defined(windows): getTempDir() else: "/tmp")
  let tmpRoot = root / "tmp"
  let homeRoot = root / "home"
  let resultDir = root / "results"       # ours, never inspected for leaks
  createDir(tmpRoot)
  createDir(homeRoot)
  defer: removeDirEventually(root)
  let env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  for k in ["TMPDIR", "TMP", "TEMP"]:
    env[k] = tmpRoot
  env["HOME"] = homeRoot
  env["USERPROFILE"] = homeRoot
  let parents = fixedParents(subjectDir)
  let before = snapshot(parents)
  result.processes = runEveryCaseInItsOwnProcess(binary, env, resultDir)
  for p in result.processes:
    # 0 = pass, 2 = skip (the protocol's codes). The probe answers 0.
    if p.exitCode notin [0, 2]:
      result.caseFailures.add((if p.name.len == 0: "--list-json" else: p.name) &
        " exited " & $p.exitCode & ": " &
        tail(p.output & "\n" & p.errorOutput, 600))
  result.leftInRoot = entriesUnder(tmpRoot) & entriesUnder(homeRoot)
  for path in snapshot(parents):
    if path in before:
      continue
    for p in result.processes:
      if namesPid(path.extractFilename, p.pid):
        result.pidNamedLeftovers.add(path & "  (left by pid " & $p.pid &
          (if p.name.len == 0: ", the --list-json probe" else:
            ", case " & p.name) & ")")
        break
  result.liveProcesses = processesMentioning(root)
  # The gate's own scratch is removed by the ``defer`` above; a fixture the
  # subject created under it is removed with it, so a failing run does not
  # itself become the leak it reports.
  for leftover in result.pidNamedLeftovers:
    try:
      removeDir(leftover.split("  (")[0])
    except OSError:
      discard

proc describe(r: LeakReport): string =
  var lines: seq[string] = @[]
  for f in r.caseFailures: lines.add("  case did not pass: " & f)
  for p in r.leftInRoot: lines.add("  left in the redirected TMPDIR/HOME: " & p)
  for p in r.pidNamedLeftovers: lines.add("  pid-named leftover: " & p)
  for p in r.liveProcesses: lines.add("  still running: " & p)
  lines.join("\n")

proc leaked(r: LeakReport): bool =
  r.leftInRoot.len > 0 or r.pidNamedLeftovers.len > 0 or
    r.liveProcesses.len > 0

when defined(posix):
  const ProtocolScript = """#!/bin/sh
# A miniature test binary speaking the runner protocol: two cases, and a
# fixture acquired when the "module" loads, i.e. in EVERY process.
fixture="${TMPDIR:-/tmp}/gate-control-$$"
mkdir -p "$fixture"
RELEASE_AT_EXIT
case "$1" in
  --list-json)
    printf '%s\n' '{"tests":[{"name":"control::uses the fixture"},{"name":"control::teardown"}]}'
    ;;
  --run)
    case "$2" in
      "control::teardown") rm -rf "$fixture" ;;
      *) test -d "$fixture" || exit 1 ;;
    esac
    ;;
esac
exit 0
"""

  proc writeControl(dir, name, releaseAtExit: string): string =
    result = dir / name
    writeFile(result, ProtocolScript.replace("RELEASE_AT_EXIT", releaseAtExit))
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

  suite "the detector fires on the teardown-as-a-case shape":
    test "a fixture released only by a teardown case is reported, per process":
      let dir = createTempDir("repro-fixture-gate-control-", "")
      defer: removeDirEventually(dir)
      let leaky = writeControl(dir, "leaky.sh", ": no release at exit")
      let r = runAndInspect(leaky, "")
      checkpoint(describe(r))
      check r.caseFailures.len == 0
      # Three processes (probe + two cases); the teardown case released its
      # own, so exactly the probe's and the other case's survive.
      check r.processes.len == 3
      check r.leftInRoot.len == 2
      for p in r.processes:
        let mine = r.leftInRoot.anyIt(it.extractFilename ==
          "gate-control-" & $p.pid)
        if p.name == "control::teardown":
          check not mine
        else:
          check mine

    test "the same fixture released at process exit is not reported":
      let dir = createTempDir("repro-fixture-gate-control-", "")
      defer: removeDirEventually(dir)
      let tidy = writeControl(dir, "tidy.sh",
        "trap 'rm -rf \"$fixture\"' EXIT")
      let r = runAndInspect(tidy, "")
      checkpoint(describe(r))
      check r.processes.len == 3
      check r.caseFailures.len == 0
      check not r.leaked

proc inspectSubject(source: string): LeakReport =
  doAssert source in Subjects, source & " is not in Subjects"
  let binary = requireBinary(binaryOf(source),
    "the test-builds edge for " & source)
  result = runAndInspect(binary, ReprobuildRepoRoot / source.parentDir)
  if result.leaked or result.caseFailures.len > 0:
    echo source, " under one process per case (", result.processes.len,
      " processes):\n", describe(result)

template checkSubject(source: string) =
  ## The body of every subject case: drive ``source``'s binary one process per
  ## case and assert that none of them left anything behind. A template so
  ## ``skip`` and ``check`` act on the case that expands it.
  let r = inspectSubject(source)
  if r.processes.len == 1:
    # The probe answered and listed nothing: every case of this subject is
    # behind a platform guard this host does not satisfy. Nothing ran, so
    # nothing can have leaked, and "passed" would claim it had been checked.
    skip(source & " registers no case on this platform")
  else:
    check r.caseFailures.len == 0
    check r.leftInRoot.len == 0
    check r.pidNamedLeftovers.len == 0
    check r.liveProcesses.len == 0

suite "no subject's fixture outlives the process that acquired it":
  test "t_fs_facts_conformance":
    checkSubject("libs/repro_fs_facts/tests/t_fs_facts_conformance.nim")
  test "t_link_capability_probe":
    checkSubject("libs/repro_cas_store/tests/t_link_capability_probe.nim")
  test "t_cas_store_occupancy_cost":
    checkSubject("libs/repro_cas_store/tests/t_cas_store_occupancy_cost.nim")
  test "t_cas_materialize_link":
    checkSubject("libs/repro_cas_store/tests/t_cas_materialize_link.nim")
  test "t_cas_link_mutation_safety":
    checkSubject("libs/repro_cas_store/tests/t_cas_link_mutation_safety.nim")
  test "t_link_capability_facts":
    checkSubject("libs/repro_cas_store/tests/t_link_capability_facts.nim")
  test "t_cas_ingest_link":
    checkSubject("libs/repro_cas_store/tests/t_cas_ingest_link.nim")
  test "t_cloud_adapter_launches_nothing_in_ci":
    checkSubject("tests/integration/t_cloud_adapter_launches_nothing_in_ci.nim")
  test "t_inline_launch_refuses_unhostable_monitor_hosting":
    checkSubject(
      "tests/integration/t_inline_launch_refuses_unhostable_monitor_hosting.nim")
  test "t_leaked_instance_is_reaped":
    checkSubject("tests/integration/t_leaked_instance_is_reaped.nim")
  test "t_measurement_manifest_cross_check":
    checkSubject("tests/integration/t_measurement_manifest_cross_check.nim")
  test "t_monitor_fault_fails_the_action_not_the_daemon":
    checkSubject(
      "tests/integration/t_monitor_fault_fails_the_action_not_the_daemon.nim")
  test "t_snp_expectation_reaches_the_manifest":
    checkSubject("tests/integration/t_snp_expectation_reaches_the_manifest.nim")
  test "t_teardown_runs_on_failure_path":
    checkSubject("tests/integration/t_teardown_runs_on_failure_path.nim")
  test "t_verify_e2e_mock":
    checkSubject("tests/integration/t_verify_e2e_mock.nim")

suite "the subject list":
  test "every subject has a case, and every case a subject":
    # The cases above are spelled out rather than generated in a loop, so the
    # static case count and the binary's own catalog agree. This keeps the
    # two spellings from drifting apart.
    let own = readFile(currentSourcePath()).multiReplace(("\n", ""), (" ", ""))
    for s in Subjects:
      if ("checkSubject(\"" & s & "\")") notin own:
        echo s, " has no case calling checkSubject"
      check ("checkSubject(\"" & s & "\")") in own

  test "every subject is an input of this gate's execute edge":
    # The subjects are listed twice, here and in ``repro.nim``, because a
    # build-edge id is content-derived and only ``repro.nim`` can collect it.
    # A subject missing THERE runs against whatever binary is on disk, so a
    # change to it would not re-run this gate.
    let project = nimSourceCommentsBlanked(
      readFile(ReprobuildRepoRoot / "repro.nim"))
    let at = project.find("PerCaseFixtureGateSubjects* =")
    check at >= 0
    let tail = project[max(at, 0) .. ^1]
    let listEnd = tail.find("]")
    let declared = if listEnd > 0: tail[0 .. listEnd] else: ""
    for subject in Subjects:
      if ("\"" & subject & "\"") notin declared:
        echo subject, " is not in repro.nim's PerCaseFixtureGateSubjects"
      check ("\"" & subject & "\"") in declared
