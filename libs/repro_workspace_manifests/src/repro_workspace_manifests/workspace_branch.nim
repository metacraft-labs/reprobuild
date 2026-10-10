## repro_workspace_manifests/workspace_branch.nim
##
## M13 — Workspace metadata for the active branch.
##
## The active workspace branch is recorded in
## ``<workspaceRoot>/.repro/workspace.toml`` under ``[workspace].branch``.
## The schema is documented in
## ``reprobuild-specs/Workspace-Manifests.md`` §"Workspace Composition
## Layers" — the same TOML the M8 composer reads. The ``branch`` key was
## already reserved on ``WorkspaceBody`` (see ``types.nim``); M13 wires
## up the writer plus a tiny read-only convenience.
##
## Two operating modes:
##
##   1. **Composer mode** — ``.repro/workspace.toml`` already exists with
##      one or more ``[[manifest]]`` entries. The writer validates the file
##      through the M5 strict reader, then edits ``workspace.branch`` in
##      place through ``manifest_editor`` — the declared manifest layers,
##      and any comment in the file, are left exactly as they are.
##
##   2. **Single-project mode** — no ``.repro/workspace.toml`` exists.
##      The writer creates a *metadata-only* workspace.toml carrying
##      ``[workspace] project = "<name>"`` and ``branch = "<name>"`` and
##      no ``[[manifest]]`` entries. Dispatch sites that distinguish
##      composer vs single-project mode use
##      ``isCompositionalWorkspaceToml`` (defined below) rather than the
##      bare ``fileExists`` so a metadata-only file still routes to the
##      M6/M7 single-project resolver.
##
## Every write goes through ``manifest_editor``: a new file is rendered from
## the typed ``WorkspaceLocal`` (``workspaceStateText``), an existing one is
## edited key by key (``applyWorkspaceState``). The writers are idempotent:
## re-running with the same values leaves the file byte-identical.

import std/[options, os, strutils]

import types
import diagnostics
import reader
import manifest_editor

# ---- helpers --------------------------------------------------------------

proc workspaceTomlPath*(workspaceRoot: string): string =
  ## Canonical absolute path of the workspace metadata file
  ## (``<workspaceRoot>/.repro/workspace.toml``). Native layout only — the
  ## legacy Google-``repo`` ``.repo/`` location is not consulted.
  workspaceRoot / ".repro" / "workspace.toml"

proc reproDir*(workspaceRoot: string): string =
  ## Directory where the workspace-local metadata is stored (``.repro``).
  workspaceRoot / ".repro"

proc manifestsRoot*(workspaceRoot: string): string =
  ## Directory containing the workspace's membership manifests (``projects/``
  ## and ``repos/``). Native layout: prefer the flat workspace root (the
  ## ``<org>/repro-workspace`` repo's ``projects/``/``repos/``); fall back to a
  ## materialized manifest checkout under ``.repro/manifests`` — e.g. an
  ## ``init --manifest-url`` shared-cache symlink, or the git-checkout store
  ## backend that also carries membership for the repos it covers. Both are
  ## native ``.repro/`` locations; the legacy ``.repo/`` tree is never consulted.
  if dirExists(workspaceRoot / "projects") or dirExists(workspaceRoot / "repos"):
    return workspaceRoot
  let reproManifests = workspaceRoot / ".repro" / "manifests"
  if dirExists(reproManifests / "projects") or dirExists(reproManifests / "repos"):
    return reproManifests
  workspaceRoot

# ---- reader ---------------------------------------------------------------

proc isCompositionalWorkspaceToml*(workspaceRoot: string): bool =
  ## True iff a ``.repro/workspace.toml`` exists at ``workspaceRoot`` AND
  ## declares at least one ``[[manifest]]`` layer. CLI dispatch helpers
  ## use this to decide between the M8 composer path and the M6/M7
  ## single-project path: a metadata-only workspace.toml (zero manifest
  ## layers — written by M9 init to record the active branch) routes to
  ## single-project mode because the composer requires manifest layers.
  let path = workspaceTomlPath(workspaceRoot)
  if not fileExists(path):
    return false
  try:
    let local = readWorkspaceLocal(path)
    return local.manifest.len > 0
  except WorkspaceManifestParseError:
    # A malformed workspace.toml is the user's problem; let the caller
    # surface the structured diagnostic when it next tries to parse the
    # file directly. For dispatch purposes, treat the file as "present
    # but unusable" — return false so the caller falls back to
    # single-project mode (which will then either succeed or emit its
    # own missing-project diagnostic).
    return false

