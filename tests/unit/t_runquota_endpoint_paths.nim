import std/[os, strutils, unittest]
import repro_core/paths

when defined(posix):
  import std/posix

  const PathLimit = min(Sockaddr_un_path_length,
    sizeof(Sockaddr_un().sun_path)) - 1
    ## The longest Unix-socket path `std/net` binds or dials: `makeUnixAddr`
    ## refuses `path.len >= Sockaddr_un_path_length` and copies the NUL too.
    ## 107 on Linux, 91 on macOS. Stated here rather than taken from
    ## `unixSocketPathMaxLen`, so the bound is checked independently of the
    ## code under test, which is also checked to agree with it.

template withTempRoot(root: string; body: untyped) =
  let wasSet = existsEnv("TMPDIR")
  let previous = getEnv("TMPDIR")
  putEnv("TMPDIR", root)
  try:
    body
  finally:
    if wasSet: putEnv("TMPDIR", previous)
    else: delEnv("TMPDIR")

suite "RunQuota endpoint paths":
  test "short paths preserve the existing transport contract":
    when defined(windows):
      check runquotaEndpointPath("test/name\\child") ==
        "\\\\.\\pipe\\runquotad-test_name_child"
    else:
      withTempRoot("/tmp"):
        check runquotaEndpointPath("test-caller") ==
          "/tmp/test-caller/runquota.sock"

  test "long temp roots retain bounded independent private rendezvous paths":
    when defined(posix):
      withTempRoot("/tmp/" & repeat('x', 180)):
        let first = runquotaEndpointPath("caller-1")
        let second = runquotaEndpointPath("caller-2")
        checkpoint(first)
        check first.len <= PathLimit
        check second.len <= PathLimit
        check first.parentDir != second.parentDir
        check first.parentDir != "/tmp"
        check first.isAbsolute
        check first == runquotaEndpointPath("caller-1")
    else:
      skip()

  test "the terminating NUL counts against the native socket address budget":
    when defined(posix):
      check unixSocketPathMaxLen() == PathLimit
      let limit = PathLimit
      let root = "/tmp/" & repeat('x', limit - "/tmp//caller/runquota.sock".len)
      withTempRoot(root):
        let exact = root / "caller" / "runquota.sock"
        require exact.len == limit
        check runquotaEndpointPath("caller") == exact
      withTempRoot(root & "x"):
        let overflow = runquotaEndpointPath("caller")
        check overflow.len <= limit
        check overflow != (root & "x") / "caller" / "runquota.sock"
    else:
      skip()

  test "long callers are not truncated to the same rendezvous":
    when defined(posix):
      withTempRoot("/tmp"):
        let common = repeat('n', 200)
        let first = runquotaEndpointPath(common & "a")
        let second = runquotaEndpointPath(common & "b")
        check first.len <= PathLimit
        check first.parentDir != second.parentDir

    else:
      skip()

  test "different long temp roots remain distinct for the same caller":
    when defined(posix):
      var first: string
      withTempRoot("/tmp/" & repeat('a', 180)):
        first = runquotaEndpointPath("caller")
      withTempRoot("/tmp/" & repeat('b', 180)):
        check first.parentDir != runquotaEndpointPath("caller").parentDir
    else:
      skip()

  test "UTF-8 paths are bounded in bytes rather than characters":
    when defined(posix):
      withTempRoot("/tmp/" & repeat("\xc3\xa9", 60)):
        check runquotaEndpointPath("caller").len <= PathLimit
    else:
      skip()
