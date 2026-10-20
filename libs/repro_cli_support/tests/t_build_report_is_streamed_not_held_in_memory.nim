## t_build_report_is_streamed_not_held_in_memory — writing the build report
## must not hold the whole report in memory.
##
## The defect (reprobuild-pm
## ``issues/2026-10-18-full-suite-run-dies-at-the-build-action-payload-cache-policy-case.md``):
## the engine running ``repro build --write-report .#test-builds`` kept
## growing after all 2,111 builds were done — 16 GB of RSS plus ~29 GB of
## swap. ``writeBuildReport`` assembled the entire report as a ``JsonNode``
## tree and then as one ``$root`` string before writing it, and that report
## is dominated by ``actions[].evidence`` path strings (7.7 GB, ~85M paths, on
## that host). The writer's peak therefore scaled with the build, at roughly
## 4.5x the document's size.
##
## What this test owns
## -------------------
##   1. MEMORY: writing a report of a few hundred MB raises the process's peak
##      RSS by a small constant, not by a multiple of the document. This is
##      the assertion that fails on the tree-building writer.
##   2. FORMAT: the streamed file is byte-identical to ``$buildReportJson``
##      — the compact single-line text the suite's
##      ``scripts/lib/build_report_attribution.sh`` greps — on every provider
##      route and with escaping-sensitive content, so streaming cannot drift
##      the format readers depend on. The failure report, which has no tree
##      form, is checked to be in canonical compact form with its members in
##      their documented order.
##   3. FAILURE: a write that raises leaves the earlier report untouched and
##      no partial file behind, as the whole-document ``writeFile`` did.
##
## Fixtures, not fakes
## -------------------
## The ``BuildRunResult`` values are synthetic DATA handed to the real
## writers, which write to the real filesystem. Nothing is mocked or stubbed.
## The data is synthetic because the property is about scale: reproducing a
## report of this size from real actions would take a multi-hour build, and
## the writer cannot tell a synthetic result from a real one — it reads only
## the fields set here.

