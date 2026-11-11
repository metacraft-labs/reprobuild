## A store root that another writer can reach: a squatted CAS digest path is
## repaired by the next write, and a planted or edited realised prefix is
## never used as if the store had published it.
##
## Why: Production-Runners-And-Shared-Store PM3 mounts the store ROOT
## read-write into runner guests, so a job can write anything under `cas/`
## and `prefixes/` before or after a later job's writer does (SEC-1 G7/T6;
## reprobuild-pm `issues/2026-11-05-runner-guests-mount-the-whole-reprobuild-
## store-root-read-write-and-can-squat-cas-and-prefix-entries.md`). Two
## defects, one case group each:
##
##   * CAS. `storeCasBlobWithStatus` / `commitCasStage` took "the digest path
##     exists" as "the blob is there": a file pre-placed at a future digest's
##     path made the honest insert a no-op, and every later read raised
##     `ECasDigestMismatch` with nothing to repair it.
##   * Prefixes. `realizePrefix` returned `roAlreadyPresent` for an indexed id
##     whose directory existed, without looking at it, and lost the rename
##     race to (i.e. adopted) any directory at the prefix path.
##
## MOCK POLICY: none. Every case runs a real `Store` on a real temporary
## directory and plays the other writer with plain filesystem and SQL
## operations, exactly what a guest with the mount can do. "A new process"
## is `forgetVerifiedPrefixes()`: the verification memo is the only
## per-process state the store keeps, and the cases that need a second
## process say so.
##
## Each attack case is paired with the honest path it must not disturb:
## the same write or realisation on an untouched store writes nothing
## extra and reports exactly what it did before.

import std/[os, strutils, tempfiles, unittest]

from repro_core/paths import extendedPath

import repro_local_store
from repro_local_store/optimise import optimiseStore
from blake3 import nil

type Fixture = object
  root: string
  storeRoot: string
  store: Store

proc openFixture(tag: string): Fixture =
  let root = createTempDir("repro-g7-" & tag & "-", "")
  result = Fixture(root: root, storeRoot: root / "store")
  result.store = openStore(result.storeRoot)

proc closeFixture(f: var Fixture) =
  close(f.store)
  try: removeDir(extendedPath(f.root))
  except OSError: discard

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text: result[i] = byte(ord(ch))

