## `repro watch` refuses an HCR agent socket path that does not fit the
## platform's Unix-socket address, naming the flag, the path and the limit.
##
## WHAT WENT WRONG. `initHcrWatchSession` hashes a RELATIVE
## `--hcr-agent-socket` into `/tmp` once its resolved form reaches 80 bytes,
## but handed an ABSOLUTE path to `bindUnix` unchecked. `std/net` refuses a
## path of `Sockaddr_un_path_length` bytes or more -- 108 on Linux, 92 on
## macOS -- so a long absolute path (two e2e tests produced 93-94-byte ones
## under the suite TMPDIR on macOS) failed with a bare `socket path too long`
## naming neither the path, the flag nor the limit. (reprobuild-pm
## `issues/2026-10-17-daemon-and-hcr-watch-socket-paths-are-not-bounded-to-
## the-platform-sun-path.md`.)
##
## WHAT THESE CASES ASSERT. The real CLI, in direct mode, given an absolute
## socket path one byte past the limit -- through the legacy
## `--hcr-agent-socket` flag and through a `--hcr-target=NAME:SOCKET:...`
## binding, which reach the same session initialisation -- exits non-zero
## BEFORE any build, with a message naming the flag, the path, its byte length
## and this platform's limit, and creates no socket.
##
## MOCK POLICY: no mocks. The graph-built `repro` binary runs as a child
## process against an empty project directory; the refusal happens before
## anything is built, so no toolchain or RunQuota daemon is needed.

import std/[os, osproc, streams, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

when defined(posix):
  import std/posix
  from repro_test_support import reproBinaryPath, requireBinary

  const PathLimit = min(Sockaddr_un_path_length,
    sizeof(Sockaddr_un().sun_path)) - 1
    ## The longest Unix-socket path `std/net` binds on this platform.

  proc runWatch(reproBin, projectRoot: string;
                args: openArray[string]): tuple[output: string; code: int] =
    ## ``repro watch`` with ``args`` in ``projectRoot``, stdout and stderr
    ## merged. Bounded so a regression that binds and starts watching cannot
    ## hang the suite: the refusal is expected within seconds.
    var process = startProcess(reproBin,
      args = @["watch", "--daemon=off", "--max-cycles=1"] & @args,
      workingDir = projectRoot,
      options = {poStdErrToStdOut})
    defer: process.close()
    let code = process.waitForExit(timeout = 120_000)
    if process.running:
      process.kill()
      discard process.waitForExit()
    (process.outputStream.readAll(), code)

suite "repro watch bounds the HCR agent socket path":
  test "an over-long absolute agent socket is refused naming the limit":
    when defined(posix):
      let reproBin = requireBinary(reproBinaryPath(), "reprobuild.apps.repro")
      let tempRoot = createTempDir("repro-hcr-sock-limit", "")
      defer: removeDir(tempRoot)
      let projectRoot = tempRoot / "project"
      createDir(projectRoot)
      let socketPath = "/tmp/" & repeat('h', PathLimit + 1 - "/tmp/.sock".len) &
        ".sock"
      require socketPath.len == PathLimit + 1
      let artifacts = tempRoot / "hcr"

      for (flag, args) in [
          ("--hcr-agent-socket", @["--hcr-agent-socket=" & socketPath,
            "--hcr-artifacts=" & artifacts]),
          ("--hcr-target", @["--hcr-target=alpha:" & socketPath & ":" &
            artifacts])]:
        let run = runWatch(reproBin, projectRoot, args)
        checkpoint(flag & " exit=" & $run.code & "\n" & run.output)
        check run.code != 0
        check flag in run.output
        check socketPath in run.output
        check ($socketPath.len & " bytes") in run.output
        check $PathLimit in run.output
        check "socket path too long" notin run.output
        check not fileExists(socketPath)
    else:
      skip("Windows HCR agents use named pipes, which have no sun_path limit; the bound is POSIX-only")
