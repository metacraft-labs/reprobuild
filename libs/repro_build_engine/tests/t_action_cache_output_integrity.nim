## Action-cache integrity: outputs must be revalidated, not merely counted.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every assertion drives the real `runBuild` scheduler in
## `repro_build_engine`, the real per-edge `ActionCache` + CAS in
## `repro_local_store`, a real C compiler (`cc`), and real files in a real
## temporary directory. A mocked store would make these tests vacuous: the
## defect under test lives in the interaction between the engine's
## "outputs are present" pre-check and the store's metadata-only fast
## path, so both halves must be the production ones.
##
## The engine config below mirrors what `repro build` actually sets --
## `rebuildMissingOutputsOnCacheHit = true` and
## `deferLocalOutputBlobs = true`
## (`libs/repro_cli_support/src/repro_cli_support.nim:7058-7059`) -- so
## these tests exercise the warm in-place local-build mode users get by
## default, not the CAS-restore mode.
##
## Governing spec text:
##
## * Incremental-Invalidation.md §"Minimum check set per target
##   consultation", Step 3.3: "For an in-place local build, declared
##   outputs must already exist **and match the recorded output
##   metadata**."
## * Incremental-Invalidation.md §"Rebuild Decision Model": "required
##   outputs exist and match expected output policy"; "If any required
##   condition cannot be checked, Reprobuild MUST fail closed."
## * Incremental-Invalidation.md §"File Fingerprint Policies": hybrid
##   "compare timestamp metadata first; when the metadata changed, compute
##   the local content hash. If the content hash is unchanged, update the
##   recorded metadata and cut off without rebuilding dependents."
## * Incremental-Invalidation.md §"Validation Criteria": "hybrid mode cuts
##   off when timestamp metadata changed but the content hash is
##   unchanged".
## * Action-Cache-Per-Edge-Store.md §5.3: "Newest-corrupt rejects."

