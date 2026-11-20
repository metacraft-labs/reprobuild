## A published prefix survives a power loss, or recovery notices it did not.
##
## Why: the write protocol (stage -> receipt -> rename -> index commit) was
## atomic against a crashed PROCESS and nothing more. The SQLite commit is
## durable, but the staged file data and the directory rename were never
## synced, and ext4's ``auto_da_alloc`` does not cover new files while XFS and
## APFS give no rename-versus-data ordering at all. After a power cut the
## index could therefore name a prefix whose files are empty, and recovery
## (``repro store recover``, the daemon's startup scan, the index rebuild)
## never looked at prefix contents: an unindexed prefix was re-inserted on the
## strength of its receipt, and the first use then recorded the damaged tree
## as the truth (trust on first use). reprobuild-pm
## ``issues/2026-11-12-crash-recovery-is-trivial-in-a-store-that-never-fsyncs-
## and-never-verifies-prefix-contents.md``; the governing text is
## Local-Content-Addressed-Store §"Write Protocol" and §"Corruption
## Detection", held to Caching-Architecture's "robustness across process
## crashes and power loss".
##
## Two case groups:
##
##   * Durability order (Linux). A power cut cannot be produced in a test, so
##     the test checks what makes one survivable: the order of the syscalls a
##     real publish makes. The test binary re-runs itself as a child that
##     publishes through the production code (``realizePrefix`` and
##     ``copyClosure``), under ``strace``. Every regular file and directory of
##     the published tree must be fsynced under its STAGED name before the
##     rename that publishes it; the directory that receives the rename must
##     be fsynced after it, and ``prefixes/`` when the package directory is
##     new; and all of it must happen before the index transaction writes its
##     commit to ``index.db-wal``. Recovery's re-insert of an unindexed tree
##     (what a bundle import's unpack leaves) must flush that tree before its
##     row commits, and a FIFO in a prefix must hang neither the flush nor
##     recovery.
##   * Recovery checks contents (every platform). The state a power cut
##     leaves is produced directly: a file of a published prefix whose name
##     survived but whose data did not (truncated to zero bytes), with the
##     index row intact, with the row lost, with the row carrying no digest,
##     and with the whole index rebuilt from receipts. Recovery must move each
##     damaged tree to ``gc/pending-deletion/`` and must not index it; the
##     next realisation must publish a fresh, correct tree. Each attack has
##     an honest twin that recovery must leave alone.
##
## MOCK POLICY: none. Real stores on real temporary directories, the real
## ``strace`` from the development shell, and the production publish and
## recovery entry points. Damage is applied with plain filesystem and SQL
## operations, which is exactly the state the disk is in after the power cut.

from repro_core/process_streams import drainStream
import std/[os, osproc, streams, strtabs, strutils, tempfiles, times,
            unittest]
when defined(posix):
  from std/posix import mkfifo

from repro_core/ambient_execution import uncontrolledStartProcess

import repro_local_store/store
import repro_local_store/store_copy
import repro_local_store/sqlite3_binding

const ChildEnv = "REPRO_T_DURABLE_PUBLISH_CHILD"
  ## Set to ``realize:<store root>`` or ``copy:<src root>|<dst root>`` for
  ## the traced child run.

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text: result[i] = byte(ord(ch))

proc hintFor(name: string): StoreReceiptHint =
  StoreReceiptHint(adapter: "path", packageName: name, version: "1.0",
    lockIdentity: "durable-" & name)

proc layOut(dir, name: string) =
  ## A tree with every kind of entry a prefix holds: nested directories,
  ## an empty directory, an executable, a plain file and a symlink.
  createDir(dir / "bin")
  createDir(dir / "lib" / "deep")
  createDir(dir / "share" / "empty")
  writeFile(dir / "bin" / name, "#!/bin/sh\necho " & name & "\n")
  setFilePermissions(dir / "bin" / name,
    {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec})
  writeFile(dir / "lib" / "deep" / "data.txt",
    repeat(name & " payload line\n", 64))
  when defined(posix):
    createSymlink(name, dir / "bin" / "alias")

proc realizeTree(s: var Store; name: string): RealizeResult =
  let prefixId = computeRealizationHash(name, "1.0", "path",
    "durable-" & name, "")
  s.realizePrefix(prefixId, hintFor(name),
    proc (stage: string; mechanism: var string) =
      layOut(stage, name))

