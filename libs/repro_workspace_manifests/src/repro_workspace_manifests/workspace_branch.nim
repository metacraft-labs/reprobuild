## repro_workspace_manifests/workspace_branch.nim
##
## M13 — Workspace metadata for the active branch, and the per-checkout state
## file it lives in.
##
## The state file is ``<workspaceRoot>/.repro/workspace-state.toml``
## (``reprobuild.workspace.state.v1``, Workspace-Settings-Files.md §5). It
## replaces ``<workspaceRoot>/.repro/workspace.toml``
## (``reprobuild.workspace.local.v1``), which is still READ until the old
## names are retired (§8). The two files carry the same ``[workspace]`` table
## (``project``, ``projects``, ``branch``, ``feature_started``).
##
## **Which file, and what happens to the old one** (§8 step 1 — the rule this
## module implements until ``repro health --fix`` migrates a checkout):
##
##   * READS prefer ``workspace-state.toml`` and fall back to
##     ``workspace.toml`` (``workspaceTomlPath``).
##   * WRITES go to ``workspace-state.toml`` only. The first write in a
##     checkout that has only the old file creates the new one FROM the old
##     one — its text, comments and any ``[[manifest]]`` layers included — with
##     the schema line changed, and then applies the edit. Nothing is lost and
##     nothing is copied twice.
##   * The OLD FILE IS LEFT UNTOUCHED, and once the new file exists THIS
##     repro ignores it: every read stops at the new name.
##
## **The hazard: version skew.** "Ignored" holds only for repro builds that
## know the new name. An OLDER repro (0.2.x, still pinned in places during
## the transition) reads and writes ``.repro/workspace.toml`` and has never
## heard of ``workspace-state.toml``. So in a checkout used by both, the two
## files CAN diverge: the new binary migrates to ``workspace-state.toml`` and
## records ``beta``; the old binary then writes ``gamma`` into
## ``workspace.toml``; each binary now reports a different active set, and
## neither knew. This module cannot prevent that — the old binary is already
## shipped — so it DETECTS it and says so (``workspaceStateSkew``): every
## state read through ``workspaceTomlPath`` reports, on stderr and once per
## process, that an older repro changed a file this one does not read. The
## remedy until ``repro health --fix`` reconciles the two (BR6) is to inspect
## both and remove the stale one.
##
## Detection keys on a SNAPSHOT, not on mtimes: when a write migrates the old
## file it also saves the old file's exact bytes beside it
## (``legacyStateSnapshotPath``). Skew is "both files exist and the old file is
## no longer byte-identical to that snapshot" — or there is no snapshot, which
## means the old file appeared after the new one existed (an older repro
## created it). An mtime comparison was rejected: the new binary's next write
## bumps ``workspace-state.toml`` past the old file's mtime and would hide an
## unreconciled change for good.
##
## Two operating modes:
##
##   1. **Composer mode** — the workspace declares ``[[manifest]]`` layers:
##      in the state file (where ``local.v1`` kept them) or in the settings
##      files (``repro-workspace.toml`` / ``repro-workspace.local.toml``, where
##      they live now). ``effectiveWorkspaceLocal`` merges the two sources.
##
##   2. **Single-project mode** — no layers. The state file is
##      *metadata-only*: ``[workspace] project = "<name>"`` and
##      ``branch = "<name>"``. Dispatch sites that distinguish composer vs
##      single-project mode use ``isCompositionalWorkspaceToml`` rather than a
##      bare ``fileExists`` so a metadata-only file still routes to the M6/M7
##      single-project resolver.
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
import settings
import repro_core/workspace_root

# The marker predicates live with the one workspace-root discovery walk in
# ``repro_core/workspace_root`` (so the dependency-free flake activation can use
# the same walk); re-exported so this module's callers see them unchanged.
export workspace_root.firstMembershipManifestPath,
  workspace_root.hasResolvedManifestCheckout,
  workspace_root.hasCommittedLockWorkspaceMarker,
  workspace_root.discoverWorkspaceRoot, workspace_root.findWorkspaceRoot,
  workspace_root.WorkspaceRootDiscovery, workspace_root.WorkspaceRootMarker

