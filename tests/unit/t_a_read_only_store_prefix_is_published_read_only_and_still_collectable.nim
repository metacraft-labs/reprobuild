## A read-only store prefix is read-only from the moment the index names it,
## and the store user can still take it back out.
##
## Why: reprobuild-pm issue `issues/2026-11-12-chmod-r-a-w-prefixes-break-the-
## gc-mover-the-docs-also-disagree-on-modes-and-hardlinking.md`. The install-
## mirror publisher (`publishInstallMirrorToStore`) stripped every write bit
## AFTER the store had renamed the prefix into `prefixes/` and indexed it, and
## it did so through `getFilePermissions` / `setFilePermissions` on every
## `pcLinkToFile`, so a symbolic link in the mirror had its TARGET made
## read-only, wherever that was. Nothing that takes a prefix back out --
## GC's move into `gc/pending-deletion/`, the sweep's unlink, recovery's
## quarantine -- restored any bit. On Linux a directory moved to a new parent
## must itself be writable (its `..` is rewritten) and an unlink needs a
## writable parent, so a store user without CAP_DAC_OVERRIDE could never
## collect a published install mirror: every GC pass audited "quarantine
## deferred" and the prefix stayed forever, and a tree already in
## `gc/pending-deletion/` was never unlinked (the sweep swallowed EACCES).
##
## The property (Local-Content-Addressed-Store.md §"Read-Only Prefixes"):
##   * a read-only publish strips the bits in staging, never through a link;
##   * GC, the sweep and recovery restore the write bit of DIRECTORIES only,
##     never a file's (a prefix file may share its inode with the source
##     mirror's), and never through a link.
##
## Privilege. CAP_DAC_OVERRIDE ignores mode bits, so as root every collection
## case would pass whether or not the store restores anything. Run as root,
## this binary re-executes itself as `nobody` with `setpriv(1)` and reports
## that run's result; if it cannot, it FAILS rather than pass vacuously.
##
## MOCK POLICY: none. Every case runs the production publisher and a real
## `Store` on a real temporary directory.

import std/[os, osproc, strutils, tempfiles, times, unittest]

import repro_local_store
import repro_project_dsl/install_mirror_publish
import repro_local_store/store_copy

when defined(posix):
  from std/posix import geteuid, chmod, Mode

const ChildMarker = "REPRO_TEST_READ_ONLY_PREFIX_UNPRIVILEGED"
const AnyWrite = {fpUserWrite, fpGroupWrite, fpOthersWrite}

when defined(posix):
  if geteuid() == 0 and getEnv(ChildMarker) != "1":
    let setpriv = findExe("setpriv")
    if setpriv.len == 0:
      echo "FAIL: running as root, and no setpriv(1) to drop to nobody: " &
        "root ignores mode bits, so this test cannot run here"
      quit(1)
    # A scratch root nobody can use whatever $TMPDIR is (a 0700 per-user
    # temp directory would refuse it): world-writable and sticky, as /tmp.
    let base = if dirExists("/tmp"): "/tmp" else: getTempDir()
    let scratch = createTempDir("repro-ro-prefix-child-", "", base)
    discard chmod(scratch.cstring, Mode(0o1777))
    putEnv(ChildMarker, "1")
    putEnv("TMPDIR", scratch)
    let child = startProcess(setpriv,
      args = @["--reuid=65534", "--regid=65534", "--clear-groups",
               getAppFilename()],
      options = {poParentStreams})
    let code = child.waitForExit()
    child.close()
    try: removeDir(scratch) except OSError: discard
    if code == 126 or code == 127:
      echo "FAIL: nobody could not execute " & getAppFilename() &
        " (exit " & $code & "); build it where uid 65534 can reach it"
    quit(code)

