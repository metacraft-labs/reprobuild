## A ``runquotad`` from another build makes way for the one this install
## would start, and never at the expense of a build in flight.
##
## THE DEFECT. On Windows the daemon reprobuild starts outlives every build
## (``releaseAutoRunQuotaProcess`` deliberately leaves it running), and each
## later invocation adopts whatever answers on the pipe. After an installer
## replaced the bundle, the old ``runquotad`` kept serving the new ``repro``
## from the old image for as long as its user stayed logged on, and nothing
## reported it (reprobuild-pm issue
## 2026-10-26-windows-runquotad-from-a-replaced-bundle-keeps-serving-the-new-repro;
## reprobuild-specs/RunQuota-Host-Configuration.md, "A daemon from another
## build makes way").
##
## WHAT THIS RUNS. ``decideRunQuotaHandover`` -- the decision the adoption
## arm of ``startAutoRunQuotaIfNeeded`` makes on Windows -- against a real
## ``runquotad`` on a private endpoint, with a real ``runquotad`` image as the
## candidate. "Another build" is a byte-for-byte copy of that image with
## bytes appended: a file whose content digest differs, which is the whole of
## what distinguishes two builds to this check.
## POSIX endpoints are invocation-owned: each case selects the official
## private policy for daemon and clients, independently of NSS service
## accounts, then restores the caller's socket and scope. Windows keeps its
## existing named-pipe policy. Endpoint modes remain owner-only.
##
## WHY NOT ``startAutoRunQuotaIfNeeded`` ITSELF. On Windows it reaches the
## fixed host-wide pipe the host's own daemon serves; driving it would retire
## that daemon. The decision is the only new behaviour on that arm -- the
## spawn it falls through to on ``rhVacated`` is the existing spawn path.
##
## FALSIFIABILITY. Make the daemon retire regardless of digest and the first
## case fails (the daemon exits); make it exit while a client is connected
## and the third fails (the held lease's daemon is gone); drop the hold the
## adopter keeps and the third fails too (the daemon exits after the other
## client, before the adopting build opened its session), and so does the
## first (another install's retire request ends the adopted daemon).
##
## NO MOCKS. A real daemon, real images, the real client library.

import std/[os, osproc, strutils, unittest]

import repro_runquota
import repro_test_support
import repro_test_support/process_fixtures
import runquota_client
import runquota_core
import runquota_core/image_digest
import runquota_protocol

const MiB = 1024'u64 * 1024'u64

type
  Fixture = object
    root: string
    socket: string
    daemon: Process

proc startDaemon(repoRoot, root, socket: string): Process =
  result = startProcess(requireRunQuotaDaemonBin(repoRoot),
    args = @["--socket", socket,
      "--host-config", root / "runquotad.toml",
      "--host-identity-file", root / "host-id",
      "--no-write-stats", "--ambient-sample-interval-millis", "0",
      "--memory-pressure-source", "unavailable"],
    options = {poUsePath, poParentStreams})
  when defined(posix):
    # Own failure before start() can return its Fixture to a caller's defer.
    terminateAtProcessExit(processID(result))
  for _ in 0 ..< 400:
    if isRunQuotaDaemonReachable():
      when defined(posix):
        doAssert getFilePermissions(socket.parentDir) ==
          {fpUserRead, fpUserWrite, fpUserExec}
        doAssert getFilePermissions(socket) == {fpUserRead, fpUserWrite}
      return
    sleep(25)
  raise newException(OSError, "runquotad did not become reachable at " &
    socket)

proc start(repoRoot, tag: string): Fixture =
  result.root = getTempDir() / ("repro-rq-makeway-" & tag & "-" &
    $getCurrentProcessId())
  releaseDirAtProcessExit(result.root)
  removeDir(result.root)
  createDir(result.root)
  result.socket = runquotaSocketEndpoint("repro-rq-makeway-" & tag & "-" &
    $getCurrentProcessId())
  when not defined(windows):
    releaseDirAtProcessExit(result.socket.parentDir)
    removeDir(result.socket.parentDir)
  putEnv("RUNQUOTA_SOCKET", result.socket)
  result.daemon = startDaemon(repoRoot, result.root, result.socket)

proc exitCode(fixture: var Fixture; budgetMs = 15_000): int =
  ## The daemon's exit status within ``budgetMs``, or -1 if it still runs.
  result = fixture.daemon.waitForExit(budgetMs)
  if fixture.daemon.running:
    result = -1

proc stop(fixture: var Fixture) =
  if fixture.daemon != nil:
    if fixture.daemon.running:
      fixture.daemon.terminate()
      discard fixture.daemon.waitForExit(5000)
    fixture.daemon.close()
    fixture.daemon = nil
  delEnv("RUNQUOTA_SOCKET")
  removeDir(fixture.root)
  when not defined(windows):
    removeDir(fixture.socket.parentDir)

proc anotherBuild(image, root: string): string =
  ## A file that is ``image`` plus a trailer: its digest differs, and that is
  ## all "another build" means to the check under test.
  result = root / addFileExt("runquotad-other", ExeExt)
  writeFile(result, readFile(image) & "\nanother build\n")