# ---- helpers --------------------------------------------------------------

const
  workspaceStateFileName* = workspace_root.StateFileName
    ## The state file's name under ``.repro/`` (Workspace-Settings-Files.md §5).
  legacyWorkspaceStateFileName* = workspace_root.LegacyStateFileName
    ## The state file's OLD name under ``.repro/``. Read, never written.

proc workspaceStatePath*(workspaceRoot: string): string =
  ## ``<workspaceRoot>/.repro/workspace-state.toml`` — where the state file is
  ## WRITTEN, whether or not it exists yet.
  workspaceRoot / ".repro" / workspaceStateFileName

proc legacyWorkspaceStatePath*(workspaceRoot: string): string =
  ## ``<workspaceRoot>/.repro/workspace.toml`` — the old state file.
  workspaceRoot / ".repro" / legacyWorkspaceStateFileName

proc legacyStateSnapshotPath*(workspaceRoot: string): string =
  ## ``<workspaceRoot>/.repro/workspace.toml.at-migration`` — the old state
  ## file's exact bytes at the moment a write migrated it to the new name.
  ## Never read as state; only compared against the old file to detect an
  ## older repro writing it afterwards (see the module note).
  workspaceRoot / ".repro" / (legacyWorkspaceStateFileName & ".at-migration")

proc workspaceStateSkew*(workspaceRoot: string): string =
  ## A diagnostic when BOTH state files exist and the old one carries changes
  ## this repro does not see — written by an older repro after the migration —
  ## or "" when there is nothing to report. See the module note for the rule.
  let current = workspaceStatePath(workspaceRoot)
  let legacy = legacyWorkspaceStatePath(workspaceRoot)
  if not (fileExists(current) and fileExists(legacy)):
    return ""
  let snapshot = legacyStateSnapshotPath(workspaceRoot)
  var unseen = true
  try:
    unseen = not fileExists(snapshot) or readFile(snapshot) != readFile(legacy)
  except IOError, OSError:
    unseen = true
  if not unseen:
    return ""
  "warning: two workspace state files exist: " & current & " (read by this " &
    "repro) and " & legacy & " (read and written by older repro builds). " &
    "An older repro has changed " & legacy & " since this repro last " &
    "migrated it, so the active project set, branch or feature mark it " &
    "recorded is NOT seen here, and each repro now reports a different " &
    "state. `repro health --fix` will reconcile the two once it is " &
    "available; until then inspect both files, keep the right content in " &
    current & ", and remove " & legacy & "."

var printedNotices {.threadvar.}: seq[string]
  ## Notices this process already printed. A notice is about the checkout, not
  ## about each of the many state reads one command does, so each prints once.
var noticedRoots {.threadvar.}: seq[string]
  ## Workspace roots whose notices (``reportWorkspaceNotices``) were computed.

var noticesSuppressed {.threadvar.}: bool
  ## Set by ``withoutWorkspaceNotices`` for the extent of a quiet path.

template withoutWorkspaceNotices*(body: untyped) =
  ## Run ``body`` with workspace notices (state-file skew, skipped settings
  ## layers) neither computed nor printed. For read-only paths whose contract
  ## forbids output they did not ask for and work beyond cheap reads — the
  ## shell prompt above all (CLI/prompt.md: silent when there is nothing to
  ## show, cheap reads only on every render). The notices are a property of the
  ## checkout that every OTHER verb reports; a path that must stay quiet opts
  ## out here, once, instead of every state read on its way having to know.
  let previous = noticesSuppressed
  noticesSuppressed = true
  try:
    body
  finally:
    noticesSuppressed = previous