proc firstMembershipManifestPath*(root: string): string =
  ## The first resolved membership manifest ``root`` itself holds -- a
  ## ``projects/*.toml`` or a ``variants/*.toml`` -- or "" when it holds none.
  ## An empty ``projects/``/``variants/`` is NOT a resolved checkout.
  ## Layout-agnostic: the caller decides WHICH directory to ask about.
  ##
  ## It answers with the PATH rather than a yes/no because a diagnostic that
  ## says "manifest data was found here" has to be able to show WHICH file
  ## said so (Interactive-UX-And-Progress.md Principle 2 -- name the specific
  ## thing at fault). ``carriesResolvedMembershipManifest`` below is this same
  ## question asked for its emptiness, so the two cannot drift into two rules.
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

proc carriesResolvedMembershipManifest(root: string): bool =
  ## True iff ``root`` itself holds at least one resolved membership manifest
  ## (a ``projects/*.toml`` or a ``variants/*.toml``). An empty
  ## ``projects/``/``variants/`` is NOT a resolved checkout. Layout-agnostic:
  ## the caller decides WHICH directory to ask about.
  firstMembershipManifestPath(root).len > 0

proc hasResolvedManifestCheckout*(workspaceRoot: string): bool =
  ## True iff ``workspaceRoot``'s ``.repro/`` SHELL carries at least one
  ## resolved membership manifest (a ``projects/*.toml`` or a
  ## ``variants/*.toml``) — either flat at the root beside that shell, or in
  ## the materialized checkout under ``.repro/manifests``. An empty
  ## ``projects/``/``variants/`` is NOT a resolved checkout.
  ##
  ## THE ``.repro/`` REQUIREMENT ON THE FLAT LAYOUT IS THE POINT, and it is
  ## the invariant ``isInitializedWorkspace`` below has always DOCUMENTED —
  ## "a directory counts as an initialized workspace only when its
  ## ``.repro/`` shell carries a resolved manifest checkout". The
  ## implementation lost it for the flat layout by asking ``manifestsRoot``,
  ## whose first clause is a bare ``dirExists(<root>/projects)``.
  ##
  ## What that admitted is the LOCK RECORD STORE — the manifests repo
  ## itself. It carries ``projects/``, ``repos/`` and ``locks/`` at its top
  ## level, so it answered this predicate with ``true``, and with it
  ## ``isInitializedWorkspace``. It is not a workspace: it holds the
  ## membership and lock records FOR one. Classified as a workspace it fell
  ## into a gap nothing covers — every "not a workspace" guard skipped, the
  ## MO-2 committed-lock fallback skipped too (it is gated on the negation of
  ## this predicate), no project nameable, and the resolver raising. The
  ## pre-push gate then exited 1 in a repo with nothing to gate, and since
  ## store publication is a STAGE of that gate, that blocked pushes across
  ## the whole workspace. A bare clone of the manifests repo is the same
  ## shape and the same non-workspace.
  ##
  ## ``.repro/`` is the marker that separates the two, and it is the one
  ## every workspace has: it is where ``workspace.toml``, the durable
  ## workspace state and the build tree live. ``hooks ensure``'s repo
  ## enumerator already draws exactly this line, and says so in its own note
  ## — "this, and NOT 'the directory happens to hold ``projects/`` and
  ## ``repos/``', is what separates a workspace root from the manifest lock
  ## backend". It draws the line at ``.repro/workspace.toml``; this predicate
  ## draws it one notch weaker, at the ``.repro/`` shell, because it must
  ## still say ``true`` for a workspace that resolves from its
  ## ``projects/*.toml`` before a metadata-only ``workspace.toml`` has been
  ## written (the case the RA-10 hook guards call out by name). Every
  ## directory that satisfies the stricter rule satisfies this one.
  ##
  ## ``manifestsRoot`` is deliberately NOT changed to match. It answers
  ## "given a root that IS a workspace, where does its membership live?" —
  ## a question whose answer for the flat native-root layout must stay the
  ## root itself, and whose callers have already decided they are looking at
  ## a workspace. The two can therefore disagree about a bare manifests
  ## clone, and that disagreement is harmless: a verb that reaches
  ## ``manifestsRoot`` there still refuses for the reason it always did (no
  ## project can be named), it just no longer does so from inside a hook
  ## that had already promised not to block.
  if workspaceRoot.len == 0:
    return false
  # The flat layout: ``projects/``/``repos/`` beside a ``.repro/`` shell.
  if dirExists(workspaceRoot / ".repro") and
      carriesResolvedMembershipManifest(workspaceRoot):
    return true
  # The materialized sub-layout: an ``init --manifest-url`` shared-cache
  # symlink, or the git-checkout store backend. Unconditional — the path
  # spells the ``.repro/`` shell itself, so there is nothing to require.
  carriesResolvedMembershipManifest(workspaceRoot / ".repro" / "manifests")

