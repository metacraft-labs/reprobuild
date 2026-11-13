## Materializing a snapshot into a fresh worktree — Distributed-Execution M7
## (the receiver half M1 extends with the reusable worktree pool).
##
## `materializeRepoSnapshot` turns a VALIDATED `RepoSnapshot` into files:
##
##   1. the base commit's tree is written out of the worker's local
##      repository cache into `dest` by `checkoutBaseTree`: the entries are
##      listed with `git ls-tree` and every blob's RAW bytes are read through
##      one `git cat-file --batch` and written as they are. No git checkout
##      machinery runs, so nothing converts them — no `.gitattributes`
##      (`text`/`eol`, `filter=` smudge, `ident`, `working-tree-encoding`),
##      no `$GIT_DIR/info/attributes` or global attributes file, no
##      `core.autocrlf`. `dest` gets no `.git`, and the cache's own index and
##      work tree are never touched;
##   2. deletions are applied and modified blobs written, each blob fetched
##      by its BLAKE3 digest and checked three ways before it is written —
##      BLAKE3 (what it was fetched by), size, and git blob id (what the tree
##      id is computed over) — so a peer cannot substitute content;
##   3. the tree id of the tracked path set is computed natively
##      (`git_tree.treeIdOf`) and must equal the manifest's `gitTreeSha1`.
##
## The worktree's content is therefore defined ONE way: a tracked file holds
## its blob's bytes. Modified entries are written verbatim, `treeIdOf` (and
## `reverifyTree` after the goal) hashes the bytes on disk, and the base
## checkout must agree with both — a converted checkout (CRLF line endings,
## an expanded `$Id$`, a smudged filter output) hashes to another blob id,
## and every snapshot of such a repository used to be refused. The goal sees
## the repository's canonical content, not a developer's smudged working
## tree.
##
## No write ever follows a symlink: every parent component of a written or
## deleted path must be a real directory under `dest` (a manifest that first
## creates `a -> /etc` and then writes `a/passwd` is refused).
##
## Distributed-Execution M1 review fixes (2026-10-22):
##
## * CANONICAL BYTES. The fresh checkout writes blob bytes itself
##   (`checkoutBaseTree`, above). The worktree pool's base checkout
##   (`pool.resetBase`) runs git's own `read-tree -u` with `git_process.
##   canonicalCheckoutArgs` (attributes from the empty tree, no attributes
##   file, `core.autocrlf=false`; git >= 2.40) and refuses a cache holding
##   `info/attributes` (which git applies regardless), then hashes every file
##   it wrote. Every git here runs with `GIT_NO_REPLACE_OBJECTS`
##   (`git_process.gitEnvironment`).
## * BASE PACKS. A base commit the cache lacks is completed from the
##   snapshot's base pack, when it names one (`ensureBaseObjects`): the pack
##   is checked by BLAKE3 and size, indexed into the cache with
##   `index-pack --fsck-objects`, and the commit and its whole tree must then
##   be present.
## * A deletion that empties a directory removes the directory, so a
##   snapshot that replaces a directory with a file materializes.
## * BOUNDED BASE TREE (round 2): a base pack is capped compressed only, so
##   before any checkout the base tree's blob sizes are summed
##   (`git ls-tree -r -l`): a blob over `MaxBlobBytes` or a total over
##   `maxTreeBytes` (default `DefaultMaxBaseTreeBytes`, 4 GiB) refuses the
##   snapshot with the reason, before a byte of it is written to disk.

import std/[options, os, osproc, sets, streams, strutils, tables]
when defined(posix):
  import std/posix

import blake3

import repro_core/ambient_execution

import ./git_process
import ./git_tree
import ./manifest

