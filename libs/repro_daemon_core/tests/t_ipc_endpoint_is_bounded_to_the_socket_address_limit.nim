## `bindIpcListener` binds every endpoint that fits the platform's Unix-socket
## address, and refuses one that does not by NAMING the limit.
##
## WHAT WENT WRONG. `bindIpcListener` publishes its endpoint atomically: it
## binds a private sibling `<dir>/.<pid>-<seq>.bind`, listens on it, and
## renames it onto the endpoint. That sibling's leaf is 13-17 bytes, LONGER
## than a short endpoint leaf such as `d.sock` (6). So an endpoint that fits
## the address limit could still fail -- at the STAGING bind, with
## `ValueError: socket path too long` from deep inside `std/net`, a message
## that names neither path nor limit. The limit is the one Nim's
## `nativesockets.makeUnixAddr` enforces: a path of
## `Sockaddr_un_path_length` bytes or more is refused, and that constant is
## 108 on Linux but 92 on macOS, below the kernel's 104. (reprobuild-pm
## `issues/2026-10-17-daemon-and-hcr-watch-socket-paths-are-not-bounded-to-
## the-platform-sun-path.md`.)
##
## WHAT THESE CASES ASSERT. Each path is padded to an exact byte length
## relative to the limit, so every case is a statement about one side of the
## boundary on THIS platform rather than about a lucky directory depth:
##
##   * an endpoint that fits, in a directory that leaves room for a compact
##     staging leaf but not the verbose one, binds, accepts a real
##     `connectIpc`, and leaves nothing but the endpoint behind;
##   * an endpoint one byte past the limit is refused with `IpcEndpointError`
##     naming the endpoint, its byte length and the limit, by both
##     `bindIpcListener` and `connectIpc`;
##   * an endpoint that fits exactly but leaves no room for ANY staging leaf
##     is refused with `IpcEndpointError` saying so, rather than binding
##     non-atomically.
##
## The limit is computed here from `std/posix` with the same formula the
## product uses (`repro_core/paths.unixSocketPathMaxLen`), and the two are
## checked to agree, so this file states the bound independently of the code
## under test.
##
## MOCK POLICY: no mocks. Real AF_UNIX sockets bound and dialled through the
## production `bindIpcListener` / `connectIpc`, in a real owner-only directory
## directly under `/tmp` (`shortSocketDirAtProcessExit`), removed at exit.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip

when defined(posix):
  import std/posix
  import repro_daemon_core/ipc
  from repro_core/paths import unixSocketPathMaxLen
  from repro_test_support/process_fixtures import shortSocketDirAtProcessExit

  const PathLimit = min(Sockaddr_un_path_length,
    sizeof(Sockaddr_un().sun_path)) - 1
    ## The longest Unix-socket path `std/net` binds or dials on this platform:
    ## `makeUnixAddr` refuses `path.len >= Sockaddr_un_path_length`, and copies
    ## `path.len + 1` bytes (the NUL) into `sun_path`. 107 on Linux, 91 on
    ## macOS.

  proc paddedDir(base: string; totalLen: int): string =
    ## A directory under ``base`` whose path is exactly ``totalLen`` bytes,
    ## created on disk. The padding is one component of ``p`` characters,
    ## which keeps it a single ``mkdir``.
    let pad = totalLen - base.len - 1
    doAssert pad > 0, "base directory " & base & " leaves no room to pad to " &
      $totalLen & " bytes"
    result = base / repeat('p', pad)
    doAssert result.len == totalLen
    createDir(result)

  proc entriesOf(dir: string): seq[string] =
    for kind, path in walkDir(dir):
      result.add(path.extractFilename)