proc emitWorkspaceNotice(message: string) =
  ## The one writer of workspace notices to stderr, de-duplicated per process
  ## and silent inside ``withoutWorkspaceNotices``.
  if noticesSuppressed or message.len == 0 or message in printedNotices:
    return
  printedNotices.add(message)
  try:
    stderr.writeLine("repro: " & message)
  except IOError:
    discard

proc reportSkippedSettingsLayers*(skipped: seq[SkippedSettingsLayer]) =
  ## Report each skipped settings layer on stderr — the report §4 requires
  ## ("reported and skipped"). De-duplicated with every other notice, so a
  ## path that reports explicitly and the state-read hook below never print
  ## one skip twice.
  for note in skipped:
    emitWorkspaceNotice("note: " & note.message)

proc reportWorkspaceNotices(workspaceRoot: string) =
  ## Everything a command must say about a workspace whatever it goes on to do,
  ## computed once per root per process:
  ##
  ##   * state-file version skew (``workspaceStateSkew``);
  ##   * settings layers skipped for want of a url (Workspace-Settings-Files.md
  ##     §4). This must be said even when EVERY layer is skipped — and then the
  ##     workspace resolves as a single project and never reaches the composer
  ##     — so it cannot live on the composer path; it lives here, on the state
  ##     read every workspace-resolving path makes.
  ##
  ## A settings file that does not parse is NOT reported here: the path that
  ## reads it for its own purpose raises the strict reader's diagnostic.
  ##
  ## Inside ``withoutWorkspaceNotices`` nothing is computed (the settings file
  ## is not even read) and the root is not marked as reported.
  if noticesSuppressed:
    return
  let key = absolutePath(workspaceRoot)
  if key in noticedRoots:
    return
  noticedRoots.add(key)
  emitWorkspaceNotice(workspaceStateSkew(workspaceRoot))
  try:
    let settingsPath = findWorkspaceSettingsPath(workspaceRoot)
    if settingsPath.len > 0:
      reportSkippedSettingsLayers(
        composeSettingsLayers(readWorkspaceSettings(settingsPath)).skipped)
  except CatchableError:
    discard

proc isSettingsMarkedRoot(dir: string): bool =
  ## Whether ``dir`` is a workspace root by a settings file (§6): it holds one,
  ## or ``REPRO_WORKSPACE_CONFIG`` names one in it.
  if dir.len == 0:
    return false
  let configured = configuredSettingsFile()
  if configured.set:
    return configured.path.len > 0 and
      cmpPaths(parentDir(configured.path), absolutePath(dir)) == 0
  settingsFileIn(dir).len > 0

proc workspaceTomlPath*(workspaceRoot: string): string =
  ## The state file to READ: ``.repro/workspace-state.toml`` when it exists,
  ## else the old ``.repro/workspace.toml`` when THAT exists, else the new name
  ## (so ``fileExists(workspaceTomlPath(root))`` answers "does this checkout
  ## record any state", and a caller that goes on to create the file creates
  ## it under the new name). Native layout only — the legacy Google-``repo``
  ## ``.repo/`` location is not consulted.
  ##
  ## Every state read resolves its file here, so this is also where the
  ## workspace notices are reported (``reportWorkspaceNotices``: state-file
  ## skew, skipped settings layers) — when the checkout records state, AND
  ## when it records none but is a workspace root by its settings file
  ## (Workspace-Settings-Files.md §6: the file in the directory itself, or the
  ## file ``REPRO_WORKSPACE_CONFIG`` names in it). The settings layers of §4
  ## exist before ``repro workspace init`` / ``enable`` has written any state,
  ## so a skipped one is reported then too. Probing any other directory
  ## reports nothing.
  let current = workspaceStatePath(workspaceRoot)
  if fileExists(current):
    reportWorkspaceNotices(workspaceRoot)
    return current
  let legacy = legacyWorkspaceStatePath(workspaceRoot)
  if fileExists(legacy):
    reportWorkspaceNotices(workspaceRoot)
    return legacy
  if isSettingsMarkedRoot(workspaceRoot):
    reportWorkspaceNotices(workspaceRoot)
  current