type
  BlobReader* = proc(digest: Blake3Digest): Option[seq[byte]] {.gcsafe, closure.}

  MaterializeResult* = object
    ok*: bool
    reason*: string
    worktree*: string
    tracked*: seq[string]
      ## The tracked path set the tree id is computed over.
    gitlinks*: seq[(string, string)]
      ## Submodule entries (path, commit id) the tree id includes.
    observedTree*: string

  BaseTreeEntry* = object
    ## One blob entry of a commit's tree, as `git ls-tree` lists it.
    path*: string
    mode*: uint32
      ## `ModeRegular`, `ModeExecutable` or `ModeSymlink`.
    oid*: string
      ## 40-hex git blob id.

  BaseCheckout* = object
    ok*: bool
    reason*: string
    paths*: seq[string]
      ## The regular-file and symlink paths written under `dest`.
    gitlinks*: seq[(string, string)]
      ## Submodule entries (path, commit id); nothing is written for them.

proc treeEntriesAt*(repoCache, commit: string;
                    gitExe = "git"): tuple[ok: bool;
                                           blobs: seq[BaseTreeEntry];
                                           gitlinks: seq[(string, string)];
                                           reason: string] =
  ## Every blob entry (path, mode, blob id) of `commit`'s tree, and its
  ## submodule links (path, commit id). A path that could not be written
  ## safely under a worktree (`validateRelPath`: `..`, `.git`, …) or a mode
  ## a worktree cannot represent refuses the whole tree. `git checkout`
  ## refuses such paths too, and nothing here may be laxer than it — so a
  ## `.git` component is refused in any letter case, as git's `verify_path`
  ## does on every platform: on a case-insensitive filesystem `.GIT/config`
  ## IS a `.git/config` to any git run inside the worktree.
  let res = runGit(gitExe, ["--git-dir=" & gitDirOf(repoCache), "ls-tree",
    "-r", "-z", "--full-tree", commit])
  if res.code != 0:
    return (false, @[], @[], "git ls-tree failed: " & res.output.strip())
  for rec in res.output.split('\0'):
    if rec.len == 0: continue
    let tab = rec.find('\t')
    if tab < 0: continue
    let meta = rec[0 ..< tab].splitWhitespace()
    let path = rec[tab + 1 .. ^1]
    if meta.len < 3: continue
    var bad = validateRelPath(path)
    if bad.len == 0:
      for comp in path.split('/'):
        if comp.toLowerAscii == ".git":
          bad = ".git component in " & path
    if bad.len > 0:
      return (false, @[], @[], "unsafe path in the base tree: " & bad)
    if meta[1] == "blob":
      var mode: uint32
      try:
        mode = uint32(parseOctInt(meta[0]))
      except ValueError:
        return (false, @[], @[], "unparsable mode " & meta[0] & " for " & path)
      if mode notin [ModeRegular, ModeExecutable, ModeSymlink]:
        return (false, @[], @[], "unsupported mode " & meta[0] & " for " &
          path)
      result.blobs.add(BaseTreeEntry(path: path, mode: mode, oid: meta[2]))
    elif meta[1] == "commit" and meta[0] == "160000":
      result.gitlinks.add((path, meta[2]))
  result.ok = true

proc trackedPathsAt*(repoCache, commit: string;
                     gitExe = "git"): tuple[ok: bool; paths: seq[string];
                                            gitlinks: seq[(string, string)];
                                            reason: string] =
  ## The regular-file and symlink paths of `commit`'s tree, and its
  ## submodule links (path, commit id) — not content a worktree carries,
  ## but part of the tree id (threat model G32: a repository with
  ## submodules never verified while they were left out).
  let entries = treeEntriesAt(repoCache, commit, gitExe)
  if not entries.ok:
    return (false, @[], @[], entries.reason)
  for e in entries.blobs: result.paths.add(e.path)
  result.gitlinks = entries.gitlinks
  result.ok = true

