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
import std/[os, osproc, streams, unittest]
import repro_test_support

const OtherAccountUid = "953"

proc withHostAccountEmulated(body: proc ()) =
  let hadScope = existsEnv("RUNQUOTA_ENDPOINT_SCOPE")
  let prevScope = getEnv("RUNQUOTA_ENDPOINT_SCOPE")
  let hadOwner = existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
  let prevOwner = getEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
  delEnv("RUNQUOTA_ENDPOINT_SCOPE")
  putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", OtherAccountUid)
  try:
    body()
  finally:
    if hadScope: putEnv("RUNQUOTA_ENDPOINT_SCOPE", prevScope)
    else: delEnv("RUNQUOTA_ENDPOINT_SCOPE")
    if hadOwner: putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", prevOwner)
    else: delEnv("RUNQUOTA_ENDPOINT_OWNER_UID")

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
