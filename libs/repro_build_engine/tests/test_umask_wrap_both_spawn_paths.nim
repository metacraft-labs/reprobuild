## M9.R.36.3 — verify the umask-022 wrap applies on BOTH the bypass and
## runquota helper-spawn / inline-runquota paths.
##
## M9.R.35.1 lifted ``umask 022`` into ``startBypassRunQuotaProcess`` to
## close a qmlcachegen mode-corruption channel (Qt6 ``QSaveFile`` ->
## ``QTemporaryFileEngine`` -> kernel umask-on-mkstemp drift producing
## ``.qmltypes`` / ``.cpp`` files at modes ``0300`` / ``0254`` / ``0044``
## / ``0204``, which then trip ``cc1plus: fatal error: Permission
## denied``).  The pin was bypass-only — a daemon-mode build that takes
## the runquota helper path forwarded ``command.argv`` straight through
## to the helper's ``launchProcess`` call site, leaving the umask drift
## channel intact.
##
## M9.R.36.3 factored ``umaskWrappedArgv`` out and applied it to BOTH
## the helper-spawn argv (via ``startRunQuotaProcess`` ->
## ``ReproCommandSpec.argv``) AND the inline-runquota batch path (via
## ``runQuotaCommand`` -> the staged ``commands[k]`` array consumed by
## ``offerWithRunQuotaBatch``).  This test pins:
##
##   1. ``umaskWrappedArgv`` emits the canonical ``/bin/sh -c "umask
##      022 && <quoted argv>"`` 3-element argv on POSIX.
##   2. The wrap is the identity transform on Windows (where umask
##      doesn't apply and ``/bin/sh`` isn't a host dep).
##   3. Each argv element is shell-quoted via ``quoteShell`` so a
##      tool name with spaces / glob chars survives the wrap.
##   4. Empty argv is preserved (identity transform).
##
## In-Process-Monitor-Hosting HM-4 ADDS TWO CASES BELOW, and they are here
## rather than in a file of their own because they pin the SAME two
## properties for the launch path that no longer has a wrapper shell to
## carry them.
##
## When the engine hosts io-mon itself (the L1 bypass path), the monitored
## child is a direct child of the engine and the argv is the recipe's own —
## no ``/bin/sh -c "umask 022 && …"`` in front of it, because a wrapper
## shell would now be INSIDE the monitored tree and its reads would land in
## the action's dependency evidence. So the two things that wrapper used to
## provide are re-established around the spawn instead
## (``beginMonitorSpawnContext``):
##
##   5. the 0022 mask, set on the engine and inherited across ``fork``;
##   6. per-action stdout/stderr, by pointing descriptors 1 and 2 at two
##      capture files — io-mon spawns with ``poParentStreams``, so without
##      this the child would write to the ENGINE's terminal and the
##      action's ``stdout`` / ``stderr`` would come back empty.
##
## Both are asserted on the real thing: a real monitored build, a real
## child, real files on disk, and for (5) a deliberately hostile ambient
## umask so the assertion cannot pass by accident on a machine whose
## default already happens to be 0022.
##
## NO MOCKS. The engine's own ``ActionResult`` and the filesystem are the
## oracles.

import std/[os, strutils, unittest]
when defined(posix):
  from std/posix import Mode, umask, dup, dup2, close

import repro_build_engine
from repro_test_support import prepareMonitorTools, testCaseScratchSlug

