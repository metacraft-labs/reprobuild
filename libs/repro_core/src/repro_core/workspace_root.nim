## repro_core/workspace_root.nim
##
## WHERE IS THE WORKSPACE ROOT? — the one answer every part of reprobuild
## uses: the CLI's workspace-wide verbs, the managed git hooks and the
## pre-push gate they run, the develop/flake verbs, and the flake dev-shell
## activation that runs inside a provider. Each of them used to walk the
## ancestors of its starting directory with its own marker list, and the lists
## had drifted apart (one keyed on the state file, one on any "initialized"
## marker including a member repo's own ``repro.lock``, one on the settings and
## state files only). A directory that one of them called a workspace root
## another did not. They now all call ``discoverWorkspaceRoot``.
##
## The rule is Workspace-Settings-Files.md §6: "The workspace root is the
## nearest ancestor directory containing ``repro-workspace.toml``, unless
## ``REPRO_WORKSPACE_CONFIG`` names the file."
##
## The RETIRED settings and state file names (``RetiredSettingsFileName``,
## ``RetiredStateFileName``) are never read as settings or state. A directory
## that holds one WITHOUT the current file still marks a root, for one reason:
## so that the workspace verbs, the managed hooks and the pre-push gate find
## the workspace and refuse there with the remedy (``retired_names.nim`` in the
## manifest library), instead of walking past it, finding no workspace and
## standing down — which would let a push through ungated.
##
## Precedence, in order:
##
##   1. ``REPRO_WORKSPACE_CONFIG`` naming an EXISTING file: the root is that
##      file's directory, wherever the walk starts. A value naming a file that
##      does not exist means "no settings file" (the same reading
##      ``findWorkspaceSettingsPath`` gives it): settings files then mark
##      nothing, and the walk below runs on the other markers alone.
##   2. The NEAREST ancestor of the starting path (inclusive) carrying a
##      workspace marker:
##        * a settings file — ``repro-workspace.toml``, or a retired one
##          (recognized only to refuse, see above);
##        * a state file — ``.repro/workspace-state.toml``, or a retired one
##          (likewise);
##        * a resolved manifest checkout inside a ``.repro/`` shell
##          (``hasResolvedManifestCheckout``) — which a lock RECORD STORE's
##          top-level ``projects/`` + ``locks/`` is not, even once the store
##          has acquired a ``.repro/`` directory.
##      Nearest wins, so a NESTED workspace (a workspace root below another
##      one) is its own root for every path under it. A MEMBER REPO of a
##      workspace carries none of these markers — its own build ``.repro/``
##      and its committed ``repro.lock`` are not workspace markers at this
##      tier — so the walk passes through it to the workspace above. A member
##      repo that commits a ``repro-workspace.toml`` of its own has, by §6,
##      made itself a nested workspace root.
##      A candidate lying INSIDE the ``.repro/`` of an ancestor that is itself
##      marked is skipped: that is the ancestor's state (its manifest-layer
##      checkouts carry ``projects/`` and would otherwise look like a
##      workspace), never a workspace of its own.
##   3. Only when no ancestor carries a marker above: the nearest ancestor
##      carrying a committed ``repro.lock`` — the manifest-optional (MO-2)
##      single-repo workspace. It is consulted last because every member repo
##      of a multi-repo workspace carries one too; consulted first it would
##      make each member its own workspace.
##   4. Otherwise there is no workspace root ("").
##
## FINDING the root is not the same as the root being INITIALIZED. A fresh
## clone of a workspace repository is a workspace root by its settings file
## before ``repro workspace init`` / ``enable`` has written any state; the
## verbs that need state (the hooks' gate, ``push``, the prompt) still ask
## ``isInitializedWorkspace`` of the root this module found and stand down when
## it says no.
##
## Dependency-free on purpose (``std/os`` and ``repro_core/paths`` only): the
## flake dev-shell activation in ``repro_dsl_stdlib`` is compiled into
## providers and must not pull in the workspace-manifest library to ask this.

import std/[os, strutils]

import ./paths

