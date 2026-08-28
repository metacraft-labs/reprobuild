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

import std/[monotimes, options, os, osproc, posix, strutils, tempfiles,
            times, unittest]

import repro_build_engine
import repro_hash
import repro_local_store
import repro_shm_index

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
let atSymlinkNofollow {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint
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

suite "action cache non-regular output integrity":
  ## Same no-mock policy and the same real `runBuild` / real `ActionCache` as
  ## the suite above. These cover the two output kinds whose recorded
  ## metadata carries nothing comparable:
  ##
  ## * a DIRECTORY output -- `fingerprintMetadata` deliberately zeroes
  ##   `sizeBytes` and `mtimeNs` for `ffkDirectory`
  ##   (repro_local_store.nim, "Existing-directory probes depend on the fact
  ##   that a directory exists"), so a kind/size/mtime comparison over a
  ##   directory reduces to "it still exists". An opaque directory output is
  ##   a shipped shape: the JS/TS convention declares `node_modules/`.
  ##
  ## * a SYMLINK output -- `fingerprintMetadata` classifies a symlink to a
  ##   file as `ffkRegular` carrying the LINK's own lstat size and mtime, so
  ##   retargeting the link and restoring its mtime with
  ##   `utimensat(AT_SYMLINK_NOFOLLOW)` compares equal.
  ##
  ## Neither needs the size-and-mtime-preserving trick the regular-file case
  ## needs; both are easier to trigger than the defect that motivated it.

  test "a rewritten file inside a directory output is not reported up to date":
    let tempRoot = createTempDir("repro-ac-dir-output", "")
    defer: removeDir(tempRoot)
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / "cache"
    createDir(workRoot / "src")
    writeFile(workRoot / "src" / "seed.txt", "seed\n")
    let gen = workRoot / "gen.sh"
    writeFile(gen,
      "#!/bin/sh\n" &
      "rm -rf out/d\n" &
      "mkdir -p out/d/nested\n" &
      "printf 'good-f\\n' > out/d/f\n" &
      "printf 'good-g\\n' > out/d/g\n" &
      "printf 'good-h\\n' > out/d/nested/h\n" &
      "printf '%s: %s\\n' out/d src/seed.txt > out/d.dep\n")
    setFilePermissions(gen, {fpUserRead, fpUserWrite, fpUserExec})

    let build = action("dir/generate", [gen],
      cwd = workRoot,
      inputs = ["src/seed.txt"],
      outputs = ["out/d"],
      depfile = "out/d.dep",
      cacheable = true,
      weakFingerprint = weak("dir/generate"),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let g = graph([build])
    let config = warmConfig(cacheRoot)

    check runBuild(g, config).byId("dir/generate").status == asSucceeded
    check runBuild(g, config).byId("dir/generate").cacheDecision == cdHit

    # Tamper with the tree's CONTENTS. No mtime restore, no size games.
    writeFile(workRoot / "out" / "d" / "f", "EVIL-PAYLOAD\n")
    removeFile(workRoot / "out" / "d" / "g")
    writeFile(workRoot / "out" / "d" / "planted", "planted\n")

    let after = runBuild(g, config).byId("dir/generate")
    check after.cacheDecision != cdHit
    check after.status != asUpToDate
    check after.launched
    let fRestored = readFile(workRoot / "out" / "d" / "f") == "good-f\n"
    let gRestored = fileExists(workRoot / "out" / "d" / "g")
    let plantedGone = not fileExists(workRoot / "out" / "d" / "planted")
    check fRestored
    check gRestored
    check plantedGone

  test "a retargeted symlink output is not reported up to date":
    let tempRoot = createTempDir("repro-ac-symlink-output", "")
    defer: removeDir(tempRoot)
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / "cache"
    createDir(workRoot / "src")
    createDir(workRoot / "out")
    writeFile(workRoot / "src" / "seed.txt", "seed\n")
    let gen = workRoot / "gen.sh"
    # `real` and `evil` are the same length, so the symlink's own lstat size
    # is identical either way -- the recorded tuple cannot tell them apart.
    writeFile(gen,
      "#!/bin/sh\n" &
      "printf 'GOOD\\n' > out/real.txt\n" &
      "printf 'EVIL\\n' > out/evil.txt\n" &
      "rm -f out/link\n" &
      "ln -s real.txt out/link\n" &
      "printf '%s: %s\\n' out/link src/seed.txt > out/link.dep\n")
    setFilePermissions(gen, {fpUserRead, fpUserWrite, fpUserExec})

    let build = action("symlink/generate", [gen],
      cwd = workRoot,
      inputs = ["src/seed.txt"],
      outputs = ["out/link"],
      depfile = "out/link.dep",
      cacheable = true,
      weakFingerprint = weak("symlink/generate"),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let g = graph([build])
    let config = warmConfig(cacheRoot)

    check runBuild(g, config).byId("symlink/generate").status == asSucceeded
    check runBuild(g, config).byId("symlink/generate").cacheDecision == cdHit
    let linkPath = workRoot / "out" / "link"
    check expandSymlink(linkPath) == "real.txt"

    # Retarget, then put the link's own lstat mtime back exactly.
    let saved = statOf(linkPath)
    removeFile(linkPath)
    createSymlink("evil.txt", linkPath)
    var ts: array[2, Timespec]
    ts[0] = saved.st_atim
    ts[1] = saved.st_mtim
    doAssert utimensatRaw(atFdCwd, linkPath.cstring, addr ts[0],
      atSymlinkNofollow) == 0
    let live = statOf(linkPath)
    doAssert live.st_size == saved.st_size, "link size changed"
    doAssert live.st_mtim.tv_sec == saved.st_mtim.tv_sec and
      live.st_mtim.tv_nsec == saved.st_mtim.tv_nsec, "link mtime not restored"

    let after = runBuild(g, config).byId("symlink/generate")
    check after.cacheDecision != cdHit
    check after.status != asUpToDate
    check after.launched
    check expandSymlink(linkPath) == "real.txt"

  test "a record with no output witness fails closed for a directory, open for a file":
    ## The witness sidecar is what carries the change time, the symlink target
    ## and the directory tree digest. A cache populated before this change has
    ## none, and neither does a record served from the shared-memory tier.
    ## Deleting the sidecar reproduces that state exactly.
    ##
    ## The two kinds must then behave DIFFERENTLY, and both behaviours are
    ## deliberate:
    ##
    ## * regular file -> still a hit. The kind/size/mtime comparison is weaker
    ##   than the change-time one but it is not vacuous, and failing closed
    ##   here would force a full rebuild of every edge in every existing cache
    ##   on upgrade. The consequence is that the corruption defect stays open
    ##   for a pre-existing record until its edge next executes.
    ##
    ## * directory -> a miss. `fingerprintMetadata` zeroes size and mtime for
    ##   `ffkDirectory`, so with no digest there is nothing to compare and the
    ##   check cannot be performed at all. Incremental-Invalidation.md
    ##   §"Rebuild Decision Model" requires failing closed when a required
    ##   condition cannot be checked. The cost is one re-execution per such
    ##   edge, after which the replacement record carries a digest.
    proc dropWitnesses(cacheRoot: string): int =
      for path in walkDirRec(cacheRoot):
        if path.endsWith(".octime"):
          removeFile(path)
          inc result

    block regularFileDegradesToAHit:
      let tempRoot = createTempDir("repro-ac-nowitness-file", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / "cache"
      createDir(workRoot / "src")
      writeFile(workRoot / "src" / "input.txt", "payload\n")
      let copy = builtinAction(bakCopyFile, "nowitness/file",
        cwd = workRoot,
        inputs = ["src/input.txt"],
        outputs = ["out/copy.txt"],
        cacheable = true,
        weakFingerprint = weak("nowitness/file"),
        actionCachePolicy = ffpTimestamp,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let g = graph([copy])
      let config = warmConfig(cacheRoot)
      check runBuild(g, config).byId("nowitness/file").status == asSucceeded
      check dropWitnesses(cacheRoot) > 0
      let after = runBuild(g, config).byId("nowitness/file")
      check after.cacheDecision == cdHit
      check not after.launched

    block directoryFailsClosed:
      let tempRoot = createTempDir("repro-ac-nowitness-dir", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / "cache"
      createDir(workRoot / "src")
      writeFile(workRoot / "src" / "seed.txt", "seed\n")
      let gen = workRoot / "gen.sh"
      writeFile(gen,
        "#!/bin/sh\n" &
        "rm -rf out/d\n" &
        "mkdir -p out/d\n" &
        "printf 'good\\n' > out/d/f\n" &
        "printf '%s: %s\\n' out/d src/seed.txt > out/d.dep\n")
      setFilePermissions(gen, {fpUserRead, fpUserWrite, fpUserExec})
      let build = action("nowitness/dir", [gen],
        cwd = workRoot,
        inputs = ["src/seed.txt"],
        outputs = ["out/d"],
        depfile = "out/d.dep",
        cacheable = true,
        weakFingerprint = weak("nowitness/dir"),
        actionCachePolicy = ffpTimestamp,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let g = graph([build])
      let config = warmConfig(cacheRoot)
      check runBuild(g, config).byId("nowitness/dir").status == asSucceeded
      check runBuild(g, config).byId("nowitness/dir").cacheDecision == cdHit
      check dropWitnesses(cacheRoot) > 0
      let after = runBuild(g, config).byId("nowitness/dir")
      check after.cacheDecision != cdHit
      check after.launched
      # And the re-execution restores a witness, so the NEXT build is a hit
      # again -- the fail-closed cost is one rebuild per edge, not permanent.
      let recovered = runBuild(g, config).byId("nowitness/dir")
      check recovered.cacheDecision == cdHit
      check not recovered.launched

suite "action cache output integrity under the real cache daemon":
  ## NO MOCKS, and specifically no hand-driven stand-in for the daemon: these
  ## spawn the PRODUCTION `repro-cache-daemon` binary via
  ## `REPRO_CACHE_DAEMON_BIN`, exactly as `repro build` does, and set
  ## `config.actionCacheRoot` so the engine attaches the shared-memory tier
  ## (`attachActionCacheShm = config.actionCacheRoot.len > 0`,
  ## repro_build_engine.nim). The suites above left `actionCacheRoot` empty,
  ## which is why they never attached shm, never spawned a daemon, and missed
  ## the defect this suite covers.
  ##
  ## The daemon decodes each record from its shm slot -- a plain record frame,
  ## carrying no output witness by construction -- and republishes it through
  ## `writePerEdgeRecords`. If that republish is allowed to overwrite the
  ## witness sidecar, every witness for an shm-eligible edge is destroyed
  ## shortly after it is written, and the corruption check silently reverts to
  ## the size+mtime comparison it was introduced to replace.

  proc daemonBinary(): string =
    for candidate in [getCurrentDir() / "build" / "bin" / "repro-cache-daemon",
                      getAppDir() / ".." / "bin" / "repro-cache-daemon"]:
      if fileExists(candidate):
        return candidate
    ""

  proc recFiles(actionCacheRoot: string): seq[string] =
    for path in walkDirRec(actionCacheRoot):
      if path.endsWith(".rec"):
        result.add(path)

  proc witnessBytes(actionCacheRoot: string):
      tuple[files: int; nonZero: int; total: int] =
    for path in walkDirRec(actionCacheRoot):
      if path.endsWith(".octime"):
        inc result.files
        let raw = readFile(path)
        result.total += raw.len
        for c in raw:
          if c != '\0':
            inc result.nonZero

  proc daemonConfig(cacheRoot, actionCacheRoot: string): BuildEngineConfig =
    result = warmConfig(cacheRoot)
    result.actionCacheRoot = actionCacheRoot

  proc waitForDaemonRepublish(actionCacheRoot: string;
                              before: seq[(string, times.Time)];
                              timeoutMs = 30_000): bool =
    ## Poll until the daemon rewrites at least one `.rec` it did not write
    ## itself. Returns false on timeout so the caller can FAIL rather than
    ## quietly pass a test the daemon never participated in.
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while getMonoTime() < deadline:
      for path in recFiles(actionCacheRoot):
        var wasSeen = false
        for (p, t) in before:
          if p == path:
            wasSeen = true
            if getLastModificationTime(path) != t:
              return true
        if not wasSeen:
          return true
      sleep(100)
    false

  test "the cache daemon republishing a record must not destroy its witness":
    let daemon = daemonBinary()
    if daemon.len == 0:
      # Non-vacuous by construction: without the real daemon this test cannot
      # say anything, and saying so is better than passing.
      checkpoint("repro-cache-daemon not built; run `just build` first")
      fail()
    else:
      putEnv("REPRO_CACHE_DAEMON_BIN", daemon)
      # The daemon is a SEPARATE binary, so this test silently depends on it
      # having been rebuilt from the current source. A daemon older than
      # `repro_local_store.nim` still carries the old republish behaviour and
      # fails the assertions below for a reason that has nothing to do with
      # the code under test. Say so rather than let it look like a real
      # regression.
      let storeSource = getCurrentDir() / "libs" / "repro_local_store" /
        "src" / "repro_local_store.nim"
      if fileExists(storeSource) and
          getLastModificationTime(daemon) < getLastModificationTime(storeSource):
        checkpoint("WARNING: " & daemon & " is OLDER than " & storeSource &
          " -- rebuild it (`just build`, or nim c the " &
          "apps/repro-cache-daemon entrypoint) before trusting this result.")
      # NOT `createTempDir`, deliberately. `submitToShm` drops any record
      # whose ENCODED size exceeds `SlotInlineCap` (256 B), and that encoding
      # is dominated by absolute path strings -- so whether the shared-memory
      # tier engages at all is a function of how long the temp path is.
      # Measured on this graph: a 19-character root encodes to 173 B and the
      # daemon republishes; a 104-character root encodes to 258 B, the submit
      # is silently dropped, and no daemon work ever happens. Inheriting
      # TMPDIR therefore makes this test pass or fail on path length, which
      # is exactly the kind of environment-dependence that makes a suite
      # untrustworthy. Pin a short root instead.
      let shortRoot = "/tmp/rbclob-" & $getCurrentProcessId()
      removeDir(shortRoot)
      createDir(shortRoot)
      let tempRoot = shortRoot
      defer:
        delEnv("REPRO_CACHE_DAEMON_BIN")
        # The daemon is a live process still writing into this tree; a single
        # removeDir races it. Teardown is not the property under test, so
        # retry briefly and give up quietly rather than fail the assertions
        # that already ran.
        for _ in 0 .. 20:
          try:
            removeDir(tempRoot)
            break
          except OSError:
            sleep(200)
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / "cache"
      let actionCacheRoot = tempRoot / "acr"
      createDir(actionCacheRoot)
      createDir(workRoot / "src")
      writeFile(workRoot / "src" / "i.txt", "payload\n")

      let copy = builtinAction(bakCopyFile, "daemon/copy",
        cwd = workRoot,
        inputs = ["src/i.txt"],
        outputs = ["out/c.txt"],
        cacheable = true,
        weakFingerprint = weak("daemon/copy"),
        actionCachePolicy = ffpTimestamp,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let g = graph([copy])
      let config = daemonConfig(cacheRoot, actionCacheRoot)

      check runBuild(g, config).byId("daemon/copy").status == asSucceeded
      let witnessedBefore = witnessBytes(actionCacheRoot)
      check witnessedBefore.files > 0
      check witnessedBefore.nonZero > 0

      var stamps: seq[(string, times.Time)] = @[]
      for path in recFiles(actionCacheRoot):
        stamps.add((path, getLastModificationTime(path)))
      check stamps.len > 0

      # The daemon can only republish a record the engine actually submitted,
      # and the engine only submits records that fit the inline slot. Measure
      # it rather than assume it, so a too-large record reports THAT instead
      # of masquerading as "the daemon never ran".
      var encodedBytes = 0
      var probe = openActionCache(actionCacheRoot / "action-cache",
        attachShm = false)
      for record in probe.loadPerEdgeRecords(copy.weakFingerprint):
        encodedBytes = max(encodedBytes, encodeActionResultRecord(record).len)
      checkpoint("encoded record = " & $encodedBytes &
        " B, inline slot cap = " & $SlotInlineCap & " B")
      if encodedBytes == 0 or encodedBytes > SlotInlineCap:
        # Never a silent pass: say why the property could not be exercised.
        checkpoint("SKIPPED: record does not fit the shared-memory slot, so " &
          "the engine never submits it and the daemon has nothing to " &
          "republish. This test cannot exercise the clobber here.")
        skip()
      else:
        # Let the production daemon drain its ring and republish.
        let republished = waitForDaemonRepublish(actionCacheRoot, stamps)
        checkpoint("daemon republished the record: " & $republished)
        check republished

        let witnessedAfter = witnessBytes(actionCacheRoot)
        check witnessedAfter.files == witnessedBefore.files
        # The witness must survive the republish byte for byte. Pre-fix this
        # is where it was zeroed.
        check witnessedAfter.nonZero == witnessedBefore.nonZero

        # And the property the witness exists for must still hold end to end.
        let outPath = workRoot / "out" / "c.txt"
        let good = readFile(outPath)
        corruptInPlacePreservingSizeAndMtime(outPath, 1, good.len - 2)
        let corrupted = readFile(outPath) != good
        check corrupted

        let after = runBuild(g, config).byId("daemon/copy")
        check after.cacheDecision != cdHit
        check after.launched
        let restored = readFile(outPath) == good
        check restored

  test "a symlink to a directory is checked as a directory too":
    ## `fingerprintMetadata` classifies a symlink-to-directory as
    ## `ffkDirectory`, so a tree digest IS recorded for it. If the symlink
    ## branch of the comparison returns early once the link target matches,
    ## that digest is never compared and tampering INSIDE the linked tree
    ## survives. The two checks have to be additive.
    let tempRoot = createTempDir("repro-ac-symlink-dir", "")
    defer: removeDir(tempRoot)
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / "cache"
    createDir(workRoot / "src")
    createDir(workRoot / "out")
    writeFile(workRoot / "src" / "seed.txt", "seed\n")
    let gen = workRoot / "gen.sh"
    writeFile(gen,
      "#!/bin/sh\n" &
      "rm -rf out/real out/link\n" &
      "mkdir -p out/real\n" &
      "printf 'good\\n' > out/real/f\n" &
      "ln -s real out/link\n" &
      "printf '%s: %s\\n' out/link src/seed.txt > out/link.dep\n")
    setFilePermissions(gen, {fpUserRead, fpUserWrite, fpUserExec})

    let build = action("symlinkdir/generate", [gen],
      cwd = workRoot,
      inputs = ["src/seed.txt"],
      outputs = ["out/link"],
      depfile = "out/link.dep",
      cacheable = true,
      weakFingerprint = weak("symlinkdir/generate"),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let g = graph([build])
    let config = warmConfig(cacheRoot)

    check runBuild(g, config).byId("symlinkdir/generate").status == asSucceeded
    check runBuild(g, config).byId("symlinkdir/generate").cacheDecision == cdHit

    # The link still points at `real`; only the CONTENT behind it changes.
    writeFile(workRoot / "out" / "real" / "f", "EVIL\n")
    check expandSymlink(workRoot / "out" / "link") == "real"

    let after = runBuild(g, config).byId("symlinkdir/generate")
    check after.cacheDecision != cdHit
    check after.launched
    let restored = readFile(workRoot / "out" / "real" / "f") == "good\n"
    check restored

  test "an EMPTY directory output with no witness fails closed":
    ## The `hasTreeDigest` guard is load-bearing exactly here. An empty
    ## directory's metadata digest is 0, which is also the value a witness-free
    ## record carries, so without the explicit guard "no evidence recorded"
    ## and "the tree is empty and unchanged" become the same answer. Zeroed
    ## sidecars are a production reality (see the daemon test above), so this
    ## is reachable, not theoretical.
    let tempRoot = createTempDir("repro-ac-empty-dir", "")
    defer: removeDir(tempRoot)
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / "cache"
    createDir(workRoot / "src")
    writeFile(workRoot / "src" / "seed.txt", "seed\n")
    let gen = workRoot / "gen.sh"
    writeFile(gen,
      "#!/bin/sh\n" &
      "rm -rf out/empty\n" &
      "mkdir -p out/empty\n" &
      "printf '%s: %s\\n' out/empty src/seed.txt > out/empty.dep\n")
    setFilePermissions(gen, {fpUserRead, fpUserWrite, fpUserExec})

    let build = action("emptydir/generate", [gen],
      cwd = workRoot,
      inputs = ["src/seed.txt"],
      outputs = ["out/empty"],
      depfile = "out/empty.dep",
      cacheable = true,
      weakFingerprint = weak("emptydir/generate"),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let g = graph([build])
    let config = warmConfig(cacheRoot)

    check runBuild(g, config).byId("emptydir/generate").status == asSucceeded
    check runBuild(g, config).byId("emptydir/generate").cacheDecision == cdHit

    # Zero every witness in place, the way a witness-free republish would.
    var zeroed = 0
    for path in walkDirRec(cacheRoot):
      if path.endsWith(".octime"):
        let raw = readFile(path)
        writeFile(path, repeat('\0', raw.len))
        inc zeroed
    check zeroed > 0

    let after = runBuild(g, config).byId("emptydir/generate")
    check after.cacheDecision != cdHit
    check after.launched

  test "revalidation counters separate record-time walks and do not accumulate":
    ## The metric is the thing that tells a reviewer what the check costs, so
    ## it gets a test of its own. Three properties, each of which was wrong:
    ##
    ## * a COLD build walks the tree to RECORD a directory output; that is
    ##   execution cost, not revalidation cost, and must not be counted as
    ##   revalidation. Reported against a target with no directory output the
    ##   distinction is invisible, so this uses one that has a directory.
    ## * a WARM build walks it once to revalidate.
    ## * the counters are process-global, so they must be zeroed per build or
    ##   the second build in a process reports its own cost plus the first's.
    let tempRoot = createTempDir("repro-ac-instrumentation", "")
    defer: removeDir(tempRoot)
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / "cache"
    createDir(workRoot / "src")
    writeFile(workRoot / "src" / "seed.txt", "seed\n")
    let gen = workRoot / "gen.sh"
    writeFile(gen,
      "#!/bin/sh\n" &
      "rm -rf out/d\n" &
      "mkdir -p out/d\n" &
      "for i in 1 2 3 4 5; do printf 'x\\n' > out/d/f$i; done\n" &
      "printf '%s: %s\\n' out/d src/seed.txt > out/d.dep\n")
    setFilePermissions(gen, {fpUserRead, fpUserWrite, fpUserExec})

    let build = action("instrument/dir", [gen],
      cwd = workRoot,
      inputs = ["src/seed.txt"],
      outputs = ["out/d"],
      depfile = "out/d.dep",
      cacheable = true,
      weakFingerprint = weak("instrument/dir"),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let g = graph([build])
    let config = warmConfig(cacheRoot)

    check runBuild(g, config).byId("instrument/dir").status == asSucceeded
    let cold = outputStateCheckStats()
    check cold.recordDirWalks == 1        # the tree was walked to record it
    check cold.recordDirEntries == 5      # 5 files, no nested dirs
    check cold.revalidateDirWalks == 0    # ... and NOT counted as revalidation
    check cold.revalidateDirEntries == 0

    check runBuild(g, config).byId("instrument/dir").cacheDecision == cdHit
    let warm = outputStateCheckStats()
    check warm.revalidateDirWalks == 1
    check warm.revalidateDirEntries == 5
    check warm.recordDirWalks == 0        # nothing was recorded this build

    # A third build must report its own cost, not the running total.
    check runBuild(g, config).byId("instrument/dir").cacheDecision == cdHit
    let warmAgain = outputStateCheckStats()
    check warmAgain.revalidateDirWalks == 1
    check warmAgain.revalidateDirEntries == 5
    check warmAgain.calls == warm.calls
