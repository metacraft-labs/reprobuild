## An executed action's evidence is filtered into its keyed input set once,
## and a `..`-spelled path is resolved afresh by every evaluation.
##
## A monitored compile reports a few hundred observations, many of them
## spelled through `..` by the compiler driver
## (`.../bin/../lib/gcc/<target>/<version>/../../../../<target>/include/...`).
## The keyed input set (`cacheInputPaths`) was computed three times per action
## from the same evidence (the keyed-set grade, the local record, the portable
## accesses), and inside each computation every `..` path was resolved through
## the filesystem once per root it was compared with. Now the grade only asks
## whether the set is empty (`hasCacheInputPath`), the record and the portable
## accesses share one computation, and one computation resolves each path
## once.
##
## What each case pins:
## * Soundness of the memo: it lives for ONE evaluation. A path whose `..`
##   walk passes through a symbolic link is resolved again by the next
##   evaluation, so retargeting the link moves the path in or out of an
##   ignored root, as it did before the memo.
## * The early-stopping grade agrees with the full set.
## * One computation per executed action: an engine build of a cacheable,
##   content-checked action (whose portable accesses are recorded beside its
##   local record) computes the keyed set once.
##
## Falsifying mutations, run by hand against this test (recorded in the plan):
## a memo that outlives its evaluation fails the first case; computing the
## portable accesses' own keyed set again fails the last.
##
## No mocks: real files and symbolic links, and a real engine build of real
## builtin actions under a fresh cache root.

import std/[os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core
import repro_local_store

let TmpDir = absolutePath(
  "build/test-tmp/t_evidence_is_evaluated_once_per_action-" &
  testCaseScratchSlug())

proc norm(path: string): string =
  path.replace('\\', '/')

proc hasPath(paths: openArray[string]; wanted: string): bool =
  for path in paths:
    if path.norm == wanted.norm:
      return true

suite "evidence is evaluated once per action":

  setup:
    if dirExists(TmpDir):
      removeDir(TmpDir)
    createDir(TmpDir)

  when defined(posix):
    test "a parent walk through a symbolic link is resolved by each evaluation":
      # a/sub and b/sub are siblings of a/root and b/root, so
      # `<tmp>/link/../root/file` lands in a/root while `link` points at
      # a/sub, and in b/root once it points at b/sub.
      for side in ["a", "b"]:
        createDir(TmpDir / side / "sub")
        createDir(TmpDir / side / "root")
        writeFile(TmpDir / side / "root" / "file", side)
      createDir(TmpDir / "proj" / "src")
      writeFile(TmpDir / "proj" / "src" / "main.c", "int main(void){return 0;}\n")
      createSymlink(TmpDir / "a" / "sub", TmpDir / "link")
      # Spelled by hand: `/` would fold the `..` lexically.
      let walked = TmpDir & "/link/../root/file"
      let source = TmpDir / "proj" / "src" / "main.c"
      var act = action("compile", ["cc", "-c", "src/main.c"],
        cwd = TmpDir / "proj", inputs = ["src/main.c"],
        outputs = ["out/main.o"], cacheable = true,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      # The recipe ignores everything under a/root.
      act.dependencyPolicy.ignoredInputPrefixes = @[TmpDir / "a" / "root"]
      var evidence: PathSetEvidence
      evidence.declaredInputs = act.inputs
      evidence.declaredOutputs = act.outputs
      evidence.monitorReads.observeAll(evidence.evidenceProvenance,
        evcMonitorCapture, [source, walked])

      let first = act.cacheInputPaths(evidence)
      checkpoint($first)
      check first.hasPath(source)
      check not first.hasPath(walked)
      check act.hasCacheInputPath(evidence)

      removeFile(TmpDir / "link")
      createSymlink(TmpDir / "b" / "sub", TmpDir / "link")
      let second = act.cacheInputPaths(evidence)
      checkpoint($second)
      check second.hasPath(source)
      check second.hasPath(walked)

  test "the early-stopping grade agrees with the full set":
    let act = action("compile", ["cc", "-c", "src/main.c"],
      cwd = TmpDir / "proj", outputs = ["out/main.o"], cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var empty: PathSetEvidence
    check act.cacheInputPaths(empty).len == 0
    check not act.hasCacheInputPath(empty)
    var onlyOwnOutput: PathSetEvidence
    onlyOwnOutput.monitorReads.observeAll(onlyOwnOutput.evidenceProvenance,
      evcMonitorCapture, [TmpDir / "proj" / "out" / "main.o"])
    check act.cacheInputPaths(onlyOwnOutput).len == 0
    check not act.hasCacheInputPath(onlyOwnOutput)
    var real: PathSetEvidence
    real.monitorReads.observeAll(real.evidenceProvenance, evcMonitorCapture,
      [TmpDir / "proj" / "out" / "main.o", TmpDir / "proj" / "src" / "main.c"])
    check act.cacheInputPaths(real).len == 1
    check act.hasCacheInputPath(real)

  test "an executed action's keyed input set is computed once":
    let p = TmpDir / "proj"
    createDir(p / "src")
    createDir(p / "out")
    writeFile(p / "src" / "in.txt", "input\n")
    let write = builtinAction(bakWriteText, "t-write", cwd = p,
      inputs = [p / "src" / "in.txt"], outputs = [p / "out" / "out.txt"],
      text = "output\n", actionCachePolicy = ffpChecksum,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var config = defaultBuildEngineConfig(TmpDir / "cache")
    config.maxParallelism = 1
    config.actionCacheRoot = TmpDir / "action-cache"
    config.portableRoots = @[
      LogicalRoot(label: "project", path: p, kind: lrkTracked)]
    config.portableContentCheckedOnly = true
    let before = cacheInputPathsComputations()
    let run = runBuild(graph(@[write], newSeq[BuildPool]()), config)
    let after = cacheInputPathsComputations()
    var executed = 0
    for r in run.results:
      checkpoint(r.id & ": " & $r.status & " launched=" & $r.launched &
        " portable=" & r.portableStrongHex & " " & r.portableReason)
      require r.status == asSucceeded
      if r.launched:
        inc executed
    # The portable accesses were recorded (the second consumer ran).
    check run.results[0].portableStrongHex.len > 0
    check executed == 1
    check after - before == executed
