## Capturing a working tree as a `WorkspaceSnapshotManifest` —
## Distributed-Execution M1 (the requester side).
##
## `captureRepoSnapshot` names the CURRENT state of one git working tree by
## content, relative to its `HEAD` commit:
##
##   1. the user's index is COPIED into a private temporary directory (its
##      modification time kept, so git's racy-entry rule judges the copy
##      exactly as it judges the original) and every later step runs against
##      the copy through `GIT_INDEX_FILE` — the real `.git/index` is read
##      once and never written (Test-Certificates TC-8, Content-Id §4.1);
##   2. in the copy, `git add -A` takes every tracked file's working-tree
##      content (staged and unstaged edits alike), drops deleted files and
##      adds the untracked files git does not ignore (`.gitignore`,
##      `.git/info/exclude`, `core.excludesFile` — the "allowed" untracked
##      files), and `git write-tree` gives the snapshot's `gitTreeSha1`;
##   3. `git diff-index --cached HEAD` against the copy lists what differs
##      from `HEAD`: each added, modified or type-changed path becomes a
##      `ModifiedFileEntry` (mode, git blob id, BLAKE3 digest, size), each
##      removed path a deletion; a submodule entry carries its commit id and
##      no blob;
##   4. the bytes of every modified file go to the caller's `BlobSink` (the
##      requester's snapshot store, `repro_peer_cache/snapshot_blobs`) under
##      their BLAKE3-256 digest — each read from the working tree and
##      accepted only when it hashes to the blob id git recorded, else read
##      from the object store (`git cat-file blob`), so the bytes always ARE
##      the blob the tree names.
##
## The tree id is the TC-8 algorithm (`git-tree-sha1`) over the state that is
## shipped: tracked files AND the allowed untracked files. That differs from
## a local certificate's working-tree content id when untracked files exist —
## those are outside a local certificate's `content` and inside a snapshot,
## because the worker builds with them. A certificate issued for such a
## snapshot therefore verifies only against a commit that includes them
## (Test-Certificates Standard §3.2: `content` must bind what the run read).
##
## States with no honest content id (Content-Id §3) are refused, as TC-8
## refuses them: unmerged entries, `assume-unchanged` entries, and
## `skip-worktree` entries whose file is present. A path the manifest cannot
## carry (a backslash, a NUL, more than `MaxPathBytes`) and a file over
## `MaxBlobBytes` are refused rather than silently left out.
##
## An UNTRACKED nested git repository (a directory with its own `.git` that
## the index does not already hold as a submodule) is refused: `git add -A`
## would record it as a gitlink — a commit id with no content the worker can
## materialize — and the build would silently run without its files.
##
## BASE PACK (review fix, 2026-10-22). The base commit is often the
## requester's unpushed `HEAD`, which no remote a worker can fetch from
## holds. Unless `shipBasePack` is off, capture packs the objects reachable
## from the base commit and NOT from any remote-tracking ref
## (`refs/remotes/*`) — `git pack-objects --revs`, a self-contained pack —
## and hands it to the sink like a blob; the manifest names it
## (`basePack`, `basePackSize`). When every commit is reachable from a
## remote-tracking ref there is no pack. A pack over `maxBasePackBytes`
## (default `MaxBasePackBytes`) is refused with the reason (push the
## history, or capture with `shipBasePack = false` for a worker whose
## configured remote has it).
##
## `captureWorkspaceSnapshot` adds the active `repro develop` siblings: every
## entry of `<workspaceRoot>/.repro/develop-overrides.toml` (each shadows its
## package's binding in the build graph, whatever its `state`) is captured the
## same way into `developSiblings`, keyed by its package id.
##
## What capture writes: blob and tree objects in each repository's object
## store (as `git add` and `git write-tree` always do), the private temporary
## directory (removed on every path out), and whatever the `BlobSink` stores.
## No ref, no index, no working-tree file.

import std/[algorithm, options, os, sets, strutils, tempfiles]