proc hasWorkspaceStateFile*(workspaceRoot: string): bool =
  ## Whether the checkout records any state, under either name.
  fileExists(workspaceTomlPath(workspaceRoot))

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

type
  EffectiveWorkspaceLocal* = object
    ## The state file's content with the layer list the workspace actually
    ## composes, and the settings layers that were skipped (§4: a shared named
    ## layer nobody supplied a url for is reported, not an error).
    local*: WorkspaceLocal
    skipped*: seq[SkippedSettingsLayer]

proc withSettingsLayers*(local: WorkspaceLocal;
                         workspaceRoot: string): EffectiveWorkspaceLocal =
  ## Add the settings files' ``[[manifest]]`` layers to a state file's layer
  ## list — the two sources of layers during the transition:
  ##
  ##   * the STATE file's own list (``local.v1`` kept layers there), used
  ##     exactly as before when present;
  ##   * the SETTINGS files' layers (Workspace-Settings-Files.md §3–§4),
  ##     resolved by ``composeSettingsLayers`` and composed AFTER the base.
  ##
  ## The base is the state file's list when it has one, else the root
  ## repository itself (§3: "The root repo is always the base layer"),
  ## contributed as a ``local_path`` layer over ``manifestsRoot`` with the
  ## ``public`` visibility a single-project workspace's repos already carry,
  ## and named ``workspaceRootLayerName`` so the refresh pass can tell it from
  ## a declared layer. A workspace whose settings declare no layer gets back
  ## exactly the state file it passed in.
  result.local = local
  let settingsPath = findWorkspaceSettingsPath(workspaceRoot)
  if settingsPath.len == 0:
    return
  let composed = composeSettingsLayers(readWorkspaceSettings(settingsPath))
  result.skipped = composed.skipped
  if composed.layers.len == 0:
    return
  if result.local.manifest.len == 0:
    var rootRel = relativePath(manifestsRoot(workspaceRoot), workspaceRoot)
    if rootRel.len == 0:
      rootRel = "."
    result.local.manifest.add(ManifestLayer(from_settings: some(true),
      local_path: some(rootRel),
      visibility: "public", name: some(workspaceRootLayerName)))
  result.local.manifest.add(composed.layers)

proc readWorkspaceStateOrEmpty*(workspaceRoot: string): WorkspaceLocal =
  ## The state file's content (``workspaceTomlPath``), or an empty ``state.v1``
  ## record when the checkout records no state yet — a workspace root before
  ## ``repro workspace init`` / ``enable`` ran, whose settings files may
  ## already declare layers (Workspace-Settings-Files.md §4 composes them
  ## "the root repository, then the shared file's ``[[manifest]]`` entries",
  ## with no state file in that sentence). A malformed state file still raises
  ## the strict reader's diagnostic.
  let path = workspaceTomlPath(workspaceRoot)
  if fileExists(path):
    return readWorkspaceLocal(absolutePath(path))
  WorkspaceLocal(schema: schemaWorkspaceStateV1)

proc effectiveWorkspaceLocalWithNotes*(workspaceRoot: string;
                                       projectName = ""):
    EffectiveWorkspaceLocal =
  ## The workspace's state (``readWorkspaceStateOrEmpty``) with the layer list
  ## it composes (``withSettingsLayers``) — THE one place the two layer
  ## sources meet, whether or not a state file exists. ``projectName`` selects
  ## the project to compose when the state records none (no state file yet,
  ## or a state file without ``[workspace] project``); a project the state
  ## records is never overridden here, so a checkout with state composes
  ## exactly what it did before. Raises the strict reader's diagnostic when
  ## the state file or a settings file is malformed.
  result = withSettingsLayers(readWorkspaceStateOrEmpty(workspaceRoot),
    workspaceRoot)
  if result.local.workspace.project.len == 0 and projectName.len > 0:
    result.local.workspace.project = projectName