proc safeParentChain(dest, rel: string): string =
  ## "" when every parent of `rel` under `dest` is a real directory (or
  ## absent), else the offending component.
  let parts = rel.split('/')
  var cur = dest
  for i in 0 ..< parts.high:
    cur = cur / parts[i]
    when defined(posix):
      var st: Stat
      if lstat(cur.cstring, st) == 0:
        if S_ISLNK(st.st_mode) or not S_ISDIR(st.st_mode):
          return cur
    else:
      if symlinkExists(cur): return cur
  ""

proc ensureParents(dest, rel: string) =
  let parts = rel.split('/')
  var cur = dest
  for i in 0 ..< parts.high:
    cur = cur / parts[i]
    if not dirExists(cur):
      createDir(cur)

proc pruneEmptyParents(dest, rel: string) =
  ## Removes the directories above `rel` that its deletion left empty (git
  ## tracks no empty directory), innermost first, never `dest` itself. The
  ## parents were checked to be real directories (`safeParentChain`).
  var parts = rel.split('/')
  while parts.len > 1:
    parts.setLen(parts.len - 1)
    let dir = dest / parts.join("/")
    if symlinkExists(dir) or not dirExists(dir):
      return
    var empty = true
    for _ in walkDir(dir):
      empty = false
      break
    if not empty:
      return
    try: removeDir(dir) except OSError: return

proc deleteSnapshotPath*(dest, rel: string; allowEmptyDirectory = false): string =
  ## Removes the file or symlink a snapshot deletes, never through a
  ## non-directory parent, and the directories that leaves empty. "" on
  ## success, else the reason. Gitlink deletion/type transitions may opt in
  ## to removing their empty checkout directory. Never remove its contents.
  let bad = safeParentChain(dest, rel)
  if bad.len > 0:
    return "refusing to delete through a non-directory component: " & bad
  if fileExists(dest / rel) or symlinkExists(dest / rel):
    removeFile(dest / rel)
  elif allowEmptyDirectory and dirExists(dest / rel):
    for _ in walkDir(dest / rel, checkDir = true):
      return "refusing to remove a non-empty gitlink directory: " & rel
    removeDir(dest / rel)
  pruneEmptyParents(dest, rel)
  ""

proc verifiedBlob*(m: ModifiedFileEntry; readBlob: BlobReader):
    tuple[ok: bool; bytes: seq[byte]; reason: string] =
  ## The bytes of a modified entry, checked three ways before anything is
  ## written: BLAKE3 (what they were fetched by), size, and git blob id
  ## (what the tree id is computed over).
  let blob = readBlob(m.blake3Digest)
  if blob.isNone:
    return (false, @[], "blob " & digestHex(m.blake3Digest) & " for " &
      m.relPath & " is unavailable")
  let bytes = blob.get()
  if blake3.digest(bytes) != m.blake3Digest:
    return (false, @[], "blob for " & m.relPath &
      " does not hash to its BLAKE3 digest")
  if uint64(bytes.len) != m.size:
    return (false, @[], "blob for " & m.relPath & " has the wrong size")
  if gitBlobOid(bytes) != m.gitOid:
    return (false, @[], "blob for " & m.relPath &
      " does not hash to its git blob id")
  (true, bytes, "")

proc writeTracked(dest, rel: string; mode: uint32; content: string): string =
  ## Writes `content` — blob bytes, verbatim — at `dest/rel` as git mode
  ## `mode` would check it out (a symlink's content is its target). "" on
  ## success, else why it was refused. Never writes through a symlink or a
  ## non-directory parent; whatever stood at `rel` itself is replaced.
  let bad = safeParentChain(dest, rel)
  if bad.len > 0:
    return "refusing to write through a non-directory component: " & bad
  ensureParents(dest, rel)
  let target = dest / rel
  if fileExists(target) or symlinkExists(target):
    removeFile(target)
  if mode == ModeSymlink:
    createSymlink(content, target)
  else:
    writeFile(target, content)
    var perms = {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead}
    if mode == ModeExecutable:
      perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
    setFilePermissions(target, perms)
  ""

