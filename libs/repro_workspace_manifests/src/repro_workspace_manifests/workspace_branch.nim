## repro_workspace_manifests/workspace_branch.nim
##
## M13 — Workspace metadata for the active branch, and the per-checkout state
## file it lives in.
##
## The state file is ``<workspaceRoot>/.repro/workspace-state.toml``
## (``reprobuild.workspace.state.v1``, Workspace-Settings-Files.md §5): the
## ``[workspace]`` table (``project``, ``projects``, ``branch``,
## ``feature_started``) and nothing else.
##
## **The state file's retired name.** No verb reads or writes the state file
## under its retired name (``retired_names.nim``). A checkout that records its
## state ONLY there is refused with the remedy (``workspaceTomlPath``):
## reading it as "no state" would silently forget the active project set and
## branch. The one reader of the retired file is ``repro health --fix``
## (``migrateWorkspaceStateFile``), which moves it to the current name and its
## ``[[manifest]]`` layers to ``repro-workspace.local.toml`` (§8 step 2). A
## retired file left over BESIDE a current one is inert: every read stops at
## the current name, and ``repro health`` reports the leftover, which
## ``--fix`` removes when it records nothing the current file lacks (it
## compares against the migration snapshot an earlier release saved,
## ``retiredStateSnapshotPath``, and refuses to choose between two diverged
## records — ``workspaceStateSkew``).
##
## Two operating modes:
##
##   1. **Composer mode** — the settings files (``repro-workspace.toml`` /
##      ``repro-workspace.local.toml``) declare ``[[manifest]]`` layers.
##      ``effectiveWorkspaceLocal`` adds them to the state.
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
import retired_names
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
  retiredWorkspaceStateFileName* = workspace_root.RetiredStateFileName
    ## The state file's retired name under ``.repro/``. Read only by
    ## ``repro health --fix`` (``migrateWorkspaceStateFile``).

proc workspaceStatePath*(workspaceRoot: string): string =
  ## ``<workspaceRoot>/.repro/workspace-state.toml`` — where the state file is
  ## WRITTEN, whether or not it exists yet.
  workspaceRoot / ".repro" / workspaceStateFileName

proc retiredWorkspaceStatePath*(workspaceRoot: string): string =
  ## The state file under its retired name (``retiredWorkspaceStateFileName``).
  workspaceRoot / ".repro" / retiredWorkspaceStateFileName

proc retiredStateSnapshotPath*(workspaceRoot: string): string =
  ## The retired state file's exact bytes as an earlier release saved them
  ## when it migrated that file to the current name (``.at-migration``
  ## beside it). Never read as state; only compared against a left-over
  ## retired file, to tell whether an older repro wrote it afterwards (see
  ## the module note).
  workspaceRoot / ".repro" / (retiredWorkspaceStateFileName & ".at-migration")

proc workspaceStateSkew*(workspaceRoot: string): string =
  ## A diagnostic when BOTH state files exist and the retired one carries
  ## changes the current one does not — written by an older repro after the
  ## migration — or "" when there is nothing to report. For ``repro health``,
  ## which must not delete such a file; see the module note for the rule.
  let current = workspaceStatePath(workspaceRoot)
  let legacy = retiredWorkspaceStatePath(workspaceRoot)
  if not (fileExists(current) and fileExists(legacy)):
    return ""
  let snapshot = retiredStateSnapshotPath(workspaceRoot)
  var unseen = true
  try:
    unseen = not fileExists(snapshot) or readFile(snapshot) != readFile(legacy)
  except IOError, OSError:
    unseen = true
  if not unseen:
    return ""
  "two workspace state files exist: " & current & " (the state file) and " &
    legacy & " (its retired name, read and written only by older repro " &
    "builds). An older repro has changed " & legacy & " since it was " &
    "migrated, so the active project set, branch or feature mark it " &
    "recorded is NOT the state. Inspect both files, keep the right content " &
    "in " & current & ", and remove " & legacy & "."

var printedNotices {.threadvar.}: seq[string]
  ## Notices this process already printed. A notice is about the checkout, not
  ## about each of the many state reads one command does, so each prints once.
