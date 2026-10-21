## `WorkspaceSnapshotManifest` — the source state a remote goal runs against
## (Distributed-Execution M1 shape, receiver half implemented in M7).
##
## A manifest names a repository state by CONTENT: the base commit the worker
## already has (or will fetch), the paths that differ from it (each with the
## BLAKE3 digest its bytes are fetched by and the git blob id they hash to),
## the paths deleted from it, and the `git-tree-sha1` the result must have
## (Test-Certificates TC-8). The worker verifies that tree id after
## materializing and again before it signs a certificate.
##
## Everything here is decoded from bytes a REMOTE caller sent, so decoding is
## strict and bounded, and `validateManifest` refuses every shape that could
## steer a write outside the materialized tree: absolute paths, `..`, empty
## or `.` components, any `.git` component, backslashes, NUL, duplicate or
## unsorted entries, unknown modes, malformed hex. Validation happens before
## a single byte is written.

import std/[algorithm, sets, strutils]

import blake3
from repro_core/codec import elementCountFits

const
  ManifestSchema* = "repro.workspace-snapshot.v1"
  ManifestMagic = "RWSM"
  ManifestVersion = 1'u16
  MaxPathBytes* = 4_096
  MaxModifiedEntries* = 200_000
  MaxDeletedEntries* = 200_000
  MaxSiblings* = 64
  MaxBlobBytes* = 512'u64 * 1024'u64 * 1024'u64
  MaxRepoIdBytes* = 512
  ModeRegular* = 0o100644'u32
  ModeExecutable* = 0o100755'u32
  ModeSymlink* = 0o120000'u32
  ModeGitlink* = 0o160000'u32
    ## A submodule: the entry is the submodule's COMMIT id (`gitOid`), with
    ## no blob to fetch (`size` 0, `blake3Digest` all zero). Repositories
    ## with submodules carry these in their tree, so their tree id cannot
    ## verify without them (threat model G32).
  AllowedModes* = [ModeRegular, ModeExecutable, ModeSymlink, ModeGitlink]

export Blake3Digest

type
  ModifiedFileEntry* = object
    relPath*: string
    mode*: uint32
    gitOid*: string
      ## 40-hex SHA-1 git blob id of the content.
    blake3Digest*: Blake3Digest
      ## What the bytes are fetched by over the content plane.
    size*: uint64

  RepoSnapshot* = object
    repoId*: string
      ## A name the worker maps to a local repository cache.
    baseCommitSha*: string
      ## 40-hex commit the snapshot is relative to.
    gitTreeSha1*: string
      ## 40-hex tree id the materialized state must hash to.
    modified*: seq[ModifiedFileEntry]
      ## Sorted by `relPath`, unique.
    deleted*: seq[string]
      ## Sorted, unique, disjoint from `modified`.

  WorkspaceSnapshotManifest* = object
    schema*: string
    primaryRepo*: RepoSnapshot
    developSiblings*: seq[RepoSnapshot]
      ## Active `repro develop` overrides (M1). Empty in M7.

  ManifestError* = object of CatchableError

proc digestHex*(d: Blake3Digest): string =
  const H = "0123456789abcdef"
  result = newString(64)
  for i, b in d:
    result[2 * i] = H[int(b) shr 4]
    result[2 * i + 1] = H[int(b) and 0xf]

proc isHex(s: string; n: int): bool =
  if s.len != n: return false
  for ch in s:
    if ch notin {'0' .. '9', 'a' .. 'f'}: return false
  true

proc validateRelPath*(p: string): string =
  ## "" when `p` is a safe worktree-relative path, else the reason.
  if p.len == 0: return "empty path"
  if p.len > MaxPathBytes: return "path too long"
  if p[0] == '/': return "absolute path: " & p
  if '\\' in p or '\0' in p: return "path contains a backslash or NUL"
  for comp in p.split('/'):
    if comp.len == 0: return "empty path component in " & p
    if comp == "." or comp == "..": return "relative component in " & p
    if comp == ".git": return ".git component in " & p
  ""