suite "M9.R.36.3 umask-022 sh-wrap":
  test "POSIX wrap shape: 3-element /bin/sh -c argv":
    let wrapped = umaskWrappedArgv(@["echo", "hello"])
    when defined(posix):
      check wrapped.len == 3
      check wrapped[0] == "/bin/sh"
      check wrapped[1] == "-c"
      check wrapped[2].startsWith("umask 022 && ")
      # Verify the wrapped command tail contains both argv elements,
      # quoted via quoteShell. We don't pin the exact quoting rules
      # because they differ per platform sub-shell, but the substrings
      # MUST survive verbatim.
      check "echo" in wrapped[2]
      check "hello" in wrapped[2]
    else:
      # Windows: identity.
      check wrapped == @["echo", "hello"]

  test "POSIX wrap shell-quotes spaces":
    let wrapped = umaskWrappedArgv(@["cc", "my file.c"])
    when defined(posix):
      check wrapped.len == 3
      check wrapped[0] == "/bin/sh"
      check wrapped[1] == "-c"
      check wrapped[2].startsWith("umask 022 && ")
      # quoteShell on POSIX single-quotes elements with spaces.  Either
      # ``'my file.c'`` or escaped ``my\ file.c`` is acceptable; just
      # check the literal substring containing the space is preserved.
      check "my file.c" in wrapped[2]
    else:
      check wrapped == @["cc", "my file.c"]

  test "empty argv is identity":
    let wrapped = umaskWrappedArgv(@[])
    check wrapped.len == 0

  test "single-element argv is wrapped":
    let wrapped = umaskWrappedArgv(@["true"])
    when defined(posix):
      check wrapped.len == 3
      check wrapped[0] == "/bin/sh"
      check wrapped[1] == "-c"
      check wrapped[2] == "umask 022 && true"
    else:
      check wrapped == @["true"]

