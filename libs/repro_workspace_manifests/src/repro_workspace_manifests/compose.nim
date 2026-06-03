## repro_workspace_manifests/compose.nim
##
## M8 — Manifest-layer composition. Walks the `manifest` array of a
## `.repo/workspace.toml` (M5 surface), acquires each manifest repo
## (clone-on-first-use via the M2 `bakWorkspaceVcs` adapter for
## `url`-backed layers, in-tree for `local_path`-backed layers),
## resolves each layer's project file through the M6 single-project
## resolver, and merges the per-layer `ResolvedProject` values into one
## flat `ResolvedProject` with per-repo provenance attached.
##
## Layer order
## -----------
##
## Layers are processed in the order they appear in the workspace TOML.
## The four visibility tiers from
## ``Workspace-And-Develop-Mode.md`` §"Workspace Composition and Manifest
## Layers" are `public`, `org`, `team`, and `private` / `personal`. The
## composer does NOT enforce a particular tier ordering — the milestone
## treats source order as the merge order ("later layers shadow earlier
## ones"). A workspace that lists a private layer first and a public
## layer second therefore gets a public-shadows-private result, and the
## TOML reader is the right place to enforce a per-tier ordering rule if
## a future milestone introduces one. M8 only encodes the merge rule.
##
## Shadowing vs. appending
## -----------------------
##
## For each layer's repos:
##
## - If a repo's `(name, path, remoteName)` triple matches a triple
##   already present from an EARLIER layer, the later layer's
##   `ResolvedRepo` REPLACES the earlier one in place (the position in
##   `repos` is preserved so source order across the whole composition
##   stays stable). This is how a private manifest overrides a public
##   manifest entry for the same repo — typically with a different
##   `revision`.
## - Otherwise the repo is APPENDED to the flat list. A repo that a
##   later layer declares with a different path or remote is treated as
##   a NEW repo, not a shadow.
##
## After every layer has been merged the M6 duplicate-detection rule is
## re-run against the final flattened triples. This guards against a
## single layer that introduces an actual ambiguity (two distinct
## fragments with the same triple) — the M6 resolver already catches
## intra-layer duplicates while building each per-layer
## `ResolvedProject`, but the post-composition rerun catches any
## edge-case duplicate the per-layer pass could not have seen.
##
## Engine seam
## -----------
##
## `url`-backed layers schedule a `bakWorkspaceVcs.clone` build action
## via M2's `gitCloneAction`. The caller MUST ensure a
## `WorkspaceVcsExecutor` is registered before invoking
## `composeManifestLayers`; in practice that means
## `installGitVcsExecutor()` from `git_actions`. The composer treats a
## pre-existing target directory as a no-op (idempotent on second-call
## semantics): it skips the action and reads the manifest contents
## directly from disk. Fresh clones execute through `runBuild` so the
## action cache and engine-level diagnostics participate uniformly.
##
## Error policy
## ------------
##
## Reuses M5's `WorkspaceManifestParseError` (same rationale as M6 and
## M7): every failure either originates inside an M5 reader or M6
## resolver, or it is a shape rule on top of those — "manifest layer
## could not be acquired", "layer is missing a `projects/<p>.toml` for
## the named project", "post-composition duplicate triple". The
## diagnostic carries the manifest URL or local path in `path` so the
## user can tell WHICH layer failed.

import std/[options, os, strutils, tables]
import types
import diagnostics
import reader
import resolver
import repro_build_engine
import git_tool
import git_actions

# ---- helpers --------------------------------------------------------------

proc visibilityFromString(layerLabel, raw: string): WorkspaceVisibility =
  ## Map the TOML `visibility` string to the canonical enum tier. The
  ## workspace schema accepts both "private" and "personal" for the
  ## per-developer tier (they are used interchangeably in
  ## Workspace-And-Develop-Mode.md §"Workspace Composition"); the enum
  ## carries one canonical name (`wvPersonal`).
  case raw
  of "public": wvPublic
  of "org": wvOrg
  of "team": wvTeam
  of "private", "personal": wvPersonal
  else:
    raiseManifestError(layerLabel, "manifest[].visibility",
      schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "unknown visibility tier '" & raw &
        "' (expected one of: public, org, team, private, personal)")

