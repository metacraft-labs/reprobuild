## The worker's worktree pool and copy-on-write worktree leases —
## Distributed-Execution M1 (the receiver side).
##
## Checking a base commit out for every goal costs a full checkout. The pool
## keeps, per repository (`repoId`), up to `maxBasesPerRepo` BASE worktrees —
## each a checkout of one base commit with its own index, kept outside every
## lease and touched only by git, under the slot's lock — and gives each goal
## a LEASE: a copy-on-write clone of a base worktree in a directory of the
## goal's own (`dest`), which the snapshot's delta is then applied to.
##
##   1. a base slot already at the snapshot's `baseCommitSha` is reused;
##      otherwise a new slot is checked out, or the least recently used one
##      is reset (`read-tree --reset -u`, then `clean -ffdx`). A base commit
##      the repository cache lacks (or whose tree it lacks objects of) is
##      completed first from the snapshot's BASE PACK, when it carries one
##      (the requester's unpushed history, `materialize.ensureBaseObjects`),
##      and from the remote the operator configured for that repository
##      (`fetchRemotes`, the daemon's `repos=` file), if any. The checkout is
##      CANONICAL (`git_process.canonicalCheckoutArgs`: no attribute
##      conversion, git >= 2.40; a cache with `info/attributes` is refused)
##      and every file it wrote is then hashed and must be its blob, so the
##      stat data recorded for the base (step 4) describes blob bytes;
##   2. under the slot's lock, the base worktree is CLONED into `dest`
##      (`clonefile(2)` on macOS/APFS; `cp -a --reflink=auto` on Linux —
##      a reflink on btrfs/XFS, a copy elsewhere);
##   3. the snapshot's deletions and modified blobs are applied to `dest` —
##      each blob checked by BLAKE3, size and git blob id before it is written
##      (`materialize.writeSnapshotEntry`), never through a symlink;
##   4. the tree is VERIFIED against the files on disk, in process: when the
##      base was checked out its entries were recorded with the `lstat` data
##      of the files git wrote (kind, exec bit, size, modification time in
##      nanoseconds — what a clone keeps); every entry the delta did not
##      write must be in the lease with that same data, or else hash
##      (natively) to the same blob id and mode, or the snapshot is refused
##      ("differs from its tree"); then the tree id of the base entries with
##      the delta applied (`git_tree.treeIdFromEntries`) must equal the
##      manifest's `gitTreeSha1`. A warm lease runs no git process at all.
##
## Nothing is written into the repository cache but the base commits it
## fetches and the base packs it indexes (unreferenced objects, bounded by
## `MaxBasePackBytes` each, until the cache's own gc): the verification
## writes no object and no index.
##
## Concurrent goals never collide: each lease is its own clone, and a write
## into it — in place or by replacement — reaches neither the base nor
## another lease (copy-on-write, or a real copy). HARDLINKED leases are not
## offered: a goal writing a file in place would write the base's inode, and
## through it every later lease (and the Linux lease's `lchown` of its tree
## would re-own the base).
##
## Retention (EVID-6): a base worktree holds only committed content (a base
## commit); the uncommitted part of a snapshot exists only in the lease,
## which its owner removes when the goal ends (`releaseLease`, or the
## receiver's lease cleanup), and in memory. The repository cache never
## holds a byte of it.

import std/[monotimes, algorithm, os, osproc, sets, streams, strutils, tables, times]
when defined(posix):
  import std/posix

import blake3

import repro_core/ambient_execution

import ./git_process
import ./git_tree
import ./manifest
import ./materialize

const
  DefaultMaxBasesPerRepo* = 4
  BaseTreeDir = "tree"
  BaseIndexFile = "index"
  BaseCommitFile = "commit"
  BaseLockFile = "lock"
  BaseEntriesFile = "entries"
  LeaseGitConfig = ["-c", "core.checkStat=minimal", "-c",
    "core.trustctime=false", "-c", "core.fsmonitor=false"]

