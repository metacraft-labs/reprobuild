{.define: reproDaemonParentPrewarmTest.}

## Dependency-Attribution MAC-2 — the daemon-parent prewarm.
##
## WHAT IS BEING GATED. The user daemon forks a worker per build request, so
## every worker starts with the in-memory build caches empty and re-reads the
## same persisted files the previous worker read. MAC-2 fills those caches in
## the PARENT, before the fork, so the worker inherits them copy-on-write. The
## three things that can go wrong with that are the three things tested here:
## the warm state might not actually be consumed (in which case the milestone
## delivers nothing), it might be consumed when it is STALE (in which case a
## build decides on data that no longer describes the project), and the pass
## might mutate process-global state in a process that is shared by every
## request (which is the hazard that kept the predecessor disabled).
##
## MOCK POLICY: no mocks, and none may be added. Every case writes a REAL
## cache record to a REAL directory with the module's own writer, and reads it
## back through the module's own reader. The properties under test are about
## what happens between a file and a table; a stand-in for either would decide
## the question by fiat. The only test-only code is the seam that exposes the
## private writer/reader/table-size — see `reproDaemonParentPrewarmTest`.
##
## WHAT MAKES EACH CASE FAIL, stated so a green run means something:
##
##   * `prewarm_makes_the_next_read_a_memory_hit` — deleting the
##     `warmLoweredGraphs[...] = ...` insert in `prewarmLoweredGraphsFrom`
##     leaves the read going to disk and reddens the counter check.
##   * `a_changed_cache_file_is_re_read_not_served_from_the_prewarm` — this is
##     the staleness gate. Replacing `cacheEvidence: evidence` in
##     `prewarmLoweredGraphsFrom` with an evidence value captured BEFORE the
##     rewrite — or removing the `evidenceFresh` arm of the warm guard —
##     serves the stale actions and reddens it.
##   * `prewarm_touches_no_process_global_state` — the hazard case. Adding a
##     single UNRESTORED `putEnv`/`setCurrentDir` anywhere under
##     `prewarmDaemonParentCaches` reddens it. Both were run; both redden on
##     the PROCESS-START comparison and neither reddens the before/after pair,
##     for the reason recorded at `processStartEnvironment` below.
##
##     WHAT THIS CASE CANNOT SEE, stated because the gap is exactly the
##     predecessor's shape: a RESTORE-AFTER mutation — save, mutate, restore —
##     leaves both comparisons green by construction, and that is precisely
##     what the disabled prewarmer did and precisely what is racy in a shared
##     parent. Nothing here can close that; it is closed by INSPECTION of the
##     transitive callee set of `prewarmDaemonParentCaches` and
##     `daemonPrewarmTargetOutputDir`, which reaches only path joins, `stat`,
##     `readFile` and pure decoders. Anyone editing this pass owes that
##     inspection again and must not read a green here as covering it.
##   * `the_output_directory_comes_from_the_request_not_the_process` — the
##     parent's own `$REPROBUILD_WORK_ROOT` and current directory are set to
##     decoys. Making `daemonPrewarmTargetOutputDir` fall back to
##     `outputDirForTarget` (which reads both) reddens it.
##   * `switching_projects_does_not_accumulate` — the RSS bound. Removing the
##     `forgetWarmBuildCaches()` call for a changed `outDir` reddens it.
##   * `a_forced_rebuild_warms_nothing` — a forced rebuild consults none of
##     these caches. Dropping the `forceRefresh` arm reddens it.

