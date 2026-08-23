## ``monitor_fault_fails_the_action_not_the_daemon``
##
## WHY THIS TEST EXISTS
## --------------------
## Today an io-monitor fault is contained by a process boundary: the
## monitor runs as ``repro internal io monitor``, so a decode or parse
## fault kills that one child and fails that one action. Hosting the
## monitor IN-PROCESS removes that boundary. The same fault would then be
## raised inside the engine — or, in daemon mode, inside the long-lived
## daemon that is serving every build on the host. Losing the process
## boundary is only acceptable if the failure is still scoped to ONE
## action.
##
## This test pins that scoping as a property of the ENGINE rather than of
## the process model, so it keeps its meaning across the hosting change:
##
##   1. a corrupt RMDF does not escape ``runBuild`` — the host survives;
##   2. it fails exactly the action whose evidence is corrupt;
##   3. an INDEPENDENT action in the SAME build still succeeds with
##      complete monitor evidence — the fault is not build-wide;
##   4. the host can run a further build afterwards — the fault is not
##      session-wide, which is the "daemon serving every build" case.
##
## THE FAULT INJECTION
## -------------------
## A real, corrupt RMDF file on the real filesystem, pre-wired onto the
## action via ``BuildAction.monitorDepfile``. ``monitoredAction``
## (repro_build_engine.nim:2735) deliberately preserves a caller-supplied
## evidence path instead of wrapping the command, so the engine reaches
## ``foldMonitorDepFileEvidence`` with bytes it cannot decode — the same
## code path a corrupt in-process snapshot would reach. The bytes are
## garbage with a valid-looking length, so the failure is a genuine
## decode error and not a missing file.
##
## NO MOCKS: real ``repro`` monitor driver, real graph-built shim, real
## compiled C fixture, real files. The engine's own results are the
## oracle.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_build_engine
import repro_test_support

const FixtureSource = r"""
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 3) return 64;
  int fd = open(argv[1], O_RDONLY);
  if (fd < 0) return 80;
  char buffer[256];
  ssize_t count = read(fd, buffer, sizeof(buffer) - 1);
  if (count < 0) return 81;
  close(fd);
  buffer[count] = '\0';
  FILE *out = fopen(argv[2], "w");
  if (out == NULL) return 82;
  fputs(buffer, out);
  fclose(out);
  return 0;
}
"""

proc compileFixture(sourcePath, outputPath: string) =
  let res = execCmdEx("cc " & quoteShell(sourcePath) & " -o " &
    quoteShell(outputPath))
  if res.exitCode != 0:
    echo res.output
  doAssert res.exitCode == 0, "fixture compile failed"

proc writeCorruptRmdf(path: string) =
  ## A file that LOOKS like an RMDF (right magic) but whose body cannot
  ## be decoded. Uses the real magic so the reader gets past the cheap
  ## checks and fails in the frame decoder, which is where an in-process
  ## host would fail too.
  createDir(path.parentDir)
  var bytes = "RMDF"
  for i in 0 ..< 64:
    bytes.add(chr((i * 37 + 11) mod 251))
  writeFile(path, bytes)

var cachedMonitorTools: MonitorTools
var cachedMonitorToolsReady = false
proc monitorTools(repoRoot: string): MonitorTools =
  if not cachedMonitorToolsReady:
    cachedMonitorTools = prepareMonitorTools(repoRoot,
      repoRoot / "build" / "test-monitor-hm4-fault", "hm4-fault-monitor")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

proc engineConfig(repoRoot, cacheRoot: string): BuildEngineConfig =
  BuildEngineConfig(
    cacheRoot: cacheRoot,
    runQuotaCliPath: monitorTools(repoRoot).monitorCliPath,
    monitorCliPath: monitorTools(repoRoot).monitorCliPath,
    monitorCliArgs: monitorTools(repoRoot).monitorCliArgs,
    maxParallelism: 2'u32,
    stdoutLimit: 256 * 1024,
    stderrLimit: 256 * 1024,
    bypassRunQuota: true)

proc resultById(run: BuildRunResult; id: string): ActionResult =
  for item in run.results:
    if item.id == id: return item
  raise newException(ValueError, "no result for " & id)

proc mentionsPath(paths: seq[string]; wanted: string): bool =
  for p in paths:
    if p == wanted: return true
  false

proc joinedDiagnostics(res: ActionResult): string =
  res.evidence.diagnostics.join("; ")

