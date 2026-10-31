## `BuildAction.scratchDirs` — BuildXL's pip temp directories.
##
## A working tree an action builds in and reads back from (`npm ci` filling
## `node_modules`, a bundler reading its own intermediate output) is not an
## input: everything there was produced by this run. That holds only if the
## directory starts empty, so the engine empties it before the action runs,
## and then leaves everything observed under it out of the evidence -- out of
## the local key, the portable record and the determinism probe alike.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_build_engine
import repro_core/path_identity
import repro_hash

proc probeAction(sh, root: string): BuildAction =
  ## Reports whether a file a PREVIOUS run left in the scratch directory is
  ## still there, then leaves one behind for the next run.
  result = action("scratch/probe",
    [sh, "-c",
     "if [ -e work/stale ]; then echo stale; else echo clean; fi " &
       "> out/seen.txt; mkdir -p work; echo left > work/stale"],
    cwd = root,
    outputs = ["out/seen.txt"],
    cacheable = false,
    weakFingerprint = weakFingerprintFromText("scratch.probe"),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.scratchDirs = @["work"]

proc run(sh, root: string; a: BuildAction): BuildRunResult =
  var config = defaultBuildEngineConfig(root / "cache")
  config.bypassRunQuota = true
  config.maxParallelism = 1'u32
  runBuild(graph([a]), config)

suite "scratch directories":

  test "the engine empties one before every run":
    let sh = findExe("sh")
    if sh.len == 0:
      skip("no `sh` on PATH; the action under test is a shell script")
    else:
      let root = createTempDir("repro-scratch-", "")
      defer: removeDir(root)
      createDir(root / "out")
      createDir(root / "work")
      writeFile(root / "work" / "stale", "from before")
      for attempt in 1 .. 2:
        let res = run(sh, root, probeAction(sh, root))
        require res.results.len == 1
        check res.results[0].status == asSucceeded
        check readFile(root / "out" / "seen.txt").strip() == "clean"
      # ...and leaves what the action wrote for it to read back.
      check fileExists(root / "work" / "stale")

  test "emptying one removes links without following them":
    # npm links each workspace package into `node_modules` -- a directory
    # junction on Windows. Emptying the scratch tree must remove the LINK and
    # leave what it points at alone; a read-only file must not stop it.
    let root = createTempDir("repro-scratch-links-", "")
    defer: removeDir(root)
    let outside = root / "linked-sources"
    createDir(outside)
    writeFile(outside / "keep.txt", "not scratch")
    createDir(root / "work" / "node_modules")
    let link = root / "work" / "node_modules" / "pkg"
    when defined(windows):
      require execShellCmd("cmd /c mklink /J \"" & link & "\" \"" &
        outside & "\" > NUL") == 0
    else:
      createSymlink(outside, link)
    writeFile(root / "work" / "readonly.txt", "x")
    setFilePermissions(root / "work" / "readonly.txt", {fpUserRead})
    var a = action("scratch/links", ["tool"], cwd = root,
      weakFingerprint = weakFingerprintFromText("scratch.links"),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    a.scratchDirs = @["work"]
    check resetScratchDirs(a) == ""
    check dirExists(root / "work")
    var left = 0
    for _ in walkDir(root / "work"):
      inc left
    check left == 0
    check readFile(outside / "keep.txt") == "not scratch"

  test "nothing observed under one is evidence":
    var a = action("scratch/evidence", ["tool"], cwd = "/proj",
      weakFingerprint = weakFingerprintFromText("scratch.evidence"),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    a.scratchDirs = @["build/work"]
    # The four OBSERVED channels are an `ObservedPathChannel`, whose only
    # append names the `EvidenceContributor` that produced the entry — so a
    # fixture states what it is pretending to be. These are the shape a real
    # monitor capture produces, hence `evcMonitorCapture`; nothing in this
    # case reads the provenance, which is why the choice is free to be the
    # honest one.
    var evidence = PathSetEvidence()
    evidence.monitorReads.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, ["/proj/src/main.c",
                          "/proj/build/work/node_modules/x.js",
                          "/proj/build/workshop/kept.c"])
    evidence.monitorWrites.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, ["/proj/build/work/a.o", "/proj/out/app"])
    evidence.monitorProbes.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, ["/proj/build/work", "/proj/src"])
    evidence.monitorDirectoryEnumerations.observeAll(
      evidence.evidenceProvenance, evcMonitorCapture,
      ["/proj/build/work/dist"])
    dropScratchEvidence(a, evidence)
    # A sibling whose name merely starts with the scratch directory's is kept.
    check evidence.monitorReads == @["/proj/src/main.c",
                                     "/proj/build/workshop/kept.c"]
    check evidence.monitorWrites == @["/proj/out/app"]
    check evidence.monitorProbes == @["/proj/src"]
    check evidence.monitorDirectoryEnumerations.len == 0

  test "one that would destroy what the action reads or makes is refused":
    var a = action("scratch/refused", ["tool"], cwd = "/home/u/proj/build",
      inputs = ["/home/u/proj/src/main.c"], outputs = ["/home/u/proj/out/app"],
      weakFingerprint = weakFingerprintFromText("scratch.refused"),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    a.scratchDirs = @["/home/u/proj/build/work"]
    check scratchDirProblem(a) == ""
    a.scratchDirs = @["/home/u/proj/src"]
    check "declared input" in scratchDirProblem(a)
    a.scratchDirs = @["/home/u/proj/out"]
    check "declared output" in scratchDirProblem(a)
    a.scratchDirs = @["/home/u/proj"]
    check "cwd" in scratchDirProblem(a)
    a.scratchDirs = @["/home"]
    check scratchDirProblem(a).len > 0

  test "a parent walk through a scratch symlink keeps external evidence":
    let root = createTempDir("repro-scratch-parent-", "")
    defer: removeDir(root)
    createDir(root / "work")
    createDir(root / "outside" / "dir")
    when defined(windows):
      require execShellCmd("cmd /c mklink /J \"" & root / "work" / "link" &
        "\" \"" & root / "outside" / "dir" & "\" > NUL") == 0
    else:
      createSymlink(root / "outside" / "dir", root / "work" / "link")
    writeFile(root / "outside" / "input", "external")
    let escaped = root / "work" / "link" & "/../input"
    require readFile(escaped) == "external"
    var a = action("scratch/parent", ["tool"], cwd = root,
      weakFingerprint = weakFingerprintFromText("scratch.parent"),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    a.scratchDirs = @["work"]
    var evidence = PathSetEvidence()
    evidence.monitorReads.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, [escaped])
    dropScratchEvidence(a, evidence)
    check evidence.monitorReads == @[escaped]

# Literal evidence tests the production folds, without mocking capture or
# filesystem resolution. Links and their targets below are real filesystem
# objects; unknown paths deliberately exercise failed kernel resolution.
proc parentWalkAction(root, excluded: string): BuildAction =
  result = action("containment", ["tool"], cwd = root,
    outputs = [excluded],
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.scratchDirs = @[excluded]
  result.dependencyPolicy.ignoredInputPrefixes = @[excluded]

proc directoryLink(target, link: string) =
  when defined(windows):
    doAssert execShellCmd("cmd /c mklink /J \"" & link & "\" \"" &
      target & "\" > NUL") == 0
  else:
    createSymlink(target, link)

proc assertExcluded(a: BuildAction; path: string; excluded: bool) =
  var evidence = PathSetEvidence()
  evidence.monitorReads.observeAll(evidence.evidenceProvenance,
    evcMonitorCapture, [path])
  evidence.monitorProbes.observeAll(evidence.evidenceProvenance,
    evcMonitorCapture, [path])
  evidence.monitorDirectoryEnumerations.observeAll(evidence.evidenceProvenance,
    evcMonitorCapture, [path])
  check a.isOwnOutput(path) == excluded
  check (a.cacheInputPaths(evidence).len == 0) == excluded
  check (a.cacheEnumeratedDirectories(evidence).len == 0) == excluded
  dropScratchEvidence(a, evidence)
  check (evidence.monitorReads.len == 0) == excluded
  check (evidence.monitorProbes.len == 0) == excluded
  check (evidence.monitorDirectoryEnumerations.len == 0) == excluded

suite "monitor containment follows parent walks through links":
  test "resolved paths and roots use the kernel namespace, with absent suffixes":
    let root = createTempDir("repro-containment-", "")
    defer: removeDir(root)
    createDir(root / "inside" / "dir")
    createDir(root / "outside" / "dir")
    directoryLink(root / "outside" / "dir", root / "inside" / "link")
    directoryLink(root / "inside" / "dir", root / "outside" / "link")
    let physicalInside = expandFilename(root / "inside")
    check resolveExistingTraversal(root / "outside" / "link" & "/..").path ==
      physicalInside
    block:
      let oldCwd = getCurrentDir()
      setCurrentDir(root)
      try:
        check resolveExistingTraversal("outside/link/..").path == physicalInside
      finally:
        setCurrentDir(oldCwd)
    let outWalk = root / "inside" / "link" & "/../missing/deep"
    let inWalk = root / "outside" / "link" & "/../missing/deep"
    let a = parentWalkAction(root, root / "inside")
    assertExcluded(a, outWalk, false)
    assertExcluded(a, inWalk, true)
    check detectSourceWrites([root / "inside"], [outWalk]).len == 0
    check detectSourceWrites([root / "inside"], [inWalk]).len == 1
    let rootWalk = root / "inside" / "link" & "/.././missing//"
    let b = parentWalkAction(root, rootWalk)
    assertExcluded(b, root / "outside" / "missing" / "deep", true)
    assertExcluded(b, root / "inside" / "missing" / "deep", false)
    check detectSourceWrites([rootWalk],
      [root / "outside" / "missing" / "deep"]).len == 1
    check detectSourceWrites([rootWalk],
      [root / "inside" / "missing" / "deep"]).len == 0
    # Relative observed paths must reach the same decision as absolute ones;
    # joinPath must not fold the link/.. before the predicate sees it.
    assertExcluded(a, "inside/link/../missing/deep", false)
    assertExcluded(a, "outside/link/../missing/deep", true)
    let relativeRoot = parentWalkAction(root, "inside/link/../missing")
    check relativeRoot.isOwnOutput(root / "outside" / "missing" / "deep")
    check not relativeRoot.isOwnOutput(root / "inside" / "missing" / "deep")
    var relativeEvidence = PathSetEvidence()
    relativeEvidence.monitorReads.observeAll(relativeEvidence.evidenceProvenance,
      evcMonitorCapture, [root / "outside" / "missing" / "deep",
        root / "inside" / "missing" / "deep"])
    dropScratchEvidence(relativeRoot, relativeEvidence)
    check relativeEvidence.monitorReads == @[root / "inside" / "missing" / "deep"]
    let parentCwd = parentWalkAction(root / "inside" / "link" & "/..", "missing")
    check parentCwd.isOwnOutput(root / "outside" / "missing" / "deep")
    check not parentCwd.isOwnOutput(root / "inside" / "missing" / "deep")
    when not defined(windows):
      # The mandatory prefix can itself resolve to the filesystem root.
      var filesystemRoot = root
      for component in root.split('/'):
        if component.len > 0:
          filesystemRoot.add("/..")
      check detectSourceWrites(["/"], [outWalk]).len == 1
      check detectSourceWrites([filesystemRoot], [outWalk]).len == 1

  test "unresolvable parent prefixes retain inputs and report source writes":
    let root = createTempDir("repro-containment-unknown-", "")
    defer: removeDir(root)
    createDir(root / "inside")
    writeFile(root / "inside" / "file", "not a directory")
    when not defined(windows):
      createSymlink(root / "absent", root / "inside" / "dangling")
      createSymlink("loop", root / "inside" / "loop")
    let a = parentWalkAction(root, root / "inside")
    check resolveExistingTraversal("").status == prsFailed
    var prefixes = @["absent", "file"]
    when not defined(windows):
      prefixes.add(["dangling", "loop"])
    for prefix in prefixes:
      let unknown = root / "inside" / prefix & "/../input"
      checkpoint(prefix)
      check resolveExistingTraversal(root / "inside" / prefix & "/..").status ==
        prsFailed
      assertExcluded(a, unknown, false)
      # A spelling outside the source root cannot prove the write safe.
      check detectSourceWrites([root / "elsewhere"], [unknown]).len == 1
      let b = parentWalkAction(root, unknown)
      assertExcluded(b, unknown & "/child", false)
      check detectSourceWrites([unknown], [root / "elsewhere"]).len == 1

  test "content-addressed tool exemptions do not discard escaped observations":
    let root = createTempDir("repro-containment-tool-", "")
    defer: removeDir(root)
    let hadStore = existsEnv("REPRO_STORE_ROOT")
    let oldStore = getEnv("REPRO_STORE_ROOT")
    putEnv("REPRO_STORE_ROOT", root)
    defer:
      if hadStore: putEnv("REPRO_STORE_ROOT", oldStore)
      else: delEnv("REPRO_STORE_ROOT")
    let toolRoot = root / "prefixes" / "tool" / "1-0123456789abcdef"
    createDir(toolRoot / "bin")
    createDir(root / "outside" / "dir")
    directoryLink(root / "outside" / "dir", toolRoot / "link")
    let a = action("tool-containment", [toolRoot / "bin" / "tool"],
      cwd = root, governingLockIdentity = lockIdentityOutsideSolvedGraph())
    require contentAddressedRoot(a.argv[0]) == toolRoot.replace('\\', '/')
    for suffix in ["link/../input", "absent/../input"]:
      let path = toolRoot & "/" & suffix
      var evidence = PathSetEvidence()
      evidence.monitorReads.observeAll(evidence.evidenceProvenance,
        evcMonitorCapture, [path])
      evidence.monitorDirectoryEnumerations.observeAll(evidence.evidenceProvenance,
        evcMonitorCapture, [path])
      check a.cacheInputPaths(evidence) == @[path]
      check a.cacheEnumeratedDirectories(evidence) == @[path]
    var control = PathSetEvidence()
    control.monitorReads.observeAll(control.evidenceProvenance,
      evcMonitorCapture, [toolRoot / "bin" / "tool"])
    check a.cacheInputPaths(control).len == 0