type
  WorktreePool* = ref object
    root*: string
    gitExe*: string
    maxBasesPerRepo*: int
    fetchRemotes*: Table[string, string]
      ## `repoId` -> a remote (URL or path) a missing base commit is fetched
      ## from. Operator configuration; never a field of a request.
    baseHits*: int
      ## Leases cloned from a base already at the wanted commit.
    baseCheckouts*: int
      ## Bases checked out (a new slot) or reset to another commit.
    baseFetches*: int
      ## Fetches from a configured remote.
    basePacks*: int
      ## Base packs indexed into a repository cache.
    maxBaseTreeBytes*: uint64
      ## The most bytes a base checkout may write (`materialize.
      ## baseTreeSizeRefusal`); `DefaultMaxBaseTreeBytes` by default.
    maxBlobBytes*: uint64
      ## The largest blob a base checkout may write; `MaxBlobBytes`.
    leases*: int
    lastCloneMode*: string
      ## `clonefile`, `cp-reflink-auto` or `copy` — what made the last lease.

  BaseSlot = object
    dir: string
    lockFd: cint

proc newWorktreePool*(root: string; gitExe = "git";
                      maxBasesPerRepo = DefaultMaxBasesPerRepo): WorktreePool =
  ## A pool under `root` (created owner-only).
  createDir(root)
  when defined(posix):
    setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
  WorktreePool(root: root, gitExe: gitExe,
    maxBasesPerRepo: max(1, maxBasesPerRepo),
    fetchRemotes: initTable[string, string](),
    maxBaseTreeBytes: DefaultMaxBaseTreeBytes, maxBlobBytes: MaxBlobBytes)

proc repoKey*(repoId: string): string =
  ## The pool directory of `repoId`: a hash, so an arbitrary repository id
  ## never becomes a path.
  digestHex(blake3.digest(repoId))[0 ..< 32]

when defined(macosx):
  proc c_clonefile(src, dst: cstring; flags: uint32): cint
    {.importc: "clonefile", header: "<sys/clonefile.h>".}
  const CloneNoFollow = 0x0001'u32
  const CloneNoOwnerCopy = 0x0002'u32

when defined(posix):
  proc c_flock(fd: cint; op: cint): cint {.importc: "flock",
    header: "<sys/file.h>".}
  const LockEx = cint(2)
  const LockNb = cint(4)

proc tryLock(path: string; blocking: bool): cint =
  ## An exclusive lock on `path` (created owner-only); the descriptor, or
  ## -1 when another holder has it (non-blocking) or it cannot be opened.
  when defined(posix):
    let fd = posix.open(path.cstring, O_RDWR or O_CREAT or O_CLOEXEC,
      Mode(0o600))
    if fd < 0:
      return -1
    let op = if blocking: LockEx else: LockEx or LockNb
    if c_flock(fd, op) != 0:
      discard posix.close(fd)
      return -1
    fd
  else:
    # One daemon per state directory (the daemon's own lock), and the pool
    # is used from its single thread: no second holder exists.
    0

proc unlock(fd: cint) =
  when defined(posix):
    if fd >= 0:
      discard posix.close(fd)

proc readCommit(slotDir: string): string =
  try: readFile(slotDir / BaseCommitFile).strip()
  except IOError, OSError: ""

proc writeCommit(slotDir, commit: string) =
  let tmp = slotDir / (BaseCommitFile & ".tmp")
  writeFile(tmp, commit & "\n")
  moveFile(tmp, slotDir / BaseCommitFile)

proc lastUsed(slotDir: string): times.Time =
  try: getLastModificationTime(slotDir / BaseCommitFile)
  except OSError: fromUnix(0)

proc ensureCommit(pool: WorktreePool; snap: RepoSnapshot; gitDir: string;
                  readBlob: BlobReader): string =
  ## "" when the base commit and its tree are in the repository cache
  ## (completed from the snapshot's base pack and the configured remote if
  ## needed), else the reason.
  ensureBaseObjects(pool.gitExe, gitDir, snap, readBlob,
    pool.fetchRemotes.getOrDefault(snap.repoId, ""), pool.basePacks,
    pool.baseFetches, pool.maxBaseTreeBytes, pool.maxBlobBytes)