# ---------------------------------------------------------------------------
# Child mode: publish once and exit, so the parent can trace exactly that.
# ---------------------------------------------------------------------------

let childSpec = getEnv(ChildEnv)
if childSpec.len > 0:
  if childSpec.startsWith("realize:"):
    var s = openStore(childSpec["realize:".len .. ^1])
    discard s.realizeTree("traced")
    s.close()
  elif childSpec.startsWith("copy:"):
    let parts = childSpec["copy:".len .. ^1].split('|')
    discard copyClosure(StoreCopyRequest(sourceRoot: parts[0],
      destinationRoot: parts[1], prefixes: @[parts[2]]))
  elif childSpec.startsWith("recover:"):
    discard recoverStoreRoot(childSpec["recover:".len .. ^1])
  elif childSpec.startsWith("fifo:"):
    when defined(posix):
      var s = openStore(childSpec["fifo:".len .. ^1])
      let prefixId = computeRealizationHash("piped", "1.0", "path",
        "durable-piped", "")
      discard s.realizePrefix(prefixId, hintFor("piped"),
        proc (stage: string; mechanism: var string) =
          layOut(stage, "piped")
          if mkfifo(cstring(stage / "lib" / "pipe"), 0o644) != 0:
            raiseOSError(osLastError(), "mkfifo"))
      # Recovery then hashes the tree against its receipt
      # (``storeTreeDigest``), which must not block on the FIFO either.
      s.db.exec("UPDATE prefixes SET content_digest = NULL WHERE " &
        "prefix_id = x'" & hexOf(prefixId) & "'")
      s.close()
      let report = recoverStoreRoot(childSpec["fifo:".len .. ^1])
      if report.quarantinedPrefixes.len != 0:
        quit("recovery quarantined the honest prefix holding a FIFO: " &
          $report.quarantinedPrefixes, 3)
  quit(0)

# ---------------------------------------------------------------------------
# Trace parsing
# ---------------------------------------------------------------------------

type
  TraceEvent = object
    syscall: string
    fdPath: string     ## ``-y`` path of the first fd argument, or ""
    strings: seq[string]  ## quoted string arguments, in order

proc parseLine(line: string): TraceEvent =
  ## One ``strace -f -y -s 4096`` line, after the pid column.
  var rest = line.strip()
  # Drop the leading pid that ``-f`` with ``-o`` writes.
  let sp = rest.find(' ')
  if sp > 0 and rest[0 ..< sp].allCharsInSet(Digits):
    rest = rest[sp + 1 .. ^1]
  let paren = rest.find('(')
  if paren <= 0: return
  result.syscall = rest[0 ..< paren]
  var i = paren + 1
  # First fd argument annotated as ``N</path>``.
  var j = i
  while j < rest.len and rest[j] in Digits: inc j
  if j > i and j < rest.len and rest[j] == '<':
    # The annotation ends at the first ``>`` followed by the next argument
    # or by the end of the argument list, whichever comes first.
    let a = rest.find(">,", j)
    let b = rest.find(">)", j)
    let e = if a >= 0 and b >= 0: min(a, b) elif a >= 0: a else: b
    if e > j: result.fdPath = rest[j + 1 ..< e]
  # Quoted strings (rename paths).
  var k = i
  while k < rest.len:
    if rest[k] == '"':
      var s = ""
      inc k
      while k < rest.len and rest[k] != '"':
        if rest[k] == '\\' and k + 1 < rest.len:
          s.add(rest[k + 1]); k += 2
        else:
          s.add(rest[k]); inc k
      result.strings.add(s)
    inc k

proc readTrace(path: string): seq[TraceEvent] =
  for line in lines(path):
    # ``-f`` splits a call another thread interrupts into an
    # ``<unfinished ...>`` line, which carries the call's name and arguments,
    # and a later ``<... resumed>`` line. The call is counted once, where it
    # started: its arguments are what this test reads.
    if "resumed>" in line: continue
    let ev = parseLine(line)
    if ev.syscall.len > 0: result.add(ev)