suite "a runquotad from another build makes way":
  let repoRoot = getCurrentDir()
  let image = requireRunQuotaDaemonBin(repoRoot)
  setup:
    let socketWasSet = existsEnv("RUNQUOTA_SOCKET")
    let priorSocket = getEnv("RUNQUOTA_SOCKET")
    when defined(posix):
      let scopeWasSet = existsEnv("RUNQUOTA_ENDPOINT_SCOPE")
      let priorScope = getEnv("RUNQUOTA_ENDPOINT_SCOPE")
      putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  teardown:
    if socketWasSet: putEnv("RUNQUOTA_SOCKET", priorSocket)
    else: delEnv("RUNQUOTA_SOCKET")
    when defined(posix):
      if scopeWasSet: putEnv("RUNQUOTA_ENDPOINT_SCOPE", priorScope)
      else: delEnv("RUNQUOTA_ENDPOINT_SCOPE")

  test "the daemon this install would start is adopted, held, and keeps running":
    var fixture = start(repoRoot, "same")
    defer: fixture.stop()
    defer: releaseAdoptedDaemonHold()
    let report = decideRunQuotaHandover(image)
    check report.handover == rhAdopt
    check report.note == ""
    check holdsAdoptedDaemon()
    sleep(300)
    check fixture.daemon.running
    check isRunQuotaDaemonReachable()
    # ANOTHER INSTALL ASKS IT TO GO while this invocation has adopted it but
    # has not opened its session yet. The hold is the other client it is
    # told about, and it stays until the hold is released.
    var other = runquota_client.connectDefault()
    let asked = other.retireDaemon(
      expectedImageDigest = imageDigestOf(anotherBuild(image, fixture.root)),
      reason = "another install")
    other.close()
    check asked.decision == retirementRetiring
    check asked.otherConnections == 1'u32
    sleep(500)
    check fixture.daemon.running
    check isRunQuotaDaemonReachable()
    releaseAdoptedDaemonHold()
    check not holdsAdoptedDaemon()
    check fixture.exitCode() == 0
    check not isRunQuotaDaemonReachable()

  test "an idle daemon from another build exits and frees the endpoint":
    var fixture = start(repoRoot, "idle")
    defer: fixture.stop()
    let report = decideRunQuotaHandover(anotherBuild(image, fixture.root))
    check report.handover == rhVacated
    check report.note == ""
    check fixture.exitCode() == 0
    check not isRunQuotaDaemonReachable()
    # The endpoint is free for the daemon this install starts in its place:
    # on Windows the pipe is created first-instance-only, so this bind needs
    # every instance of the old daemon's pipe closed.
    fixture.daemon.close()
    fixture.daemon = startDaemon(repoRoot, fixture.root, fixture.socket)
    var client = runquota_client.connectDefault()
    var session = client.registerSession("replacement", "1")
    var lease = session.requestLease(resourceRequest("after", milliCpu(100),
      bytes(1'u64 * MiB)))
    check lease.active
    lease.release()
    session.closeSession()
    client.close()

  test "a busy daemon from another build serves on, held by the build that adopted it, then exits after its last client":
    var fixture = start(repoRoot, "busy")
    defer: fixture.stop()
    defer: releaseAdoptedDaemonHold()
    var holder = runquota_client.connectDefault()
    var held = holder.registerSession("in flight", "1")
    var lease = held.requestLease(resourceRequest("held", milliCpu(100),
      bytes(1'u64 * MiB)))
    require lease.active
    let report = decideRunQuotaHandover(anotherBuild(image, fixture.root))
    # ADOPTED, and told why: cutting off the build in flight is not an option.
    check report.handover == rhAdopt
    check "is from another build than" in report.note
    check "exits once its 1 other client(s) and this build disconnect" in
      report.note
    check holdsAdoptedDaemon()
    sleep(300)
    check fixture.daemon.running
    # The build in flight is still served.
    var second = held.requestLease(resourceRequest("second", milliCpu(100),
      bytes(1'u64 * MiB)))
    check second.active
    second.release()
    lease.release()
    held.closeSession()
    holder.close()
    # THE ADOPTER'S HOLD KEEPS IT. The client it was busy with is gone, but
    # the build that adopted it has not opened its own session yet; a daemon
    # that exited now would leave that build with no daemon at all.
    sleep(500)
    check fixture.daemon.running
    check isRunQuotaDaemonReachable()
    var adopted = runquota_client.connectDefault()
    var adoptedSession = adopted.registerSession("adopter", "1")
    var adoptedLease = adoptedSession.requestLease(resourceRequest("adopted",
      milliCpu(100), bytes(1'u64 * MiB)))
    check adoptedLease.active
    adoptedLease.release()
    adoptedSession.closeSession()
    adopted.close()
    # Released, the daemon goes after its last client.
    releaseAdoptedDaemonHold()
    check not holdsAdoptedDaemon()
    check fixture.exitCode() == 0
    check not isRunQuotaDaemonReachable()

  test "a candidate that proves nothing asks nothing":
    var fixture = start(repoRoot, "nothing")
    defer: fixture.stop()
    check decideRunQuotaHandover("").handover == rhAdopt
    check decideRunQuotaHandover(fixture.root / "no-such-runquotad").handover ==
      rhAdopt
    sleep(300)
    check fixture.daemon.running
