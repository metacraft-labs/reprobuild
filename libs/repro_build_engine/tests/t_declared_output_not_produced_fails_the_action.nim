## A cacheable action that exits 0 without producing a declared output FAILS,
## on every platform, as a structured action failure -- and nothing escapes
## `runBuild`. A non-cacheable one may declare an output it never writes:
## that is the always-run idiom, and it still succeeds.
##
## Build-Engine-And-Scheduler.md §"A declared output is an obligation".
##
## The defect this pins: the engine took exit 0 as success and went on to
## record the action, touching each declared output on the way. On POSIX the
## record step's `getFilePermissions` raised a raw `OSError` out of
## `runBuild` (found through the profile run edge, whose intent document a
## profile that never reaches its emitter does not write); on Windows that
## call is compiled out and the record step's read of the output's bytes
## raised a raw `IOError` instead; and a cacheable action whose publication
## was withheld recorded nothing and reported success everywhere. Measured
## with the engine check disabled: on Windows the first and third cases die
## with that `IOError`, the withheld case reports `asSucceeded`.
##
## The scope arm (the non-cacheable case) is what keeps the CMake edges
## working: the Reprobuild CMake generator declares CMake's never-created
## `SYMBOLIC` custom-target placeholder and custom-command byproducts on
## non-cacheable edges, and the CMake regeneration edge declares a
## never-written sentinel exactly when it is non-cacheable. Measured with the
## scope removed: that case fails with `missingOutputs` set.
##
## Each case is checked against the engine's own result AND out of band: a
## run log the action appends to shows whether a second build re-executed
## it, i.e. whether anything was recorded for the failed run.
##
## MOCK POLICY: the portable restore case supplies the engine's transport
## callback by copying real produced files from a local snapshot. This isolates
## portable result selection from network/signing services; it does not replace
## a subprocess, cache record, fingerprint, or output-set decision. All cases use
## real `runBuild`, the per-edge action cache and CAS, a real subprocess (`sh`),
## and real files in a temporary tree. The directory coverage assertion supplies
## observed-write evidence directly to the S7 predicate so its file coverage is
## checked independently of shell-monitor availability. The
## dependency policy is the Make depfile the action writes, so the cases do
## not depend on the io-monitor and run identically on every platform that
## has `sh` (on Windows, the Git for Windows `sh` env.ps1 puts on PATH).

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_build_engine
import repro_core
from repro_local_store import ffpHybrid, LogicalRoot, lrkTracked, PortableMemoRecord