var noticedRoots {.threadvar.}: seq[string]
  ## Workspace roots whose notices (``reportWorkspaceNotices``) were computed.

var noticesSuppressed {.threadvar.}: bool
  ## Set by ``withoutWorkspaceNotices`` for the extent of a quiet path.

template withoutWorkspaceNotices*(body: untyped) =
  ## Run ``body`` with workspace notices (skipped settings layers) neither
  ## computed nor printed. For read-only paths whose contract
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
  ## computed once per root per process: the settings layers skipped for want
  ## of a url (Workspace-Settings-Files.md §4). This must be said even when
  ## EVERY layer is skipped — and then the workspace resolves as a single
  ## project and never reaches the composer — so it cannot live on the
  ## composer path; it lives here, on the state read every workspace-resolving
  ## path makes.
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
  try:
    let settingsPath = findWorkspaceSettingsPath(workspaceRoot)
    if settingsPath.len > 0:
      reportSkippedSettingsLayers(
        composeSettingsLayers(readWorkspaceSettings(settingsPath)).skipped)
  except CatchableError:
    discard

proc layerSettingsFor(workspaceRoot: string): Option[WorkspaceSettings] =
  ## The settings whose ``[[manifest]]`` layers ``workspaceRoot`` composes:
  ## the shared settings file governing it (with its local file beside it),
  ## else a local settings file standing alone at the root
  ## (``readLoneLocalSettings`` — where ``repro health --fix`` puts an old
  ## state file's layers in a workspace that has no shared file). ``none``
  ## when there is neither. A malformed file raises.
  let settingsPath = findWorkspaceSettingsPath(workspaceRoot)
  if settingsPath.len > 0:
    return some(readWorkspaceSettings(settingsPath))
  readLoneLocalSettings(workspaceRoot)

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
  ## The state file, ``.repro/workspace-state.toml``, whether or not it exists
  ## (so ``fileExists(workspaceTomlPath(root))`` answers "does this checkout
  ## record any state", and a caller that goes on to create the file creates
  ## it here). Native layout only — the legacy Google-``repo`` ``.repo/``
  ## location is not consulted.
  ##
  ## A checkout that records its state only under the retired name is
  ## REFUSED here with the remedy (``retired_names.refuseRetiredStateFile``):
  ## answering "no state" would make every verb forget its project set and
  ## branch without a word. Inside ``repro health`` the refusal is set aside
  ## for its ``workspace-state`` row instead, and the answer is "no state".
  ##
  ## Every state read resolves its file here, so this is also where the
  ## workspace notices are reported (``reportWorkspaceNotices``: skipped
  ## settings layers) — when the checkout records state, AND
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
  if refuseRetiredStateFile(workspaceRoot):
    return current
  if isSettingsMarkedRoot(workspaceRoot):
    reportWorkspaceNotices(workspaceRoot)
  current

proc hasWorkspaceStateFile*(workspaceRoot: string): bool =
  ## Whether the checkout records any state.
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
  ## Add the settings files' ``[[manifest]]`` layers
  ## (Workspace-Settings-Files.md §3–§4, resolved by ``composeSettingsLayers``)
  ## to the state, composed AFTER the base.
  ##
  ## The base is a layer list ``local`` already carries (a caller that built
  ## one itself), else the root repository itself (§3: "The root repo is
  ## always the base layer"),
  ## contributed as a ``local_path`` layer over ``manifestsRoot`` with the
  ## ``public`` visibility a single-project workspace's repos already carry,
  ## and named ``workspaceRootLayerName`` so the refresh pass can tell it from
  ## a declared layer. A workspace whose settings declare no layer gets back
  ## exactly the state file it passed in.
  result.local = local
  var settings: WorkspaceSettings
  try:
    let found = layerSettingsFor(workspaceRoot)
    if found.isNone:
      return
    settings = found.get()
  except WorkspaceManifestParseError as err:
    # Only inside ``toleratingMalformedWorkspaceFiles`` (``repro health``),
    # which reports what it set aside; everywhere else it propagates.
    if not setAsideMalformedWorkspaceFile(err, mwkSettings):
      raise
    return
  let composed = composeSettingsLayers(settings)
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