import blake3

import repro_workspace_manifests/develop_overrides
from repro_workspace_manifests/types import DevelopOverrides, DevelopOverrideEntry

import ./git_process
import ./git_tree
import ./manifest

type
  BlobSink* = proc(digest: Blake3Digest; bytes: seq[byte]) {.gcsafe, closure.}
    ## Stores one blob of the snapshot under its BLAKE3-256 digest. Called
    ## once per distinct digest.

  RepoCaptureResult* = object
    ok*: bool
    reason*: string
    snapshot*: RepoSnapshot
    toplevel*: string
    exportedBlobs*: int
    exportedBytes*: uint64
      ## Modified files' blobs (the base pack is counted apart).
    basePacks*: int

  CaptureResult* = object
    ok*: bool
    reason*: string
    manifest*: WorkspaceSnapshotManifest
    exportedBlobs*: int
      ## Distinct blobs handed to the sink, over every repository (modified
      ## files; base packs are counted in `basePacks`).
    exportedBytes*: uint64
    basePacks*: int
      ## Base packs handed to the sink (one per repository with unpushed
      ## history).

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc modeOf(text: string): tuple[ok: bool; mode: uint32] =
  case text
  of "100644": (true, ModeRegular)
  of "100755": (true, ModeExecutable)
  of "120000": (true, ModeSymlink)
  of "160000": (true, ModeGitlink)
  else: (false, 0'u32)

proc probeNoContentIdStates(gitExe, top: string;
                            env: openArray[(string, string)];
                            gitlinks: var HashSet[string]): string =
  ## Content-Id §3 states among the entries of the copied index: "" when
  ## there are none, else the refusal naming them. Collects the index's
  ## submodule (gitlink) paths into `gitlinks`.
  let listing = runGit(gitExe, ["-c", "core.fsmonitor=false", "ls-files",
    "-z", "-s", "-v"], env, cwd = top, mergeStderr = false)
  if listing.code != 0:
    return "git ls-files failed: " & describe(listing)
  var unmerged, assumeUnchanged, skipPresent: seq[string]
  for rec in nulRecords(listing.output):
    # `<tag> SP <mode> SP <object> SP <stage> TAB <path>` (git-ls-files(1)).
    let tab = rec.find('\t')
    let fields = (if tab < 0: @[] else: rec[0 ..< tab].split(' '))
    if fields.len != 4 or fields[0].len != 1:
      return "`git ls-files -s -v` printed a record this capture cannot " &
        "read: " & rec.escape()
    let path = rec[tab + 1 .. ^1]
    if fields[1] == "160000":
      gitlinks.incl(path)
    if fields[3] != "0":
      unmerged.add(path)
    elif fields[0][0] in {'a' .. 'z'}:
      assumeUnchanged.add(path)
    elif fields[0][0] == 'S':
      let p = top / path
      if fileExists(p) or dirExists(p) or symlinkExists(p):
        skipPresent.add(path)
  if unmerged.len > 0:
    return "the index has unmerged entries (resolve and stage them): " &
      unmerged.join(", ")
  if assumeUnchanged.len > 0:
    return "entries are marked assume-unchanged (git update-index " &
      "--no-assume-unchanged): " & assumeUnchanged.join(", ")
  if skipPresent.len > 0:
    return "entries are marked skip-worktree while their file is present " &
      "(git update-index --no-skip-worktree): " & skipPresent.join(", ")
  ""

proc fileBytes(path: string): tuple[ok: bool; bytes: seq[byte]] =
  ## What git would hash for `path`: a symlink's target, a file's content.
  try:
    if symlinkExists(path):
      (true, toBytes(expandSymlink(path)))
    elif fileExists(path):
      (true, toBytes(readFile(path)))
    else:
      (false, @[])
  except OSError, IOError:
    (false, @[])

proc basePackOf(gitExe, top, base: string; maxBytes: uint64):
    tuple[ok: bool; none: bool; bytes: seq[byte]; reason: string] =
  ## The base pack of `base` (see the module doc): `none` when every
  ## commit is reachable from a remote-tracking ref.
  let tips = runGit(gitExe, ["for-each-ref", "--format=%(objectname)",
    "refs/remotes/"], cwd = top, mergeStderr = false)
  if tips.code != 0:
    return (false, false, @[], "git for-each-ref failed: " & describe(tips))
  var revs = base & "\n"
  for line in tips.output.splitLines:
    let t = line.strip()
    if t.len == 40: revs.add("^" & t & "\n")
  let unpushed = runGit(gitExe, ["rev-list", "--count", "--stdin"],
    input = revs, cwd = top, mergeStderr = false)
  if unpushed.code != 0:
    return (false, false, @[], "git rev-list failed: " & describe(unpushed))
  if unpushed.output.strip() == "0":
    return (true, true, @[], "")
  # Read at most `maxBytes + 1` bytes of the pack: an oversized one is
  # refused without being buffered whole.
  let bounded = runGitBounded(gitExe, ["pack-objects", "--stdout", "--revs",
    "-q", "--delta-base-offset"], int(min(maxBytes, uint64(high(int) - 1))),
    input = revs, cwd = top)
  if bounded.truncated:
    return (false, false, @[], "the base commit's unpushed history packs to " &
      "more than a snapshot may carry (" & $maxBytes & " bytes); push it, " &
      "or capture without a base pack for a worker whose configured remote " &
      "has it")
  let pack = bounded.run
  if pack.code != 0:
    return (false, false, @[], "git pack-objects failed: " & describe(pack))
  (true, false, toBytes(pack.output), "")

proc captureRepoSnapshot*(repoDir, repoId: string; sink: BlobSink;
                          gitExe = "git";
                          exported: ref HashSet[Blake3Digest] = nil;
                          shipBasePack = true;
                          maxBasePackBytes = MaxBasePackBytes):
    RepoCaptureResult =
  ## See the module doc. `exported` (shared across repositories) dedups the
  ## sink: a digest already in it is not handed over again.
  let seen = if exported.isNil: (ref HashSet[Blake3Digest])() else: exported
  let rp = runGit(gitExe, ["rev-parse", "--path-format=absolute",
    "--show-toplevel", "--show-object-format", "--git-path", "index"],
    cwd = repoDir, mergeStderr = false)
  if rp.code != 0:
    return RepoCaptureResult(reason: "`" & repoDir & "` is not inside a git " &
      "working tree: " & describe(rp))
  let lines = rp.output.strip().splitLines()
  if lines.len != 3:
    return RepoCaptureResult(reason: "unexpected `git rev-parse` output: " &
      rp.output.escape())
  let top = lines[0]
  if lines[1] != "sha1":
    return RepoCaptureResult(reason: "`" & top & "` uses object format " &
      lines[1] & "; a snapshot manifest carries git-tree-sha1 ids only")
  let userIndex = lines[2]
  let head = runGit(gitExe, ["rev-parse", "--verify", "-q", "HEAD^{commit}"],
    cwd = top, mergeStderr = false)
  if head.code != 0:
    return RepoCaptureResult(reason: "`" & top & "` has no HEAD commit to " &
      "snapshot against")
  let base = head.output.strip()
  let scratch = createTempDir("repro-snapshot-", "")
  defer:
    try: removeDir(scratch) except OSError: discard
  let index = scratch / "index"
  let env = [("GIT_INDEX_FILE", index)]
  if fileExists(userIndex):
    try:
      copyFile(userIndex, index)
      setLastModificationTime(index, getLastModificationTime(userIndex))
    except OSError, IOError:
      return RepoCaptureResult(reason: "could not copy the index `" &
        userIndex & "`: " & getCurrentExceptionMsg())
  else:
    let empty = runGit(gitExe, ["read-tree", "--empty"], env, cwd = top)
    if empty.code != 0:
      return RepoCaptureResult(reason: "git read-tree --empty failed: " &
        describe(empty))
  var indexGitlinks = initHashSet[string]()
  let refused = probeNoContentIdStates(gitExe, top, env, indexGitlinks)
  if refused.len > 0:
    return RepoCaptureResult(reason: "`" & top & "`: " & refused)
  let added = runGit(gitExe, ["-c", "core.fsmonitor=false", "-c",
    "core.safecrlf=false", "add", "-A"], env, cwd = top)
  if added.code != 0:
    return RepoCaptureResult(reason: "git add -A (temporary index) failed: " &
      describe(added))
  let tree = runGit(gitExe, ["write-tree"], env, cwd = top,
    mergeStderr = false)
  if tree.code != 0:
    return RepoCaptureResult(reason: "git write-tree failed: " &
      describe(tree))
  var snap = RepoSnapshot(repoId: repoId, baseCommitSha: base,
    gitTreeSha1: tree.output.strip())
  let diff = runGit(gitExe, ["diff-index", "--cached", "-z", "--raw",
    "--no-renames", "--no-abbrev", "--ignore-submodules=none", base], env,
    cwd = top, mergeStderr = false)
  if diff.code != 0:
    return RepoCaptureResult(reason: "git diff-index failed: " &
      describe(diff))
  # Raw records: `:<old mode> <new mode> <old oid> <new oid> <status>`, NUL,
  # the path, NUL (git-diff(1), "Raw output format", with -z).
  let recs = diff.output.split('\0')
  var i = 0
  var exportedBlobs = 0
  var exportedBytes = 0'u64
  while i + 1 < recs.len:
    let meta = recs[i]
    let path = recs[i + 1]
    i += 2
    if meta.len == 0:
      continue
    let fields = meta[1 .. ^1].split(' ')
    if meta[0] != ':' or fields.len != 5:
      return RepoCaptureResult(reason: "`git diff-index` printed a record " &
        "this capture cannot read: " & meta.escape())
    let bad = validateRelPath(path)
    if bad.len > 0:
      return RepoCaptureResult(reason: "`" & top & "`: a snapshot cannot " &
        "carry this path (" & bad & ")")
    let status = fields[4][0]
    if status == 'D':
      snap.deleted.add(path)
      continue
    if status notin {'A', 'M', 'T'}:
      return RepoCaptureResult(reason: "`git diff-index` reported status " &
        fields[4] & " for " & path)
    let (known, mode) = modeOf(fields[1])
    if not known:
      return RepoCaptureResult(reason: "unsupported mode " & fields[1] &
        " for " & path)
    let oid = fields[3]
    if mode == ModeGitlink:
      if status == 'A' and path notin indexGitlinks:
        return RepoCaptureResult(reason: "`" & top & "`: " & path & " is an " &
          "untracked nested git repository; a snapshot would carry it as a " &
          "bare commit id with none of its files (add it as a submodule, " &
          "ignore it, or move it out of the working tree)")
      snap.modified.add(ModifiedFileEntry(relPath: path, mode: mode,
        gitOid: oid))
      continue
    var got = fileBytes(top / path)
    if not got.ok or gitBlobOid(got.bytes) != oid:
      # Changed since `git add`, or converted by a clean filter: the bytes
      # the tree names come from the object store.
      let cat = runGit(gitExe, ["cat-file", "blob", oid], cwd = top,
        mergeStderr = false)
      if cat.code != 0:
        return RepoCaptureResult(reason: "git cat-file blob " & oid &
          " failed: " & describe(cat))
      got = (true, toBytes(cat.output))
      if gitBlobOid(got.bytes) != oid:
        return RepoCaptureResult(reason: "the object store returned other " &
          "bytes for blob " & oid & " (" & path & ")")
    if uint64(got.bytes.len) > MaxBlobBytes:
      return RepoCaptureResult(reason: path & " is larger than a snapshot " &
        "blob may be (" & $MaxBlobBytes & " bytes)")
    let digest = blake3.digest(got.bytes)
    if digest notin seen[]:
      seen[].incl(digest)
      sink(digest, got.bytes)
      inc exportedBlobs
      exportedBytes += uint64(got.bytes.len)
    snap.modified.add(ModifiedFileEntry(relPath: path, mode: mode,
      gitOid: oid, blake3Digest: digest, size: uint64(got.bytes.len)))
  var basePacks = 0
  if shipBasePack:
    let pack = basePackOf(gitExe, top, base, maxBasePackBytes)
    if not pack.ok:
      return RepoCaptureResult(reason: "`" & top & "`: " & pack.reason)
    if not pack.none:
      let digest = blake3.digest(pack.bytes)
      if digest notin seen[]:
        seen[].incl(digest)
        sink(digest, pack.bytes)
      snap.basePack = digest
      snap.basePackSize = uint64(pack.bytes.len)
      basePacks = 1
  snap.sortedEntries()
  let invalid = validateManifest(WorkspaceSnapshotManifest(
    schema: ManifestSchema, primaryRepo: snap))
  if invalid.len > 0:
    return RepoCaptureResult(reason: "`" & top & "`: " & invalid)
  RepoCaptureResult(ok: true, snapshot: snap, toplevel: top,
    exportedBlobs: exportedBlobs, exportedBytes: exportedBytes,
    basePacks: basePacks)

proc captureWorkspaceSnapshot*(primaryRepo, primaryRepoId: string;
                               sink: BlobSink; workspaceRoot = "";
                               gitExe = "git"; shipBasePack = true;
                               maxBasePackBytes = MaxBasePackBytes):
                               CaptureResult =
  ## The primary repository and every active `repro develop` sibling of
  ## `workspaceRoot` (default: the primary repository's top level), captured
  ## as one manifest. See the module doc.
  let exported = (ref HashSet[Blake3Digest])()
  let primary = captureRepoSnapshot(primaryRepo, primaryRepoId, sink, gitExe,
    exported, shipBasePack, maxBasePackBytes)
  if not primary.ok:
    return CaptureResult(reason: primary.reason)
  result.manifest = WorkspaceSnapshotManifest(schema: ManifestSchema,
    primaryRepo: primary.snapshot)
  result.exportedBlobs = primary.exportedBlobs
  result.exportedBytes = primary.exportedBytes
  result.basePacks = primary.basePacks
  let root = if workspaceRoot.len > 0: workspaceRoot else: primary.toplevel
  var overrides: Option[DevelopOverrides]
  try:
    overrides = readDevelopOverridesFile(root)
  except CatchableError as err:
    return CaptureResult(reason: "cannot read the develop overrides of `" &
      root & "`: " & err.msg)
  if overrides.isSome:
    var entries = listOverrides(overrides.get())
    entries.sort(proc(a, b: DevelopOverrideEntry): int =
      cmp(a.package, b.package))
    for entry in entries:
      let dir = normalizedPath(
        if isAbsolute(entry.local_path): entry.local_path
        else: root / entry.local_path)
      if not dirExists(dir):
        return CaptureResult(reason: "repro develop sibling " &
          entry.package & ": its checkout `" & dir & "` does not exist")
      let sibling = captureRepoSnapshot(dir, entry.package, sink, gitExe,
        exported, shipBasePack, maxBasePackBytes)
      if not sibling.ok:
        return CaptureResult(reason: "repro develop sibling " &
          entry.package & ": " & sibling.reason)
      if sibling.toplevel == primary.toplevel:
        continue
      result.manifest.developSiblings.add(sibling.snapshot)
      result.exportedBlobs += sibling.exportedBlobs
      result.exportedBytes += sibling.exportedBytes
      result.basePacks += sibling.basePacks
  let invalid = validateManifest(result.manifest)
  if invalid.len > 0:
    return CaptureResult(reason: invalid)
  result.ok = true
