# repro_workspace_manifests/project_set.nim
#
# PS-1 — resolution of a workspace's ACTIVE PROJECT SET.
#
# A workspace participates in a SET of manifest projects, not a single one
# (`[workspace] projects` in `.repro/workspace-state.toml`). The participating repo
# set is the UNION of every project in that set. This module owns the union
# and the conflict rule; every membership-resolution entry point in the CLI
# funnels through `extendWithActiveProjectSet` so the whole set is visible to
# sync / init / list / lock / branch / checkout / hooks / check alike.
#
# Two composition axes meet here and they are NOT the same operation:
#
#   * WITHIN one project, manifest layers compose by visibility tier and a
#     later layer SHADOWS an earlier one for the same `(name, path, remote)`
#     triple. That is `compose.nim`.
#   * ACROSS projects, resolved projects UNION and nothing shadows: dedup
#     identity is the checkout PATH, and two projects that disagree about the
#     facts of one path are in CONFLICT.
#
# The asymmetry is deliberate. A layer exists to override (that is what a
# private layer is for), while a project set is a statement about which
# working trees the developer wants side by side. Picking a winner across
# projects would make the workspace's build inputs depend on the order the
# developer happened to add projects in, so a genuine disagreement is refused
# instead — see `Workspace-And-Develop-Mode.md` §"Multi-Project Workspaces".

import std/[os, strutils, tables]

import types
import diagnostics
import resolver
import compose
import workspace_branch

# ---- the by-name ladder, over any manifest source --------------------------
#
# Workspace-Membership-Model.md — a name resolves through ONE ladder:
# `projects/<name>.toml`, then `variants/<name>.toml`, then
# `repo-sets/<name>.toml`. It is defined once, over a `ManifestSource`, so the
# working tree (a directory source) and a pinned revision of the metadata
# repository (a git source) cannot drift apart in which file a name means.

proc ladderRelPaths(name: string):
    tuple[project, variant, repoSet: string] =
  ## The three source-relative paths the ladder consults, in order.
  (project: "projects/" & name & ".toml",
   variant: "variants/" & name & ".toml",
   repoSet: repoSetsDirName & "/" & name & ".toml")

proc namesOnlyVariantOrRepoSetAt*(source: ManifestSource;
                                  name: string): bool =
  ## Whether ``name`` is, in ``source``, ONLY a variant or a repo-set: no
  ## ``projects/<name>.toml``, but a ``variants/<name>.toml`` or
  ## ``repo-sets/<name>.toml``.
  let rel = ladderRelPaths(name)
  not source.hasFile(rel.project) and
    (source.hasFile(rel.variant) or source.hasFile(rel.repoSet))

proc namesOnlyRootVariantOrRepoSet*(workspaceRoot, name: string): bool =
  ## Whether ``name`` is, at the workspace's manifests root, ONLY a variant or
  ## a repo-set: no ``projects/<name>.toml`` there, but a
  ## ``variants/<name>.toml`` or ``repo-sets/<name>.toml``. Such a name
  ## resolves from the root and is never composed across manifest layers: the
  ## composer composes projects, and neither kind is defined across layers.
  ## The one definition of that rule for every name lookup that routes on it.
  namesOnlyVariantOrRepoSetAt(newDirectorySource(manifestsRoot(workspaceRoot)),
    name)

proc resolveManifestNameAt*(source: ManifestSource;
                            name: string): ResolvedProject =
  ## Resolve ONE name through the ladder over ``source``. An unresolvable
  ## name raises: the diagnostic names the source root and the three paths
  ## looked for, in the source's display form.
  let rel = ladderRelPaths(name)
  # Workspace-Membership-Model.md — a repo-set that is ENABLED is what used to
  # be called a project, so `repo-sets/<name>.toml` joins the same ladder
  # rather than getting a parallel one. Looked up last, so a converted manifest
  # repo and an unconverted one both resolve the name they actually carry, and
  # a workspace mid-conversion keeps preferring the project it already had.
  if source.hasFile(rel.project):
    return resolveProjectAt(source, rel.project)
  if source.hasFile(rel.variant):
    return resolveVariantAt(source, rel.variant)
  if source.hasFile(rel.repoSet):
    return resolveRepoSetAt(source, rel.repoSet)
  raise newException(ValueError,
    "no repo-set, project or variant named '" & name & "' found under '" &
      source.displayRoot & "' (looked for '" &
      source.displayPath(rel.project) & "', '" &
      source.displayPath(rel.variant) & "' and '" &
      source.displayPath(rel.repoSet) & "')")