proc treeEntriesOf(dir: string): seq[string] =
  ## Every regular file and directory of ``dir``, relative ("" is ``dir``).
  result.add("")
  for rel in walkDirRec(dir, yieldFilter = {pcFile, pcDir}, relative = true,
                        followFilter = {pcDir}):
    result.add(rel.replace('\\', '/'))

proc straceExe(): string =
  result = findExe("strace")
  if result.len == 0:
    raise newException(OSError, "strace is not on PATH; it is part of the " &
      "reprobuild development shell (`nix develop`), which these Linux " &
      "durability cases require")

proc traceChild(spec, traceFile: string) =
  let args = @["-f", "-qq", "-y", "-s", "4096", "-o", traceFile,
    "-e", "trace=fsync,fdatasync,rename,renameat,renameat2,pwrite64,write",
    getAppFilename()]
  # strace is a host tool, deliberately outside reprobuild's typed
  # execution profiles: it is the observer, not the thing under test.
  let p = uncontrolledStartProcess(straceExe(), args = args,
    env = (block:
      var t = newStringTable()
      for k, v in envPairs(): t[k] = v
      t[ChildEnv] = spec
      t),
    options = {poStdErrToStdOut})
  let output = drainStream(p.outputStream)
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(OSError, "traced child failed (" & $code & "): " &
      output)

type DurabilityVerdict = object
  problems: seq[string]

proc checkPublishOrder(events: seq[TraceEvent]; publishedDir,
                       storeRoot: string): DurabilityVerdict =
  ## The order a power-loss-safe publish of ``publishedDir`` must show.
  let leaf = publishedDir.extractFilename
  var renameAt = -1
  var stagePath = ""
  for i, ev in events:
    if ev.syscall in ["rename", "renameat", "renameat2"] and
        ev.strings.len >= 2 and ev.strings[^1].endsWith("/" & leaf):
      renameAt = i
      stagePath = ev.strings[0]
      break
  if renameAt < 0:
    result.problems.add("no rename onto " & publishedDir & " in the trace")
    return
  # The fd paths ``-y`` prints are canonical; compare canonically.
  # The stage is gone by now; canonicalise through the store root, which
  # is not.
  let rootCanon = expandFilename(storeRoot)
  if not stagePath.startsWith(storeRoot & "/"):
    result.problems.add("the publishing rename's source " & stagePath &
      " is not under the store root " & storeRoot)
    return
  let stageCanon = rootCanon / stagePath[storeRoot.len + 1 .. ^1]
  let parentCanon = expandFilename(publishedDir.parentDir)
  let prefixesCanon = expandFilename(publishedDir.parentDir.parentDir)
  var synced: seq[string] = @[]
  for i in 0 ..< renameAt:
    let ev = events[i]
    if ev.syscall in ["fsync", "fdatasync"] and ev.fdPath.len > 0:
      if ev.fdPath == stageCanon:
        synced.add("")
      elif ev.fdPath.startsWith(stageCanon & "/"):
        synced.add(ev.fdPath[stageCanon.len + 1 .. ^1])
  for rel in treeEntriesOf(publishedDir):
    if rel notin synced:
      result.problems.add("staged " &
        (if rel.len == 0: "directory root" else: "entry '" & rel & "'") &
        " was never fsynced before the rename published it (its data or " &
        "directory entry can be lost to a power cut while the index names " &
        "the prefix)")
  # Every publish in this test creates ``prefixes/<pkg>/``, whose own name
  # in ``prefixes/`` must be durable before the index names the prefix.
  var prefixesSyncAt = -1
  for i, ev in events:
    if ev.syscall in ["fsync", "fdatasync"] and ev.fdPath == prefixesCanon:
      prefixesSyncAt = i
      break
  var parentSyncAt = -1
  var walWriteAt = -1
  for i in renameAt + 1 ..< events.len:
    let ev = events[i]
    if parentSyncAt < 0 and ev.syscall in ["fsync", "fdatasync"] and
        ev.fdPath == parentCanon:
      parentSyncAt = i
    if walWriteAt < 0 and ev.syscall in ["pwrite64", "write"] and
        ev.fdPath.endsWith("/index.db-wal"):
      walWriteAt = i
  if walWriteAt < 0:
    result.problems.add("no index.db-wal write after the rename: the index " &
      "commit was not observed, so the order cannot be judged")
  if parentSyncAt < 0:
    result.problems.add("the directory receiving the rename (" & parentCanon &
      ") was never fsynced after it: the rename itself can be lost to a " &
      "power cut")
  elif walWriteAt >= 0 and parentSyncAt > walWriteAt:
    result.problems.add("the index commit was written before the rename " &
      "was made durable (parent fsync after the index.db-wal write)")
  if prefixesSyncAt < 0:
    result.problems.add("the new package directory's name in " &
      prefixesCanon & " was never fsynced")
  elif walWriteAt >= 0 and prefixesSyncAt > walWriteAt:
    result.problems.add("the index commit was written before the new " &
      "package directory's name in " & prefixesCanon & " was made durable")