import std/[options, os, osproc, posix, strutils, tempfiles, times, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("action-cache-output-integrity." & name)

proc ccPath(): string =
  result = findExe("cc")
  if result.len == 0:
    result = findExe("gcc")

# `std/posix` does not bind `utimensat(2)`, and `os.setLastModificationTime`
# rounds through `times.Time`. The whole point of this test is a
# BIT-EXACT mtime restore, so bind the syscall directly.
let atFdCwd {.importc: "AT_FDCWD", header: "<fcntl.h>".}: cint
proc utimensatRaw(dirfd: cint; path: cstring; times: ptr Timespec;
                  flags: cint): cint
  {.importc: "utimensat", header: "<sys/stat.h>".}

proc statOf(path: string): Stat =
  doAssert lstat(path.cstring, result) == 0, "lstat failed for " & path

proc restoreTimes(path: string; saved: Stat) =
  ## Restore atime+mtime to nanosecond precision. This is the operation an
  ## attacker (or a careless restore tool) performs; POSIX offers no way to
  ## also restore st_ctime, which is the property the fix relies on.
  var ts: array[2, Timespec]
  ts[0] = saved.st_atim
  ts[1] = saved.st_mtim
  doAssert utimensatRaw(atFdCwd, path.cstring, addr ts[0], 0) == 0,
    "utimensat failed for " & path

proc corruptInPlacePreservingSizeAndMtime(path: string; offset, count: int) =
  ## Overwrite `count` bytes at `offset` with 0xCC, then put size and mtime
  ## back exactly. Size is preserved because the write is inside the file.
  let saved = statOf(path)
  var fh = open(path, fmReadWriteExisting)
  fh.setFilePos(offset)
  var filler = newString(count)
  for i in 0 ..< count:
    filler[i] = char(0xCC)
  fh.write(filler)
  fh.close()
  let after = statOf(path)
  doAssert after.st_size == saved.st_size, "corruption changed the size"
  restoreTimes(path, saved)
  let final = statOf(path)
  doAssert final.st_mtim.tv_sec == saved.st_mtim.tv_sec and
      final.st_mtim.tv_nsec == saved.st_mtim.tv_nsec,
    "mtime was not restored exactly"
  doAssert final.st_size == saved.st_size

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc launchedCount(res: BuildRunResult): int =
  for item in res.results:
    if item.launched:
      inc result

proc warmConfig(cacheRoot: string): BuildEngineConfig =
  ## Exactly the mode `repro build` runs in.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 4'u32

const ProgramSource = """
#include <stdio.h>
static int helper_one(int v) { return v + 1; }
static int helper_two(int v) { return v * 3; }
static int helper_three(int v) { return v - 7; }
int main(void) {
  int acc = 0;
  for (int i = 0; i < 64; ++i) acc += helper_three(helper_two(helper_one(i)));
  printf("OK %d\n", acc);
  return 0;
}
"""

suite "action cache output integrity":

  test "corrupted output preserving size and mtime is not reported up to date":
    let cc = ccPath()
    if cc.len == 0:
      skip()
    else:
      let tempRoot = createTempDir("repro-ac-output-corrupt", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / "cache"
      createDir(workRoot / "src")
      createDir(workRoot / "out")
      writeFile(workRoot / "src" / "prog.c", ProgramSource)

      let compile = action("compile-prog",
        [cc, "-O1", "-MD", "-MF", "out/prog.d", "-o", "out/prog",
         "src/prog.c"],
        cwd = workRoot,
        inputs = ["src/prog.c"],
        outputs = ["out/prog"],
        depfile = "out/prog.d",
        cacheable = true,
        weakFingerprint = weak("compile-prog"),
        actionCachePolicy = ffpTimestamp,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let g = graph([compile])
      let config = warmConfig(cacheRoot)

      let first = runBuild(g, config)
      check first.byId("compile-prog").status == asSucceeded
      let progPath = workRoot / "out" / "prog"
      check fileExists(progPath)
      let goodBytes = readFile(progPath)
      check goodBytes.len > 4096

      # Sanity: the freshly built program runs.
      check execProcess(progPath).strip().startsWith("OK ")

      # A warm re-run with nothing touched must be a hit -- this is the
      # property the fix must not destroy.
      let warm = runBuild(g, config)
      check warm.byId("compile-prog").cacheDecision == cdHit
      check not warm.byId("compile-prog").launched

      # Now corrupt the artifact in place, preserving size and mtime.
      corruptInPlacePreservingSizeAndMtime(progPath, goodBytes.len div 3,
        min(200 * 1024, goodBytes.len div 3))
      let corruptedDiffers = readFile(progPath) != goodBytes
      let corruptedSameLength = readFile(progPath).len == goodBytes.len
      check corruptedDiffers
      check corruptedSameLength

      let afterCorruption = runBuild(g, config)
      let r = afterCorruption.byId("compile-prog")

      # The invariant: a build that reports success must not leave a
      # corrupted declared output in place, and must not call it a hit.
      check r.cacheDecision != cdHit
      check r.status != asUpToDate
      check r.launched
      let outputRestored = readFile(progPath) == goodBytes
      check outputRestored
      check execProcess(progPath).strip().startsWith("OK ")

  test "corrupted output is not handed to a downstream consumer":
    let cc = ccPath()
    if cc.len == 0:
      skip()
    else:
      let tempRoot = createTempDir("repro-ac-output-consumer", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / "cache"
      createDir(workRoot / "src")
      createDir(workRoot / "out")
      writeFile(workRoot / "src" / "prog.c", ProgramSource)
      let runner = workRoot / "run.sh"
      writeFile(runner,
        "#!/bin/sh\n" &
        "printf '%s: %s\\n' \"$2\" \"$1\" > \"$3\"\n" &
        "exec \"$1\" > \"$2\"\n")
      setFilePermissions(runner, {fpUserRead, fpUserWrite, fpUserExec})

      let compile = action("consumer/compile",
        [cc, "-O1", "-MD", "-MF", "out/prog.d", "-o", "out/prog",
         "src/prog.c"],
        cwd = workRoot,
        inputs = ["src/prog.c"],
        outputs = ["out/prog"],
        depfile = "out/prog.d",
        cacheable = true,
        weakFingerprint = weak("consumer/compile"),
        actionCachePolicy = ffpTimestamp,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let runIt = action("consumer/run",
        [runner, "out/prog", "out/report.txt", "out/report.d"],
        cwd = workRoot,
        deps = ["consumer/compile"],
        inputs = ["out/prog"],
        outputs = ["out/report.txt"],
        depfile = "out/report.d",
        cacheable = true,
        weakFingerprint = weak("consumer/run"),
        actionCachePolicy = ffpTimestamp,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let g = graph([compile, runIt])
      let config = warmConfig(cacheRoot)

      let first = runBuild(g, config)
      check first.byId("consumer/compile").status == asSucceeded
      check first.byId("consumer/run").status == asSucceeded
      let progPath = workRoot / "out" / "prog"
      let reportPath = workRoot / "out" / "report.txt"
      let goodBytes = readFile(progPath)
      check readFile(reportPath).strip().startsWith("OK ")

      corruptInPlacePreservingSizeAndMtime(progPath, goodBytes.len div 3, 4096)
      removeFile(reportPath)

      # `out/report.txt` is gone, so `consumer/run` MUST execute. It must
      # not execute the corrupted binary: the producer has to be
      # revalidated first.
      let second = runBuild(g, config)
      check second.byId("consumer/compile").launched
      check second.byId("consumer/run").status == asSucceeded
      check readFile(reportPath).strip().startsWith("OK ")

  test "timestamp policy rebuilds on a byte-identical touch (spec'd trade)":
    # Incremental-Invalidation.md §"File Fingerprint Policies" defines the
    # timestamp policy as "compare recorded filesystem metadata such as
    # mtime, size, and file type ... suitable when the user accepts
    # Ninja-like local invalidation semantics". A byte-identical `touch`
    # therefore MUST invalidate under `ffpTimestamp`; silently making it a
    # hit would change the meaning of the default policy without saying so.
    # The spec's answer for users who want the no-op touch to be free is
    # `ffpHybrid`, asserted in the next test.
    let tempRoot = createTempDir("repro-ac-touch-timestamp", "")
    defer: removeDir(tempRoot)
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / "cache"
    createDir(workRoot / "src")
    let src = workRoot / "src" / "input.txt"
    writeFile(src, "identical bytes\n")

    let copy = builtinAction(bakCopyFile, "touch/timestamp",
      cwd = workRoot,
      inputs = ["src/input.txt"],
      outputs = ["out/copy.txt"],
      cacheable = true,
      weakFingerprint = weak("touch/timestamp"),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let g = graph([copy])
    let config = warmConfig(cacheRoot)

    check runBuild(g, config).byId("touch/timestamp").status == asSucceeded
    check runBuild(g, config).byId("touch/timestamp").cacheDecision == cdHit

    let before = readFile(src)
    setLastModificationTime(src, getTime() + initDuration(seconds = 5))
    check readFile(src) == before

    let touched = runBuild(g, config).byId("touch/timestamp")
    check touched.cacheDecision == cdMiss
    check touched.launched

  test "hybrid policy cuts off on a byte-identical touch":
    # Incremental-Invalidation.md §"Validation Criteria": "hybrid mode cuts
    # off when timestamp metadata changed but the content hash is
    # unchanged". This is the opt-in that makes a no-op touch free.
    let tempRoot = createTempDir("repro-ac-touch-hybrid", "")
    defer: removeDir(tempRoot)
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / "cache"
    createDir(workRoot / "src")
    let src = workRoot / "src" / "input.txt"
    writeFile(src, "identical bytes\n")

    let copy = builtinAction(bakCopyFile, "touch/hybrid",
      cwd = workRoot,
      inputs = ["src/input.txt"],
      outputs = ["out/copy.txt"],
      cacheable = true,
      weakFingerprint = weak("touch/hybrid"),
      actionCachePolicy = ffpHybrid,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let g = graph([copy])
    let config = warmConfig(cacheRoot)

    check runBuild(g, config).byId("touch/hybrid").status == asSucceeded
    check runBuild(g, config).byId("touch/hybrid").cacheDecision == cdHit

    let before = readFile(src)
    setLastModificationTime(src, getTime() + initDuration(seconds = 5))
    check readFile(src) == before

    let touched = runBuild(g, config).byId("touch/hybrid")
    check touched.cacheDecision in {cdHit, cdHybridCutoff}
    check not touched.launched

  test "warm re-run executes zero edges (performance regression guard)":
    # The guard the correctness fix must not break: a warm re-run of an
    # unchanged graph launches NOTHING. Without this, a later "make it
    # correct" change can silently reintroduce full rebuilds.
    let cc = ccPath()
    if cc.len == 0:
      skip()
    else:
      let tempRoot = createTempDir("repro-ac-warm-guard", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / "cache"
      createDir(workRoot / "src")
      createDir(workRoot / "out")
      var actions: seq[BuildAction] = @[]
      const EdgeCount = 8
      for i in 0 ..< EdgeCount:
        let name = "unit" & $i
        writeFile(workRoot / "src" / (name & ".c"),
          "int " & name & "_fn(int v) { return v + " & $i & "; }\n")
        actions.add action("warm/compile-" & name,
          [cc, "-O1", "-c", "-MD", "-MF", "out/" & name & ".d",
           "-o", "out/" & name & ".o", "src/" & name & ".c"],
          cwd = workRoot,
          inputs = ["src/" & name & ".c"],
          outputs = ["out/" & name & ".o"],
          depfile = "out/" & name & ".d",
          cacheable = true,
          weakFingerprint = weak("warm/compile-" & name),
          actionCachePolicy = ffpTimestamp,
          governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let g = graph(actions)
      let config = warmConfig(cacheRoot)

      let cold = runBuild(g, config)
      check cold.launchedCount == EdgeCount

      let warm = runBuild(g, config)
      check warm.launchedCount == 0
      for item in warm.results:
        check item.cacheDecision == cdHit
        check item.status in {asUpToDate, asCacheHit}