proc checkWorkspaceSettingsAndState*(workspaceRoot: string) =
  ## Raise the strict reader's ``WorkspaceManifestParseError`` — naming the
  ## file and the key or line — when the state file or a settings file
  ## (``repro-workspace.toml`` / ``repro-workspace.local.toml``) governing
  ## ``workspaceRoot`` EXISTS but does not parse or validate; do nothing when
  ## each either parses or does not exist. For a verb that must refuse before
  ## it writes anything, and that would otherwise reach the files only inside
  ## a step whose other failures it tolerates (``repro workspace enable``
  ## records membership even while the manifests are not reachable yet).
  discard withSettingsLayers(readWorkspaceStateOrEmpty(workspaceRoot),
    workspaceRoot)

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
  ##
  ## A state or settings file that EXISTS but does not parse or validate
  ## raises the strict reader's ``WorkspaceManifestParseError`` (naming the
  ## file and the key) instead of answering ``false``. Answering ``false``
  ## used to route the caller to the single-project ladder, which never reads
  ## the settings files' layers: a typo in ``repro-workspace.toml`` silently
  ## dropped every repo a partner layer adds, with exit 0, and a rejected key
  ## in the state file surfaced as "neither was present" about a file that
  ## was present (Workspace-Settings-Files.md §4: every genuine layer failure
  ## is an error). Only a file that does not exist counts as absent.
  let path = workspaceTomlPath(workspaceRoot)
  if not fileExists(path):
    # The settings files are read (and so validated) even when no project is
    # named, so a malformed one is reported by every verb that asks, not only
    # by the ones that happen to name a project.
    let composes = withSettingsLayers(
      WorkspaceLocal(schema: schemaWorkspaceStateV1),
      workspaceRoot).local.manifest.len > 0
    return composes and projectName.len > 0
  let local = readWorkspaceLocal(path)
  if local.workspace.project.len == 0 and projectName.len == 0:
    # A state file the strict reader accepts always records a project, so
    # this is ``repro health`` reading a malformed one it set aside
    # (``toleratingMalformedWorkspaceFiles``): with no project there is
    # nothing to compose, exactly as with no state file and no project named.
    return false
  if local.manifest.len > 0:
    return true
  withSettingsLayers(local, workspaceRoot).local.manifest.len > 0

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
  ## DISCLOSED LIMIT, NOW NARROWER THAN IT WAS. A record store that has
  ## acquired a ``.repro/`` directory -- the field state: an older engine
  ## filed ``.repro/workspace/post-commit-*`` into it, and deleting those
  ## files leaves the directory -- is no longer CLASSIFIED as a workspace:
  ## ``hasResolvedManifestCheckout`` treats membership beside a top-level
  ## ``locks/``, with no settings or state file in the root, as the store
  ## (Workspace-Manifests.md: metadata and records are never one repository),
  ## so the hooks and the gate stand down there and file nothing. What
  ## remains is only THIS diagnostic's wording: it states that no ``.repro/``
  ## shell sits beside the manifests, so for a store carrying a stray one it
  ## returns "" and the caller gives the generic sentence instead of a false
  ## one. RA-10's stray-shell case asserts the classification half; nothing
  ## reaches this message from a hook any more, only from a verb an operator
  ## runs by hand inside the store.
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
  ##   * a state file exists — ``.repro/workspace-state.toml`` (the metadata
  ##     file ``repro workspace init`` writes once the workspace shell is
  ##     established — single-project or compositional); a state file under
  ##     its retired name is refused with its remedy (``workspaceTomlPath``),
  ##     never read as "not initialized", OR
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
  ## marker above — and that holds even after the store has acquired a stray
  ## ``.repro/`` directory, because ``hasResolvedManifestCheckout`` reads
  ## membership beside a top-level ``locks/`` as the store. It describes a
  ## workspace; it is not one. See ``hasResolvedManifestCheckout`` for what
  ## that misclassification cost.
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