proc textOf(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes: result[i] = char(b)

proc blake3Digest(bytes: openArray[byte]): PrefixIdBytes =
  blake3.digest(bytes)

proc squat(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

proc captureCasLog(lines: ref seq[string]) =
  casRepairLogHook = proc (message: string) = lines[].add(message)

proc capturePrefixLog(lines: ref seq[string]) =
  prefixIntegrityLogHook = proc (message: string) = lines[].add(message)

suite "CAS: an occupied digest path counts as present only when it verifies":
  setup:
    var logged = new seq[string]
    captureCasLog(logged)
  teardown:
    casRepairLogHook = nil

  test "a squatted digest path is replaced by the next write and reads back":
    var f = openFixture("cas-squat")
    defer: closeFixture(f)
    let payload = bytesOf("the blob a later job will need")
    let digest = blake3Digest(payload)
    let path = f.store.casPath(digest)
    # Same length, other bytes: the size pre-check cannot catch this one.
    squat(path, "THE BLOB A LATER JOB WILL NEED")
    expect ECasDigestMismatch:
      discard f.store.readCasBlob(digest)
    let stored = f.store.storeCasBlobWithStatus(payload)
    check stored.digest == digest
    check stored.inserted
    check stored.repaired
    check f.store.readCasBlob(digest) == payload
    check logged[].len == 1
    check hexOf(digest) in logged[0]

  test "a wrong-size squatter, a symlink and a directory are all replaced":
    var f = openFixture("cas-kinds")
    defer: closeFixture(f)
    let decoy = f.root / "decoy"
    writeFile(decoy, "decoy bytes")
    for kind in ["short", "symlink", "directory"]:
      let payload = bytesOf("payload for " & kind)
      let digest = blake3Digest(payload)
      let path = f.store.casPath(digest)
      createDir(parentDir(path))
      case kind
      of "short": writeFile(path, "x")
      of "symlink": createSymlink(decoy, path)
      else:
        createDir(path)
        writeFile(path / "inside", "x")
      let stored = f.store.storeCasBlobWithStatus(payload)
      check stored.repaired
      check getFileInfo(path, followSymlink = false).kind == pcFile
      check f.store.readCasBlob(digest) == payload
    # The decoy the symlink pointed at was not written through.
    check readFile(decoy) == "decoy bytes"

  test "file ingest repairs a squatted digest and never reports alreadyPresent":
    var f = openFixture("cas-ingest")
    defer: closeFixture(f)
    let source = f.root / "output.bin"
    writeFile(source, "a build output the store is asked to keep")
    let digest = blake3Digest(bytesOf(readFile(source)))
    squat(f.store.casPath(digest), "planted by another job, same digest path")
    let outcome = f.store.storeCasFileBlobDetailed(source,
      uint64(getFileSize(source)))
    check outcome.digest == digest
    check outcome.repaired
    check not outcome.alreadyPresent
    check "did not verify" in outcome.diagnostic
    check textOf(f.store.readCasBlob(digest)) == readFile(source)

  test "honest dedupe: storing the same bytes again writes nothing":
    var f = openFixture("cas-honest")
    defer: closeFixture(f)
    let payload = bytesOf("stored twice")
    let first = f.store.storeCasBlobWithStatus(payload)
    check first.inserted and not first.repaired
    let path = f.store.casPath(first.digest)
    let before = getFileInfo(path, followSymlink = false)
    let second = f.store.storeCasBlobWithStatus(payload)
    check second.digest == first.digest
    check not second.inserted
    check not second.repaired
    let after = getFileInfo(path, followSymlink = false)
    check after.id == before.id                       # same inode: no rename
    check after.lastWriteTime == before.lastWriteTime
    let source = f.root / "same.bin"
    writeFile(source, textOf(payload))
    let ingest = f.store.storeCasFileBlobDetailed(source,
      uint64(getFileSize(source)))
    check ingest.alreadyPresent
    check not ingest.repaired
    check getFileInfo(path, followSymlink = false).id == before.id
    check logged[].len == 0

suite "Prefixes: only an indexed, verified directory is a realised prefix":
  setup:
    var logged = new seq[string]
    capturePrefixLog(logged)
    forgetVerifiedPrefixes()
  teardown:
    prefixIntegrityLogHook = nil

  var sources = 0
  proc honestSource(f: Fixture; name: string): string =
    ## A FRESH source tree per call. The store may hardlink a prefix's files
    ## from its source, so reusing one source tree would let an edit made
    ## through the prefix (or a rewrite of the source) reach the other.
    inc sources
    result = f.root / ("src-" & name & "-" & $sources)
    createDir(result / "bin")
    writeFile(result / "bin" / "tool", "#!/bin/sh\necho honest " & name & "\n")
    createDir(result / "share")
    writeFile(result / "share" / "data", "honest data")

  proc hintFor(name: string): StoreReceiptHint =
    StoreReceiptHint(adapter: "path", packageName: name, version: "1.0",
      declaredExecutablePath: "bin/tool", lockIdentity: "g7-test")

  proc idFor(h: StoreReceiptHint): PrefixIdBytes =
    computeRealizationHash(h.packageName, h.version, h.adapter,
      h.lockIdentity, h.declaredExecutablePath, h.provenanceUrl,
      h.provenanceChecksum)

  proc pendingDeletion(f: Fixture): seq[string] =
    for kind, p in walkDir(f.storeRoot / "gc" / "pending-deletion"):
      result.add(p)

  proc recordedDigest(f: Fixture; id: PrefixIdBytes): string =
    var q = f.store.db.prepare(
      "SELECT content_digest FROM prefixes WHERE prefix_id = ?")
    defer: q.finalize()
    q.bindBlob(1, id)
    if q.step() == SqliteRow and not q.columnIsNull(0):
      result = hexOf(q.columnBlob(0))

  test "a planted directory with a forged receipt is displaced, not adopted":
    var f = openFixture("plant")
    defer: closeFixture(f)
    let hint = hintFor("victim")
    let id = idFor(hint)
    let rel = prefixRelativePath(hint.packageName, hint.version, id, "")
    let planted = f.store.absolutePrefixPath(rel)
    # What a guest can do: compute the id, pre-place the directory, and seal
    # a receipt that names it. No index row.
    createDir(planted / "bin")
    writeFile(planted / "bin" / "tool", "#!/bin/sh\necho PLANTED\n")
    writeReceiptFile(planted / ReceiptFileName, RealizationReceipt(
      schemaVersion: 1'u16, adapter: hint.adapter,
      packageName: hint.packageName, version: hint.version,
      realizationHash: id, realizedPath: rel,
      declaredExecutablePath: hint.declaredExecutablePath,
      lockIdentity: hint.lockIdentity, materializationMechanism: "copy",
      writerMode: "direct"))
    check not f.store.lookupPrefix(id).found
    let res = f.store.realizeDirectoryAsPrefix(f.honestSource("victim"), hint)
    check res.prefixId == id
    check res.absolutePath == planted
    check res.outcome == roPublished
    check res.replacedUntrusted
    check "no row in the store index" in res.integrityDiagnostic
    check readFile(planted / "bin" / "tool") == "#!/bin/sh\necho honest victim\n"
    check f.store.lookupPrefix(id).found
    check f.recordedDigest(id) == hexOf(prefixTreeDigest(planted))
    # The planted tree is kept as evidence for the GC grace, not deleted.
    let moved = f.pendingDeletion()
    check moved.len == 1
    check readFile(moved[0] / "bin" / "tool") == "#!/bin/sh\necho PLANTED\n"
    check logged[].len == 1
    # And a later process accepts the published one without re-realising.
    forgetVerifiedPrefixes()
    let again = f.store.realizeDirectoryAsPrefix(f.honestSource("victim"), hint)
    check again.outcome == roAlreadyPresent
    check again.verification == pvVerified

  test "a file edited inside an indexed prefix is caught by the next process":
    var f = openFixture("tamper")
    defer: closeFixture(f)
    let hint = hintFor("edited")
    let first = f.store.realizeDirectoryAsPrefix(f.honestSource("edited"), hint)
    check first.outcome == roPublished
    let tool = first.absolutePath / "bin" / "tool"
    # A root holds it: the repair must not cost the root its hold.
    f.store.registerRoot("job-1", rkSession)
    f.store.attachPrefixToRoot("job-1", first.prefixId)
    setFilePermissions(tool, {fpUserRead, fpUserWrite, fpUserExec})
    writeFile(tool, "#!/bin/sh\necho EDITED\n")
    # The SAME process does not re-hash a prefix it already verified (the
    # documented first-use policy) ...
    let sameProcess = f.store.realizeDirectoryAsPrefix(
      f.honestSource("edited"), hint)
    check sameProcess.outcome == roAlreadyPresent
    check sameProcess.verification == pvCached
    # ... the next one does, treats the prefix as absent and realises it
    # again in place.
    forgetVerifiedPrefixes()
    let next = f.store.realizeDirectoryAsPrefix(f.honestSource("edited"), hint)
    check next.outcome == roPublished
    check next.replacedUntrusted
    check "does not match the store index's record" in next.integrityDiagnostic
    check readFile(tool) == "#!/bin/sh\necho honest edited\n"
    check f.recordedDigest(first.prefixId) ==
      hexOf(prefixTreeDigest(first.absolutePath))
    var holds = f.store.db.prepare(
      "SELECT COUNT(*) FROM root_holds_prefix WHERE root_id = ? " &
      "AND prefix_id = ?")
    holds.bindText(1, "job-1")
    holds.bindBlob(2, first.prefixId)
    check holds.step() == SqliteRow
    check holds.columnInt(0) == 1
    holds.finalize()
    check f.pendingDeletion().len == 1

  test "an added file, a swapped symlink or a forged receipt is a mismatch":
    var f = openFixture("tamper-kinds")
    defer: closeFixture(f)
    for kind in ["added", "symlink", "receipt"]:
      forgetVerifiedPrefixes()
      let hint = hintFor("kinds-" & kind)
      let res = f.store.realizeDirectoryAsPrefix(
        f.honestSource("kinds-" & kind), hint)
      let dir = res.absolutePath
      case kind
      of "added":
        writeFile(dir / "bin" / "ld.so.preload", "/tmp/evil.so")
      of "symlink":
        removeFile(dir / "share" / "data")
        createSymlink("/etc/passwd", dir / "share" / "data")
      else:
        var rec = readReceiptFile(dir / ReceiptFileName)
        rec.exportedExecutables = @["../../../../usr/bin/evil"]
        writeReceiptFile(dir / ReceiptFileName, rec)
      forgetVerifiedPrefixes()
      let check1 = f.store.verifyRealizedPrefix(res.prefixId, dir)
      check check1.outcome == pvMismatch
      let again = f.store.realizeDirectoryAsPrefix(
        f.honestSource("kinds-" & kind), hint)
      check again.replacedUntrusted
      check f.store.verifyRealizedPrefix(res.prefixId, dir,
        useMemo = false).outcome == pvVerified

  test "a prefix path redirected by a symlink is replaced by a real directory":
    ## The redirect points at an exact copy of the published tree, so its
    ## content digest matches: only the shape (the store never renames a
    ## symlink into place) gives it away. The guest owns the target and can
    ## change it after any check, so it is never used.
    var f = openFixture("redirect")
    defer: closeFixture(f)
    let hint = hintFor("redirected")
    let first = f.store.realizeDirectoryAsPrefix(
      f.honestSource("redirected"), hint)
    let dir = first.absolutePath
    let elsewhere = f.root / "guest-owned"
    copyDirWithPermissions(dir, elsewhere)
    check prefixTreeDigest(elsewhere) == prefixTreeDigest(dir)
    removeDir(dir)
    createSymlink(elsewhere, dir)
    forgetVerifiedPrefixes()
    check f.store.verifyRealizedPrefix(first.prefixId, dir).outcome ==
      pvMismatch
    let again = f.store.realizeDirectoryAsPrefix(
      f.honestSource("redirected"), hint)
    check again.replacedUntrusted
    check getFileInfo(dir, followSymlink = false).kind == pcDir
    check dirExists(elsewhere)       # the guest's tree is not touched
    # A dangling redirect and a plain file at an UNINDEXED prefix path are
    # displaced on the publish path, not reported as an I/O failure.
    for occupant in ["dangling", "file"]:
      let h = hintFor("occupied-" & occupant)
      let rel = prefixRelativePath(h.packageName, h.version, idFor(h), "")
      let path = f.store.absolutePrefixPath(rel)
      createDir(parentDir(path))
      if occupant == "dangling": createSymlink(f.root / "nowhere", path)
      else: writeFile(path, "not a prefix")
      let res = f.store.realizeDirectoryAsPrefix(
        f.honestSource("occupied-" & occupant), h)
      check res.outcome == roPublished
      check res.replacedUntrusted
      check getFileInfo(path, followSymlink = false).kind == pcDir

  test "honest hit: verified once, then cached, and the prefix is untouched":
    var f = openFixture("honest")
    defer: closeFixture(f)
    let hint = hintFor("honest")
    let first = f.store.realizeDirectoryAsPrefix(f.honestSource("honest"), hint)
    check first.outcome == roPublished
    check not first.replacedUntrusted
    let tool = first.absolutePath / "bin" / "tool"
    let before = getFileInfo(tool)
    let rowBefore = f.store.lookupPrefix(first.prefixId).row
    forgetVerifiedPrefixes()
    let second = f.store.realizeDirectoryAsPrefix(f.honestSource("honest"), hint)
    check second.outcome == roAlreadyPresent
    check second.verification == pvVerified
    let third = f.store.realizeDirectoryAsPrefix(f.honestSource("honest"), hint)
    check third.outcome == roAlreadyPresent
    check third.verification == pvCached
    let after = getFileInfo(tool)
    check after.id == before.id
    check after.lastWriteTime == before.lastWriteTime
    let rowAfter = f.store.lookupPrefix(first.prefixId).row
    check rowAfter.receiptDigest == rowBefore.receiptDigest
    check rowAfter.createdAtUnix == rowBefore.createdAtUnix
    check f.pendingDeletion().len == 0
    check logged[].len == 0

  test "store optimise keeps every prefix verifying, and stages outside them":
    ## `repro store optimise` collapses byte-identical files across prefixes
    ## onto one inode, whatever their modes. That must not read as tampering:
    ## the tree digest leaves modes out, and the temp link optimise renames
    ## over a duplicate is made in the store's `tmp/`, never inside a
    ## published prefix where a concurrent verifier (or one after an
    ## interrupted run) would count it as an added file.
    var f = openFixture("optimise")
    defer: closeFixture(f)
    var results: seq[RealizeResult] = @[]
    for name in ["opt-a", "opt-b"]:
      results.add(f.store.realizeDirectoryAsPrefix(f.honestSource(name),
        hintFor(name)))
    let a = results[0].absolutePath / "share" / "data"
    let b = results[1].absolutePath / "share" / "data"
    setFilePermissions(b, {fpUserRead})
    check getFileInfo(a).id != getFileInfo(b).id
    let res = optimiseStore(f.storeRoot / "prefixes")
    check res.linked >= 1
    check getFileInfo(a).id == getFileInfo(b).id
    for r in results:
      for p in walkDirRec(r.absolutePath):
        check not p.endsWith(".repro-optimise-tmp")
    forgetVerifiedPrefixes()
    for r in results:
      check f.store.verifyRealizedPrefix(r.prefixId, r.absolutePath,
        useMemo = false).outcome == pvVerified
    check f.pendingDeletion().len == 0
    check logged[].len == 0

  test "a row an older build wrote (no digest) is recorded on first use":
    var f = openFixture("legacy")
    defer: closeFixture(f)
    let hint = hintFor("legacy")
    let first = f.store.realizeDirectoryAsPrefix(f.honestSource("legacy"), hint)
    f.store.db.exec("UPDATE prefixes SET content_digest = NULL")
    check f.recordedDigest(first.prefixId) == ""
    forgetVerifiedPrefixes()
    let res = f.store.realizeDirectoryAsPrefix(f.honestSource("legacy"), hint)
    check res.outcome == roAlreadyPresent
    check res.verification == pvRecordedFirst
    check f.recordedDigest(first.prefixId) ==
      hexOf(prefixTreeDigest(first.absolutePath))
    forgetVerifiedPrefixes()
    check f.store.verifyRealizedPrefix(first.prefixId,
      first.absolutePath).outcome == pvVerified

  test "a multi-output prefix edited after publication is realised again":
    var f = openFixture("multi")
    defer: closeFixture(f)
    let binStage = f.root / "out-bin"
    createDir(binStage / "bin")
    writeFile(binStage / "bin" / "tool", "multi honest")
    let hint = StoreReceiptHint(adapter: "path", packageName: "multi",
      version: "1.0", lockIdentity: "g7-multi")
    let outputs = @[MultiOutputSpec(outputName: "bin", stagingDir: binStage)]
    let first = f.store.realizeMultiOutput(hint, outputs)
    check first.perOutput[0].outcome == roPublished
    let dir = first.perOutput[0].absolutePath
    # Replaced, not written in place: the prefix may share the stage's inode,
    # and editing the stage would change the (content-derived) output id.
    removeFile(dir / "bin" / "tool")
    writeFile(dir / "bin" / "tool", "multi EDITED")
    forgetVerifiedPrefixes()
    let again = f.store.realizeMultiOutput(hint, outputs)
    check again.perOutput[0].outcome == roPublished
    check readFile(dir / "bin" / "tool") == "multi honest"
    forgetVerifiedPrefixes()
    let honest = f.store.realizeMultiOutput(hint, outputs)
    check honest.perOutput[0].outcome == roAlreadyPresent