proc resolveWorkspaceProjectByName*(workspaceRoot, name: string;
                                    layersMayOmitProject = false):
    ResolvedProject =
  ## Resolve ONE project of the set by name, using the same ladder a
  ## single-project workspace uses: the composer when the workspace declares
  ## `[[manifest]]` layers (the named project is composed across every layer),
  ## otherwise `projects/<name>.toml` then `variants/<name>.toml` under the
  ## workspace's manifests root.
  ##
  ## An unresolvable name raises: a project recorded in the active set but
  ## absent from every manifest layer is a membership error the operator has
  ## to see, not a repo set to silently narrow.
  ##
  ## The layer stack is the workspace's whole stack — the state file's and the
  ## settings files' (`effectiveWorkspaceLocal`) — whether or not a state file
  ## exists yet. A PROJECT is composed across it (Workspace-Settings-Files.md
  ## §4). By default every DECLARED layer must declare it (the M8 contract);
  ## `layersMayOmitProject` composes additively instead — the project is the
  ## union of what the layers declaring it contribute — for callers that look
  ## a name up rather than compose the workspace's own project (the sync
  ## scope). A name no layer declares raises the composer's
  ## `noLayerDeclaresProjectTag` diagnostic either way. A name the root layer
  ## declares only as a VARIANT or a REPO-SET resolves from the root, as it
  ## always did: the composer composes projects, and neither kind is defined
  ## across layers.
  let manifests = newDirectorySource(manifestsRoot(workspaceRoot))
  if not namesOnlyVariantOrRepoSetAt(manifests, name) and
      isCompositionalWorkspaceToml(workspaceRoot, name):
    let absToml = absolutePath(workspaceTomlPath(workspaceRoot))
    var workspaceLocal = effectiveWorkspaceLocal(workspaceRoot, name)
    # Compose the NAMED project across the same layer stack. Only the selected
    # project name changes; the layer list, visibilities and branches are the
    # workspace's own.
    workspaceLocal.workspace.project = name
    return composeManifestLayersWithOptions(workspaceLocal, workspaceRoot,
      absToml, ComposeOptions(layersMayOmitProject: layersMayOmitProject)).project
  resolveManifestNameAt(manifests, name)

# `WorkspaceProjectSetConflictError` and `conflictingFields` moved to
# `resolver.nim` when repo-set expansion gained the same dedup-by-path rule:
# one refusal, one set of evidence, whichever route reached the second
# declaration. Re-exported here so every existing caller is unaffected.
export WorkspaceProjectSetConflictError, conflictingFields,
  conflictingFieldIds

type
  ProjectSetConflictFrame = object
    ## What a union conflict is attributed to: the workspace's active-set
    ## record (`.repro/workspace-state.toml`, key `workspace.projects`) for a
    ## workspace union, or the metadata source itself for a union resolved
    ## at a revision, which has no active-set record to blame.
    path, keyPath, schema: string

proc raiseProjectSetConflict(frame: ProjectSetConflictFrame; path: string;
                             owningProject, otherProject: string;
                             differences, fieldIds: seq[string]) {.noreturn.} =
  let inner = "projects '" & owningProject & "' and '" & otherProject &
    "' declare checkout path '" & path & "' with different " &
    differences.join(", ") &
    "; a path is ONE working tree, so the active project set cannot be " &
    "resolved. Align the two manifests (normally by having both projects " &
    "`include` the same repo fragment) or drop one project from the set"
  var e = newException(WorkspaceProjectSetConflictError, "")
  e.path = frame.path
  e.keyPath = frame.keyPath
  e.expectedSchema = frame.schema
  e.observedSchema = frame.schema
  e.innerMessage = inner
  e.checkoutPath = path
  e.sources = @[owningProject, otherProject]
  e.fields = fieldIds
  e.msg = "[" & e.path & "]" &
    (if e.keyPath.len > 0: " at key '" & e.keyPath & "'" else: "") & ": " &
    inner
  raise e

proc unionResolved(primary: ResolvedProject; additional: openArray[string];
                   resolveName: proc (name: string): ResolvedProject;
                   frame: ProjectSetConflictFrame): ResolvedProject =
  ## The Union Rules (Workspace-And-Develop-Mode.md §"Union Rules"), once,
  ## for every route: dedup by checkout path, identical declarations merge,
  ## a disagreement is refused, first-seen order. ``resolveName`` resolves one
  ## additional name (through the workspace's ladder, or a source's).
  result = primary
  if additional.len == 0:
    return
  var byPath = initTable[string, int]()
  var declaredBy = initTable[string, string]()
  for idx, repo in result.repos:
    byPath[repo.path] = idx
    declaredBy[repo.path] = primary.projectName
  for name in additional:
    let other = resolveName(name)
    for repo in other.repos:
      if repo.path in byPath:
        let existing = result.repos[byPath[repo.path]]
        let differences = conflictingFields(existing, repo)
        if differences.len > 0:
          raiseProjectSetConflict(frame, repo.path,
            declaredBy.getOrDefault(repo.path, primary.projectName), name,
            differences, conflictingFieldIds(existing, repo))
        # Identical declaration — the common case for shared infrastructure
        # repos every project includes. One checkout, one entry.
      else:
        byPath[repo.path] = result.repos.len
        declaredBy[repo.path] = name
        result.repos.add(repo)