proc sanitizeForPath(raw: string): string =
  ## Turn a manifest URL or local-path string into a filesystem-safe
  ## suffix for the per-layer clone directory under `.repo/`. Any
  ## character that isn't alphanumeric, dash, dot, or underscore is
  ## replaced with `-`. The result is folded down to a bounded length so
  ## a pathological URL can't blow up the directory name.
  var raw1 = newStringOfCap(raw.len)
  for ch in raw:
    case ch
    of 'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_': raw1.add(ch)
    else: raw1.add('-')
  # Collapse runs of `-` so we don't end up with absurd dashes.
  var collapsed = newStringOfCap(raw1.len)
  var prevDash = false
  for ch in raw1:
    if ch == '-':
      if not prevDash: collapsed.add(ch)
      prevDash = true
    else:
      collapsed.add(ch)
      prevDash = false
  if collapsed.len > 80:
    collapsed.setLen(80)
  result = collapsed.strip(chars = {'-'}, leading = true, trailing = true)
  if result.len == 0:
    result = "layer"

proc layerDirName(index: int; entry: ManifestLayer): string =
  ## Filesystem name used for `url`-backed layer checkouts under
  ## `<workspaceRoot>/.repo/`. The index makes the directory unique even
  ## if two layers share the same sanitized URL suffix.
  let urlOrLocal =
    if entry.url.isSome and entry.url.get().len > 0: entry.url.get()
    elif entry.local_path.isSome and entry.local_path.get().len > 0:
      entry.local_path.get()
    else: "layer"
  "manifests-" & $index & "-" & sanitizeForPath(urlOrLocal)

proc layerLabel(entry: ManifestLayer): string =
  ## Human-facing identifier for a manifest layer (used as the `path`
  ## field on diagnostics and as the `manifestLayer` provenance string
  ## on each composed `ResolvedRepo`). Prefers `url` when present (the
  ## remote source of record), falling back to `local_path` when the
  ## layer is in-tree.
  if entry.url.isSome and entry.url.get().len > 0:
    entry.url.get()
  elif entry.local_path.isSome and entry.local_path.get().len > 0:
    entry.local_path.get()
  else:
    "<unknown manifest layer>"

proc acquireUrlLayer(
    workspaceRoot, workspaceTomlPath: string;
    layerIdx: int;
    entry: ManifestLayer): string =
  ## Acquire a `url`-backed manifest layer. Returns the absolute path of
  ## the on-disk checkout (a `manifests-<i>-<sanitized>` directory
  ## under `<workspaceRoot>/.repo/`).
  ##
  ## On first invocation the M2 `gitCloneAction` is scheduled through
  ## the build engine; the engine's registered `WorkspaceVcsExecutor`
  ## (typically `git_actions.executeWorkspaceVcsAction`, installed via
  ## `installGitVcsExecutor()`) performs the clone. On subsequent calls
  ## the target directory already exists and the composer treats the
  ## layer as available without re-running the clone — the action cache
  ## otherwise restores only the receipt, not the working tree, so we
  ## cannot rely on a cache hit to re-materialize the manifest checkout.
  let dotRepo = workspaceRoot / ".repo"
  createDir(dotRepo)
  let target = dotRepo / layerDirName(layerIdx, entry)
  if dirExists(target):
    return target

  let url = entry.url.get()
  let revision =
    if entry.branch.isSome and entry.branch.get().len > 0:
      entry.branch.get()
    else: ""

  let identity =
    try:
      ensureGitToolResolvable(tpmPathOnly, getEnv("PATH"))
    except CatchableError as err:
      raiseManifestError(workspaceTomlPath,
        "manifest[" & $layerIdx & "].url",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "cannot resolve git tool to acquire manifest layer '" & url &
          "': " & err.msg)
  let receiptPath = dotRepo / (layerDirName(layerIdx, entry) & ".receipt")
  var action = gitCloneAction(
    "m8-manifest-clone-" & $layerIdx,
    identity,
    remoteUrl = url,
    repoPath = target,
    receiptPath = receiptPath,
    revision = revision)
  action.cwd = workspaceRoot
  let cacheRoot = dotRepo / "engine-cache"
  var config = defaultBuildEngineConfig(cacheRoot)
  config.suppressTrace = true
  let res = runBuild(graph([action]), config)
  if res.results.len != 1 or
      res.results[0].status notin {asSucceeded, asCacheHit, asUpToDate}:
    let outcome =
      if res.results.len > 0: res.results[0]
      else: ActionResult(status: asFailed, reason: "no-result")
    raiseManifestError(workspaceTomlPath,
      "manifest[" & $layerIdx & "].url",
      schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "failed to clone manifest layer '" & url &
        "' (status=" & $outcome.status &
        ", reason=" & outcome.reason &
        ", stderr=" & outcome.stderr & ")")
  if not dirExists(target):
    raiseManifestError(workspaceTomlPath,
      "manifest[" & $layerIdx & "].url",
      schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "manifest layer '" & url &
        "' clone reported success but the working tree does not exist at " &
        target)
  target

