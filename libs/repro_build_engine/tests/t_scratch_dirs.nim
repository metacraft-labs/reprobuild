## `BuildAction.scratchDirs` — BuildXL's pip temp directories.
##
## A working tree an action builds in and reads back from (`npm ci` filling
## `node_modules`, a bundler reading its own intermediate output) is not an
## input: everything there was produced by this run. That holds only if the
## directory starts empty, so the engine empties it before the action runs,
## and then leaves everything observed under it out of the evidence -- out of
## the local key, the portable record and the determinism probe alike.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
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
      skip()
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