proc validateRepo(r: RepoSnapshot; what: string): string =
  if r.repoId.len == 0 or r.repoId.len > MaxRepoIdBytes:
    return what & ": repoId missing or too long"
  if not isHex(r.baseCommitSha, 40):
    return what & ": baseCommitSha is not 40 lowercase hex"
  if not isHex(r.gitTreeSha1, 40):
    return what & ": gitTreeSha1 is not 40 lowercase hex"
  if r.modified.len > MaxModifiedEntries or r.deleted.len > MaxDeletedEntries:
    return what & ": too many entries"
  var seen = initHashSet[string]()
  var prev = ""
  for i, m in r.modified:
    let bad = validateRelPath(m.relPath)
    if bad.len > 0: return what & ": " & bad
    if i > 0 and m.relPath <= prev:
      return what & ": modified entries are not sorted and unique"
    prev = m.relPath
    if m.mode notin AllowedModes:
      return what & ": unsupported mode " & toOct(int(m.mode), 6) & " for " &
        m.relPath
    if not isHex(m.gitOid, 40):
      return what & ": malformed git blob id for " & m.relPath
    if m.mode == ModeGitlink:
      var zero: Blake3Digest
      if m.size != 0 or m.blake3Digest != zero:
        return what & ": a submodule entry carries no blob (" & m.relPath & ")"
    if m.size > MaxBlobBytes:
      return what & ": " & m.relPath & " is too large"
    seen.incl(m.relPath)
  prev = ""
  for i, d in r.deleted:
    let bad = validateRelPath(d)
    if bad.len > 0: return what & ": " & bad
    if i > 0 and d <= prev:
      return what & ": deleted entries are not sorted and unique"
    prev = d
    if d in seen:
      return what & ": " & d & " is both modified and deleted"
  ""

proc validateManifest*(m: WorkspaceSnapshotManifest): string =
  ## "" when the manifest is safe to act on, else the first reason.
  if m.schema != ManifestSchema:
    return "unsupported manifest schema: " & m.schema
  if m.developSiblings.len > MaxSiblings:
    return "too many develop siblings"
  result = validateRepo(m.primaryRepo, "primary repository")
  if result.len > 0: return
  for i, s in m.developSiblings:
    result = validateRepo(s, "develop sibling " & $i)
    if result.len > 0: return

proc sortedEntries*(r: var RepoSnapshot) =
  ## Puts a manifest the CALLER is building into canonical order.
  r.modified.sort(proc(a, b: ModifiedFileEntry): int = cmp(a.relPath, b.relPath))
  r.deleted.sort(system.cmp[string])

# ---------------------------------------------------------------------------
# Canonical encoding.
# ---------------------------------------------------------------------------

proc putU16(d: var seq[byte]; v: uint16) =
  d.add(byte(v and 0xff)); d.add(byte(v shr 8))
proc putU32(d: var seq[byte]; v: uint32) =
  for s in countup(0, 24, 8): d.add(byte((v shr uint32(s)) and 0xff))
proc putU64(d: var seq[byte]; v: uint64) =
  for s in countup(0, 56, 8): d.add(byte((v shr uint64(s)) and 0xff))
proc putStr(d: var seq[byte]; s: string) =
  d.putU32(uint32(s.len))
  for ch in s: d.add(byte(ord(ch)))

proc need(data: openArray[byte]; pos, n: int) =
  if n < 0 or pos + n > data.len:
    raise newException(ManifestError, "truncated snapshot manifest")
proc getU16(data: openArray[byte]; pos: var int): uint16 =
  need(data, pos, 2)
  result = uint16(data[pos]) or (uint16(data[pos + 1]) shl 8)
  pos += 2
proc getU32(data: openArray[byte]; pos: var int): uint32 =
  need(data, pos, 4)
  for i in 0 ..< 4: result = result or (uint32(data[pos + i]) shl uint32(8 * i))
  pos += 4
proc getU64(data: openArray[byte]; pos: var int): uint64 =
  need(data, pos, 8)
  for i in 0 ..< 8: result = result or (uint64(data[pos + i]) shl uint64(8 * i))
  pos += 8
proc getStr(data: openArray[byte]; pos: var int; maxLen: int): string =
  let n = int(getU32(data, pos))
  if n > maxLen:
    raise newException(ManifestError, "snapshot manifest string too long")
  need(data, pos, n)
  result = newString(n)
  for i in 0 ..< n: result[i] = char(data[pos + i])
  pos += n

