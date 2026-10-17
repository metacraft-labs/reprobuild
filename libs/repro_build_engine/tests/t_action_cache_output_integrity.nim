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

suite "action cache output integrity across a witness-free republish":
  ## THIS SUITE WAS REWRITTEN, AND THE SUBJECT MOVED RATHER THAN SHRANK.
  ##
  ## It used to spawn the production `repro-cache-daemon`, because the daemon
  ## decoded each record out of its shared-memory slot — a plain record frame,
  ## carrying no output witness by construction — and republished it through
  ## `writePerEdgeRecords`. Letting that republish overwrite the `.octime`
  ## sidecar destroyed every witness for a shm-eligible edge seconds after it
  ## was written, silently reverting the corruption check to the size+mtime
  ## comparison it exists to replace.
  ##
  ## There is no daemon now: Tier 2 is a shared-memory grow-only set of
  ## REFERENCES that every engine inserts into directly, and it never carries a
  ## record, so it can never republish one. What has NOT gone away is the
  ## witness-free republish itself — the peer-cache installer
  ## (`appendActionResultRecord`) does exactly that, writing a remote record
  ## whose frame carries no witness over an edge whose local outputs are
  ## already witnessed. That is the same clobber with a different caller, so
  ## the case now drives it through the caller that still exists.
  ##
  ## This is also STRONGER than what it replaces, in one specific way: the old
  ## version could not run at all when the record exceeded the 256-byte inline
  ## submission slot, and skipped itself with a diagnostic when it did. Since
  ## the encoded size is dominated by absolute path strings, whether the test
  ## exercised anything was a function of how long `$TMPDIR` happened to be —
  ## which is why it pinned a short root under `/tmp`. No size threshold is
  ## involved any more, so it runs everywhere and needs no such pin.

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

  test "a witness-free republish must not destroy an existing witness":
    let tempRoot = createTempDir("repro-ac-republish", "")
    defer: removeDir(tempRoot)
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / "cache"
    let actionCacheRoot = tempRoot / "acr"
    createDir(actionCacheRoot)
    createDir(workRoot / "src")
    writeFile(workRoot / "src" / "i.txt", "payload\n")

    let copy = builtinAction(bakCopyFile, "republish/copy",
      cwd = workRoot,
      inputs = ["src/i.txt"],
      outputs = ["out/c.txt"],
      cacheable = true,
      weakFingerprint = weak("republish/copy"),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let g = graph([copy])
    var config = warmConfig(cacheRoot)
    config.actionCacheRoot = actionCacheRoot

    check runBuild(g, config).byId("republish/copy").status == asSucceeded
    let witnessedBefore = witnessBytes(actionCacheRoot)
    check witnessedBefore.files > 0
    check witnessedBefore.nonZero > 0

    # Re-publish the edge's record through the SAME entry point the peer-cache
    # installer uses, from a record frame that carries no witness — the exact
    # shape a remote bundle decodes to.
    var store = openActionCache(actionCacheRoot / "action-cache")
    var republished = 0
    for record in store.loadPerEdgeRecords(copy.weakFingerprint):
      let frame = decodeActionResultRecord(encodeActionResultRecord(record))
      store.appendActionResultRecord(frame)
      inc republished
    store.closeShmTier()
    check republished > 0

    let witnessedAfter = witnessBytes(actionCacheRoot)
    check witnessedAfter.files == witnessedBefore.files
    # The witness must survive the republish byte for byte. Pre-fix this is
    # where it was zeroed.
    check witnessedAfter.nonZero == witnessedBefore.nonZero

    # And the property the witness exists for must still hold end to end.
    let outPath = workRoot / "out" / "c.txt"
    let good = readFile(outPath)
    corruptInPlacePreservingSizeAndMtime(outPath, 1, good.len - 2)
    check readFile(outPath) != good
    let after = runBuild(g, config).byId("republish/copy")
    check after.cacheDecision != cdHit
    check after.launched
    check readFile(outPath) == good

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

suite "action cache container directory outputs":
  ## Same no-mock policy, the same real `runBuild` / real `ActionCache`, and
  ## the same warm in-place configuration `repro build` uses.
  ##
  ## Some built-in actions declare a directory as an output only to say that
  ## the directory exists. `fs.ensureDir` creates the directory and nothing
  ## else. `fs.preserveTree` declares its output root together with each entry
  ## it copies, plus a manifest. Other actions then write their own outputs
  ## into that directory: CodeTracer's C compiles write into its `build-c-dir`,
  ## and its `frontend-public-ui-js` copy writes into the
  ## `frontend-public-resources` tree. The directory's contents therefore
  ## belong to other writers.
  ##
  ## The recursive tree digest that protects an OPAQUE directory output
  ## (`node_modules/`, a webpack `dist/`) is the wrong check here. It folds in
  ## every byte another action writes, so a warm build after the first sees
  ## "directory output contents changed" and re-runs a built-in that has
  ## nothing to restore (reprobuild-pm issue
  ## 2026-10-05-codetracer-in-place-frontend-aggregate-and-m52-diverge-from-
  ## the-pinned-codetracer.md, finding 1). Re-running it cannot change that
  ## content either: `ensureDir` writes nothing into the directory, and
  ## `preserveTree` neither owns nor removes entries it did not copy.
  ##
  ## Governing spec text: Incremental-Invalidation.md §"Non-regular outputs"
  ## ("Container directory outputs"), and Failure-Semantics.md §"General
  ## Rules": a rejected lookup must say why.

  proc writeIntoDirAction(id, dirOutput, fileName: string; dep: string;
                          workRoot: string): BuildAction =
    ## A process action that writes ONE declared file into `dirOutput`, the
    ## shape of a compiler writing `build/c/main.o` into `build-c-dir`.
    let script = workRoot / (fileName & ".sh")
    writeFile(script,
      "#!/bin/sh\n" &
      "printf 'payload\\n' > " & dirOutput & "/" & fileName & "\n" &
      "printf '%s: %s\\n' " & dirOutput & "/" & fileName &
      " src/seed.txt > out/" & fileName & ".dep\n")
    setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
    action(id, [script],
      cwd = workRoot,
      deps = [dep],
      inputs = ["src/seed.txt"],
      outputs = [dirOutput & "/" & fileName],
      depfile = "out/" & fileName & ".dep",
      cacheable = true,
      weakFingerprint = weak(id),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

  proc describe(item: ActionResult): string =
    item.id & " status=" & $item.status & " launched=" & $item.launched &
      " cacheDecision=" & $item.cacheDecision & " reason=" & item.reason &
      " cacheMissReason=" & item.cacheMissReason

  type
    WarmArm = enum
      ## The revalidation paths a warm build of an unchanged graph can take.
      ## Each one checks the record's outputs on its own, so each one must
      ## be handed the action's containers: a fix wired to one of them takes
      ## effect or not depending on which arm the graph happened to take.
      waProbeScan
        ## The whole-graph fast no-op, `skipCacheHitEvidence = true` arm
        ## (`scanHotIndexMetadataInputsUnchanged`). What `repro build` runs.
      waPerRecordScan
        ## The whole-graph fast no-op, per-record arm (evidence wanted).
      waScheduler
        ## The per-edge lookup, reached because a progress callback without
        ## `fastNoopReportsProgress` disables the whole-graph prefix.
      waRestoreMode
        ## The CAS-restore mode (`rebuildMissingOutputsOnCacheHit = false`):
        ## the per-edge lookup, then `restoreWouldOverwriteMatchingOutputs`.

  proc armConfig(cacheRoot: string; arm: WarmArm): BuildEngineConfig =
    result = warmConfig(cacheRoot)
    result.statsEnabled = true
    case arm
    of waProbeScan:
      result.skipCacheHitEvidence = true
    of waPerRecordScan:
      result.skipCacheHitEvidence = false
    of waScheduler:
      result.progressCallback = proc(event: BuildProgressEvent) = discard
    of waRestoreMode:
      result.rebuildMissingOutputsOnCacheHit = false
      result.deferLocalOutputBlobs = false

  proc answeredByWholeGraphPrefix(run: BuildRunResult): bool =
    ## Only the whole-graph fast no-op emits this metric, on both of its
    ## arms, and only when it answered the build. Without it a warm build
    ## that fell back to the scheduler looks identical from the results.
    for metric in run.stats.metrics:
      if metric.name == "repro cache hit result materialize":
        return true
    false

  type
    ContainerFixture = object
      ## One graph in its own temporary tree: a container built-in and the
      ## process actions that write into it.
      root, work, cache: string
      g: BuildGraph
      containerId: string
      otherWriterOutputs: seq[string]
        ## Absolute paths the OTHER writers put inside the container.

  proc ensureDirFixture(): ContainerFixture =
    ## `fs.ensureDir("out/c")` and two compiles writing `a.o` / `b.o` into it.
    result.root = createTempDir("repro-ac-container-ensure-dir", "")
    result.work = result.root / "work"
    result.cache = result.root / "cache"
    createDir(result.work / "src")
    createDir(result.work / "out")
    writeFile(result.work / "src" / "seed.txt", "seed\n")
    result.containerId = "container/ensure-dir"
    let ensure = builtinAction(bakEnsureDir, result.containerId,
      cwd = result.work,
      outputs = ["out/c"],
      cacheable = true,
      weakFingerprint = weak(result.containerId),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    result.g = graph([ensure,
      writeIntoDirAction("container/compile-a", "out/c", "a.o",
        result.containerId, result.work),
      writeIntoDirAction("container/compile-b", "out/c", "b.o",
        result.containerId, result.work)])
    result.otherWriterOutputs = @[result.work / "out" / "c" / "a.o",
      result.work / "out" / "c" / "b.o"]

  proc preserveTreeFixture(): ContainerFixture =
    ## The shape `fs.preserveTree` lowers to -- the output ROOT, each copied
    ## entry, and the manifest, all declared -- and a copy writing `ui.js`
    ## into the root, as CodeTracer's `frontend-public-ui-js` does.
    result.root = createTempDir("repro-ac-container-preserve-tree", "")
    result.work = result.root / "work"
    result.cache = result.root / "cache"
    createDir(result.work / "src" / "tree" / "sub")
    createDir(result.work / "out")
    writeFile(result.work / "src" / "seed.txt", "seed\n")
    writeFile(result.work / "src" / "tree" / "one.txt", "one\n")
    writeFile(result.work / "src" / "tree" / "sub" / "two.txt", "two\n")
    result.containerId = "container/preserve"
    let preserve = builtinAction(bakPreserveTree, result.containerId,
      cwd = result.work,
      inputs = ["src/tree/one.txt", "src/tree/sub/two.txt"],
      outputs = ["out/pub", "out/pub/one.txt", "out/pub/sub/two.txt",
        ".repro/preserve-tree/container_preserve.manifest"],
      text = "src/tree\nout/pub",
      entries = ["file\tone.txt", "file\tsub/two.txt"],
      cacheable = true,
      weakFingerprint = weak(result.containerId),
      actionCachePolicy = ffpTimestamp,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    result.g = graph([preserve,
      writeIntoDirAction("container/copy-into", "out/pub", "ui.js",
        result.containerId, result.work)])
    result.otherWriterOutputs = @[result.work / "out" / "pub" / "ui.js"]

  proc checkWarmOnEveryArm(makeFixture: proc(): ContainerFixture) =
    ## On every arm in `WarmArm`: a cold build, then a warm build of the
    ## unchanged graph that runs nothing, reports the container's edge as a
    ## hit, and leaves the other writers' entries in place.
    ##
    ## Each arm gets a FRESH fixture and cold build. Sharing one would make
    ## every arm after the first vacuous against a broken engine: the first
    ## rejection re-runs the built-in, whose new record already describes
    ## the filled directory, so the next arm sees a matching digest.
    for arm in WarmArm:
      let f = makeFixture()
      defer: removeDir(f.root)
      let config = armConfig(f.cache, arm)
      let cold = runBuild(f.g, config)
      require cold.byId(f.containerId).status == asSucceeded
      require cold.launchedCount == f.g.actions.len
      let run = runBuild(f.g, config)
      let item = run.byId(f.containerId)
      checkpoint($arm & ": " & describe(item))
      check item.cacheDecision == cdHit
      check not item.launched
      check run.launchedCount == 0
      case arm
      of waProbeScan, waPerRecordScan:
        check run.answeredByWholeGraphPrefix()
        check item.status == asUpToDate
      of waScheduler:
        check not run.answeredByWholeGraphPrefix()
        check item.status == asUpToDate
        check item.reason == "outputs-present"
      of waRestoreMode:
        # `outputs-present`, not `restored`: nothing was materialized over
        # the container, so nothing another writer put there was touched.
        check item.status == asCacheHit
        check item.reason == "outputs-present"
      for path in f.otherWriterOutputs:
        check fileExists(path)

  test "an ensureDir that other actions write into is up to date on a warm build":
    # Before the fix the built-in re-ran on the warm build with `cdRejected`
    # because the two compiles had written `a.o` and `b.o` into the
    # directory after it was recorded.
    checkWarmOnEveryArm(ensureDirFixture)

    let f = ensureDirFixture()
    defer: removeDir(f.root)
    let config = warmConfig(f.cache)
    require runBuild(f.g, config).launchedCount == 3

    # A file nobody declared is not the built-in's either: re-creating the
    # directory would not remove it, so it must not invalidate the edge.
    writeFile(f.work / "out" / "c" / "planted.txt", "planted\n")
    let planted = runBuild(f.g, config).byId(f.containerId)
    checkpoint(describe(planted))
    check planted.cacheDecision == cdHit
    check not planted.launched

    # What the built-in DOES own is the directory's existence. Remove it and
    # the edge re-runs, with a lookup verdict that says why.
    removeDir(f.work / "out" / "c")
    let removed = runBuild(f.g, config).byId(f.containerId)
    checkpoint(describe(removed))
    check removed.launched
    check removed.status == asSucceeded
    check removed.cacheDecision != cdHit
    check removed.cacheMissReason.len > 0
    check dirExists(f.work / "out" / "c")

    # A regular file in its place is not "the directory exists" either: the
    # kind is checked too. The record is not served, so the built-in runs,
    # and it cannot create a directory over a file, so the build fails. A
    # served hit would have returned normally and left the file in place.
    removeDir(f.work / "out" / "c")
    writeFile(f.work / "out" / "c", "not a directory\n")
    expect BuildEngineError:
      discard runBuild(f.g, config)

  test "a preserveTree root that another action writes into is up to date on a warm build":
    checkWarmOnEveryArm(preserveTreeFixture)

    let f = preserveTreeFixture()
    defer: removeDir(f.root)
    let config = warmConfig(f.cache)
    require runBuild(f.g, config).launchedCount == 2
    check readFile(f.work / "out" / "pub" / "sub" / "two.txt") == "two\n"

    # An entry the built-in COPIED is still its own declared output and is
    # still revalidated: tampering with it re-runs the edge, restores the
    # entry, and the lookup verdict names the entry.
    writeFile(f.work / "out" / "pub" / "one.txt", "EVIL\n")
    let tampered = runBuild(f.g, config).byId(f.containerId)
    checkpoint(describe(tampered))
    check tampered.launched
    check tampered.cacheDecision != cdHit
    check "out/pub/one.txt" in tampered.cacheMissReason
    check readFile(f.work / "out" / "pub" / "one.txt") == "one\n"