const
  SettingsFileName* = "repro-workspace.toml"
    ## The shared settings file (Workspace-Settings-Files.md §3). The file that
    ## makes a directory a workspace root.
  RetiredSettingsFileName* = ".repro-workspace.toml"
    ## The settings file's retired name. Never read; it marks a root only so
    ## that commands refuse there with the remedy (module note).
  StateFileName* = "workspace-state.toml"
    ## The state file under ``.repro/`` (§5).
  RetiredStateFileName* = "workspace.toml"
    ## The state file's retired name under ``.repro/``. Read only by
    ## ``repro health --fix``, which moves it to ``StateFileName``.
  CommittedLockFileName* = "repro.lock"
    ## The committed solved-graph lock — the MO-2 manifest-optional marker.
  WorkspaceConfigEnvVar* = "REPRO_WORKSPACE_CONFIG"
    ## Names the settings file explicitly (§3, §6).

type
  WorkspaceRootMarker* = enum
    ## Which marker made a directory the workspace root.
    wrmNone            ## no workspace root was found
    wrmConfigEnv       ## ``REPRO_WORKSPACE_CONFIG`` names the settings file
    wrmSettingsFile    ## ``repro-workspace.toml``, or a retired settings name
    wrmStateFile       ## ``.repro/workspace-state.toml``, or a retired state name
    wrmManifestCheckout ## a resolved manifest checkout in a ``.repro/`` shell
    wrmCommittedLock   ## MO-2: a committed ``repro.lock`` and nothing above

  WorkspaceRootDiscovery* = object
    root*: string      ## absolute; "" when ``marker == wrmNone``
    marker*: WorkspaceRootMarker

proc exists(path: string): bool =
  fileExists(extendedPath(path))

proc settingsFileIn*(dir: string): string =
  ## The settings file ``dir`` itself holds — ``repro-workspace.toml`` — or
  ## "" when it holds none.
  if dir.len == 0:
    return ""
  let current = dir / SettingsFileName
  if exists(current):
    return current
  ""

proc retiredSettingsFileIn*(dir: string): string =
  ## The RETIRED settings file ``dir`` holds when it holds no current one, or
  ## "". Beside a ``repro-workspace.toml`` the retired file is inert: the
  ## current file governs, and ``repro health`` reports the leftover.
  if dir.len == 0 or settingsFileIn(dir).len > 0:
    return ""
  let retired = dir / RetiredSettingsFileName
  if exists(retired):
    return retired
  ""

proc configuredSettingsFile*(): tuple[set: bool; path: string] =
  ## ``REPRO_WORKSPACE_CONFIG``: whether it is set (non-empty), and the
  ## absolute path it names when that file exists ("" when it does not).
  let value = getEnv(WorkspaceConfigEnvVar)
  if value.len == 0:
    return (false, "")
  let path = absolutePath(value)
  (true, (if exists(path): path else: ""))

proc stateFileIn*(dir: string): string =
  ## The state file ``dir`` records — ``.repro/workspace-state.toml`` — or "".
  ## A pure probe (the reading accessor is ``workspaceTomlPath`` in the
  ## manifest library).
  if dir.len == 0:
    return ""
  let current = dir / ".repro" / StateFileName
  if exists(current):
    return current
  ""

proc retiredStateFileIn*(dir: string): string =
  ## The state file under its RETIRED name when ``dir`` records no current
  ## one, or "". Beside a current state file the retired one is inert.
  if dir.len == 0 or stateFileIn(dir).len > 0:
    return ""
  let retired = dir / ".repro" / RetiredStateFileName
  if exists(retired):
    return retired
  ""

proc firstMembershipManifestPath*(root: string): string =
  ## The first resolved membership manifest ``root`` itself holds -- a
  ## ``projects/*.toml`` or a ``variants/*.toml`` -- or "" when it holds none.
  ## An empty ``projects/``/``variants/`` is NOT a resolved checkout.
  ## Layout-agnostic: the caller decides WHICH directory to ask about.
  ##
  ## It answers with the PATH rather than a yes/no because a diagnostic that
  ## says "manifest data was found here" has to be able to show WHICH file
  ## said so (Interactive-UX-And-Progress.md Principle 2 -- name the specific
  ## thing at fault).
  ##
  ## The scan is ORDERED rather than first-hit, so the file a message names is
  ## the same on every host: ``walkDir`` yields in directory order, which is
  ## the filesystem's business and not a fact a diagnostic should depend on.
  if root.len == 0:
    return ""
  for sub in ["projects", "variants"]:
    let dir = root / sub
    if dirExists(dir):
      var earliest = ""
      for kind, path in walkDir(dir):
        if kind == pcFile and path.endsWith(".toml") and
            (earliest.len == 0 or path < earliest):
          earliest = path
      if earliest.len > 0:
        return earliest
  ""

