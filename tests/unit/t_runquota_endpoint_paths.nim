import std/[os, sequtils, strutils, tempfiles, unittest]
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

when defined(posix):
  # POSIX only: `createPrivateRunQuotaEndpoint` makes a filesystem
  # rendezvous directory, which a Windows named pipe has no equivalent of.
  proc modeOf(path: string): int =
    var info: Stat
    doAssert lstat(path.cstring, info) == 0
    int(info.st_mode) and 0o7777

  proc shortTempRoot(prefix: string): string =
    ## A temp root directly under ``/tmp``. These cases test what happens
    ## when the root FITS, so it must fit whatever the suite's TMPDIR is: a
    ## root under a long TMPDIR (the persistent runner's
    ## ``/var/lib/github-runner-work/<runner>/.cache/reprobuild-test-tmp/<n>``)
    ## is itself past the socket-path limit, and the code under test then
    ## correctly relocates to ``/tmp`` -- which is the case below, not these.
    createTempDir(prefix, "", "/tmp")

  suite "fresh private RunQuota endpoints":
    test "every call creates a new owner-only directory nobody held before":
      let root = shortTempRoot("repro-rq-fresh-")
      defer: removeDir(root)
      withTempRoot(root):
        let first = createPrivateRunQuotaEndpoint("caller-")
        let second = createPrivateRunQuotaEndpoint("caller-")
        checkpoint(first & " / " & second)
        check first.parentDir != second.parentDir
        check first.parentDir.parentDir == root
        check first.extractFilename == "runquota.sock"
        check first.parentDir.extractFilename.startsWith("caller-")
        check dirExists(first.parentDir)
        check modeOf(first.parentDir) == 0o700
        # The socket itself is the daemon's to bind.
        check not fileExists(first) and not symlinkExists(first)

    test "a directory left at a predictable name is never chosen":
      # The defect a pid-derived name had: a leftover from an earlier holder
      # of the same name. Whatever is already there, the result is new.
      let root = shortTempRoot("repro-rq-stale-")
      defer: removeDir(root)
      withTempRoot(root):
        createDir(root / "caller-")
        for _ in 0 ..< 32:
          let endpoint = createPrivateRunQuotaEndpoint("caller-")
          check endpoint.parentDir != root / "caller-"
          check walkDir(endpoint.parentDir).toSeq.len == 0

    test "the umask cannot narrow the exact mode the private policy requires":
      let root = shortTempRoot("repro-rq-umask-")
      defer: removeDir(root)
      let previous = umask(Mode(0o277))
      defer: discard umask(previous)
      withTempRoot(root):
        check modeOf(createPrivateRunQuotaEndpoint("caller-").parentDir) == 0o700

    test "a temp root too long for a socket moves the directory under /tmp":
      withTempRoot("/tmp/" & repeat('x', 180)):
        let endpoint = createPrivateRunQuotaEndpoint("caller-")
        defer: removeDir(endpoint.parentDir)
        checkpoint(endpoint)
        check endpoint.len <= PathLimit
        check endpoint.parentDir.parentDir == "/tmp"
        check endpoint.parentDir.extractFilename.startsWith(
          "repro-rq-" & $getuid() & "-")
        check modeOf(endpoint.parentDir) == 0o700

    test "a missing temp root is an error, not a silent relocation":
      let root = shortTempRoot("repro-rq-missing-")
      removeDir(root)
      withTempRoot(root):
        expect OSError:
          discard createPrivateRunQuotaEndpoint("caller-")