proc standaloneMembershipManifestCheckout*(workspaceRoot: string): string =
  ## "" unless ``workspaceRoot`` IS a membership-manifest checkout rather than
  ## a workspace that HAS one -- a standalone or bare clone of the manifests
  ## repo, which is to say the LOCK RECORD STORE. Otherwise the path of the
  ## manifest file that proves it, so a diagnostic can name the evidence
  ## instead of asserting the conclusion.
  ##
  ## The line is the ``.repro/`` SHELL, exactly the line
  ## ``hasResolvedManifestCheckout`` above draws and for the reason its note
  ## gives: membership at the top level BESIDE a ``.repro/`` is a workspace
  ## resolving from its own ``projects/*.toml`` before any ``workspace.toml``
  ## was written; membership at the top level with NO ``.repro/`` at all is
  ## the store that describes a workspace living somewhere else. In every
  ## other respect the two are the same directory listing.
  ##
  ## NOTE WHICH WAY ROUND THIS IS, because the obvious reading is the wrong
  ## one. ``hasResolvedManifestCheckout`` answers TRUE for the metadata-less
  ## workspace and FALSE for the bare store, so this is not "that predicate
  ## plus a detail" -- over the roots that carry membership at all it is very
  ## nearly its negation. A caller that keys a "this is not a workspace"
  ## verdict on ``hasResolvedManifestCheckout`` being TRUE says it of real
  ## workspaces, and the migrated-workspace fixtures are exactly those.
  ##
  ## DISCLOSED LIMIT: a record store that has acquired a ``.repro/`` directory
  ## -- from a tool that wrote state into it -- reads as the metadata-less
  ## workspace and gets the generic diagnostic back. That is the same
  ## ambiguity ``hasResolvedManifestCheckout`` accepts, and the managed hooks
  ## are what keep it theoretical: RA-10 Part 4 asserts that no hook ever
  ## manufactures a ``.repro/`` inside the store.
  if workspaceRoot.len == 0:
    return ""
  if dirExists(workspaceRoot / ".repro"):
    return ""
  firstMembershipManifestPath(workspaceRoot)

const committedLockFileName = "repro.lock"
  ## Workspace-Manifest-Optional MO-2 — the committed solved-graph lock
  ## filename. Mirrors ``repro_lock.CommittedLockFileName`` /
  ## ``repro_cli_support.CommittedLockFileName``; duplicated here as a
  ## stable filename convention so ``repro_workspace_manifests`` does not
  ## acquire an upward dependency on the CLI / lock modules.

proc hasCommittedLockWorkspaceMarker*(workspaceRoot: string): bool =
  ## MO-2 — true iff ``workspaceRoot`` carries a committed ``repro.lock``
  ## (the MO-1 solved-graph lock) at its root. This is the manifest-OPTIONAL
  ## workspace marker: an all-public, single-repo workspace whose
  ## reproducibility boundary is the committed lock needs no manifest repo,
  ## yet must still count as an initialized workspace so the managed hooks
  ## and the pre-push gate enforce there too. A project file alone (no
  ## committed lock) is intentionally NOT a marker — the committed lock is
  ## the reproducibility boundary the manifest-optional model leans on, so
  ## ``repro lock refresh`` establishes it first.
  if workspaceRoot.len == 0:
    return false
  fileExists(workspaceRoot / committedLockFileName)

proc isInitializedWorkspace*(workspaceRoot: string): bool =
  ## RA-10 canonical "initialized workspace" marker. A directory counts
  ## as an initialized workspace only when its ``.repro/`` shell carries a
  ## *resolved manifest checkout* — NOT merely a bare
  ## ``.repro/`` directory left behind by a half-finished bootstrap — OR
  ## (MO-2) when it carries a committed ``repro.lock`` (the manifest-
  ## optional reproducibility artifact).
  ##
  ## Concretely, the marker is present when ANY of:
  ##
  ##   * ``<workspaceRoot>/.repro/workspace.toml`` exists (the metadata
  ##     file ``repro workspace init`` writes once the workspace shell is
  ##     established — single-project or compositional), OR
  ##   * (MO-2) ``<workspaceRoot>/repro.lock`` exists — a committed-lock-
  ##     only repo with no manifest repo is a manifest-optional workspace,
  ##     so the hooks/gate must enforce there too.
  ##
  ## A bare ``.repro/`` with none of those is treated
  ## as "not an initialized workspace": the shared predicate the hook
  ## bodies and any init-skip logic consult so a managed hook installed
  ## under a half-bootstrapped or non-workspace parent no-ops with
  ## success instead of blocking.
  ##
  ## Neither is the LOCK RECORD STORE — the manifests repo, which carries
  ## ``projects/``, ``repos/`` and ``locks/`` at its top level and neither
  ## marker above. It describes a workspace; it is not one. See
  ## ``hasResolvedManifestCheckout`` for what that misclassification cost.
  if workspaceRoot.len == 0:
    return false
  if fileExists(workspaceTomlPath(workspaceRoot)):
    return true
  if hasResolvedManifestCheckout(workspaceRoot):
    return true
  hasCommittedLockWorkspaceMarker(workspaceRoot)

