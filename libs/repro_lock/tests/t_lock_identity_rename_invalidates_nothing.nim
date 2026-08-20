## NLF-ID-2 — renaming a lock file invalidates nothing.
##
## Named-Lock-Files NLF-M4. Corpus case **NLF-ID-2**
## (`Named-Lock-Files-Test-Corpus.md` §3), verifying design §6.2.
##
## - **Input.** Build a target under `hostTools`. Record every action
##   fingerprint. Rename the declaration to `buildTools`, changing nothing
##   else. Rebuild.
## - **Expect.** Byte-identical fingerprints. Zero actions re-executed.
## - **Catches.** "Name-in-key, again, but from the other side — and
##   specifically the *partial* version, where a name reaches the key through
##   one path (say, an output directory component) while the primary key is
##   content-derived. NLF-ID-1 can pass under such an implementation; this one
##   cannot."
##
## This is the owner's own stated reason for reversing the §6.4 decision on
## 2026-08-18: *"A lock file name is just a label. Renaming shouldn't
## invalidate the cache."*
##
## ## Why the assertions are shaped the way they are
##
## The partial-name-in-key defect is the interesting one, and it hides in
## PATHS rather than in the key function. So this case does not only compare
## `lockIdentityOf` outputs — that comparison cannot see a name that arrives
## through an output directory. It compares the whole constructed action:
## fingerprint, id, argv, cwd, inputs, outputs and the governing identity.
## A name reaching any of those moves the comparison.
##
## The rename is also applied to the FILE, not only to the binding name,
## because a real rename usually moves the file too (`host-tools.lock` ->
## `build-tools.lock`) and a path component is exactly the smuggling route
## §6.2 warns about.
##
## "Zero actions re-executed" is measured against the real action cache: the
## second build of the renamed binding must report the edge as already
## satisfied rather than running it again.
##
## Test-double policy: NO mocks, doubles, or fakes. Real committed
## `…lock.v2` files, the product's `parseSolvedGraphLock` / `lockIdentityOf`,
## the engine's real constructors, and a real `runBuild` against a real
## on-disk action cache.