when defined(posix):
  proc idOf(hex: string): PrefixIdBytes =
    doAssert hex.len == 64, "prefix id hex: " & hex
    for i in 0 ..< 32:
      result[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))

  proc writeFileMode(path, body: string; perms: set[FilePermission]) =
    createDir(parentDir(path))
    writeFile(path, body)
    setFilePermissions(path, perms)

  proc anyWritable(root: string): seq[string] =
    ## Every regular file and directory under `root` (itself included) that
    ## still carries a write bit, read without following a link.
    if (getFileInfo(root, followSymlink = false).permissions * AnyWrite).len > 0:
      result.add(root)
    for entry in walkDirRec(root, yieldFilter = {pcFile, pcDir},
                            followFilter = {pcDir}):
      let info = getFileInfo(entry, followSymlink = false)
      if (info.permissions * AnyWrite).len > 0:
        result.add(entry)

  proc forceRemove(root: string) =
    ## Fixture teardown: whatever the case left read-only.
    if not dirExists(root): return
    for entry in walkDirRec(root, yieldFilter = {pcDir},
                            followFilter = {pcDir}):
      try: setFilePermissions(entry, {fpUserRead, fpUserWrite, fpUserExec})
      except OSError: discard
    try: setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError: discard
    removeDir(root)

  type Fixture = object
    root, storeRoot, recipesRoot, mirror, outsideDir, outsideFile: string

  proc newFixture(): Fixture =
    result.root = createTempDir("repro-ro-prefix-", "")
    result.storeRoot = result.root / "store"
    result.recipesRoot = result.root / "recipes"
    result.mirror = result.root / "mirror"
    result.outsideDir = result.root / "outside-dir"
    result.outsideFile = result.root / "outside.txt"
    createDir(result.recipesRoot)
    createDir(result.outsideDir)
    writeFileMode(result.outsideFile, "not the store's\n",
      {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
    writeFileMode(result.mirror / "bin" / "tool", "#!/bin/sh\necho tool\n",
      {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
       fpOthersRead, fpOthersExec})
    writeFileMode(result.mirror / "share" / "doc" / "README", "docs\n",
      {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
    createSymlink(result.outsideFile, result.mirror / "share" / "linked.txt")
    createSymlink(result.outsideDir, result.mirror / "share" / "linked-dir")

  proc publish(f: Fixture; version = "1.0"): InstallMirrorPublishResult =
    publishInstallMirrorToStore(f.recipesRoot, "ro-demo", version, f.mirror,
      f.storeRoot)

  proc pendingEntries(f: Fixture): seq[string] =
    let pending = f.storeRoot / "gc" / "pending-deletion"
    if dirExists(pending):
      for _, entry in walkDir(pending): result.add(entry)

  suite "a read-only prefix is published read-only, never through a link":
    test "the published install mirror has no write bit on any file or directory":
      let f = newFixture()
      defer: forceRemove(f.root)
      let published = f.publish()
      check dirExists(published.absolutePath)
      check anyWritable(published.absolutePath).len == 0

    test "a link in the mirror keeps its target's mode":
      let f = newFixture()
      defer: forceRemove(f.root)
      discard f.publish()
      check fpUserWrite in getFilePermissions(f.outsideFile)
      check fpUserWrite in getFilePermissions(f.outsideDir)

  suite "the store user collects a read-only prefix":
    test "gc moves an unheld read-only prefix out and the sweep unlinks it":
      let f = newFixture()
      defer: forceRemove(f.root)
      let published = f.publish()
      var store = openStore(f.storeRoot)
      defer: store.close()
      let report = store.gc(graceSeconds = 0)
      check report.quarantined.len == 1
      check not dirExists(published.absolutePath)
      check not store.lookupPrefix(idOf(published.realizationHashHex)).found
      check f.pendingEntries().len == 0

    test "gcPrefix collects a named read-only prefix":
      let f = newFixture()
      defer: forceRemove(f.root)
      let published = f.publish()
      var store = openStore(f.storeRoot)
      defer: store.close()
      let r = store.gcPrefix(idOf(published.realizationHashHex),
        graceSeconds = 0)
      check r.reason == "collected"
      check r.reclaimed
      check not dirExists(published.absolutePath)

    test "a read-only tree an older build left in gc/pending-deletion is swept":
      let f = newFixture()
      defer: forceRemove(f.root)
      var store = openStore(f.storeRoot)
      defer: store.close()
      let left = f.storeRoot / "gc" / "pending-deletion" / "old-prefix.x"
      writeFileMode(left / "a" / "b" / "file", "x\n", {fpUserRead})
      for dir in [left / "a" / "b", left / "a", left]:
        setFilePermissions(dir, {fpUserRead, fpUserExec})
      setLastModificationTime(left, fromUnix(0))
      let swept = store.sweepPendingDeletion(graceSeconds = 0)
      check swept == @[left]
      check not dirExists(left)

    test "recovery quarantines a read-only prefix whose receipt is gone":
      let f = newFixture()
      defer: forceRemove(f.root)
      let published = f.publish()
      # Play the damage recovery exists for: the owner can always chmod.
      setFilePermissions(published.absolutePath,
        {fpUserRead, fpUserWrite, fpUserExec})
      removeFile(published.absolutePath / ".repro-receipt")
      setFilePermissions(published.absolutePath, {fpUserRead, fpUserExec})
      var store = openStore(f.storeRoot)
      defer: store.close()
      let report = store.recover()
      check report.quarantinedPrefixes.len == 1
      check not dirExists(published.absolutePath)

    test "collecting never makes a file writable, nor a link's target":
      let f = newFixture()
      defer: forceRemove(f.root)
      let published = f.publish()
      # The prefix may hardlink the mirror's files: whatever mode the publish
      # left on the mirror's inode, collection must leave exactly that.
      let toolBefore = getFilePermissions(f.mirror / "bin" / "tool")
      let docBefore = getFilePermissions(f.mirror / "share" / "doc" / "README")
      let outsideBefore = getFilePermissions(f.outsideFile)
      var store = openStore(f.storeRoot)
      defer: store.close()
      discard store.gc(graceSeconds = 0)
      check not dirExists(published.absolutePath)
      check getFilePermissions(f.mirror / "bin" / "tool") == toolBefore
      check getFilePermissions(f.mirror / "share" / "doc" / "README") ==
        docBefore
      check getFilePermissions(f.outsideFile) == outsideBefore

    test "a read-only prefix republished after collection is read-only again":
      let f = newFixture()
      defer: forceRemove(f.root)
      let first = f.publish()
      block:
        var store = openStore(f.storeRoot)
        defer: store.close()
        discard store.gc(graceSeconds = 0)
      check not dirExists(first.absolutePath)
      let again = f.publish()
      check again.absolutePath == first.absolutePath
      check anyWritable(again.absolutePath).len == 0

  suite "the store itself publishes read-only in staging":
    test "realizeDirectoryAsPrefix(readOnly) returns a tree with no write bit":
      let f = newFixture()
      defer: forceRemove(f.root)
      var store = openStore(f.storeRoot)
      defer: store.close()
      let hint = StoreReceiptHint(adapter: "test-ro", packageName: "ro-direct",
        version: "1.0", lockIdentity: "test-ro:ro-direct:1.0")
      let r = store.realizeDirectoryAsPrefix(f.mirror, hint, readOnly = true)
      check r.outcome == roPublished
      check anyWritable(r.absolutePath).len == 0
      check fpUserWrite in getFilePermissions(f.outsideFile)

    test "store copy reproduces a read-only prefix in another store":
      let f = newFixture()
      defer: forceRemove(f.root)
      let published = f.publish()
      let dst = f.root / "copy-store"
      let report = copyClosure(StoreCopyRequest(sourceRoot: f.storeRoot,
        destinationRoot: dst, prefixes: @[published.storeRelativePath]))
      check report.copied == @[published.storeRelativePath]
      check anyWritable(dst / published.storeRelativePath).len == 0
else:
  echo "POSIX-only: mode bits are what this test is about"