proc checkReinsertOrder(events: seq[TraceEvent];
                        prefixDir: string): DurabilityVerdict =
  ## The order recovery's re-insert of the unindexed ``prefixDir`` must
  ## show: every regular file and directory of the tree, its package
  ## directory and ``prefixes/`` fsynced (under their final names: nothing
  ## is renamed), and no ``index.db-wal`` write between the first of those
  ## flushes and the last, with the commit after the last.
  let canon = expandFilename(prefixDir)
  var wanted: seq[string] = @[]
  for rel in treeEntriesOf(prefixDir):
    wanted.add(if rel.len == 0: canon else: canon / rel)
  wanted.add(expandFilename(prefixDir.parentDir))
  wanted.add(expandFilename(prefixDir.parentDir.parentDir))
  var firstAt = -1
  var lastAt = -1
  for want in wanted:
    var at = -1
    for i, ev in events:
      if ev.syscall in ["fsync", "fdatasync"] and ev.fdPath == want:
        at = i
    if at < 0:
      result.problems.add(want & " was never fsynced before recovery " &
        "re-inserted the prefix naming it")
      continue
    if firstAt < 0 or at < firstAt: firstAt = at
    if at > lastAt: lastAt = at
  if lastAt < 0: return
  var commitAt = -1
  for i in firstAt ..< events.len:
    let ev = events[i]
    if ev.syscall in ["pwrite64", "write"] and
        ev.fdPath.endsWith("/index.db-wal"):
      if i < lastAt:
        result.problems.add("an index.db-wal write came between the flushes " &
          "of the re-inserted tree: the row was committed before the tree " &
          "was durable")
        return
      commitAt = i
      break
  if commitAt < 0:
    result.problems.add("no index.db-wal write after the flushes: the " &
      "re-insert's commit was not observed, so the order cannot be judged")