when defined(linux) or defined(macosx):
  ## HM-4 — the same two properties, for the launch path that has no
  ## wrapper shell any more.

  proc hostedConfig(cacheRoot: string): BuildEngineConfig =
    ## The L1 bypass path with a monitor driver wired, which is exactly the
    ## combination the engine hosts in-process.
    let tools = prepareMonitorTools(getCurrentDir(),
      getCurrentDir() / "build" / "test-umask-hm4", "umask-hm4")
    putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
    BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: tools.monitorCliPath,
      monitorCliPath: tools.monitorCliPath,
      monitorCliArgs: tools.monitorCliArgs,
      maxParallelism: 1'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      bypassRunQuota: true,
      # In-process hosting is opt-in and off by default; these cases are
      # ABOUT the hosted path, so they ask for it explicitly.
      hostMonitorInProcess: true)

  proc hm4ScratchRoot(name: string): string =
    let root = absolutePath("build" / "test-tmp" /
      "test_umask_wrap_both_spawn_paths" / testCaseScratchSlug() / name)
    if dirExists(root):
      removeDir(root)
    createDir(root)
    root

  suite "HM-4 in-process monitor host":
    test "a hosted action's output carries the canonical 0022 mask":
      ## MUTATION TARGET: delete the ``umask(Mode(0o022))`` /
      ## ``umask(ctx.savedMask)`` pair in ``beginMonitorSpawnContext`` /
      ## ``endMonitorSpawnContext`` and this case reddens on the permission
      ## check — the child inherits the engine's 0077 and writes 0600.
      let root = hm4ScratchRoot("umask")
      let work = root / "work"
      createDir(work)
      let cacheRoot = root / "cache"
      let outName = "hosted-out.txt"

      # A HOSTILE ambient mask, so a pass cannot be the machine's default.
      let previousMask = umask(Mode(0o077))
      var run: BuildRunResult
      try:
        run = runBuild(graph([action("hm4-umask",
          @["sh", "-c", "printf hosted > " & quoteShell(outName)],
          cwd = work,
          outputs = [outName],
          governingLockIdentity = lockIdentityOutsideSolvedGraph())]),
          hostedConfig(cacheRoot))
      finally:
        discard umask(previousMask)

      check run.results.len == 1
      if run.results[0].status != asSucceeded:
        echo "hm4-umask failed exit=", run.results[0].exitCode,
          " stderr=", run.results[0].stderr
      check run.results[0].status == asSucceeded
      check fileExists(work / outName)
      # 0644 — readable by group and other, writable by neither. Under the
      # ambient 0077 above, an unmasked child produces 0600.
      let perms = getFilePermissions(work / outName)
      check fpGroupRead in perms
      check fpOthersRead in perms
      check fpGroupWrite notin perms
      check fpOthersWrite notin perms

    test "a hosted action's stdout and stderr reach its ActionResult":
      ## MUTATION TARGET: delete the two ``dup2`` calls in
      ## ``beginMonitorSpawnContext`` and this case reddens — the child
      ## writes to the ENGINE's own descriptors (visible in this test's own
      ## output) and both payloads come back empty.
      ##
      ## The two streams are checked SEPARATELY on purpose: io-mon's own
      ## ``captureChildStdio`` merges them, and a host that used it would
      ## satisfy "stderr is non-empty" while destroying the distinction the
      ## engine reports to the user.
      let root = hm4ScratchRoot("stdio")
      let work = root / "work"
      createDir(work)
      let cacheRoot = root / "cache"

      let run = runBuild(graph([action("hm4-stdio",
        @["sh", "-c",
          "echo hm4-on-stdout; echo hm4-on-stderr >&2; exit 3"],
        cwd = work,
        cacheable = false,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())]),
        hostedConfig(cacheRoot))

      check run.results.len == 1
      let res = run.results[0]
      check res.status == asFailed
      check res.exitCode == 3
      check "hm4-on-stdout" in res.stdout
      check "hm4-on-stderr" in res.stderr
      # And not crossed over: stderr must not swallow stdout.
      check "hm4-on-stderr" notin res.stdout
      check "hm4-on-stdout" notin res.stderr

    test "a hosted action reads EOF on stdin, not the engine's own":
      ## MUTATION TARGET: delete the ``/dev/null`` open and the descriptor-0
      ## ``dup2`` in ``beginMonitorSpawnContext`` and this case reddens on
      ## ``res.stdout`` — the child reads the line planted below instead of
      ## seeing EOF.
      ##
      ## WHY THIS IS A CORRECTNESS CASE. Every other launch path hands the
      ## child ``/dev/null`` on descriptor 0: RunQuota's POSIX backend opens
      ## it explicitly before ``execvp``. io-mon spawns with
      ## ``poParentStreams``, so a hosted child inherits the ENGINE's stdin —
      ## in a real ``repro build``, the user's terminal. An action that reads
      ## stdin would then block the whole build on a keystroke, or consume
      ## one meant for the user.
      ##
      ## A HOSTILE AMBIENT STDIN, for the same reason the umask case above
      ## sets 0077: under a test runner descriptor 0 is often already
      ## /dev/null or a closed pipe, and the assertion would pass without the
      ## product doing anything. Descriptor 0 is pointed at a real file with a
      ## real line in it for the duration of the build, so "EOF" can only come
      ## from the redirect under test.
      let root = hm4ScratchRoot("stdin")
      let work = root / "work"
      createDir(work)
      let cacheRoot = root / "cache"

      let plantedPath = root / "planted-stdin.txt"
      writeFile(plantedPath, "PLANTED-STDIN-LINE\n")

      var planted: File
      check open(planted, plantedPath, fmRead)
      let savedStdin = dup(cint(0))
      check savedStdin >= 0
      discard dup2(cint(getFileHandle(planted)), cint(0))

      var run: BuildRunResult
      try:
        run = runBuild(graph([action("hm4-stdin",
          @["sh", "-c",
            "if IFS= read -r line; then echo \"READ:$line\"; " &
              "else echo NOTHING-ON-STDIN; fi"],
          cwd = work,
          cacheable = false,
          governingLockIdentity = lockIdentityOutsideSolvedGraph())]),
          hostedConfig(cacheRoot))
      finally:
        discard dup2(savedStdin, cint(0))
        discard close(savedStdin)
        close(planted)

      check run.results.len == 1
      let res = run.results[0]
      if "PLANTED-STDIN-LINE" in res.stdout:
        echo "hm4-stdin: the hosted child read the ENGINE's stdin: ",
          res.stdout
      check "NOTHING-ON-STDIN" in res.stdout
      check "PLANTED-STDIN-LINE" notin res.stdout
      check res.status == asSucceeded
