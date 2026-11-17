## Bundle selection (Workspace-Bundles.md §1): a workspace and the name of a
## project, variant, repo set or single repo, resolved by the workspace's own
## manifest resolution.

import std/[algorithm, os, sets, strutils]
import repro_workspace_manifests
import repro_local_store/store_bundle
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

proc nativeSelection*(workspaceRoot: string; members: seq[BundleMember];
                      skip: openArray[string] = []): BundleSelection =
  ## The selection a bundle of `members` carries in its native half
  ## (docs/store-bundles.md §2.1): every Git checkout under the
  ## workspace root that is not a checked-out member is excluded, and a
  ## member inside an excluded checkout is included again. `skip` names
  ## subtrees the walk does not enter (the store and the action cache when
  ## they live in the workspace).
  ##
  ## A checkout is a directory holding `.git` (a directory, or the file a
  ## worktree or a submodule has). The walk does not descend into `.git`, and
  ## stops at an excluded checkout: nothing below it is carried, except a
  ## member, which is named by its own path.
  let root = normalizedPath(absolutePath(workspaceRoot))
  var memberPaths = initHashSet[string]()
  for m in members:
    if m.checkedOut:
      memberPaths.incl(normalizedPath(m.absPath))
  let skipDirs = @skip
  var excluded: seq[string]
  proc walk(start: string; excluded: var seq[string]) =
    var stack = @[start]
    while stack.len > 0:
      let dir = stack.pop()
      for kind, path in walkDir(dir):
        if kind != pcDir or path.extractFilename == ".git":
          continue
        var skipped = false
        for s in skipDirs:
          if path == s or path.startsWith(s & "/"):
            skipped = true
        if skipped:
          continue
        if isCheckout(path) and path notin memberPaths:
          excluded.add(path)
          continue
        stack.add(path)
  walk(root, excluded)
  # A member inside an excluded checkout is included again, and walked
  # itself, so a checkout nested in it that is not a member is excluded too.
  var included = initHashSet[string]()
  while true:
    var added = false
    for m in members:
      if not m.checkedOut or m.relPath == ".":
        continue
      let p = normalizedPath(m.absPath)
      if p in included:
        continue
      for e in excluded:
        if p.startsWith(e & "/"):
          included.incl(p)
          result.included.add(p)
          walk(p, excluded)
          added = true
          break
    if not added: break
  result.excluded = excluded
  result.excluded.sort()
  result.included.sort()