proc readWorkspaceFeatureStarted*(workspaceRoot: string): bool =
  ## M16 — Return ``true`` iff the workspace metadata records that the
  ## current ``[workspace].branch`` value names a feature branch
  ## the operator deliberately started via
  ## ``repro branch <name> --checkout``. Returns ``false`` when the
  ## file is missing, the key is absent, or the key is present and
  ## ``false``. A malformed workspace.toml propagates as
  ## ``WorkspaceManifestParseError`` so the caller sees the same
  ## diagnostic the M5 reader would have raised.
  let path = workspaceTomlPath(workspaceRoot)
  if not fileExists(path):
    return false
  let local = readWorkspaceLocal(path)
  if local.workspace.feature_started.isSome:
    return local.workspace.feature_started.get()
  false

proc readWorkspaceBranch*(workspaceRoot: string): Option[string] =
  ## Return the workspace's active branch as recorded in
  ## ``.repo/workspace.toml`` under ``[workspace].branch``. Returns
  ## ``none`` when the file is missing, when the field is absent, or
  ## when the field is present but empty. A malformed workspace.toml
  ## propagates as ``WorkspaceManifestParseError`` so the caller sees
  ## the same diagnostic the M5 reader would have raised — this proc
  ## is a thin convenience over ``readWorkspaceLocal``.
  let path = workspaceTomlPath(workspaceRoot)
  if not fileExists(path):
    return none(string)
  let local = readWorkspaceLocal(path)
  if local.workspace.branch.isSome and local.workspace.branch.get().len > 0:
    return some(local.workspace.branch.get())
  none(string)

proc recordWorkspaceState(path: string; local: WorkspaceLocal) =
  ## Write ``local`` to the state file at ``path`` through the manifest
  ## editor: rendered from the typed value when the file is new, edited key
  ## by key when it exists (so a hand-added comment or a manifest layer the
  ## writer does not touch survives).
  if fileExists(path):
    var doc = loadManifestDoc(path)
    discard doc.applyWorkspaceState(local.workspace)
    doc.saveManifestDoc()
  else:
    writeWorkspaceManifestFile(path, workspaceStateText(local))

proc readWorkspaceProjects*(workspaceRoot: string): seq[string] =
  ## RA-6 — return the active PROJECT SET recorded in
  ## ``.repo/workspace.toml``. The set is the ``[workspace] projects``
  ## array when present; otherwise it degrades to the single
  ## ``[workspace] project`` scalar (the single-project steady state).
  ## Returns an empty seq when the file is missing. A malformed
  ## workspace.toml propagates the M5 reader's structured diagnostic.
  let path = workspaceTomlPath(workspaceRoot)
  if not fileExists(path):
    return @[]
  let local = readWorkspaceLocal(path)
  if local.workspace.projects.len > 0:
    return local.workspace.projects
  if local.workspace.project.len > 0:
    return @[local.workspace.project]
  @[]

proc writeWorkspaceProjects*(workspaceRoot: string; projects: seq[string]) =
  ## RA-6 — record the active PROJECT SET in ``.repo/workspace.toml``.
  ##
  ## The FIRST entry of ``projects`` becomes the primary
  ## ``[workspace] project`` (kept non-empty for the M6/M8 resolver and
  ## every existing reader); the full ordered set is stored in the
  ## ``[workspace] projects`` array. Duplicates are folded out preserving
  ## first-seen order so re-adding an already-active project is a no-op.
  ##
  ## When ``.repo/workspace.toml`` already exists the writer reads it
  ## through the strict reader and preserves the branch / manifest layers
  ## / feature-started fields verbatim, replacing only the project set.
  ## Idempotent: re-running with the same set yields a byte-identical file.
  var deduped: seq[string]
  for p in projects:
    if p.len > 0 and p notin deduped:
      deduped.add(p)
  if deduped.len == 0:
    raiseManifestError(workspaceTomlPath(workspaceRoot),
      "workspace.projects", schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "writeWorkspaceProjects refuses to record an empty project set")

  let path = workspaceTomlPath(workspaceRoot)
  createDir(parentDir(path))

  var local: WorkspaceLocal
  if fileExists(path):
    local = readWorkspaceLocal(path)
  else:
    local.schema = schemaWorkspaceLocalV1

  local.workspace.project = deduped[0]
  local.workspace.projects = deduped
  recordWorkspaceState(path, local)