import std/[json, options, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_cli_support
import repro_build_engine
import repro_interface_artifacts
import repro_provider_runtime
import repro_project_dsl
import repro_test_support/reasoned_skip

proc evidenceWith(reads, probes: openArray[string];
                  declared: openArray[string] = []): PathSetEvidence =
  ## Evidence carrying the given paths in the two channels that dominate a
  ## real report (``monitorReads`` 39%, ``monitorProbes`` 56% of the 7.7 GB
  ## one), recorded through the engine's own ``observeAll`` so the channel
  ## invariants hold.
  result.declaredInputs = @declared
  result.monitorReads.observeAll(result.evidenceProvenance,
    evcMonitorCapture, reads)
  result.monitorProbes.observeAll(result.evidenceProvenance,
    evcMonitorCapture, probes)

proc procStatusKiB(field: string): int =
  ## A ``kB`` field of ``/proc/self/status`` (``VmRSS``, ``VmHWM``).
  for line in readFile("/proc/self/status").splitLines():
    if line.startsWith(field & ":"):
      return parseInt(line[field.len + 1 .. ^1].strip().split()[0])
  raise newException(ValueError, field & " not in /proc/self/status")

proc resetPeakRss(): bool =
  ## Reset ``VmHWM`` to the current RSS (``proc(5)``, ``clear_refs`` value
  ## 5), so the peak read afterwards belongs to the code under test and not
  ## to the fixture construction before it.
  try:
    writeFile("/proc/self/clear_refs", "5")
    true
  except IOError:
    false

proc variedFixture(): tuple[cmake, build: BuildRunResult;
                            resolutions: seq[TargetResolutionRecord]] =
  ## Small, but exercising every member the writer emits and every escape
  ## class JSON has: quotes, backslashes, control characters, non-ASCII,
  ## empty strings and floats.
  result.cmake.results.add(ActionResult(id: "cmake-regen",
    status: asSucceeded, launched: true,
    evidence: evidenceWith(["/src/CMakeLists.txt"], [])))
  result.build.results.add(ActionResult(id: "compile \"quoted\" \\ back",
    status: asFailed, exitCode: 2, launched: true, cacheDecision: cdMiss,
    cacheMissReason: "input metadata changed: /src/a.nim",
    cachePublishSkipReason: "failed",
    reason: "line1\nline2\ttab\x01ctl", leaseId: 42'u64,
    runQuotaBackend: "runquota", runQuotaSocket: "/run/rq.sock",
    stdout: "héllo — ünïcode ✓", stderr: "",
    evidence: evidenceWith(["/src/a.nim", "/src/with space.nim"],
      ["/probe/\"q\"", "/probe/back\\slash"], declared = ["/src/a.nim"])))
  result.build.results.add(ActionResult(id: "cached", status: asCacheHit,
    cacheDecision: cdHit))
  result.build.results.add(ActionResult(id: "blocked", status: asBlocked,
    blockedBy: "compile \"quoted\" \\ back"))
  result.build.trace.add(SchedulerTraceEvent(seq: 1, actionId: "cached",
    event: "ready", detail: ""))
  result.build.trace.add(SchedulerTraceEvent(seq: 18446744073709551615'u64,
    actionId: "compile \"quoted\" \\ back", event: "finished",
    detail: "exit=2\n"))
  result.build.stats = BuildStats(metrics: @[
    BuildStatsMetric(name: "engine.lookup", count: 3, totalUs: 1234.5),
    BuildStatsMetric(name: "engine.empty", count: 0, totalUs: 0.0)])
  result.build.runQuotaBypassed = true
  result.resolutions = @[
    TargetResolutionRecord(selector: "test-builds", kind: trkResolved,
      actionId: "cached", owningPackage: "reprobuild",
      targetKind: tekCollection),
    TargetResolutionRecord(selector: "amb", kind: trkAmbiguous,
      candidates: @["a.amb", "b.amb"]),
    TargetResolutionRecord(selector: "nope", kind: trkUnknown,
      suggestions: @["nope2"])]

suite "build report: streamed to disk, byte-identical to the tree form":

  test "every provider route writes exactly $buildReportJson":
    let scratch = createTempDir("repro-report-stream-format-", "")
    defer: removeDir(scratch)
    let binary = scratch / "repro-standard-provider"
    writeFile(binary, "prebuilt provider bytes")
    let fixture = variedFixture()
    var compileResult: BuildRunResult
    compileResult.results.add(ActionResult(id: "provider-compile",
      status: asSucceeded, launched: true,
      evidence: evidenceWith(["/src/repro.nim"], ["/probe/nim.cfg"])))
    let refresh = ProviderRefreshReport(persistedSnapshotPath: "/s.rbsz")
    let contexts = @[
      compiledProviderReportContext(ProviderCompileArtifact(
        outputBinaryPath: "/work/provider",
        executionResult: ProviderCompileExecutionResult(exitCode: 0,
          output: "compiled \"ok\"\n")), compileResult, "artifact-id",
        refresh, 3),
      prebuiltProviderReportContext("tier2b-standard-direct", binary,
        "repro-standard-provider.v1.x", refresh),
      loweredGraphCacheReportContext("/work/lowered.rbsz")]
    var index = 0
    for context in contexts:
      for resolutions in [none(seq[TargetResolutionRecord]),
          some(newSeq[TargetResolutionRecord]()), some(fixture.resolutions)]:
        for cmake in [BuildRunResult(), fixture.cmake]:
          inc index
          let path = scratch / "out" / ("report-" & $index & ".json")
          writeBuildReport(path, context, cmake, fixture.build,
            targetResolutions = resolutions)
          let expected = $buildReportJson(context, cmake, fixture.build,
            targetResolutions = resolutions)
          check readFile(path) == expected
    # Nothing but the finished documents is left in the directory.
    check toSeq(walkDir(scratch / "out")).len == index

  test "the failure report is compact, canonical and in member order":
    let scratch = createTempDir("repro-report-stream-failure-", "")
    defer: removeDir(scratch)
    let path = scratch / "build-failure-report.json"
    let fixture = variedFixture()
    let actions = @[BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      id: "compile \"quoted\" \\ back", argv: @["nim", "c", "a b.nim"],
      cwd: "/work", inputs: @["a b.nim"], outputs: @["out"], cacheable: true)]
    writeBuildFailureReport(path, fixture.build, actions, ".#x", "/work",
      "/work/out", 1)
    let text = readFile(path)
    let node = parseJson(text)
    # Re-serialising the parsed document reproduces the file exactly only if
    # the file is the single-line ``$`` form and its members keep their order.
    check $node == text
    check toSeq(node.keys) == @["schemaId", "target", "projectRoot",
      "outDir", "exitCode", "counts", "failedActions", "blockedActions",
      "runQuota"]
    check node["failedActions"].len == 1
    check node["failedActions"][0]["argv"].len == 3
    check node["blockedActions"].len == 1
    check node["counts"]["total"].getInt == 3

  test "a write that raises keeps the earlier report and leaves no partial":
    let scratch = createTempDir("repro-report-stream-raise-", "")
    defer: removeDir(scratch)
    let path = scratch / "build-report.json"
    writeFile(path, "earlier report")
    var buildResult: BuildRunResult
    buildResult.results.add(ActionResult(id: "fine", status: asSucceeded,
      evidence: evidenceWith(["/src/a.nim"], [])))
    # An elided result reaching the report writer is refused (see
    # ``actionResultJson``) — after the first action has been streamed.
    buildResult.results.add(ActionResult(id: "elided", status: asCacheHit,
      evidencePathCounts: EvidencePathCounts(elided: true)))
    expect ValueError:
      writeBuildReport(path, loweredGraphCacheReportContext("/l.rbsz"),
        BuildRunResult(), buildResult)
    check readFile(path) == "earlier report"
    check toSeq(walkDir(scratch)).len == 1

  test "a rename that fails after a complete write leaves no partial":
    # The last step can fail too: here the report path is an existing,
    # non-empty directory, so the document is fully written and only the
    # rename onto ``path`` is refused. The partial must not outlive it.
    let scratch = createTempDir("repro-report-stream-rename-", "")
    defer: removeDir(scratch)
    let path = scratch / "build-report.json"
    createDir(path)
    writeFile(path / "occupant", "keeps the directory non-empty")
    expect OSError:
      writeBuildReport(path, loweredGraphCacheReportContext("/l.rbsz"),
        BuildRunResult(), BuildRunResult())
    check dirExists(path)
    check readFile(path / "occupant") == "keeps the directory non-empty"
    check toSeq(walkDir(scratch)).len == 1

  test "a dead writer's partial is reclaimed; a live writer's is kept":
    # A writer killed mid-write (OOM, signal, timeout) leaves its
    # ``<name>.partial-<pid>`` behind, and for a ``.#test-builds`` report
    # that file is gigabytes. The next write of the same report reclaims
    # it when its pid is dead, and leaves alone everything it cannot prove
    # abandoned: a live pid (a concurrent writer) and any other name.
    when defined(windows):
      skip("the live and dead writer pids come from `true` and `sleep`, " &
        "which a Windows host does not have on PATH")
    else:
      let scratch = createTempDir("repro-report-stream-partials-", "")
      defer: removeDir(scratch)
      let path = scratch / "build-report.json"
      # A pid that is certainly dead: a child that has exited and been reaped.
      let exited = startProcess("true", options = {poUsePath})
      let deadPid = exited.processID
      discard exited.waitForExit()
      exited.close()
      # A pid that is certainly alive for the duration of the write.
      let sleeper = startProcess("sleep", args = ["300"],
        options = {poUsePath})
      defer:
        sleeper.kill()
        discard sleeper.waitForExit()
        sleeper.close()
      let livePid = sleeper.processID
      let dead = path & ".partial-" & $deadPid
      let live = path & ".partial-" & $livePid
      let unrelated = @[
        path & ".partial-notapid",           # does not parse as a pid
        path & ".partial-" & $deadPid & ".bak", # not exactly the pattern
        scratch / "other.json.partial-" & $deadPid] # another report's
      for file in @[dead, live] & unrelated:
        writeFile(file, "partial bytes")
      writeBuildReport(path, loweredGraphCacheReportContext("/l.rbsz"),
        BuildRunResult(), BuildRunResult())
      check fileExists(path)
      check not fileExists(dead)
      check fileExists(live)
      for file in unrelated:
        check fileExists(file)