proc unionProjectSet*(workspaceRoot: string; primary: ResolvedProject;
                      additional: openArray[string]): ResolvedProject =
  ## Union `additional` projects onto an already-resolved `primary`.
  ##
  ## The primary project's identity is carried through unchanged
  ## (`projectName`, `workspaceMainline`, `projectFile`): everything
  ## that needs exactly ONE project — the lock destination, `repro add`'s
  ## mutation target — keeps resolving to the primary. Only the repo set
  ## grows.
  ##
  ## First-seen order is preserved, so adding a project APPENDS its
  ## previously-unseen repos and never reorders what was already there.
  unionResolved(primary, additional,
    proc (name: string): ResolvedProject =
      resolveWorkspaceProjectByName(workspaceRoot, name),
    ProjectSetConflictFrame(path: workspaceTomlPath(workspaceRoot),
      keyPath: "workspace.projects", schema: schemaWorkspaceStateV1))

proc activeProjectSetOrEmpty*(workspaceRoot: string): seq[string] =
  ## The recorded active project set, or an empty seq when the workspace
  ## records no state. A state file that exists but does not parse raises the
  ## strict reader's diagnostic: falling back to the primary project alone
  ## would silently drop every other active project's repos from the command.
  readWorkspaceProjects(workspaceRoot)

proc extendWithActiveProjectSet*(workspaceRoot: string;
                                 primary: ResolvedProject): ResolvedProject =
  ## PS-2 entry point: given the project a command resolved through its own
  ## ladder, extend it with every OTHER project in the workspace's active set.
  ##
  ## A single-project workspace (no `projects` array, a one-entry set, or no
  ## readable metadata) returns `primary` unchanged and byte-identical — this
  ## proc is a no-op on every workspace that predates project sets.
  let active = activeProjectSetOrEmpty(workspaceRoot)
  if active.len <= 1:
    return primary
  var additional: seq[string]
  for name in active:
    # The primary is already resolved; skip it however it was named. Comparing
    # against the resolved project name covers the variant case, where the set
    # records the variant name and the resolver reports the composed name.
    if name == primary.projectName:
      continue
    if name notin additional:
      additional.add(name)
  if additional.len == 0:
    return primary
  unionProjectSet(workspaceRoot, primary, additional)

proc resolveProjectSet*(workspaceRoot: string;
                        names: openArray[string]): ResolvedProject =
  ## Resolve an EXPLICIT project set (rather than the recorded one) into a
  ## single participating repo set. `repro workspace enable` uses this
  ## to validate a PROSPECTIVE set before it writes membership: a set that
  ## would not resolve must be refused with nothing mutated (PS-4).
  if names.len == 0:
    raise newException(ValueError, "resolveProjectSet requires a project name")
  result = resolveWorkspaceProjectByName(workspaceRoot, names[0])
  if names.len > 1:
    result = unionProjectSet(workspaceRoot, result, names[1 .. ^1])

proc resolveProjectSetAt*(source: ManifestSource;
                          names: openArray[string]): ResolvedProject =
  ## Resolve an explicit set of names against ONE metadata tree — `source` —
  ## with the same ladder (`resolveManifestNameAt`) and the same Union Rules
  ## (`unionResolved`) `resolveProjectSet` applies to a workspace.
  ##
  ## This is the entry point for resolving a project set at a pinned
  ## REVISION of the metadata repository (`openGitRevisionSource`) without a
  ## working tree, and without writing to that repository. What it reads is
  ## that single repository's tree and nothing else: the `[[manifest]]` layer
  ## composition `resolveWorkspaceProjectByName` performs is NOT applied,
  ## because the layer list lives in the settings files — workspace-local
  ## configuration outside the metadata repository, which has
  ## no revision to be read at. A conflict is attributed to the source root
  ## (`displayRoot`), not to an active-set record.
  if names.len == 0:
    raise newException(ValueError,
      "resolveProjectSetAt requires a project name")
  result = resolveManifestNameAt(source, names[0])
  if names.len > 1:
    result = unionResolved(result, names[1 .. ^1],
      proc (name: string): ResolvedProject =
        resolveManifestNameAt(source, name),
      ProjectSetConflictFrame(path: source.displayRoot, keyPath: "",
        schema: ""))