const NoShell = "no `sh` on PATH; the actions under test are shell scripts"

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc writer(sh, root, id: string; produce: openArray[string];
            outputs: openArray[string]; cacheable: bool): BuildAction =
  ## A shell action that reads `in.txt`, appends a line to `runs-<id>.log`,
  ## writes its depfile, and creates exactly the files in `produce` -- which
  ## may be fewer than the `outputs` it declares.
  let tag = id.replace("/", "-")
  var script = "echo run >> runs-" & tag & ".log; " &
    "printf '%s: in.txt\\n' stamp > " & tag & ".d"
  for path in produce:
    script.add("; echo built > " & path)
  result = action(id, [sh, "-c", script],
    cwd = root,
    inputs = ["in.txt"],
    outputs = outputs,
    depfile = tag & ".d",
    cacheable = cacheable,
    weakFingerprint = weakFingerprintFromText(
      "declared-output-not-produced." & id & "." & produce.join(",")),
    actionCachePolicy = ffpHybrid,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc runs(root, id: string): int =
  let log = root / ("runs-" & id.replace("/", "-") & ".log")
  if fileExists(log):
    for line in readFile(log).splitLines():
      if line.strip().len > 0:
        inc result

proc build(root: string; actions: openArray[BuildAction]): BuildRunResult =
  var config = defaultBuildEngineConfig(root / "cache")
  config.bypassRunQuota = true
  config.maxParallelism = 1'u32
  config.rebuildMissingOutputsOnCacheHit = true
  # Whatever the engine does with an absent output, it must answer through
  # the result: an exception here is the defect.
  runBuild(graph(actions), config)

proc newTree(prefix: string): string =
  result = createTempDir(prefix, "")
  createDir(result / "out")
  writeFile(result / "in.txt", "input\n")

suite "a declared output the action did not produce":

  test "a cacheable action that exits 0 without its output fails, unrecorded":
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = newTree("repro-missing-output-")
      defer: removeDir(root)
      let silent = writer(sh, root, "tool/silent", [], ["out/result.txt"],
        cacheable = true)
      var consumer = action("tool/consumer", [sh, "-c", "true"], cwd = root,
        deps = ["tool/silent"], inputs = ["out/result.txt"],
        weakFingerprint = weakFingerprintFromText("missing-output.consumer"),
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let res = build(root, [silent, consumer])
      let item = res.byId("tool/silent")
      checkpoint("status=" & $item.status & " stderr=" & item.stderr)
      check item.launched
      check item.exitCode == 0
      check item.status == asFailed
      check item.missingOutputs == @["out/result.txt"]
      check "did not produce its declared output" in item.stderr
      check "out/result.txt" in item.stderr
      # Its dependent never runs on the strength of a product that is not
      # there.
      check res.byId("tool/consumer").status == asBlocked
      check runs(root, "tool/silent") == 1
      # Nothing was recorded for the failed run: the next build executes it
      # again rather than answering it from the cache.
      let again = build(root, [silent])
      check again.byId("tool/silent").status == asFailed
      check again.byId("tool/silent").launched
      check runs(root, "tool/silent") == 2

  test "control: the same action producing its output succeeds and is cached":
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = newTree("repro-missing-output-control-")
      defer: removeDir(root)
      let producing = writer(sh, root, "tool/producing", ["out/result.txt"],
        ["out/result.txt"], cacheable = true)
      let first = build(root, [producing]).byId("tool/producing")
      checkpoint("status=" & $first.status & " stderr=" & first.stderr)
      check first.status == asSucceeded
      check first.missingOutputs.len == 0
      let second = build(root, [producing]).byId("tool/producing")
      check not second.launched
      check runs(root, "tool/producing") == 1

  test "conditional import libraries are recorded and restored only when produced":
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = newTree("repro-optional-import-")
      defer: removeDir(root)
      var exported = writer(sh, root, "tool/exported",
        ["out/module.dll", "out/module.lib"], ["out/module.dll"], true)
      exported.optionalOutputs = @["out/module.lib"]
      var config = defaultBuildEngineConfig(root / "cache")
      config.bypassRunQuota = true
      config.maxParallelism = 1
      config.enableCachedOutputRestore()
      let first = runBuild(graph([exported]), config).byId(exported.id)
      checkpoint first.stderr
      check first.status == asSucceeded
      removeFile(root / "out/module.dll")
      removeFile(root / "out/module.lib")
      let restored = runBuild(graph([exported]), config).byId(exported.id)
      checkpoint restored.stderr
      check restored.status == asCacheHit
      check not restored.launched
      check readFile(root / "out/module.dll") == "built\n"
      check readFile(root / "out/module.lib") == "built\n"

      var noExports = writer(sh, root, "tool/no-exports",
        ["out/module.dll"], ["out/module.dll"], true)
      noExports.optionalOutputs = @["out/module.lib"]
      # The previous exported link left a .lib; the no-export link must not
      # record it as if it had just produced it.
      let absent = runBuild(graph([noExports]), config).byId(noExports.id)
      checkpoint absent.stderr
      check absent.status == asSucceeded
      check absent.missingOutputs.len == 0
      check not fileExists(root / "out/module.lib")
      removeFile(root / "out/module.dll")
      writeFile(root / "out/module.lib", "stale\n")
      let absentHit = runBuild(graph([noExports]), config).byId(noExports.id)
      checkpoint absentHit.stderr
      check absentHit.status == asCacheHit
      check not absentHit.launched
      check fileExists(root / "out/module.dll")
      check not fileExists(root / "out/module.lib")
      noExports.optionalOutputs.add("out/module.pdb")
      let changedCandidates = runBuild(graph([noExports]), config).byId(noExports.id)
      check changedCandidates.launched
      check changedCandidates.status == asSucceeded
      check runs(root, noExports.id) == 2

  test "conditional directory snapshots restore nested payload and cached absence":
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = newTree("repro-optional-directory-")
      defer: removeDir(root)
      let stage = root / "out/stage"
      var populated = writer(sh, root, "tool/populated-stage",
        ["out/witness.txt", "out/stage/sub/payload.txt"], ["out/witness.txt"], true)
      populated.argv[2] = "mkdir -p out/stage/sub; " & populated.argv[2]
      populated.optionalOutputs = @["out/stage"]
      var config = defaultBuildEngineConfig(root / "cache")
      config.bypassRunQuota = true
      config.maxParallelism = 1
      config.enableCachedOutputRestore()
      let first = runBuild(graph([populated]), config).byId(populated.id)
      checkpoint first.stderr
      require first.status == asSucceeded
      var writes = PathSetEvidence()
      writes.monitorWrites.observeAll(writes.evidenceProvenance,
        evcMonitorCapture, [stage / "sub/payload.txt"])
      check populated.undeclaredSurvivingWrites(writes).len == 0
      removeDir(stage)
      removeFile(root / "out/witness.txt")
      let restored = runBuild(graph([populated]), config).byId(populated.id)
      checkpoint restored.stderr
      check restored.status == asCacheHit
      check not restored.launched
      check readFile(stage / "sub/payload.txt") == "built\n"
      var empty = writer(sh, root, "tool/empty-stage",
        ["out/witness.txt"], ["out/witness.txt"], true)
      empty.optionalOutputs = @["out/stage"]
      let absent = runBuild(graph([empty]), config).byId(empty.id)
      checkpoint absent.stderr
      check absent.status == asSucceeded
      check not dirExists(stage)
      createDir(stage / "stale")
      writeFile(stage / "stale/old.txt", "old\n")
      removeFile(root / "out/witness.txt")
      let absentHit = runBuild(graph([empty]), config).byId(empty.id)
      checkpoint absentHit.stderr
      check absentHit.status == asCacheHit
      check not absentHit.launched
      check not dirExists(stage)
      check fileExists(root / "out/witness.txt")

  test "portable restore includes a produced conditional import library":
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = newTree("repro-portable-exported-import-")
      defer: removeDir(root)
      var producer = writer(sh, root, "tool/portable-exported",
        ["out/module.dll", "out/module.lib"], ["out/module.dll"], true)
      producer.optionalOutputs = @["out/module.lib"]
      var config = defaultBuildEngineConfig(root / "cache")
      config.bypassRunQuota = true
      config.maxParallelism = 1
      config.portableLookup = true
      config.portableRoots = @[
        LogicalRoot(label: "project", path: root, kind: lrkTracked),
        LogicalRoot(label: "shell", path: parentDir(sh), kind: lrkTracked)]
      let first = runBuild(graph([producer]), config).byId(producer.id)
      checkpoint first.stderr & " " & first.portableReason
      require first.status == asSucceeded
      require first.portable
      require first.portableOutputs.len == 2
      let saved = root / "saved"
      copyDir(root / "out", saved)
      removeFile(root / "out/module.dll")
      removeFile(root / "out/module.lib")
      config.portableMemoRestorer = proc (roots: seq[LogicalRoot];
          record: PortableMemoRecord): string {.gcsafe.} =
        for output in record.outputs:
          if output.path notin ["project:out/module.dll", "project:out/module.lib"]:
            return "unexpected portable output " & output.path
          copyFile(saved / extractFilename(output.path),
            root / "out" / extractFilename(output.path))
        ""
      let restored = runBuild(graph([producer]), config).byId(producer.id)
      checkpoint restored.stderr & " " & restored.reason
      check not restored.launched
      check restored.reason == "portable-restored"
      check readFile(root / "out/module.dll") == "built\n"
      check readFile(root / "out/module.lib") == "built\n"
      check runs(root, producer.id) == 1

  test "portable reuse preserves an absent conditional import library":
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = newTree("repro-portable-optional-import-")
      defer: removeDir(root)
      var producer = writer(sh, root, "tool/portable-no-exports",
        ["out/module.dll"], ["out/module.dll"], true)
      producer.optionalOutputs = @["out/module.lib"]
      var config = defaultBuildEngineConfig(root / "cache")
      config.bypassRunQuota = true
      config.maxParallelism = 1
      config.portableLookup = true
      config.portableRoots = @[
        LogicalRoot(label: "project", path: root, kind: lrkTracked),
        LogicalRoot(label: "shell", path: parentDir(sh), kind: lrkTracked)]
      let first = runBuild(graph([producer]), config).byId(producer.id)
      checkpoint first.stderr & " " & first.portableReason
      require first.status == asSucceeded
      require first.portable
      writeFile(root / "out/module.lib", "stale\n")
      let reused = runBuild(graph([producer]), config).byId(producer.id)
      checkpoint reused.stderr & " " & reused.reason
      check not reused.launched
      check reused.reason == "portable-outputs-present"
      check not fileExists(root / "out/module.lib")

  test "optional outputs obey the destructive-path safety guard":
    var unsafe = BuildAction(cwd: getCurrentDir(), optionalOutputs: @["/"],
      governingLockIdentity: lockIdentityOutsideSolvedGraph())
    check "too close to a filesystem root" in unsafe.removeBeforeRunProblem()
    unsafe.optionalOutputs = @["/tmp"]
    check "too close to a filesystem root" in unsafe.removeBeforeRunProblem()
    unsafe.optionalOutputs = @["/tmp/unused/../.."]
    check "too close to a filesystem root" in unsafe.removeBeforeRunProblem()
    when not defined(windows):
      let root = newTree("repro-optional-root-alias-")
      defer: removeDir(root)
      createSymlink("/", root / "root-link")
      # A symlink to `/` deep in a scratch tree, walked back up to `/`. The
      # location must be resolved through the link, not collapsed lexically
      # (which would name the scratch tree's parent, as deep as TMPDIR, and
      # pass the guard): this case was red under the suite's TMPDIR and
      # green only under a shallow one until the resolution was fixed.
      unsafe.optionalOutputs = @[root & "/root-link/tmp/../.."]
      check "too close to a filesystem root" in unsafe.removeBeforeRunProblem()
      unsafe.optionalOutputs = @[root & "/root-link/tmp/../x.txt"]
      check "too close to a filesystem root" in unsafe.removeBeforeRunProblem()
      # Control: a parent walk through an ordinary directory stays where it
      # is, and a location as deep as the tree is not flagged.
      createDir(root / "sub")
      unsafe.optionalOutputs = @[root & "/sub/../out.txt"]
      check unsafe.removeBeforeRunProblem() == ""

  test "only the absent outputs are named":
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = newTree("repro-missing-output-partial-")
      defer: removeDir(root)
      let partial = writer(sh, root, "tool/partial", ["out/a.txt"],
        ["out/a.txt", "out/b.txt"], cacheable = true)
      let item = build(root, [partial]).byId("tool/partial")
      checkpoint("status=" & $item.status & " stderr=" & item.stderr)
      check item.status == asFailed
      check item.missingOutputs == @["out/b.txt"]

  test "a cacheable action whose publication is withheld is held too":
    # The class the old record step never reached: a cacheable action that
    # publishes nothing -- here because its declared depfile is never
    # written, which withholds publication without failing it
    # (t_declared_depfile_absent_is_not_cacheable) -- used to report success
    # on every platform for a product it never made.
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = newTree("repro-missing-output-withheld-")
      defer: removeDir(root)
      let withheld = action("tool/withheld",
        [sh, "-c", "echo run >> runs-tool-withheld.log"],
        cwd = root,
        inputs = ["in.txt"],
        outputs = ["out/result.txt"],
        depfile = "never-written.d",
        cacheable = true,
        weakFingerprint = weakFingerprintFromText("missing-output.withheld"),
        actionCachePolicy = ffpHybrid,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let item = build(root, [withheld]).byId("tool/withheld")
      checkpoint("status=" & $item.status & " stderr=" & item.stderr)
      check item.launched
      check item.status == asFailed
      check item.exitCode == 0
      check item.missingOutputs == @["out/result.txt"]
      check runs(root, "tool/withheld") == 1

  test "a non-cacheable action may declare an output it never writes":
    # The always-run idiom (Make's FORCE, CMake's SYMBOLIC outputs): the
    # absent output keeps the edge out of date and nothing records it, so
    # there is nothing for the obligation to protect. The edge succeeds, its
    # dependent runs, and the next build runs it again.
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = newTree("repro-missing-output-uncached-")
      defer: removeDir(root)
      let symbolic = writer(sh, root, "tool/uncached", [],
        ["out/always-run.sentinel"], cacheable = false)
      check not symbolic.declaredOutputsAreObligatory()
      let consumer = action("tool/after-uncached", [sh, "-c", "true"],
        cwd = root, deps = ["tool/uncached"],
        weakFingerprint = weakFingerprintFromText(
          "missing-output.after-uncached"),
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let res = build(root, [symbolic, consumer])
      let item = res.byId("tool/uncached")
      checkpoint("status=" & $item.status & " stderr=" & item.stderr)
      check item.status == asSucceeded
      check item.missingOutputs.len == 0
      check "did not produce" notin item.stderr
      check res.byId("tool/after-uncached").status == asSucceeded
      check not fileExists(root / "out" / "always-run.sentinel")
      let again = build(root, [symbolic]).byId("tool/uncached")
      check again.status == asSucceeded
      check again.launched
      check runs(root, "tool/uncached") == 2

  test "a failing exit is reported as the exit, not as a missing output":
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = newTree("repro-missing-output-exit-")
      defer: removeDir(root)
      # Cacheable, so its outputs are obligatory, and a depfile policy so it
      # launches without the io-monitor: the exit is the only thing wrong.
      let failing = action("tool/failing", [sh, "-c", "exit 3"], cwd = root,
        inputs = ["in.txt"],
        outputs = ["out/result.txt"],
        depfile = "failing.d",
        cacheable = true,
        weakFingerprint = weakFingerprintFromText("missing-output.failing"),
        actionCachePolicy = ffpHybrid,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      check failing.declaredOutputsAreObligatory()
      let item = build(root, [failing]).byId("tool/failing")
      checkpoint("status=" & $item.status & " stderr=" & item.stderr)
      check item.launched
      check item.status == asFailed
      check item.exitCode == 3
      check item.missingOutputs.len == 0

  test "missingDeclaredOutputs reads existence without following links":
    let root = newTree("repro-missing-output-probe-")
    defer: removeDir(root)
    writeFile(root / "out" / "present.txt", "x\n")
    createDir(root / "out" / "dir")
    let a = action("tool/probe", ["tool"], cwd = root,
      outputs = ["out/present.txt", "out/dir", "out/absent.txt",
                 root / "out" / "absent-abs.txt"],
      weakFingerprint = weakFingerprintFromText("missing-output.probe"),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check a.missingDeclaredOutputs() ==
      @["out/absent.txt", root / "out" / "absent-abs.txt"]
    when not defined(windows):
      # A link the action created is the output it produced, dangling or
      # not; whether a link may be an output is another rule's question.
      createSymlink(root / "out" / "nowhere", root / "out" / "link")
      let linked = action("tool/link", ["tool"], cwd = root,
        outputs = ["out/link"],
        weakFingerprint = weakFingerprintFromText("missing-output.link"),
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      check linked.missingDeclaredOutputs().len == 0