proc acquireLocalPathLayer(
    workspaceRoot, workspaceTomlPath: string;
    layerIdx: int;
    entry: ManifestLayer): string =
  ## Resolve a `local_path`-backed manifest layer to its on-disk path.
  ## The path is interpreted relative to `workspaceRoot` when not
  ## absolute; the directory MUST already exist (a local-path layer
  ## describes an in-tree manifest checkout the user has prepared, NOT
  ## a target the composer creates).
  let raw = entry.local_path.get()
  let resolved =
    if isAbsolute(raw): raw
    else: workspaceRoot / raw
  if not dirExists(resolved):
    raiseManifestError(workspaceTomlPath,
      "manifest[" & $layerIdx & "].local_path",
      schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "manifest layer local_path '" & raw &
        "' does not exist on disk (resolved to '" & resolved & "')")
  resolved

# ---- merge rule -----------------------------------------------------------

proc mergeLayerIntoResult(
    workspaceTomlPath, layerProvenance: string;
    visibility: WorkspaceVisibility;
    layerResolved: ResolvedProject;
    composed: var ResolvedProject;
    seen: var Table[string, int]) =
  ## Merge one layer's `ResolvedProject` into the accumulating composed
  ## project. The triple `(name, path, remoteName)` is the identity used
  ## to detect a shadow: when a later layer's triple matches an earlier
  ## layer's, the later entry REPLACES the earlier one in place. A new
  ## triple is APPENDED.
  for repo in layerResolved.repos:
    var stamped = repo
    stamped.manifestLayer = layerProvenance
    stamped.visibility = visibility
    let triple = stamped.name & "\t" & stamped.path & "\t" & stamped.remoteName
    if triple in seen:
      composed.repos[seen[triple]] = stamped
    else:
      seen[triple] = composed.repos.len
      composed.repos.add(stamped)

# ---- public entry points --------------------------------------------------

