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
      ## is the one where it would actually take effect): the scans below
      ## redden and name the file.
      ##
      ## In-Process-Monitor-Hosting P3 turned the field from a `bool` into
      ## `MonitorHostingMode`, so there are now two ways to say "on" and the
      ## scans below cover both: the FIELD NAME, which no shipped file but
      ## the CLI may write at all, and the two ENABLING MODE names, which no
      ## shipped file may write under any circumstances.
      ##
      ## WHAT P1(b) CHANGED HERE, AND WHY IT IS A RELAXATION AND NOT A HOLE.
      ## P1 asked what this field is FOR and the answer taken was (b): give
      ## it an operator surface — `--monitor-hosting=never|where-supported|
      ## required` plus `REPROBUILD_MONITOR_HOSTING` — so the HM-6 verdict can
      ## be re-checked on other hardware through the CLI instead of by writing
      ## a harness. P1 also says, correctly, that adding the surface "would
      ## need the new pin's third assertion relaxed deliberately, which is the
      ## right shape: adding the surface should be a visible edit to the test
      ## that says there is none."
      ##
      ## This is that edit. The old third assertion was "no shipped source
      ## under libs/ or apps/ so much as NAMES the field", which the plumbing
      ## necessarily violates. It is replaced by TWO assertions that between
      ## them still pin exactly what mattered:
      ##
      ##   1. NO shipped source, WITH NO EXCEPTIONS AT ALL, so much as NAMES
      ##      an enabling mode literal. This is the "silent flip" refusal and
      ##      it has no allowlist — not even for the plumbing file, which is
      ##      why the parser was put in the field's OWN module
      ##      (`parseMonitorHostingMode`): the CLI never spells
      ##      `mhmWhereSupported` or `mhmRequired`, so it does not need an
      ##      exemption from this one. The rule is deliberately about the
      ##      MODE ALONE rather than about the mode next to the field — see
      ##      `EnablingModes` below for the two one-line edits that walk past
      ##      the weaker version, both of them measured.
      ##   2. The only shipped file that names the field AT ALL is the one
      ##      named below, by path. A SECOND shipped site — even one that
      ##      assigns a variable rather than a literal, which assertion 1
      ##      cannot see — reddens here. The permission is a named file, not
      ##      a widened rule: "anything under repro_cli_support" or "any line
      ##      that also mentions a flag" would have re-admitted exactly the
      ##      class this case exists to refuse.
      ##
      ## And the allowlist is itself pinned NOT VACUOUS: the file it names has
      ## to actually carry the surface (assertion 3 below). An allowlist entry
      ## whose plumbing was deleted would otherwise sit there permanently
      ## permitting a mention nobody is making.
      ##
      ## THE SCAN IS STILL `libs/` + `apps/` AND DELIBERATELY NOT
      ## `benchmarks/`. `benchmarks/suites/monitor-overhead/hm6_acceptance.nim`
      ## sets the field on purpose — it is the harness that MEASURED the
      ## verdict, and it has to drive both arms to do that. It is not a
      ## shipped configuration and this case's name is about shipped
      ## configurations, so widening the walk would mean adding a second
      ## allowlist entry for a file whose whole job is to enable hosting.
      ## Recorded here rather than left to be re-derived.
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
      # The mode literals that TURN IT ON. NAMING ONE AT ALL is the trigger,
      # not naming one next to the field — and that is the whole reason the
      # P1(b) parser was put in the field's own module rather than beside the
      # CLI's other flag parsers.
      #
      # WHY NOT "the field AND a mode on the same line", which is the obvious
      # rule. Because it is a rule about LINES, and both ways around it are
      # ordinary Nim that nobody would look at twice:
      #
      #   let wanted = mhmRequired      # names a mode, not the field
      #   config.monitorHosting = wanted    # names the field, not a mode
      #
      #   config.monitorHosting =       # names the field, not a mode
      #     mhmRequired                 # names a mode, not the field
      #
      # Neither is caught by a line-local conjunction. In the ONE file the
      # allowlist below permits to name the field, neither would be caught by
      # anything else either — which would leave the "no exceptions" claim
      # true only of the spelling nobody uses to be sneaky. MEASURED: with
      # the conjunction rule, both edits sat in `repro_cli_support.nim` with
      # this case reporting 8 [OK].
      #
      # So the rule is the stronger and simpler one: OUTSIDE THE DECLARING
      # MODULE, NO SHIPPED SOURCE NAMES AN ENABLING MODE AT ALL. That is
      # exactly the property P1(b)'s design already relies on — the CLI
      # offers `--monitor-hosting` without ever spelling `mhmWhereSupported`
      # or `mhmRequired`, because `parseMonitorHostingMode` lives next to the
      # enum — and it is now PINNED rather than merely true. Moving the
      # parser into the CLI reddens this case, which is the right answer: it
      # would put both halves of an enable in a file the scan is not allowed
      # to refuse mentions in.
      const EnablingModes = ["mhmWhereSupported", "mhmRequired"]
      # THE ALLOWLIST, BY PATH AND FOR ONE REASON EACH. Adding an entry here
      # is the visible edit P1(b) asks for.
      #   * repro_cli_support.nim — `--monitor-hosting` /
      #     `REPROBUILD_MONITOR_HOSTING`: the local variable, the flag branch,
      #     the `executeBuildTarget` parameter and call, and the field on the
      #     two main `BuildEngineConfig`s. Every one of those carries the
      #     OPERATOR's value; none of them names an enabling mode.
      let optInPlumbing = [getCurrentDir() / "libs" / "repro_cli_support" /
        "src" / "repro_cli_support.nim"]
      # The module that DECLARES the field names it in its own type, in three
      # comments and in the hosting decision, so it cannot be scanned for a
      # bare mention. It needs no scanning: the only config it constructs is
      # `defaultBuildEngineConfig`, and the first check above pins that one at
      # RUNTIME, which is stronger than a source match.
      let fieldOwner = getCurrentDir() / "libs" / "repro_build_engine" /
        "src" / "repro_build_engine.nim"
      var enablingSites: seq[string] = @[]
      var unpermittedMentions: seq[string] = @[]
      var permittedMentions = 0
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
        var permittedHere = false
        for permitted in optInPlumbing:
          if fileExists(permitted) and sameFile(path, permitted):
            permittedHere = true
            break
        for line in readFile(path).splitLines():
          # ASSERTION 1 — no allowlist, not even for the plumbing, and the
          # mode literal ALONE is the trigger. See `EnablingModes`.
          for mode in EnablingModes:
            if mode in line:
              enablingSites.add path.extractFilename & ": " & line.strip()
              break
          if Field notin line:
            continue
          # ASSERTION 2 — the mention itself, permitted only by name.
          if permittedHere:
            inc permittedMentions
          else:
            unpermittedMentions.add path.extractFilename & ": " & line.strip()
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
        echo "a shipped source names an enabling ", Field, " mode:\n  ",
          enablingSites.join("\n  "),
          "\n  HM-6 measured hosting as no faster at the default ",
          "parallelism on a real build, and consistently slower on cheap ",
          "actions, and it is ",
          "reachable on the bypass path only. Enabling it in the product ",
          "needs the HM-6 verdict revisited, not a config edit. The P1(b) ",
          "operator surface is how you turn it on for a MEASUREMENT: ",
          "`--monitor-hosting=where-supported` (with `--no-runquota`, which ",
          "is the only launch path that can host) or ",
          "`REPROBUILD_MONITOR_HOSTING`."
      check enablingSites.len == 0

      if unpermittedMentions.len > 0:
        echo "a shipped source outside the P1(b) opt-in plumbing names ",
          Field, ":\n  ", unpermittedMentions.join("\n  "),
          "\n  Exactly one shipped file is allowed to name it — the CLI, ",
          "which carries `--monitor-hosting` / `REPROBUILD_MONITOR_HOSTING` ",
          "into the engine config. A second site is how the default gets ",
          "flipped for one code path without flipping the default: it needs ",
          "a named entry in `optInPlumbing` above and a reason, not a ",
          "silent mention."
      check unpermittedMentions.len == 0

      # ASSERTION 3, AND IT IS WHAT KEEPS ASSERTION 2's ALLOWLIST HONEST.
      # An allowlist entry is a hole the moment the thing it was opened for
      # stops existing: delete the flag and the entry keeps permitting
      # whatever else lands in that file. So the permission has to be USED,
      # and the surface it was opened for has to be THERE.
      let cliText = readFile(cliSource)
      if permittedMentions == 0:
        echo "the P1(b) allowlist permits ", Field,
          " in the CLI, but the CLI does not name it: the entry is now a ",
          "standing exemption for a plumbing that no longer exists. Remove ",
          "the entry, or restore the surface."
      check permittedMentions > 0
      if not cliText.contains("--monitor-hosting"):
        echo "the CLI does not carry the `--monitor-hosting` flag, so the ",
          "P1(b) operator surface this case's allowlist was relaxed for is ",
          "gone; the HM-6 verdict is once again unreproducible without a ",
          "harness."
      check cliText.contains("--monitor-hosting")
      # AND THAT ONE IS A SOURCE MATCH, WITH THE WEAKNESS A SOURCE MATCH
      # HAS: a CLI that had lost the flag but kept a comment naming it would
      # satisfy it. It cannot be pinned at runtime from here — this file is
      # a `repro_build_engine` test and does not link the CLI, and importing
      # `repro_cli_support` to reach one flag would invert the dependency
      # direction. What actually exercises the flag end to end is the
      # shipped binary: `repro build --help` lists it, a bad value exits 1
      # naming the flag, and `--no-runquota --monitor-hosting=where-supported`
      # produces a `.host.stdout` where the default produces none. Declared
      # rather than papered over.
      #
      # The environment half is pinned at RUNTIME rather than by a source
      # match, because a source match for an env-var name would pass on a
      # mention of it in a comment. `configuredMonitorHostingMode` is what
      # the CLI's `var monitorHosting = …` initialiser calls, so this is the
      # decode the flag falls back to.
      let priorEnv = getEnv(MonitorHostingEnvVar)
      let priorEnvSet = existsEnv(MonitorHostingEnvVar)
      delEnv(MonitorHostingEnvVar)
      # AN UNSET ENVIRONMENT IS STILL OFF — the surface did not become a
      # second way for the default to drift.
      check configuredMonitorHostingMode() == mhmNever
      putEnv(MonitorHostingEnvVar, "where-supported")
      check configuredMonitorHostingMode() == mhmWhereSupported
      putEnv(MonitorHostingEnvVar, "required")
      check configuredMonitorHostingMode() == mhmRequired
      if priorEnvSet:
        putEnv(MonitorHostingEnvVar, priorEnv)
      else:
        delEnv(MonitorHostingEnvVar)
      # And the flag's own vocabulary decodes to the same three values, so
      # `--monitor-hosting` and the variable cannot drift apart.
      check parseMonitorHostingMode("never", "--monitor-hosting") == mhmNever
      check parseMonitorHostingMode("where-supported",
        "--monitor-hosting") == mhmWhereSupported
      check parseMonitorHostingMode("required",
        "--monitor-hosting") == mhmRequired
      var rejected = false
      try:
        discard parseMonitorHostingMode("yes-please", "--monitor-hosting")
      except ValueError:
        rejected = true
      if not rejected:
        echo "`--monitor-hosting` accepted a value outside its vocabulary; ",
          "a typo would then silently select whichever mode the parser ",
          "falls through to."
      check rejected