suite "monitor_fault_fails_the_action_not_the_daemon":

  when defined(linux) or defined(macosx):
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-hm4-monitor-fault", "")
    let fixtureSource = tempRoot / "fixture.c"
    let fixtureBin = tempRoot / "fixture"
    writeFile(fixtureSource, FixtureSource)
    compileFixture(fixtureSource, fixtureBin)

    test "a corrupt RMDF fails one action, not the build and not the host":
      let workRoot = tempRoot / "work"
      createDir(workRoot)
      let cacheRoot = tempRoot / ".repro-cache"

      let faultMarker = workRoot / "fault-marker.txt"
      let healthyMarker = workRoot / "healthy-marker.txt"
      writeFile(faultMarker, "fault payload\n")
      writeFile(healthyMarker, "healthy payload\n")

      # The corrupt evidence, on disk, before the build starts.
      let corruptRmdf = tempRoot / "corrupt" / "faulted.rdep"
      writeCorruptRmdf(corruptRmdf)

      let faulted = action("faulted",
        [fixtureBin, faultMarker, workRoot / "fault-out.txt"],
        cwd = workRoot,
        inputs = ["fault-marker.txt"],
        outputs = ["fault-out.txt"],
        commandStatsId = "faulted",
        cacheable = true,
        monitorDepfile = corruptRmdf,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())

      let healthy = action("healthy",
        [fixtureBin, healthyMarker, workRoot / "healthy-out.txt"],
        cwd = workRoot,
        inputs = ["healthy-marker.txt"],
        outputs = ["healthy-out.txt"],
        commandStatsId = "healthy",
        governingLockIdentity = lockIdentityOutsideSolvedGraph())

      var run: BuildRunResult
      var escaped = ""
      try:
        run = runBuild(graph([faulted, healthy]), engineConfig(repoRoot,
          cacheRoot))
      except CatchableError as err:
        escaped = $err.name & ": " & err.msg

      # PRIMARY ASSERTION. The monitor fault did not escape the engine.
      # With an in-process host this is what stands between one bad
      # action and a daemon that dies serving every build on the host.
      if escaped.len > 0:
        echo "monitor fault escaped runBuild: ", escaped
      check escaped.len == 0

      if escaped.len == 0:
        check run.results.len == 2

        # It failed the ONE action whose evidence is corrupt, and said why.
        let bad = run.resultById("faulted")
        check bad.status == asFailed
        if not bad.joinedDiagnostics.contains("monitor depfile read failed"):
          echo "faulted action diagnostics: ", bad.joinedDiagnostics
        check bad.joinedDiagnostics.contains("monitor depfile read failed")
        # The COMMAND itself was fine — this is an evidence fault, not a
        # command failure, so the isolation claim is about the monitor.
        check bad.exitCode == 0

        # The independent sibling in the SAME build is untouched and its
        # own monitor evidence is complete.
        let good = run.resultById("healthy")
        if good.status != asSucceeded:
          echo "healthy action failed exit=", good.exitCode,
            " diagnostics: ", good.joinedDiagnostics,
            " stderr: ", good.stderr
        check good.status == asSucceeded
        check good.monitorDepfilePath.len > 0
        check mentionsPath(good.evidence.monitorReads,
          expandFilename(healthyMarker))
        check not good.joinedDiagnostics.contains("monitor depfile read failed")

    test "the host still serves a further build after the fault":
      ## The "daemon serving every build on the host" half: a monitor
      ## fault in one build must not poison the next one in the same
      ## process.
      let workRoot = tempRoot / "after"
      createDir(workRoot)
      let cacheRoot = tempRoot / ".repro-cache-after"
      let marker = workRoot / "after-marker.txt"
      writeFile(marker, "after payload\n")

      let act = action("after-fault",
        [fixtureBin, marker, workRoot / "after-out.txt"],
        cwd = workRoot,
        inputs = ["after-marker.txt"],
        outputs = ["after-out.txt"],
        commandStatsId = "after-fault",
        governingLockIdentity = lockIdentityOutsideSolvedGraph())

      var run: BuildRunResult
      var escaped = ""
      try:
        run = runBuild(graph([act]), engineConfig(repoRoot, cacheRoot))
      except CatchableError as err:
        escaped = $err.name & ": " & err.msg
      check escaped.len == 0

      if escaped.len == 0:
        check run.results.len == 1
        let res = run.results[0]
        if res.status != asSucceeded:
          echo "post-fault build failed: ", res.joinedDiagnostics,
            " stderr: ", res.stderr
        check res.status == asSucceeded
        # And still fully monitored — the fault did not leave the host in
        # a degraded state that silently stops capturing evidence.
        check mentionsPath(res.evidence.monitorReads, expandFilename(marker))

    test "teardown":
      removeDir(tempRoot)
      check true