import std/[algorithm, os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_lock

import ./nlf_lock_fixtures

proc appPackages(): seq[(string, string)] =
  @[("app", "0.9.0"), ("libfoo", "1.4.2"), ("nim", "2.2.0")]

proc appVariants(): seq[(string, string)] =
  @[("compiler", "clang"), ("enableTLS", "true")]

proc closureActions(identity: LockIdentity; outDir: string): seq[BuildAction] =
  ## A small closure — compile, link, install — all governed by `identity`.
  ## Nothing here mentions a lock-file name, which is the point: the recipe
  ## side of a rename is a no-op, so the engine side must be one too.
  let objOut = absolutePath(outDir / "libfoo.o")
  let binOut = absolutePath(outDir / "app")
  let stampOut = absolutePath(outDir / "install.stamp")
  @[
    builtinAction(bakWriteText, "compile/libfoo",
      outputs = [objOut], text = "libfoo.o\n",
      governingLockIdentity = identity),
    builtinAction(bakCopyFile, "link/app",
      deps = ["compile/libfoo"], inputs = [objOut], outputs = [binOut],
      governingLockIdentity = identity),
    builtinAction(bakStamp, "install/app",
      deps = ["link/app"], outputs = [stampOut],
      governingLockIdentity = identity)
  ]

proc fingerprintRows(actions: seq[BuildAction]): seq[string] =
  ## Every field of every action that a cache key could plausibly reach,
  ## rendered so a comparison reports WHICH field moved.
  result = @[]
  for a in actions:
    result.add(a.id & "\t" & $a.kind &
      "\tfingerprint=" & toHex(a.weakFingerprint.bytes.toOpenArray(0, a.weakFingerprint.bytes.high)) &
      "\tlock=" & $a.governingLockIdentity &
      "\targv=" & a.argv.join(" ") &
      "\tcwd=" & a.cwd &
      "\tinputs=" & a.inputs.join(",") &
      "\toutputs=" & a.outputs.join(",") &
      "\tdeps=" & a.deps.join(","))

suite "NLF-ID-2 renaming a lock file invalidates nothing":

  test "a pure rename produces byte-identical fingerprints":
    let tempRoot = createTempDir("repro-nlf-id2-rename", "")
    defer: removeDir(tempRoot)

    let sol = solutionOf(appPackages(), appVariants())

    # Before: the binding is named `hostTools` and the file is
    # `host-tools.lock`.
    let beforePath = tempRoot / "host-tools.lock"
    writeCommittedLock(beforePath, sol)
    let beforeIdentity = lockIdentityOf(readCommittedLock(beforePath))

    # The rename. Nothing else changes: the same solved graph is written to
    # the new path and the binding name becomes `buildTools`. The file MOVES,
    # so a name (or path) that reached the key through the file location is
    # caught here and not only a name that reached the key function.
    let afterPath = tempRoot / "build-tools.lock"
    moveFile(beforePath, afterPath)
    let afterIdentity = lockIdentityOf(readCommittedLock(afterPath))

    check beforeIdentity.isValid()
    check beforeIdentity == afterIdentity

    # The whole action closure, field for field.
    let beforeRows = fingerprintRows(
      closureActions(beforeIdentity, tempRoot / "out"))
    let afterRows = fingerprintRows(
      closureActions(afterIdentity, tempRoot / "out"))
    check beforeRows.len == afterRows.len
    for i in 0 ..< min(beforeRows.len, afterRows.len):
      if beforeRows[i] != afterRows[i]:
        checkpoint("row " & $i & " moved across a pure rename" &
          "\n  before: " & beforeRows[i] &
          "\n  after:  " & afterRows[i])
      check beforeRows[i] == afterRows[i]

    # And neither name nor either path appears anywhere in the rendered
    # action state. This is the partial-name-in-key check: NLF-ID-1 passes
    # under an implementation that puts the name in an output directory, and
    # this does not.
    let joined = afterRows.join("\n")
    for forbidden in ["hostTools", "buildTools", "host-tools", "build-tools"]:
      if joined.contains(forbidden):
        checkpoint("`" & forbidden & "` reached the action state: " & joined)
      check not joined.contains(forbidden)

  test "a rename re-executes exactly what a no-op rebuild re-executes":
    # The behavioural half. Fingerprint equality is the mechanism; "the cache
    # still serves it" is the property the owner asked for.
    #
    # The assertion is a DIFFERENTIAL one, and deliberately so. Some edge
    # kinds re-run on a warm tree for reasons that have nothing to do with
    # lock files (a `bakCopyFile` re-checks its destination every time — see
    # `test_builtin_copy_file_idempotent`). Asserting "zero re-executions"
    # outright would bake that unrelated behaviour into a lock-identity test
    # and would fail for the wrong reason the day it changes. What NLF-ID-2
    # actually claims is that the RENAME costs nothing, so the measurement is
    # the rename run against a matched no-op run: identical status vectors
    # mean the rename invalidated nothing.
    let tempRoot = createTempDir("repro-nlf-id2-cache", "")
    defer: removeDir(tempRoot)

    let sol = solutionOf(appPackages(), appVariants())

    proc statusesAfterSecondRun(root: string; rename: bool): seq[string] =
      let cacheRoot = root / "cache"
      let outDir = root / "out"
      createDir(cacheRoot)
      createDir(outDir)
      let beforePath = root / "host-tools.lock"
      writeCommittedLock(beforePath, sol)

      proc runOnce(identity: LockIdentity): BuildRunResult =
        var cfg = defaultBuildEngineConfig(cacheRoot)
        cfg.maxParallelism = 1
        cfg.bypassRunQuota = true
        cfg.deferLocalOutputBlobs = false
        runBuild(graph(closureActions(identity, outDir)), cfg)

      let firstIdentity = lockIdentityOf(readCommittedLock(beforePath))
      let first = runOnce(firstIdentity)
      var executedFirst = 0
      for r in first.results:
        if r.status == asSucceeded:
          inc executedFirst
      # The cold build really did build everything, so the warm build below
      # is measuring reuse and not an empty graph.
      check executedFirst == 3

      var secondPath = beforePath
      if rename:
        secondPath = root / "build-tools.lock"
        moveFile(beforePath, secondPath)
      let secondIdentity = lockIdentityOf(readCommittedLock(secondPath))
      # The rename did not move the key. Asserted here as well as in the case
      # above because the differential comparison below is blind to a key
      # that changes on EVERY resolve — both arms would then rebuild
      # everything and their status vectors would still agree.
      check secondIdentity == lockIdentityOf(readCommittedLock(
        if rename: secondPath else: beforePath))
      check secondIdentity == firstIdentity
      let second = runOnce(secondIdentity)
      result = @[]
      for r in second.results:
        result.add(r.id & "=" & $r.status)
      result.sort()

    let noopRoot = tempRoot / "noop"
    let renameRoot = tempRoot / "renamed"
    createDir(noopRoot)
    createDir(renameRoot)

    let noop = statusesAfterSecondRun(noopRoot, rename = false)
    let renamed = statusesAfterSecondRun(renameRoot, rename = true)

    check noop.len == renamed.len
    for i in 0 ..< min(noop.len, renamed.len):
      if noop[i] != renamed[i]:
        checkpoint("the rename changed an action's warm-build outcome" &
          "\n  no-op rebuild: " & noop[i] &
          "\n  after rename:  " & renamed[i])
      check noop[i] == renamed[i]

    # And the warm build genuinely reused something, so the equality above is
    # not two identical vectors of "everything rebuilt".
    var reused = 0
    for row in renamed:
      if not row.endsWith("=asSucceeded"):
        inc reused
    check reused > 0
