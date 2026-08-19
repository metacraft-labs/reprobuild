# repro_workspace_manifests/project_set.nim
#
# PS-1 — resolution of a workspace's ACTIVE PROJECT SET.
#
# A workspace participates in a SET of manifest projects, not a single one
# (`[workspace] projects` in `.repro/workspace.toml`). The participating repo
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

import std/[options, os, strutils, tables]

import types
import diagnostics
import reader
import resolver
import compose
import workspace_branch

proc resolveWorkspaceProjectByName*(workspaceRoot, name: string):
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
  if isCompositionalWorkspaceToml(workspaceRoot):
    let absToml = absolutePath(workspaceTomlPath(workspaceRoot))
    var workspaceLocal = readWorkspaceLocal(absToml)
    # Compose the NAMED project across the same layer stack. Only the selected
    # project name changes; the layer list, visibilities and branches are the
    # workspace's own.
    workspaceLocal.workspace.project = name
    return composeManifestLayers(workspaceLocal, workspaceRoot, absToml)
  let manifests = manifestsRoot(workspaceRoot)
  let projectFile = manifests / "projects" / (name & ".toml")
  let variantFile = manifests / "variants" / (name & ".toml")
  if fileExists(projectFile):
    return resolveProject(projectFile)
  if fileExists(variantFile):
    return resolveVariant(variantFile)
  raise newException(ValueError,
    "no project or variant named '" & name & "' found under '" & manifests &
      "' (looked for '" & projectFile & "' and '" & variantFile & "')")

type
  WorkspaceProjectSetConflictError* = object of WorkspaceManifestParseError
    ## PS-4 — raised ONLY when two projects of the set declare one checkout
    ## path with different facts. Callers distinguish this from every other
    ## resolution failure: a conflict is a decision the operator has to make
    ## (the set cannot be resolved at all), whereas an unresolvable or
    ## not-yet-materialized manifest may simply be a workspace whose manifest
    ## checkout has not landed yet.

proc conflictingFields(existing, candidate: ResolvedRepo): seq[string] =
  ## The load-bearing facts of a checkout: what would be cloned, from where,
  ## at which revision, with which VCS. Two projects may reach these through
  ## differently-NAMED remotes (`origin` vs `metacraft-labs` pointing at the
  ## same fetch base) without disagreeing about anything real, so the remote
  ## KEY is deliberately not compared — the resolved fetch URL is.
  if existing.name != candidate.name:
    result.add("name (" & existing.name & " vs " & candidate.name & ")")
  if existing.fetchUrl != candidate.fetchUrl:
    result.add("fetch url (" & existing.fetchUrl & " vs " &
      candidate.fetchUrl & ")")
  if existing.revision != candidate.revision:
    result.add("revision (" & existing.revision & " vs " &
      candidate.revision & ")")
  if existing.vcs != candidate.vcs:
    result.add("vcs (" & existing.vcs & " vs " & candidate.vcs & ")")

proc raiseProjectSetConflict(workspaceRoot, path: string;
                             owningProject, otherProject: string;
                             differences: seq[string]) {.noreturn.} =
  let inner = "projects '" & owningProject & "' and '" & otherProject &
    "' declare checkout path '" & path & "' with different " &
    differences.join(", ") &
    "; a path is ONE working tree, so the active project set cannot be " &
    "resolved. Align the two manifests (normally by having both projects " &
    "`include` the same repo fragment) or drop one project from the set"
  var e = newException(WorkspaceProjectSetConflictError, "")
  e.path = workspaceTomlPath(workspaceRoot)
  e.keyPath = "workspace.projects"
  e.expectedSchema = schemaWorkspaceLocalV1
  e.observedSchema = schemaWorkspaceLocalV1
  e.innerMessage = inner
  e.msg = "[" & e.path & "] at key 'workspace.projects': " & inner
  raise e

proc unionProjectSet*(workspaceRoot: string; primary: ResolvedProject;
                      additional: openArray[string]): ResolvedProject =
  ## Union `additional` projects onto an already-resolved `primary`.
  ##
  ## The primary project's identity is carried through unchanged
  ## (`projectName`, `defaultRevision`, `trunk`, `projectFile`,
  ## `certificatePolicy`): everything that needs exactly ONE project — the
  ## lock destination, the certificate gate policy, `repro add`'s mutation
  ## target — keeps resolving to the primary. Only the repo set grows.
  ##
  ## First-seen order is preserved, so adding a project APPENDS its
  ## previously-unseen repos and never reorders what was already there.
  result = primary
  if additional.len == 0:
    return
  var byPath = initTable[string, int]()
  var declaredBy = initTable[string, string]()
  for idx, repo in result.repos:
    byPath[repo.path] = idx
    declaredBy[repo.path] = primary.projectName
  for name in additional:
    let other = resolveWorkspaceProjectByName(workspaceRoot, name)
    for repo in other.repos:
      if repo.path in byPath:
        let differences = conflictingFields(result.repos[byPath[repo.path]], repo)
        if differences.len > 0:
          raiseProjectSetConflict(workspaceRoot, repo.path,
            declaredBy.getOrDefault(repo.path, primary.projectName), name,
            differences)
        # Identical declaration — the common case for shared infrastructure
        # repos every project includes. One checkout, one entry.
      else:
        byPath[repo.path] = result.repos.len
        declaredBy[repo.path] = name
        result.repos.add(repo)

proc activeProjectSetOrEmpty*(workspaceRoot: string): seq[string] =
  ## The recorded active project set, or an empty seq when the workspace has
  ## no readable metadata. A malformed `workspace.toml` is NOT fatal here:
  ## every caller already resolved a primary project through its own ladder,
  ## and the pre-existing behaviour for unreadable metadata is to fall back to
  ## that single project rather than to fail the command.
  try:
    readWorkspaceProjects(workspaceRoot)
  except CatchableError:
    @[]

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
