## Store optimise — hardlink-dedup a realized tool store, the way
## `nix-store --optimise` deduplicates a Nix store.
##
## ## Why it exists
##
## The realize path already tries `cloneSiblingRealization`, which
## hardlink-clones a sibling prefix that carries the same content
## (`lockIdentity` + checksum). But it only fires when the sibling ALREADY
## exists, so N packages that share one tarball and realize concurrently
## (cargo / rustc / clippy / rustfmt all pointing at one Rust distribution)
## each race to a fresh unpack and land as N full copies — the ~5–8 GB of
## duplicated Rust the M8 dedup goal names. This closes that gap from the
## other side: a post-hoc pass that finds byte-identical files ANYWHERE under
## the store and collapses them onto one inode, whatever realize path
## produced them.
##
## ## Why it is safe
##
## A published prefix is immutable — nothing in the store reopens one for
## writing (see `PrefixMaterializeAllowSharedInodeDefault`'s rationale). So a
## shared inode between two identical files in two prefixes has no writer on
## either end, exactly as a materialisation-time hardlink does. Files are
## grouped by (size, SHA-256) so only genuinely identical content is ever
## linked, and the link is made through a temp name + atomic rename so an
## interrupted run never leaves a prefix with a missing file.

import std/[os, algorithm, tables]

import nimcrypto/[hash, sha2]

type
  DedupCandidate* = object
    ## One regular file considered for deduplication.
    path*: string
    size*: int64

  DedupLink* = object
    ## A decided link: `duplicate` is to be replaced by a hardlink to
    ## `canonical`, which holds identical bytes.
    canonical*: string
    duplicate*: string

proc sha256File(path: string): string =
  ## Streaming SHA-256 of a file's bytes, hex.
  var ctx: sha256
  ctx.init()
  var f: File
  if not open(f, path, fmRead):
    return ""
  defer: close(f)
  var buf: array[65536, byte]
  while true:
    let n = readBytes(f, buf, 0, buf.len)
    if n <= 0: break
    ctx.update(buf[0 ..< n])
  $ctx.finish()

proc planDedup*(candidates: openArray[DedupCandidate]): seq[DedupLink] =
  ## Decide which files to collapse. Pure over the (path, size) list plus a
  ## content hash: group by size first (cheap), hash only the sizes that
  ## collide, then within one (size, hash) group keep the
  ## lexicographically-first path as canonical and link the rest to it. The
  ## deterministic canonical choice makes the plan stable across runs, so
  ## re-optimising an already-optimised store is a no-op.
  var bySize = initTable[int64, seq[string]]()
  for c in candidates:
    if c.size <= 0:  # empty files: linking saves nothing, skip.
      continue
    bySize.mgetOrPut(c.size, @[]).add(c.path)
  for size, paths in bySize:
    if paths.len < 2:
      continue
    var byHash = initTable[string, seq[string]]()
    for p in paths:
      let h = sha256File(p)
      if h.len == 0:
        continue
      byHash.mgetOrPut(h, @[]).add(p)
    for h, group in byHash:
      if group.len < 2:
        continue
      var sorted = group
      sorted.sort()
      let canonical = sorted[0]
      for i in 1 ..< sorted.len:
        result.add(DedupLink(canonical: canonical, duplicate: sorted[i]))

proc alreadyLinked(a, b: string): bool =
  ## True when the two paths already resolve to the same inode — nothing to
  ## do. On a filesystem without inode identity this returns false and the
  ## link attempt simply re-links, which is harmless.
  try:
    let ia = getFileInfo(a, followSymlink = false)
    let ib = getFileInfo(b, followSymlink = false)
    ia.id == ib.id
  except CatchableError:
    false

proc applyDedup*(links: openArray[DedupLink]): tuple[linked: int; reclaimed: int64] =
  ## Replace each `duplicate` with a hardlink to `canonical`, via a temp name
  ## and atomic rename so an interrupted run never leaves a hole. Skips a pair
  ## already sharing an inode. Returns how many files were linked and the
  ## bytes reclaimed.
  for link in links:
    if alreadyLinked(link.canonical, link.duplicate):
      continue
    var sz: int64 = 0
    try: sz = getFileSize(link.duplicate)
    except CatchableError: continue
    let tmp = link.duplicate & ".repro-optimise-tmp"
    try:
      if fileExists(tmp): removeFile(tmp)
      createHardlink(link.canonical, tmp)
    except CatchableError:
      try:
        if fileExists(tmp): removeFile(tmp)
      except CatchableError: discard
      continue
    try:
      moveFile(tmp, link.duplicate)  # atomic replace
      result.linked.inc
      result.reclaimed += sz
    except CatchableError:
      try:
        if fileExists(tmp): removeFile(tmp)
      except CatchableError: discard

proc collectCandidates*(root: string): seq[DedupCandidate] =
  ## Every regular file under `root`, with its size. Symlinks are left alone.
  for path in walkDirRec(root, yieldFilter = {pcFile}, followFilter = {pcDir}):
    try:
      let info = getFileInfo(path, followSymlink = false)
      if info.kind == pcFile:
        result.add(DedupCandidate(path: path, size: info.size))
    except CatchableError:
      discard

proc optimiseStore*(prefixesRoot: string):
    tuple[linked: int; reclaimed: int64] =
  ## Dedup every prefix under `prefixesRoot`. The one entry point a
  ## `repro store optimise` command or a maintenance script calls.
  if not dirExists(prefixesRoot):
    return (0, 0'i64)
  applyDedup(planDedup(collectCandidates(prefixesRoot)))
