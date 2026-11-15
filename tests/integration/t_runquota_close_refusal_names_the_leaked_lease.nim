## A refused session close names the lease and action it refused over.
##
## WHY. The daemon refuses to close a session that still owns a lease, and the
## build used to report only ``session still owns leases`` (reprobuild-specs
## issue 2026-11-04-repro-build-fails-with-session-still-owns-leases-after-
## every-action-executed): no lease id, no action. ``runQuotaSessionLeases``
## reads the daemon's ``leases`` inspection subject and lists the session's
## unfinished leases, which the engine appends to a failed close.
##
## NO MOCKS: a real ``runquotad`` decides, and the leak is a real granted lease
## that this test deliberately does not release.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import runquota_client
import repro_core
import repro_runquota
import repro_test_support

suite "a refused RunQuota session close names the leaked lease":
  test "the unfinished lease is listed with its label and state":
    let root = createTempDir("repro-closeleak", "")
    defer: removeDir(root)
    let socket = runquotaSocketEndpoint("repro-closeleak-" &
      $getCurrentProcessId() & "-" & root.extractFilename)
    writeFile(root / "runquotad.toml", "schema = \"runquota.host-config.v1\"\n")
    putEnv("RUNQUOTA_SOCKET", socket)
    var daemon = startProcess(requireRunQuotaDaemonBin(getCurrentDir()), args = [
      "--socket", socket, "--host-config", root / "runquotad.toml",
      "--cpu-milli", "4000", "--memory-bytes", $(8'u64 shl 30),
      "--host-identity-file", root / "host-id", "--no-write-stats",
      "--ambient-sample-interval-millis", "0",
      "--memory-pressure-source", "unavailable"],
      options = {poUsePath, poParentStreams})
    defer:
      daemon.terminate()
      discard daemon.waitForExit(5000)
      daemon.close()
      delEnv("RUNQUOTA_SOCKET")
    for _ in 0 ..< 400:
      if isRunQuotaDaemonReachable(): break
      sleep(25)
    let session = openRunQuotaSession("close leak")
    let offers = session.offerWithRunQuotaBatch(
      [ReproResourceRequest(label: "leaky-action", commandStatsId: "leaky",
        cpuMilli: 1000, memoryBytes: 64'u64 shl 20)],
      [ReproCommandSpec(argv: @[getAppFilename(), "fixture"], cwd: root)])
    # Positive control: the offer produced a started lease we now abandon.
    check offers.len == 1
    let live = session.runQuotaSessionLeases()
    checkpoint("live leases: " & live.join(" | "))
    check live.len == 1
    if live.len == 1:
      check "leaky-action" in live[0]
    var closeError = ""
    try:
      session.close()
    except CatchableError as err:
      closeError = err.msg
    check "session still owns leases" in closeError
    # The refusal itself now carries the lease id, label and state.
    check "unreleased: lease " in closeError
    check "leaky-action" in closeError
    check "state=" in closeError
    # Pure summarizer: finished and foreign-session leases are excluded.
    let lines = summarizeSessionLeases(
      """{"leases":[{"id":7,"label":"leaky-action","session_id":3,"state":"running","child_process_id":42},
      {"id":8,"label":"done","session_id":3,"state":"finished","child_process_id":1},
      {"id":9,"label":"other","session_id":4,"state":"running","child_process_id":2}]}""",
      3'u64)
    check lines.len == 1
    check "lease 7" in lines[0]
    check "state=running" in lines[0]
