import std/[os, tempfiles, unittest]

import repro_build_engine

suite "declared daemon platform refusals":
  test "relative endpoints are rejected before platform-specific checks":
    let verdict = checkDeclaredDaemon(DeclaredDaemon(
      kind: ddkRunQuota, endpoint: "relative.sock",
      assertions: {daProgram}, program: "runquotad"))
    check checkedDaemonOutcome(verdict) == dcoEndpointNotAbsolute
    check checkedDaemonPid(verdict) == 0
    check not trustDaemonWeChecked(ddkRunQuota, verdict)

  test "an unavailable peer cannot become trusted":
    let scratch = createTempDir("daemon-refusal-", "")
    defer: removeDir(scratch)
    let before = declaredTrustedDaemonRegistry()
    let verdict = checkDeclaredDaemon(DeclaredDaemon(
      kind: ddkRunQuota, endpoint: absolutePath(scratch / "absent.sock"),
      assertions: {daProgram}, program: "runquotad"))
    when defined(posix):
      check checkedDaemonOutcome(verdict) == dcoUnreachable
    else:
      check checkedDaemonOutcome(verdict) == dcoNoPeerCredentials
    check checkedDaemonPid(verdict) == 0
    check checkedDaemonAssertions(verdict) == {}
    check checkedDaemonIdentity(verdict).len == 0
    check checkedDaemonDetail(verdict).len > 0
    check not trustDaemonWeChecked(ddkRunQuota, verdict)
    check declaredTrustedDaemonRegistry() == before