# ---- writer ---------------------------------------------------------------

proc writeWorkspaceBranch*(workspaceRoot, project, branch: string) =
  ## Update ``.repo/workspace.toml`` to record ``branch`` as the
  ## workspace's active branch.
  ##
  ## - If ``.repo/workspace.toml`` already exists, the writer reads
  ##   it through the M5 strict reader, replaces
  ##   ``workspace.branch``, and re-emits the canonical TOML.
  ##   ``project`` is IGNORED when the file already exists — the
  ##   existing project name is authoritative (it was set by the
  ##   composer-mode workspace and changing it would orphan the
  ##   manifest layers).
  ## - If the file does NOT exist, a metadata-only workspace.toml is
  ##   created with ``[workspace] project = "<project>"`` and
  ##   ``branch = "<branch>"`` and no ``[[manifest]]`` entries. This
  ##   is the single-project (M9 init) path. Callers MUST pass a
  ##   non-empty ``project`` in this case; an empty ``project`` plus
  ##   a missing file raises ``WorkspaceManifestParseError`` rather
  ##   than emit a file the strict reader would later reject.
  ##
  ## Idempotent: re-running with the same arguments yields a
  ## byte-identical file (the serializer is deterministic). Empty
  ## ``branch`` clears the field rather than emitting ``branch = ""``.
  if branch.len == 0:
    raiseManifestError(workspaceTomlPath(workspaceRoot),
      "workspace.branch", schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "writeWorkspaceBranch refuses to record an empty branch name")

  let path = workspaceTomlPath(workspaceRoot)
  createDir(parentDir(path))

  var local: WorkspaceLocal
  if fileExists(path):
    local = readWorkspaceLocal(path)
  else:
    if project.len == 0:
      raiseManifestError(path, "workspace.project",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "writeWorkspaceBranch requires a non-empty project when " &
          "creating workspace.toml from scratch (single-project mode)")
    local.schema = schemaWorkspaceLocalV1
    local.workspace.project = project

  local.workspace.branch = some(branch)
  recordWorkspaceState(path, local)

proc writeWorkspaceBranchWithStarted*(workspaceRoot, project, branch: string;
                                     featureStarted: bool) =
  ## M16 variant of ``writeWorkspaceBranch`` that ALSO records the
  ## feature-started mark. ``featureStarted = true`` writes
  ## ``feature_started = true`` under ``[workspace]``; ``false`` clears
  ## the field entirely (by setting the Option to ``none`` so the
  ## serializer omits the key — the steady state for branches that are
  ## NOT feature branches, e.g. ``main``).
  ##
  ## Semantics mirror ``writeWorkspaceBranch``: when the file already
  ## exists in composer mode the existing project and manifest layers
  ## are preserved verbatim; in single-project mode the file is created
  ## from scratch with just the metadata keys. Idempotent: re-running
  ## with the same arguments produces byte-identical output.
  if branch.len == 0:
    raiseManifestError(workspaceTomlPath(workspaceRoot),
      "workspace.branch", schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
      "writeWorkspaceBranchWithStarted refuses to record an empty branch name")

  let path = workspaceTomlPath(workspaceRoot)
  createDir(parentDir(path))

  var local: WorkspaceLocal
  if fileExists(path):
    local = readWorkspaceLocal(path)
  else:
    if project.len == 0:
      raiseManifestError(path, "workspace.project",
        schemaWorkspaceLocalV1, schemaWorkspaceLocalV1,
        "writeWorkspaceBranchWithStarted requires a non-empty project when " &
          "creating workspace.toml from scratch (single-project mode)")
    local.schema = schemaWorkspaceLocalV1
    local.workspace.project = project

  local.workspace.branch = some(branch)
  if featureStarted:
    local.workspace.feature_started = some(true)
  else:
    # Clear the field. The serializer omits absent / false values, so
    # ``none`` keeps the workspace.toml minimal.
    local.workspace.feature_started = none(bool)
  recordWorkspaceState(path, local)
