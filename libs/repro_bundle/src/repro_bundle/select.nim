## Bundle selection (Workspace-Bundles.md §1): a workspace and the name of a
## project, variant, repo set or single repo, resolved by the workspace's own
## manifest resolution.

import std/[algorithm, os, strutils]
import repro_workspace_manifests
import ./exec

type
  BundleMember* = object
    name*: string
    relPath*: string     ## workspace-relative, "." for the workspace root
    absPath*: string
    checkedOut*: bool

proc isCheckout(dir: string): bool =
  dirExists(dir / ".git") or fileExists(dir / ".git")

proc resolveMembers*(workspaceRoot, selector: string): seq[BundleMember] =
  ## The workspace root first, then the selector's members in manifest order,
  ## each once.
  let root = normalizedPath(absolutePath(workspaceRoot))
  result.add(BundleMember(name: extractFilename(root), relPath: ".",
    absPath: root, checkedOut: isCheckout(root)))
  var resolved: seq[tuple[name, path: string]]
  var projectError = ""
  try:
    let project = resolveWorkspaceProjectByName(root, selector,
      layersMayOmitProject = true)
    for repo in project.repos:
      resolved.add((repo.name, repo.path))
  except CatchableError as e:
    projectError = e.msg
  if projectError.len > 0:
    # Not a project, variant or repo set: a single repo fragment.
    let fragment = root / "repos" / (selector & ".toml")
    if not fileExists(fragment):
      bundleFail("`" & selector & "` names no project, variant, repo set or " &
        "repo in " & root & ": " & projectError)
    let repo = readRepoFragment(fragment).repo
    resolved.add((repo.name, (if repo.path.len > 0: repo.path else: repo.name)))
  for (name, path) in resolved:
    let rel = normalizedPath(path)
    if rel == "." or rel.len == 0: continue
    var seen = false
    for m in result:
      if m.relPath == rel: seen = true
    if seen: continue
    let abs = normalizedPath(root / rel)
    result.add(BundleMember(name: name, relPath: rel, absPath: abs,
      checkedOut: isCheckout(abs)))

proc byDepth*(members: seq[BundleMember]): seq[BundleMember] =
  ## Parents before children: the workspace root, then by path depth, then
  ## by path, so a nested checkout is cloned into its parent's clone.
  result = members
  result.sort(proc (a, b: BundleMember): int =
    let da = (if a.relPath == ".": 0 else: a.relPath.count('/') + 1)
    let db = (if b.relPath == ".": 0 else: b.relPath.count('/') + 1)
    if da != db: cmp(da, db) else: cmp(a.relPath, b.relPath))
