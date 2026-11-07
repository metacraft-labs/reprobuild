## What a path mutation in a monitor capture means to the action cache.
##
## io-mon records a namespace change that has no open behind it -- a
## directory created or removed, an entry unlinked, a symbolic link created --
## as an `mrPathMutation` record, naming the call first in its detail. The
## engine used to drop every such record, so:
##   * a symbolic link an action laid down was no product: the S7 gate
##     (`undeclaredSurvivingWrites`) could not see it, and a restored hit
##     lacked it;
##   * a source file the action deleted, or a directory it created under a
##     read-only root, escaped the R6 check (`sourceWriteOffenders`).
##
## Folding them as plain writes would have been wrong the other way: a path
## written and gone at the end is the action's own temporary
## (`transientOwnWrites`) and leaves the portable key, and a REMOVED path is no
## evidence of having made the file. A file the action read and then deleted
## is an input it consumed; dropping it from the key is a false hit. So a
## removal lands in `monitorRemovals`, a creation in `monitorWrites`, and this
## file grades each consumer against real files on disk.
##
## Mocks: none. The records are the shapes io-mon's Linux and macOS shims
## emit (`linux_preload.nim` `repro_linux_observe_mutation`,
## `macos_interpose.nim` ROUND-4 RW2), folded by the engine's own
## `foldMonitorRecordsEvidence`; the consumers read the real filesystem.

import std/[os, sequtils, sets, tempfiles, unittest]

import repro_build_engine
import repro_core
import io_mon/types

proc mutation(path, detail: string): MonitorRecord =
  MonitorRecord(kind: mrPathMutation, observationKind: moPathMutation,
    osPid: 10, threadId: 10, path: path, detail: detail & " run=1-10-1")

proc fold(records: openArray[MonitorRecord]; cwd: string): PathSetEvidence =
  var seen: EvidenceSeenSets
  discard foldMonitorRecordsEvidence(records, cwd, result, seen)

suite "path mutations in monitor evidence":

  test "removals and creations land in separate channels":
    let evidence = fold([
      mutation("/w/unlinked", "unlink"),
      mutation("/w/unlinkedat", "unlinkat dirfd=4 flags=0"),
      mutation("/w/rmdir-at", "rmdir unlinkat dirfd=4 flags=512"),
      mutation("/w/rmdir-at-macos", "unlinkat dirfd=4 flags=128"),
      mutation("/w/removed-dir", "rmdir"),
      mutation("/w/removed", "remove"),
      mutation("/w/made-dir", "mkdir"),
      mutation("/w/made-dir-at", "mkdirat dirfd=4"),
      mutation("/w/link", "symlink target=x"),
      mutation("/w/link-at", "symlinkat dirfd=4 target=y")], "/w")
    check evidence.monitorRemovals.paths.toHashSet == toHashSet([
      "/w/unlinked", "/w/unlinkedat", "/w/rmdir-at", "/w/rmdir-at-macos",
      "/w/removed-dir", "/w/removed"])
    check evidence.monitorWrites.paths.toHashSet == toHashSet([
      "/w/made-dir", "/w/made-dir-at", "/w/link", "/w/link-at"])

  test "every path mutation under a read-only root is a source write":
    let evidence = fold([
      mutation("/repro/src/pkg/configure.in", "unlink"),
      mutation("/repro/src/pkg/old", "rmdir"),
      mutation("/repro/src/pkg/newdir", "mkdir"),
      mutation("/repro/src/pkg/alias", "symlink target=x"),
      mutation("/repro/build/scratch", "unlink")], "/repro")
    var act = action("configure", @["sh"], cwd = "/repro",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    act.readOnlyRoots = @["/repro/src/pkg"]
    let offenders = act.sourceWriteOffenders(evidence)
    check offenders.mapIt(it.write).toHashSet == toHashSet([
      "/repro/src/pkg/configure.in", "/repro/src/pkg/old",
      "/repro/src/pkg/newdir", "/repro/src/pkg/alias"])
    check offenders.allIt(it.root == "/repro/src/pkg")

  test "a removed file is not the action's own temporary; a made one is":
    ## Both paths are gone at the end. The directory the action made and
    ## removed is its own doing; the file it only removed is not, so a read
    ## of it stays in the key.
    let tempRoot = createTempDir("repro-path-mutation-transient", "")
    defer: removeDir(tempRoot)
    let madeAndRemoved = tempRoot / "tmpdir"
    let removedOnly = tempRoot / "input.txt"
    let evidence = fold([
      mutation(madeAndRemoved, "mkdir"),
      mutation(madeAndRemoved, "rmdir"),
      mutation(removedOnly, "unlink")], tempRoot)
    let transient = transientOwnWrites(evidence)
    check madeAndRemoved in transient
    check removedOnly notin transient

  test "a surviving symbolic link the action made is a product":
    ## Whatever it points at: a directory (which `dirExists` follows) or
    ## nothing (which `fileExists` follows to nothing). A file link is the
    ## positive control: it was already visible as a file.
    let tempRoot = createTempDir("repro-path-mutation-symlink", "")
    defer: removeDir(tempRoot)
    createDir(tempRoot / "out")
    createDir(tempRoot / "out" / "real-dir")
    writeFile(tempRoot / "out" / "real-file", "x\n")
    createSymlink("real-dir", tempRoot / "out" / "dir-link")
    createSymlink("missing", tempRoot / "out" / "dangling-link")
    createSymlink("real-file", tempRoot / "out" / "file-link")
    let evidence = fold([
      mutation(tempRoot / "out" / "real-dir", "mkdir"),
      mutation(tempRoot / "out" / "dir-link", "symlink target=real-dir"),
      mutation(tempRoot / "out" / "dangling-link", "symlink target=missing"),
      mutation(tempRoot / "out" / "file-link", "symlink target=real-file")],
      tempRoot)
    var act = action("ln", @["ln"], cwd = tempRoot,
      outputs = @["out/real-file"], cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let reported = act.undeclaredSurvivingWrites(evidence).toHashSet
    check reported == toHashSet([
      tempRoot / "out" / "dir-link", tempRoot / "out" / "dangling-link",
      tempRoot / "out" / "file-link"])