proc slotAt(pool: WorktreePool; repoId, commit: string): bool =
  let repoDir = pool.root / repoKey(repoId)
  for i in 0 ..< pool.maxBasesPerRepo:
    if readCommit(repoDir / ("b" & $i)) == commit:
      return true
  false

proc needsBasePack*(pool: WorktreePool; repoCache: string;
                    snap: RepoSnapshot): bool =
  ## Whether a lease of `snap` would need its base pack: it carries one, no
  ## base slot is at its commit and the repository cache lacks the commit
  ## or objects of its tree. The receiver fetches a base pack only then.
  if not snap.hasBasePack or pool.slotAt(snap.repoId, snap.baseCommitSha):
    return false
  not baseComplete(pool.gitExe, absolutePath(gitDirOf(repoCache)),
    snap.baseCommitSha)

proc statOf(path: string): tuple[present, symlink, regular, exec: bool;
                                   size, mtimeNs: int64] =
  ## `lstat(2)` of `path`: kind, owner-exec bit, size and modification time
  ## in nanoseconds — what a copy-on-write clone keeps from its base.
  when defined(posix):
    var st: Stat
    if lstat(path.cstring, st) != 0:
      return
    result.present = true
    result.symlink = S_ISLNK(st.st_mode)
    result.regular = S_ISREG(st.st_mode)
    result.exec = (st.st_mode.int and 0o100) != 0
    result.size = int64(st.st_size)
    result.mtimeNs = int64(st.st_mtim.tv_sec) * 1_000_000_000 +
      int64(st.st_mtim.tv_nsec)
  else:
    try:
      let info = getFileInfo(path, followSymlink = false)
      result.present = true
      result.symlink = info.kind in {pcLinkToFile, pcLinkToDir}
      result.regular = info.kind == pcFile
      result.exec = fpUserExec in info.permissions
      result.size = info.size
      result.mtimeNs = info.lastWriteTime.toUnix * 1_000_000_000 +
        info.lastWriteTime.nanosecond
    except OSError:
      discard

proc resetBase(pool: WorktreePool; gitDir, slotDir, commit: string): string =
  ## Puts the base worktree of `slotDir` at `commit`. "" or the reason. The
  ## commit file is removed first, so a crash mid-reset leaves a slot that
  ## the next use resets again.
  try: removeFile(slotDir / BaseCommitFile) except OSError: discard
  let tree = slotDir / BaseTreeDir
  let fresh = not dirExists(tree)
  createDir(tree)
  let env = @[("GIT_INDEX_FILE", slotDir / BaseIndexFile)] &
    canonicalCheckoutEnv()
  let base = @["--git-dir=" & gitDir, "--work-tree=" & tree]
  var res = runGit(pool.gitExe, base & canonicalCheckoutArgs() &
    @LeaseGitConfig & @["read-tree", "--reset", "-u", commit], env, cwd = tree)
  if res.code != 0:
    return "git read-tree of the base commit failed: " & describe(res)
  if not fresh:
    res = runGit(pool.gitExe, base & @LeaseGitConfig &
      @["clean", "-ffdxq"], env, cwd = tree)
    if res.code != 0:
      return "git clean of the base worktree failed: " & describe(res)
  # The base's entries with the stat data of the files git just wrote: what
  # every lease cloned from this base is checked against, without a process.
  res = runGit(pool.gitExe, base & @["ls-files", "-s", "-z"], env, cwd = tree,
    mergeStderr = false)
  if res.code != 0:
    return "listing the base index failed: " & describe(res)
  var entries = ""
  for rec in nulRecords(res.output):
    # `<mode> SP <object> SP <stage> TAB <path>`
    let tab = rec.find('\t')
    if tab < 0: continue
    let meta = rec[0 ..< tab].split(' ')
    if meta.len != 3: continue
    let path = rec[tab + 1 .. ^1]
    var size = -1'i64
    var mtime = 0'i64
    if meta[0] != "160000":
      # What git wrote must BE the blob (no conversion slipped through):
      # the stat data recorded below vouches for these bytes in every
      # lease cloned from this base.
      let disk = diskEntry(tree / path)
      let modeDiffers = when defined(posix): disk.mode != meta[0] else: false
      if not disk.present or modeDiffers or hexOf(disk.oid) != meta[1]:
        return "the base checkout wrote other bytes than the blob for " &
          path & " (an attribute conversion or filter?)"
      let st = statOf(tree / path)
      if not st.present:
        return "the base worktree lacks " & path & " after its checkout"
      size = st.size
      mtime = st.mtimeNs
    entries.add(meta[0] & " " & meta[1] & " " & $size & " " & $mtime & "\t" &
      path & "\0")
  writeFile(slotDir / BaseEntriesFile, entries)
  writeCommit(slotDir, commit)
  inc pool.baseCheckouts
  ""