suite "build report: writing it does not hold the report in memory":

  test "peak RSS growth while writing is bounded, not proportional":
    when not defined(linux):
      skip("peak RSS is read from /proc/self/status, which only Linux has")
    else:
      # ~2,000 actions x 1,200 paths of ~90 bytes: a ~230 MB report, the
      # shape of the 7.7 GB one scaled down ~33x. Every path is distinct, as
      # in a real build, so nothing can be shared between them.
      const actionCount = 2_000
      const pathsPerChannel = 600
      var buildResult: BuildRunResult
      for a in 0 ..< actionCount:
        var reads, probes: seq[string]
        for p in 0 ..< pathsPerChannel:
          let tail = "/" & align($a, 5, '0') & "/" & align($p, 5, '0')
          reads.add("/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nim-2.2.4" &
            "/lib/pure/collections/read" & tail & ".nim")
          probes.add("/home/builder/m/reprobuild/build/nimcache/probe" &
            "/@m..@slibs@srepro_core@ssrc" & tail & ".nim.c")
        buildResult.results.add(ActionResult(id: "test-build-" & $a,
          status: asSucceeded, launched: true,
          evidence: evidenceWith(reads, probes)))
      let scratch = createTempDir("repro-report-stream-memory-", "")
      defer: removeDir(scratch)
      let path = scratch / "build-report.json"
      let exactPeak = resetPeakRss()
      let rssBefore = procStatusKiB("VmRSS")
      let peakBefore = procStatusKiB("VmHWM")
      writeBuildReport(path, loweredGraphCacheReportContext("/l.rbsz"),
        BuildRunResult(), buildResult)
      let peakAfter = procStatusKiB("VmHWM")
      let reportKiB = int(getFileSize(path) div 1024)
      # Without the reset the peak before the write may already sit above
      # the current RSS (fixture construction), and only growth past it is
      # visible; with it, the baseline is the RSS at the call.
      let baseline = if exactPeak: rssBefore else: max(rssBefore, peakBefore)
      let growthKiB = max(0, peakAfter - baseline)
      checkpoint "report " & $reportKiB & " KiB; RSS before " &
        $rssBefore & " KiB; peak during write " & $peakAfter &
        " KiB; growth " & $growthKiB & " KiB (exact peak reset: " &
        $exactPeak & ")"
      echo "report=", reportKiB, "KiB rssBefore=", rssBefore,
        "KiB peakAfter=", peakAfter, "KiB growth=", growthKiB, "KiB"
      check reportKiB > 150 * 1024
      # The tree-building writer grew by more than the report itself (the
      # tree, then the ``$root`` string). The streamed one holds one
      # action's subtree, the scratch buffer and the 1 MiB file buffer.
      check growthKiB < 32 * 1024
