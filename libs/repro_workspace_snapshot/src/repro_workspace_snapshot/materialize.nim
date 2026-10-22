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

proc gitEnv(extraEnv: openArray[(string, string)]): StringTableRef =
  ## The environment of every git this module runs: a fresh table, so no
  ## ambient `GIT_*` variable (`GIT_DIR`, `GIT_OBJECT_DIRECTORY`,
  ## `GIT_REPLACE_REF_BASE`, …) reaches it.
  result = newStringTable(modeCaseSensitive)
  for key in ["PATH", "HOME", "TMPDIR", "SYSTEMROOT"]:
    if existsEnv(key): result[key] = getEnv(key)
  result["GIT_CONFIG_NOSYSTEM"] = "1"
  result["GIT_TERMINAL_PROMPT"] = "0"
  # Read the objects the ids NAME, never a `refs/replace/*` substitute: a
  # replace ref in the cache would otherwise make `ls-tree` list another
  # tree for the base commit and `cat-file` return another blob's bytes
  # (https://git-scm.com/docs/git-replace). Grafts change only a commit's
  # parents, which nothing here reads.
  result["GIT_NO_REPLACE_OBJECTS"] = "1"
  for (k, v) in extraEnv: result[k] = v

proc runGit(gitExe: string; args: openArray[string];
            extraEnv: openArray[(string, string)] = []): tuple[code: int;
                                                            output: string] =
  # The worker's OWN repository cache, read with the git the caller names
  # (`gitExe`; production passes the daemon's resolved git). Nothing here
  # runs a binary a caller supplied over the wire.
  let p = uncontrolledStartProcess(gitExe, args = @args, env = gitEnv(extraEnv),
    options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  (p.waitForExit(), output)

proc gitDirOf(repoCache: string): string =
  if dirExists(repoCache / ".git"): repoCache / ".git" else: repoCache

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
  ## conversion may run. The one definition of a base checkout: materializing
  ## a snapshot uses it, and so must anything that resets a worktree to a
  ## base commit. Gitlinks are reported, not written. A filesystem error
  ## while writing (a blob path where `dest` already holds a directory, …)
  ## raises, as it does from `materializeRepoSnapshot`.
  ##
  ## Blobs are read through ONE `git cat-file --batch` (never `--filters` or
  ## `--textconv`, which would apply the very conversions this avoids), one
  ## request at a time: write an id, read its response, so neither pipe can
  ## fill while the other side waits. `--batch` flushes after every object
  ## unless `--buffer` is given (https://git-scm.com/docs/git-cat-file). Each
  ## blob must hash to the id the tree names before it is written.
  let entries = treeEntriesAt(repoCache, commit, gitExe)
  if not entries.ok:
    return BaseCheckout(reason: "base commit " & commit &
      " is not available in the repository cache: " & entries.reason)
  createDir(dest)
  if entries.blobs.len > 0:
    let p = uncontrolledStartProcess(gitExe,
      args = ["--git-dir=" & gitDirOf(repoCache), "cat-file", "--batch"],
      env = gitEnv([]), options = {poUsePath})
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

proc materializeRepoSnapshot*(repoCache: string; snap: RepoSnapshot;
                              dest: string; readBlob: BlobReader;
                              gitExe = "git"): MaterializeResult =
  ## See the module doc. `snap` must already have passed
  ## `validateManifest`. `dest` must not exist.
  result.worktree = dest
  if dirExists(dest) or fileExists(dest):
    return MaterializeResult(reason: "materialization target exists: " & dest)
  let base = checkoutBaseTree(repoCache, snap.baseCommitSha, dest, gitExe)
  if not base.ok:
    return MaterializeResult(reason: base.reason)
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
    var text = newString(bytes.len)
    if bytes.len > 0: copyMem(addr text[0], unsafeAddr bytes[0], bytes.len)
    let refused = writeTracked(dest, m.relPath, m.mode, text)
    if refused.len > 0:
      return MaterializeResult(reason: refused)
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