proc writeSnapshotEntry*(dest: string; m: ModifiedFileEntry;
                         readBlob: BlobReader): string =
  ## Writes one verified, non-submodule modified entry under `dest`, never
  ## through a non-directory parent. "" on success, else the reason.
  let blob = verifiedBlob(m, readBlob)
  if not blob.ok:
    return blob.reason
  var text = newString(blob.bytes.len)
  if blob.bytes.len > 0:
    copyMem(addr text[0], unsafeAddr blob.bytes[0], blob.bytes.len)
  writeTracked(dest, m.relPath, m.mode, text)

proc toText(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  if bytes.len > 0: copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc readExactly(s: Stream; n: int): string =
  ## Up to `n` bytes of `s`, fewer only at end of stream. One `readData` is
  ## not enough: on Windows a pipe read returns what one `ReadFile` call
  ## delivered, which can be part of a large blob.
  result = newString(n)
  var got = 0
  while got < n:
    let r = s.readData(addr result[got], n - got)
    if r <= 0: break
    got += r
  result.setLen(got)

proc checkoutBaseTree*(repoCache, commit, dest: string;
                       gitExe = "git"): BaseCheckout =
  ## Writes `commit`'s tree from the repository cache into `dest` (created
  ## when absent) as BLOB BYTES — see the module doc for why no git
  ## conversion may run. Gitlinks are reported, not written. A filesystem
  ## error while writing (a blob path where `dest` already holds a
  ## directory, …) raises, as it does from `materializeRepoSnapshot`.
  ## (The worktree pool's base checkout uses git's own canonical checkout
  ## instead, `pool.resetBase`, and hashes every file it wrote.)
  ##
  ## Blobs are read through ONE `git cat-file --batch` (never `--filters` or
  ## `--textconv`, which would apply the very conversions this avoids), one
  ## request at a time: write an id, read its response, so neither pipe can
  ## fill while the other side waits. `--batch` flushes after every object
  ## unless `--buffer` is given (https://git-scm.com/docs/git-cat-file). Each
  ## blob must hash to the id the tree names before it is written. The
  ## caller bounds the tree's sizes first (`baseTreeSizeRefusal`).
  let entries = treeEntriesAt(repoCache, commit, gitExe)
  if not entries.ok:
    return BaseCheckout(reason: "base commit " & commit &
      " is not available in the repository cache: " & entries.reason)
  createDir(dest)
  if entries.blobs.len > 0:
    let p = uncontrolledStartProcess(gitExe,
      args = ["--git-dir=" & gitDirOf(repoCache), "cat-file", "--batch"],
      env = gitEnvironment([]), options = {poUsePath})
    # POSIX: a git that died (a corrupt pack, a full disk) leaves our next
    # request on a pipe with no reader, and SIGPIPE's DEFAULT disposition
    # kills the whole worker, silently. Ignored for the batch, the write
    # fails with an ordinary EPIPE `IOError` instead; the previous
    # disposition is restored, so this is not a process-wide policy change.
    when defined(posix):
      var ignoredSigPipe, previousSigPipe: Sigaction
      ignoredSigPipe.sa_handler = SIG_IGN
      discard sigemptyset(ignoredSigPipe.sa_mask)
      ignoredSigPipe.sa_flags = 0
      let sigPipeGuardInstalled =
        sigaction(SIGPIPE, ignoredSigPipe, addr previousSigPipe) == 0
    defer:
      # A refusal returns mid-batch with git still waiting on its stdin:
      # stop it and reap it on every path, not only the successful one.
      if p.running: p.terminate()
      discard p.waitForExit()
      p.close()
      when defined(posix):
        if sigPipeGuardInstalled:
          discard sigaction(SIGPIPE, previousSigPipe)
    proc gitGaveUp(what: string): BaseCheckout =
      # git's own diagnosis (`fatal: …` on stderr) is the useful half of a
      # premature end. git is stopped first, so reading stderr to its end
      # cannot block.
      if p.running: p.terminate()
      discard p.waitForExit()
      BaseCheckout(reason: what & ": " & p.errorStream.readAll().strip())
    let input = p.inputStream
    let output = p.outputStream
    for e in entries.blobs:
      try:
        input.write(e.oid & "\n")
        input.flush()
      except IOError as err:
        return gitGaveUp("git cat-file stopped reading before " & e.oid &
          " (" & e.path & "): " & err.msg)
      var header = ""
      if not output.readLine(header):
        return gitGaveUp("git cat-file ended before " & e.oid & " (" &
          e.path & ")")
      # "<oid> blob <size>", or "<oid> missing" / "<oid> ambiguous".
      let fields = header.splitWhitespace()
      if fields.len != 3 or fields[0] != e.oid or fields[1] != "blob":
        return BaseCheckout(reason: "git cat-file could not read blob " &
          e.oid & " for " & e.path & ": " & header)
      var size: int
      try:
        size = parseInt(fields[2])
      except ValueError:
        return BaseCheckout(reason: "git cat-file sent a malformed header: " &
          header)
      if size < 0:
        return BaseCheckout(reason: "git cat-file sent a malformed header: " &
          header)
      let content = output.readExactly(size)
      if content.len != size or output.readExactly(1) != "\n":
        return gitGaveUp("git cat-file sent a short blob " & e.oid & " for " &
          e.path)
      if gitBlobOid(content.toOpenArrayByte(0, content.high)) != e.oid:
        return BaseCheckout(reason: "blob for " & e.path &
          " does not hash to its git blob id " & e.oid)
      let refused = writeTracked(dest, e.path, e.mode, content)
      if refused.len > 0:
        return BaseCheckout(reason: refused)
      result.paths.add(e.path)
    input.close()
    let code = p.waitForExit()
    if code != 0:
      return BaseCheckout(reason: "git cat-file failed with exit code " &
        $code & ": " & p.errorStream.readAll().strip())
  result.gitlinks = entries.gitlinks
  result.ok = true

const
  DefaultMaxBaseTreeBytes* = 4'u64 * 1024'u64 * 1024'u64 * 1024'u64
    ## The most bytes a base commit's checkout may write (sum of its blobs).

proc baseTreeSizeRefusal*(gitExe, gitDir, commit: string;
                          maxTreeBytes = DefaultMaxBaseTreeBytes;
                          maxBlobBytes = MaxBlobBytes): string =
  ## "" when every blob of `commit`'s tree is at most `maxBlobBytes` and
  ## all of them together at most `maxTreeBytes`, else the reason. Reads
  ## object sizes only (`ls-tree -l`); nothing is inflated to disk.
  let res = runGit(gitExe, ["--git-dir=" & gitDir, "ls-tree", "-r", "-l",
    "-z", "--full-tree", commit], mergeStderr = false)
  if res.code != 0:
    return "listing the base tree failed: " & describe(res)
  var total = 0'u64
  for rec in nulRecords(res.output):
    # `<mode> SP <type> SP <object> SP+ <size> TAB <path>`
    let tab = rec.find('\t')
    if tab < 0: continue
    let meta = rec[0 ..< tab].splitWhitespace()
    if meta.len != 4 or meta[1] != "blob": continue
    var size: uint64
    try: size = uint64(parseBiggestUInt(meta[3]))
    except ValueError:
      return "the base tree lists an unreadable size for " & rec[tab + 1 .. ^1]
    if size > maxBlobBytes:
      return "base commit " & commit & " holds " & rec[tab + 1 .. ^1] &
        " of " & $size & " bytes, more than a worker checks out (" &
        $maxBlobBytes & ")"
    total += size
    if total > maxTreeBytes:
      return "base commit " & commit & " checks out to more than " &
        $maxTreeBytes & " bytes, more than a worker checks out"
  ""

proc commitPresent*(gitExe, gitDir, commit: string): bool =
  runGit(gitExe, ["--git-dir=" & gitDir, "cat-file", "-e",
    commit & "^{commit}"]).code == 0

proc baseComplete*(gitExe, gitDir, commit: string): bool =
  ## The commit is in the cache with every object of its tree (what a
  ## checkout of it reads; its history is not needed).
  if not commitPresent(gitExe, gitDir, commit):
    return false
  let res = runGit(gitExe, ["--git-dir=" & gitDir, "rev-list", "--objects",
    "--missing=print", commit & "^{tree}"], mergeStderr = false)
  if res.code != 0:
    return false
  for line in res.output.splitLines:
    if line.startsWith("?"):
      return false
  true

proc cacheNeedsBasePack*(repoCache: string; snap: RepoSnapshot;
                         gitExe = "git"): bool =
  ## Whether materializing `snap` from `repoCache` without a worktree pool
  ## would need its base pack (it carries one and the cache lacks the base
  ## commit or objects of its tree).
  snap.hasBasePack and not baseComplete(gitExe, gitDirOf(repoCache),
    snap.baseCommitSha)

proc applyBasePack*(gitExe, gitDir: string; snap: RepoSnapshot;
                    readBlob: BlobReader): string =
  ## Indexes the snapshot's base pack into the repository cache. "" or the
  ## reason.
  if not snap.hasBasePack:
    return "the snapshot carries no base pack"
  let blob = readBlob(snap.basePack)
  if blob.isNone:
    return "base pack " & digestHex(snap.basePack) & " is unavailable"
  let bytes = blob.get()
  if blake3.digest(bytes) != snap.basePack:
    return "base pack does not hash to its BLAKE3 digest"
  if uint64(bytes.len) != snap.basePackSize or
      snap.basePackSize > MaxBasePackBytes:
    return "base pack has the wrong size"
  let res = runGit(gitExe, ["--git-dir=" & gitDir, "index-pack", "--stdin",
    "--fsck-objects"], input = toText(bytes))
  if res.code != 0:
    return "indexing the base pack failed: " & describe(res)
  ""

proc ensureBaseObjectsUnbounded(gitExe, gitDir: string; snap: RepoSnapshot;
                                 readBlob: BlobReader; remote: string;
                                 packsApplied, remoteFetches: var int): string =
  let commit = snap.baseCommitSha
  if baseComplete(gitExe, gitDir, commit):
    return ""
  var why: seq[string] = @[]
  if snap.hasBasePack:
    let bad = applyBasePack(gitExe, gitDir, snap, readBlob)
    if bad.len == 0:
      inc packsApplied
      if baseComplete(gitExe, gitDir, commit):
        return ""
      why.add("the base pack left objects of the base tree missing")
    else:
      why.add(bad)
  if remote.len > 0:
    inc remoteFetches
    var res = runGit(gitExe, ["--git-dir=" & gitDir, "fetch", "-q",
      "--no-tags", "--no-write-fetch-head", remote, commit])
    if res.code != 0 or not baseComplete(gitExe, gitDir, commit):
      # A glob refspec needs a destination: the remote's branch heads land
      # under a namespace of the cache's own (`refs/reprobuild-remote/`),
      # never over a branch of the cache.
      res = runGit(gitExe, ["--git-dir=" & gitDir, "fetch", "-q",
        "--no-tags", "--no-write-fetch-head", remote,
        "+refs/heads/*:refs/reprobuild-remote/*"])
    if baseComplete(gitExe, gitDir, commit):
      return ""
    why.add("fetching from the configured remote did not complete it: " &
      describe(res))
  elif not snap.hasBasePack:
    why.add("the snapshot carries no base pack and no remote is configured " &
      "to fetch it from")
  "base commit " & commit & " is not available in the repository cache (" &
    why.join("; ") & ")"

proc ensureBaseObjects*(gitExe, gitDir: string; snap: RepoSnapshot;
                        readBlob: BlobReader; remote = "";
                        packsApplied, remoteFetches: var int;
                        maxTreeBytes = DefaultMaxBaseTreeBytes;
                        maxBlobBytes = MaxBlobBytes): string =
  ## "" when `snap.baseCommitSha` and its tree are in the repository cache
  ## — already, or after indexing the snapshot's base pack, or after
  ## fetching from `remote` (an operator-configured remote; by object id,
  ## then its branch heads) — and its tree is within the checkout bounds
  ## (`baseTreeSizeRefusal`), else the reason.
  result = ensureBaseObjectsUnbounded(gitExe, gitDir, snap, readBlob, remote,
    packsApplied, remoteFetches)
  if result.len == 0:
    result = baseTreeSizeRefusal(gitExe, gitDir, snap.baseCommitSha,
      maxTreeBytes, maxBlobBytes)

proc materializeRepoSnapshot*(repoCache: string; snap: RepoSnapshot;
                              dest: string; readBlob: BlobReader;
                              gitExe = "git";
                              maxTreeBytes = DefaultMaxBaseTreeBytes;
                              maxBlobBytes = MaxBlobBytes): MaterializeResult =
  ## See the module doc. `snap` must already have passed
  ## `validateManifest`. `dest` must not exist.
  result.worktree = dest
  if dirExists(dest) or fileExists(dest):
    return MaterializeResult(reason: "materialization target exists: " & dest)
  let gitDir = gitDirOf(repoCache)
  var packs, fetches = 0
  let missing = ensureBaseObjects(gitExe, gitDir, snap, readBlob, "", packs,
    fetches, maxTreeBytes, maxBlobBytes)
  if missing.len > 0:
    return MaterializeResult(reason: missing)
  let base = checkoutBaseTree(repoCache, snap.baseCommitSha, dest, gitExe)
  if not base.ok:
    return MaterializeResult(reason: base.reason)
  var tracked = initHashSet[string]()
  for p in base.paths: tracked.incl(p)
  var gitlinks = initTable[string, string]()
  for (p, commit) in base.gitlinks: gitlinks[p] = commit
  for rel in snap.deleted:
    let bad = deleteSnapshotPath(dest, rel,
      allowEmptyDirectory = gitlinks.hasKey(rel))
    if bad.len > 0:
      return MaterializeResult(reason: bad)
    gitlinks.del(rel)
    tracked.excl(rel)
  for m in snap.modified:
    if gitlinks.hasKey(m.relPath) or m.mode == ModeGitlink:
      let bad = deleteSnapshotPath(dest, m.relPath, allowEmptyDirectory = true)
      if bad.len > 0:
        return MaterializeResult(reason: bad)
    if m.mode == ModeGitlink:
      # A submodule moved to another commit: metadata only, no blob.
      gitlinks[m.relPath] = m.gitOid
      tracked.excl(m.relPath)
      continue
    gitlinks.del(m.relPath)
    let bad = writeSnapshotEntry(dest, m, readBlob)
    if bad.len > 0:
      return MaterializeResult(reason: bad)
    tracked.incl(m.relPath)
  for p in tracked: result.tracked.add(p)
  for p, commit in gitlinks.pairs: result.gitlinks.add((p, commit))
  let tree = treeIdOf(dest, result.tracked, result.gitlinks)
  result.observedTree = tree.treeHex
  if tree.treeHex != snap.gitTreeSha1:
    result.reason = "materialized tree " & tree.treeHex &
      " does not match the manifest's git-tree-sha1 " & snap.gitTreeSha1
    return
  result.ok = true

proc reverifyTree*(worktree: string; tracked: openArray[string];
                   expected: string;
                   gitlinks: openArray[(string, string)] = []):
                   tuple[ok: bool; observed: string] =
  ## The check run again after the goal and before a certificate is signed:
  ## does the tracked content still hash to `expected`?
  let tree = treeIdOf(worktree, tracked, gitlinks)
  (tree.treeHex == expected, tree.treeHex)