# ---- moving an old state file's layers (§8 step 2) --------------------------

type
  StateMigrationError* = object of CatchableError
    ## A migration step that cannot be taken without guessing — a layer the
    ## local settings file already declares differently, a layer that cannot
    ## live in that file, two state files that disagree. The message names
    ## the files and what to do. Raised BEFORE anything is written.

  LayerMoveOutcome* = object
    ## What ``moveLayersToLocalSettings`` did, one description per layer.
    localPath*: string
      ## The local settings file the layers were moved to.
    added*: seq[string]
      ## Layers appended to it.
    present*: seq[string]
      ## Layers it (or the shared file) already composes identically: not
      ## written twice.
    dropped*: seq[string]
      ## Layers naming the root repository's own manifests, which the root
      ## contributes as the base layer anyway (§3).

proc describeLayer(layer: ManifestLayer): string =
  ## ``url '<u>'`` / ``local_path '<p>'``, with the branch and visibility.
  result =
    if layer.url.isSome: "url '" & layer.url.get() & "'"
    else: "local_path '" & layer.local_path.get("") & "'"
  if layer.branch.isSome:
    result.add(" (branch " & layer.branch.get() & ")")
  result.add(" [" & layer.visibility & "]")

proc layerSourceKey(layer: ManifestLayer; baseDir: string): string =
  ## The identity of a layer's source: its url, or its ``local_path``
  ## resolved against ``baseDir`` (both files resolve it against the
  ## workspace root) and normalized, so ``./m`` and ``m`` are one layer.
  if layer.url.isSome and layer.url.get().len > 0:
    return "url:" & layer.url.get()
  let raw = layer.local_path.get("")
  "path:" & normalizedPath(if isAbsolute(raw): raw else: baseDir / raw)

