## Path safety for session workspaces (spec §"Path safety").
##
## A provider names files by canonical workspace-relative paths. The host
## resolves them beneath the workspace root one component at a time,
## examining every component with `lstat` so that a symlink — planted by
## the provider, or left by a checkout — that leads outside the workspace
## is refused rather than followed.
##
## The component walk decides containment; it does not by itself close the
## window between the check and the open. The host is the only writer of a
## workspace in this protocol (the provider's sandbox denies it direct
## access, §"Parties"), so nothing can swap a component between the two.
## A host whose workspaces are shared with other writers must open with
## `openat2(RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS)` instead
## (https://man7.org/linux/man-pages/man2/openat2.2.html).

import std/[algorithm, os, posix, strutils]

import ./[types, capabilities]

const MaxSymlinkHops = 40
  ## The Linux `MAXSYMLINKS` bound, so a symlink cycle refuses.

proc isBeneath*(root, path: string): bool =
  ## Whether normalized absolute `path` is `root` or inside it.
  let r = root.normalizedPath
  let p = path.normalizedPath
  p == r or p.startsWith(r & "/")

proc isSymlinkAt(p: string): bool =
  var st: Stat
  lstat(p.cstring, st) == 0 and S_ISLNK(st.st_mode)

proc resolveBeneath*(root, rel: string; forWrite = false): string =
  ## The absolute path `rel` names beneath `root`, refusing `path-escape`
  ## when `rel` is not canonical or any component resolves outside
  ## `root`. `root` must be an absolute path with no symlink components.
  ## With `forWrite`, the final component may not be a symlink at all, so
  ## a write never lands somewhere other than the name the user saw.
  if not isCanonicalRelPath(rel):
    refuse(arPathEscape, "not a canonical workspace-relative path: " &
      rel.escape)
  let realRoot = root.normalizedPath
  var hops = 0
  var pending = rel.split('/')
  var cur = realRoot
  var i = 0
  while i < pending.len:
    let comp = pending[i]
    let next = cur / comp
    if isSymlinkAt(next):
      if forWrite and i == pending.high:
        refuse(arPathEscape, "write target is a symlink: " & rel.escape)
      inc hops
      if hops > MaxSymlinkHops:
        refuse(arPathEscape, "too many symlinks resolving " & rel.escape)
      let target = expandSymlink(next)
      let resolved =
        if target.isAbsolute: target.normalizedPath
        else: (cur / target).normalizedPath
      if not isBeneath(realRoot, resolved):
        refuse(arPathEscape, "symlink leaves the workspace: " & rel.escape)
      # Continue the walk from the symlink's target: its own components
      # may be symlinks too, so restart from the root on the remainder.
      let restRel = resolved.relativePath(realRoot)
      var rest = if restRel == ".": @[] else: restRel.split('/')
      for j in i + 1 ..< pending.len:
        rest.add pending[j]
      pending = rest
      cur = realRoot
      i = 0
      continue
    cur = next
    inc i
  if not isBeneath(realRoot, cur):
    refuse(arPathEscape, "resolves outside the workspace: " & rel.escape)
  cur

proc readBeneath*(root, rel: string): string =
  let p = resolveBeneath(root, rel)
  if not fileExists(p):
    refuse(arOperationFailed, "no such file: " & rel.escape)
  readFile(p)

proc writeBeneath*(root, rel, content: string) =
  ## Write `content` to `rel`, creating parent directories beneath `root`.
  if content.len > MaxSourceWriteBytes:
    refuse(arBoundsExceeded, "source write larger than 1 MiB")
  let p = resolveBeneath(root, rel, forWrite = true)
  # Re-resolve the parent: creating directories cannot have introduced a
  # symlink, but checking costs nothing and keeps the invariant local.
  let parent = p.parentDir
  if not isBeneath(root, parent):
    refuse(arPathEscape, "parent leaves the workspace: " & rel.escape)
  createDir(parent)
  writeFile(p, content)

proc listBeneath*(root, rel: string): seq[string] =
  ## Workspace-relative names of the regular files under directory `rel`
  ## (`rel` may be `.` for the whole workspace), sorted. Symlinks are
  ## listed but not descended into.
  let base =
    if rel == ".": root.normalizedPath
    else: resolveBeneath(root, rel)
  if not dirExists(base):
    refuse(arOperationFailed, "no such directory: " & rel.escape)
  for p in walkDirRec(base, yieldFilter = {pcFile, pcLinkToFile, pcLinkToDir},
                      followFilter = {pcDir}):
    result.add p.relativePath(root.normalizedPath)
  result.sort()