proc hasResolvedManifestCheckout*(workspaceRoot: string): bool =
  ## True iff ``workspaceRoot``'s ``.repro/`` SHELL carries at least one
  ## resolved membership manifest (a ``projects/*.toml`` or a
  ## ``variants/*.toml``) — either flat at the root beside that shell, or in
  ## the materialized checkout under ``.repro/manifests`` — and, for the flat
  ## form, the root is not shaped like a lock RECORD STORE (see below).
  ##
  ## THE ``.repro/`` REQUIREMENT ON THE FLAT LAYOUT IS THE POINT. Without it
  ## the LOCK RECORD STORE — the manifests repo itself, which carries
  ## ``projects/``, ``repos/`` and ``locks/`` at its top level — answers
  ## ``true``. It is not a workspace: it holds the membership and lock records
  ## FOR one. Classified as a workspace, the pre-push gate exited 1 in a repo
  ## with nothing to gate, and since store publication is a STAGE of that
  ## gate, that blocked pushes across the whole workspace. A bare clone of the
  ## manifests repo is the same shape and the same non-workspace. The
  ## ``.repro/`` shell is the line, drawn one notch weaker than a state file
  ## because a workspace may resolve from its ``projects/*.toml`` before a
  ## metadata-only state file has been written.
  ##
  ## AND A TOP-LEVEL ``locks/`` TAKES THE FLAT LAYOUT BACK OUT AGAIN — unless
  ## the root records a workspace marker of its own. The shell alone is not a
  ## reliable line, because a record store ACQUIRES one: engines before the
  ## report move filed ``.repro/workspace/post-commit-*`` into it, deleting
  ## those files by hand leaves ``.repro/workspace/`` behind, and any
  ## ``repro`` command run inside the store can create the directory too.
  ## Read as a workspace from then on, every commit there filed its hook
  ## reports into the store's working tree, the lock publisher refused the
  ## store as "dirty outside locks/", and the publisher's own next commit
  ## fired the hook that regenerated the dirt — a self-sustaining wedge on
  ## every push of the workspace. What separates the two shapes is
  ## Workspace-Manifests.md §"Metadata and records are separate
  ## repositories": the metadata repo and the record store are never the
  ## same repository, so a root with membership and ``locks/`` side by side
  ## and NOTHING ELSE claiming it is a workspace is the store.
  ##
  ## "Nothing else" is a settings file or a state file IN THIS ROOT, and the
  ## exemption is checked HERE rather than left to ``workspaceMarkerIn`` /
  ## ``isInitializedWorkspace`` (which do accept those first) because this
  ## predicate is also consulted ALONE: the MO-2 committed-lock fallbacks in
  ## ``resolveWorkspaceProjectShared`` / ``resolveWorkspaceLockedDeps`` and
  ## the pre-push gate read "false" as "resolve membership from
  ## ``repro.lock`` instead". A workspace repo that still carries the legacy
  ## co-located ``locks/`` beside its committed settings file — and so every
  ## fresh clone of one, before ``init`` writes state — must keep resolving
  ## from its manifests there. A record store carries neither file:
  ## it is written by reprobuild alone and holds no workspace settings.
  ##
  ## The test is on the DIRECTORY, not its content: a store that has filed no
  ## record yet is still a store. Git does not keep an empty directory, so a
  ## fresh clone of an EMPTY store has no ``locks/`` — but it has no
  ## ``.repro/`` either, and the shell requirement already excludes it.
  if workspaceRoot.len == 0:
    return false
  # The flat layout: ``projects/``/``repos/`` beside a ``.repro/`` shell, and
  # NOT the record-store shape (membership + ``locks/`` with no workspace
  # marker of the root's own).
  if dirExists(workspaceRoot / ".repro") and
      firstMembershipManifestPath(workspaceRoot).len > 0:
    let recordStoreShape = dirExists(workspaceRoot / "locks") and
      settingsFileIn(workspaceRoot).len == 0 and
      retiredSettingsFileIn(workspaceRoot).len == 0 and
      stateFileIn(workspaceRoot).len == 0 and
      retiredStateFileIn(workspaceRoot).len == 0
    if not recordStoreShape:
      return true
  # The materialized sub-layout: an ``init --manifest-url`` shared-cache
  # symlink, or the git-checkout store backend. Unconditional — the path
  # spells the ``.repro/`` shell itself, so there is nothing to require, and
  # a ``locks/`` inside that checkout is the store the workspace keeps there,
  # which says nothing about whether the ROOT is a workspace.
  firstMembershipManifestPath(workspaceRoot / ".repro" / "manifests").len > 0