proc moveLayersToLocalSettings*(workspaceRoot, fromPath: string;
                                layers: seq[ManifestLayer]): LayerMoveOutcome =
  ## Move ``layers`` — the ``[[manifest]]`` list of the old state file
  ## ``fromPath`` — into ``repro-workspace.local.toml`` at ``workspaceRoot``
  ## (Workspace-Settings-Files.md §8 step 2), through the manifest editor:
  ## an existing local file is edited, never rewritten, so its comments and
  ## entries survive; a missing one is created. ``fromPath`` itself is not
  ## touched — the caller removes the layers from it.
  ##
  ## Each layer, in order:
  ##
  ##   * names the root's own manifests (a ``local_path`` resolving to the
  ##     workspace root or its manifest directory) — DROPPED: the root is
  ##     always the base layer (§3), so moving it would compose it twice;
  ##   * the settings files already compose a layer with the same source
  ##     (url, or resolved ``local_path``) and the same branch and
  ##     visibility — PRESENT, not written again (so a repeated migration,
  ##     or one after an earlier release already moved the layers, is a
  ##     no-op);
  ##   * the same source with a different branch or visibility, or supplied
  ##     as the url of a shared named layer — a CONFLICT;
  ##   * a ``local_path`` under ``.repro/`` other than the manifest directory
  ##     — a CONFLICT: §4 forbids it in the local file;
  ##   * otherwise appended (``url`` / ``local_path``, ``branch``,
  ##     ``visibility``).
  ##
  ## A conflict, and a shared settings file that governs the root from an
  ## ANCESTOR directory (a local file at the root would not be read; one
  ## beside the ancestor's file would change that other workspace), raise
  ## ``StateMigrationError`` before anything is written. A layer listed in
  ## the old file kept the M8 rule that it must declare the workspace's
  ## project; once moved it composes additively per project like every
  ## settings-file layer (§4 "Layers are additive per project").
  let root = absolutePath(workspaceRoot)
  result.localPath = root / localSettingsFileName
  if layers.len == 0:
    return
  let sharedPath = findWorkspaceSettingsPath(root)
  if sharedPath.len > 0 and
      cmpPaths(parentDir(absolutePath(sharedPath)), root) != 0:
    raise newException(StateMigrationError,
      fromPath & " carries " & $layers.len & " `[[manifest]]` layer(s), " &
      "but the settings file governing " & root & " is " & sharedPath &
      ", in another directory: a " & localSettingsFileName & " here would " &
      "not be read, and one beside it would add the layers to that " &
      "workspace too. Move the layers by hand into the " &
      localSettingsFileName & " the workspace should read, then remove " &
      "them from " & fromPath)
  # What the settings files compose today, by source.
  var composed: seq[(string, ManifestLayer)]
  var namedSupplies: seq[(string, string)]
  let settings = layerSettingsFor(root)
  if settings.isSome:
    for layer in composeSettingsLayers(settings.get()).layers:
      composed.add((layerSourceKey(layer, root), layer))
    for entry in settings.get().localLayers:
      if entry.name.isSome and entry.url.isSome:
        namedSupplies.add(("url:" & entry.url.get(), entry.name.get()))
  let baseKeys = ["path:" & normalizedPath(root),
                  "path:" & normalizedPath(absolutePath(manifestsRoot(root)))]
  let reproDirPath = normalizedPath(root / ".repro")
  var toAdd: seq[ManifestLayer]
  var conflicts: seq[string]
  for layer in layers:
    let key = layerSourceKey(layer, root)
    if key in baseKeys:
      result.dropped.add(describeLayer(layer))
      continue
    if key.startsWith("path:") and (key == "path:" & reproDirPath or
        key.startsWith("path:" & reproDirPath & DirSep)):
      conflicts.add(describeLayer(layer) & " lies under .repro/, which " &
        localSettingsFileName & " may not name; move that directory " &
        "out of .repro/ and list it by hand")
      continue
    var handled = false
    for (supplied, name) in namedSupplies:
      if supplied == key:
        conflicts.add(describeLayer(layer) & " is already the url " &
          result.localPath & " supplies for the shared layer '" & name & "'")
        handled = true
    for (k, existing) in composed:
      if handled or k != key:
        continue
      handled = true
      if existing.branch == layer.branch and
          existing.visibility == layer.visibility:
        result.present.add(describeLayer(layer))
      else:
        conflicts.add(describeLayer(layer) & " is already composed by the " &
          "settings files as " & describeLayer(existing))
    for queued in toAdd:
      if not handled and layerSourceKey(queued, root) == key:
        handled = true
        if queued.branch == layer.branch and
            queued.visibility == layer.visibility:
          result.present.add(describeLayer(layer))
        else:
          conflicts.add(describeLayer(layer) & " repeats the source of " &
            describeLayer(queued) & " with a different branch or visibility")
    if not handled:
      toAdd.add(layer)
  if conflicts.len > 0:
    raise newException(StateMigrationError,
      "cannot move the `[[manifest]]` layers of " & fromPath & " to " &
      result.localPath & ": " & conflicts.join("; ") & ". Nothing was " &
      "changed. Reconcile the two files by hand — keep the declaration you " &
      "want in " & result.localPath & " and delete the layers from " &
      fromPath & " — then rerun `repro health --fix`")
  if toAdd.len == 0:
    return
  var doc =
    if fileExists(result.localPath): loadManifestDoc(result.localPath)
    else: manifestDocFromText("schema = " &
      tomlQuote(schemaWorkspaceSettingsLocalV1) & "\n", result.localPath)
  for layer in toAdd:
    var fields: seq[TomlEditField]
    if layer.url.isSome:
      fields.add(tomlField("url", tomlStr(layer.url.get())))
    else:
      fields.add(tomlField("local_path", tomlStr(layer.local_path.get())))
    if layer.branch.isSome:
      fields.add(tomlField("branch", tomlStr(layer.branch.get())))
    fields.add(tomlField("visibility", tomlStr(layer.visibility)))
    if doc.ensureArrayTableEntry("manifest", fields):
      result.added.add(describeLayer(layer))
    else:
      result.present.add(describeLayer(layer))
  doc.changed = true
  doc.saveManifestDoc()

# ---- the state file's migration (§8 step 2) ---------------------------------

