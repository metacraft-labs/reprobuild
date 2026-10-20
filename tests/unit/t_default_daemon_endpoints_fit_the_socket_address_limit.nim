## The DEFAULT endpoints of the repro daemon and of the store daemon fit the
## platform's Unix-socket address, however long the temp directory is.
##
## WHAT WENT WRONG. With no ``XDG_RUNTIME_DIR`` (macOS without the darwin
## per-user temp dir, CI shells, ``su`` sessions) both defaults were derived
## from ``getTempDir()`` -- ``$TMPDIR`` -- with no bound:
## ``<tmp>/repro-<uid>/repro-daemon-<uid>.sock`` for the user daemon
## (``userDaemonRuntimeDir`` / ``defaultUserDaemonEndpoint``) and
## ``<tmp>/reprostore-<uid>.sock`` for the store daemon
## (``defaultDevEndpoint``). A deep ``TMPDIR`` such as the test runner's
## ``~/.cache/reprobuild-test-tmp/<slot>`` or a ``nix-shell`` session dir
## leaves an endpoint `std/net` cannot bind: it refuses a path of
## ``Sockaddr_un_path_length`` bytes or more, 108 on Linux and 92 on macOS.
## And ``bindIpcListener`` needs room for a staging sibling next to the
## endpoint as well, for its bind-then-rename publish. (reprobuild-pm
## ``issues/2026-10-17-daemon-and-hcr-watch-socket-paths-are-not-bounded-to-
## the-platform-sun-path.md``.)
##
## WHAT THESE CASES ASSERT. With every explicit override unset and
## ``XDG_RUNTIME_DIR`` unset, a ``TMPDIR`` that is an EXISTING directory long
## enough to overflow the limit still yields default endpoints that fit, with
## room beside them for the longest compact staging leaf ``bindIpcListener``
## can fall back to: ``.zik0zj.1y2p0ij32e8e7``, the largest ``pid_t`` and the
## largest 64-bit bind sequence in base 36 (21 bytes). A short ``TMPDIR``
## keeps the derivation it always had, so nothing moves for a host where it
## already fitted.
##
## Nothing is BOUND at the default endpoint on purpose: with a long ``TMPDIR``
## it falls back into ``/tmp``, which is where a real user daemon on this host
## may be listening, and ``bindIpcListener``'s rename would replace its
## socket. The binding itself is covered against a private directory by
## ``libs/repro_daemon_core/tests/t_ipc_endpoint_is_bounded_to_the_socket_address_limit.nim``.
##
## MOCK POLICY: no mocks. The production derivations read the real process
## environment, which each case sets and restores.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip

when defined(posix):
  import std/posix
  import repro_daemon_core/protocol as daemonProtocol
  import repro_store_daemon/protocol as storeProtocol
  from repro_test_support/process_fixtures import shortSocketDirAtProcessExit

  const
    PathLimit = min(Sockaddr_un_path_length,
      sizeof(Sockaddr_un().sun_path)) - 1
      ## The longest Unix-socket path `std/net` binds on this platform.
    StagingLeafRoom = ".zik0zj.1y2p0ij32e8e7".len
      ## The longest compact staging leaf: `.` + `high(int32)` in base 36 +
      ## `.` + `high(int64)` in base 36. Stated here as a literal, not taken
      ## from the product, so the bound is checked independently of it.

  const ScrubbedVars = ["XDG_RUNTIME_DIR", "TMPDIR",
    "REPRO_DAEMON_RUNTIME_DIR", "REPRO_DAEMON_ENDPOINT",
    "REPROSTORED_ENDPOINT"]

  template withEnvironment(tmpdir: string; body: untyped) =
    ## Run ``body`` with every variable the derivations read unset except
    ## ``TMPDIR`` = ``tmpdir``, restoring the previous values afterwards.
    var saved: seq[(string, bool, string)]
    for name in ScrubbedVars:
      saved.add((name, existsEnv(name), getEnv(name)))
      delEnv(name)
    putEnv("TMPDIR", tmpdir)
    try:
      body
    finally:
      for (name, wasSet, value) in saved:
        if wasSet: putEnv(name, value)
        else: delEnv(name)

  proc longTempDir(): string =
    ## An existing directory whose path alone is within a few bytes of the
    ## limit, so anything derived under it overflows.
    let base = shortSocketDirAtProcessExit("dep-")
    result = base / repeat('t', PathLimit - 8 - base.len - 1)
    createDir(result)

  proc fitsWithStaging(endpoint: string): bool =
    endpoint.len <= PathLimit and
      endpoint.parentDir.len + 1 + StagingLeafRoom <= PathLimit

suite "default daemon endpoints fit the socket address limit":
  test "the user daemon's default endpoint fits under a long TMPDIR":
    when defined(linux):
      let tmp = longTempDir()
      withEnvironment(tmp):
        let endpoint = daemonProtocol.defaultUserDaemonEndpoint()
        checkpoint(endpoint)
        check endpoint.isAbsolute
        check fitsWithStaging(endpoint)
        check endpoint.extractFilename ==
          "repro-daemon-" & $daemonProtocol.currentUid() & ".sock"
    else:
      # macOS derives the runtime dir from the darwin per-user temp dir, not
      # TMPDIR; the getTempDir branch there is reached only when confstr is
      # unavailable, which this process cannot arrange.
      skip("macOS derives the runtime dir from the darwin per-user temp dir, not TMPDIR; Windows uses a named pipe")

  test "the user daemon's default endpoint is unchanged under a short TMPDIR":
    when defined(linux):
      withEnvironment("/tmp"):
        check daemonProtocol.defaultUserDaemonEndpoint() ==
          "/tmp" / ("repro-" & $daemonProtocol.currentUid()) /
            ("repro-daemon-" & $daemonProtocol.currentUid() & ".sock")
    else:
      skip("the TMPDIR-derived runtime dir is the Linux default only; macOS uses the darwin per-user temp dir, Windows a named pipe")

  test "the store daemon's default endpoint fits under a long TMPDIR":
    when defined(posix):
      let tmp = longTempDir()
      withEnvironment(tmp):
        let endpoint = storeProtocol.defaultDevEndpoint()
        checkpoint(endpoint)
        check endpoint.isAbsolute
        check fitsWithStaging(endpoint)
        check endpoint.extractFilename ==
          "reprostore-" & $storeProtocol.currentUid() & ".sock"
    else:
      skip("Windows endpoints are named pipes, which have no sun_path limit; the bound is POSIX-only")

  test "the store daemon's default endpoint is unchanged under a short TMPDIR":
    when defined(posix):
      withEnvironment("/tmp"):
        check storeProtocol.defaultDevEndpoint() ==
          "/tmp" / ("reprostore-" & $storeProtocol.currentUid() & ".sock")
    else:
      skip("Windows endpoints are named pipes, which have no sun_path limit; the bound is POSIX-only")

  test "an explicit endpoint override is respected verbatim":
    when defined(posix):
      let tmp = longTempDir()
      withEnvironment(tmp):
        let tooLong = tmp / "explicit-endpoint.sock"
        putEnv("REPRO_DAEMON_ENDPOINT", tooLong)
        putEnv("REPROSTORED_ENDPOINT", tooLong)
        check daemonProtocol.defaultUserDaemonEndpoint() == tooLong
        check storeProtocol.defaultDevEndpoint() == tooLong
    else:
      skip("Windows endpoints are named pipes, which have no sun_path limit; the bound is POSIX-only")
