## A `runquotad` that a test starts on an endpoint the test owns must come up
## on a host that has a `runquota` account, exactly as it does on one that
## has none (issue 2026-11-14-reprobuild-tests-that-start-their-own-runquotad-
## are-refused-on-hosts-with-a-runquota-account).
##
## The host fact is reproduced rather than assumed: `RUNQUOTA_ENDPOINT_OWNER_UID`
## names an account other than the invoking user, which is what
## `rendezvousPolicy` resolves on a host with a `runquota` account, so the
## host policy refuses a daemon the invoking user started in a directory the
## invoking user owns. A real `runquotad` is started, because the refusal is
## the daemon's, not this library's. No mock is involved.
##
## The same holds for the OTHER way a fixture obtains an endpoint,
## `runquotaRendezvousDir`, which hands back a directory the caller appends
## its own socket name to (`t_every_launch_path_is_monitored`'s RunQuota
## fixture was refused there with "refusing a path owned by uid 1000 with
## mode 0750; configured daemon owner uid 953"). Those cases
## also emulate the host's `runquota` GROUP, through
## `RUNQUOTA_ENDPOINT_GROUP` naming this process's own gid, because that is
## what made the observed directory `0750`: the host scope on a host with
## both the account and the group. Both the short-root `<root>/ep` directory
## and the relocated `/tmp/repro-rqt-<uid>-<hash>` one (the directory the
## observed refusal named) are exercised, because they are separate branches.
import std/[os, osproc, streams, strutils, unittest]
when defined(posix):
  import std/posix
import repro_test_support

const OtherAccountUid = "953"

proc withHostAccountEmulated(body: proc (); emulateGroup = false) =
  const keys = ["RUNQUOTA_ENDPOINT_SCOPE", "RUNQUOTA_ENDPOINT_OWNER_UID",
                "RUNQUOTA_ENDPOINT_GROUP"]
  var saved: seq[(string, bool, string)] = @[]
  for key in keys:
    saved.add((key, existsEnv(key), getEnv(key)))
  delEnv("RUNQUOTA_ENDPOINT_SCOPE")
  putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", OtherAccountUid)
  when defined(posix):
    if emulateGroup:
      # Numeric, so the group need not have a name on this host; it is this
      # process's own gid, so the group the host scope requires is one the
      # directory really carries.
      putEnv("RUNQUOTA_ENDPOINT_GROUP", $getgid())
  try:
    body()
  finally:
    for (key, had, value) in saved:
      if had: putEnv(key, value)
      else: delEnv(key)

proc socketExists(path: string): bool =
  ## ``fileExists`` is false for a socket, so ask for the entry itself.
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

suite "test-owned runquotad on a host with a runquota account":
  test "the daemon binds the socket runquotaSocketEndpoint names":
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
    let daemonBin = requireRunQuotaDaemonBin(repoRoot)
    withHostAccountEmulated(proc () =
      let socketPath = runquotaSocketEndpoint(
        "repro-rqt-acct-" & $getCurrentProcessId())
      let daemon = startProcess(daemonBin, args = [
        "--socket", socketPath, "--cpu-milli", "1000",
        "--memory-bytes", "1073741824", "--no-write-stats"],
        options = {poUsePath, poStdErrToStdOut})
      defer:
        if daemon.running: daemon.terminate()
        discard daemon.waitForExit()
        daemon.close()
        removeDir(socketPath.parentDir)
      var appeared = false
      for _ in 0 ..< 200:
        if socketExists(socketPath):
          appeared = true
          break
        if not daemon.running:
          break
        sleep(25)
      if not appeared and not daemon.running:
        # Say why the daemon left instead of only that no socket appeared.
        # readall-ok: diagnostic from a daemon that left or was stopped; a descendant may hold the pipe
        checkpoint(daemon.outputStream.readAll())
      check appeared
    )

  test "a scope the test already chose is left alone":
    let hadScope = existsEnv("RUNQUOTA_ENDPOINT_SCOPE")
    let prevScope = getEnv("RUNQUOTA_ENDPOINT_SCOPE")
    defer:
      if hadScope: putEnv("RUNQUOTA_ENDPOINT_SCOPE", prevScope)
      else: delEnv("RUNQUOTA_ENDPOINT_SCOPE")
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "host")
    discard runquotaSocketEndpoint("repro-rqt-keep-" & $getCurrentProcessId())
    check getEnv("RUNQUOTA_ENDPOINT_SCOPE") == "host"

proc startedDaemonBinds(daemonBin, socketPath: string): bool =
  ## Start a real runquotad on ``socketPath`` and report whether it bound.
  ## A daemon that refused its rendezvous exits; what it said is recorded
  ## as a checkpoint so a failure names the refusal.
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath, "--cpu-milli", "1000",
    "--memory-bytes", "1073741824", "--no-write-stats"],
    options = {poUsePath, poStdErrToStdOut})
  defer:
    if daemon.running: daemon.terminate()
    discard daemon.waitForExit()
    daemon.close()
  for _ in 0 ..< 200:
    if socketExists(socketPath):
      return true
    if not daemon.running:
      break
    sleep(25)
  if not daemon.running:
    # readall-ok: diagnostic from a daemon that left or was stopped; a descendant may hold the pipe
    checkpoint(daemon.outputStream.readAll())
  false

template rendezvousDirBinds(root: string; expectRelocated: bool) =
  ## Ask ``runquotaRendezvousDir`` for ``root``'s rendezvous under the
  ## emulated host account and group, and start a real daemon there. The
  ## call itself provisions and VERIFIES the directory, so a refusal can
  ## surface from either half; both are the defect.
  ##
  ## A template, not a proc, so its ``check``s expand inside the calling
  ## ``test`` and fail that case rather than only the process exit code.
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  let daemonBin = requireRunQuotaDaemonBin(repoRoot)
  createDir(root)
  defer: removeDir(root)
  withHostAccountEmulated(proc () =
    var dir = ""
    var refusal = ""
    try:
      dir = runquotaRendezvousDir(root)
    except CatchableError as err:
      refusal = err.msg
    check refusal == ""
    if refusal.len == 0:
      defer: removeDir(dir)
      # The branch under test really was taken.
      check dir.startsWith("/tmp/repro-rqt-" & $getuid() & "-") ==
        expectRelocated
      check startedDaemonBinds(daemonBin, dir / "runquota.sock")
  , emulateGroup = true)

# POSIX only: on Windows the endpoint is a named pipe with its own ACL, and
# ``runquotaRendezvousDir`` verifies no directory owner or mode.
when defined(posix):
  suite "test-owned runquotad in a runquotaRendezvousDir directory":
    test "the daemon binds in the <root>/ep directory of a short root":
      let root = "/tmp" / ("repro-rqt-short-" & $getCurrentProcessId())
      rendezvousDirBinds(root, expectRelocated = false)

    test "the daemon binds in the relocated /tmp/repro-rqt directory":
      # A root long enough that ``<root>/ep/<socket>`` cannot fit a
      # ``sockaddr_un``, so the rendezvous moves to
      # ``/tmp/repro-rqt-<uid>-<hash>`` -- the directory the observed
      # refusal named.
      let base = getTempDir() / ("repro-rqt-long-" & $getCurrentProcessId())
      defer: removeDir(base)
      let root = base / repeat('x', 100)
      rendezvousDirBinds(root, expectRelocated = true)
