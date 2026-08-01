## The infra-apply action-edge dispatch must treat a cache hit whose
## declared outputs are already on disk as a no-op.
##
## ``applyBuildActionsEngineConfig`` builds the ``BuildEngineConfig``
## used by ``repro infra apply`` for the build-action half of an apply.
## It previously inherited ``rebuildMissingOutputsOnCacheHit = false``
## from ``defaultBuildEngineConfig``, which makes the engine call
## ``LocalCas.restoreOutputs`` on every cache hit. ``restoreOutputs``
## rewrites each declared output through a temp-file + unlink + rename
## sequence even when the bytes on disk are already correct, so a cache
## hit DESTROYS and recreates outputs that needed no change at all.
##
## With the flag set, an all-outputs-present hit is served by the
## engine's whole-graph fast no-op scan (``tryFastNoopCacheHits``, which
## is itself gated on this flag) and reported as ``asCacheHit`` without
## the scheduler ever running; if that scan declines, the per-action
## outputs-present branch reports ``asUpToDate``. Neither path calls
## ``restoreOutputs``, so the tests below accept either status and rely
## on the inode/mtime assertion for the real claim.
##
## Three properties are pinned here:
##   1. a cache hit with outputs present does not rewrite them,
##   2. a cache hit with outputs missing still regenerates them,
##   3. a cache hit whose present output cannot be rewritten still
##      succeeds.
##
## APPROXIMATION NOTICE — read before trusting this test's scope.
## Property 3 is the regression that motivated the fix. In production
## the unrewritable output is a Windows executable image that a
## concurrently running process has mapped: the platform refuses to
## unlink it and ``restoreOutputs`` raises out of ``runBuild``. That
## condition CANNOT be reproduced on Linux and this test does not
## reproduce it. The analogue used here is an output file that exists
## and is readable but whose PARENT DIRECTORY is not writable, so the
## restore path cannot stage its temp file. The two differ in which leg
## of ``restoreOutputs`` fails — the Windows case fails at
## ``removeFile(dest)``, this one fails earlier at
## ``writeFile(tmp)``. What both share, and what this test actually
## pins, is the property the fix relies on: when the outputs are
## already present and correct, the engine must not enter
## ``restoreOutputs`` AT ALL, so no leg of it can fail. A test that
## enters the restore path fails under either condition; a test that
## short-circuits before it passes under both.
##
## Note on property 3's guard: the unwritable-directory analogue is
## only meaningful for an unprivileged user, since root bypasses the
## directory write bit. The case is skipped when running as root rather
## than passing vacuously.
##
## Note on property 2: the flag is named ``rebuildMissingOutputsOnCache
## Hit`` because a hit with MISSING outputs is downgraded to a miss and
## the action is RE-EXECUTED — it is not restored from the CAS. The
## assertion below is written against that actual contract (the output
## comes back, produced by a relaunch) rather than against a restore
## that does not happen on this path.
##
## No mocks. The test drives the real build engine through the real
## ``applyBuildActionsEngineConfig`` against a real on-disk action
## cache and CAS in a real temp directory, with a real ``bakWriteText``
## action. The elevation spawner is passed as ``nil`` because no action
## here sets ``requiresElevation``; that is an unused seam, not a
## stubbed collaborator. Nothing is faked, so no mock justification is
## required.

