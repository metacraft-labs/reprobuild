## Workspace-relative path markers — Distributed-Execution M0 Catch #4.
##
## An action-cache record names its inputs and outputs by the paths the
## producing build saw. Two checkouts of the same workspace at different
## roots (`/tmp/ws-a`, `/tmp/ws-b`) therefore disagree on every absolute
## path inside the workspace even when every byte is the same. Under
## `REPRO_PORTABLE_CACHE=1` the peer cache publishes records with those
## paths rewritten to a logical marker, `$WORKSPACE/<rel>`, and the consumer
## rewrites the marker onto ITS workspace root before anything reads or
## writes a file.
##
## Paths outside the workspace (toolchain, SDK headers) and relative names
## (a relocatable record's cwd-relative inputs) are left exactly as they
## are: the former are host facts that the strong fingerprint checks by
## content, the latter already resolve against the consulting action's own
## working directory.
##
## Hermetic-Builds-And-Path-Independence.md motivates the marker; the
## `<label>:<rel>` logical paths of `repro_local_store/portable_fingerprint`
## are the same idea for the portable memo plane.

import std/[os, strutils]

const
  WorkspaceMarker* = "$WORKSPACE"
    ## The logical root marker. A normalized path is either exactly this
    ## (the workspace root itself) or `$WORKSPACE/` followed by a
    ## `/`-separated workspace-relative path.

type
  WorkspacePathError* = object of CatchableError

proc slashed(path: string): string =
  path.replace('\\', '/')

proc rootSpellings(workspaceRoot: string): seq[string] =
  ## The spellings under which a build may have recorded paths in the
  ## workspace: the root as configured and its symlink-resolved form (on
  ## macOS `/tmp` is a link to `/private/tmp`, and a recorded path can carry
  ## either spelling). Longest first so the most specific prefix wins.
  if workspaceRoot.len == 0:
    return @[]
  let given = slashed(normalizedPath(absolutePath(workspaceRoot)))
  result.add(given)
  try:
    let resolved = slashed(normalizedPath(expandFilename(workspaceRoot)))
    if resolved != given:
      result.add(resolved)
  except OSError:
    discard
  if result.len == 2 and result[1].len > result[0].len:
    swap(result[0], result[1])

proc isWorkspaceMarked*(path: string): bool =
  ## True for `$WORKSPACE` and `$WORKSPACE/...`.
  path == WorkspaceMarker or path.startsWith(WorkspaceMarker & "/")

proc normalizeWorkspacePath*(path, workspaceRoot: string): string =
  ## `path` rewritten to `$WORKSPACE/<rel>` when it is an absolute path inside
  ## `workspaceRoot`; unchanged otherwise (relative names, paths outside the
  ## workspace, an empty `workspaceRoot`).
  if workspaceRoot.len == 0 or path.len == 0 or not path.isAbsolute:
    return path
  let target = slashed(normalizedPath(path))
  for root in rootSpellings(workspaceRoot):
    if target == root:
      return WorkspaceMarker
    let prefix = if root.endsWith("/"): root else: root & "/"
    if target.startsWith(prefix):
      return WorkspaceMarker & "/" & target[prefix.len .. ^1]
  path

proc rebaseWorkspacePath*(path, workspaceRoot: string): string =
  ## Inverse of `normalizeWorkspacePath` against the CONSUMER's root:
  ## `$WORKSPACE/<rel>` becomes `<workspaceRoot>/<rel>` with native
  ## separators. Unmarked paths are returned unchanged. Raises
  ## `WorkspacePathError` for a marked path when no workspace root is known,
  ## or for a relative part that would escape the root (`..`).
  if not isWorkspaceMarked(path):
    return path
  if workspaceRoot.len == 0:
    raise newException(WorkspacePathError,
      "record names " & path & " but no workspace root is configured")
  let root = normalizedPath(absolutePath(workspaceRoot))
  if path == WorkspaceMarker:
    return root
  let rel = path[WorkspaceMarker.len + 1 .. ^1]
  for part in rel.split('/'):
    if part == "..":
      raise newException(WorkspacePathError,
        "workspace-relative path escapes the workspace: " & path)
  normalizedPath(root / rel.replace('/', DirSep))

proc isWorkspaceAncestor*(path, workspaceRoot: string): bool =
  ## True when `path` (absolute) is a PROPER ancestor of `workspaceRoot`, in
  ## either of the root's spellings — `/`, `/tmp`, `/private/tmp/pa` for a
  ## root `/tmp/pa/ws`. Used to recognise the parent-directory walk a shell
  ## or a compiler performs from inside the workspace (Distributed-Execution
  ## M0, reprobuild-pm issue
  ## 2026-10-16-peer-cache-pathsets-key-ancestor-probes-by-absolute-path).
  if workspaceRoot.len == 0 or path.len == 0 or not path.isAbsolute:
    return false
  var target = slashed(normalizedPath(path))
  if target.len > 1 and target.endsWith("/"):
    target.setLen(target.len - 1)
  for root in rootSpellings(workspaceRoot):
    if target == root:
      return false
    if target == "/" or root.startsWith(target & "/"):
      return true
  false
