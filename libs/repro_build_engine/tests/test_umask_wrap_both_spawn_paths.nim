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
## HM-6 ADDS A SEVENTH PROPERTY, and it is the inverse of the other three:
##
##   7. hosting is OFF in every shipped configuration.
##
## It is here rather than in a file of its own because this is where the
## hosted path's properties already live, and because the three cases above
## are the reason it is needed: they all REQUEST hosting, so between them
## and `t_every_launch_path_is_monitored` — which requests it for all four
## launch paths deliberately, to keep the negative half of its oracle
## honest — the whole suite would stay green if the shipped default were
## reversed. See the case for what that would cost.
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
      monitorHosting: mhmWhereSupported)

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

    test "in-process hosting is off in every shipped configuration":
      ## In-Process-Monitor-Hosting HM-6. The three cases above all ASK for
      ## hosting, because they are about it. Nothing anywhere asserted that
      ## the shipped default does not.
      ##
      ## WHY THAT MATTERS ENOUGH TO BE ITS OWN CASE. HM-6 measured hosting
      ## against the CLI wrapper on a real parallel build: indistinguishable
      ## at the default parallelism (median ratio 1.013 against a +-4%
      ## within-arm spread, reproduced independently at 0.988 against a
      ## wider one) and measurably SLOWER on cheap actions — 1.5-2.4x on one
      ## machine, 1.1-1.9x on a more loaded one, always in that direction.
      ## So the
      ## default is a decision, not an accident — and it is a decision no
      ## test could see being reversed. `t_every_launch_path_is_monitored`
      ## sets the field to `mhmWhereSupported` for all four launch paths on
      ## purpose (it was a bare `true` before P3 made the field an enum), so it
      ## stays green either way; production takes L3/L3b, which cannot host
      ## at all, so it would not notice; and what WOULD change is every
      ## `--no-runquota` build and every nested test build in the suite,
      ## which would silently start paying the cheap-action cost and would
      ## acquire a stdout/stderr capture whose PEAK is unbounded (the hosted
      ## path redirects descriptors 1 and 2 into files nothing truncates
      ## until the action ends, where RunQuota's backend bounds capture in
      ## memory as it drains). A one-word diff, no failing test, no
      ## diagnostic.
      ##
      ## Two independent halves, because they fail differently:
      ##
      ## MUTATION TARGET A — add `monitorHosting: mhmWhereSupported` to
      ## `defaultBuildEngineConfig`, or reorder `MonitorHostingMode` so that
      ## `mhmNever` is no longer its zero value: the first two checks redden.
      ## MUTATION TARGET B — set the field at any construction site in any
      ## shipped source under `libs/` or `apps/` (for instance
      ## `repro_profile_compile/edge.nim`, which is on the bypass path and so
      ## is the one where it would actually take effect): the last check
      ## reddens and names the file.
      ##
      ## In-Process-Monitor-Hosting P3 turned the field from a `bool` into
      ## `MonitorHostingMode`, and the scan below follows the FIELD NAME, so
      ## it covers `mhmWhereSupported` and `mhmRequired` alike — a shipped
      ## site cannot request either one without writing `monitorHosting`.
      check defaultBuildEngineConfig(getCurrentDir() / "build" /
        "test-tmp" / "hm6-default").monitorHosting == mhmNever
      # And not merely because `defaultBuildEngineConfig` omits it: a bare
      # object must be off too, since most construction sites in the tree
      # build one field-by-field rather than starting from the default.
      check BuildEngineConfig(cacheRoot: "unused").monitorHosting == mhmNever

      # No shipped construction site enables it. This is a source scan and it
      # RAISES rather than passing when it cannot read what it is scanning —
      # a scan that silently found nothing is exactly how a coverage gate
      # reports a green run it did not do.
      #
      # THE SCAN COVERS EVERY SHIPPED SOURCE, not just the CLI. An earlier
      # version read `repro_cli_support.nim` plus `apps/` only, and adding
      # `monitorHosting: mhmWhereSupported` to
      # `repro_profile_compile/edge.nim`'s `BuildEngineConfig(` — a shipped
      # construction site that already sets `bypassRunQuota: true`, i.e. the
      # ONE launch path that can host — reddened nothing. A config no test
      # covers, on the only path where the field has any effect, is exactly
      # the silent flip this case exists to refuse.
      const Field = "monitorHosting"
      # The module that DECLARES the field names it in its own type, in three
      # comments and in the hosting decision, so it cannot be scanned for a
      # bare mention. It needs no scanning: the only config it constructs is
      # `defaultBuildEngineConfig`, and the first check above pins that one at
      # RUNTIME, which is stronger than a source match.
      let fieldOwner = getCurrentDir() / "libs" / "repro_build_engine" /
        "src" / "repro_build_engine.nim"
      var enablingSites: seq[string] = @[]
      var scanned = 0
      let cliSource = getCurrentDir() / "libs" / "repro_cli_support" / "src" /
        "repro_cli_support.nim"
      if not fileExists(cliSource):
        raise newException(IOError,
          "cannot scan " & cliSource & " for " & Field &
          ": this case must run from the repository root")
      if not fileExists(fieldOwner):
        raise newException(IOError,
          "cannot resolve the field's declaring module at " & fieldOwner &
          ": this case must run from the repository root")
      var sources: seq[string] = @[]
      for root in ["libs", "apps"]:
        for path in walkDirRec(getCurrentDir() / root):
          if not path.endsWith(".nim"): continue
          # A test may legitimately ask for hosting; three of them do, and the
          # three cases above are among them.
          if ("/tests/" in path) or sameFile(path, fieldOwner): continue
          sources.add path
      for path in sources:
        inc scanned
        for line in readFile(path).splitLines():
          if Field in line:
            enablingSites.add path.extractFilename & ": " & line.strip()
      # NOT VACUOUS, and `scanned > 1` is not enough to say so: a walk that
      # went to the wrong tree, or an exclusion rule that grew until it
      # excluded everything, still scans hundreds of files and still reports a
      # pass. So name the sources that MUST have been read — the CLI, and the
      # two shipped libraries outside it that build a `BuildEngineConfig`
      # field by field, one of which sets `bypassRunQuota: true`.
      var missed: seq[string] = @[]
      for required in [cliSource,
                       getCurrentDir() / "libs" / "repro_profile_compile" /
                         "src" / "repro_profile_compile" / "edge.nim",
                       getCurrentDir() / "libs" / "repro_dev_env_engine" /
                         "src" / "repro_dev_env_engine.nim"]:
        var seen = false
        for path in sources:
          if sameFile(path, required):
            seen = true
            break
        if not seen:
          missed.add required
      if missed.len > 0:
        echo "the ", Field, " scan did not reach:\n  ", missed.join("\n  ")
      check missed.len == 0
      check scanned > 1
      if enablingSites.len > 0:
        echo "a shipped construction site names ", Field, ":\n  ",
          enablingSites.join("\n  "),
          "\n  HM-6 measured hosting as no faster at the default ",
          "parallelism on a real build, and consistently slower on cheap ",
          "actions, and it is ",
          "reachable on the bypass path only. Enabling it in the product ",
          "needs the HM-6 verdict revisited, not a config edit."
      check enablingSites.len == 0