proc getCount(data: openArray[byte]; pos: var int; minimumBytes: int): int =
  ## An element count, bounded BEFORE anything is sized or looped over by
  ## it: each element takes at least `minimumBytes` (repro_core/codec).
  let raw = getU32(data, pos)
  if not elementCountFits(raw, data.len - pos, minimumBytes):
    raise newException(ManifestError, "snapshot manifest element count exceeds remaining bytes")
  int(raw)

proc encodeRepo(d: var seq[byte]; r: RepoSnapshot) =
  d.putStr(r.repoId)
  d.putStr(r.baseCommitSha)
  d.putStr(r.gitTreeSha1)
  d.putU32(uint32(r.modified.len))
  for m in r.modified:
    d.putStr(m.relPath)
    d.putU32(m.mode)
    d.putStr(m.gitOid)
    for b in m.blake3Digest: d.add(b)
    d.putU64(m.size)
  d.putU32(uint32(r.deleted.len))
  for p in r.deleted: d.putStr(p)

proc decodeRepo(data: openArray[byte]; pos: var int): RepoSnapshot =
  result.repoId = getStr(data, pos, MaxRepoIdBytes)
  result.baseCommitSha = getStr(data, pos, 40)
  result.gitTreeSha1 = getStr(data, pos, 40)
  # A modified entry: path, mode, git oid, 32-byte BLAKE3, u64 size.
  let nm = getCount(data, pos, 52)
  if nm > MaxModifiedEntries:
    raise newException(ManifestError, "too many modified entries")
  for _ in 0 ..< nm:
    var m: ModifiedFileEntry
    m.relPath = getStr(data, pos, MaxPathBytes)
    m.mode = getU32(data, pos)
    m.gitOid = getStr(data, pos, 40)
    need(data, pos, 32)
    for i in 0 ..< 32: m.blake3Digest[i] = data[pos + i]
    pos += 32
    m.size = getU64(data, pos)
    result.modified.add(m)
  let nd = getCount(data, pos, 4)
  if nd > MaxDeletedEntries:
    raise newException(ManifestError, "too many deleted entries")
  for _ in 0 ..< nd:
    result.deleted.add(getStr(data, pos, MaxPathBytes))

proc encodeManifest*(m: WorkspaceSnapshotManifest): seq[byte] =
  for ch in ManifestMagic: result.add(byte(ord(ch)))
  result.putU16(ManifestVersion)
  result.putStr(m.schema)
  result.encodeRepo(m.primaryRepo)
  result.putU32(uint32(m.developSiblings.len))
  for s in m.developSiblings: result.encodeRepo(s)

proc decodeManifest*(data: openArray[byte]): WorkspaceSnapshotManifest =
  ## Strict, bounded decode. Call `validateManifest` before acting on it.
  need(data, 0, ManifestMagic.len)
  for i, ch in ManifestMagic:
    if data[i] != byte(ord(ch)):
      raise newException(ManifestError, "not a snapshot manifest")
  var pos = ManifestMagic.len
  if getU16(data, pos) != ManifestVersion:
    raise newException(ManifestError, "unsupported snapshot manifest version")
  result.schema = getStr(data, pos, 64)
  result.primaryRepo = decodeRepo(data, pos)
  # A repo: three strings and two counts, a u32 each.
  let ns = getCount(data, pos, 20)
  if ns > MaxSiblings:
    raise newException(ManifestError, "too many develop siblings")
  for _ in 0 ..< ns:
    result.developSiblings.add(decodeRepo(data, pos))
  if pos != data.len:
    raise newException(ManifestError, "trailing bytes after snapshot manifest")

proc manifestDigest*(m: WorkspaceSnapshotManifest): Blake3Digest =
  ## The manifest's content address (BLAKE3-256 of its canonical encoding):
  ## what a `ReachGoalRequest` names and the content plane fetches.
  blake3.digest(encodeManifest(m))

proc contentIdOf*(m: WorkspaceSnapshotManifest): string =
  ## The TC-8 content id the snapshot denotes.
  "git-tree-sha1:" & m.primaryRepo.gitTreeSha1