proc acquireBase(pool: WorktreePool; snap: RepoSnapshot; gitDir: string;
                 readBlob: BlobReader): tuple[slot: BaseSlot; reason: string] =
  ## A locked base slot at the snapshot's base commit (see the module doc).
  let repoId = snap.repoId
  let commit = snap.baseCommitSha
  let repoDir = pool.root / repoKey(repoId)
  if not dirExists(repoDir):
    createDir(repoDir)
    writeFile(repoDir / "repo-id", repoId & "\n")
  var slots: seq[string] = @[]
  for i in 0 ..< pool.maxBasesPerRepo:
    if dirExists(repoDir / ("b" & $i)):
      slots.add(repoDir / ("b" & $i))
  # 1. A slot already at the commit.
  for s in slots:
    if readCommit(s) == commit:
      let fd = tryLock(s / BaseLockFile, blocking = false)
      if fd >= 0:
        if readCommit(s) == commit:
          try: setLastModificationTime(s / BaseCommitFile, getTime())
          except OSError: discard
          inc pool.baseHits
          return (BaseSlot(dir: s, lockFd: fd), "")
        unlock(fd)
  # Everything below checks a commit out: it must be in the cache.
  let missing = pool.ensureCommit(snap, gitDir, readBlob)
  if missing.len > 0:
    return (BaseSlot(lockFd: -1), missing)
  # 2. A new slot.
  if slots.len < pool.maxBasesPerRepo:
    for i in 0 ..< pool.maxBasesPerRepo:
      let s = repoDir / ("b" & $i)
      if dirExists(s): continue
      createDir(s)
      let fd = tryLock(s / BaseLockFile, blocking = false)
      if fd < 0: continue
      let bad = pool.resetBase(gitDir, s, commit)
      if bad.len > 0:
        unlock(fd)
        return (BaseSlot(lockFd: -1), bad)
      return (BaseSlot(dir: s, lockFd: fd), "")
  # 3. The least recently used slot, reset.
  var lru = slots
  lru.sort(proc(a, b: string): int = cmp(lastUsed(a), lastUsed(b)))
  var fd = -1.cint
  var chosen = ""
  for s in lru:
    fd = tryLock(s / BaseLockFile, blocking = false)
    if fd >= 0:
      chosen = s
      break
  if fd < 0:
    chosen = lru[0]
    fd = tryLock(chosen / BaseLockFile, blocking = true)
    if fd < 0:
      return (BaseSlot(lockFd: -1), "cannot lock a base worktree slot")
  if readCommit(chosen) == commit:
    inc pool.baseHits
    return (BaseSlot(dir: chosen, lockFd: fd), "")
  let bad = pool.resetBase(gitDir, chosen, commit)
  if bad.len > 0:
    unlock(fd)
    return (BaseSlot(lockFd: -1), bad)
  (BaseSlot(dir: chosen, lockFd: fd), "")

proc cloneTree(pool: WorktreePool; src, dest: string): string =
  ## Copy-on-write clone of the directory `src` to `dest` (which must not
  ## exist). "" or the reason.
  when defined(macosx):
    if c_clonefile(src.cstring, dest.cstring,
        CloneNoFollow or CloneNoOwnerCopy) == 0:
      pool.lastCloneMode = "clonefile"
      return ""
    # Not APFS (or across volumes): fall through to a copy.
  when defined(posix):
    let args =
      when defined(linux): @["-a", "--reflink=auto", src, dest]
      else: @["-pPR", src, dest]
    let p = uncontrolledStartProcess("cp", args = args,
      options = {poUsePath, poStdErrToStdOut})
    let output = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    if code != 0:
      return "cloning the base worktree failed: " & output.strip()
    pool.lastCloneMode = when defined(linux): "cp-reflink-auto" else: "copy"
    ""
  else:
    try:
      copyDirWithPermissions(src, dest)
      pool.lastCloneMode = "copy"
      ""
    except OSError as err:
      "cloning the base worktree failed: " & err.msg