proc effectiveWorkspaceLocal*(workspaceRoot: string;
                              projectName = ""): WorkspaceLocal =
  ## ``effectiveWorkspaceLocalWithNotes``, reporting skipped layers on stderr.
  let eff = effectiveWorkspaceLocalWithNotes(workspaceRoot, projectName)
  reportSkippedSettingsLayers(eff.skipped)
  eff.local

proc isCompositionalWorkspaceToml*(workspaceRoot: string;
                                   projectName = ""): bool =
  ## True iff the workspace composes at least one ``[[manifest]]`` layer —
  ## from the state file or from the settings files (``withSettingsLayers``)
  ## — and the composer has a project to select. CLI dispatch helpers use this
  ## to decide between the M8 composer path and the M6/M7 single-project path:
  ## a workspace with no layers anywhere routes to single-project mode because
  ## the composer requires layers.
  ##
  ##   * The checkout records state (either state-file name): any layer
  ##     decides, exactly as before — the project is the state's own.
  ##   * It records none (a workspace root before ``init`` / ``enable``): the
  ##     settings layers still compose (Workspace-Settings-Files.md §4), when
  ##     the caller names the project (``projectName``, a ``<project>``
  ##     argument). With no project named there is nothing to compose, and the
  ##     caller's single-project ladder reports that as it always did.
  ##
  ## Callers that answer ``true`` compose through ``effectiveWorkspaceLocal``
  ## / ``composeWorkspaceLayers`` with the same ``projectName``.
  let path = workspaceTomlPath(workspaceRoot)
  if not fileExists(path):
    if projectName.len == 0:
      return false
    try:
      return withSettingsLayers(WorkspaceLocal(schema: schemaWorkspaceStateV1),
        workspaceRoot).local.manifest.len > 0
    except WorkspaceManifestParseError:
      return false
  try:
    let local = readWorkspaceLocal(path)
    if local.manifest.len > 0:
      return true
    return withSettingsLayers(local, workspaceRoot).local.manifest.len > 0
  except WorkspaceManifestParseError:
    # A malformed state or settings file is the user's problem; let the
    # caller surface the structured diagnostic when it next tries to parse
    # the file directly. For dispatch purposes, treat it as "present but
    # unusable" — return false so the caller falls back to single-project
    # mode (which will then either succeed or emit its own diagnostic).
    return false

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
  ##   * a state file exists — ``.repro/workspace-state.toml`` or the old
  ##     ``.repro/workspace.toml`` (the metadata file ``repro workspace
  ##     init`` writes once the workspace shell is established —
  ##     single-project or compositional), OR
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
  ## the state file under ``[workspace].branch``. Returns
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

proc recordWorkspaceState(workspaceRoot: string; local: WorkspaceLocal) =
  ## Write ``local`` to the state file through the manifest editor, ALWAYS
  ## under the new name (``workspaceStatePath``). See the module note for the
  ## rule; in short:
  ##
  ##   * the new file exists — edit it key by key (a hand-added comment or a
  ##     carried-over manifest layer survives);
  ##   * only the old file exists — start the new file from the old file's
  ##     text, re-labelled ``state.v1``, and edit that; the old file is not
  ##     written, its bytes are snapshotted (``legacyStateSnapshotPath``), and
  ##     this repro ignores it from now on because reads stop at the new name
  ##     — an OLDER repro does not, which the snapshot lets us report;
  ##   * neither exists — render a new file from the typed value.
  let target = workspaceStatePath(workspaceRoot)
  let legacy = legacyWorkspaceStatePath(workspaceRoot)
  if fileExists(target) or fileExists(legacy):
    var doc = loadManifestDoc(if fileExists(target): target else: legacy)
    let migrating = doc.path != target
    if migrating:
      # Remember exactly what was migrated, so a later write to the old file
      # by an older repro is detectable (``workspaceStateSkew``).
      writeWorkspaceManifestFile(legacyStateSnapshotPath(workspaceRoot),
        readFile(legacy))
    doc.path = target
    discard doc.setKey("", "schema", tomlStr(schemaWorkspaceStateV1))
    discard doc.applyWorkspaceState(local.workspace)
    if migrating:
      doc.changed = true
    doc.saveManifestDoc()
  else:
    var fresh = local
    fresh.schema = schemaWorkspaceStateV1
    writeWorkspaceManifestFile(target, workspaceStateText(fresh))