when defined(linux):
  suite "Linux: a publish is durable before the index names it":
    test "realizePrefix fsyncs the staged tree, renames, fsyncs the parent, then commits":
      let top = createTempDir("repro-durable-realize-", "")
      defer: removeDir(top)
      let storeRoot = top / "store"
      # Create the store first, so the trace holds the publish, not setup.
      block:
        var s = openStore(storeRoot)
        s.close()
      let traceFile = top / "trace.txt"
      traceChild("realize:" & storeRoot, traceFile)
      var s = openStore(storeRoot)
      defer: s.close()
      let rows = s.listPrefixes()
      check rows.len == 1
      let published = s.absolutePrefixPath(rows[0].realizedPath)
      let verdict = checkPublishOrder(readTrace(traceFile), published,
                                      storeRoot)
      for p in verdict.problems: checkpoint(p)
      check verdict.problems.len == 0

    test "store copy fsyncs the copied tree, renames, fsyncs the parent, then commits":
      let top = createTempDir("repro-durable-copy-", "")
      defer: removeDir(top)
      let src = top / "src"
      let dst = top / "dst"
      var rel = ""
      block:
        var s = openStore(src)
        rel = s.realizeTree("copied").relativePath
        s.close()
        var d = openStore(dst)
        d.close()
      let traceFile = top / "trace.txt"
      traceChild("copy:" & src & "|" & dst & "|" & rel, traceFile)
      let published = dst / rel
      check dirExists(published)
      let verdict = checkPublishOrder(readTrace(traceFile), published, dst)
      for p in verdict.problems: checkpoint(p)
      check verdict.problems.len == 0

    test "recovery flushes an unindexed tree before it re-inserts its row":
      # The tree a bundle import's unpack or a writer that died before its
      # index commit leaves: on disk, never flushed, with no row.
      let top = createTempDir("repro-durable-reinsert-", "")
      defer: removeDir(top)
      let root = top / "store"
      var rel = ""
      block:
        var s = openStore(root)
        let r = s.realizeTree("orphan")
        rel = r.relativePath
        s.db.exec("DELETE FROM prefixes WHERE prefix_id = x'" &
          hexOf(r.prefixId) & "'")
        s.close()
      let traceFile = top / "trace.txt"
      traceChild("recover:" & root, traceFile)
      block:
        var s = openStore(root)
        defer: s.close()
        check s.listPrefixes().len == 1
      let verdict = checkReinsertOrder(readTrace(traceFile), root / rel)
      for p in verdict.problems: checkpoint(p)
      check verdict.problems.len == 0

    test "a FIFO in a prefix hangs neither the flush nor recovery":
      # ``walkDir`` reports a FIFO as a file. Opening one to fsync or to
      # hash it without O_NONBLOCK waits for a writer that never comes.
      let top = createTempDir("repro-durable-fifo-", "")
      defer: removeDir(top)
      let root = top / "store"
      block:
        var s = openStore(root)
        s.close()
      let p = uncontrolledStartProcess(getAppFilename(), args = @[],
        env = (block:
          var t = newStringTable()
          for k, v in envPairs(): t[k] = v
          t[ChildEnv] = "fifo:" & root
          t),
        options = {poStdErrToStdOut})
      let deadline = epochTime() + 120.0
      while p.running and epochTime() < deadline:
        sleep(50)
      let hung = p.running
      if hung:
        p.kill()
      let code = p.waitForExit()
      let output = drainStream(p.outputStream)
      p.close()
      checkpoint("child output: " & output)
      check not hung
      check code == 0
      var s = openStore(root)
      defer: s.close()
      check s.listPrefixes().len == 1

# ---------------------------------------------------------------------------
# Recovery
# ---------------------------------------------------------------------------

proc loseFileData(path: string) =
  ## What a power cut leaves of a file whose name was journaled but whose
  ## data blocks were never written: the name, at size zero.
  writeFile(path, "")

proc deleteRow(s: var Store; prefixId: PrefixIdBytes) =
  s.db.exec("DELETE FROM prefixes WHERE prefix_id = x'" & hexOf(prefixId) &
    "'")

proc clearContentDigest(s: var Store; prefixId: PrefixIdBytes) =
  s.db.exec("UPDATE prefixes SET content_digest = NULL WHERE prefix_id = x'" &
    hexOf(prefixId) & "'")

proc pendingDeletionHolds(storeRoot, leaf: string): bool =
  for kind, p in walkDir(storeRoot / "gc" / "pending-deletion"):
    if p.extractFilename.startsWith(leaf): return true

proc damagedFile(r: RealizeResult; storeRoot: string): string =
  storeRoot / r.relativePath / "lib" / "deep" / "data.txt"