proc materializeLease*(pool: WorktreePool; repoCache: string;
                       snap: RepoSnapshot; dest: string;
                       readBlob: BlobReader): MaterializeResult =
  ## Materializes `snap` (already validated) into `dest` (which must not
  ## exist; its parent must) as a lease cloned from the pool. See the module
  ## doc.
  result.worktree = dest
  if dirExists(dest) or fileExists(dest) or symlinkExists(dest):
    return MaterializeResult(worktree: dest,
      reason: "materialization target exists: " & dest)
  let gitDir = absolutePath(gitDirOf(repoCache))
  let tooOld = canonicalCheckoutRefusal(pool.gitExe)
  if tooOld.len > 0:
    return MaterializeResult(worktree: dest, reason: tooOld)
  let attrs = cacheAttributesRefusal(gitDir)
  if attrs.len > 0:
    return MaterializeResult(worktree: dest, reason: attrs)
  let acquired = pool.acquireBase(snap, gitDir, readBlob)
  if acquired.reason.len > 0:
    return MaterializeResult(worktree: dest, reason: acquired.reason)
  var baseEntries = ""
  block cloning:
    defer: unlock(acquired.slot.lockFd)
    let bad = pool.cloneTree(acquired.slot.dir / BaseTreeDir, dest)
    if bad.len > 0:
      return MaterializeResult(worktree: dest, reason: bad)
    try:
      baseEntries = readFile(acquired.slot.dir / BaseEntriesFile)
    except IOError, OSError:
      return MaterializeResult(worktree: dest, reason: "reading the base " &
        "entry list failed: " & getCurrentExceptionMsg())
  inc pool.leases
  # The base's entries: path -> (mode, object id, size, mtime in ns).
  type BaseEntry = tuple[mode: string; oid: Sha1Bytes; size, mtime: int64]
  var entries = initOrderedTable[string, BaseEntry]()
  for rec in nulRecords(baseEntries):
    let tab = rec.find('\t')
    if tab < 0: continue
    let meta = rec[0 ..< tab].split(' ')
    if meta.len != 4: continue
    try:
      entries[rec[tab + 1 .. ^1]] = (meta[0], parseSha1Hex(meta[1]),
        parseBiggestInt(meta[2]), parseBiggestInt(meta[3]))
    except ValueError:
      return MaterializeResult(worktree: dest, reason: "the base entry list " &
        "is malformed")
  # Apply the delta.
  var touched = initHashSet[string]()
  for rel in snap.deleted:
    touched.incl(rel)
    if entries.getOrDefault(rel).mode == "160000":
      entries.del(rel)        # a submodule: no file to remove
      continue
    let bad = deleteSnapshotPath(dest, rel)
    if bad.len > 0:
      return MaterializeResult(worktree: dest, reason: bad)
    entries.del(rel)
  for m in snap.modified:
    touched.incl(m.relPath)
    if m.mode != ModeGitlink:
      let bad = writeSnapshotEntry(dest, m, readBlob)
      if bad.len > 0:
        return MaterializeResult(worktree: dest, reason: bad)
    entries[m.relPath] = (toOct(int(m.mode), 6).strip(leading = true,
      trailing = false, chars = {'0'}), parseSha1Hex(m.gitOid), -1'i64, 0'i64)
  # Verify against the disk: every entry the delta did not write must be in
  # the lease exactly as the base checked it out — the same kind, size and
  # modification time (a clone keeps them), or else the same content and
  # mode, hashed. Anything else is a worktree that differs from its tree.
  var drifted: seq[string] = @[]
  for path, e in entries.pairs:
    if path in touched or e.mode == "160000":
      continue
    let st = statOf(dest / path)
    if not st.present:
      drifted.add(path)
      continue
    let kindOk =
      if e.mode == "120000": st.symlink
      else: st.regular and (st.exec == (e.mode == "100755"))
    let same = kindOk and st.size == e.size and st.mtimeNs == e.mtime
    if not same:
      let disk = diskEntry(dest / path)
      if not disk.present or disk.mode != e.mode or disk.oid != e.oid:
        drifted.add(path)
  if drifted.len > 0:
    drifted.sort()
    return MaterializeResult(worktree: dest, reason: "the materialized " &
      "worktree differs from its tree at " & drifted.join(", "))
  var treeEntries: seq[tuple[path, mode: string; oid: Sha1Bytes]] = @[]
  for path, e in entries.pairs:
    treeEntries.add((path, e.mode, e.oid))
    if e.mode == "160000": result.gitlinks.add((path, hexOf(e.oid)))
    else: result.tracked.add(path)
  result.tracked.sort()
  result.observedTree = treeIdFromEntries(treeEntries)
  if result.observedTree != snap.gitTreeSha1:
    result.reason = "materialized tree " & result.observedTree &
      " does not match the manifest's git-tree-sha1 " & snap.gitTreeSha1
    return
  result.ok = true