proc readWorkspaceProjects*(workspaceRoot: string): seq[string] =
  ## RA-6 — return the active PROJECT SET recorded in
  ## the state file. The set is the ``[workspace] projects``
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
  ## RA-6 — record the active PROJECT SET in the state file.
  ##
  ## The FIRST entry of ``projects`` becomes the primary
  ## ``[workspace] project`` (kept non-empty for the M6/M8 resolver and
  ## every existing reader); the full ordered set is stored in the
  ## ``[workspace] projects`` array. Duplicates are folded out preserving
  ## first-seen order so re-adding an already-active project is a no-op.
  ##
  ## When the state file already exists the writer reads it
  ## through the strict reader and preserves the branch / manifest layers
  ## / feature-started fields verbatim, replacing only the project set.
  ## Idempotent: re-running with the same set yields a byte-identical file.
  var deduped: seq[string]
  for p in projects:
    if p.len > 0 and p notin deduped:
      deduped.add(p)
  if deduped.len == 0:
    raiseManifestError(workspaceTomlPath(workspaceRoot),
      "workspace.projects", schemaWorkspaceStateV1, schemaWorkspaceStateV1,
      "writeWorkspaceProjects refuses to record an empty project set")

  let path = workspaceTomlPath(workspaceRoot)

  var local: WorkspaceLocal
  if fileExists(path):
    local = readWorkspaceLocal(path)
  local.schema = schemaWorkspaceStateV1

  local.workspace.project = deduped[0]
  local.workspace.projects = deduped
  recordWorkspaceState(workspaceRoot, local)

# ---- writer ---------------------------------------------------------------

proc writeWorkspaceBranch*(workspaceRoot, project, branch: string) =
  ## Update the state file to record ``branch`` as the
  ## workspace's active branch.
  ##
  ## - If the state file already exists, the writer reads
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
      "workspace.branch", schemaWorkspaceStateV1, schemaWorkspaceStateV1,
      "writeWorkspaceBranch refuses to record an empty branch name")

  let path = workspaceTomlPath(workspaceRoot)

  var local: WorkspaceLocal
  if fileExists(path):
    local = readWorkspaceLocal(path)
  else:
    if project.len == 0:
      raiseManifestError(path, "workspace.project",
        schemaWorkspaceStateV1, schemaWorkspaceStateV1,
        "writeWorkspaceBranch requires a non-empty project when " &
          "creating the state file from scratch (single-project mode)")
    local.schema = schemaWorkspaceStateV1
    local.workspace.project = project

  local.workspace.branch = some(branch)
  recordWorkspaceState(workspaceRoot, local)

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
      "workspace.branch", schemaWorkspaceStateV1, schemaWorkspaceStateV1,
      "writeWorkspaceBranchWithStarted refuses to record an empty branch name")

  let path = workspaceTomlPath(workspaceRoot)

  var local: WorkspaceLocal
  if fileExists(path):
    local = readWorkspaceLocal(path)
  else:
    if project.len == 0:
      raiseManifestError(path, "workspace.project",
        schemaWorkspaceStateV1, schemaWorkspaceStateV1,
        "writeWorkspaceBranchWithStarted requires a non-empty project when " &
          "creating the state file from scratch (single-project mode)")
    local.schema = schemaWorkspaceStateV1
    local.workspace.project = project

  local.workspace.branch = some(branch)
  if featureStarted:
    local.workspace.feature_started = some(true)
  else:
    # Clear the field. The serializer omits absent / false values, so
    # ``none`` keeps the workspace.toml minimal.
    local.workspace.feature_started = none(bool)
  recordWorkspaceState(workspaceRoot, local)
