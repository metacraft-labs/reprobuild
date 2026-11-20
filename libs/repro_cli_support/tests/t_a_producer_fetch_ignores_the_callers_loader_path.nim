## A lock-pinned producer fetch runs the host's git without the caller's
## loader search path.
##
## ``fetchLockPinnedProducer`` runs the ``git`` it finds on ``PATH``, which on
## a CI runner is the distribution's ``/usr/bin/git``. A Nix dev shell on that
## runner exported an ``LD_LIBRARY_PATH`` naming Nix's krb5 and OpenSSL, built
## against a newer glibc than the runner's. git inherited it, its
## ``git-remote-https`` loaded those libraries in place of its own, and every
## fetch died:
##
##     /usr/lib/git-core/git-remote-https: /lib/x86_64-linux-gnu/libc.so.6:
##     version `GLIBC_2.38' not found (required by …-krb5-1.22.1-lib/…)
##
## Properties asserted, each separately falsifiable:
##
##   1. control: the poisoned ``LD_LIBRARY_PATH`` below really does stop this
##      host's git from starting, so the test can fail;
##   2. with that ``LD_LIBRARY_PATH`` in the caller's environment, the fetch
##      still materializes the pinned revision;
##   3. the caller's own environment is left as it was.
##
## The poison is a shared library named ``libc.so.6`` that defines none of
## glibc's symbol versions. Every dynamically linked git needs ``libc.so.6``,
## and ``LD_LIBRARY_PATH`` is searched before a DT_RUNPATH and before the
## default directories (https://man7.org/linux/man-pages/man8/ld.so.8.html), so
## a git that inherits it fails the way the runner's did: ``version
## `GLIBC_2.2.5' not found``. The remote is a ``file://`` repository built
## here, so no network is needed.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## The production ``fetchLockPinnedProducer`` runs the real ``git`` against a
## real local remote. The poisoned library is a real shared object loaded by
## the real dynamic loader.

import std/[os, osproc, streams, strtabs, strutils, unittest]

import repro_cli_support
import repro_core/process_streams
import repro_lock
import repro_test_support/reasoned_skip

const ProducerName = "loader-path-producer"

when defined(linux):
  proc runIn(dir: string; argv: openArray[string];
             env: StringTableRef = nil): tuple[output: string, code: int] =
    let p = startProcess(argv[0], workingDir = dir, args = argv[1 .. ^1],
      env = env, options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    # Read to EOF, not to the first short read of the pipe.
    result.output = drainStream(p.outputStream)
    result.code = p.waitForExit()

  suite "a lock-pinned producer fetch ignores the caller's loader path":
    test "a poisoned LD_LIBRARY_PATH does not reach the host's git":
      let git = findExe("git")
      let cc = findExe(getEnv("CC", "cc"))
      if git.len == 0 or cc.len == 0:
        # The case runs the real git and builds the poison with the compiler.
        skip("git or a C compiler (cc / $CC) is not on PATH")
      else:
        let scratch = getTempDir() /
          ("t_producer_fetch_loader_path_" & $getCurrentProcessId())
        removeDir(scratch)
        createDir(scratch)
        defer: removeDir(scratch)

        # The producer: a real repository with one commit.
        let remote = scratch / "producer"
        createDir(remote)
        writeFile(remote / "repro.nim", "# producer\n")
        let identity = @["-c", "user.name=t", "-c", "user.email=t@example.com",
          "-c", "commit.gpgsign=false"]
        for argv in [@[git, "init", "--quiet"], @[git, "add", "repro.nim"],
                     @[git] & identity & @["commit", "--quiet", "-m", "p"]]:
          let step = runIn(remote, argv)
          checkpoint(step.output)
          require step.code == 0
        let head = runIn(remote, [git, "rev-parse", "HEAD"])
        require head.code == 0
        let revision = head.output.strip()

        # The poison: a `libc.so.6` with a version node glibc never defines.
        let poison = scratch / "poison"
        createDir(poison)
        writeFile(scratch / "poison.map",
          "REPRO_POISON_1 { global: repro_poison; local: *; };\n")
        writeFile(scratch / "poison.c", "int repro_poison(void) { return 0; }\n")
        let built = runIn(scratch, [cc, "-shared", "-fPIC", "-nostdlib",
          "-Wl,-soname,libc.so.6",
          "-Wl,--version-script=" & (scratch / "poison.map"),
          "-o", poison / "libc.so.6", scratch / "poison.c"])
        checkpoint(built.output)
        require built.code == 0

        # (1) Control: this host's git does not start with it.
        var poisoned = newStringTable(modeCaseSensitive)
        for key, value in envPairs():
          poisoned[key] = value
        poisoned["LD_LIBRARY_PATH"] = poison
        let control = runIn(scratch, [git, "--version"], poisoned)
        checkpoint("control: " & control.output)
        require control.code != 0

        # (2) The fetch, with the poison in the caller's environment.
        let workspace = scratch / "consumer"
        createDir(workspace)
        let dep = LockedDep(
          name: ProducerName,
          coordinates: Coordinates(kind: ckVcs,
            url: "file://" & remote, revision: revision))
        let hadPath = existsEnv("LD_LIBRARY_PATH")
        let oldPath = getEnv("LD_LIBRARY_PATH")
        putEnv("LD_LIBRARY_PATH", poison)
        var root, message: string
        try:
          root = fetchLockPinnedProducer(dep, workspace)
        except OSError as e:
          message = e.msg
        finally:
          # (3) is checked before the environment is restored.
          check getEnv("LD_LIBRARY_PATH") == poison
          if hadPath: putEnv("LD_LIBRARY_PATH", oldPath)
          else: delEnv("LD_LIBRARY_PATH")
        checkpoint("error: " & message)
        check message.len == 0
        # An empty root would make the reads below answer for the enclosing
        # checkout instead.
        require root.len > 0
        check root == workspace / ".repro" / "cross-repo-producers" /
          ProducerName / revision
        check fileExists(root / "repro.nim")
        let fetched = runIn(root, [git, "rev-parse", "HEAD"])
        check fetched.code == 0
        check fetched.output.strip() == revision
else:
  discard # ELF loader regression: LD_LIBRARY_PATH is a Linux loader control.
