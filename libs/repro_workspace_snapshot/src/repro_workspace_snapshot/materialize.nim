## Materializing a snapshot into a fresh worktree — Distributed-Execution M7
## (the receiver half M1 extends with the reusable worktree pool).
##
## `materializeRepoSnapshot` turns a VALIDATED `RepoSnapshot` into files:
##
##   1. the base commit's tree is checked out of the worker's local
##      repository cache into `dest` through a temporary index
##      (`read-tree` + `checkout-index`), so `dest` has no `.git` and the
##      cache's own index and work tree are never touched;
##   2. deletions are applied and modified blobs written, each blob fetched
##      by its BLAKE3 digest and checked three ways before it is written —
##      BLAKE3 (what it was fetched by), size, and git blob id (what the tree
##      id is computed over) — so a peer cannot substitute content;
##   3. the tree id of the tracked path set is computed natively
##      (`git_tree.treeIdOf`) and must equal the manifest's `gitTreeSha1`.
##
## No write ever follows a symlink: every parent component of a written or
## deleted path must be a real directory under `dest` (a manifest that first
## creates `a -> /etc` and then writes `a/passwd` is refused).

import std/[options, os, osproc, sets, streams, strtabs, strutils, tables]
when defined(posix):
  import std/posix

import blake3

import repro_core/ambient_execution

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

proc runGit(gitExe: string; args: openArray[string];
            extraEnv: openArray[(string, string)] = []): tuple[code: int;
                                                            output: string] =
  var env = newStringTable(modeCaseSensitive)
  for key in ["PATH", "HOME", "TMPDIR", "SYSTEMROOT"]:
    if existsEnv(key): env[key] = getEnv(key)
  env["GIT_CONFIG_NOSYSTEM"] = "1"
  env["GIT_TERMINAL_PROMPT"] = "0"
  for (k, v) in extraEnv: env[k] = v
  # The worker's OWN repository cache, read with the git the caller names
  # (`gitExe`; production passes the daemon's resolved git). Nothing here
  # runs a binary a caller supplied over the wire.
  let p = uncontrolledStartProcess(gitExe, args = @args, env = env,
    options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  (p.waitForExit(), output)

proc gitDirOf(repoCache: string): string =
  if dirExists(repoCache / ".git"): repoCache / ".git" else: repoCache

proc trackedPathsAt*(repoCache, commit: string;
                     gitExe = "git"): tuple[ok: bool; paths: seq[string];
                                            gitlinks: seq[(string, string)];
                                            reason: string] =
  ## The regular-file and symlink paths of `commit`'s tree, and its
  ## submodule links (path, commit id) — not content a worktree carries,
  ## but part of the tree id (threat model G32: a repository with
  ## submodules never verified while they were left out).
  let res = runGit(gitExe, ["--git-dir=" & gitDirOf(repoCache), "ls-tree",
    "-r", "-z", "--full-tree", commit])
  if res.code != 0:
    return (false, @[], @[], "git ls-tree failed: " & res.output.strip())
  for rec in res.output.split('\0'):
    if rec.len == 0: continue
    let tab = rec.find('\t')
    if tab < 0: continue
    let meta = rec[0 ..< tab].splitWhitespace()
    if meta.len >= 2 and meta[1] == "blob":
      result.paths.add(rec[tab + 1 .. ^1])
    elif meta.len >= 3 and meta[1] == "commit" and meta[0] == "160000":
      result.gitlinks.add((rec[tab + 1 .. ^1], meta[2]))
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

proc materializeRepoSnapshot*(repoCache: string; snap: RepoSnapshot;
                              dest: string; readBlob: BlobReader;
                              gitExe = "git"): MaterializeResult =
  ## See the module doc. `snap` must already have passed
  ## `validateManifest`. `dest` must not exist.
  result.worktree = dest
  if dirExists(dest) or fileExists(dest):
    return MaterializeResult(reason: "materialization target exists: " & dest)
  let gitDir = gitDirOf(repoCache)
  let base = trackedPathsAt(repoCache, snap.baseCommitSha, gitExe)
  if not base.ok:
    return MaterializeResult(reason: "base commit " & snap.baseCommitSha &
      " is not available in the repository cache: " & base.reason)
  createDir(dest)
  let index = dest.parentDir / ("." & dest.extractFilename & ".index")
  defer:
    try: removeFile(index) except OSError: discard
  let env = [("GIT_INDEX_FILE", index)]
  var res = runGit(gitExe, ["--git-dir=" & gitDir, "read-tree",
    snap.baseCommitSha], env)
  if res.code != 0:
    return MaterializeResult(reason: "git read-tree failed: " & res.output)
  res = runGit(gitExe, ["--git-dir=" & gitDir, "--work-tree=" & dest,
    "checkout-index", "-a", "-f"], env)
  if res.code != 0:
    return MaterializeResult(reason: "git checkout-index failed: " &
      res.output)
  var tracked = initHashSet[string]()
  for p in base.paths: tracked.incl(p)
  var gitlinks = initTable[string, string]()
  for (p, commit) in base.gitlinks: gitlinks[p] = commit
  for rel in snap.deleted:
    if gitlinks.hasKey(rel):
      gitlinks.del(rel)
      continue
    let bad = safeParentChain(dest, rel)
    if bad.len > 0:
      return MaterializeResult(reason: "refusing to delete through a " &
        "non-directory component: " & bad)
    if fileExists(dest / rel) or symlinkExists(dest / rel):
      removeFile(dest / rel)
    tracked.excl(rel)
  for m in snap.modified:
    if m.mode == ModeGitlink:
      # A submodule moved to another commit: metadata only, no blob.
      gitlinks[m.relPath] = m.gitOid
      tracked.excl(m.relPath)
      continue
    let blob = readBlob(m.blake3Digest)
    if blob.isNone:
      return MaterializeResult(reason: "blob " & digestHex(m.blake3Digest) &
        " for " & m.relPath & " is unavailable")
    let bytes = blob.get()
    if blake3.digest(bytes) != m.blake3Digest:
      return MaterializeResult(reason: "blob for " & m.relPath &
        " does not hash to its BLAKE3 digest")
    if uint64(bytes.len) != m.size:
      return MaterializeResult(reason: "blob for " & m.relPath &
        " has the wrong size")
    if gitBlobOid(bytes) != m.gitOid:
      return MaterializeResult(reason: "blob for " & m.relPath &
        " does not hash to its git blob id")
    let bad = safeParentChain(dest, m.relPath)
    if bad.len > 0:
      return MaterializeResult(reason: "refusing to write through a " &
        "non-directory component: " & bad)
    ensureParents(dest, m.relPath)
    let target = dest / m.relPath
    if fileExists(target) or symlinkExists(target):
      removeFile(target)
    var text = newString(bytes.len)
    if bytes.len > 0: copyMem(addr text[0], unsafeAddr bytes[0], bytes.len)
    if m.mode == ModeSymlink:
      createSymlink(text, target)
    else:
      writeFile(target, text)
      var perms = {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead}
      if m.mode == ModeExecutable:
        perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
      setFilePermissions(target, perms)
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