proc releaseLease*(dest: string) =
  ## Removes a lease's worktree (and with it the snapshot's uncommitted
  ## content on this host).
  try: removeDir(dest) except OSError: discard

proc siblingDirName*(repoId: string): string =
  ## The directory a `repro develop` sibling is materialized under: its
  ## repository id when that is a plain name, else a hash of it.
  var plain = repoId.len > 0 and repoId.len <= 100 and repoId notin [".", ".."]
  for ch in repoId:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '-'}:
      plain = false
  if plain: repoId else: "repo-" & repoKey(repoId)

type
  WorkspaceMaterializeResult* = object
    ok*: bool
    reason*: string
    primary*: MaterializeResult
    siblings*: seq[(string, MaterializeResult)]
      ## (repoId, result) per `repro develop` sibling, in manifest order.
    elapsedMs*: seq[float]
      ## Wall time of each repository's lease, primary first.

proc materializeWorkspaceSnapshot*(pool: WorktreePool;
    manifest: WorkspaceSnapshotManifest;
    repoCacheFor: proc(repoId: string): string {.gcsafe, closure.};
    primaryDest, siblingsRoot: string;
    readBlob: BlobReader): WorkspaceMaterializeResult =
  ## The primary repository into `primaryDest` and every `repro develop`
  ## sibling into `siblingsRoot/<siblingDirName(repoId)>`, each as a pool
  ## lease, each verified against its own `gitTreeSha1`. Stops at the first
  ## failure.
  let invalid = validateManifest(manifest)
  if invalid.len > 0:
    return WorkspaceMaterializeResult(reason: invalid)
  var repos = @[(manifest.primaryRepo, primaryDest)]
  if manifest.developSiblings.len > 0:
    createDir(siblingsRoot)
  for s in manifest.developSiblings:
    repos.add((s, siblingsRoot / siblingDirName(s.repoId)))
  var seenDest = initHashSet[string]()
  for i, (snap, dest) in repos:
    if dest in seenDest:
      return WorkspaceMaterializeResult(reason: "two repositories of the " &
        "snapshot map to " & dest)
    seenDest.incl(dest)
    let cache = repoCacheFor(snap.repoId)
    if cache.len == 0:
      return WorkspaceMaterializeResult(reason: "this worker holds no " &
        "repository cache for '" & snap.repoId & "'")
    let started = getMonoTime()
    let mat = pool.materializeLease(cache, snap, dest, readBlob)
    result.elapsedMs.add(float((getMonoTime() - started).inMicroseconds) /
      1000.0)
    if i == 0:
      result.primary = mat
    else:
      result.siblings.add((snap.repoId, mat))
    if not mat.ok:
      result.reason = (if i == 0: "primary repository: "
                       else: "repro develop sibling " & snap.repoId & ": ") &
        mat.reason
      return
  result.ok = true