import std/[os, posix, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store
import repro_profile_compile

import repro_test_support

proc fingerprintForPayload(payload: string): ContentDigest =
  casDigest(payload.toOpenArrayByte(0, payload.high),
            domain = hdActionFingerprint)

proc oneWriteTextAction(outputPath, payload, token: string): BuildGraph =
  let action = BuildAction(
    kind: bakWriteText,
    id: "t-apply-cache-hit",
    deps: @[],
    inputs: @[],
    outputs: @[outputPath],
    cacheable: true,
    actionCachePolicy: ffpTimestamp,
    weakFingerprint: fingerprintForPayload(payload & "|" & token),
    builtinText: payload)
  graph(@[action], newSeq[BuildPool]())

proc applyCfg(cacheRoot: string): BuildEngineConfig =
  ## The exact config `repro infra apply` uses for build-action edges.
  applyBuildActionsEngineConfig(cacheRoot, nil)

type FileIdentity = object
  inode: uint64
  mtimeSec: int64
  mtimeNsec: int64

proc identityOf(path: string): FileIdentity =
  var st: Stat
  doAssert stat(path, st) == 0, "stat failed for " & path
  FileIdentity(
    inode: uint64(st.st_ino),
    mtimeSec: int64(st.st_mtim.tv_sec),
    mtimeNsec: int64(st.st_mtim.tv_nsec))

proc leakedTempFiles(dir: string): seq[string] =
  result = @[]
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    if kind == pcFile and path.extractFilename.contains(".reprotmp."):
      result.add(path.extractFilename)

suite "integration_infra_apply_cache_hit_preserves_present_outputs":
  when isNixSupported:

    test "a cache hit with outputs present does not rewrite them":
      let tempRoot = createTempDir("repro-apply-hit-present", "")
      defer: removeDir(tempRoot)

      let cacheRoot = tempRoot / "cache"
      let outDir = tempRoot / "out"
      createDir(cacheRoot)
      createDir(outDir)
      let outputPath = absolutePath(outDir / "artifact.bin")
      let payload = "apply payload\n"
      let g = oneWriteTextAction(outputPath, payload, "present")

      # First run produces the output and populates the action cache.
      let first = runBuild(g, applyCfg(cacheRoot))
      check first.results.len == 1
      check first.results[0].status == asSucceeded
      check readFile(outputPath) == payload

      let before = identityOf(outputPath)

      # Second run is a cache hit with the output already on disk. The
      # engine must short-circuit and leave the file completely alone.
      let second = runBuild(g, applyCfg(cacheRoot))
      check second.results.len == 1
      # Either short-circuit is acceptable and both mean "hit, nothing
      # rebuilt": the whole-graph fast no-op scan reports asCacheHit,
      # the per-action outputs-present branch reports asUpToDate. What
      # must NOT happen is asSucceeded, which would mean the action was
      # relaunched. The inode assertion below is the load-bearing one.
      check second.results[0].status in {asCacheHit, asUpToDate}
      check readFile(outputPath) == payload

      let after = identityOf(outputPath)

      # A temp-file + rename rewrite always yields a NEW inode, so the
      # inode check alone falsifies the destructive path. mtime is
      # asserted too so an in-place rewrite would also be caught.
      check after.inode == before.inode
      check after.mtimeSec == before.mtimeSec
      check after.mtimeNsec == before.mtimeNsec
      check leakedTempFiles(outDir) == newSeq[string]()

    test "a cache hit with outputs missing still regenerates them":
      let tempRoot = createTempDir("repro-apply-hit-missing", "")
      defer: removeDir(tempRoot)

      let cacheRoot = tempRoot / "cache"
      let outDir = tempRoot / "out"
      createDir(cacheRoot)
      createDir(outDir)
      let outputPath = absolutePath(outDir / "artifact.bin")
      let payload = "apply payload missing\n"
      let g = oneWriteTextAction(outputPath, payload, "missing")

      let first = runBuild(g, applyCfg(cacheRoot))
      check first.results.len == 1
      check first.results[0].status == asSucceeded

      # Delete the output. The next run must NOT report up-to-date and
      # must put the declared output back.
      removeFile(outputPath)
      check not fileExists(outputPath)

      let second = runBuild(g, applyCfg(cacheRoot))
      check second.results.len == 1
      # Downgraded to a miss and relaunched — NOT restored from the CAS.
      check second.results[0].status == asSucceeded
      check fileExists(outputPath)
      check readFile(outputPath) == payload
      check leakedTempFiles(outDir) == newSeq[string]()

    test "a cache hit whose present output cannot be rewritten succeeds":
      if geteuid() == 0:
        skip()
      else:
        let tempRoot = createTempDir("repro-apply-hit-locked", "")
        # The read-only directory has to be restored before the tree can
        # be torn down.
        defer:
          discard chmod(cstring(tempRoot / "out"), 0o755)
          removeDir(tempRoot)

        let cacheRoot = tempRoot / "cache"
        let outDir = tempRoot / "out"
        createDir(cacheRoot)
        createDir(outDir)
        let outputPath = absolutePath(outDir / "artifact.bin")
        let payload = "apply payload locked\n"
        let g = oneWriteTextAction(outputPath, payload, "locked")

        let first = runBuild(g, applyCfg(cacheRoot))
        check first.results.len == 1
        check first.results[0].status == asSucceeded
        check readFile(outputPath) == payload

        # Make the output's directory unwritable. The file itself stays
        # present and readable, so the outputs-present short-circuit is
        # satisfied, but any attempt to stage a temp file beside it or
        # unlink it now fails with EACCES.
        doAssert chmod(cstring(outDir), 0o555) == 0
        check fileExists(outputPath)

        # This is the regression: before the fix the engine took the
        # restore path here and the OSError escaped runBuild, failing
        # the whole dispatch.
        var raised = ""
        var status = asFailed
        try:
          let second = runBuild(g, applyCfg(cacheRoot))
          check second.results.len == 1
          status = second.results[0].status
        except CatchableError as err:
          raised = $err.name & ": " & err.msg

        check raised == ""
        check status in {asCacheHit, asUpToDate}
        check readFile(outputPath) == payload

        doAssert chmod(cstring(outDir), 0o755) == 0
        check leakedTempFiles(outDir) == newSeq[string]()