type
  StateFileFindingKind* = enum
    sffOldNameOnly   ## only the retired name exists
    sffOldLeftover   ## the retired file (or its migration snapshot) is left
                     ## over beside the current one, and holds nothing unseen
    sffSkew          ## both exist and an older repro changed the retired one
    sffLayersInState ## ``[[manifest]]`` layers in ``workspace-state.toml``

  StateFileFinding* = object
    kind*: StateFileFindingKind
    message*: string

proc inspectWorkspaceStateFiles*(workspaceRoot: string): seq[StateFileFinding] =
  ## What ``migrateWorkspaceStateFile`` would have to do in this checkout, in
  ## words — for ``repro health``'s row. Reads raw (``readStateFileForMigration``)
  ## so layers the strict reader refuses are still counted; a file that does
  ## not parse at all is left to the malformed-file row and not reported
  ## here. Empty when the checkout is migrated, or records no state.
  let current = workspaceStatePath(workspaceRoot)
  let legacy = retiredWorkspaceStatePath(workspaceRoot)
  let snapshot = retiredStateSnapshotPath(workspaceRoot)
  proc layerCount(path: string): int =
    try: readStateFileForMigration(path).manifest.len
    except CatchableError: 0
  if fileExists(current):
    let n = layerCount(current)
    if n > 0:
      result.add(StateFileFinding(kind: sffLayersInState, message:
        current & " carries " & $n & " `[[manifest]]` layer(s); the state " &
        "file carries none, so every repro verb refuses it until they are " &
        "moved to " & localSettingsFileName))
    if fileExists(legacy):
      let skew = workspaceStateSkew(workspaceRoot)
      if skew.len > 0:
        result.add(StateFileFinding(kind: sffSkew, message: skew))
      else:
        result.add(StateFileFinding(kind: sffOldLeftover, message:
          "the state file's retired name " & legacy & " is left over " &
          "beside " & current & " and records nothing the state file lacks"))
    elif fileExists(snapshot):
      result.add(StateFileFinding(kind: sffOldLeftover, message:
        "the migration snapshot " & snapshot & " is left over"))
  elif fileExists(legacy):
    let n = layerCount(legacy)
    result.add(StateFileFinding(kind: sffOldNameOnly, message:
      "the state file has its retired name " & legacy &
      (if n > 0: " and carries " & $n & " `[[manifest]]` layer(s) that " &
         "belong in " & localSettingsFileName
       else: "")))