suite "bindIpcListener is bounded to the platform's socket address limit":
  test "the product limit is the std/net limit":
    when defined(posix):
      check unixSocketPathMaxLen() == PathLimit
      # The reserve the default-endpoint derivations leave beside an endpoint
      # covers the LONGEST compact staging leaf, for any process and any
      # number of binds: `.` + high(int32) in base 36 + `.` + high(int64) in
      # base 36, stated as a literal so this does not restate the product.
      check IpcCompactStagingLeafReserve >= ".zik0zj.1y2p0ij32e8e7".len
    else:
      skip("Windows endpoints are named pipes, which have no sun_path limit; the bound is POSIX-only")

  test "an endpoint that fits binds even when the verbose staging leaf would not":
    when defined(posix):
      # Room for a 10-byte staging leaf next to the endpoint: the compact
      # leaf is `.` + pid in base 36 (at most 6 characters for any 31-bit
      # pid) + `.` + sequence in base 36 (1 character for the first 35 binds
      # of a process), so 9 bytes at most here. The VERBOSE leaf
      # `.<pid>-<seq>.bind` is 9 bytes plus the pid's decimal digits, so it
      # overflows whenever the pid has 2 or more digits.
      let dir = paddedDir(shortSocketDirAtProcessExit("ipc-"),
        PathLimit - 1 - 10)
      let endpoint = dir / "d.sock"
      let verboseLeaf = "." & $getCurrentProcessId() & "-1.bind"
      require endpoint.len <= PathLimit
      require (dir / verboseLeaf).len > PathLimit
      var listener = bindIpcListener(endpoint)
      defer: closeIpcListener(listener)
      # Listening AT THE PUBLISHED PATH, not merely bound somewhere: a real
      # client dials the endpoint and the listener accepts it.
      let client = connectIpc(endpoint)
      defer: closeIpcConn(client)
      check waitForClient(listener, 5_000)
      let server = acceptIpc(listener)
      closeIpcConn(server)
      # The staging sibling was renamed onto the endpoint, so nothing else is
      # left in the directory.
      check entriesOf(dir) == @["d.sock"]
    else:
      skip("Windows endpoints are named pipes, which have no sun_path limit; the bound is POSIX-only")

  test "an endpoint past the limit is refused with an error naming the limit":
    when defined(posix):
      let dir = paddedDir(shortSocketDirAtProcessExit("ipc-"),
        PathLimit + 1 - "/d.sock".len)
      let endpoint = dir / "d.sock"
      require endpoint.len == PathLimit + 1
      try:
        var listener = bindIpcListener(endpoint)
        closeIpcListener(listener)
        check false
      except IpcEndpointError as err:
        checkpoint(err.msg)
        check endpoint in err.msg
        check ($endpoint.len & " bytes") in err.msg
        check $PathLimit in err.msg
        check "socket path too long" notin err.msg
      except CatchableError as err:
        checkpoint("wrong error: " & $err.name & ": " & err.msg)
        check false
      check entriesOf(dir).len == 0
      # The dialling side names the limit too.
      try:
        let client = connectIpc(endpoint)
        closeIpcConn(client)
        check false
      except IpcEndpointError as err:
        checkpoint(err.msg)
        check endpoint in err.msg
        check ($endpoint.len & " bytes") in err.msg
        check $PathLimit in err.msg
        check "socket path too long" notin err.msg
    else:
      skip("Windows endpoints are named pipes, which have no sun_path limit; the bound is POSIX-only")

  test "an endpoint that leaves no room for a staging leaf is refused clearly":
    when defined(posix):
      # A 1-byte endpoint leaf at exactly the limit: every staging leaf is at
      # least 4 bytes (`.` + 1 + `.` + 1), so no sibling of it can fit.
      let dir = paddedDir(shortSocketDirAtProcessExit("ipc-"),
        PathLimit - "/s".len)
      let endpoint = dir / "s"
      require endpoint.len == PathLimit
      try:
        var listener = bindIpcListener(endpoint)
        closeIpcListener(listener)
        check false
      except IpcEndpointError as err:
        checkpoint(err.msg)
        check endpoint in err.msg
        check "staging" in err.msg
        check $PathLimit in err.msg
      except CatchableError as err:
        checkpoint("wrong error: " & $err.name & ": " & err.msg)
        check false
      check entriesOf(dir).len == 0
    else:
      skip("Windows endpoints are named pipes, which have no sun_path limit; the bound is POSIX-only")