suite "Recovery verifies prefix contents":
  test "an indexed prefix whose file lost its data is moved aside, and realised again":
    let top = createTempDir("repro-recover-indexed-", "")
    defer: removeDir(top)
    let root = top / "store"
    var s = openStore(root)
    let damaged = s.realizeTree("damaged")
    let honest = s.realizeTree("honest")
    s.close()
    loseFileData(damaged.damagedFile(root))
    forgetVerifiedPrefixes()
    let report = recoverStoreRoot(root)
    checkpoint("quarantined: " & $report.quarantinedPrefixes)
    check (root / damaged.relativePath) in report.quarantinedPrefixes
    check not dirExists(root / damaged.relativePath)
    check pendingDeletionHolds(root, damaged.relativePath.extractFilename)
    # The honest twin is untouched.
    check (root / honest.relativePath) notin report.quarantinedPrefixes
    check dirExists(root / honest.relativePath)
    # The next realisation publishes a correct tree in place.
    s = openStore(root)
    defer: s.close()
    let again = s.realizeTree("damaged")
    check again.relativePath == damaged.relativePath
    check readFile(again.damagedFile(root)) ==
      repeat("damaged payload line\n", 64)

  test "an unindexed prefix whose file lost its data is not re-inserted":
    let top = createTempDir("repro-recover-unindexed-", "")
    defer: removeDir(top)
    let root = top / "store"
    var s = openStore(root)
    let damaged = s.realizeTree("damaged")
    let honest = s.realizeTree("honest")
    # The index commit did not survive the power cut, for either prefix.
    s.deleteRow(damaged.prefixId)
    s.deleteRow(honest.prefixId)
    s.close()
    loseFileData(damaged.damagedFile(root))
    let report = recoverStoreRoot(root)
    checkpoint("reinserted: " & $report.reinsertedPrefixes &
      " quarantined: " & $report.quarantinedPrefixes)
    check (root / damaged.relativePath) notin report.reinsertedPrefixes
    check (root / damaged.relativePath) in report.quarantinedPrefixes
    check not dirExists(root / damaged.relativePath)
    # The honest twin is re-inserted WITH its tree digest recorded, so a
    # later use checks it rather than trusting whatever it then finds.
    check (root / honest.relativePath) in report.reinsertedPrefixes
    s = openStore(root)
    defer: s.close()
    check not s.lookupPrefix(damaged.prefixId).found
    check s.lookupPrefix(honest.prefixId).found
    forgetVerifiedPrefixes()
    let v = s.verifyRealizedPrefix(honest.prefixId, root / honest.relativePath)
    check v.outcome == pvVerified

  test "a row with no recorded digest is checked against the receipt's":
    let top = createTempDir("repro-recover-nodigest-", "")
    defer: removeDir(top)
    let root = top / "store"
    var s = openStore(root)
    let damaged = s.realizeTree("damaged")
    let honest = s.realizeTree("honest")
    # An older build's row, or one the index rebuild wrote: no digest.
    s.clearContentDigest(damaged.prefixId)
    s.clearContentDigest(honest.prefixId)
    s.close()
    loseFileData(damaged.damagedFile(root))
    forgetVerifiedPrefixes()
    let report = recoverStoreRoot(root)
    check (root / damaged.relativePath) in report.quarantinedPrefixes
    check not dirExists(root / damaged.relativePath)
    check (root / honest.relativePath) notin report.quarantinedPrefixes
    # Recovery records the honest tree's digest instead of leaving it to
    # trust on first use.
    s = openStore(root)
    defer: s.close()
    forgetVerifiedPrefixes()
    check s.verifyRealizedPrefix(honest.prefixId,
      root / honest.relativePath).outcome == pvVerified

  test "an index rebuilt from receipts does not adopt a damaged prefix":
    let top = createTempDir("repro-recover-rebuild-", "")
    defer: removeDir(top)
    let root = top / "store"
    var s = openStore(root)
    let damaged = s.realizeTree("damaged")
    let honest = s.realizeTree("honest")
    s.close()
    loseFileData(damaged.damagedFile(root))
    # The index itself did not survive.
    for side in ["index.db", "index.db-wal", "index.db-shm"]:
      if fileExists(root / side): removeFile(root / side)
    writeFile(root / "index.db", "this is not a database, it is debris")
    let report = recoverStoreRoot(root)
    check report.indexRebuilt
    check (root / damaged.relativePath) notin report.reinsertedPrefixes
    check (root / damaged.relativePath) in report.quarantinedPrefixes
    check (root / honest.relativePath) in report.reinsertedPrefixes
    s = openStore(root)
    defer: s.close()
    check not s.lookupPrefix(damaged.prefixId).found
    forgetVerifiedPrefixes()
    check s.verifyRealizedPrefix(honest.prefixId,
      root / honest.relativePath).outcome == pvVerified

  test "honest store: recovery quarantines nothing and changes nothing":
    let top = createTempDir("repro-recover-honest-", "")
    defer: removeDir(top)
    let root = top / "store"
    var s = openStore(root)
    let a = s.realizeTree("a")
    let b = s.realizeTree("b")
    s.close()
    let before = @[prefixTreeDigest(root / a.relativePath),
                   prefixTreeDigest(root / b.relativePath)]
    let report = recoverStoreRoot(root)
    check report.quarantinedPrefixes.len == 0
    check report.reinsertedPrefixes.len == 0
    check @[prefixTreeDigest(root / a.relativePath),
            prefixTreeDigest(root / b.relativePath)] == before
