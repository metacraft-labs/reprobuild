## Junction-aware recursive directory removal helper (M10 —
## Realize-Closure-And-Catalog-Expansion.milestones.org "M10:
## ``repro home gc`` subcommand").
##
## Rationale: per the project memories
## ``project_reprobuild_store_junction_hazard`` and
## ``feedback_nim_removedir_junction_destructive``, Nim's stdlib
## ``os.removeDir`` on Windows walks INTO a junction's link target,
## recursively deletes the target's children, THEN unlinks the
## reparse point. Reprobuild's content-addressed store and launcher
## prefixes routinely contain NTFS junctions pointing into real user
## data (e.g. Scoop app dirs under ``%USERPROFILE%\scoop\apps\``); a
## naive ``removeDir`` over such a prefix would silently destroy the
## user's files.
##
## The helper here is the M10 gc path's ONLY deletion primitive: it
## detects junctions / symlinks-to-dirs via ``getFileInfo(path,
## followSymlink = false)``, unlinks the reparse point directly
## (Win32 ``RemoveDirectoryW``), and only recurses into REAL
## subdirectories.
##
## Mirrors the M3 ``removeJunctionAware`` proc in
## ``repro_home_apply/builtin_adapter.nim`` (verified working under
## the M3 ``test_m3_pre_install_runner_remove_does_not_recurse_into_junction``
## fixture). We extract a dedicated module here so the gc code and
## the dedicated junction-hazard regression test depend on a SINGLE
## point of truth.
##
## Public surface:
##
##   * `isJunction(path: string): bool` — true if ``path`` is a
##     directory-shaped reparse point (Windows junction) or POSIX
##     symlink to a directory.
##   * `unlinkJunction(path: string)` — unlink the reparse point
##     itself. Never touches the link target.
##   * `removeJunctionAware(path: string)` — recursive delete with
##     junction-safe traversal. Drop-in replacement for
##     ``os.removeDir`` when the tree MAY contain junctions.

import std/[os]
from repro_core/paths import extendedPath

when defined(windows):
  import std/[winlean]

  proc removeDirectoryW(lpPathName: WideCString): int32 {.
    importc: "RemoveDirectoryW", dynlib: "kernel32", stdcall.}
    ## Win32 ``RemoveDirectoryW`` — removes a directory entry
    ## (including a reparse-point junction) without recursing into
    ## its children or following its target.

proc isJunction*(path: string): bool =
  ## Detect a Windows junction (a directory-shaped reparse point) or
  ## a POSIX symlink-to-directory. We deliberately call
  ## ``getFileInfo`` with ``followSymlink = false`` so the answer
  ## reports the link entry's own kind, not the target's kind.
  let info = try: getFileInfo(extendedPath(path), followSymlink = false)
             except OSError: return false
  info.kind == pcLinkToDir

proc unlinkJunction*(path: string) =
  ## Unlink a junction / symlink-to-dir at ``path`` WITHOUT touching
  ## the link target. Windows: ``RemoveDirectoryW`` against the
  ## reparse point. POSIX: ``removeFile`` (``unlink``) — treats the
  ## symlink as a file entry; the target survives by definition.
  ##
  ## Silently no-ops on failure: the caller (gc) treats best-effort
  ## as the correct behaviour because the prefix is being reclaimed
  ## anyway and a transient permission error must not abort the
  ## whole gc.
  when defined(windows):
    let wide = newWideCString(extendedPath(path))
    discard removeDirectoryW(wide)
  else:
    try: removeFile(extendedPath(path))
    except OSError:
      try: removeDir(extendedPath(path), checkDir = false)
      except OSError: discard

proc removeJunctionAware*(path: string) =
  ## Junction-safe directory/file removal. If ``path`` itself is a
  ## junction (Windows reparse point) or a symlink, unlink the link
  ## WITHOUT recursing into the target. Otherwise walk children one
  ## level at a time, unlinking any nested junctions safely and
  ## recursing into REAL subdirs only.
  ##
  ## This is the ONLY deletion primitive the M10 gc code path uses
  ## against the store. A bare ``removeDir`` over a prefix containing
  ## junctions WOULD destroy the link target's contents — see
  ## ``project_reprobuild_store_junction_hazard`` and
  ## ``feedback_nim_removedir_junction_destructive``.
  if not (fileExists(extendedPath(path)) or dirExists(extendedPath(path))):
    return
  if isJunction(path):
    unlinkJunction(path)
    return
  if dirExists(extendedPath(path)):
    for kind, child in walkDir(extendedPath(path)):
      case kind
      of pcLinkToDir:
        unlinkJunction(child)
      of pcLinkToFile:
        try: removeFile(extendedPath(child))
        except OSError: discard
      of pcDir:
        removeJunctionAware(child)
      of pcFile:
        try: removeFile(extendedPath(child))
        except OSError: discard
    # After all children are gone (and junctions were unlinked, not
    # recursed-into), the dir itself is empty — Win32
    # ``RemoveDirectoryW`` removes it cleanly.
    when defined(windows):
      let wide = newWideCString(extendedPath(path))
      discard removeDirectoryW(wide)
    else:
      try:
        removeDir(extendedPath(path), checkDir = false)
      except OSError:
        discard
  else:
    try:
      removeFile(extendedPath(path))
    except OSError:
      discard

proc directorySizeBytes*(path: string): int64 =
  ## Recursive sum of the file sizes under ``path``, in bytes.
  ## Junctions and symlinks are EXCLUDED from the sum (their size
  ## is ~0 for the reparse point itself, and walking into the
  ## target would double-count user data the prefix doesn't own).
  ##
  ## Used by the M10 gc footprint report; the spec calls out
  ## "junction targets EXCLUDED from the sum".
  result = 0
  if not dirExists(extendedPath(path)):
    if fileExists(extendedPath(path)):
      try: result = getFileSize(extendedPath(path)) except OSError: discard
    return
  if isJunction(path):
    return  # don't follow into the target
  for kind, child in walkDir(extendedPath(path)):
    case kind
    of pcFile:
      try: result += getFileSize(extendedPath(child)) except OSError: discard
    of pcDir:
      result += directorySizeBytes(child)
    of pcLinkToDir, pcLinkToFile:
      # Skip reparse points; we never walk through them, even for
      # size accounting.
      discard