proc composeManifestLayers*(
    workspaceLocal: WorkspaceLocal;
    workspaceRoot: string;
    workspaceTomlPath: string = ""): ResolvedProject =
  ## Compose the manifest layers declared in `workspaceLocal` into a
  ## single `ResolvedProject`. `workspaceRoot` is the absolute path of
  ## the directory containing `.repo/` and is used to:
  ##
  ## - Anchor `url`-backed layer checkouts under
  ##   `<workspaceRoot>/.repo/manifests-<i>-<sanitized>/`.
  ## - Resolve `local_path` entries when their value is relative.
  ##
  ## `workspaceTomlPath` is the absolute path of the `workspace.toml`
  ## that produced `workspaceLocal`; it is carried on every structured
  ## diagnostic as the `path` field so the user can tell which workspace
  ## file led to the failure. When the caller has only the parsed
  ## `WorkspaceLocal` and not the source path the empty string is
  ## acceptable; in that case the diagnostic's `path` falls back to the
  ## URL or local path of the offending layer.
  if not isAbsolute(workspaceRoot):
    raiseManifestError(workspaceTomlPath, "workspaceRoot",
      schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "composeManifestLayers requires an absolute workspaceRoot, got '" &
        workspaceRoot & "'")

  let projectName = workspaceLocal.workspace.project
  if projectName.len == 0:
    raiseManifestError(workspaceTomlPath, "workspace.project",
      schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "workspace.project is empty; composeManifestLayers cannot select a project")
  if workspaceLocal.manifest.len == 0:
    raiseManifestError(workspaceTomlPath, "manifest",
      schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "workspace declares no manifest layers")

  var composed: ResolvedProject
  var seen = initTable[string, int]()

  for layerIdx, entry in workspaceLocal.manifest:
    let hasUrl = entry.url.isSome and entry.url.get().len > 0
    let hasLocal = entry.local_path.isSome and entry.local_path.get().len > 0
    if not hasUrl and not hasLocal:
      raiseManifestError(workspaceTomlPath,
        "manifest[" & $layerIdx & "]",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "manifest layer needs either `url` or `local_path` (both empty)")
    if hasUrl and hasLocal:
      raiseManifestError(workspaceTomlPath,
        "manifest[" & $layerIdx & "]",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "manifest layer declares BOTH `url` and `local_path`; choose one")

    let provenance = layerLabel(entry)
    let visibility = visibilityFromString(
      if workspaceTomlPath.len > 0: workspaceTomlPath else: provenance,
      entry.visibility)

    let layerRoot =
      if hasUrl:
        acquireUrlLayer(workspaceRoot, workspaceTomlPath, layerIdx, entry)
      else:
        acquireLocalPathLayer(workspaceRoot, workspaceTomlPath, layerIdx, entry)

    let projectFile = layerRoot / "projects" / (projectName & ".toml")
    if not fileExists(projectFile):
      raiseManifestError(workspaceTomlPath,
        "manifest[" & $layerIdx & "]",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "manifest layer '" & provenance &
          "' does not declare project '" & projectName &
          "' (expected file '" & projectFile & "' to exist)")

    var layerResolved: ResolvedProject
    try:
      layerResolved = resolveProject(projectFile)
    except WorkspaceManifestParseError as err:
      # Re-raise with the layer's provenance prepended to the inner
      # message so the user can tell WHICH layer's project resolution
      # failed.
      raiseManifestError(workspaceTomlPath,
        "manifest[" & $layerIdx & "]",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "manifest layer '" & provenance &
          "' failed to resolve project '" & projectName & "': " &
          err.msg)

    # First layer establishes the project-level fields. Later layers
    # legitimately may differ on `projectName` (only if a layer
    # mis-declares the project file, which the file-exists check above
    # would have rejected) — we treat the first layer as authoritative.
    if layerIdx == 0:
      composed.projectName = layerResolved.projectName
      composed.defaultRevision = layerResolved.defaultRevision
      composed.trunk = layerResolved.trunk
      composed.projectFile = layerResolved.projectFile

    mergeLayerIntoResult(
      workspaceTomlPath, provenance, visibility,
      layerResolved, composed, seen)

  # Post-composition duplicate detection. The per-layer M6 resolver
  # already catches intra-layer duplicates; this pass guards against an
  # edge case where two layers introduce the same triple via the
  # shadow path AND the appended path (impossible in the current rule
  # but cheap to assert). It also surfaces a clear diagnostic if some
  # future change in the merge rule ever loses uniqueness.
  var finalSeen = initTable[string, int]()
  for i, repo in composed.repos:
    let triple = repo.name & "\t" & repo.path & "\t" & repo.remoteName
    if triple in finalSeen:
      raiseManifestError(workspaceTomlPath,
        "manifest",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "composed repo set has duplicate (name='" & repo.name &
          "', path='" & repo.path & "', remote='" & repo.remoteName &
          "') at indices " & $finalSeen[triple] & " and " & $i)
    finalSeen[triple] = i

  result = composed

proc composeManifestLayersFromFile*(
    workspaceTomlPath: string): ResolvedProject =
  ## Convenience wrapper that reads the `.repo/workspace.toml` at
  ## `workspaceTomlPath` via M5's `readWorkspaceLocal` and then invokes
  ## `composeManifestLayers`. The `workspaceRoot` is the parent of the
  ## TOML file's directory (the directory holding `.repo/`).
  let absToml = absolutePath(workspaceTomlPath)
  let workspaceLocal = readWorkspaceLocal(absToml)
  # workspace.toml lives at <workspaceRoot>/.repo/workspace.toml; strip
  # the two trailing components to recover the workspace root.
  let workspaceRoot = parentDir(parentDir(absToml))
  composeManifestLayers(workspaceLocal, workspaceRoot, absToml)