proc migrateWorkspaceStateFile*(workspaceRoot: string): seq[string] =
  ## Bring a checkout's state file to Workspace-Settings-Files.md §5, as
  ## ``repro health --fix`` does (§8 step 2), and return one line per action:
  ##
  ##   * the state file under its retired name is MOVED to
  ##     ``.repro/workspace-state.toml``
  ##     (``state.v1``): its text through the manifest editor — comments and
  ##     the ``[workspace]`` table kept — re-labelled, without its
  ##     ``[[manifest]]`` layers, which go to ``repro-workspace.local.toml``
  ##     (``moveLayersToLocalSettings``). The old file and its migration
  ##     snapshot are removed.
  ##   * layers found in ``workspace-state.toml`` (left there by the release
  ##     that carried an old file's layers across) are moved the same way.
  ##   * an old file left over beside the new one, holding nothing unseen, is
  ##     removed after its layers (if any) are moved — a layer the first state
  ##     write already moved is found present and not written twice.
  ##
  ## Refuses with ``StateMigrationError``, before writing anything, when an
  ## older repro changed the old file after the migration (``sffSkew``): which
  ## of the two records is right is the operator's call, not this one's. A
  ## state file that does not parse raises the strict reader's diagnostic.
  ## Idempotent: a migrated checkout yields no actions.
  let findings = inspectWorkspaceStateFiles(workspaceRoot)
  if findings.len == 0:
    return
  for f in findings:
    if f.kind == sffSkew:
      raise newException(StateMigrationError, f.message &
        " `repro health --fix` does not choose between the two records")
  let current = workspaceStatePath(workspaceRoot)
  let legacy = retiredWorkspaceStatePath(workspaceRoot)
  let snapshot = retiredStateSnapshotPath(workspaceRoot)
  proc report(outcome: LayerMoveOutcome; source: string): seq[string] =
    for d in outcome.added:
      result.add("moved manifest layer " & d & " from " & source & " to " &
        outcome.localPath)
    for d in outcome.present:
      result.add("manifest layer " & d & " of " & source & " is already in " &
        "the settings files; not added twice")
    for d in outcome.dropped:
      result.add("dropped manifest layer " & d & " of " & source & ": it " &
        "names the workspace root's own manifests, the base layer")
    if outcome.added.len > 0:
      result.add("the workspace root is now the base layer, and so the " &
        "lock record store unless repro-workspace.toml declares " &
        "`[records]`; the moved layers compose additively per project. " &
        "If lock records were published to the first layer of the old " &
        "file, declare it as `[records]` in repro-workspace.toml")
  # Read both files first, so a malformed one stops the migration before any
  # file changes. Each layer move checks its conflicts before writing; the
  # one partial outcome is a left-over old file whose layers conflict with
  # layers already moved from the new file — the new file is then migrated,
  # the old one is kept, and a rerun reports the same conflict.
  let legacyLayers =
    if fileExists(legacy): readStateFileForMigration(legacy).manifest
    else: @[]
  let currentLayers =
    if fileExists(current): readStateFileForMigration(current).manifest
    else: @[]
  if fileExists(current):
    if currentLayers.len > 0:
      result.add(report(moveLayersToLocalSettings(workspaceRoot, current,
        currentLayers), current))
      var doc = loadManifestDoc(current)
      discard doc.removeArrayTable("manifest")
      # A file under the current name may still declare the retired schema
      # (it was copied, not re-rendered); without its layers it is exactly a
      # state.v1 file, so it says so.
      discard doc.setKey("", "schema", tomlStr(schemaWorkspaceStateV1))
      doc.saveManifestDoc()
      result.add("removed the `[[manifest]]` layers from " & current)
    if fileExists(legacy):
      if legacyLayers.len > 0:
        result.add(report(moveLayersToLocalSettings(workspaceRoot, legacy,
          legacyLayers), legacy))
      removeFile(legacy)
      result.add("removed the state file's retired name " & legacy & " (" &
        current & " is the state file)")
  else:
    result.add(report(moveLayersToLocalSettings(workspaceRoot, legacy,
      legacyLayers), legacy))
    var doc = loadManifestDoc(legacy)
    doc.path = current
    discard doc.setKey("", "schema", tomlStr(schemaWorkspaceStateV1))
    discard doc.removeArrayTable("manifest")
    doc.changed = true
    doc.saveManifestDoc()
    removeFile(legacy)
    result.add("moved the state file " & legacy & " to " & current &
      " (" & schemaWorkspaceStateV1 & ")")
  if fileExists(snapshot):
    removeFile(snapshot)
    result.add("removed the migration snapshot " & snapshot)

proc recordWorkspaceState(workspaceRoot: string; local: WorkspaceLocal) =
  ## Write ``local`` to the state file through the manifest editor: an
  ## existing file is edited key by key (a hand-added comment survives), a
  ## missing one is rendered from the typed value. Callers read the state
  ## through ``workspaceTomlPath`` first, which refuses a checkout recording
  ## its state only under the retired name, so nothing here can shadow it.
  let target = workspaceStatePath(workspaceRoot)
  if fileExists(target):
    var doc = loadManifestDoc(target)
    discard doc.setKey("", "schema", tomlStr(schemaWorkspaceStateV1))
    discard doc.applyWorkspaceState(local.workspace)
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
  ## through the strict reader and preserves the branch and feature-started
  ## fields verbatim, replacing only the project set.
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
  ##   existing project name is authoritative (the settings files' layers
  ##   compose for it, and changing it would orphan them).
  ## - If the file does NOT exist, a metadata-only state file is
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
  ## exists the existing project is preserved verbatim; otherwise the file
  ## is created
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