import std/[algorithm, options, os, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_cli_support
import repro_core
import repro_hash

proc sampleActions(tag: string): seq[BuildAction] =
  @[BuildAction(
      governingLockIdentity: emptySolvedGraphIdentity("mac2-prewarm"),
      kind: bakStamp,
      id: "action-" & tag,
      weakFingerprint: weakFingerprintFromText("fingerprint-" & tag))]

proc writeRecord(outDir, tag: string): string =
  ## Write one lowered-graph cache record under ``outDir`` and return its path.
  let path = loweredGraphCachePathForTest(outDir, "target")
  writeLoweredGraphCacheFileForTest(path, outDir / "repro.nim", outDir,
    "target", "PATHENV", "cachekey", sampleActions(tag))
  path

proc readRecord(outDir, path: string):
    Option[tuple[actions: seq[BuildAction]; pools: seq[BuildPool]]] =
  readLoweredGraphForTest(path, outDir / "repro.nim", outDir, "target",
    "PATHENV", "cachekey")

proc environmentSnapshot(): seq[string] =
  for key, value in envPairs():
    result.add(key & "=" & value)
  result.sort()

let processStartEnvironment = environmentSnapshot()
let processStartDirectory = getCurrentDir()
  ## Captured BEFORE any case runs, and compared against at the end of the
  ## global-state case.
  ##
  ## This is not belt-and-braces; it is the whole case. A before/after pair
  ## around ONE call cannot see a leak that has already happened: an injected
  ## `putEnv` inside `prewarmDaemonParentCaches` was invisible to that pair,
  ## because two earlier cases had already called the pass and the name was
  ## present in `envBefore` too. Verified — that mutation left every case green
  ## until this snapshot was added.

suite "MAC-2 daemon parent prewarm":
  test "prewarm_makes_the_next_read_a_memory_hit":
    let root = createTempDir("repro-mac2-hit", "")
    defer: removeDir(root)
    let path = writeRecord(root, "one")

    # Cold: the table is empty (the writer seam forgot it), so the read goes
    # to disk. This half is what proves the counter moves at all — without it
    # the warm half below would pass against a counter that never increments.
    let coldBefore = warmBuildCacheCounters.loweredGraphDiskReads
    let cold = readRecord(root, path)
    check cold.isSome
    check warmBuildCacheCounters.loweredGraphDiskReads == coldBefore + 1

    forgetWarmBuildCaches()
    let report = prewarmDaemonParentCaches(root)
    checkpoint("warmed loweredGraphs=" & $report.loweredGraphs)
    check report.loweredGraphs == 1

    let warmBefore = warmBuildCacheCounters.loweredGraphDiskReads
    let warm = readRecord(root, path)
    require warm.isSome
    check warm.get().actions.len == cold.get().actions.len
    check warm.get().actions[0].id == cold.get().actions[0].id
    # THE WITNESS. Byte equality above cannot distinguish a warm hit from a
    # second disk read that produced the same bytes; the counter can.
    check warmBuildCacheCounters.loweredGraphDiskReads == warmBefore

    # And the second prewarm of the same unchanged project re-decodes nothing.
    let again = prewarmDaemonParentCaches(root)
    check again.reused

  test "a_changed_cache_file_is_re_read_not_served_from_the_prewarm":
    # THE STALENESS GATE, and the reason the milestone insists on one: warmed
    # state that outlives the file it was decoded from would let a build
    # schedule from a lowering that no longer describes the project. The setup
    # is the one a daemon really produces — the parent decodes the file for
    # request N, and the project changes before request N+1.
    let root = createTempDir("repro-mac2-stale", "")
    defer: removeDir(root)
    let path = writeRecord(root, "original")
    forgetWarmBuildCaches()
    check prewarmDaemonParentCaches(root).loweredGraphs == 1
    let warmed = readRecord(root, path)
    require warmed.isSome
    check warmed.get().actions[0].id == "action-original"

    # Change the file WITHOUT re-warming: the table still holds the decode of
    # the previous bytes. `sleep` is deliberate — the guard is a stat identity
    # including nanoseconds, and this test is about the guard, not about its
    # resolution limit.
    sleep(20)
    writeLoweredGraphCacheFileForTest(path, root / "repro.nim", root,
      "target", "PATHENV", "cachekey", sampleActions("current"))

    let before = warmBuildCacheCounters.loweredGraphDiskReads
    let served = readRecord(root, path)
    require served.isSome
    check served.get().actions[0].id == "action-current"
    # ...and it got there by RE-READING, not by some other route to the same
    # answer. A stale entry must be discarded, not patched.
    check warmBuildCacheCounters.loweredGraphDiskReads == before + 1

    # The parent notices too: its own idempotence stamp is no longer fresh, so
    # the next prewarm re-decodes instead of reporting `reused`.
    check not prewarmDaemonParentCaches(root).reused

  test "prewarm_touches_no_process_global_state":
    let root = createTempDir("repro-mac2-global", "")
    defer: removeDir(root)
    discard writeRecord(root, "global")
    let cwdBefore = getCurrentDir()
    let envBefore = environmentSnapshot()
    discard prewarmDaemonParentCaches(root)
    check getCurrentDir() == cwdBefore
    let envAfter = environmentSnapshot()
    if envAfter != envBefore:
      checkpoint("env delta: " &
        envAfter.filterIt(it notin envBefore).join(" | ") & " // removed: " &
        envBefore.filterIt(it notin envAfter).join(" | "))
    check envAfter == envBefore

    # ...and nothing any EARLIER prewarm in this process did survives either.
    if envAfter != processStartEnvironment:
      checkpoint("env drifted since process start: added " &
        envAfter.filterIt(it notin processStartEnvironment).join(" | ") &
        " // removed " &
        processStartEnvironment.filterIt(it notin envAfter).join(" | "))
    check envAfter == processStartEnvironment
    check getCurrentDir() == processStartDirectory

  test "the_output_directory_comes_from_the_request_not_the_process":
    # NOTE ON THE ARGUMENT VECTORS BELOW. They carry no `build` verb, because
    # `UserDaemonBuildRequest.rawArgs` carries none: the dispatcher hands
    # `runBuildCommand` `args[1 .. ^1]`, and the internal callers compose
    # their own vectors without one. A case that spelled `@["build", "."]`
    # would be exercising a shape the daemon never sends.
    let root = createTempDir("repro-mac2-outdir", "")
    defer: removeDir(root)
    let project = root / "p"
    createDir(project)
    writeFile(project / "repro.nim", "# project\n")
    let requestWorkRoot = root / "requested-work"
    let decoyWorkRoot = root / "decoy-work"
    createDir(requestWorkRoot)
    createDir(decoyWorkRoot)

    # The parent's OWN answers, which must not be consulted.
    let previousCwd = getCurrentDir()
    let hadDecoy = existsEnv("REPROBUILD_WORK_ROOT")
    let previousDecoy = getEnv("REPROBUILD_WORK_ROOT")
    defer:
      setCurrentDir(previousCwd)
      if hadDecoy: putEnv("REPROBUILD_WORK_ROOT", previousDecoy)
      else: delEnv("REPROBUILD_WORK_ROOT")
    putEnv("REPROBUILD_WORK_ROOT", decoyWorkRoot)
    setCurrentDir(root)

    let fromEnv = daemonPrewarmTargetOutputDir(
      @["."], project,
      @["REPROBUILD_WORK_ROOT=" & requestWorkRoot])
    checkpoint("fromEnv=" & fromEnv)
    check fromEnv.len > 0
    check fromEnv.startsWith(requestWorkRoot)
    check not fromEnv.contains("decoy-work")

    # An explicit flag wins over the request environment, as it does in the
    # build itself.
    let flagRoot = root / "flag-work"
    createDir(flagRoot)
    let fromFlag = daemonPrewarmTargetOutputDir(
      @[".", "--work-root=" & flagRoot], project,
      @["REPROBUILD_WORK_ROOT=" & requestWorkRoot])
    checkpoint("fromFlag=" & fromFlag)
    check fromFlag.startsWith(flagRoot)

    # No work root anywhere in the REQUEST means the in-tree `.repro/build`,
    # even though the process has one set. Falling through to the ambient
    # value is the defect this asserts against.
    let inTree = daemonPrewarmTargetOutputDir(@["."], project, @[])
    checkpoint("inTree=" & inTree)
    check inTree == project / ".repro" / "build" / "repro"

    # A relative target resolves against the REQUEST's working directory, not
    # the process's.
    let relative = daemonPrewarmTargetOutputDir(@["p"], root, @[])
    check relative == project / ".repro" / "build" / "repro"

  test "a_forced_rebuild_warms_nothing":
    let root = createTempDir("repro-mac2-force", "")
    defer: removeDir(root)
    let project = root / "p"
    createDir(project)
    writeFile(project / "repro.nim", "# project\n")
    check daemonPrewarmTargetOutputDir(
      @[".", "--force-rebuild"], project, @[]).len == 0
    check daemonPrewarmTargetOutputDir(
      @[".", "--dry-run"], project, @[]).len == 0
    check daemonPrewarmTargetOutputDir(@["."], project, @[]).len > 0

  test "switching_projects_does_not_accumulate":
    let root = createTempDir("repro-mac2-bound", "")
    defer: removeDir(root)
    let first = root / "a"
    let second = root / "b"
    createDir(first)
    createDir(second)
    discard writeRecord(first, "a")
    discard writeRecord(second, "b")

    forgetWarmBuildCaches()
    check prewarmDaemonParentCaches(first).loweredGraphs == 1
    check warmLoweredGraphCountForTest() == 1
    check prewarmDaemonParentCaches(second).loweredGraphs == 1
    # ONE project's worth, not two. A daemon that served a thousand projects
    # would otherwise hold a thousand lowered graphs it will never consult
    # again — which is the RSS objection that helped disable the predecessor.
    check warmLoweredGraphCountForTest() == 1