proc hasCommittedLockWorkspaceMarker*(workspaceRoot: string): bool =
  ## MO-2 — true iff ``workspaceRoot`` carries a committed ``repro.lock`` (the
  ## MO-1 solved-graph lock) at its root: the manifest-OPTIONAL workspace
  ## marker. An all-public, single-repo workspace whose reproducibility
  ## boundary is the committed lock needs no manifest repo, yet must still
  ## count as an initialized workspace so the managed hooks and the pre-push
  ## gate enforce there too. A project file alone (no committed lock) is
  ## intentionally NOT a marker.
  if workspaceRoot.len == 0:
    return false
  exists(workspaceRoot / CommittedLockFileName)

proc workspaceMarkerIn*(dir: string; settingsCount = true): WorkspaceRootMarker =
  ## The tier-2 marker ``dir`` itself carries (settings file, then state file,
  ## then resolved manifest checkout), or ``wrmNone``. The MO-2 committed lock
  ## is NOT reported here; it is tier 3 and only ``discoverWorkspaceRoot``
  ## decides when it counts. ``settingsCount = false`` disregards settings
  ## files (``REPRO_WORKSPACE_CONFIG`` names a file that does not exist).
  if settingsCount and (settingsFileIn(dir).len > 0 or
      retiredSettingsFileIn(dir).len > 0):
    return wrmSettingsFile
  if stateFileIn(dir).len > 0 or retiredStateFileIn(dir).len > 0:
    return wrmStateFile
  if hasResolvedManifestCheckout(dir):
    return wrmManifestCheckout
  wrmNone

proc selfAndAncestors(startPath: string): seq[string] =
  ## ``startPath`` (absolute) and every directory above it, nearest first.
  if startPath.len == 0:
    return
  var probe = absolutePath(startPath)
  while probe.len > 0:
    result.add(probe)
    let parent = parentDir(probe)
    if parent.len == 0 or parent == probe:
      break
    probe = parent

proc discoverWorkspaceRoot*(startPath: string): WorkspaceRootDiscovery =
  ## The workspace root owning ``startPath``, and the marker that decided it.
  ## See the module note for the precedence; ``wrmNone`` / "" when there is
  ## no workspace root.
  let configured = configuredSettingsFile()
  if configured.path.len > 0:
    return WorkspaceRootDiscovery(root: parentDir(configured.path),
      marker: wrmConfigEnv)
  let settingsCount = not configured.set
  let ancestors = selfAndAncestors(startPath)
  var markers = newSeq[WorkspaceRootMarker](ancestors.len)
  for i, dir in ancestors:
    markers[i] = workspaceMarkerIn(dir, settingsCount)
  for i, candidate in ancestors:
    if markers[i] == wrmNone:
      continue
    # Skip a candidate inside the ``.repro/`` of a MARKED ancestor (a manifest
    # layer checkout such as ``.repro/manifests-public``): it is that
    # ancestor's state, not a workspace.
    var insideAncestorState = false
    for j in i + 1 ..< ancestors.len:
      if markers[j] != wrmNone and
          candidate.startsWith(ancestors[j] / ".repro" & DirSep):
        insideAncestorState = true
        break
    if not insideAncestorState:
      return WorkspaceRootDiscovery(root: candidate, marker: markers[i])
  for candidate in ancestors:
    if hasCommittedLockWorkspaceMarker(candidate):
      return WorkspaceRootDiscovery(root: candidate, marker: wrmCommittedLock)
  WorkspaceRootDiscovery(root: "", marker: wrmNone)

proc findWorkspaceRoot*(startPath: string): string =
  ## ``discoverWorkspaceRoot(startPath).root``.
  discoverWorkspaceRoot(startPath).root
