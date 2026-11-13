## The add-on layer over ``repro infra apply``.
##
## On an add-on host every generation is the add-on's own objects (its
## generation-0 set, kept in ``own.profile``) plus the operator's profile.
## This module composes the two, decides for every target what the
## distribution's records allow, works out what left the profile, applies
## the result through ``repro_infra.runInfraApply`` -- the same apply path
## every system-scope host uses -- and records the outcome in the ownership
## ledger.
##
## What the layer adds to a plain infra apply:
##
## - **scope** (spec §4.1, §4.4): a resource kind the add-on does not
##   manage, or an ``/etc`` path outside the profile's declared managed
##   prefixes, is refused with ``EAddOnOutOfScope`` before anything is
##   observed or written.
## - **the collision pass** (spec §4.3): every target is observed through
##   the distribution's collision driver and decided by the table in
##   ``collision.nim``. A refusal (``EAddOnPackageOwned``,
##   ``EAddOnUnitShadows``, ``EDrift``, a link on the path, a foreign
##   diversion) ends the apply before anything is written. The opt-ins
##   change the shape of what is applied: ``collision = divert`` adds the
##   ``linux.dpkgDiversion`` the file depends on, ``collision = dropIn``
##   turns the unit into a drop-in file of the package's unit,
##   ``collision = replace`` lets the /etc unit shadow the package's, and
##   an adoption (an identical unowned object, or ``repro system adopt``)
##   makes the profile ask for exactly the bytes already there so nothing
##   is written and the ledger owns them. The pass runs again before each
##   write (``PreWriteGuard``).
## - **removal by ledger** (spec §4.2). A resource that leaves the profile
##   is removed only when the ledger lists its objects and they still
##   carry the recorded digests. A changed object is left in place and
##   reported as actionable drift (its ledger entry is kept, so the add-on
##   still accounts for it); ``--reconcile-drift`` authorises removing it.
##   An object the ledger does not list is never removed. An adopted,
##   reconciled or replaced file is not deleted but restored from the
##   bytes the ledger preserved.
## - **the objects an apply creates as a side effect**: the parent
##   directories a file needed, the ``.wants`` links and directories
##   ``systemctl enable`` made, the mount a ``.mount`` unit holds, and the
##   package file a diversion moved aside. Each is a ledger entry, so
##   uninstall removes it and the do-no-harm gates can account for it.
## - **the store roots**: after every apply the new generation is registered
##   as a ``profile`` root holding the add-on's prefixes, and the previous
##   generation's root stays registered.
##
## - **the switch** (spec §7.2, A4): the generation's link-form objects
##   are one store object, the static tree; ``/etc/repro/static`` is
##   flipped to it in one rename between the plan and the first write, so
##   every ``/etc/X -> /etc/repro/static/X`` link changes content at once;
##   the drivers then create the links that are new and the copies the
##   kinds that need regular files (sysusers and tmpfiles fragments, the
##   add-on's own objects); the fragment tools run on the changed
##   fragments and sysctl is applied by the host's own ``systemd-sysctl``;
##   the service transitions (§7.3, ``transitions.nim``) run in two
##   steps around the files; and ``current`` moves only when all of it
##   succeeded. The nine steps are named (``SwitchStep``) and the pending
##   marker records the last one completed, for the re-assert unit (A5).
##
## The plan's three add-on sections (spec §7.1) are in the result: the
## ledger diff, the collision report, and the service transition list.

import std/[algorithm, json, monotimes, options, os, sets, strutils, tables,
            times]
from std/posix import Statvfs, statvfs, Stat, lstat, stat, rmdir, S_ISLNK, ENOENT, O_WRONLY, O_CREAT,
  O_TRUNC, O_RDONLY, O_CLOEXEC, fsync
import std/posix as posix
import std/uri
import repro_binary_cache_client/http_pool

import repro_core/host_apply_lock
import repro_dsl_stdlib/packages/apt_closure
import repro_elevation
import repro_elevation/posix_system_driver
import repro_infra
import repro_infra/addon_diagnostics
import repro_infra/planner
import repro_infra/start_holds
from repro_infra/service_floor import floorWritablePlaces, serviceDirectives,
  StartingDependencyKeys, BaseReachKeys, normalisedPath,
  PrivilegedGroups
import repro_infra/service_floor as serviceFloor
from repro_profile import ProfileBuildAction
import repro_local_store/store

import ./agent_record
import ./collision
import ./own_profile
import ./contain_marker
import ./tmpfiles_scope
import ./addon_secrets
import ./base_identity
import ./etc_write
import ./evidence
import ./fingerprint
import ./generation0
import ./handback
import ./host_exec
import ./health
import ./ledger
import ./mutations
import ./pending_plan
import ./seams
import ./static_tree
import ./store_custody
import ./store_root
import ./switch
import ./evidence
import ./effective_floor
import ./sysctl_precedence
import ./transitions

export AddonDriftError, AddonCollisionError, EAddOnExclusiveOverlap
export transitions.Transition, transitions.TransitionVerb,
  transitions.renderTransitions, transitions.parseTransitions
export switch.RetentionPolicy, switch.DefaultRetention
export health.ConfirmOutcome

type
  AddonApplyError* = object of CatchableError
  AddonFailedAtFloor* = object of AddonApplyError
    ## A switch failed after its flip and was NOT reverted, because the
    ## signed rollback floor is above the sequence of the generation it
    ## would go back to (spec §7.5): the host keeps what the switch wrote;
    ## when the switch did not commit, its pending marker stays (a recovery
    ## finishes it forward, never reverts it) and ``floor-hold`` records why.
  AddonRolledBack* = object of AddonApplyError
  AddonNeedsOperator* = object of AddonApplyError
    ## Refused for an operator to act, not to be retried: an unattended
    ## (agent) apply that would give a running unit its first hardening
    ## floor (spec §10.1). The deploy agent reports it as
    ## ``aoOperatorAction`` and does not retry the sequence.
  AddonStoreSpaceError* = object of AddonApplyError
    ## The profile's apt closures would not fit on the store's filesystem
    ## with ``StoreSpaceReserveBytes`` (or a quarter of what they need)
    ## left free: refused before step 1 writes anything (spec §9).
  AddonRecordedOnly* = object of AddonApplyError
    ## A record-only replay finished: it recorded the failed switch's
    ## writes and, by design, committed nothing. Any other error out of a
    ## record-only replay is a real failure.
    ## The switch did not complete -- a health check failed within
    ## ``confirmTimeout``, a write was refused, a step failed -- and it was
    ## reverted: the host is back in the generation ``current`` names
    ## (§7.5). The attempt's apply log records ``rolled-back``.

  AddonPaths* = object
    stateDir*: string

  AddonApplyOptions* = object
    stateDir*: string
    carriedStateDir*: string
      ## Test seams: where carried state is looked for and the root its
      ## directories are under ("": ``CarriedStateDir`` and ``/``).
    carriedStateRoot*: string
    probeArchives*: bool
      ## A plan (the migration plan) asks the archive for every closure
      ## member it would fetch (``httpDebProbe``) and refuses the ones not
      ## served. The switch itself has no network and never sets it.
    hostIdentity*: string
    userProfileText*: string
    ownProfileText*: string
      ## Bootstrap passes generation 0's text here; later applies leave it
      ## empty and the stored ``own.profile`` is used.
    bootstrapEntries*: seq[LedgerEntry]
      ## Bootstrap-created roots, keys and store prefixes (generation 0
      ## only); carried forward unchanged by every later apply.
    reconcileDrift*: bool
      ## ``--reconcile-drift``: replace a differing unowned (or changed
      ## owned) object, preserving its current bytes; remove a changed
      ## object that left the profile.
    adoptAddresses*: seq[string]
      ## ``repro system adopt <address>``: claim these resources' targets
      ## as they are, writing nothing.
    planOnly*: bool
      ## ``repro infra plan``: observe, decide and report; write nothing,
      ## not even under the state directory.
    driver*: CollisionDriver
      ## The collision observer; ``nil`` selects the host's.
    retention*: Option[RetentionPolicy]
      ## Which generations keep their store roots after this commit
      ## (spec §5.2); ``none`` means the default (last 5 or 30 days).
      ## ``some(RetentionPolicy(keepGenerations: 0, keepDays: 0))`` keeps
      ## only what is always kept: the current and the previous
      ## generation, and any generation a running managed unit runs from.
    planId*: string
      ## ``--plan <id>``: the add-on plan id ``repro infra plan`` printed
      ## (``planIdOf``). The apply recomputes it from what it observes now
      ## and refuses with ``EPlanStale`` before anything is written when
      ## the two differ (spec §7.1). Empty: no pin.
    purpose*: string
      ## ``apply`` (default), ``rollback``, ``revert`` (the switch's own
      ## undo of a failed attempt) or ``replay`` (recovery of an
      ## interrupted switch). Recorded in the pending marker.
    replay*: bool
      ## Re-run the interrupted switch whose write-ahead plan
      ## (``pending_plan``) is on disk, with the observations and decisions
      ## it made before its first write, instead of observing the host
      ## anew (spec §7.7). The profile texts come from the plan.
    assumeActive*: seq[string]
      ## Units to treat as running when planning transitions: what an
      ## interrupted or failed switch had stopped, so its replay or revert
      ## starts them again (a restart applies only to an active unit).
    reproExe*: string
      ## The binary that runs the TCP and HTTP health probes in the host's
      ## namespaces; "" means this process's own executable.
    revertOf*: string
      ## A revert: the failed attempt's generation id, recorded in the
      ## marker so a recovery that finishes the revert can record the
      ## attempt as rolled back.
    revertReason*: string
    replayOf*: string
      ## A replay: the purpose of the switch it replays (a replayed revert
      ## is still a revert: it does not revert itself).
    storedTarget*: bool
      ## ``userProfileText`` is a stored generation's profile (a revert, a
      ## rollback, a re-apply of the current generation), not a new one: it
      ## is parsed under the rules it was installed with
      ## (``parseStoredUserProfile``), so a generation from before the
      ## hardening floor comes back byte for byte (spec §10.1).
    recordOnly*: bool
      ## Replay a failed switch's writes only to bring its ledger up to
      ## date with what it wrote, never starting or committing anything:
      ## what a revert needs when the switch failed before it recorded
      ## its ledger.
    secretsEnvelope*: string
      ## The sealed envelope this switch materialises from (spec §10.3):
      ## the deploy agent's tick names the section it staged; "" selects by
      ## purpose -- the latest accepted envelope for an apply, the
      ## committed generation's own copy for a revert, the target's copy
      ## for a rollback (``secretsFromGeneration``), the interrupted
      ## switch's own choice for a replay.
    secretsFromGeneration*: string
      ## A rollback: the generation whose envelope copy it materialises.
    baseIdentity*: Option[BaseIdentity]
      ## The base, observed by the caller instead of read from this host:
      ## a hermetic test planning over a fixture tree on a build host
      ## whose own base is not in the matrix. ``none`` (every product
      ## caller) observes the host.
    nonBlockingStarts*: bool
      ## Queue step 7's jobs without waiting for them (``--no-block``): a
      ## recovery at boot, which must never wait on the boot transaction.
      ## The confirm step still waits for the health checks.
    buildActions*: seq[ProfileBuildAction]
      ## The action edges the deploy agent's compiled profile carries (its
      ## build outputs: substitute-only, digest-pinned store prefixes), run
      ## by the infra apply before the live state as for any apply. Empty
      ## for an operator apply of canonical text, a rollback and a replay:
      ## their prefixes are already realised and held by the generations'
      ## store roots.
    buildActionDispatcher*: BuildActionDispatcher
    agentRecord*: AgentRecord
    legacySecretsDirs*: seq[string]
      ## A full-engine agent's `--secrets-dir`, for this apply, beside the
      ## ones registered with the add-on (``registeredLegacySecretsDirs``):
      ## a hand-written `LoadCredential=` from under one is accepted (spec
      ## §10.3, "Legacy delivery").
      ## A deploy-agent apply: the manifest's ``deploymentId`` and sequence,
      ## recorded in the generation it commits (spec §7.4).
    confirmCapSec*: int
      ## When > 0, step 8 waits at most this long, whatever the profile's
      ## ``confirmTimeout``: a recovery at boot runs a replay's confirm
      ## and, if that fails, a revert's, inside the re-assert unit's start
      ## timeout, so each is capped (``reassert``, ``BootConfirmCapSec``).
    # --- Milestone A8: the deploy agent's apply unit (spec §7.5, §9.1). ---
    agentSequence*: uint64
      ## The signed manifest sequence this switch applies (0: not a deploy
      ## agent's). Recorded with the generation (``AgentSequenceFileName``)
      ## so a later rollback floor can tell how old it is.
    rollbackFloor*: uint64
      ## The signed manifest's rollback floor (a sequence; 0 = none). When
      ## the generation ``current`` names was applied from a lower sequence
      ## (or by no manifest), a failure after the flip does not revert: the
      ## new generation is committed with ``failedAtFloor`` set and an
      ## evidence record (spec §7.5, threat model T36).
    aptFetch*: AptDebFetcher
      ## Where an apt closure's ``.deb`` files come from; nil is the
      ## network. The agent's apply unit has none, and passes the copy of
      ## what its fetch unit staged.

  AddonApplyResult* = object
    generationId*: string
    previousGenerationId*: string
    ledger*: Ledger
    previousLedger*: Ledger
    removed*: seq[string]          ## resource addresses removed
    infra*: ApplyResult
    collisions*: seq[CollisionLine]  ## the collision report (spec §7.1)
    ledgerDiff*: seq[string]       ## ``<verb>\t<path>\t<address>`` lines
    transitions*: seq[Transition]  ## the service transition list (§7.1, §7.3)
    drift*: seq[string]            ## left in place as actionable drift
    closureSources*: seq[string]   ## where each closure member to publish
                                   ## comes from (``ClosureSpace.sources``)
    storeSpace*: string            ## what realising the closures needs of
                                   ## the store's filesystem (``closureSpace``);
                                   ## "" when every closure is realised
    restored*: seq[string]         ## paths restored from preserved bytes
    unlisted*: seq[string]         ## resources that left the profile but
                                   ## had no ledger entry; never removed
    staticTree*: string            ## the generation's static tree (§7.2)
    sysctlObserved*: seq[tuple[key, value: string]]
      ## Every sysctl key the generation sets, with the value observed from
      ## the host's namespaces after step 6.
    retentionDropped*: seq[string] ## generations whose store roots the
                                   ## retention policy released
    planId*: string                ## the add-on plan id (spec §7.1): the
                                   ## digest of everything the plan was
                                   ## computed from (``planIdOf``)
    confirm*: ConfirmOutcome       ## step 8 (§7.5): the health checks
    healthChecks*: seq[UnitHealthCheck]
    baseIdentity*: BaseIdentity    ## the base observed at plan time (§7.4)
    previousBase*: BaseIdentity    ## the one the current generation recorded
    baseChanges*: seq[string]      ## what changed between the two (§7.9)
    floorIntroduced*: seq[string]
      ## Units whose floor this generation changes -- installed without it
      ## or under an older floor version (``floorIntroducedUnits``): each
      ## is a changed unit file and a restart, listed apart in the plan;
      ## an agent apply refuses them (spec §10.1).
    floorExceptions*: seq[string]
      ## The target profile's hardening-floor exceptions (spec §10.1,
      ## CONF-2): ``<unit>: <Setting>: <reason>`` each, printed in every
      ## plan (``floorExceptionPlanLines``).
    failedAtFloor*: seq[string]
      ## Non-empty when the switch failed after its flip and the rollback
      ## floor kept it in place: what failed (spec §7.5, ``failed-at-floor``).
    heldAtRevert*: seq[string]
      ## A revert whose own effective-unit check refused units: each refusal
      ## line. The revert commits; those units keep their start hold and
      ## are not started, until a later switch's check passes (spec §10.1,
      ## A9 review round 12).

const
  DefaultStateDir* = SystemStateDir
  AddonManagedKinds* = {srkFsSystemFile, srkSystemdSystemUnit,
                        srkLinuxDpkgDiversion, srkSystemdSystemDropIn,
                        srkLinuxSysusersEntry, srkLinuxTmpfilesRule,
                        srkLinuxSysctl, srkSystemdUnitState}
    ## The resource kinds an add-on generation may carry in this release:
    ## the ``etcFile``, ``unit``, ``dropIn``, ``diversion``, ``sysusers``,
    ## ``tmpfiles``, ``sysctl`` and ``unitState`` classes of spec §4.1
    ## (``secret`` arrives with A7, ``firewall`` is opt-in and refused in
    ## agent applies until §13 Q6).
  AddonProfileKinds* = AddonManagedKinds + {srkSystemdSystemTimer,
                        srkPasswdUser, srkPasswdGroup, srkLinuxAddOnTool}
    ## What an add-on profile may declare (spec §8.3, "As implemented (A6)"):
    ## the managed kinds, and the four the composition carries through them
    ## (``reshape``): a ``systemd.systemTimer`` is the ``unit`` class's
    ## timer, written as a unit; ``passwd.user`` / ``passwd.group`` are
    ## accounts the infra drivers converge (subset semantics), ledgered as
    ## accounts; a ``linux.addOnTool`` is applied by its driver, and its
    ## wrapper and launcher manifest are ledgered as the ``etcFile``s they
    ## are (§4.1).
  LinkFormKinds* = {srkFsSystemFile, srkSystemdSystemDropIn, srkLinuxSysctl}
    ## The kinds materialised as links into the static tree (spec §7.2
    ## step 4). The driver declares it per kind; a resource cannot choose:
    ## sysusers and tmpfiles fragments are copies so they stay readable
    ## when the store is unavailable at early boot (step 5), and so are
    ## the add-on's own objects and anything adopted as it is. Unit files
    ## are copies too: `systemctl enable` on a symlinked unit file writes
    ## the link's RESOLVED target into the `[Install]` links it creates
    ## (measured on Debian 13 and Ubuntu 24.04), so a link-form unit would
    ## carry a generation-specific store path into `.wants`, re-point a
    ## package's own enablement link of a `replace`d unit, and dangle once
    ## retention released that tree. Drop-ins are read, never enabled, so
    ## they stay links.

proc addonDir*(stateDir: string): string = stateDir / "addon"
proc ledgerCopyPath*(stateDir: string): string = stateDir / "addon-ledger"
proc ownProfilePath*(stateDir: string): string = addonDir(stateDir) / "own.profile"
proc userProfilePath*(stateDir: string): string = addonDir(stateDir) / "user.profile"
proc generationLedgerPath*(stateDir, generationId: string): string =
  stateDir / "generations" / generationId / "addon-ledger"

let SelfExeAtStart = getAppFilename()
  ## This binary's path as the process started. Read once, at start-up:
  ## once a thread has entered the store's private writable view
  ## (``enterWritableStoreView``), ``/proc/self/exe`` of a binary in the
  ## store names it relative to the store bind's own root
  ## (``/prefixes/...``), and the confirm step's probes, which run this
  ## binary in the host's namespaces, could not find it (measured on
  ## Debian 13 from ``repro-agent-apply.service``, 2026-10-31).

const AgentSequenceFileName* = "agent-sequence"
  ## In a generation's directory: the manifest sequence a deploy-agent
  ## apply committed it from (absent: an operator apply, sequence 0).

proc generationAgentSequence*(stateDir, generationId: string): uint64 =
  ## The manifest sequence ``generationId`` was applied from; 0 when it was
  ## applied by no manifest or the record is unreadable (below every floor,
  ## the safe direction).
  if generationId.len == 0: return 0
  let p = stateDir / "generations" / generationId / AgentSequenceFileName
  if not fileExists(p): return 0
  try: parseBiggestUInt(readFile(p).strip()) except CatchableError: 0'u64

proc floorHoldPath*(stateDir: string): string =
  ## Present while a switch the rollback floor kept from reverting is
  ## pending: a recovery may finish it, never revert it.
  stateDir / "addon" / "floor-hold"

proc invocationTablePath*(stateDir: string): string =
  addonDir(stateDir) / "invocations"

proc generationUnitLookup*(stateDir: string): GenerationUnitLookup =
  ## A unit's definition (``switch.unitDefinition``) in a generation's own
  ## ledger, for retention (``switch.generationsHeldBy``). A ledger that
  ## is missing or unreadable is reported as not found, which keeps the
  ## generation.
  var cache = initTable[string, Ledger]()
  var missing = initHashSet[string]()
  result = proc(generationId, unit: string):
      tuple[ledgerFound, unitFound: bool; definition: string] =
    if generationId in missing: return (false, false, "")
    if generationId notin cache:
      try:
        cache[generationId] = readLedger(generationLedgerPath(stateDir, generationId))
      except CatchableError:
        missing.incl(generationId)
        return (false, false, "")
    let d = unitDefinition(cache[generationId], unit)
    (true, d.len > 0, d)

proc heldGenerations*(stateDir: string; ledger: Ledger; current: string):
    HashSet[string] =
  ## The generations running managed units still run from (spec §5.2), by
  ## the invocation table the switches keep -- no clock involved.
  generationsHeldBy(runningManagedUnits(ledger),
    readInvocationTable(invocationTablePath(stateDir)), current,
    generationUnitLookup(stateDir), retained = generationRoots())

proc isAddonHost*(stateDir = DefaultStateDir): bool =
  ## An add-on host is one whose state directory holds the ledger copy.
  fileExists(ledgerCopyPath(stateDir))

proc readHostname*(): string =
  try: readFile("/proc/sys/kernel/hostname").strip()
  except IOError, OSError: "localhost"

proc storeChangedSince*(realised: openArray[tuple[path, signature: string]];
                        quarantinePath = StoreQuarantinePath): seq[string] =
  ## The store objects whose ``storeSignature`` differs from the one
  ## recorded, or that are gone -- or that store verification quarantined
  ## (spec §13 decision 46: no switch uses an altered path again).
  let quarantined = readStoreQuarantine(quarantinePath)
  for (path, sig) in realised:
    let now = if dirExists(path): storeSignature(path) else: "(gone)"
    if now != sig: result.add(path)
    elif path in quarantined: result.add(path & " (quarantined: its bytes " &
      "differed from its realisation digest)")

proc storeObjectFor*(path: string): string =
  ## The store object a path lies in: a prefix
  ## (``/repro/store/prefixes/<name>/<version>``) or another top-level
  ## entry of the store; "" outside the store.
  result = storeObjectOf(path)
  if result.len == 0 and path.startsWith(StoreRoot & "/"):
    let first = path[StoreRoot.len + 1 .. ^1].split('/')[0]
    if first.len > 0 and first notin [".", ".."]:
      result = StoreRoot & "/" & first

proc knownUnitDigests(stateDir, path: string): HashSet[string] =
  ## Every digest a ledger in ``stateDir`` -- the current copy and each
  ## generation's -- records for the unit file ``path``: the bytes some
  ## generation installed there.
  if stateDir.len == 0: return
  var ledgers: seq[string]
  if fileExists(ledgerCopyPath(stateDir)): ledgers.add(ledgerCopyPath(stateDir))
  let gens = stateDir / "generations"
  if dirExists(gens):
    for kind, d in walkDir(gens):
      if kind == pcDir and fileExists(d / "addon-ledger"):
        ledgers.add(d / "addon-ledger")
  for lp in ledgers:
    try:
      for e in readLedger(lp).entries:
        if e.class == lcUnit and e.path == path and e.sha256.len > 0:
          result.incl(e.sha256)
    except CatchableError:
      discard   # an unreadable ledger records nothing to match

proc unrecordedFloorVersion(r: SystemResource;
                            known: HashSet[string]): string =
  ## The floor version of a stored floored unit that names none: one of
  ## the engines before version 3 stored it -- 1 (1a598170c0), 2 before
  ## fca5ed3486 (no ``RequiresMountsFor=`` for a kept state directory:
  ## ``2-prekeep``) or 2 after it (to d03bb6759e). It is the version whose
  ## rendering a ledger records for the unit file: the bytes it was
  ## installed with. None recording any is refused, never guessed (A9
  ## review round 3, finding 8): a wrong version would re-render other
  ## bytes than were installed.
  when mutated("stored-floor-guess"):
    # Falsifying build: round 2's fall-back to the newest version that
    # renders the unit at all.
    for v in ["2", "1"]:
      var c = r
      c.suFloorVersion = v
      try:
        discard renderedSystemUnitContent(c)
        return v
      except CatchableError: discard
    return "2"
  for v in ["2", "2-prekeep", "1"]:
    var c = r
    c.suFloorVersion = v
    try:
      if sha256Hex(renderedSystemUnitContent(c)) in known: return v
    except CatchableError:
      discard
  raiseSystemProfileInvalid("systemd.systemUnit '" & r.suName & "': the " &
    "stored generation names no floor version, and no ledger in the state " &
    "directory records the bytes any earlier floor version renders for " &
    "it; the add-on will not guess which floor it was installed with")

proc parseStoredUserProfile*(text: string; stateDir = ""): SystemProfile =
  ## A stored generation's user profile (``user.profile``, a generation's
  ## ``addon-user.profile``, the write-ahead record's) as it was installed.
  ## The add-on stores what it applied rendered (``renderProfileText``):
  ## a unit the floor reached carries ``hardening = "serviceFloor"`` and,
  ## from floor version 3, the ``floorVersion`` it was rendered with, and
  ## every other unit carries neither. Parsing it WITHOUT the add-on
  ## default and with the stored generation's own floor version renders
  ## each unit exactly as it was installed: a generation an engine from
  ## before the floor applied stays floor-off, and one an earlier floor
  ## version applied keeps that floor (spec §10.1, *Stored generations and
  ## floor versions*). A floored unit stored without a version gets the
  ## one its ledger records (``unrecordedFloorVersion``; the ledgers of
  ## ``stateDir``). Nothing the engine that stored it accepted is judged
  ## again under today's rules (``parseSystemProfile(..., stored = true)``).
  when mutated("stored-profile-floored"):
    # Falsifying build: stored generations re-rendered under today's
    # default, which wedges a host whose installed profile the floor
    # refuses and keeps a revert from restoring the pre-floor unit.
    return parseSystemProfile(text, addOnDefaults = true)
  result = parseSystemProfile(text, stored = true)
  when not mutated("stored-floor-unversioned"):
    # (The falsifying build renders a stored floored unit without a
    # version under today's floor, as versions 1 and 2 did not exist.)
    for r in result.resources.mitems:
      if r.kind == srkSystemdSystemUnit and
          r.suHardening == ServiceFloorHardening and r.suFloorVersion.len == 0:
        r.suFloorVersion = unrecordedFloorVersion(r,
          knownUnitDigests(stateDir, unitPath(r.suName)))

proc effectiveFloor*(r: SystemResource): string =
  ## The floor a unit renders with: "" for none (no ``hardening``, or the
  ## whole floor waived), else its floor version (``FloorVersion`` when the
  ## unit names none: a new profile's).
  if r.kind != srkSystemdSystemUnit or
      r.suHardening != ServiceFloorHardening:
    return ""
  for e in r.suFloorExceptions:
    if e.strip().startsWith(WholeFloorException & ":"): return ""
  if r.suFloorVersion.len > 0: r.suFloorVersion else: FloorVersion

proc floorAccountRefusal*(p: SystemProfile; r: SystemResource): string =
  ## Why the account the floored unit ``r`` of ``p`` runs as breaks the
  ## floor, as far as the profile alone says (A9 review round 6, finding
  ## 1), or "". The values are the last ``User=``, ``Group=`` and
  ## ``DynamicUser=`` and the accumulated ``SupplementaryGroups=`` of the
  ## unit and the profile's drop-ins onto it, resolved the way systemd
  ## resolves them (``resolveServiceAccount``): a specifier that names root
  ## (``%U``, ``%u``, ``%G``, ``%g``) or an instance whose name is root is
  ## root; a specifier that does not resolve (``%i`` in a template's own
  ## file, which any instance may start) is refused, since it may be root.
  ## Exceptions lift the spelling rules (``service_floor``), never these. An
  ## account neither root nor the profile's is left to the effective-unit
  ## check, which reads the host's databases. The parse-time lookup is the
  ## profile's alone (``profileAccountLookup``), so a profile parses the same
  ## on every host.
  when mutated("floor-static-r3-disabled") or mutated("floor-unchecked"):
    return ""
  # The unit as the floor renders it: a unit without an account gets the
  # floor's DynamicUser=yes.
  var files = @[renderedSystemUnitContent(r)]
  for d in p.resources:
    if d.kind == srkSystemdSystemDropIn and dropInApplies(d.diUnit, r.suName):
      files.add(d.diContent)
    elif d.kind == srkSystemdSystemUnit and d.suCollision == "dropIn" and
        dropInApplies(d.suName, r.suName):
      files.add(d.suContent)
  var user, group, dynamic = ""
  var supplementary: seq[string]
  for f in files:
    for (k, v) in serviceDirectives(f):
      case k
      of "User": user = v.strip()
      of "Group": group = v.strip()
      of "DynamicUser": dynamic = v.strip().toLowerAscii()
      of "SupplementaryGroups":
        if v.strip().len == 0: supplementary.setLen(0)
        else: supplementary.add(v.splitWhitespace())
      else: discard
  for (k, v) in [("User", user), ("Group", group)]:
    var ok: bool
    discard expandSpecifiers(v, r.suName, ok)
    if not ok:
      return k & "=" & v & " names a specifier systemd cannot resolve " &
        "for " & r.suName & " (in a template's own file an instance " &
        "specifier names whichever instance is started), so the service " &
        "may run as root; a floored unit may not"
  for w in supplementary:
    var ok: bool
    discard expandSpecifiers(w, r.suName, ok)
    if not ok:
      return "SupplementaryGroups=" & w & " names a specifier systemd " &
        "cannot resolve for " & r.suName & "; a floored unit may not"
  let a = resolveServiceAccount(user, group, supplementary.join(" "),
    dynamic in ["yes", "true", "1", "on"], r.suName,
    profileAccountLookup(p))
  if a.uid == 0:
    return "User=" & user & " runs the service as root (uid 0, the " &
      "account systemd resolves it to); a floored unit may not (only " &
      "\"serviceFloor: <why>\" allows it)"
  if 0 in a.allGids:
    return "the service runs with gid 0 (Group=" & group & "); a floored " &
      "unit may not (only \"serviceFloor: <why>\" allows it)"
  var names = @[a.group]
  for w in supplementary:
    var ok: bool
    names.add(expandSpecifiers(w, r.suName, ok))
  for n in names:
    if n in PrivilegedGroups and not (n == a.group and a.dynamicGroup):
      return "the service runs in the privileged group " & n & "; a " &
        "floored unit may not (only \"serviceFloor: <why>\" allows it)"
  # The memberships the profile itself gives the account (A9 review round
  # 7, finding 6): `passwd.user` `groups` and `passwd.group` `members`.
  # The resolver knows their gids only for groups the profile creates, so
  # they are judged by name here; the effective half judges them by gid.
  when not mutated("profile-memberships-ignored"):
    if not a.dynamicUser:
      for o in p.resources:
        var g = ""
        if o.kind == srkPasswdUser and o.puName == a.user:
          for gn in o.puGroups:
            if gn in PrivilegedGroups or gn == "root": g = gn
        elif o.kind == srkPasswdGroup and a.user in o.pgMembers and
            (o.pgName in PrivilegedGroups or o.pgName == "root"):
          g = o.pgName
        if g.len > 0:
          return "the profile puts the service's account " & a.user &
            " in the privileged group " & g & " (" & o.address & "); a " &
            "floored unit may not (only \"serviceFloor: <why>\" allows it)"
  ""

proc parseAddOnUserProfile*(text: string): SystemProfile =
  ## A user profile as the add-on realises it: parsed with the add-on's
  ## defaults (``parseSystemProfile(..., addOnDefaults = true)``), so every
  ## unit with a ``[Service]`` section that is not a ``collision = dropIn``
  ## gets the hardening floor unless it names an exception (spec §10.1).
  ## Every add-on path that plans, applies or compares a user profile --
  ## the target, the current and the previous generation's -- parses
  ## through here, so a unit renders the same bytes wherever the add-on
  ## renders it, and a unit a pre-floor generation installed without the
  ## floor is planned as a change of its file (a restart in the transition
  ## list), never applied silently. A new profile renders with today's
  ## floor version: naming an older one would ask for a weaker floor, and
  ## is refused (spec §10.1, *Stored generations and floor versions*).
  result = parseSystemProfile(text, addOnDefaults = true)
  for r in result.resources:
    if r.kind == srkSystemdSystemUnit and r.suFloorVersion.len > 0 and
        r.suFloorVersion != FloorVersion:
      raiseSystemProfileInvalid("systemd.systemUnit '" & r.suName &
        "' names floorVersion " & r.suFloorVersion & ": a new profile " &
        "renders with today's floor (version " & FloorVersion & "); only " &
        "a stored generation keeps an older one")
  for r in result.resources:
    if r.kind == srkSystemdSystemUnit and r.suCollision != "dropIn" and
        effectiveFloor(r).len > 0:
      let why = floorAccountRefusal(result, r)
      if why.len > 0:
        raiseSystemProfileInvalid("systemd.systemUnit '" & r.suName &
          "': " & why)

proc exceptionHeads(r: SystemResource): HashSet[string] =
  ## A unit's exceptions by what they name (``Setting`` or
  ## ``Setting+values``), reasons left out.
  for e in r.suFloorExceptions:
    result.incl(e.split(':', 1)[0].strip())

proc floorIntroducedUnits*(previousUser: SystemProfile; previous: Ledger;
                           units: openArray[SystemResource]): seq[string] =
  ## The units whose floor this generation changes on a host that runs
  ## them: a unit the previous generation installed without the floor, or
  ## under an older floor version, that the target renders under today's
  ## floor (spec §10.1). Decided from the two profiles' floors -- the
  ## stored generation's (``parseStoredUserProfile``) against the target's
  ## -- whatever else changes in the unit: a unit whose command line
  ## changes in the same generation gets its first floor all the same.
  ## Each entry reads ``<unit> (<from> -> floor version <n>)``. Every plan
  ## lists them (``AddonApplyResult.floorIntroduced``) and an agent apply
  ## refuses them (``runAddonApply``): a running service's floor changes
  ## in an operator's reviewed apply, never in an unattended restart.
  when mutated("floor-change-by-ledger-bytes"):
    # Falsifying build: the round-1 rule -- a unit whose ledgered file
    # holds exactly its floor-less rendering -- which misses a first floor
    # that comes with any other change to the unit.
    for r in units:
      if r.kind != srkSystemdSystemUnit or
          r.suHardening != ServiceFloorHardening: continue
      for e in previous.entries:
        if e.class != lcUnit or e.path != unitPath(r.suName) or
            e.sha256.len == 0: continue
        let before = sha256Hex(renderedUnitBeforeFloor(r))
        if e.sha256 == before and
            before != sha256Hex(renderedSystemUnitContent(r)):
          result.add(r.suName)
        break
    return
  var before = initTable[string, string]()
  var beforeEx = initTable[string, HashSet[string]]()
  for r in previousUser.resources:
    if r.kind == srkSystemdSystemUnit:
      before[r.suName] = effectiveFloor(r)
      beforeEx[r.suName] = exceptionHeads(r)
  for r in units:
    let now = effectiveFloor(r)
    if now.len == 0 or r.suName notin before: continue
    let was = before[r.suName]
    if was != now:
      result.add(r.suName & " (" &
        (if was.len == 0: "no floor" else: "floor version " & was) &
        " -> floor version " & now & ")")
      continue
    # The same floor with an exception taken away is a stricter floor the
    # running service has not run under (A9 review round 3, finding 9).
    when not mutated("floor-change-ignores-exceptions"):
      let gone = beforeEx.getOrDefault(r.suName) - exceptionHeads(r)
      if gone.len > 0:
        var g: seq[string]
        for x in gone: g.add(x)
        g.sort()
        result.add(r.suName & " (floor version " & now & ", exception " &
          g.join(", ") & " removed)")

# ---------------------------------------------------------------------------
# Scope (spec §4.1, §4.4; threat model G8).
# ---------------------------------------------------------------------------

proc managedPrefixes*(p: SystemProfile): seq[string] =
  ## The prefixes the profile may write below: what it declared, plus the
  ## add-on's own directory.
  result = @[AlwaysManagedEtcPrefix]
  for pfx in p.addOn.managedEtcPrefixes:
    if pfx notin result: result.add(pfx)

proc isManagedPath*(path: string; prefixes: openArray[string]): bool =
  for pfx in prefixes:
    if isUnderManagedPrefix(path, pfx): return true
  false

proc unmanagedKindReason*(r: SystemResource): string =
  ## "" when the add-on manages ``r.kind``; otherwise the refusal text.
  if r.kind in AddonProfileKinds: ""
  else: "resource kind " & $r.kind & " is not managed by the add-on in " &
        "this release (" & r.address & "); nothing was applied"

proc addOnNameError*(r: SystemResource): string =
  ## "" when every name of ``r`` that becomes part of a path or an argv
  ## (a unit name, a drop-in's unit and name, a fragment name, a sysctl
  ## key and file name, an account name) is valid exactly as written,
  ## else why not. The parser refuses these already; the scope check
  ## repeats it for a profile built in memory, because the add-on derives
  ## the path it observes from the same text the driver derives the path
  ## it writes from, and the two only agree when nothing is stripped.
  when mutated("scope-accepts-unnormalised-paths"):
    return ""
  else:
    case r.kind
    of srkSystemdSystemUnit:
      result = systemdUnitNameError("systemd.systemUnit name", r.suName)
      if result.len == 0 and r.suDropInName.len > 0 and
          not isSafeDropInName(r.suDropInName):
        result = "systemd.systemUnit dropInName '" & r.suDropInName.escape() &
          "' is not one path segment of [A-Za-z0-9._-]"
    of srkSystemdSystemDropIn:
      result = systemdUnitNameError("systemd.systemDropIn unit", r.diUnit)
      if result.len == 0 and not isSafeFragmentName(r.diName):
        result = "systemd.systemDropIn name '" & r.diName.escape() &
          "' is not one path segment of [A-Za-z0-9._-]"
    of srkSystemdUnitState:
      result = systemdUnitNameError("systemd.unitState name", r.usName)
    of srkLinuxTmpfilesRule:
      if not isSafeDropInBasename(r.tmpfilesName):
        result = "linux.tmpfilesRule name '" & r.tmpfilesName.escape() &
          "' is not a single-segment basename of [A-Za-z0-9._-]"
    of srkLinuxSysctl:
      if not isSafeSysctlKey(r.sysctlKey):
        result = "linux.sysctl key '" & r.sysctlKey.escape() &
          "' is not in the sysctl-key charset [A-Za-z0-9._/-]"
      elif r.sysctlFilename.len > 0 and not isSafeDropInBasename(r.sysctlFilename):
        result = "linux.sysctl filename '" & r.sysctlFilename.escape() &
          "' is not a single-segment basename of [A-Za-z0-9._-]"
    of srkLinuxSysusersEntry:
      if not isSafePosixUserOrGroupName(r.seName):
        result = "linux.sysusersEntry name '" & r.seName.escape() &
          "' is not an account name of [A-Za-z0-9._-]"
    of srkSystemdSystemTimer:
      result = systemdUnitNameError("systemd.systemTimer name", r.stName)
      if result.len == 0 and not r.stName.endsWith(".timer"):
        result = "systemd.systemTimer name '" & r.stName.escape() &
          "' does not end in .timer"
      elif result.len == 0 and r.stRunning != r.stEnabled:
        # The unit class enables-and-starts a unit, or does neither (§7.3:
        # "start if enabled"); a timer enabled but stopped, or started but
        # not enabled, has no add-on form in this release.
        result = "systemd.systemTimer " & r.stName & " sets enabled = " &
          $r.stEnabled & " and running = " & $r.stRunning & "; an add-on " &
          "unit is enabled and started, or neither"
    of srkPasswdUser:
      if not isSafePosixUserOrGroupName(r.puName):
        result = "passwd.user name '" & r.puName.escape() &
          "' is not an account name of [A-Za-z0-9._-]"
    of srkPasswdGroup:
      if not isSafePosixUserOrGroupName(r.pgName):
        result = "passwd.group name '" & r.pgName.escape() &
          "' is not an account name of [A-Za-z0-9._-]"
    of srkLinuxAddOnTool:
      if not isSafeAddOnToolCommand(r.atCommand):
        result = "linux.addOnTool command '" & r.atCommand.escape() &
          "' is a file name of [A-Za-z0-9._+-] not starting with . or -"
    else:
      discard

const RawCredentialDirectives* = ["LoadCredential", "LoadCredentialEncrypted",
                                  "SetCredential", "SetCredentialEncrypted",
                                  "ImportCredential"]
  ## systemd's credential directives (systemd.exec(5) "Credentials"). In an
  ## add-on unit or drop-in they are refused: a unit gets secrets only
  ## through its ``credentials`` field, which names its own service's
  ## secrets and nothing else (spec §10.3, CRED-3).

proc credentialSourceResolvesUnder*(src, dir: string): bool =
  ## Whether ``src``, as the filesystem resolves it now, is still below
  ## ``dir``: a source that is itself a symbolic link, dangling or not, is
  ## refused, and so is one an intermediate link takes out of the
  ## directory (spec §10.3, "Legacy delivery"). A source that does not
  ## exist yet resolves to nothing and is accepted: the directory is
  ## root-owned and neither group- nor world-writable
  ## (``legacySecretsDirTrustError``), so only root can put a link there
  ## later, and root can read any file anyway.
  if lstatLegacy(src).isLink: return false
  var realSrc, realDir: string
  try: realDir = expandFilename(dir)
  except OSError: return false
  try: realSrc = expandFilename(src)
  except OSError: return true
  realSrc.startsWith(realDir & "/")

proc legacyCredentialSource*(value: string;
                             legacySecretsDirs: openArray[string]): bool =
  ## Whether a ``LoadCredential=`` value (``ID:PATH``) loads a file under
  ## one of the agent's legacy secrets directories (spec §10.3, "Legacy
  ## delivery"): a clean path (``legacySecretsPathError``: no `\` or `"`
  ## systemd would unescape, no specifier) strictly below the directory,
  ## which also resolves below it (``credentialSourceResolvesUnder``).
  ## ``ID`` alone (systemd's credential store) and any other source are not.
  let colon = value.find(':')
  if colon <= 0: return false
  let id = value[0 ..< colon].strip()
  let src = value[colon + 1 .. ^1].strip()
  if id.len == 0 or '\\' in id or '"' in id: return false
  if legacySecretsPathError(src).len > 0: return false
  for d in legacySecretsDirs:
    if legacySecretsDirError(d).len == 0 and src.startsWith(d & "/") and
        credentialSourceResolvesUnder(src, d):
      return true
  false

proc rawCredentialDirective*(content: string;
                             legacySecretsDirs: openArray[string] = []):
    string =
  ## The first credential directive written into ``content`` by hand that
  ## the add-on refuses, or "". A ``LoadCredential=`` whose source is under
  ## one of ``legacySecretsDirs`` is the legacy delivery §10.3 accepts.
  for line in joinUnitContinuations(content):
    let t = line.strip()
    if t.len == 0 or t[0] in {'#', ';'}: continue
    let eq = t.find('=')
    if eq <= 0: continue
    let key = t[0 ..< eq].strip()
    if key notin RawCredentialDirectives: continue
    if key == "LoadCredential" and
        legacyCredentialSource(t[eq + 1 .. ^1], legacySecretsDirs):
      continue
    return key
  ""

proc checkScope*(user: SystemProfile;
                 legacySecretsDirs: openArray[string] = [];
                 legacyRejected: openArray[string] = []) =
  ## Refuse, with ``EAddOnOutOfScope``, what an add-on generation may not
  ## carry: a kind outside the add-on's classes, and an ``/etc`` path
  ## outside the declared managed prefixes or inside a directory a class
  ## of its own reaches. Every resource is checked BEFORE anything is
  ## observed or written: a refused kind must refuse the whole apply, not
  ## be applied by the infra layer and then fail when the ledger is built
  ## (which would leave an unledgered object behind for uninstall to miss).
  let prefixes = managedPrefixes(user)
  # The prefixes themselves, as the parser checks them, for a profile
  # built in memory (a non-canonical one, a class or unit directory).
  for pfx in user.addOn.managedEtcPrefixes:
    when not mutated("scope-accepts-unnormalised-paths"):
      let why = managedPrefixError(pfx)
      if why.len > 0:
        raise newAddOnOutOfScope("addOn.managedEtcPrefixes", "", "addOn", why)
  for r in user.resources:
    when not mutated("apply-skips-kind-check"):
      let why = unmanagedKindReason(r)
      if why.len > 0:
        raise newAddOnOutOfScope($r.kind, "", r.address, why)
    let badName = addOnNameError(r)
    if badName.len > 0:
      raise newAddOnOutOfScope($r.kind & ".name", "", r.address, badName)
    let rawContent = case r.kind
      of srkSystemdSystemUnit: r.suContent
      of srkSystemdSystemDropIn: r.diContent
      else: ""
    let rawKey = rawCredentialDirective(rawContent, legacySecretsDirs)
    if rawKey.len > 0:
      raise newAddOnOutOfScope($r.kind & ".content", "", r.address,
        "the content writes " & rawKey & "= by hand; on an add-on host a " &
        "unit loads secrets only through its `credentials` field (spec " &
        "§10.3), which names its own service's secrets and nothing else" &
        (if rawKey == "LoadCredential":
           "; a LoadCredential= is accepted only from under the deploy " &
           "agent's own --secrets-dir (" &
           (if legacySecretsDirs.len > 0: legacySecretsDirs.join(", ")
            else: "none registered") & ")" &
           (if legacyRejected.len > 0: "; not accepted as one: " &
              legacyRejected.join("; ") else: "")
         else: ""))
    case r.kind
    of srkLinuxTmpfilesRule:
      # Spec §4.1: the tmpfiles class lives at /etc/tmpfiles.d/repro-<name>.conf.
      if not r.tmpfilesName.startsWith(AddOnFragmentPrefix):
        raise newAddOnOutOfScope($r.kind & ".name", "", r.address,
          "a tmpfiles fragment of the add-on is named repro-<name>.conf " &
          "(spec §4.1), got " & r.tmpfilesName)
      # The lines decide what systemd-tmpfiles writes, as root, at once and
      # at every boot: each path is held to the class's directories, never
      # /etc, a class directory or another owner's tree (spec §4.1, §4.4).
      let lines = tmpfilesScopeRefusal(r.tmpfilesContent)
      if lines.len > 0:
        raise newAddOnOutOfScope($r.kind & ".content", "", r.address, lines)
    of srkLinuxSysctl:
      # Spec §4.1: /etc/sysctl.d/90-repro-<name>.conf; a filename left
      # empty is derived to that form by the composition.
      if r.sysctlFilename.len > 0 and
          not r.sysctlFilename.startsWith(AddOnSysctlPrefix):
        raise newAddOnOutOfScope($r.kind & ".filename", "", r.address,
          "a sysctl fragment of the add-on is named 90-repro-<name>.conf " &
          "(spec §4.1), got " & r.sysctlFilename)
    else:
      discard
    let path = case r.kind
      of srkFsSystemFile: r.sfPath
      of srkLinuxDpkgDiversion: r.ddPath
      else: ""
    if path.len == 0:
      continue
    # Every compare below is on the path's text, so the text must be the
    # one spelling the kernel, dpkg and ucf use: a `//` or `.` segment
    # would put `/etc/./systemd/system/cron.service` outside the unit
    # directory and `/etc/ssh//sshd_config` outside every package's list.
    # The parser refuses such a path already; this repeats it for a
    # profile built in memory (threat model G8).
    when not mutated("scope-accepts-unnormalised-paths"):
      let canon = nonCanonicalPathError($r.kind & ".path", path)
      if canon.len > 0:
        raise newAddOnOutOfScope($r.kind & ".path", "", r.address, canon)
    for d in AddOnClassDirectories:
      if path.startsWith(d) or path & "/" == d:
        raise newAddOnOutOfScope($r.kind & ".path", "", r.address,
          path & " is below " & d & ", which is reached through its own " &
          "class (declare a systemd.systemUnit, or wait for the sysusers, " &
          "tmpfiles and sysctl classes), never as a file")
    if not isManagedPath(path, prefixes):
      raise newAddOnOutOfScope($r.kind & ".path", "", r.address,
        path & " is outside the profile's managed /etc prefixes (" &
        prefixes.join(", ") & "); declare it in `addOn { " &
        "managedEtcPrefixes = [...] }` (spec §4.4)")

# ---------------------------------------------------------------------------
# Observation before the apply.
# ---------------------------------------------------------------------------

proc missingParents(path: string): seq[string] =
  ## The ancestors of ``path`` that do not exist, shallowest first.
  var p = parentDir(path)
  var chain: seq[string]
  while p.len > 1 and not dirExists(p) and not fileExists(p):
    chain.add(p)
    p = parentDir(p)
  chain.reverse()
  chain

proc baseValue(path: string): string =
  ## The fingerprint ``etc`` value of ``path`` now, or "" when absent.
  var exists = fileExists(path) or dirExists(path) or symlinkExists(path)
  if exists: etcEntryValue(path) else: ""

proc installLinkPaths*(unit, content: string): seq[tuple[link, dir: string]] =
  ## The symlinks ``systemctl enable <unit>`` creates, and the directory
  ## each lives in.
  for t in installTargets(content):
    case t.kind
    of "WantedBy":
      let d = SystemdUnitDir / (t.target & ".wants")
      result.add((link: d / unit, dir: d))
    of "RequiredBy":
      let d = SystemdUnitDir / (t.target & ".requires")
      result.add((link: d / unit, dir: d))
    of "UpheldBy":
      let d = SystemdUnitDir / (t.target & ".upholds")
      result.add((link: d / unit, dir: d))
    of "Alias":
      result.add((link: SystemdUnitDir / t.target, dir: SystemdUnitDir))
    else: discard

type
  ResourcePlan = object
    ## One composed resource, what the apply will find, and what the
    ## collision pass decided for it.
    r: SystemResource
    own: bool                   ## one of generation 0's objects
    targetPath: string          ## the file the resource materialises
    replaced: string            ## fingerprint value before the add-on
    newDirs: seq[string]
    preLinks: seq[string]       ## install links that existed before (a
                                ## package's own enablement): never ledgered
    baseUnitState: string
    baseActiveState: string
    observation: string
    collision: string           ## the ledger's `collision` value
    preserved: string
    verdict: string
    content: string             ## the bytes the object will carry
    form: string                ## planned materialisation: link / copy
    sysctlBefore: string        ## sysctl: the host's value before
    accountKey: string          ## sysusers: `user:<name>` / `group:<name>`
    accountBefore: string       ## sysusers: the account's fingerprint
                                ## value before, "" when absent
    groupBefore: string         ## sysusers (user): the same-named group's
    closureRelocated: bool      ## a unit an older closure realiser bound
                                ## (``legacyClosureRenderings``): rewritten
                                ## at the store-published prefix, the same
                                ## package bytes, so not restarted
    keepLedgerSha: string       ## a revert holding a target changed out of
                                ## band before the reverted switch: the
                                ## ledger keeps this digest, so the drift
                                ## stays visible (``revertHeld``)
    skipInfra: bool             ## adopted as it is, and the kind renders its
                                ## own bytes (sysctl, sysusers): the infra
                                ## apply does not get it, so nothing of it is
                                ## written, applied or re-run this generation

# ---------------------------------------------------------------------------
# The write-ahead plan (``pending_plan``): what the collision pass observed
# and decided, saved before the first write and reused by a replay.
# ---------------------------------------------------------------------------

proc toSaved(p: ResourcePlan; dec: CollisionDecision;
             target: PlannedTarget): SavedPlan =
  SavedPlan(address: p.r.address, targetPath: p.targetPath,
    diversion: target.diversion, unitClass: $target.unitClass,
    replaced: p.replaced, newDirs: p.newDirs, preLinks: p.preLinks,
    baseUnitState: p.baseUnitState, baseActiveState: p.baseActiveState,
    observation: dec.observation, observedSha256: dec.observedSha256,
    reason: dec.reason, verdict: $dec.verdict, collision: p.collision,
    preserved: p.preserved, form: p.form, sysctlBefore: p.sysctlBefore,
    accountKey: p.accountKey, accountBefore: p.accountBefore,
    groupBefore: p.groupBefore)

proc overlaySaved(p: var ResourcePlan; s: SavedPlan) =
  ## Replace what ``preObserve`` just saw with what the interrupted switch
  ## saw before it changed anything: the host now shows the switch's own
  ## partial work, which is not "what was there before the add-on".
  p.targetPath = s.targetPath
  p.replaced = s.replaced
  p.newDirs = s.newDirs
  p.preLinks = s.preLinks
  p.baseUnitState = s.baseUnitState
  p.baseActiveState = s.baseActiveState
  p.sysctlBefore = s.sysctlBefore
  p.accountKey = s.accountKey
  p.accountBefore = s.accountBefore
  p.groupBefore = s.groupBefore

proc savedDecision(s: SavedPlan; fileBacked = true): CollisionDecision =
  ## The interrupted switch's decision, as it made it. The bytes an
  ## adoption or reconciliation displaced were preserved at plan time --
  ## for a file; an account (``fileBacked = false``) has none.
  var found = false
  for v in CollisionVerdict:
    if $v == s.verdict:
      result.verdict = v
      found = true
  if not found:
    raise newException(AddonApplyError, "the pending plan names an unknown " &
      "collision verdict '" & s.verdict & "' for " & s.address)
  result.observation = s.observation
  result.observedSha256 = s.observedSha256
  result.reason = s.reason & " (replayed)"
  result.acceptedOutOfBand = s.reason == AcceptedOutOfBandReason
  if fileBacked and result.verdict in {cvAdopt, cvReconcile}:
    if s.preserved.len == 0 or not fileExists(s.preserved):
      raise newException(AddonApplyError, "the pending plan's preserved " &
        "bytes for " & s.address & " are missing (" & s.preserved & ")")
    result.preWriteBytes = readFile(s.preserved)

proc targetFor(address: string; inp: DecisionInputs; path: string;
               dec: CollisionDecision; obs: TargetObservation;
               saved: tuple[found: bool; plan: SavedPlan]): PlannedTarget =
  ## The pre-write guard's record of one decision. A replay rebuilds it
  ## from the interrupted switch's plan-time observation (the diversion and
  ## where systemd loaded the unit from), never from the host now.
  if not saved.found:
    return plannedTarget(address, inp, path, dec, obs)
  var cls = ucNone
  for c in UnitClass:
    if $c == saved.plan.unitClass: cls = c
  PlannedTarget(address: address, path: path, kind: inp.kind,
    unit: inp.unit, observation: dec.observation,
    observedSha256: dec.observedSha256, desiredSha256: inp.desiredSha256,
    verdict: dec.verdict, diversion: saved.plan.diversion, unitClass: cls,
    replay: true)

proc alreadyRestored*(e: LedgerEntry): bool =
  ## A replay finds the removals the interrupted switch already made:
  ## an object that had preserved bytes now carries exactly them (its
  ## restore ran), or is gone when it was the add-on's creation.
  if e.class in {lcEtcFile, lcUnit, lcDropIn} and e.replaced.len > 0 and
      fileExists(e.path) and not symlinkExists(e.path):
    # The base's own file is back (a diversion's removal moved the
    # package's copy back, or a restore ran): what the path held before the
    # add-on, by the digest the ledger recorded.
    let at = e.replaced.find("sha256:")
    if at >= 0 and sha256OfFile(e.path) == e.replaced[at + 7 .. ^1].strip():
      return true
  if e.preserved.len == 0: return false
  if e.replaced.len == 0:
    return not fileExists(e.path) and not symlinkExists(e.path)
  fileExists(e.path) and not symlinkExists(e.path) and
    sha256OfFile(e.path) == extractFilename(e.preserved)

proc replayTolerates(e: LedgerEntry; drift: string): bool =
  ## Differences a replay expects to find, because the interrupted switch
  ## caused them: the flip left a removed link-form object's link
  ## dangling, or a removal's restore already ran.
  (e.isLink and drift.startsWith("dangling")) or alreadyRestored(e)

proc accountFingerprintValue*(kind, name: string): string =
  ## The ``accounts`` fingerprint value of an account or group now, "" when
  ## it does not exist (read from the live passwd / group databases).
  let (file, prefix) = if kind == "group": ("/etc/group", "group:")
                       else: ("/etc/passwd", "user:")
  if not fileExists(file): return ""
  let rows = if kind == "group": parseGroup(readFile(file))
             else: parsePasswd(readFile(file))
  for (k, v) in rows:
    if k == prefix & name: return v
  ""

proc isUnitDependency*(kind: string): bool =
  ## Whether a `depends_on` of this kind names a unit (§4.1's `unit` class:
  ## a unit, or a timer, which is composed as one): its change reaches the
  ## dependent through the unit propagation of §7.3, not as a changed
  ## configuration file the unit reads.
  kind in [$srkSystemdSystemUnit, $srkSystemdSystemTimer]

proc droppedSupplementaryGroups*(r: SystemResource;
                                 groupText = ""): seq[string] =
  ## The supplementary groups a `passwd.user` update drops: its driver's
  ## `usermod --groups` sets exactly the declared set, so a live group the
  ## resource does not name goes (spec §4.4, "accounts"). Read from
  ## ``groupText``, else through NSS (`getent group`, the database `usermod`
  ## itself consults), else /etc/group when no getent is installed.
  if r.kind != srkPasswdUser: return
  var text = groupText
  if text.len == 0:
    let getent = resolveHostTool(["/usr/bin/getent", "/bin/getent"])
    if getent.len > 0:
      try:
        let g = runHostTool([getent, "group"], mergeStderr = false)
        if g.exitCode == 0: text = g.output
      except CatchableError:
        discard
    if text.len == 0 and fileExists("/etc/group"):
      text = readFile("/etc/group")
  for line in text.splitLines():
    let f = line.split(':')
    if f.len < 4 or f[0].len == 0: continue
    var members: seq[string]
    for m in f[3].split(','):
      if m.strip().len > 0: members.add(m.strip())
    if r.puName in members and f[0] notin r.puGroups and
        f[0] notin result:
      result.add(f[0])

proc accountKeyOf*(r: SystemResource): string =
  ## ``user:<name>`` / ``group:<name>`` of a ``passwd.*`` resource, "" else.
  case r.kind
  of srkPasswdUser: "user:" & r.puName
  of srkPasswdGroup: "group:" & r.pgName
  else: ""

proc decideAccount*(r: SystemResource; ledgerValue: string;
                    ledgerOwns, reconcileDrift, adopt: bool):
    CollisionDecision =
  ## The collision decision of a ``passwd.user`` / ``passwd.group`` (spec
  ## §4.1 ``sysusers`` row, §4.3). The account is compared the way its
  ## driver compares it: the observation masked by what the resource
  ## declares (reprobuild 1ad1f593c8), so a group's ``members`` is a subset
  ## requirement and an unpinned gid or uid is not compared.
  ##
  ## | account | verdict |
  ## |---|---|
  ## | absent | create |
  ## | present, as declared, the ledger owns it | no-op (accepted out of band when its fingerprint moved since the ledger) |
  ## | present, as declared, not the ledger's | adopt: recorded, nothing applied |
  ## | present, other than declared, the ledger owns it | update |
  ## | present, other than declared, not the ledger's | EDrift; `--reconcile-drift` converges it, `repro system adopt` claims it as it is |
  let op = toPrivilegedOperation(r)
  let obs = if r.kind == srkPasswdUser: observePasswdUser(op)
            else: observePasswdGroup(op)
  let kind = if r.kind == srkPasswdUser: "user" else: "group"
  let name = if r.kind == srkPasswdUser: r.puName else: r.pgName
  let now = accountFingerprintValue(kind, name)
  result.observation = if obs.present: "unowned" else: "absent"
  if not obs.present:
    result.verdict = cvCreate
    result.reason = "absent; created by its driver"
    return
  let asDeclared = obs.digestHex == posixSystemDesiredDigestHex(op)
  if asDeclared:
    if ledgerOwns:
      result.verdict = cvNoOp
      if ledgerValue.len > 0 and ledgerValue != now:
        result.acceptedOutOfBand = true
        result.reason = AcceptedOutOfBandReason
      else:
        result.reason = "owned by the ledger, as declared"
    else:
      result.verdict = cvAdopt
      result.reason = "present, unowned, as declared (" &
        (if kind == "group": "declared members present" else: "declared fields match") &
        "): adopted without a change"
    return
  if ledgerOwns:
    result.verdict = cvUpdate
    result.reason = "owned by the ledger; converged to the declaration"
  elif reconcileDrift:
    result.verdict = cvReconcile
    result.reason = "present, unowned, other than declared; " &
      "--reconcile-drift converges it"
  elif adopt:
    result.verdict = cvAdopt
    result.reason = "present, unowned, claimed by `repro system adopt` as it is"
  else:
    raise newException(AddonDriftError, "EDrift: account " & kind & " " &
      name & " (" & r.address & ") exists and is not as declared; review " &
      "it, then re-run with --reconcile-drift to converge it, or `repro " &
      "system adopt " & r.address & "` to take it as it is")

proc desiredBytes*(r: SystemResource): string =
  ## The bytes a resource puts on the host, as the switch's static tree
  ## and the collision pass see them.
  case r.kind
  of srkFsSystemFile: desiredFileContent(toPrivilegedOperation(r))
  of srkSystemdSystemUnit: renderedSystemUnitContent(r)
  of srkSystemdSystemDropIn: r.diContent
  of srkLinuxSysctl: sysctlDropInContent(r.sysctlKey, r.sysctlValue)
  of srkLinuxTmpfilesRule: r.tmpfilesContent
  of srkLinuxSysusersEntry: sysusersEntryContent(r)
  else: ""

proc switchStoreObjects*(r: SystemResource): seq[string] =
  ## The store prefixes a resource makes systemd run once the switch flips
  ## (spec §10.2): every one a unit, a ``collision = "dropIn"`` unit's
  ## drop-in or a ``systemDropIn`` names in the bytes it installs. The
  ## switch re-checks each before the flip and before step 7.
  when mutated("recheck-skips-dropin-prefixes"):
    # Falsifying build: round 1's collection, which read a unit's rendered
    # file and nothing a drop-in installs.
    if r.kind == srkSystemdSystemUnit and r.suCollision != "dropIn":
      return referencedStoreObjects(renderedSystemUnitContent(r))
    return @[]
  if r.kind in {srkSystemdSystemUnit, srkSystemdSystemDropIn}:
    referencedStoreObjects(desiredBytes(r))
  else: @[]

proc targetPathOf*(r: SystemResource): string =
  ## The file a resource materialises, "" for a kind without one.
  case r.kind
  of srkFsSystemFile: r.sfPath
  of srkSystemdSystemUnit: unitPath(r.suName)
  of srkSystemdSystemDropIn: systemDropInPath(r.diUnit, r.diName)
  of srkLinuxSysctl: sysctlDropInPath(toPrivilegedOperation(r))
  of srkLinuxTmpfilesRule: tmpfilesRulePath(r.tmpfilesName)
  of srkLinuxSysusersEntry: sysusersFragmentPath(r.seName)
  of srkLinuxDpkgDiversion: r.ddPath
  else: ""


proc declaredByProfile*(unit: string; declared: HashSet[string]): bool =
  ## ``unit`` is a unit the profile declares, or an instance
  ## (``foo@x.service``) of a template it declares (``foo@.service``): a
  ## drop-in for it is checked through the profile's own unit (A9 review
  ## round 4, finding 8: an instance drop-in over a template the same
  ## generation installs was refused, "nothing provides foo@x.service").
  if unit in declared: return true
  when mutated("instance-dropin-needs-provider"):
    return false
  let at = unit.find('@')
  let dot = unit.rfind('.')
  if at > 0 and dot > at + 1:
    return (unit[0 .. at] & unit[dot .. ^1]) in declared
  false

proc floorInstancesOf(tmpl: string; resources: openArray[SystemResource]):
    seq[string] =
  ## The instances of a floored template (``foo@.service``) the generation
  ## names: a drop-in for one, a unit that depends on one, or a unit of
  ## that name. systemd will not show the template itself.
  let at = tmpl.find('@')
  let typ = tmpl[tmpl.rfind('.') .. ^1]
  let stem = tmpl[0 .. at]
  proc consider(n: string; acc: var seq[string]) =
    if n.startsWith(stem) and n.endsWith(typ) and n.len > stem.len + typ.len and
        n != tmpl and n notin acc:
      acc.add(n)
  for r in resources:
    case r.kind
    of srkSystemdSystemDropIn: consider(r.diUnit, result)
    of srkSystemdSystemUnit:
      consider(r.suName, result)
      for t in r.suContent.splitWhitespace():
        for w in t.split({'=', ' '}):
          consider(w, result)
    else: discard

proc floorTemplateOf(name: string): string =
  ## ``foo@.service`` for an instance ``foo@x.service``, else "".
  let at = name.find('@')
  let dot = name.rfind('.')
  if at > 0 and dot > at + 1: name[0 .. at] & name[dot .. ^1] else: ""

proc revertHeldUnits*(refusals: openArray[string]; ownUnits: HashSet[string];
                      floored: openArray[string]): seq[string] =
  ## The units a revert keeps on hold for its floor check's ``refusals``
  ## (spec §10.1, A9 review round 12): each refusal's subject when it is a
  ## unit the generation installs (a template, for an instance), else
  ## every floored unit of the generation (``floored``): a refusal about a
  ## host's type-wide drop-in, the search path or the manager bears on all
  ## of them. Never a name the generation does not install: a hold on
  ## ``service`` would be a type-wide drop-in that keeps every service on
  ## the host from starting.
  for l in refusals:
    let c = l.find(": ")
    let subj = if c > 0: l[0 ..< c].strip() else: ""
    var u = ""
    when mutated("revert-holds-any-subject"):
      # Falsifying build: the first cut, any subject held as named.
      u = (let t = floorTemplateOf(subj); if t.len > 0: t else: subj)
    else:
      let t = floorTemplateOf(subj)
      if t.len > 0 and t in ownUnits: u = t
      elif subj in ownUnits: u = subj
    if u.len == 0:
      for f in floored:
        if f notin result: result.add(f)
    elif u notin result:
      result.add(u)

proc startHoldPath*(unit: string): string =
  ## Where the switch's start hold for ``unit`` (a template's, for an
  ## instance: one hold covers every instance) is written
  ## (``start_holds.holdPath``, shared with the full apply).
  holdPath(unit, StartHoldName)

proc flooredUnitNames(resources: openArray[SystemResource]): seq[string] =
  for r in resources:
    if r.kind == srkSystemdSystemUnit and r.suCollision != "dropIn" and
        effectiveFloor(r).len > 0:
      result.add(r.suName)

proc writeStartHolds*(resources: openArray[SystemResource];
                      extra: openArray[string] = []): seq[string] =
  ## A start hold for every floored unit of the generation, and for each
  ## unit of ``extra`` (the services the carried-state cross-check judges;
  ## A13 review round 6, finding 6), written before step 6's reload (spec
  ## §10.1, A9 review round 4, finding 7). Returns the holds written.
  when mutated("floor-start-unheld"):
    return
  var units = flooredUnitNames(resources)
  for u in extra:
    if u notin units: units.add(u)
  writeHolds(units, StartHoldName, StartHoldText)

proc removeStartHolds*(holds: openArray[string]) =
  ## Remove each hold file, and its directory only when the hold was the
  ## last thing in it (``start_holds.removeHolds``; A9 review round 5,
  ## finding 5).
  removeHolds(holds)

proc clearStaleStartHolds*(root = "/run/systemd/system"): seq[string] =
  ## Every start hold under ``root`` that an earlier switch left behind --
  ## one whose check refused, before a revert to a generation with no
  ## floored unit, or a switch that died -- removed (A9 review round 5,
  ## finding 5). Returns the holds removed.
  clearStaleHolds(StartHoldName, root)

proc unitSearchPaths*(): seq[string] =
  ## systemd's unit search path (``systemd-analyze unit-paths``): every
  ## directory a drop-in may be read from, vendor ones included.
  let exe = resolveHostTool(SystemdAnalyzeCandidates)
  if exe.len == 0:
    raise newException(HostToolMissing, "systemd-analyze not found")
  let r = runHostTool([exe, "unit-paths"], mergeStderr = false)
  if r.exitCode != 0:
    raise newException(OSError, "systemd-analyze unit-paths: " & r.output.strip())
  for l in r.output.splitLines():
    if l.strip().startsWith("/"): result.add(l.strip())

proc dropInDirApplies*(dir, unit: string): bool =
  ## Whether systemd reads the drop-in directory ``dir`` (``<name>.d``'s
  ## name, without ``.d``) for ``unit`` or -- for a template
  ## ``foo@.service`` -- for any of its instances: the unit's own name, an
  ## instance's name, the template's, a dashed prefix (``foo-.service``)
  ## and the type-wide ``service`` (systemd.unit(5), "Description").
  ## Independent of the profile's parse-time ``dropInApplies``.
  let dot = unit.rfind('.')
  if dot <= 0: return false
  let typ = unit[dot .. ^1]
  if dir == unit or dir == typ[1 .. ^1]: return true
  if not dir.endsWith(typ): return false
  let dstem = dir[0 ..< dir.len - typ.len]
  let stem = unit[0 ..< dot]
  let at = stem.find('@')
  if at >= 0 and at == stem.len - 1:
    # A template: every instance name, and the template's own.
    if dstem.startsWith(stem): return true
  if dstem.endsWith("-") and stem.startsWith(dstem): return true
  if at >= 0 and dstem.endsWith("-") and stem[0 .. at].startsWith(dstem):
    return true
  false

proc foreignDropInsFor*(units: openArray[string]; own: HashSet[string];
                        roots: openArray[string]): seq[string] =
  ## Every drop-in file under ``roots`` that systemd would read for one of
  ## ``units`` (or any instance of a template among them) and that is not
  ## in ``own``: a host's, a package's, or a type-wide one (spec §10.1, A9
  ## review round 4, findings 2 and 3).
  for root in roots:
    if not dirExists(root): continue
    for kind, d in walkDir(root):
      if kind notin {pcDir, pcLinkToDir} or not d.endsWith(".d"): continue
      let name = extractFilename(d)[0 ..< extractFilename(d).len - 2]
      var applies = false
      for u in units:
        if dropInDirApplies(name, u): applies = true
      if not applies: continue
      for k2, f in walkDir(d):
        if f.endsWith(".conf") and f notin own:
          result.add(f)

proc unitStartsReported*(unit: string; own: HashSet[string];
                         cache: var Table[string, seq[string]]): seq[string] =
  ## What starting ``unit`` starts, as systemd reports it: for a unit of the
  ## generation (``own``, a template's instances included) every starting
  ## dependency and what it triggers; for a unit the base defines what it
  ## pulls in (``BaseReachKeys``), not its own ``OnFailure=`` (A9 review
  ## round 7, finding 4). Cached per check. A unit systemd cannot show
  ## starts nothing it could report.
  if unit in cache: return cache[unit]
  let mine = declaredByProfile(unit, own)
  var keys = if mine: @StartingDependencyKeys & @["Triggers"] else: @BaseReachKeys
  try:
    let r = runSystemctl(@["show", "--no-pager", "-p", keys.join(","), "--", unit])
    if r.exitCode == 0:
      for k, v in parseShow(r.output):
        for t in v.splitWhitespace(): result.add(t)
  except CatchableError:
    discard
  cache[unit] = result

proc createdDirsPath*(stateDir: string): string =
  ## The directories the add-on recorded as created for a floored unit by
  ## its own start (§13 decisions 57, 67, 68, 71 and 76): one
  ## ``<path>\t<unit>\t<st_dev>\t<st_ino>\t<birth ns>\t<InvocationID>``
  ## line each.
  addonDir(stateDir) / "floor-created-dirs"

proc recordKeptMarker*(stateDir, generationId: string): string =
  ## The marker an engine that keeps ``floor-created-dirs`` writes into
  ## every generation it sets (§13 decision 72): a committed generation
  ## without it was written by an older engine.
  generationDir(stateDir, generationId) / "floor-record-kept"

proc readCreatedDirs*(stateDir: string): Table[string, CreatedDir] =
  ## ``createdDirsPath``. An unreadable file, or a line without the full
  ## identity (round 9's and round 10's shorter forms), records nothing:
  ## every existing tree is then refused until the unit's next start
  ## records it (fail closed).
  try:
    for l in readFile(createdDirsPath(stateDir)).splitLines():
      let f = l.split('\t')
      if f.len == 6 and f[0].startsWith("/") and f[1].len > 0:
        try:
          result[f[0]] = CreatedDir(unit: f[1], dev: parseBiggestUInt(f[2]),
                                    ino: parseBiggestUInt(f[3]),
                                    btime: parseBiggestInt(f[4]), invocation: f[5])
        except ValueError: discard
  except IOError, OSError: discard

proc writeDurably(path, text: string) =
  ## ``text`` at ``path``, atomically and durably: a temporary file in the
  ## same directory, ``fsync``-ed, renamed over ``path``, then the
  ## directory ``fsync``-ed, so a crash leaves the old record or the new one
  ## (rename(2), fsync(2)).
  let tmp = path & ".tmp"
  let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_TRUNC or O_CLOEXEC, 0o600)
  if fd < 0: raiseOSError(osLastError(), tmp)
  try:
    var off = 0
    while off < text.len:
      let n = posix.write(fd, unsafeAddr text[off], text.len - off)
      if n < 0: raiseOSError(osLastError(), tmp)
      off += n
    if fsync(fd) != 0: raiseOSError(osLastError(), tmp)
  finally:
    discard posix.close(fd)
  moveFile(tmp, path)
  let dfd = posix.open(parentDir(path).cstring, O_RDONLY or O_CLOEXEC)
  if dfd >= 0:
    discard fsync(dfd)
    discard posix.close(dfd)

proc writeCreatedDirs(stateDir: string; t: Table[string, CreatedDir]) =
  var text = ""
  for k, v in t:
    text.add(k & "\t" & v.unit & "\t" & $v.dev & "\t" & $v.ino & "\t" &
             $v.btime & "\t" & v.invocation & "\n")
  writeDurably(createdDirsPath(stateDir), text)

proc entryOf(unit: string; now: PathIdentity; invocation: string): CreatedDir =
  CreatedDir(unit: unit, dev: now.dev, ino: now.ino, btime: now.btime,
             invocation: invocation)

proc recordCreatedDirs*(stateDir, unit: string;
                        pending: openArray[tuple[path, unit: string]];
                        identityOf: proc (p: string): PathIdentity = identityOfPath;
                        invocation = "") =
  ## Called right after ``unit``'s own start (§13 decision 68): record, for
  ## it, each of its directories the check found absent that exists now, so
  ## its start created it (systemd.exec(5)), with the identity it has (§13
  ## decision 76: device, inode and birth time; a path whose file system
  ## reports no birth time is not recorded, so it stays refused). Only
  ## ``unit``'s own pending paths: another unit's start, later in the same
  ## step, records its own. Every entry already there is kept only while its
  ## path still has the recorded identity; one whose directory is gone (a
  ## ``RuntimeDirectory=`` at stop, ``/run`` at reboot) or was replaced is
  ## dropped, so a later tree at that path is judged afresh. Written
  ## atomically and durably (``writeDurably``).
  when mutated("created-dirs-ignored"): return
  let before = readCreatedDirs(stateDir)
  var t = initTable[string, CreatedDir]()
  for path, c in before:
    let now = identityOf(path)
    when mutated("created-dirs-by-path"):
      t[path] = c
    else:
      if sameIdentity(c, now):
        t[path] = c
  for (path, u) in pending:
    when not mutated("created-dirs-per-step"):
      if u != unit: continue
    if path in t:
      # The same directory, now the run this start began (spec §10.1
      # round 12, "A directory made again outside a switch"): its
      # InvocationID is recorded, so a tree made at the path later in this
      # same run is not taken as a new run's (A9 review round 12).
      when not mutated("record-keeps-old-invocation"):
        if invocation.len > 0 and t[path].invocation != invocation and
            flooredKey(t[path].unit) == flooredKey(unit):
          t[path].invocation = invocation
          t[path].unit = unit
      continue
    let now = identityOf(path)
    if now.exists and now.btime != 0:
      t[path] = entryOf(u, now, invocation)
  if t == before: return
  writeCreatedDirs(stateDir, t)

proc recordStartedSince*(stateDir: string;
                         pending: openArray[tuple[path, unit: string]];
                         invocationOf: proc (u: string): tuple[id: string; start: int64];
                         identityOf: proc (p: string): PathIdentity = identityOfPath) =
  ## After the start step (spec §10.1 round 12, "What the start step made"):
  ## each pending directory -- one
  ## the check found absent -- that exists now is recorded for the unit it
  ## was pending for, as ``recordCreatedDirs`` does for a unit the switch
  ## started by name. That covers a unit the switch did not start by name
  ## but that started during it (a template instance a ``Wants=`` pulled
  ## in), and a directory its activator's start made for it (a socket's
  ## start makes the listener's parent, ``/run/<stem>``, which is the
  ## service's ``RuntimeDirectory=``; A9 review round 12, finding 3). The
  ## residual is the start step's own: a tree another process makes there
  ## between the check and the start is recorded as the unit's. The
  ## unit's ``InvocationID`` is recorded with it, empty when it has none.
  when mutated("dependency-starts-unrecorded"): return
  when mutated("created-dirs-ignored"): return
  var t = readCreatedDirs(stateDir)
  var changed = false
  # One entry per path. A template's directory is pending for its
  # observation instance, which never runs, and for each instance the
  # generation names; it is recorded for an instance that has a run
  # (an InvocationID), never for the observation instance while one does
  # (A9 review round 12, finding 4).
  var order: seq[string]
  var units = initTable[string, seq[string]]()
  for (path, u) in pending:
    if path notin units: order.add(path)
    units.mgetOrPut(path, @[]).add(u)
  for path in order:
    let now = identityOf(path)
    if not now.exists or now.btime == 0: continue
    var same = false
    if path in t:
      let c = t[path]
      # Kept while it is still that directory; a stale entry (the unit's
      # restart made it again) is replaced.
      same = sameIdentity(c, now)
    var best = ""
    var bestId = ""
    when mutated("start-step-records-first-unit"):
      # Falsifying build: round 12's first cut, the first pending unit
      # (the observation instance, for a template).
      best = units[path][0]
      bestId = invocationOf(best).id
    for u in units[path]:
      when mutated("start-step-records-first-unit"): break
      let id = invocationOf(u).id
      if best.len == 0 or (bestId.len == 0 and id.len > 0) or
          (isObservationInstance(best) and not isObservationInstance(u) and
           (id.len > 0 or bestId.len == 0)):
        best = u
        bestId = id
    if same:
      # The same directory: only the run it now belongs to is refreshed
      # (spec §10.1 round 12, "A directory made again outside a
      # switch"), so a later tree in this run is not a new run's.
      when not mutated("record-keeps-old-invocation"):
        if bestId.len > 0 and t[path].invocation != bestId and
            flooredKey(t[path].unit) == flooredKey(best):
          t[path].invocation = bestId
          t[path].unit = best
          changed = true
      continue
    t[path] = entryOf(best, now, bestId)
    changed = true
  if changed: writeCreatedDirs(stateDir, t)

proc acceptRecreated*(stateDir, path, unit, invocation: string;
                      identityOf: proc (p: string): PathIdentity = identityOfPath) =
  ## Record ``path`` again for ``unit`` under the identity it has now and
  ## the invocation systemd made it for, once the effective check accepted
  ## it by §13 decision 71. Raises when it cannot be written, so the
  ## acceptance is not made.
  var t = readCreatedDirs(stateDir)
  let now = identityOf(path)
  if not now.exists or now.btime == 0:
    raise newException(IOError, path & ": no identity to record")
  t[path] = entryOf(unit, now, invocation)
  writeCreatedDirs(stateDir, t)

proc createdDirsAbsent*(stateDir: string): bool =
  ## The record file does not exist at all (``lstat`` says ENOENT). A file
  ## that exists but cannot be read, or holds nothing valid, is present: it
  ## fails closed in the effective check (every existing tree refused) and
  ## never counts as absent, so it cannot start the migration again (§13
  ## decision 72).
  when mutated("corrupt-record-as-absent"):
    # Falsifying build: an unreadable or empty record taken as absent.
    return not fileExists(createdDirsPath(stateDir)) or
      readCreatedDirs(stateDir).len == 0
  var st: Stat
  if lstat(createdDirsPath(stateDir).cstring, st) == 0: return false
  osLastError().int32 == ENOENT

proc installedDirectories*(unitFile: string; dropIns: openArray[string]): seq[string] =
  ## The directories a unit the add-on installed declares, read from the
  ## files the add-on wrote for it (its unit file, then its own drop-ins in
  ## order), not from systemd's view, which a drop-in the add-on did not
  ## write could add to (A9 review round 11, finding 5). Each
  ## ``*Directory=`` value under its root; an empty assignment resets.
  var vals = initTable[string, seq[string]]()
  for f in @[unitFile] & @dropIns:
    var text = ""
    try: text = readFile(f)
    except IOError, OSError: continue
    for (k, v) in serviceDirectives(text):
      for (dk, _) in DirectoryRoots:
        if k != dk: continue
        if v.strip().len == 0: vals[k] = @[]
        else: vals.mgetOrPut(k, @[]).add(v.splitWhitespace())
  for (k, root) in DirectoryRoots:
    for v in vals.getOrDefault(k):
      let d = v.split(':')[0]
      if d.len > 0 and '/' notin d: result.add(normalisedPath(root & "/" & d))

proc installedListeners*(unitFile: string; dropIns: openArray[string]):
    tuple[service: string; paths: seq[string]] =
  ## The unix listeners an activator the add-on installed declares, and the
  ## service it starts, read from the files the add-on wrote for it (its
  ## unit file, then its own drop-ins; an empty assignment resets), for the
  ## one-time migration (spec §10.1 round 12, "The migration records
  ## listeners").
  let name = extractFilename(unitFile)
  let dot = name.rfind('.')
  if dot <= 0 or name[dot + 1 .. ^1] != "socket": return
  var explicit, accept = ""
  var vals: seq[string]
  for f in @[unitFile] & @dropIns:
    var text = ""
    try: text = readFile(f)
    except IOError, OSError: continue
    for d in serviceFloor.sectionDirectives(text, ["Socket"]):
      case d.key
      of "Service": explicit = d.value.strip()
      of "Accept": accept = d.value.strip()
      of "ListenStream", "ListenDatagram", "ListenSequentialPacket":
        if d.value.strip().len == 0: vals = @[]
        elif d.value.strip().startsWith("/"): vals.add(normalisedPath(d.value.strip()))
      else: discard
  result.paths = vals
  result.service =
    if explicit.len > 0: explicit
    elif accept.toLowerAscii() in ["yes", "true", "1", "on"]: name[0 ..< dot] & "@.service"
    else: name[0 ..< dot] & ".service"

proc migrateCreatedDirs*(stateDir, committed: string; previous: Ledger;
                         invocationOf: proc (unit: string): string;
                         audit: proc (path: string; c: CreatedDir): bool;
                         identityOf: proc (p: string): PathIdentity = identityOfPath;
                         showOf: proc (unit: string): ShowProps = nil;
                         alsoUnits: openArray[string] = []):
                         seq[tuple[path: string; entry: CreatedDir]] =
  ## §13 decision 72, the one-time migration of a host whose committed
  ## generation an engine without the record wrote. It runs only when the
  ## record file is absent (``createdDirsAbsent``) and the committed
  ## generation carries no ``recordKeptMarker``, which every engine that
  ## keeps the record writes into each generation it sets. It records, with
  ## its identity (device, inode, birth time) and the unit's invocation,
  ## each existing directory exactly declared by a floored unit the
  ## committed generation's ledger installed (``lcUnit``, its unit file
  ## carrying the floor's block), as that generation's own files declare it
  ## (``installedDirectories``, never systemd's view), whose name is no
  ## base tree and whose directory passes the shape rule. Each entry is
  ## audit-logged first (``audit``); one that cannot be logged is not
  ## recorded, so it stays refused. Then it writes the record file,
  ## atomically and durably, even empty, so it never runs again; with no
  ## committed generation, or one an engine with the record wrote, it only
  ## writes the empty file. After it, only provenance counts (decision 71).
  ## ``showOf`` serves only the falsifying build ``migration-reads-systemd``.
  when not mutated("migration-reruns"):
    if not createdDirsAbsent(stateDir): return
  var t = initTable[string, CreatedDir]()
  var olderEngine = committed.len > 0 and
    not fileExists(recordKeptMarker(stateDir, committed))
  when mutated("migration-ignores-engine"):
    olderEngine = committed.len > 0
  if olderEngine:
    var units: seq[tuple[name, file: string]]
    var dropIns = initTable[string, seq[string]]()
    for e in previous.entries:
      if e.class == lcUnit:
        let name = if e.unit.len > 0: e.unit else: extractFilename(e.path)
        units.add((name, e.path))
      elif e.class == lcDropIn and e.unit.len > 0:
        dropIns.mgetOrPut(e.unit, @[]).add(e.path)
    when mutated("migration-any-unit"):
      for u in alsoUnits: units.add((u, ""))
    for (unit, file) in units:
      if '@' in unit: continue                  # a template: no one instance
      if baseTreeUnitRefusal(unit).len > 0: continue
      when not mutated("migration-any-unit"):
        var text = ""
        try: text = readFile(file)
        except IOError, OSError: continue
        if FloorMarker notin text: continue     # not a floored unit
      var candidates: seq[string]
      when mutated("migration-any-unit"):
        # Falsifying build: a unit the committed generation did not install
        # (no file of its own) taken from systemd's view.
        if file.len == 0 and showOf != nil:
          let sh = showOf(unit)
          for (k, root) in DirectoryRoots:
            for v in sh.getOrDefault(k).splitWhitespace():
              let d = v.split(':')[0]
              if d.len > 0 and '/' notin d: candidates.add(normalisedPath(root & "/" & d))
      when mutated("migration-any-path"):
        if showOf != nil:
          for fp in firstComponentPaths(showOf(unit)): candidates.add(fp.path)
      elif mutated("migration-reads-systemd"):
        # Falsifying build: round 10's reading, systemd's view (foreign
        # drop-ins included).
        if showOf != nil:
          let sh = showOf(unit)
          for (k, root) in DirectoryRoots:
            for v in sh.getOrDefault(k).splitWhitespace():
              let d = v.split(':')[0]
              if d.len > 0 and '/' notin d: candidates.add(normalisedPath(root & "/" & d))
      else:
        for d in installedDirectories(file, dropIns.getOrDefault(unit)):
          let first = d.split('/')[^1]
          var shapeOk = true
          for (k, root) in DirectoryRoots:
            if d == normalisedPath(root & "/" & first) and
                managerDirectoryRefusal(unit, k, first).len > 0:
              shapeOk = false
          if shapeOk: candidates.add(d)
      for path in candidates:
        if inAddOnTree(path) or path in t: continue
        let now = identityOf(path)
        if now.exists and now.btime != 0:
          let c = entryOf(unit, now, invocationOf(unit))
          when mutated("unlogged-migration"):
            discard audit(path, c)
            t[path] = c
          else:
            if audit(path, c): t[path] = c
    # Spec §10.1 round 12, "The migration records listeners": the unix
    # listeners of the activators that generation
    # installed for its floored services, as its own files declare them and
    # where the listener rule allows them, recorded for the activator, so
    # the first apply under this engine, and its revert, pass decision 78's
    # existing-listener rule.
    when not mutated("migration-skips-listeners"):
      var flooredFiles = initHashSet[string]()
      for (unit, file) in units:
        try:
          if FloorMarker in readFile(file): flooredFiles.incl(unit)
        except IOError, OSError: discard
      for (unit, file) in units:
        if not unit.endsWith(".socket") or file.len == 0 or '@' in unit: continue
        let (service, paths) = installedListeners(file, dropIns.getOrDefault(unit))
        let at = service.find('@')
        let sdot = service.rfind('.')
        let tpl = if at > 0 and sdot > at: service[0 .. at] & service[sdot .. ^1] else: service
        if service notin flooredFiles and tpl notin flooredFiles: continue
        for path in paths:
          if inAddOnTree(path) or path in t: continue
          if serviceFloor.listenerRefusal(unit, path, service).len > 0: continue
          let now = identityOf(path)
          if now.exists and now.btime != 0:
            let c = entryOf(unit, now, invocationOf(unit))
            if audit(path, c): t[path] = c
  writeCreatedDirs(stateDir, t)
  for k, v in t: result.add((k, v))

type UnitRun* = object
  ## One snapshot of a unit's run, from one ``systemctl show`` (A9 review
  ## round 12, finding 5): its ``InvocationID``, when its current or last
  ## run began (``InactiveExitTimestamp``) and ended
  ## (``InactiveEnterTimestamp``, for a unit not running), and whether it
  ## runs (``ActiveState``). Times are nanoseconds since the epoch, 0 when
  ## systemd does not say.
  id*: string
  start*, stop*: int64
  running*: bool

proc parseUtcStamp(v: string): int64 =
  ## "Sun 2026-11-08 10:00:00.123456 UTC" (``--timestamp=us+utc``) in
  ## nanoseconds since the epoch, or 0.
  let parts = v.strip().splitWhitespace()
  if parts.len == 4 and parts[3] == "UTC":
    try:
      let dt = parse(parts[1] & " " & parts[2].split('.')[0], "yyyy-MM-dd HH:mm:ss", utc())
      var us = 0'i64
      if '.' in parts[2]: us = parseBiggestInt(parts[2].split('.')[1])
      return dt.toTime.toUnix * 1_000_000_000'i64 + us * 1000
    except ValueError, TimeParseError: discard
  0

proc parseUnitRun*(output: string): UnitRun =
  ## ``UnitRun`` from the output of ``systemctl show --timestamp=us+utc -p
  ## InvocationID -p InactiveExitTimestamp -p InactiveEnterTimestamp -p
  ## ActiveState``.
  for l in output.splitLines():
    let eq = l.find('=')
    if eq <= 0: continue
    let k = l[0 ..< eq]
    let v = l[eq + 1 .. ^1].strip()
    case k
    of "InvocationID": result.id = v
    of "InactiveExitTimestamp": result.start = parseUtcStamp(v)
    of "InactiveEnterTimestamp": result.stop = parseUtcStamp(v)
    of "ActiveState": result.running = v in ["active", "activating", "reloading"]
    else: discard

proc unitRun*(unit: string;
              show: proc (args: seq[string]): tuple[exitCode: int; output: string] = nil):
              UnitRun =
  ## ``unit``'s run, read in one ``systemctl show`` (``show`` stands in for
  ## systemctl in tests); empty when systemd does not say.
  let args = @["show", "--no-pager", "--timestamp=us+utc", "-p", "InvocationID",
               "-p", "InactiveExitTimestamp", "-p", "InactiveEnterTimestamp",
               "-p", "ActiveState", "--", unit]
  try:
    let r = (if show != nil: show(args)
             else: (let x = runSystemctl(args); (x.exitCode, x.output)))
    if r.exitCode != 0: return
    result = parseUnitRun(r.output)
  except CatchableError: discard

proc unitInvocation*(unit: string): tuple[id: string; start: int64] =
  ## The unit's current ``InvocationID`` and when that invocation began
  ## (``unitRun``).
  let r = unitRun(unit)
  (r.id, r.start)

proc hostRunningInstances*(tmpl: string): seq[string] =
  ## The instances of the template ``tmpl`` (``a@.service``) systemd reports
  ## active, activating or reloading (``systemctl list-units``); empty when
  ## it does not say.
  let at = tmpl.find('@')
  if at <= 0: return
  let pattern = tmpl[0 .. at] & "*" & tmpl[at + 1 .. ^1]
  try:
    let r = runSystemctl(@["list-units", "--plain", "--no-legend", "--no-pager",
                           "--state=active,activating,reloading", "--", pattern])
    if r.exitCode != 0: return
    for l in r.output.splitLines():
      let w = l.splitWhitespace()
      if w.len > 0 and w[0].startsWith(tmpl[0 .. at]) and w[0] != tmpl:
        result.add(w[0])
  except CatchableError: discard

proc hostSystemdView*(path, unit: string; show: ShowProps;
                      systemctlShow: proc (args: seq[string]):
                        tuple[exitCode: int; output: string] = nil): SystemdView =
  ## systemd's own state of ``path``, a directory of ``unit``, for §13
  ## decisions 71 and 77: the directory's birth time (through systemd's own
  ## ``private/<name>`` link of a dynamic user and no other link) and the
  ## start of the unit's current invocation. The dynamic-uid record, the
  ## owner and the ctime are read for the audit log only.
  result.dynamicUid = -1
  result.owner = -1
  if show.getOrDefault("DynamicUser") == "yes":
    # With no User=, systemd names the dynamic user after the unit, its
    # name without the type suffix (systemd.exec(5), DynamicUser=).
    var user = show.getOrDefault("User")
    if user.len == 0:
      let dot = unit.rfind('.')
      user = if dot > 0: unit[0 ..< dot] else: unit
    if user.len > 0:
      try:
        for kind, f in walkDir("/run/systemd/dynamic-uid"):
          if kind != pcFile: continue
          try:
            if readFile(f).strip(chars = {'\0', '\n', ' '}) == user:
              result.dynamicUid = parseInt(extractFilename(f))
          except IOError, OSError, ValueError: discard
      except OSError: discard
  var target = path
  var st: Stat
  if lstat(path.cstring, st) == 0 and S_ISLNK(st.st_mode):
    try:
      let l = expandSymlink(path)
      if l == "private/" & extractFilename(path):
        target = parentDir(path) / l
      else:
        return
    except OSError: return
  if stat(target.cstring, st) == 0:
    result.owner = int(st.st_uid)
    result.ctime = int64(st.st_ctim.tv_sec)
  result.btime = birthTimeOf(target)
  when mutated("view-two-calls"):
    # Falsifying build: round 11's two reads, the start and the state from
    # separate calls.
    let a = unitRun(unit, systemctlShow)
    let b = unitRun(unit, systemctlShow)
    result.invocationId = a.id
    result.invocationStart = a.start
    result.lastStop = a.stop
    result.stopped = not b.running
  else:
    let run = unitRun(unit, systemctlShow)
    result.invocationId = run.id
    result.invocationStart = run.start
    result.lastStop = run.stop
    result.stopped = not run.running

proc refusalLine*(subject, code, key, msg: string): string =
  ## A refusal line of the effective check that no rule of
  ## ``effective_floor`` produced (a report systemd did not give, a file it
  ## loaded that cannot be read): tagged like every other (A9 review round
  ## 10, finding 4), so the gate cannot take it for no reason.
  when mutated("refusal-lines-untagged"):
    subject & ": " & msg
  else:
    subject & ": " & msg & " [rule:" & code & " key:" & key & "]"

proc effectiveFloorCheck*(resources: openArray[SystemResource];
                          owned: seq[string] = @[];
                          adopted = initTable[string, string]();
                          created = initTable[string, CreatedDir]();
                          pending: ptr seq[tuple[path, unit: string]] = nil;
                          ledgerDirs = initHashSet[string]();
                          recreated: ptr seq[tuple[path, unit: string; v: SystemdView]] = nil;
                          acceptRecreatedLogged: proc (path, unit: string; v: SystemdView): bool = nil):
                          seq[string] =
  ## ``owned``: the store objects the generation owns with a recorded
  ## digest; an ``EnvironmentFile=`` or a read-only bind source must lie in
  ## one (A9 review round 7, findings 1 and 5).
  ## Every floored unit of the generation as systemd now reads it, against
  ## the floor it is rendered under (``effective_floor``; spec §10.1, A9
  ## review rounds 3 and 4): one problem line per difference. For a
  ## template, its probe instance and each instance the generation names;
  ## and for every floored unit, any drop-in on the unit search path the
  ## generation did not write (a template's instances included, named or
  ## not). Called after step 6's reload, while the start holds keep every
  ## floored unit from starting, and before step 7.
  var groups = initTable[string, seq[string]]()
  var groupsRead = false
  var own = initHashSet[string]()
  for d in resources:
    if d.kind == srkSystemdSystemDropIn: own.incl(targetPathOf(d))
  for u in flooredUnitNames(resources): own.incl(startHoldPath(u))
  # A revert's persistent holds are the add-on's own (§13 decision 126).
  var revertHoldFiles: seq[string]
  for d in [PersistentUnitDir, RuntimeUnitDir]:
    try: revertHoldFiles.add(staleHolds(RevertHoldName, d))
    except OSError: discard
  for h in revertHoldFiles: own.incl(h)
  var ownUnits = initHashSet[string]()
  for d in resources:
    if d.kind == srkSystemdSystemUnit: ownUnits.incl(d.suName)
  var ownFiles: seq[string]
  for d in resources:
    if d.kind == srkFsSystemFile: ownFiles.add(d.sfPath)
  var startsCache = initTable[string, seq[string]]()
  let startsOf = proc (u: string): seq[string] =
    unitStartsReported(u, ownUnits, startsCache)
  var conflictsCache = initTable[string, seq[string]]()
  let conflictsOf = proc (u: string): seq[string] =
    if u in conflictsCache: return conflictsCache[u]
    try:
      let r = runSystemctl(@["show", "--no-pager", "-p", "Conflicts", "--value", "--", u])
      if r.exitCode == 0: result = r.output.splitWhitespace()
    except CatchableError: discard
    conflictsCache[u] = result
  var limits = initTable[string, string]()
  if flooredUnitNames(resources).len > 0:
    try: limits = managerLimits()
    except CatchableError as ex:
      result.add(refusalLine("the service manager", "manager-limits", "-",
                             "its limits cannot be read: " & ex.msg))
  when not mutated("unnamed-instances-unchecked"):
    try:
      for f in foreignDropInsFor(flooredUnitNames(resources), own,
                                 unitSearchPaths()):
        # Named by the unit its directory is for (<unit>.d), and tagged with
        # its rule like every other refusal (A9 review round 9, finding 3).
        let dir = extractFilename(parentDir(f))
        let unit = if dir.endsWith(".d"): dir[0 ..< dir.len - 2] else: dir
        result.add(unit & ": " & f & ": a drop-in the add-on did not install, " &
                   "read for a floored unit (or an instance of a floored " &
                   "template) [rule:foreign-drop-in key:DropInPaths]")
    except CatchableError as e:
      result.add(refusalLine("the unit search path", "search-path", "DropInPaths",
                             e.msg))
  for r in resources:
    if effectiveFloor(r).len == 0 or r.suCollision == "dropIn": continue
    let rendered = renderedSystemUnitContent(r)
    if not groupsRead:
      groups = baseSyscallGroups()
      groupsRead = true
    let denied = deniedCalls(rendered, groups)
    var names: seq[string]
    # For a template: the instances the generation names, which every name
    # of it judges a remade directory against, and the directories an
    # earlier name refused, which a later name does not accept, so all its
    # names reach one verdict and a refused check rewrites no record (§13
    # decision 71; issue 2026-11-13-floor-template-observation-instance-
    # refuses-a-directory-its-instance-restart-made).
    var tmplInstances: seq[string]
    var tmplRefused: ref HashSet[string] = nil
    if r.suName.contains("@."):
      tmplInstances = floorInstancesOf(r.suName, resources)
      tmplRefused = new HashSet[string]
      tmplRefused[] = initHashSet[string]()
      when not mutated("unnamed-instances-unchecked"):
        names.add(templateObservationName(r.suName))
      names.add(tmplInstances)
    else:
      names = @[r.suName]
    # A template's directories decision 71 accepts are held until every
    # name of it has been checked, then recorded and logged once each, and
    # only if no name refused them (``commitRecreatedProblems``; same
    # issue). So is what the start step would record for them
    # (``startMayCreate``'s ``acceptedNow``): it stands only for a
    # directory that was written.
    var tentative: seq[RecreatedAcceptance]
    var heldPending: seq[tuple[path, unit: string]]
    for name in names:
      var e = EffectiveInput(unit: name, rendered: rendered,
        version: r.suFloorVersion, exceptions: r.suFloorExceptions,
        fragment: unitPath(r.suName), denied: denied, uidOf: systemUid,
        groupsOf: systemGroups, gidOf: systemGid, ownUnits: ownUnits,
        limitCeilings: limits, storeObjects: owned, ownFiles: ownFiles,
        adoptedFiles: adopted, startsOf: startsOf, conflictsOf: conflictsOf,
        createdDirs: created, ledgerDirs: ledgerDirs,
        systemdView: proc (p, u: string; s: ShowProps): SystemdView =
          hostSystemdView(p, u, s),
        runningInstances: hostRunningInstances,
        templateInstances: tmplInstances, templateRefused: tmplRefused)
      var acceptedNow: seq[string]
      var held: seq[tuple[path, unit: string; v: SystemdView]]
      if tmplRefused != nil:
        # A template: held, decided after its last name.
        e.onRecreated = proc (path, unit: string; v: SystemdView): bool =
          held.add((path, unit, v))
          acceptedNow.add(path)
          true
      else:
        e.onRecreated = proc (path, unit: string; v: SystemdView): bool =
          # Recorded again and logged, or not accepted (§13 decision 71; A9
          # review round 11, finding 6).
          if acceptRecreatedLogged == nil or not acceptRecreatedLogged(path, unit, v):
            return false
          acceptedNow.add(path)
          if recreated != nil: recreated[].add((path, unit, v))
          true
      for o in resources:
        if o.kind == srkSystemdSystemUnit and o.suName != r.suName and
            effectiveFloor(o).len > 0 and o.suCollision != "dropIn":
          e.otherWritable.add(floorWritablePlaces(serviceDirectives(
            renderedSystemUnitContent(o))))
      for d in resources:
        if d.kind == srkSystemdSystemDropIn and dropInApplies(d.diUnit, name):
          e.ownDropIns.add((path: targetPathOf(d), content: d.diContent))
      e.ownDropIns.add((path: startHoldPath(name), content: StartHoldText))
      for h in revertHoldFiles:
        e.ownDropIns.add((path: h, content: RevertHoldText))
      try:
        let text = showUnitText(name)
        e.show = parseShow(text)
        e.lines = parseShowLines(text)
      except CatchableError as ex:
        result.add(refusalLine(name, "show", "-", ex.msg))
        continue
      for f in @[e.show.getOrDefault("FragmentPath")] &
               e.show.getOrDefault("DropInPaths").splitWhitespace():
        if f.len == 0: continue
        try: e.loaded.add((path: f, content: readFile(f)))
        except IOError, OSError:
          result.add(refusalLine(name, "unreadable", "FragmentPath,DropInPaths",
                                 "cannot read " & f & ", which systemd loaded"))
      result.add(effectiveFloorProblems(e))
      for h in held:
        var key = ""
        for fp in firstComponentPaths(e.show):
          if fp.path == h.path:
            key = fp.key
            break
        noteRecreated(tentative, name, h.path, h.unit, key, h.v)
      # The first components the unit's start may create, or make again on
      # a restart (§13 decisions 57 and 68; ``startMayCreate``).
      if pending != nil:
        for fp in firstComponentPaths(e.show):
          # A directory decision 71 accepted just now is the unit's too:
          # this switch's restart of the unit makes it again.
          if startMayCreate(fp.path, name, identityOfPath(fp.path), created,
                            acceptedNow):
            if tmplRefused != nil and fp.path in acceptedNow:
              heldPending.add((fp.path, name))
            else:
              pending[].add((fp.path, name))
      # The units that trigger it: sockets, timers, path units (A9 review
      # round 5, finding 2), whoever defines them.
      when not mutated("activators-unchecked"):
        for a in e.show.getOrDefault("TriggeredBy").splitWhitespace():
          var aown: seq[string]
          for d in resources:
            if d.kind == srkSystemdSystemDropIn and dropInApplies(d.diUnit, a):
              aown.add(targetPathOf(d))
          try:
            let at = showUnitText(a)
            let ash = parseShow(at)
            var aloaded: seq[tuple[path, content: string]]
            for f in @[ash.getOrDefault("FragmentPath")] &
                     ash.getOrDefault("DropInPaths").splitWhitespace():
              if f.len == 0: continue
              try: aloaded.add((path: f, content: readFile(f)))
              except IOError, OSError:
                result.add(refusalLine(a, "unreadable", "FragmentPath,DropInPaths",
                                       "cannot read " & f & ", which systemd loaded"))
            # §13 decision 78: a unix listener is the activator's when its
            # path is absent now (its start creates it, and that start
            # records it) or the record names it for the activator, still
            # the same inode and birth time.
            let act = a
            let listenerProvenance = proc (path: string): string =
              let now = identityOfPath(path)
              if not now.exists:
                if pending != nil: pending[].add((path, act))
                return ""
              if createdForUnit(path, act, now, created, ledgerDirs): return ""
              if pending != nil and startMayCreate(path, act, now, created):
                pending[].add((path, act))
              # A path statx could not read (EACCES, a filter's EPERM, ELOOP)
              # is no less refused (A9 review round 12, finding 6).
              if now.dev == 0 and now.ino == 0 and now.btime == 0:
                return "its identity cannot be read"
              "it exists"
            result.add(activatorProblems(a, ash, parseShowLines(at),
                                         unitPath(a), aown, aloaded, startsOf,
                                         ownUnits, conflictsOf, listenerProvenance,
                                         serviceWritable = writablePlacesOf(e.show)))
          except CatchableError as ex:
            result.add(refusalLine(a, "show", "-", ex.msg))
    if tmplRefused != nil:
      var committed: seq[RecreatedAcceptance]
      result.add(commitRecreatedProblems(tentative, tmplRefused[],
                                         acceptRecreatedLogged, committed))
      var written = initHashSet[string]()
      for a in committed:
        written.incl(a.path)
        if recreated != nil: recreated[].add((a.path, a.unit, a.view))
      if pending != nil:
        for hp in heldPending:
          if hp.path in written: pending[].add(hp)

proc retargetedAddresses*(previous, wanted: openArray[SystemResource]):
    seq[tuple[address, was, now: string]] =
  ## The addresses that name a different object now than in the previous
  ## generation: same address, but another kind or another target path (a
  ## unit renamed while its `address` was kept). The ledger and the
  ## removal pass know objects by address, so such a resource would be
  ## neither removed nor kept: its old file would stay on the host, out of
  ## the ledger, and an old instance of a unit would keep running beside
  ## the new one -- for an `exclusive` unit, exactly the overlap §7.3
  ## forbids. The switch refuses it instead; a rename is a new address.
  var before = initTable[string, string]()
  for r in previous:
    before[r.address] = $r.kind & " " & targetPathOf(r)
  for r in wanted:
    let now = $r.kind & " " & targetPathOf(r)
    if r.address in before and before[r.address] != now:
      result.add((r.address, before[r.address], now))

proc preObserve(p: var ResourcePlan; driver: CollisionDriver) =
  case p.r.kind
  of srkFsSystemFile:
    p.targetPath = p.r.sfPath
    p.replaced = baseValue(p.r.sfPath)
    p.newDirs = missingParents(p.r.sfPath)
  of srkSystemdSystemDropIn, srkLinuxTmpfilesRule:
    p.targetPath = targetPathOf(p.r)
    p.replaced = baseValue(p.targetPath)
    p.newDirs = missingParents(p.targetPath)
  of srkLinuxSysctl:
    p.targetPath = targetPathOf(p.r)
    p.replaced = baseValue(p.targetPath)
    p.newDirs = missingParents(p.targetPath)
    # The value the key has before the add-on sets it, read from the
    # host's namespaces (a net.* key inside PrivateNetwork is not the
    # host's): what removal restores and what the ledger's delta expects.
    p.sysctlBefore = observeSysctlInHostNamespaces(p.r.sysctlKey)
  of srkLinuxSysusersEntry:
    p.targetPath = targetPathOf(p.r)
    p.replaced = baseValue(p.targetPath)
    p.newDirs = missingParents(p.targetPath)
    p.accountKey = (if p.r.seKind == "group": "group:" else: "user:") &
      p.r.seName
    p.accountBefore = accountFingerprintValue(p.r.seKind, p.r.seName)
    if p.r.seKind == "user":
      p.groupBefore = accountFingerprintValue("group", p.r.seName)
  of srkSystemdUnitState:
    let u = driver.unitProvision(p.r.usName)
    p.baseUnitState = u.unitFileState
    p.baseActiveState = u.activeState
  of srkPasswdUser, srkPasswdGroup:
    p.accountKey = accountKeyOf(p.r)
    p.accountBefore = accountFingerprintValue(
      (if p.r.kind == srkPasswdUser: "user" else: "group"),
      (if p.r.kind == srkPasswdUser: p.r.puName else: p.r.pgName))
  of srkSystemdSystemUnit:
    p.targetPath = unitPath(p.r.suName)
    p.replaced = baseValue(p.targetPath)
    if p.r.suEnabled:
      for l in installLinkPaths(p.r.suName, p.r.suContent):
        if not dirExists(l.dir) and l.dir notin p.newDirs:
          p.newDirs.add(l.dir)
        if symlinkExists(l.link):
          p.preLinks.add(l.link)
    let u = driver.unitProvision(p.r.suName)
    p.baseUnitState = u.unitFileState
    p.baseActiveState = u.activeState
  of srkLinuxDpkgDiversion:
    p.targetPath = p.r.ddPath
    p.replaced = baseValue(p.r.ddPath)
  else:
    discard

# ---------------------------------------------------------------------------
# Preserved bytes: the content an adoption, reconciliation or replacement
# displaces, kept content-addressed under the state directory so removal
# and uninstall can put it back (spec §4.2, §6.4 step 2).
# ---------------------------------------------------------------------------

proc preservePath*(stateDir, content: string): string =
  preservedDir(stateDir) / sha256Hex(content)

proc preserveBytes*(stateDir, content: string): string =
  ## Store ``content`` and return its path. Idempotent: the same bytes
  ## always land at the same path.
  let path = preservePath(stateDir, content)
  if fileExists(path) and sha256OfFile(path) == sha256Hex(content):
    return path
  createDir(preservedDir(stateDir))
  writeFileNoFollow(path, content, 0o600)
  path

proc parseEtcFileValue(value: string): tuple[mode, owner: string] =
  ## ``f 0644 0:0 sha256:...`` -> mode and owner.
  let parts = value.splitWhitespace()
  if parts.len < 3 or parts[0] != "f":
    raise newException(AddonApplyError, "not a file value: " & value)
  (parts[1], parts[2])

proc restorePreserved*(e: LedgerEntry): bool =
  ## Undo ``e`` the way its history says: put back the bytes the ledger
  ## preserved, with the mode and owner the path had -- or, when the path
  ## was absent before the add-on (``replaced`` empty, so the preserved
  ## bytes are what a later ``--reconcile-drift`` displaced, not a prior
  ## state), delete it: the undo of a creation is a deletion, and the
  ## displaced bytes stay under the state directory for the operator.
  ## False when the entry preserved nothing (a plain deletion is then the
  ## right undo, and the caller's).
  if e.preserved.len == 0:
    return false
  if e.replaced.len == 0:
    # The object may be the add-on's link into the static tree, or the
    # file a hand edit put in its place: either way it goes -- unlinked
    # relative to its parent's descriptor, never through a link on the
    # way (threat model G29).
    discard removeLeafNoFollow(e.path)
    return true
  if not fileExists(e.preserved):
    raise newException(AddonApplyError, "preserved bytes for " & e.path &
      " are missing at " & e.preserved)
  # The add-on's own link into the static tree (the ledger names its
  # target; the restore loop checked nothing else moved it) is replaced by
  # the restored file in one rename, never removed first: the path is never
  # missing, and a crash leaves the link or the file. The writer refuses a
  # link to anything else.
  let ownLink = e.isLink and symlinkExists(e.path) and
                expandSymlink(e.path) == e.linkTarget
  let (mode, owner) = parseEtcFileValue(e.replaced)
  let (uid, gid) = parseOwner(owner)
  writeFileNoFollow(e.path, readFile(e.preserved), parseOctInt(mode), uid, gid,
                    replacingLinkTo = (if ownLink: e.linkTarget else: ""))
  true

# ---------------------------------------------------------------------------
# Ledger construction after the apply.
# ---------------------------------------------------------------------------

proc fileEntry(class: LedgerClass; path, resource, replaced: string):
    LedgerEntry =
  ## What is at ``path`` now: a link into the static tree is recorded
  ## with ``form = link`` and its target, a regular file as a copy. The
  ## digest is of the content either way (through the link).
  let st = statOwner(path)
  result = LedgerEntry(class: class, path: path, mode: st.mode,
                       owner: st.owner, replaced: replaced,
                       resource: resource, form: "copy")
  if symlinkExists(path):
    result.form = "link"
    result.linkTarget = expandSymlink(path)
    result.mode = "0777"
  if fileExists(path):
    result.sha256 = sha256OfFile(path)

proc dirEntry(path, resource: string): LedgerEntry =
  let st = statOwner(path)
  LedgerEntry(class: lcDir, path: path, mode: st.mode, owner: st.owner,
              resource: resource)

proc entriesFor(p: ResourcePlan; previous: seq[LedgerEntry];
                driver: CollisionDriver): seq[LedgerEntry] =
  ## The ledger entries of one applied resource. Entries the previous
  ## ledger already holds for the same resource and target keep what was
  ## recorded when the add-on first touched the object (the replaced
  ## value, the base unit states, the preserved bytes, the directories it
  ## created), because only that first observation saw the base.
  let r = p.r
  var prevDirs: seq[LedgerEntry]
  var prevMain: LedgerEntry
  var known = false
  for e in previous:
    if e.resource == r.address:
      if e.class == lcDir: prevDirs.add(e)
      if (e.class in {lcEtcFile, lcUnit, lcDropIn, lcDiversion, lcUnitState} and
          (e.path == p.targetPath or e.class == lcUnitState)) or
          (e.class == lcAccount and p.accountKey.len > 0 and
           e.path == p.accountKey):
        known = true
        prevMain = e
  if p.own and prevMain.collision == "supersede":
    # Generation 0 takes back an object a profile had superseded (§9): the
    # address is the path's either way, so the entry, and with it the
    # first-touch record, carries over; the `supersede` mark does not.
    prevMain.collision = ""
  let replaced = if known: prevMain.replaced else: p.replaced
  let observation = if known and p.observation.len == 0: prevMain.observation
                    else: p.observation
  let collisionMode =
    if known and prevMain.collision.len > 0 and p.collision.len == 0:
      prevMain.collision
    else: p.collision
  let preserved = if known and prevMain.preserved.len > 0: prevMain.preserved
                  else: p.preserved
  # The newest reconcile's displaced bytes are named too: ``preserved``
  # keeps the first-touch bytes removal restores, ``displaced`` what the
  # operator's last --reconcile-drift threw out.
  let displaced = if p.collision == "reconcile": p.preserved
                  elif known: prevMain.displaced
                  else: ""
  if known:
    for d in prevDirs:
      if dirExists(d.path): result.add(d)
  else:
    for d in p.newDirs:
      if dirExists(d): result.add(dirEntry(d, r.address))
  case r.kind
  of srkFsSystemFile:
    if fileExists(r.sfPath):
      var f = fileEntry(if collisionMode == "dropIn": lcDropIn else: lcEtcFile,
                        r.sfPath, r.address, replaced)
      f.observation = observation
      f.collision = collisionMode
      f.preserved = preserved
      f.displaced = displaced
      if collisionMode == "dropIn":
        # /etc/systemd/system/<unit>.d/<file>: the unit is the directory's
        # stem.
        f.unit = extractFilename(parentDir(r.sfPath))
        f.unit = f.unit[0 ..< f.unit.len - 2]
      result.add(f)
  of srkSystemdSystemUnit:
    let path = unitPath(r.suName)
    if fileExists(path):
      var u = fileEntry(lcUnit, path, r.address, replaced)
      u.unit = r.suName
      u.enabled = r.suEnabled
      u.started = r.suEnabled
      u.hasInstall = hasInstallSection(r.suContent)
      u.observation = observation
      u.collision = collisionMode
      u.preserved = preserved
      u.displaced = displaced
      let now = driver.unitProvision(r.suName)
      u.unitState = now.unitFileState
      u.activeState = now.activeState
      if known:
        u.baseUnitState = prevMain.baseUnitState
        u.baseActiveState = prevMain.baseActiveState
      else:
        u.baseUnitState = p.baseUnitState
        u.baseActiveState = p.baseActiveState
      result.add(u)
      if r.suEnabled:
        var prevLinks: seq[string]
        for e in previous:
          if e.resource == r.address and e.class == lcInstallLink:
            prevLinks.add(e.path)
        for l in installLinkPaths(r.suName, r.suContent):
          # A link that existed before the add-on first touched the unit
          # (a package's own enablement of a `replace`d unit) is the
          # base's, never the ledger's.
          if symlinkExists(l.link) and
              (l.link in prevLinks or (not known and l.link notin p.preLinks)):
            result.add(LedgerEntry(class: lcInstallLink, path: l.link,
              unit: r.suName, linkTarget: expandSymlink(l.link),
              resource: r.address))
      if r.suName.endsWith(".mount") and r.suEnabled:
        let where = mountWhere(r.suContent)
        if where.len > 0:
          result.add(LedgerEntry(class: lcMount, path: where, unit: r.suName,
                                 resource: r.address))
  of srkLinuxDpkgDiversion:
    result.add(LedgerEntry(class: lcDiversion, path: r.ddPath,
                           replaced: replaced, resource: r.address,
                           observation: observation, collision: collisionMode))
  of srkSystemdSystemDropIn:
    if fileExists(p.targetPath) or symlinkExists(p.targetPath):
      var f = fileEntry(lcDropIn, p.targetPath, r.address, replaced)
      f.unit = r.diUnit
      f.observation = observation
      f.collision = collisionMode
      f.preserved = preserved
      f.displaced = displaced
      result.add(f)
  of srkLinuxTmpfilesRule:
    if fileExists(p.targetPath):
      var f = fileEntry(lcEtcFile, p.targetPath, r.address, replaced)
      f.observation = observation
      f.collision = collisionMode
      f.preserved = preserved
      f.displaced = displaced
      result.add(f)
  of srkLinuxSysctl:
    if fileExists(p.targetPath) or symlinkExists(p.targetPath):
      # The fragment keeps its first-touch bytes like any file (an adopted
      # or reconciled fragment is restored on removal, spec §4.2, C36).
      var f = fileEntry(lcEtcFile, p.targetPath, r.address, replaced)
      f.observation = observation
      f.collision = collisionMode
      f.preserved = preserved
      f.displaced = displaced
      result.add(f)
      # The kernel parameter itself, with the host's value before the
      # add-on first set it (what removal restores). A fragment adopted
      # as it is was not applied: the key still has the value it had.
      var before = p.sysctlBefore
      for e in previous:
        if e.resource == r.address and e.class == lcSysctl:
          before = e.replaced
      let applied = if p.skipInfra: p.sysctlBefore else: r.sysctlValue
      result.add(LedgerEntry(class: lcSysctl, path: r.sysctlKey,
        value: applied, replaced: before, resource: r.address))
  of srkLinuxSysusersEntry:
    if fileExists(p.targetPath):
      var f = fileEntry(lcEtcFile, p.targetPath, r.address, replaced)
      f.observation = observation
      f.collision = collisionMode
      f.preserved = preserved
      f.displaced = displaced
      result.add(f)
      # The account the fragment created is retained for ever (spec
      # §6.4): a resource-less entry, so every later ledger carries it.
      # One that existed before the add-on is the base's and gets none.
      # A `u` line also creates a group of the same name (sysusers.d(5)),
      # so both are recorded when the fragment created them.
      var kinds = @[r.seKind]
      if r.seKind == "user": kinds.add("group")
      for kind in kinds:
        let key = (if kind == "group": "group:" else: "user:") & r.seName
        var retained = false
        for e in previous:
          if e.class == lcAccount and e.path == key: retained = true
        let before = if kind == r.seKind: p.accountBefore
                     else: p.groupBefore
        if not retained and before.len == 0:
          let now = accountFingerprintValue(kind, r.seName)
          if now.len > 0:
            result.add(LedgerEntry(class: lcAccount, path: key,
              value: now, kindHint: kind))
  of srkPasswdUser, srkPasswdGroup:
    # The account as it is after its driver converged it (or as adopted),
    # with what it was before the add-on first touched it (``replaced``,
    # "" when the add-on created it): the fingerprint delta's terms.
    let kind = if r.kind == srkPasswdUser: "user" else: "group"
    let now = accountFingerprintValue(kind,
      (if r.kind == srkPasswdUser: r.puName else: r.pgName))
    if now.len > 0:
      result.add(LedgerEntry(class: lcAccount, path: p.accountKey,
        value: now, kindHint: kind, resource: r.address,
        replaced: (if known: prevMain.replaced else: p.accountBefore),
        observation: observation, collision: collisionMode))
  of srkSystemdUnitState:
    # The add-on owns nothing here; the ledger records the unit's state
    # so the fingerprint delta accounts for the enablement and activity
    # the requirement converged. Removing the resource forgets the
    # requirement and changes nothing (§4.1): the entry then stays,
    # resource-less.
    let now = readUnitProvision(r.usName)
    var u = LedgerEntry(class: lcUnitState, path: r.usName, unit: r.usName,
      resource: r.address, unitState: now.unitFileState,
      activeState: now.activeState, enabled: r.usEnabled,
      started: r.usRunning, hasInstall: true)
    if known:
      u.baseUnitState = prevMain.baseUnitState
      u.baseActiveState = prevMain.baseActiveState
    else:
      u.baseUnitState = p.baseUnitState
      u.baseActiveState = p.baseActiveState
    result.add(u)
  of srkLinuxAddOnTool:
    # Ledgered through its two carriers (``addOnToolCarriers``): the files
    # are theirs; the launcher link is in no digest (§4.1).
    discard
  else:
    # Unreachable after `checkScope`; kept so a future kind cannot be
    # applied without a ledger entry.
    raise newAddOnOutOfScope($r.kind, "", r.address, unmanagedKindReason(r))

# ---------------------------------------------------------------------------
# Composition: the operator's resources, reshaped by their opt-ins.
# ---------------------------------------------------------------------------

proc dropInUnitOf(path: string): string =
  ## ``/etc/systemd/system/<unit>.d/<file>`` -> ``<unit>``.
  let d = extractFilename(parentDir(path))
  if d.endsWith(".d"): d[0 ..< d.len - 2] else: ""

const AddOnToolCarrierSuffixes = ["#wrapper", "#manifest"]

proc addOnToolCarrierOf*(r: SystemResource): string =
  ## The ``linux.addOnTool`` address whose wrapper or launcher manifest
  ## ``r`` stands for in the composition (``reshape``), "" for any other.
  ## Recognised by shape, not by an address prefix: a tool's address is
  ## whatever the profile names it (rpi2's are ``ipmitool`` and
  ## ``wakeonlan``; a text profile's default is ``addOnTool:<command>``),
  ## so a carrier is ``<tool address>#wrapper`` at a wrapper path, or
  ## ``<tool address>#manifest`` at a launcher manifest path, under
  ## ``AddOnToolDir``.
  if r.kind != srkFsSystemFile or parentDir(r.sfPath) != AddOnToolDir:
    return ""
  let isManifest = r.sfPath.endsWith(".launcher.manifest")
  for sfx in AddOnToolCarrierSuffixes:
    if r.address.len > sfx.len and r.address.endsWith(sfx) and
        isManifest == (sfx == "#manifest"):
      return r.address[0 ..< r.address.len - sfx.len]
  ""

proc addOnToolCarriers*(r: SystemResource): seq[SystemResource] =
  ## The two ``etcFile``s a ``linux.addOnTool`` writes (spec §4.1): the
  ## wrapper ``/etc/repro/bin/<command>`` and its launcher manifest, with
  ## the bytes its driver renders. They carry the tool's collision
  ## decisions and ledger entries; the driver itself writes them (with the
  ## wrapper's mode), realises the closure and converges the launcher link,
  ## which is in no digest.
  let manifestPath = addOnToolManifestPath(r.atCommand)
  let prefix = aptClosurePrefixPath(AddOnSystemStoreRoot,
    parseAptClosureLock(r.atAptClosureLock))
  @[SystemResource(kind: srkFsSystemFile, address: r.address & "#wrapper",
      sfPath: addOnToolWrapperPath(r.atCommand),
      sfContent: renderAddOnToolWrapper(manifestPath)),
    SystemResource(kind: srkFsSystemFile, address: r.address & "#manifest",
      sfPath: manifestPath,
      sfContent: renderAddOnToolManifest(prefix, r.atProgram))]

proc reshape(user: SystemProfile; dropIns: var HashSet[string]):
    seq[SystemResource] =
  ## The operator's resources as the apply carries them: a
  ## ``collision = dropIn`` unit becomes the drop-in file it writes
  ## (keeping the resource's address, which ``dropIns`` collects), and a
  ## ``collision = divert`` file gains the ``linux.dpkgDiversion`` it
  ## depends on unless the profile already declares one for the path. A
  ## ``systemd.systemTimer`` is the unit it writes (keeping its address);
  ## a ``linux.addOnTool`` is preceded by the two files it writes
  ## (``addOnToolCarriers``).
  var diverted = initHashSet[string]()
  for r in user.resources:
    if r.kind == srkLinuxDpkgDiversion: diverted.incl(r.ddPath)
  for r in user.resources:
    case r.kind
    of srkSystemdSystemUnit:
      if r.suCollision == "dropIn":
        dropIns.incl(r.address)
        result.add(SystemResource(kind: srkSystemdSystemDropIn,
          address: r.address, diUnit: r.suName,
          diName: (if r.suDropInName.len > 0: r.suDropInName else: "addon"),
          diContent: r.suContent, diRestartHeld: r.suRestartHeld,
          dependsOn: r.dependsOn))
      else:
        result.add(r)
    of srkSystemdSystemTimer:
      # Spec §4.1: the `unit` class's timer is a unit file like any other;
      # the address stays the timer's.
      result.add(SystemResource(kind: srkSystemdSystemUnit,
        address: r.address, suName: r.stName, suContent: r.stContent,
        suEnabled: r.stEnabled, dependsOn: r.dependsOn))
    of srkLinuxAddOnTool:
      result.add(addOnToolCarriers(r))
      result.add(r)
    of srkLinuxSysctl:
      if r.sysctlFilename.len == 0:
        # Spec §4.1: /etc/sysctl.d/90-repro-<name>.conf, <name> from the
        # key (the driver's own default puts it under 99-reprobuild-).
        var f = r
        f.sysctlFilename = AddOnSysctlPrefix &
          r.sysctlKey.replace('.', '-').replace('/', '-') & ".conf"
        result.add(f)
      else:
        result.add(r)
    of srkFsSystemFile:
      if r.sfCollision == "divert" and r.sfPath notin diverted:
        result.add(SystemResource(kind: srkLinuxDpkgDiversion,
          address: "dpkgDiversion:" & r.sfPath, ddPath: r.sfPath))
        diverted.incl(r.sfPath)
        var f = r
        f.dependsOn.add((kind: $srkLinuxDpkgDiversion, name: r.sfPath))
        result.add(f)
      elif r.sfPath in diverted:
        # The profile declares the diversion itself: the file still goes
        # in only after it (the diversion's `--rename` would otherwise move
        # the add-on's own copy aside), whatever order the profile wrote.
        var f = r
        var has = false
        for dep in f.dependsOn:
          if dep.kind == $srkLinuxDpkgDiversion and dep.name == r.sfPath:
            has = true
        if not has:
          f.dependsOn.add((kind: $srkLinuxDpkgDiversion, name: r.sfPath))
        result.add(f)
      else:
        result.add(r)
    else:
      result.add(r)

proc hasDiversionFor(resources: seq[SystemResource]; path: string): bool =
  for r in resources:
    if r.kind == srkLinuxDpkgDiversion and r.ddPath == path: return true
  false

# ---------------------------------------------------------------------------
# The apply.
# ---------------------------------------------------------------------------

proc removalRank(r: SystemResource): int =
  ## Destroy order: units stop first (nothing still uses their files),
  ## then drop-ins and files and fragments, then the diversions those
  ## files filled (a diversion can only be removed once the path it
  ## diverts is free again).
  case r.kind
  of srkSystemdSystemUnit: 0
  of srkSystemdSystemDropIn, srkFsSystemFile, srkLinuxSysctl,
     srkLinuxTmpfilesRule, srkLinuxSysusersEntry: 1
  of srkLinuxDpkgDiversion: 2
  else: 3

proc entryKeyOf*(e: LedgerEntry): string = $e.class & " " & e.path

proc changedSincePlan*(e: LedgerEntry; planned: string): string =
  ## "" when the object ``e`` describes may still be removed or restored
  ## as decided: it is as it was when the decision was made (``planned``
  ## is what ``observeDrift`` said then), or it is gone, or it is the
  ## add-on's own link left dangling by the switch's flip (the removal in
  ## progress). Otherwise the drift as observed now.
  let now = observeDrift(e)
  if now == planned or now.startsWith("missing") or
      (e.isLink and now.startsWith("dangling")):
    return ""
  now

proc removeOwnedUnitFile(e: LedgerEntry): bool =
  ## Remove the file or link the ledger owns at ``e.path`` (a link whose
  ## tree no longer carries it included); false when it is already gone.
  removeLeafNoFollow(e.path)

proc removeEmptyDirs*(entries: seq[LedgerEntry]) =
  ## ``rmdir`` the ledger's directories deepest first, leaving any that
  ## something else has put a file in.
  var dirs: seq[string]
  for e in entries:
    if e.class == lcDir: dirs.add(e.path)
  dirs.sort(proc(a, b: string): int = cmp(b.len, a.len))
  for d in dirs:
    # `rmdir` relative to the parent's descriptor: it removes only an
    # empty directory, so there is no check-then-remove window, and it
    # never follows a link planted on the way (threat model G29).
    try:
      discard removeEmptyDirNoFollow(d)
    except OSError, NoFollowError:
      discard     # a parent that is gone or became a link: left alone

proc daemonReload() =
  try:
    let r = runSystemctl(["daemon-reload"])
    if r.exitCode != 0:
      raise newException(AddonApplyError, "systemctl daemon-reload: " &
        r.output.strip())
  except HostToolMissing as e:
    raise newException(AddonApplyError, e.msg)

proc systemctlOrRaise(args: openArray[string]) =
  try:
    let r = runSystemctl(args)
    if r.exitCode != 0:
      raise newException(AddonApplyError, "systemctl " & args.join(" ") &
        ": " & r.output.strip())
  except HostToolMissing as e:
    raise newException(AddonApplyError, e.msg)

proc quietHandBack*(preservedSha, ledgerSha: string;
                    dropInsChanged, dependenciesChanged: bool): bool =
  ## Whether a unit handed back to the base may be left running: the bytes
  ## put back are the ones it ran (an adopted unit, handed back as found),
  ## and nothing else it loads changed in this switch -- no drop-in the
  ## add-on wrote for it, no `depends_on` target. Otherwise it is restarted
  ## from the base's file (§7.3).
  preservedSha.len > 0 and preservedSha == ledgerSha and
    not dropInsChanged and not dependenciesChanged

proc restoreUnitState*(e: LedgerEntry; driver: CollisionDriver;
                       othersChanged = true) =
  ## After the add-on's unit file left (restored or removed), put the unit
  ## back in the state the base had it: a `replace`d package unit that was
  ## enabled and active stays so, now from the package's file. Runs after
  ## `daemon-reload`, and after the install links the add-on made for the
  ## unit were removed: an adopted hand-written unit the add-on enabled is
  ## disabled by that. Never `systemctl disable`, which would also remove
  ## links the base made (its [Install] may name units the add-on does
  ## not own).
  let now = driver.unitProvision(e.unit)
  let nowEnabled = now.unitFileState in ["enabled", "enabled-runtime"]
  if e.baseUnitState == "enabled" and not nowEnabled and
      now.loadState == "loaded":
    systemctlOrRaise(["enable", "--", e.unit])
  # The bytes put back are the bytes the add-on had there (an adopted
  # unit, handed back as found), and nothing else it loads changed
  # (``othersChanged``: its drop-ins, its `depends_on` targets): the
  # definition systemd runs did not change, so a running instance is left
  # alone. ``othersChanged`` defaults to true: a caller that has not
  # established that restarts.
  let preservedSha = if e.preserved.len > 0 and fileExists(e.preserved):
                       sha256Hex(readFile(e.preserved)) else: ""
  # A relocated closure unit hands back its older binding: the same
  # package bytes as the one it runs (§9 "Migration").
  let quiet = quietHandBack(preservedSha,
                            (if e.collision == "closure-relocate": preservedSha
                             else: e.sha256),
                            dropInsChanged = othersChanged,
                            dependenciesChanged = othersChanged)
  if e.baseActiveState == "active" and now.loadState == "loaded":
    if quiet and now.activeState == "active":
      discard
    else:
      # The running instance is the add-on's definition; restart it from
      # the base's file.
      systemctlOrRaise(["restart", "--", e.unit])
  elif e.baseActiveState != "active" and now.activeState == "active":
    systemctlOrRaise(["stop", "--", e.unit])

proc inlineSafeOrRefuse(what, text: string) =
  ## The canonical profile text cannot carry a double quote inside a
  ## value (its parser strips the surrounding quotes and decodes no
  ## escapes); such a unit cannot be adopted inline.
  if text.contains('"'):
    raise newException(AddonApplyError, what & " contains a double quote, " &
      "which the canonical system-profile text cannot carry; it cannot be " &
      "adopted as a unit resource")

proc prefixIdHex*(id: PrefixIdBytes): string =
  for b in id: result.add(toHex(int(b), 2).toLowerAscii())

proc parsePrefixIdHex*(hex: string): PrefixIdBytes =
  if hex.len != 2 * result.len:
    raise newException(AddonApplyError, "malformed store prefix id in " &
      "the ledger: " & hex)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))

proc keptPathRefusal*(previous: Ledger; path: string): string =
  ## "" unless ``path`` is a pre-bootstrap input the ledger keeps as found
  ## (spec §6.1): then why a resource there is refused at plan time. The
  ## input is the add-on's by no resource and is carried forward by every
  ## apply; a resource at the same path would take the ledger slot and
  ## the kept file would neither be restored by uninstall nor reported.
  ## The path is ``targetPathOf``'s, so every file-shaped kind is covered
  ## -- a ``linux.tmpfilesRule`` named ``repro-addon-bootstrap.conf`` lands
  ## exactly on the kept fragment.
  if path.len == 0: return ""
  for e in previous.entries:
    if e.isPreBootstrapInput and e.class in {lcEtcFile, lcKey, lcKept} and
        e.path == path:
      return path & " is a pre-bootstrap input the add-on keeps as found " &
             "(spec §6.1); a profile cannot declare a resource at that path"
  ""

proc pinToBytes(r: var SystemResource; p: var ResourcePlan;
                bytes, preservedPath: string; planOnly: bool) =
  ## Make ``r`` ask the apply for exactly ``bytes``, the bytes already at
  ## its target, so that applying it writes nothing (an adoption, or a
  ## resource an adopt holds). A file reads them from ``preservedPath``
  ## (the content-addressed copy under the state directory, written
  ## before the apply); a plan, which writes nothing, carries them inline.
  ## Sysctl and sysusers fragments are rendered from fields (a key and a
  ## value, an account line), so the apply cannot be asked for other
  ## bytes: the resource is left out of this generation's infra apply
  ## (``skipInfra``) -- nothing is written, applied or re-run -- and the
  ## ledger owns the fragment as it is. The next ordinary apply converges
  ## it like any owned object (spec §11.2 step 4).
  case r.kind
  of srkFsSystemFile:
    r.sfContent = ""
    r.sfSourceUrl = ""
    r.sfSha256 = ""
    r.sfSourceLocal = if planOnly: r.sfSourceLocal else: preservedPath
    if r.sfSourceLocal.len == 0:
      r.sfContent = bytes
  of srkSystemdSystemUnit:
    inlineSafeOrRefuse("unit " & r.suName, bytes)
    r.suContent = bytes
  of srkSystemdSystemDropIn:
    r.diContent = bytes
  of srkLinuxTmpfilesRule:
    r.tmpfilesContent = bytes
  of srkLinuxSysctl, srkLinuxSysusersEntry:
    p.skipInfra = true
  else:
    discard
  p.content = bytes

proc scopedAdoptProfile*(given: SystemProfile; currentText: string;
                         addresses: openArray[string];
                         stateDir = ""): SystemProfile =
  ## The profile ``repro system adopt <address> --profile <file>`` applies
  ## (spec §11.2 step 3): the current generation's operator profile with
  ## the addressed resources taken from ``given`` -- added, or in place of
  ## the current generation's resource of that address. Every other
  ## resource of ``given`` is ignored, so an adopt never writes a pending
  ## change the operator has not applied. The managed prefixes are the
  ## current ones plus, for an adopted path they do not cover, the
  ## narrowest prefix ``given`` declares that covers it (owner decision
  ## 2026-10-30): an adopt widens the scope by exactly what the adopted
  ## object needs. Raises when ``given`` does not declare an addressed
  ## resource.
  let current = if currentText.len > 0:
                  parseStoredUserProfile(currentText, stateDir)
                else: SystemProfile()
  result.addOn = current.addOn
  # An adopt changes no secret: the current generation's declarations stay.
  result.secretFiles = current.secretFiles
  # Whether the stored profile carries an addOn stanza is the current
  # generation's; only a needed prefix (below) comes from the given one.
  result.addOn.declared = current.addOn.declared
  var wanted = initHashSet[string]()
  for a in addresses: wanted.incl(a)
  for r in current.resources:
    if r.address notin wanted: result.resources.add(r)
  for a in addresses:
    var found = false
    for r in given.resources:
      if r.address != a: continue
      result.resources.add(r)
      found = true
      let path = case r.kind
        of srkFsSystemFile: r.sfPath
        of srkLinuxDpkgDiversion: r.ddPath
        else: ""
      if path.len == 0 or
          isManagedPath(path, managedPrefixes(result)):
        continue
      var narrowest = ""
      for pfx in given.addOn.managedEtcPrefixes:
        if isUnderManagedPrefix(path, pfx) and pfx.len > narrowest.len:
          narrowest = pfx
      if narrowest.len > 0:
        result.addOn.managedEtcPrefixes.add(narrowest)
        result.addOn.declared = true
    if not found:
      raise newException(AddonApplyError, "cannot adopt " & a &
        ": the profile declares no resource with that address")

when TestPauseSeam:
  import std/posix as seamPosix

  proc testSeamPause() =
    ## The write-time re-check gate's seam (test-only builds): when the
    ## gate has created the FIFO ``/run/repro-addon-test-seam/continue``,
    ## announce the pause with ``paused`` and block until the gate writes
    ## to the FIFO -- after the plan and its observations, before the
    ## first write. Without the FIFO the apply does not pause.
    const dir = "/run/repro-addon-test-seam"
    var st: seamPosix.Stat
    if seamPosix.stat(cstring(dir & "/continue"), st) != 0 or
        not seamPosix.S_ISFIFO(st.st_mode):
      return
    writeFile(dir & "/paused", $getCurrentProcessId() & "\n")
    discard readFile(dir & "/continue")
    # Once per run: the FIFO goes with the release, so an apply this one
    # starts (a rollback's re-apply) does not pause again.
    removeFile(dir & "/continue")
    removeFile(dir & "/paused")

proc planIdOf*(inputs: openArray[string]): string =
  ## The add-on plan id: the first 32 hex digits of the SHA-256 of the
  ## plan's observation records, one per line.
  sha256Hex(inputs.join("\n") & "\n")[0 ..< 32]

const
  AddonOwnProfileName* = "addon-own.profile"
  AddonUserProfileName* = "addon-user.profile"
    ## Under ``generations/<id>/``: what that generation applied.

proc generationProfiles*(stateDir, generationId: string):
    tuple[found: bool; own, user: string] =
  ## The own and user profile texts a generation applied, when it was
  ## applied by a release that records them.
  let gd = generationDir(stateDir, generationId)
  if fileExists(gd / AddonOwnProfileName) and
      fileExists(gd / AddonUserProfileName):
    (true, readFile(gd / AddonOwnProfileName),
     readFile(gd / AddonUserProfileName))
  else:
    (false, "", "")

proc revertProfiles(stateDir, committed, fallbackOwn,
                    fallbackUser: string): tuple[own, user: string] =
  ## What a failed switch goes back to: the committed generation's own
  ## copies, or -- for a generation applied before they were kept -- the
  ## stored profile the switch began from.
  let g = generationProfiles(stateDir, committed)
  if g.found: (g.own, g.user) else: (fallbackOwn, fallbackUser)

proc undoPreStop(m: PendingMarker): seq[string] =
  ## Put back what step 2 did before a refusal stopped the switch ahead of
  ## the flip: re-enable what it disabled, start what it stopped.
  for u in m.disabled:
    try:
      let r = runSystemctl(["enable", "--", u])
      if r.exitCode != 0: result.add("enable " & u & ": " & r.output.strip())
    except CatchableError as e:
      result.add("enable " & u & ": " & e.msg)
  for u in m.stopped:
    # A unit whose stop the refusal is about (an exclusive instance that
    # would not die) is still running: it is not "stopped", and starting
    # it would put a second instance beside the live one (§7.3). Only a
    # unit whose control group is confirmed empty is started again.
    try:
      if unitIsActive(u) or unitAliveness(u) != uaEmpty: continue
      startUnit(u)
    except CatchableError as e: result.add(e.msg)

proc recordRolledBack*(stateDir, attempt, backTo, asGeneration, why: string;
                       healthFailed: bool) =
  ## The attempt's apply log records the outcome (§7.5: "records the
  ## apply as rolled-back"), so `repro system audit` and the evidence
  ## trail show it under the id the attempt would have had.
  ## An attempt that failed before it was allocated an id has no log of
  ## its own: the record goes to the log of the generation the revert
  ## committed instead, so it is never lost.
  let logGen = if attempt.len > 0: attempt else: asGeneration
  if logGen.len == 0: return
  appendAuditRecord(applyLogPath(stateDir, logGen), AuditRecord(
    timestamp: getTime().toUnix(), operationKind: "addon.switch",
    resourceAddress: "generation:" &
      (if attempt.len > 0: attempt else: "(an attempt with no id)"),
    outcome: "rolled-back",
    diagnostic: (if healthFailed: "confirm failed: " else: "") & why &
      " -> back to " & backTo & " as " & asGeneration,
    recordClass: AuditClassLiveState))

proc decideInstall(driver: CollisionDriver; r: SystemResource;
                   ownedLinks: HashSet[string];
                   enabledUnits: HashSet[string];
                   targets: var seq[PlannedTarget]) =
  ## The ``[Install]`` section of an enabled unit, through the decision
  ## table (spec §4.3 unit rows). ``systemctl enable`` does more than link
  ## the unit under its targets:
  ##
  ## - ``Alias=`` creates ``/etc/systemd/system/<alias>`` -- a unit of that
  ##   name. It is decided as a unit target: a package unit of that name is
  ##   ``EAddOnUnitShadows`` unless the resource opted into ``replace``; a
  ##   masked, transient, generated or local one, a foreign diversion, or
  ##   anything already at the path that the ledger does not hold as this
  ##   resource's link refuses; the guard re-checks it before the write.
  ## - ``Also=`` enables other units too, links the add-on would neither
  ##   own nor ledger: refused unless it names a unit this profile itself
  ##   declares enabled.
  ## - ``DefaultInstance=`` enables a template as an instance whose links
  ##   the add-on does not derive: refused.
  ##
  ## ``WantedBy``/``RequiredBy``/``UpheldBy`` links are the unit's own
  ## (``installLinkPaths``) and are ledgered after the apply.
  if not r.suEnabled: return
  let dot = r.suName.rfind('.')
  let suffix = if dot >= 0: r.suName[dot .. ^1] else: ""
  for t in installTargets(r.suContent):
    case t.kind
    of "DefaultInstance":
      raise newException(AddonCollisionError, "refusing " & r.address &
        ": [Install] DefaultInstance=" & t.target & " enables a template " &
        "instance whose links the add-on does not derive; declare the " &
        "instance's unit instead")
    of "Also":
      if t.target notin enabledUnits:
        raise newException(AddonCollisionError, "refusing " & r.address &
          ": [Install] Also=" & t.target & " would enable " & t.target &
          ", which this profile does not declare as an enabled unit; " &
          "`systemctl enable` would change the enablement of a unit the " &
          "add-on does not own")
    of "Alias":
      let err = systemdUnitNameError("[Install] Alias of " & r.suName, t.target)
      if err.len > 0:
        raise newException(AddonCollisionError, "refusing " & r.address &
          ": " & err)
      if not t.target.endsWith(suffix):
        raise newException(AddonCollisionError, "refusing " & r.address &
          ": [Install] Alias=" & t.target & " is not a " & suffix &
          " name (systemd requires an alias of the unit's own type)")
      let path = unitPath(t.target)
      if path in ownedLinks:
        continue          # the alias link this resource already holds
      if r.suCollision == "replace" and leafNoFollow(path).kind == lkLink:
        # The base's own alias of the package unit this resource replaces
        # (Debian's `sshd.service -> /lib/systemd/system/ssh.service`): the
        # package's enablement, left to the base and never ledgered, like
        # its other install links; `systemctl enable` treats a link to a
        # same-named unit as already in place.
        let existing = readLinkNoFollow(path)
        var basePackageAlias = false
        for d in PackageUnitDirs:
          if existing == d & r.suName: basePackageAlias = true
        if basePackageAlias:
          continue
      if leafNoFollow(path).kind != lkAbsent:
        raise newException(AddonDriftError, "EDrift: " & path & " (" &
          r.address & ", [Install] Alias=" & t.target & ") already exists " &
          "and the ledger does not hold it as this unit's alias; an alias " &
          "would replace it")
      let inp = DecisionInputs(address: r.address, kind: tkUnit,
        unit: t.target,
        collision: (if r.suCollision == "replace": "replace" else: ""))
      let (dec, obs) = decide(driver, inp, path)
      targets.add(plannedTarget(r.address, inp, path, dec, obs))
    else:
      discard

proc newlyShadowedVendorUnits*(previous: Ledger;
                                driver: CollisionDriver): seq[string] =
  ## Every unit name the add-on owns in /etc/systemd/system (a unit file,
  ## or an alias link) that a package or vendor unit directory now
  ## provides too: the add-on's /etc copy shadows it silently since the
  ## package arrived. Reported by every plan and apply as actionable drift
  ## (spec §4.3, `EAddOnUnitShadows`); a `replace`d unit was shadowed by
  ## opt-in and is not reported.
  var seen = initHashSet[string]()
  for e in previous.entries:
    if e.resource.len == 0: continue
    let isAlias = e.class == lcInstallLink and
                  parentDir(e.path) == SystemdUnitDir
    if not ((e.class == lcUnit and e.collision != "replace") or isAlias):
      continue
    let name = extractFilename(e.path)
    if name in seen: continue
    seen.incl(name)
    for d in @PackageUnitDirs & @["/usr/local/lib/systemd/system/"]:
      let vendor = d & name
      if fileExists(vendor) or symlinkExists(vendor):
        let pkg = driver.packageOwner(vendor).package
        result.add("EAddOnUnitShadows: " & name & " is now also provided by " &
          (if pkg.len > 0: "package " & pkg else: "a vendor unit") & " at " &
          vendor & "; the add-on's " & e.path & " (" & e.resource &
          ") shadows it. Declare `collision = \"replace\"` on the resource " &
          "to keep shadowing it, or remove the resource")
        break

proc recordingRefusals(inner: PreWriteGuard;
                       refused: var HashSet[string]): PreWriteGuard =
  ## ``inner``, also noting in ``refused`` every address it refuses (not
  ## one it keeps as drift), for the ledger built after the writes.
  let sink = addr refused
  result = proc(op: PrivilegedOperation): string {.gcsafe.} =
    let why = inner(op)
    if why.len > 0 and not why.startsWith(PreWriteKeepPrefix):
      {.cast(gcsafe).}:
        sink[].incl(op.address)
    why

proc seamedGuard(stateDir, seamPrefix: string;
                 inner: PreWriteGuard): PreWriteGuard =
  ## The pre-write guard, with the two write-time test seams in front of
  ## it (a no-op outside a ``-d:reproAddonTestSeams`` build).
  when AddonTestSeams:
    var calls = 0
    result = proc(op: PrivilegedOperation): string {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
        if calls == 1: seamPause(stateDir, seamPrefix & "pre-write")
        elif calls == 2: seamPause(stateDir, seamPrefix & "mid-write")
        inner(op)
  else:
    inner

const
  SysusersCandidates = ["/usr/bin/systemd-sysusers", "/bin/systemd-sysusers"]
  TmpfilesCandidates = ["/usr/bin/systemd-tmpfiles", "/bin/systemd-tmpfiles"]

proc rerunFragmentTool(candidates: openArray[string]; fragment: string;
                       extra = "") =
  ## Run the host's ``systemd-sysusers`` / ``systemd-tmpfiles`` on one
  ## fragment (a replay's step 6; see there).
  let exe = resolveHostTool(candidates)
  if exe.len == 0:
    raise newException(AddonApplyError, "no " & candidates[0] & " on this host")
  var argv = @[exe]
  if extra.len > 0: argv.add(extra)
  argv.add(fragment)
  let r = runHostTool(argv)
  if r.exitCode != 0:
    raise newException(AddonApplyError, argv.join(" ") & ": " & r.output.strip())

proc seamCommitPoint(stateDir, seamPrefix: string): proc(point: string) {.gcsafe.} =
  ## The infra commit's crash points, as seams (nil outside a seam build).
  when AddonTestSeams:
    result = proc(point: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        seamPause(stateDir, seamPrefix & point)
  else:
    nil

# ---------------------------------------------------------------------------
# Secrets (milestone A7, spec §10.3): which envelope a switch materialises
# from, and what its commit keeps.
# ---------------------------------------------------------------------------

proc secretsSourcePath*(stateDir: string): string =
  ## The envelope the switch in progress materialises from, written before
  ## its pending marker: a replay uses the same one, and a crash after the
  ## commit is finished from it.
  stateDir / "addon" / "secrets-source"

proc envelopeDigest(path: string): string =
  if fileExists(path): sha256OfFile(path) else: ""

proc writeSecretsSource(stateDir, source: string) =
  ## The path and the digest of the envelope this switch uses: a later
  ## retry of its commit copies it only while it is still that envelope
  ## (the next tick re-stages over the staged path).
  createDir(stateDir / "addon")
  writeFileAtomic(secretsSourcePath(stateDir),
    source & "\n" & envelopeDigest(source) & "\n", 0o600)

proc readSecretsSourceRecord*(stateDir: string): tuple[path, digest: string] =
  if fileExists(secretsSourcePath(stateDir)):
    let lines = readFile(secretsSourcePath(stateDir)).splitLines()
    if lines.len > 0: result.path = lines[0].strip()
    if lines.len > 1: result.digest = lines[1].strip()

proc readSecretsSource*(stateDir: string): string =
  readSecretsSourceRecord(stateDir).path

proc generationEnvelopeOf*(stateDir, generationId: string): string =
  generationEnvelopePath(generationDir(stateDir, generationId))

proc selectSecretsSource(stateDir: string; l: SecretsLayout;
                         opts: AddonApplyOptions; purpose,
                         committedPrevious: string): string =
  when mutated("secrets-single-retained-envelope"):
    return latestEnvelopePath(l)
  if opts.secretsEnvelope.len > 0:
    return opts.secretsEnvelope
  case purpose
  of "replay":
    let recorded = readSecretsSource(stateDir)
    if recorded.len > 0 and fileExists(recorded): return recorded
  of "revert":
    if committedPrevious.len > 0 and
        fileExists(generationEnvelopeOf(stateDir, committedPrevious)):
      return generationEnvelopeOf(stateDir, committedPrevious)
  of "rollback":
    if opts.secretsFromGeneration.len > 0 and
        fileExists(generationEnvelopeOf(stateDir, opts.secretsFromGeneration)):
      return generationEnvelopeOf(stateDir, opts.secretsFromGeneration)
  else:
    discard
  latestEnvelopePath(l)

proc commitSecretsOf*(stateDir: string; l: SecretsLayout; generationId: string) =
  ## What a committed switch keeps of its secrets (``commitEnvelope``), from
  ## the source it recorded; idempotent, and a no-op once the record is
  ## gone. A failure here is reported, never undoes the commit: the
  ## generation stands, and the re-assert unit retries it.
  let rec = readSecretsSourceRecord(stateDir)
  var source = rec.path
  if source.len > 0 and rec.digest.len > 0 and
      envelopeDigest(source) notin [rec.digest, ""]:
    # The envelope at the recorded path is no longer the one the switch
    # used (a later tick staged another): it is not copied as this
    # generation's. A generation without a copy is handled as §10.3 says.
    stderr.writeLine("repro-addon: " & source & " changed since generation " &
      generationId & " used it; not kept as its envelope")
    source = ""
  if generationId.len > 0:
    try:
      var reseal = envelopeCopies(stateDir)
      commitEnvelope(l, source, generationEnvelopeOf(stateDir, generationId),
        reseal, ledgerCopyPath(stateDir), seamStateDir = stateDir)
    except CatchableError as e:
      # The record stays: the next tick or re-assert retries the copy.
      stderr.writeLine("repro-addon: keeping the generation's secrets: " &
        e.msg & " (retried by the next tick or re-assert)")
      return
  if fileExists(secretsSourcePath(stateDir)):
    removeFile(secretsSourcePath(stateDir))

proc unitFileChanged*(isNew: bool; verdict: string;
                      prevSha256, renderedSha256: string;
                      closureMissing, loadedStale: bool): bool =
  ## Whether a unit's definition changes in this apply, for the §7.3 table
  ## (a running unit whose definition changed is restarted).
  ##
  ## A unit the previous ledger does not know is a change, except one the
  ## switch adopts (§4.3: present, unowned, identical -- or claimed): the
  ## switch writes nothing, so the definition systemd runs is the one on
  ## disk, unless systemd has not loaded those bytes yet (``loadedStale``,
  ## its ``NeedDaemonReload``). This is what lets a migration (§9) take over
  ## the units an agent applied outside the switch without restarting them.
  if closureMissing: return true
  if isNew:
    return verdict != $cvAdopt or loadedStale
  prevSha256 != renderedSha256 or
    verdict in [$cvCreate, $cvUpdate, $cvReconcile, $cvReplace]

proc accountRecheck(base: PreWriteGuard; checks: seq[tuple[r: SystemResource;
                    ledgerValue: string; owns: bool;
                    verdict: CollisionVerdict]];
                    reconcileDrift: bool): PreWriteGuard =
  ## The write-time re-check of a ``passwd.*`` operation: the account is
  ## decided again (``decideAccount``) and its write refused when the
  ## decision changed since the plan -- the plan decided on an account the
  ## host no longer has. Every other operation goes to ``base``.
  result = proc(op: PrivilegedOperation): string {.gcsafe.} =
    {.cast(gcsafe).}:
      if op.kind in {pokPasswdUser, pokPasswdGroup} and
          not (op.kind == pokPasswdUser and op.puDestroy) and
          not (op.kind == pokPasswdGroup and op.pgDestroy):
        for c in checks:
          if c.r.address != op.address: continue
          var now: CollisionVerdict
          try:
            now = decideAccount(c.r, c.ledgerValue, c.owns, reconcileDrift,
                                c.verdict == cvAdopt).verdict
          except CatchableError as e:
            return "refusing " & op.address & " at write time: " & e.msg
          if now != c.verdict:
            return "refusing " & op.address & " at write time: the " &
              "account changed since the plan (" & $c.verdict & " -> " &
              $now & ")"
          return ""
      base(op)

proc acceptedOutOfBandDiff*(accepted: seq[tuple[path, address: string]]):
    seq[string] =
  ## The ledger-diff lines for targets accepted as changed out of band
  ## (spec §4.3): ``accepted-out-of-band<TAB>path<TAB>address``, one per
  ## path, whichever passes of the apply decided it (the add-on's own
  ## objects, the operator's resources, a `repro system adopt` scope).
  var seen = initHashSet[string]()
  for a in accepted:
    if a.path in seen: continue
    seen.incl(a.path)
    result.add("accepted-out-of-band\t" & a.path & "\t" & a.address)

proc ledgerRecordsAttempt(stateDir, fromGeneration: string): bool =
  ## The ledger copy was rewritten since ``fromGeneration`` was committed:
  ## only the interrupted switch (or a replay of it) writes it while
  ## `current` still names ``fromGeneration``, and it does so after its
  ## writes, so a revert planned from it can tell them apart.
  let lp = ledgerCopyPath(stateDir)
  if not fileExists(lp): return false
  try: readLedger(lp).generation != fromGeneration
  except CatchableError: false

proc legacyClosureBytes*(r: SystemResource;
                         tool = SystemResource()): seq[string] =
  ## The bytes ``r`` had when an older closure realiser bound its closure:
  ## a unit's (``legacyClosureRenderings``), or a ``linux.addOnTool``'s
  ## launcher manifest (``tool``, the carrier's tool), which names the
  ## closure prefix the launcher binds over ``/usr``. The wrapper names no
  ## prefix, so it has no older rendering. Empty for anything else.
  if r.kind == srkSystemdSystemUnit: return legacyClosureRenderings(r)
  if tool.kind != srkLinuxAddOnTool or
      addOnToolCarrierOf(r) != tool.address or
      r.sfPath != addOnToolManifestPath(tool.atCommand):
    return
  let lock = parseAptClosureLock(tool.atAptClosureLock)
  let current = aptClosurePrefixPath(AddOnSystemStoreRoot, lock)
  for legacy in legacyAptClosurePrefixPaths(AddOnSystemStoreRoot, lock):
    if legacy != current:
      result.add(renderAddOnToolManifest(legacy, tool.atProgram))

const
  ClosureUnpackFactor = 4'i64
    ## A ``.deb``'s unpacked size over its archive size, for a member no
    ## older realiser unpacked on this host (xz-compressed data members
    ## unpack to about 3x; rounded up).
  StoreSpaceReserveBytes = 1'i64 shl 30
    ## Free space the realisation must leave on the store's filesystem at
    ## the least: on an add-on host it is usually the root filesystem, which
    ## the host's own services (a time-series database, the journal) keep
    ## writing to.

type
  ClosureSpace* = object
    ## What realising a profile's apt closures will take from the store's
    ## filesystem and the network (ReproOS Add-On Mode §9 "Migration",
    ## §8.3).
    closures*: int          ## closures not realised at their store prefix
    members*: int           ## members to publish (each once)
    reusedMembers*: int     ## of those, published from an older realiser's
                            ## prefix of the same archive bytes (shared
                            ## files: nothing unpacked, nothing fetched)
    downloadBytes*: int64   ## ``.deb`` archives to fetch
    unpackBytes*: int64     ## the unpacked trees of the members not reused
    measuredMembers*: int   ## members whose size an older realiser's
                            ## prefix gave (allocated blocks)
    largestDebBytes*: int64 ## the largest archive to fetch: it sits beside
                            ## its unpacked tree until it is published
    freeBytes*: int64       ## available to this process on that filesystem
    reserveBytes*: int64    ## left free at the least
    unavailable*: seq[string] ## archives to fetch that the archive did not
                            ## serve (``closureSpace``'s ``probe``)
    sources*: seq[string]   ## one line per member to publish:
                            ## ``reuse|cached|download <name> <version>
                            ## <older prefix or URL>``

  DebServed* = enum
    dsServed      ## the archive serves it (2xx)
    dsUnserved    ## the archive says it does not (404, 410)
    dsUnknown     ## anything else: a refusing mirror, no TLS, no network,
                  ## the deadline -- inconclusive, which refuses
  DebProbe* = proc (url: string): tuple[verdict: DebServed; detail: string]
    {.closure.}
    ## Whether the archive serves ``url``, and how it answered.

proc treeBytes(dir: string): int64 =
  ## The bytes the regular files under ``dir`` occupy (allocated blocks,
  ## each inode once; links not followed).
  var seen = initHashSet[(int64, int64)]()
  for f in walkDirRec(dir, yieldFilter = {pcFile}, followFilter = {pcDir}):
    var st: Stat
    if lstat(f.cstring, st) != 0: continue
    let key = (int64(st.st_dev), int64(st.st_ino))
    if key in seen: continue
    seen.incl(key)
    result += int64(st.st_blocks) * 512

proc availableBytes(path: string): int64 =
  ## Free bytes an unprivileged writer may use on the filesystem holding
  ## ``path`` (its nearest existing ancestor); -1 when it cannot be read.
  var p = path
  while p.len > 1 and not dirExists(p): p = parentDir(p)
  var st: Statvfs
  if statvfs(p.cstring, st) != 0: return -1
  int64(st.f_bavail) * int64(st.f_frsize)

proc neededBytes*(c: ClosureSpace): int64 =
  c.unpackBytes + c.largestDebBytes

proc closureSpace*(locks: seq[AptClosureLock];
                   storeRoot = AddOnSystemStoreRoot;
                   cacheDir = AddOnAptDebCacheDir;
                   probe: DebProbe = nil): ClosureSpace =
  ## What realising ``locks`` will need: every closure not yet realised at
  ## its store-published prefix, and every member of one not yet published
  ## there, counted once, each listed in ``sources`` as ``cached``,
  ## ``download`` or ``reuse-because-unserved``. The archive is always the
  ## source when it is cached or served; an older realiser's verified
  ## prefix (``reusableLegacyMember``) stands in only when the archive
  ## answers that it does not serve the member (404/410), and then costs
  ## neither bytes nor a fetch. A member not served with no such prefix,
  ## or one whose probe is inconclusive, is ``unavailable`` (a refusal).
  ## An unpacked tree is measured from an older realiser's prefix where
  ## one exists, else estimated at ``ClosureUnpackFactor`` times the
  ## archive. A union is hard links of its members' files and costs no
  ## file bytes of its own. Without ``probe`` (the switch, which has no
  ## network) every member not cached counts as a download: the most it
  ## could take.
  var seen = initHashSet[string]()
  for lock in locks:
    if aptClosureRealised(storeRoot, lock): continue
    inc result.closures
    for d in lock.debs:
      if d.sha256 in seen: continue
      seen.incl(d.sha256)
      if fileExists(aptDebPrefixPath(storeRoot, d) / ".repro-apt-deb"):
        continue
      inc result.members
      let cached = fileExists(cacheDir / (d.sha256 & ".deb"))
      if cached:
        result.sources.add("cached\t" & d.name & " " & d.version & "\t" &
          cacheDir / (d.sha256 & ".deb"))
      else:
        let url = debUrl(lock, d)
        var verdict = dsServed
        var detail = ""
        if probe != nil: (verdict, detail) = probe(url)
        case verdict
        of dsServed:
          result.sources.add("download\t" & d.name & " " & d.version & "\t" &
            url)
          result.downloadBytes += d.size
          result.largestDebBytes = max(result.largestDebBytes, d.size)
        of dsUnserved:
          # The one case an older realiser's prefix stands in for the
          # archive (threat model C20, approved by Zahary Karadjov,
          # 2026-11-01): it costs no bytes and no fetch.
          let reusable = reusableLegacyMember(storeRoot, d)
          if reusable.len > 0:
            inc result.reusedMembers
            result.sources.add("reuse-because-unserved\t" & d.name & " " &
              d.version & "\t" & reusable & " (" & url & ": " & detail & ")")
            continue
          result.unavailable.add(d.name & " " & d.version & ": " & url &
            " is not served (" & detail & ") and no older realiser's " &
            "prefix of it verifies")
          continue
        of dsUnknown:
          result.unavailable.add(d.name & " " & d.version & ": " & url &
            " could not be probed (" & detail & "); whether the archive " &
            "serves it is unknown, and only an archive that does not may " &
            "be stood in for")
          continue
      let legacy = legacyAptDebPrefixPath(storeRoot, d)
      if dirExists(legacy):
        result.unpackBytes += treeBytes(legacy)
        inc result.measuredMembers
      else:
        result.unpackBytes += d.size * ClosureUnpackFactor
  result.freeBytes = availableBytes(storeRoot)
  result.reserveBytes = max(StoreSpaceReserveBytes, neededBytes(result) div 4)

proc probeVerdict*(code: int): DebServed =
  ## An archive's answer, as ``httpDebProbe`` reads it.
  if code >= 200 and code < 300: dsServed
  elif code in [404, 410]: dsUnserved
  else: dsUnknown

proc httpDebProbe*(timeoutMs = 10_000; deadlineMs = 300_000): DebProbe =
  ## The migration plan's probe: an HTTP ``HEAD`` of the archive URL,
  ## following redirects; a mirror that refuses ``HEAD`` (403, 405, 501) is
  ## asked for the first byte instead (``GET`` with ``Range: bytes=0-0``).
  ## Nothing more is downloaded. 404 and 410 are ``dsUnserved``; any other
  ## answer, an error (no TLS in this build, no network) or a probe begun
  ## after ``deadlineMs`` since the first is ``dsUnknown``: a plan of a
  ## host with hundreds of members ends in bounded time.
  var started: MonoTime
  var begun = false
  result = proc (url: string): tuple[verdict: DebServed; detail: string] =
    # A monotonic clock: a wall clock stepped by NTP mid-plan (a Pi boots
    # without one) would stretch or cut the deadline.
    let now = getMonoTime()
    if not begun:
      started = now
      begun = true
    if (now - started).inMilliseconds > deadlineMs:
      return (dsUnknown, "the plan's probe deadline of " &
        $(deadlineMs div 1000) & " s had passed")
    try:
      let pool = newHttpPool(maxConnections = 1, receiveTimeoutMs = timeoutMs)
      defer: pool.close()
      proc ask(meth: string; headers: seq[(string, string)]):
          tuple[code: int; final: string] =
        ## Status and headers only, never a body (a mirror that ignores
        ## ``Range`` would send the whole archive). Redirects are followed
        ## by hand, at most five, so that only the configured archive's own
        ## 404/410 reads as "not served", as the realiser's fetch reads it
        ## (``downloadBounded``).
        var current = url
        for _ in 0 .. 5:
          let r = pool.requestStatusOnly(meth, current, headers)
          if r.statusCode in [301, 302, 303, 307, 308] and r.location.len > 0:
            let next = $combine(parseUri(current), parseUri(r.location))
            if parseUri(current).scheme == "https" and
                parseUri(next).scheme != "https":
              return (-1, "a redirect to " & next & " drops TLS")
            current = next
            continue
          return (r.statusCode, current)
        (-1, "more than five redirects")
      var (code, final) = ask("HEAD", @[])
      var how = "HEAD"
      if code in [403, 405, 501]:
        (code, final) = ask("GET", @[("Range", "bytes=0-0")])
        how = "GET bytes=0-0"
      if code < 0: return (dsUnknown, final)
      var verdict = probeVerdict(code)
      if verdict == dsUnserved and originOf(final) != originOf(url):
        verdict = dsUnknown
      (verdict, how & " " & $code & (if final != url: " at " & final else: ""))
    except CatchableError as e:
      (dsUnknown, e.msg)

proc spaceIsShort*(c: ClosureSpace): bool =
  ## Whether the realisation would leave less than the reserve free. An
  ## unreadable filesystem (``freeBytes`` -1) is short: the switch cannot
  ## show it is not.
  c.closures > 0 and c.freeBytes < neededBytes(c) + c.reserveBytes

proc mib(b: int64): string = $((b + (1'i64 shl 20) - 1) shr 20) & " MiB"

proc describe*(c: ClosureSpace): string =
  $c.closures & " closure(s) to realise, " & $c.members & " member(s) to " &
    "publish (" & $c.reusedMembers & " from an older realiser's prefix of " &
    "the same archive): about " & mib(neededBytes(c)) & " of store space (" &
    mib(c.unpackBytes) & " unpacked, " & $c.measuredMembers & " measured; " &
    "the largest archive " & mib(c.largestDebBytes) & "), " &
    mib(c.downloadBytes) & " to download; " &
    (if c.freeBytes < 0: "free space unreadable"
     else: mib(c.freeBytes) & " free") &
    ", " & mib(c.reserveBytes) & " to be left free"

proc relocatesClosure*(r: SystemResource; path: string;
                       tool = SystemResource()): bool =
  ## Whether the file at ``path`` is ``r`` as an older closure realiser
  ## bound it (``legacyClosureBytes``): the same unit or launcher
  ## manifest, the same package bytes, an older prefix path. ``tool`` is
  ## the ``linux.addOnTool`` a manifest carrier writes for.
  if not fileExists(path) or symlinkExists(path): return
  let current = readFile(path)
  try: current in legacyClosureBytes(r, tool)
  except CatchableError: false

proc revertMayKeep*(purpose: string; ledgerOwns, regularFile: bool;
                    currentSha, plannedSha: string): bool =
  ## Whether a revert keeps a drifted ledger-owned file as found (§7.5, "A
  ## revert over drift the failed switch did not cause"): only a regular
  ## file whose bytes are exactly what the failed switch's plan observed
  ## before the flip -- bytes it found there and left alone.
  purpose == "revert" and ledgerOwns and regularFile and
    plannedSha.len > 0 and currentSha == plannedSha

proc revertOverwritesRestored*(purpose: string; ledgerOwns, regularFile: bool;
                               currentSha, preservedPath: string): bool =
  ## Whether a revert writes over a ledger-owned file that holds exactly
  ## the bytes the ledger preserved for it: what the failed switch's
  ## restore (spec §7.2, before step 7) put there before it failed. Its
  ## preserved file is named by the bytes' SHA-256.
  when mutated("revert-refuses-restored"):
    return false
  purpose == "revert" and ledgerOwns and regularFile and
    preservedPath.len > 0 and currentSha == extractFilename(preservedPath)

proc liveReachProfile(resources: openArray[SystemResource]): SystemProfile =
  for r in resources: result.resources.add(r)

proc liveCheckAtStep6*(anyUnitChange, replaying, recordOnly: bool;
                       liveUnits: openArray[string]):
    tuple[reload: bool; judged: seq[string]] =
  ## Step 6's decision (spec §11.1, §13 decision 59): whether the switch
  ## holds, reloads and judges, and the services it judges. Every switch
  ## that writes a unit file, replays, or has services to judge (carried
  ## state on the host) reloads; a switch that is not record-only judges
  ## every service of ``liveUnits`` -- also a switch that writes no unit
  ## file but restarts one whose ``depends_on`` file or credentials changed
  ## (A13 review round 7, finding 1). The reload the switch relies on is
  ## this one: a unit driver's own reload in step 3 (the dependency restart
  ## the planner dispatches rewrites the unit file and reloads) is incidental
  ## to how that driver writes, and a credentials-only restart has none.
  let every =
    when mutated("narrowed-live-set"): false
    else: liveUnits.len > 0
  result.reload = anyUnitChange or replaying or every
  if result.reload and not recordOnly: result.judged = @liveUnits

proc liveReachUnitsFor(opts: AddonApplyOptions;
                       resources: openArray[SystemResource]): seq[string] =
  ## The services the carried-state cross-check judges for this switch
  ## (``carried_state.liveReachUnits``): held with the floored units from
  ## step 6's reload until the check passes.
  let carriedAt = if opts.carriedStateDir.len > 0: opts.carriedStateDir
                  else: CarriedStateDir
  let root = if opts.carriedStateRoot.len > 0: opts.carriedStateRoot else: "/"
  liveReachUnits(liveReachProfile(resources), carriedAt, root)

proc carriedRefusalFor(opts: AddonApplyOptions; stateDir: string): string

proc liveReachProblemsFor(opts: AddonApplyOptions; units: seq[string];
                          resources: openArray[SystemResource];
                          stateDir: string): seq[string] =
  ## After step 6's reload, before any start: each of ``units`` re-judged
  ## from ``systemctl show`` (``carried_state.liveReachProblems``, shared
  ## with ``runInfraApply``), and the carried-state refusal decided again
  ## over the host as the reload left it -- a drop-in a host generator made
  ## at the switch's own reloads is read now, so a path or a command it
  ## adds is judged too, not only the account (A13 round 6).
  when mutated("addon-live-reach-skipped"):
    return
  let root = if opts.carriedStateRoot.len > 0: opts.carriedStateRoot else: "/"
  result = liveReachProblems(units, liveReachProfile(resources),
    proc (u: string): Table[string, string] = showUnit(u), root)
  when not mutated("post-reload-refusal-skipped"):
    let why = carriedRefusalFor(opts, stateDir)
    if why.len > 0: result.add(why & " (decided again after the reload)")

proc carriedRefusalFor(opts: AddonApplyOptions; stateDir: string): string =
  ## The carried-state refusal for this apply (``carried_state``), "" when
  ## it may go ahead. A stored generation (a revert, a rollback, a replay)
  ## is read under the rules it was installed with, as the switch reads it
  ## (§10.1): a pre-floor generation parsed with today's floor default
  ## would throw here, and a revert to it could never start.
  let carriedFrom =
    if opts.storedTarget or opts.replay:
      parseStoredUserProfile(opts.userProfileText, stateDir)
    else: parseAddOnUserProfile(opts.userProfileText)
  carriedStateRefusal(carriedFrom,
    (if opts.carriedStateDir.len > 0: opts.carriedStateDir
     else: CarriedStateDir),
    (if opts.carriedStateRoot.len > 0: opts.carriedStateRoot else: "/"))

proc hostLockWithCarriedRecheck*(opts: AddonApplyOptions;
                                 stateDir: string): HostApplyLock =
  ## Take the host apply lock for this apply and decide carried state again
  ## under it: a state backup takes the same lock, so a hold it wrote while
  ## this apply waited for the lock is seen here, before anything is
  ## written, not after the switch has started units. Raises
  ## ``AddonApplyError`` (with the lock released) on a refusal.
  result = acquireHostApplyLock("add-on " &
    (if opts.purpose.len > 0: opts.purpose else: "apply") & " (state " &
    stateDir & ")")
  when not mutated("carried-check-not-under-lock"):
    let why = carriedRefusalFor(opts, stateDir)
    if why.len > 0:
      result.release()
      raise newException(AddonApplyError, why)

# ---------------------------------------------------------------------------
# Store custody inside the switch (spec §13 decisions 47 and 48).
# ---------------------------------------------------------------------------

proc fileSourceObject*(r: SystemResource): StoreObjectRef =
  ## The store object an ``fs.systemFile`` copies its bytes from; ``path``
  ## "" when its source is not in the store.
  if r.kind == srkFsSystemFile and r.sfSourceLocal.startsWith(StoreRoot & "/"):
    let o = storeObjectFor(r.sfSourceLocal)
    if o.len > 0:
      return StoreObjectRef(path: o, kind: classifyStoreObject(o),
                            referrer: r.address)

proc storeObjectsNamedIn*(text: string): seq[string] =
  ## Every store object any ``/repro/store`` path in ``text`` names, read as
  ## systemd reads paths (``normalisedPath``) and placed by
  ## ``storeObjectFor``: a prefix, or the top-level store entry a path
  ## outside every prefix lies in (``/repro/store/tmp``, a loose directory),
  ## which custody then refuses as having no realiser (default deny, A11
  ## review finding 12). The store itself and its prefixes directory name no
  ## object.
  when mutated("custody-prefixes-only"):
    return       # FALSIFYING BUILD: only prefixes are seen, as before
  var tok = ""
  proc take(tok: var string; acc: var seq[string]) =
    let i = tok.find("/repro")
    if i >= 0:
      let p = serviceFloor.normalisedPath(tok[i .. ^1])
      if p.startsWith(StoreRoot & "/"):
        let obj = storeObjectFor(p)
        if obj.len > 0 and obj != StoreRoot / "prefixes" and obj notin acc:
          acc.add(obj)
    tok = ""
  for c in text & " ":
    if c in {' ', '\t', '\n', '\r', '\'', '"', ';', ':', '=', ',', '(', ')'}:
      take(tok, result)
    else:
      tok.add(c)

proc isSha256Name(s: string): bool =
  s.len == 64 and s.allCharsInSet(HexDigits)

proc filesRecovery*(prefix: string; resources: openArray[SystemResource];
                    stateDir: string; storeRoot = StoreRoot): Recovery =
  ## Generation 0's files prefix (and ``evidence-enrol``'s) holds one file
  ## per body, named by the SHA-256 of its bytes; the names are in the
  ## generation's own profile text (state directory, outside the store).
  ## The trusted bytes are any copy outside the store whose SHA-256 is its
  ## name: the installed ``/etc`` copy, or the preserved bytes. Every name
  ## must have one, and together they must name exactly this prefix (its
  ## path is a function of the names and its version); otherwise there is
  ## no trusted source and the switch refuses.
  var names: seq[string]
  var targets = initTable[string, seq[string]]()
  for r in resources:
    if r.kind == srkFsSystemFile and parentDir(r.sfSourceLocal) == prefix:
      let n = extractFilename(r.sfSourceLocal)
      if not isSha256Name(n):
        return Recovery(why: r.sfSourceLocal & " is not named by its digest")
      if n notin names: names.add(n)
      targets.mgetOrPut(n, @[]).add(r.sfPath)
  if names.len == 0:
    return Recovery(why: "no resource of this generation copies from it")
  let version = prefixVersionOf(prefix)
  if version.len == 0 or filesPrefixPath(names, version, storeRoot) != prefix:
    return Recovery(why: "the generation's own files do not name this " &
      "prefix's whole content")
  var files: seq[tuple[name, content: string]]
  for n in names:
    var found = false
    var candidates = targets.getOrDefault(n, @[])
    candidates.add(preservedDir(stateDir) / n)
    when mutated("recovery-trusts-store-bytes"):
      # FALSIFYING BUILD: the altered prefix's own copy is a source too.
      candidates.insert(prefix / n, 0)
    for c in candidates:
      if fileExists(c) and not symlinkExists(c):
        let bytes = try: readFile(c) except IOError, OSError: ""
        when mutated("recovery-trusts-store-bytes"):
          let good = true
        else:
          let good = sha256Hex(bytes) == n
        if good:
          files.add((n, bytes))
          found = true
          break
    if not found:
      return Recovery(why: "no copy of " & n & " outside the store holds " &
        "the bytes its name is the digest of")
  Recovery(ok: true, source: "generation 0's bodies (installed copies " &
    "whose SHA-256 is their name)",
    realise: proc (): string =
      realiseFilesPrefix(files, version).digest)

proc closureRecovery*(o: StoreObjectRef; locks: openArray[AptClosureLock];
                      site: CustodySite; fetch: AptDebFetcher;
                      storeRoot = AddOnSystemStoreRoot;
                      cacheDir = AddOnAptDebCacheDir): Recovery =
  ## An apt closure's union or member is realised again from the lock's
  ## ``.deb`` archives (SHA-256 pinned by the lock in the signed manifest),
  ## which the apply reads from what the fetch unit staged. A member is
  ## rebuilt whenever it is gone, whatever the union's state (an altered
  ## member's union may be intact: it holds hard links, and a file added to
  ## or removed from the member's directory is not in it; A11 review finding
  ## 1). The union, when its own bytes are altered too, is moved aside and
  ## rebuilt with the member. A member whose archive the apply has no copy
  ## of is not realised: the switch refuses, and the next fetch, finding the
  ## member gone, stages its archive.
  for lock in locks:
    var paths = @[aptClosurePrefixPath(storeRoot, lock)]
    for d in lock.debs: paths.add(aptDebPrefixPath(storeRoot, d))
    if o.path notin paths: continue
    let l = lock
    let union = paths[0]
    return Recovery(ok: true, source: "the lock's .deb archives (pinned " &
      "by SHA-256 in the signed manifest)",
      realise: proc (): string =
        var unionAside, unionExp, unionNow = ""
        if dirExists(union) and union != o.path:
          unionExp = expectedDigests(site).getOrDefault(union, "")
          unionNow = storeTreeDigest(union)
          if unionExp.len > 0 and unionNow != unionExp:
            unionAside = moveAside(site, union)
        let log = AptRealisationLog(verifyReuse: proc (p: string): string =
          let exp = expectedDigests(site).getOrDefault(p, "")
          if exp.len == 0:
            return (if custodyHost(site): "it has no recorded digest" else: "")
          let c = verifiedDigest(site, p, exp)
          if c.verdict == cvVerified: "" else: "its bytes are altered")
        discard realiseAptClosure(l, storeRoot, cacheDir, fetch,
          log = log, rebuildMissingMembers = true)
        result = ""
        for (p, d) in log.published:
          recordRealised(site, p, d)
          if p == o.path: result = d
        if unionAside.len > 0 and dirExists(union) and
            storeTreeDigest(union) == unionExp:
          # The union is back: only now is its alteration filed and recorded.
          let entry = fileEvidence(site, unionAside, union, unionExp, unionNow,
            "built from the altered member " & o.path)
          recordRecovered(site, StoreObjectRef(path: union,
            kind: sokAptClosure, referrer: o.referrer), unionExp, unionNow,
            entry, "rebuilt with the recovered member")
          markRecorded(entry))
  Recovery(why: "no closure of this generation consists of it")

proc storeRecovery*(o: StoreObjectRef; resources: openArray[SystemResource];
                    locks: openArray[AptClosureLock]; site: CustodySite;
                    stateDir: string; fetch: AptDebFetcher): Recovery =
  ## Where an altered object's trusted bytes come from, by kind (§13
  ## decision 47). No trusted source: no recovery.
  case o.kind
  of sokFiles: filesRecovery(o.path, resources, stateDir)
  of sokAptClosure: closureRecovery(o, locks, site, fetch)
  of sokStaticTree:
    Recovery(why: "the static tree is realised again by the switch that " &
      "plans it, from the plan's bytes")
  of sokBinary:
    Recovery(why: "it is the add-on's own binary, which is running this " &
      "switch; only a new bootstrap of a verified binary replaces it")
  of sokPrefix:
    Recovery(why: "a prefix the agent installs from the signed manifest's " &
      "pinned build outputs is re-installed by the agent's next tick, not " &
      "by a switch")
  of sokOther:
    Recovery(why: "nothing realises it")

proc runAddonApply*(opts: AddonApplyOptions): AddonApplyResult
  ## Defined below, after the switch it wraps with its evidence record.

proc applyGenerationUnrecorded(opts: AddonApplyOptions): AddonApplyResult =
  ## Apply one add-on generation (or, with ``planOnly``, decide and report
  ## it). Raises a typed refusal with nothing written when the scope or
  ## collision pass refuses, and ``AddonApplyError`` when the infra apply
  ## reports an error -- after recording, in the ledger, every object that
  ## apply did create, so uninstall still finds them.
  # While carried state is installed, every unit of the generation that
  # reaches it requires the first-boot restore, through a drop-in the
  # generation itself writes (spec §11.1; A13 review round 4, finding 4):
  # added to the user profile, so the scope and collision passes, the
  # ledger and the effective-unit check see it like any other drop-in. A
  # stored generation (a revert, a rollback, a replay) is applied as it was
  # installed, with the requirements it was given then.
  var opts = opts
  let carriedAt = if opts.carriedStateDir.len > 0: opts.carriedStateDir
                  else: CarriedStateDir
  if not opts.storedTarget and not opts.replay and
      carriedStateInstalled(carriedAt):
    # Parsed as an add-on user profile (the floor's defaults included),
    # as the reach analysis of the refusal below reads it.
    opts.userProfileText &= carriedRequirementText(
      parseAddOnUserProfile(opts.userProfileText), carriedAt,
      (if opts.carriedStateRoot.len > 0: opts.carriedStateRoot else: "/"))
  let stateDir = if opts.stateDir.len > 0: opts.stateDir else: DefaultStateDir
  # An operator contained the host (decision 51): no deploy agent applies,
  # whichever agent it is -- the add-on's own units or the full engine's
  # ``repro deploy-agent`` (A11 review finding 6). Enforced here, in the
  # switch every agent apply goes through, not only in the units.
  if opts.agentSequence > 0'u64 and isContained(stateDir) and
      not mutated("contained-agent-applies"):
    raise newException(AddonApplyError, "EAddOnContained: the host is " &
      "contained by an operator (" & containedMarkerPath(stateDir) & "); " &
      "a deploy-agent apply is refused until `repro system addon release`; " &
      "nothing was written")
  if opts.agentRecord.present and opts.agentSequence > 0'u64 and
      opts.agentRecord.sequence != opts.agentSequence:
    # The generation would carry two different sequences, and the floor
    # (§7.5) and the agent record (§7.4) would disagree about its age.
    raise newException(AddonApplyError, "the agent record's sequence " &
      $opts.agentRecord.sequence & " is not the apply's sequence " &
      $opts.agentSequence)
  if not opts.planOnly:
    # Carried state a conversion brought is restored before any apply
    # reaches it, and nothing is applied under a state backup's hold
    # (spec §11.1), whichever path asked for the apply (an operator, the
    # deploy agent, an adopt, a rollback). Decided by the library both
    # apply paths share (`carried_state`); first, before anything else is
    # looked at or written, and again under the host lock below.
    let why = carriedRefusalFor(opts, stateDir)
    if why.len > 0:
      raise newException(AddonApplyError, why)
    # The before-each-write re-check runs on the in-process apply path,
    # which is the one an add-on apply takes: as root, in this process. A
    # process that would hand the privileged set to a broker would apply
    # without it, so it is refused rather than let through unchecked.
    if not isProcessElevated() or getEnv(ForceBrokerEnvVar).len > 0:
      raise newException(AddonApplyError, "an add-on apply runs as root " &
        "in one process (the before-each-write collision check runs " &
        "there); re-run as root" &
        (if getEnv(ForceBrokerEnvVar).len > 0: " without " & ForceBrokerEnvVar
         else: ""))
  # One apply at a time per HOST, whatever its state directory
  # (``repro_core/host_apply_lock``), taken before the first write and
  # before the state directory's own lock, and held across the whole
  # switch, not only the infra apply inside it.
  var hostLock: HostApplyLock
  if not opts.planOnly:
    hostLock = hostLockWithCarriedRecheck(opts, stateDir)
  defer: hostLock.release()
  if not opts.planOnly:
    enterWritableStoreView()
    createDir(addonDir(stateDir))
  # One apply at a time per state directory (the same lock `repro infra
  # apply` takes). A caller that already holds it -- the full engine's CLI
  # -- is not asked to take it twice. A plan takes none: it writes nothing.
  var ownLock = false
  if not opts.planOnly and applyLockOwner(stateDir) != getCurrentProcessId():
    let acq = tryAcquireApplyLock(stateDir)
    if not acq.acquired:
      raise newException(AddonApplyError, "another apply holds the lock: " &
        describeApplyLockHolder(stateDir, acq))
    ownLock = true
  defer:
    if ownLock: releaseApplyLock(stateDir)

  let purpose = if opts.purpose.len > 0: opts.purpose
                elif opts.replay: "replay"
                else: "apply"
  # An interrupted or failed switch must be finished or undone before
  # another one starts: its marker and write-ahead plan are the only
  # record of what it changed. Its own replay and revert are the
  # exceptions, and so is a plan, which writes nothing.
  if not opts.planOnly and purpose notin ["replay", "revert"] and
      hasPendingMarker(stateDir):
    # An apply recovers an interrupted switch first when that switch's
    # owner is gone -- a previous boot's, or a killed process's -- under
    # the host and state-directory locks it already holds (both are
    # re-entrant within the process), so an apply that wins the race with
    # the boot recovery does not leave the host half-switched until the
    # next boot (§7.7). The guard checks this apply's own state directory
    # (an add-on bootstrapped with --state-dir is applied with it); when
    # recovery does not resolve it, the apply refuses with nothing written.
    var why = "run `repro system addon recover` to finish or revert it first"
    if pendingSwitchGuard != nil:
      let g = pendingSwitchGuard(stateDir)
      if not g.ok: why = "recovery did not resolve it: " & g.why
    if hasPendingMarker(stateDir):
      raise newException(AddonApplyError, "an interrupted switch is " &
        "pending (" & pendingMarkerPath(stateDir) & "); " & why)
  var replayPlan: PendingPlan
  if opts.replay:
    replayPlan = readPendingPlan(stateDir)
  let replaying = opts.replay
  # A revert's seam points are named apart, so a gate can stop the revert
  # of a failed switch rather than the switch itself; so are a replay's,
  # so a recovery never stops at a point meant for the switch it recovers
  # (the pause request that switch consumed need not have reached the disk
  # before the reset: the seams never sync).
  let seamPrefix = if replaying: "replay:"
                   elif purpose == "revert": "revert:"
                   else: ""
  # Generation 0's objects this build renders differently are re-rendered
  # by every switch (A11 review findings 2 and 8: a host bootstrapped
  # before a fix gets it with its next switch; ``own_profile``). A replay
  # applies exactly what the interrupted switch planned.
  let ownText =
    if replaying: replayPlan.targetOwnText
    elif opts.ownProfileText.len > 0: migrateOwnProfile(opts.ownProfileText)
    elif fileExists(ownProfilePath(stateDir)):
      migrateOwnProfile(readFile(ownProfilePath(stateDir)))
    else: raise newException(AddonApplyError,
      "not an add-on host: " & ownProfilePath(stateDir) & " is missing")
  let previous =
    if replaying: parseLedger(replayPlan.fromLedgerText)
    elif fileExists(ledgerCopyPath(stateDir)): readLedger(ledgerCopyPath(stateDir))
    else: Ledger()
  result.previousLedger = previous
  # The generation `current` names, not the ledger copy's: a switch that
  # failed after its writes leaves the copy describing the host under the
  # id it would have committed, which is no generation at all. Retention
  # and the pending marker speak of committed generations only.
  let committedPrevious = readCurrentGenerationId(stateDir)
  result.previousGenerationId = committedPrevious
  # §13 decision 72: a host whose committed generation an engine without
  # the record of floored units' directories wrote is migrated once, from
  # what systemd runs now, before this apply changes anything. A plan
  # writes nothing; a replay or a revert finishes a switch an engine with
  # the record started.
  if not opts.planOnly and purpose notin ["replay", "revert"]:
    # Each entry is logged before it is recorded; one whose audit record
    # cannot be written is not recorded, so it stays refused (A9 review
    # round 11, finding 6).
    discard migrateCreatedDirs(stateDir, committedPrevious, previous,
      proc (u: string): string = unitInvocation(u).id,
      proc (path: string; c: CreatedDir): bool =
        try:
          appendAuditRecord(applyLogPath(stateDir, committedPrevious), AuditRecord(
            timestamp: getTime().toUnix(), operationKind: "addon.floor",
            resourceAddress: "directory:" & path, outcome: "migrated",
            diagnostic: c.unit & ": recorded once from the committed generation " &
              committedPrevious & " (st_dev " & $c.dev & ", st_ino " & $c.ino &
              ", birth " & $c.btime & " ns, invocation " & c.invocation &
              "; §13 decision 72)",
            recordClass: AuditClassLiveState))
          true
        except CatchableError: false,
      showOf = proc (u: string): ShowProps =
        try: parseShow(showUnitText(u)) except CatchableError: initTable[string, string]())
  let previousUserText =
    if replaying: replayPlan.fromUserText
    elif fileExists(userProfilePath(stateDir)): readFile(userProfilePath(stateDir))
    else: ""
  let targetUserText = if replaying: replayPlan.targetUserText
                       else: opts.userProfileText
  let reconcileDrift = if replaying: replayPlan.reconcileDrift
                       else: opts.reconcileDrift
  let adoptAddresses = if replaying: replayPlan.adopt else: opts.adoptAddresses
  var decisions = initTable[string, CollisionDecision]()

  var own = parseSystemProfile(ownText)
  # A stored generation (a revert, a rollback, the current generation
  # re-applied, or the replay of a switch that was one) keeps the rules it
  # was installed with; a new profile is held to the floor (§10.1).
  # A replay parses the target as the interrupted switch did: the
  # write-ahead plan records it; an older build's plan does not, and the
  # switch's purpose decides.
  let storedTarget =
    if replaying and replayPlan.storedTargetRecorded: replayPlan.storedTarget
    else: opts.storedTarget or (replaying and hasPendingMarker(stateDir) and
      readPendingMarker(stateDir).purpose in ["revert", "rollback"])
  let parseTarget = proc(t: string): SystemProfile =
    if storedTarget: parseStoredUserProfile(t, stateDir)
    else: parseAddOnUserProfile(t)
  var user =
    if adoptAddresses.len > 0:
      scopedAdoptProfile(parseTarget(targetUserText),
                         previousUserText, adoptAddresses, stateDir)
    else: parseTarget(targetUserText)
  when mutated("addon-unit-renders-differently"):
    # FALSIFYING MUTATION (e2e_addon_reproos_service_parity): the add-on
    # writes every unit with one line the full realisation does not.
    for r in user.resources.mitems:
      if r.kind == srkSystemdSystemUnit:
        r.suContent.add("# rendered by the add-on\n")
  var legacyDirs = registeredLegacySecretsDirs(stateDir)
  var legacyRejected: seq[string]
  for d in opts.legacySecretsDirs:
    # This apply's own directory is held to the registry's rules; one that
    # fails them is named in the refusal of the lines it would have served.
    let why = legacySecretsDirTrustError(d)
    if why.len > 0:
      legacyRejected.add(d & " (" & why & ")")
      result.drift.add("legacy secrets directory not accepted: " & d &
        " (" & why & ")")
    elif d notin legacyDirs: legacyDirs.add(d)
  checkScope(user, legacyDirs, legacyRejected)
  # The envelope this switch's secrets come from (spec §10.3, A7).
  let secretsLayout = defaultSecretsLayout()
  let secretsSource = selectSecretsSource(stateDir, secretsLayout, opts,
                                          purpose, committedPrevious)
  # Generation 0's objects in the profile (spec §9, "Generation-0 objects a
  # profile supersedes"). A profile that declares one of
  # ``SupersedableOwnPaths`` takes it over: generation 0's resource leaves
  # this composition, so the generation has one writer of the path, and the
  # ledger records the profile's resource with collision ``supersede``.
  # Every other generation-0 object stays the add-on's and is refused.
  var ownByIdentity = initTable[string, SystemResource]()
  var ownAddresses = initHashSet[string]()
  for r in own.resources:
    ownAddresses.incl(r.address)
    ownByIdentity[realWorldIdentity(r)] = r
  var superseded = initTable[string, string]()   # own address -> user address
  var supersedingUser = initHashSet[string]()    # user addresses that do
  for r in user.resources:
    let id = realWorldIdentity(r)
    if id in ownByIdentity:
      let o = ownByIdentity[id]
      if not (o.kind == srkFsSystemFile and r.kind == srkFsSystemFile and
              targetPathOf(o) in SupersedableOwnPaths):
        raise newException(AddonApplyError, "the profile declares " &
          r.address & " (" & id & "), which is one of the add-on's own " &
          "objects (generation 0); only " & SupersedableOwnPaths.join(", ") &
          " may be taken over by a profile; drop it from the profile")
      superseded[o.address] = r.address
      supersedingUser.incl(r.address)
    elif r.address in ownAddresses:
      raise newException(AddonApplyError, "the profile declares " &
        r.address & ", which is one of the add-on's own objects")
  if superseded.len > 0:
    var kept: seq[SystemResource]
    for r in own.resources:
      if r.address notin superseded: kept.add(r)
      else:
        result.ledgerDiff.add("supersede\t" & targetPathOf(r) & "\t" &
          superseded[r.address] & " (over generation 0's " & r.address & ")")
    own.resources = kept
  for a in adoptAddresses:
    var declared = false
    for r in user.resources:
      if r.address == a: declared = true
    if not declared:
      raise newException(AddonApplyError, "cannot adopt " & a &
        ": the profile declares no resource with that address")

  # One observer for the whole apply: the dpkg driver re-reads its package
  # index whenever the database changed (``indexStamp``), so the guard's
  # re-observation before each write still sees a package installed since
  # the plan, without re-reading every file list for every operation.
  let driver = if opts.driver != nil: opts.driver else: detectCollisionDriver()
  # --- The base (A10; spec §7.4, §7.9): observed at plan time, recorded
  # with the generation, and gated by the supported matrix. The gate runs
  # after the base itself and the previous ledger were read (they are what
  # it checks) and before the collision pass observes any target and before
  # anything is written. A replay or a revert finishes or undoes a switch
  # already under way and is never refused for the base; uninstall does not
  # come through here (spec §6.4, §13 decision 25).
  block:
    var planned = own.resources
    planned.add(user.resources)
    result.baseIdentity =
      if opts.baseIdentity.isSome: opts.baseIdentity.get()
      else: observeBaseIdentity(previous, planned, driver)
    if committedPrevious.len > 0:
      result.previousBase = readGenerationBase(
        generationDir(stateDir, committedPrevious))
    result.baseChanges = baseIdentityChanges(result.previousBase,
                                             result.baseIdentity)
    if purpose notin ["revert", "replay"] and not opts.recordOnly:
      checkSupportedBase(result.baseIdentity)
  let baseIdentityText = renderBaseIdentity(result.baseIdentity)
  # A package that arrived since the add-on took a unit name (spec §4.3):
  # reported on every plan and apply as actionable drift.
  for why in newlyShadowedVendorUnits(previous, driver):
    result.drift.add(why)
  # A package installed or upgraded since that owns a ledger path (spec
  # §7.6, §7.8): the apt hook reported it; every plan and apply reports it
  # as actionable drift, naming the package.
  # A resource that leaves the profile in this apply is not drift: its
  # removal hands the path back to the package (``handback.nim``).
  block:
    var stillDeclared = Ledger(generation: previous.generation)
    var declared = initHashSet[string]()
    for r in own.resources: declared.incl(r.address)
    for r in user.resources: declared.incl(r.address)
    for e in previous.entries:
      if e.resource in declared: stillDeclared.entries.add(e)
    for why in newOwnerFindings(stillDeclared, driver):
      result.drift.add(why)
  let newDriver: DriverFactory = proc(): CollisionDriver = driver
  var dropIns = initHashSet[string]()
  var userResources = reshape(user, dropIns)
  for r in userResources:
    # A pre-bootstrap input is kept as found, by no resource; a resource
    # at its path would silently displace the carried-forward entry.
    let why = keptPathRefusal(previous, targetPathOf(r))
    if why.len > 0:
      raise newException(AddonCollisionError, "refusing " & r.address & ": " & why)
    if r.kind == srkLinuxSysctl:
      # A base fragment applied after the add-on's would put its own
      # value back at every boot (spec §4.3, §7.2 step 6).
      let clash = sysctlPrecedenceRefusal(r.sysctlKey, r.sysctlValue,
                                          targetPathOf(r))
      if clash.len > 0:
        raise newException(AddonCollisionError, "refusing " & r.address &
          ": " & clash)
      # networkd writes the forwarding knobs itself at runtime when its
      # configuration asks it to (spec §7.2 step 6).
      let nd = readUnitProvision("systemd-networkd.service")
      let networkdInUse = nd.activeState == "active" or
        nd.unitFileState in ["enabled", "enabled-runtime", "linked",
                             "linked-runtime", "alias"]
      let nwd = networkdRefusal(r.sysctlKey, r.sysctlValue, networkdInUse,
                                networkdVersion = hostSystemdVersion())
      if nwd.len > 0:
        raise newException(AddonCollisionError, "refusing " & r.address &
          ": " & nwd)

  var prevForm = initTable[string, string]()  # target path -> link / copy
  for e in previous.entries:
    if e.class in FileClasses and e.resource.len > 0:
      prevForm[e.path] = (if e.isLink: "link" else: "copy")
  var prevSha = initTable[string, string]()   # target path -> ledger digest
  var prevObs = initTable[string, string]()   # target path -> its observation
  var prevOwned = initHashSet[string]()
  var prevPreserved = initTable[string, string]()  # path -> preserved bytes
  for e in previous.entries:
    if e.class in {lcEtcFile, lcUnit, lcDropIn} and e.resource.len > 0:
      prevSha[e.path] = e.sha256
      if e.preserved.len > 0: prevPreserved[e.path] = e.preserved
      prevObs[e.path] = e.observation
      prevOwned.incl(e.path)
    elif e.class == lcDiversion:
      prevOwned.incl("diversion:" & e.path)

  # --- Store custody of the bytes the plan reads (§13 decisions 47, 48). ---
  # An ``fs.systemFile`` copies its bytes from the store, and the plan below
  # reads them (its content, the static tree's link-form files): every such
  # source object is checked against its recorded digest FIRST, and one
  # altered is recovered from its trusted bytes before anything reads it
  # (audit session 2, G1: generation 0's altered files were installed into
  # /etc and owned). A plan only reports what the switch would recover.
  var custody = custodySite(stateDir)
  custody.noWrites = opts.planOnly
  let custodyFetch = if opts.aptFetch != nil: opts.aptFetch
                     else: httpDebFetcher()
  var allResources = own.resources
  allResources.add(user.resources)
  # A files prefix is recovered from ALL of generation 0's bodies, those a
  # profile superseded too: the prefix's path is a function of every name.
  var recoveryResources = parseSystemProfile(ownText).resources
  recoveryResources.add(user.resources)
  var sourceObjects: seq[StoreObjectRef]
  when not mutated("custody-skips-file-sources"):
    for r in allResources:
      let o = fileSourceObject(r)
      if o.path.len > 0: sourceObjects.add(o)
  block:
    if sourceObjects.len > 0 and not opts.planOnly: enterWritableStoreView()
    let c = custodyPass(custody, sourceObjects,
      proc (o: StoreObjectRef): Recovery =
        storeRecovery(o, recoveryResources, [], custody, stateDir,
                      custodyFetch),
      mayRecover = not opts.planOnly)
    if c.refusals.len > 0:
      raise newAddOnError(adStoreChanged, "the generation copies files " &
        "from store objects that do not hold their realisation bytes: " &
        c.refusals.join("; ") & "; nothing was switched")

  # --- The collision pass (plan time). ---
  # Preserved bytes are only named here: nothing is written under the
  # state directory until every resource has been decided, so a refusal
  # of a later resource leaves no bytes of an earlier one behind
  # (``deferPreserve``; written just before the switch's first step).
  var pendingPreserve: seq[string]
  proc deferPreserve(bytes: string): string =
    if opts.planOnly: return ""
    pendingPreserve.add(bytes)
    preservePath(stateDir, bytes)
  var revertHeldDrift: seq[string]
  # What the failed switch observed at each target before it changed
  # anything (its write-ahead plan, still the pending one while its revert
  # plans): a revert keeps a file as found only when it still has exactly
  # those bytes, i.e. the failed switch did not touch it.
  var failedPlanObserved = initTable[string, string]()
  if purpose == "revert" and hasPendingPlan(stateDir):
    try:
      for sp in readPendingPlan(stateDir).plans:
        if sp.targetPath.len > 0 and sp.observedSha256.len > 0:
          failedPlanObserved[sp.targetPath] = sp.observedSha256
    except CatchableError:
      discard          # unreadable: nothing is kept as found (refused below)
  proc revertHeld(r: var SystemResource; p: var ResourcePlan;
                  inp: DecisionInputs; e: ref AddonDriftError):
      (CollisionDecision, TargetObservation) =
    ## A revert (§7.5) undoes what the failed switch changed. A ledger-owned
    ## target whose bytes changed out of band, which the failed switch did
    ## not write -- an earlier writer's bytes it accepted (§4.3), rpi2's
    ## caches.conf -- is not the revert's to refuse: it is kept as found,
    ## asked for its own bytes so nothing is written, its ledger digest kept
    ## (the drift stays visible), and reported. Any other purpose refuses.
    let regular = fileExists(p.targetPath) and not symlinkExists(p.targetPath)
    let current = if regular: readFile(p.targetPath) else: ""
    # Bytes the failed switch itself put back: it restored this object's
    # preserved bytes before it failed (spec §7.2, the restore before step
    # 7), and its ledger kept the entry because the switch did not commit.
    # The revert writes its own generation's bytes over them, as the
    # owner of the object; the preserved bytes stay recorded.
    if revertOverwritesRestored(purpose, inp.ledgerOwns, regular,
        sha256Hex(current), prevPreserved.getOrDefault(p.targetPath)):
      let o = observeTarget(driver, p.targetPath, inp.unit)
      return (CollisionDecision(verdict: cvUpdate,
        observation: observationText(o, inp.kind), observedSha256: o.sha256,
        reason: "the failed switch restored its preserved bytes; the " &
          "revert writes its generation's bytes again"), o)
    # Only bytes the failed switch found there and left alone: the same
    # digest its plan observed before the flip. Anything else -- a file it
    # wrote, or one that changed since -- is refused as before.
    if not revertMayKeep(purpose, inp.ledgerOwns, regular, sha256Hex(current),
                         failedPlanObserved.getOrDefault(p.targetPath)):
      raise e
    pinToBytes(r, p, current, deferPreserve(current), opts.planOnly)
    p.keepLedgerSha = inp.ledgerSha256
    let o = observeTarget(driver, p.targetPath, inp.unit)
    revertHeldDrift.add(p.targetPath & ": changed out of band before the " &
      "reverted switch (sha256 " & o.sha256[0 ..< min(12, o.sha256.len)] &
      ", ledger " & inp.ledgerSha256[0 ..< min(12, inp.ledgerSha256.len)] &
      "); the revert kept it as found")
    (CollisionDecision(verdict: cvNoOp, observation: observationText(o,
       inp.kind), observedSha256: o.sha256,
       reason: "changed out of band before the reverted switch; kept as " &
         "found (drift)"), o)
  var plans: seq[ResourcePlan]
  var targets: seq[PlannedTarget]
  var verdictByAddress = initTable[string, CollisionVerdict]()
  var acceptedOutOfBand: seq[tuple[path, address: string]]
  var accountChecks: seq[tuple[r: SystemResource; ledgerValue: string;
                               owns: bool; verdict: CollisionVerdict]]
    # The accounts' decisions, re-made before their driver writes (they
    # have no file target for the write-time re-check).
    # Ledger paths changed out of band to the desired bytes, from the own
    # pass and the operator's (adopt-scoped or not); reported once each.
  # The add-on's own objects go through the same table as the operator's:
  # a link planted on one of their paths, or a package that came to own
  # one, is met the same way, and the pre-write guard knows them.
  for oi in 0 ..< own.resources.len:
    var r = own.resources[oi]
    var p = ResourcePlan(r: r, own: true, form: "copy")
    preObserve(p, driver)
    let saved = if replaying: replayPlan.savedPlanFor(r.address)
                else: (found: false, plan: SavedPlan())
    if saved.found: overlaySaved(p, saved.plan)
    p.content = desiredBytes(r)
    var inp = DecisionInputs(address: r.address,
      reconcileDrift: reconcileDrift, desiredContent: p.content)
    case r.kind
    of srkFsSystemFile:
      inp.kind = tkFile
    of srkSystemdSystemUnit:
      inp.kind = tkUnit
      inp.unit = r.suName
    else:
      discard
    inp.desiredSha256 = sha256Hex(inp.desiredContent)
    inp.ledgerOwns = p.targetPath in prevOwned
    inp.ledgerSha256 = prevSha.getOrDefault(p.targetPath)
    inp.ledgerObservation = prevObs.getOrDefault(p.targetPath)
    var dec: CollisionDecision
    var obs: TargetObservation
    if saved.found: dec = savedDecision(saved.plan)
    else:
      try: (dec, obs) = decide(driver, inp, p.targetPath)
      except AddonDriftError as e:
        (dec, obs) = revertHeld(r, p, inp, e)
        own.resources[oi] = r
    decisions[r.address] = dec
    p.observation = dec.observation
    p.verdict = $dec.verdict
    if dec.verdict == cvReconcile:
      p.collision = "reconcile"
      p.preserved = deferPreserve(dec.preWriteBytes)
    elif dec.verdict == cvAdopt:
      p.collision = "adopt"
      p.preserved = deferPreserve(dec.preWriteBytes)
    verdictByAddress[r.address] = dec.verdict
    if dec.acceptedOutOfBand:
      acceptedOutOfBand.add((p.targetPath, r.address))
    result.collisions.add(CollisionLine(address: r.address, target: p.targetPath,
      observation: dec.observation, verdict: $dec.verdict, reason: dec.reason))
    targets.add(targetFor(r.address, inp, p.targetPath, dec, obs, saved))
    plans.add(p)
  var enabledUnits = initHashSet[string]()   # units this profile enables
  for r in own.resources & userResources:
    if r.kind == srkSystemdSystemUnit and r.suEnabled:
      enabledUnits.incl(r.suName)
  # Units the profile itself declares: a drop-in of one of them is checked
  # through the unit's own target (its decision and its write-time
  # re-check), not through a second target on the unit file the same
  # switch is about to rewrite -- that one would refuse the drop-in for
  # the switch's own write of its unit.
  var declaredUnits = initHashSet[string]()
  for r in own.resources:
    if r.kind == srkSystemdSystemUnit: declaredUnits.incl(r.suName)
  for r in userResources:
    if r.kind == srkSystemdSystemUnit: declaredUnits.incl(r.suName)
  # The tool each ``linux.addOnTool`` carrier writes for: its launcher
  # manifest binds the tool's closure (``relocatesClosure``).
  var addOnTools = initTable[string, SystemResource]()
  for r in userResources:
    if r.kind == srkLinuxAddOnTool: addOnTools[r.address] = r
  var refusals: seq[ref Exception]
  for i in 0 ..< userResources.len:
    try:
      var r = userResources[i]
      # The tool this file carries for, when it is one of the two files a
      # `linux.addOnTool` of this profile writes (its shape alone is not
      # enough: the tool must be declared).
      let carrier = block:
        let c = addOnToolCarrierOf(r)
        if c in addOnTools: c else: ""
      var p = ResourcePlan(r: r)
      preObserve(p, driver)
      let saved = if replaying: replayPlan.savedPlanFor(r.address)
                  else: (found: false, plan: SavedPlan())
      if saved.found: overlaySaved(p, saved.plan)
      if r.kind == srkSystemdSystemDropIn and not saved.found and
          not declaredByProfile(r.diUnit, declaredUnits):
        # The unit a drop-in modifies must be provided by something; the
        # unit rows decide that (a package unit, or a hand-written one), the
        # file rows the drop-in file itself.
        # The unit's decision is kept for the guard too: a unit masked, or
        # given a transient or /etc fragment, between the plan and the
        # drop-in's write refuses the write.
        let unitInp = DecisionInputs(address: r.address, kind: tkUnit,
          unit: r.diUnit, collision: "dropIn",
          ledgerOwnsDiversion: ("diversion:" & unitPath(r.diUnit)) in prevOwned)
        let (unitDec, unitObs) = decide(driver, unitInp, unitPath(r.diUnit))
        targets.add(plannedTarget(r.address, unitInp, unitPath(r.diUnit),
                                  unitDec, unitObs))
      if r.kind == srkSystemdUnitState:
        # Nothing of the add-on's on the host: no target, no collision row.
        # A missing or masked unit is refused by its driver.
        p.form = "copy"
        p.verdict = $cvNoOp
        verdictByAddress[r.address] = cvNoOp
        plans.add(p)
        continue
      if r.kind in {srkPasswdUser, srkPasswdGroup}:
        # An account: no file, so no write-time target; its driver converges
        # it. The ledger owns it when the previous ledger lists it under
        # this resource (``decideAccount``).
        var ledgerValue = ""
        var owns = false
        for e in previous.entries:
          if e.class == lcAccount and e.path == p.accountKey and
              e.resource == r.address:
            owns = true
            ledgerValue = e.value
        let dec =
          if saved.found: savedDecision(saved.plan, fileBacked = false)
          else: decideAccount(r, ledgerValue, owns, reconcileDrift,
                              r.address in adoptAddresses)
        decisions[r.address] = dec
        accountChecks.add((r: r, ledgerValue: ledgerValue, owns: owns,
                           verdict: dec.verdict))
        p.form = "copy"
        p.observation = dec.observation
        p.verdict = $dec.verdict
        if dec.verdict == cvAdopt:
          # As it is: nothing for the driver to do. No `adopt` collision
          # mark -- that names preserved file bytes, which an account has
          # none of; uninstall keeps every account anyway (§6.4).
          p.skipInfra = true
        verdictByAddress[r.address] = dec.verdict
        if dec.acceptedOutOfBand:
          acceptedOutOfBand.add((p.accountKey, r.address))
        result.collisions.add(CollisionLine(address: r.address,
          target: p.accountKey, observation: dec.observation,
          verdict: $dec.verdict, reason: dec.reason))
        if dec.verdict != cvNoOp:
          result.ledgerDiff.add($dec.verdict & "\t" & p.accountKey & "\t" &
            r.address)
        if dec.verdict in {cvUpdate, cvReconcile}:
          # `usermod --groups` sets exactly the declared set: what it drops
          # is reported, never dropped silently.
          let dropped = droppedSupplementaryGroups(r)
          if dropped.len > 0:
            result.ledgerDiff.add("drop-groups\t" & p.accountKey & "\t" &
              dropped.join(",") & " (" & r.address & " declares " &
              (if r.puGroups.len > 0: r.puGroups.join(",") else: "none") & ")")
        plans.add(p)
        continue
      if r.kind == srkLinuxAddOnTool:
        # Its driver writes the two files the carriers before it decided
        # (``addOnToolCarriers``): the tool changes when either does.
        var v = cvNoOp
        for c in AddOnToolCarrierSuffixes:
          let cv = verdictByAddress.getOrDefault(r.address & c, cvNoOp)
          if cv notin {cvNoOp, cvAdopt}: v = cvUpdate
          elif cv == cvAdopt and v == cvNoOp: v = cvAdopt
        p.form = "copy"
        p.verdict = $v
        verdictByAddress[r.address] = v
        plans.add(p)
        continue
      var inp = DecisionInputs(address: r.address,
        reconcileDrift: reconcileDrift,
        adopt: r.address in adoptAddresses)
      var path = p.targetPath
      case r.kind
      of srkFsSystemFile:
        inp.kind = tkFile
        inp.collision = r.sfCollision
        inp.divertedByProfile = hasDiversionFor(userResources, r.sfPath)
        let declared = r
        inp.stanza = proc (bytes: string): string =
          var x = declared
          x.sfContent = bytes
          x.sfSourceLocal = ""
          renderStanza(x).join("\n")
        if r.sfSourceLocal.len > 0:
          inp.desiredContent = readFile(r.sfSourceLocal)
        else:
          inp.desiredContent = r.sfContent
      of srkSystemdSystemUnit:
        inp.kind = tkUnit
        inp.unit = r.suName
        inp.collision = r.suCollision
        inp.desiredContent = renderedSystemUnitContent(r)
      of srkLinuxDpkgDiversion:
        inp.kind = tkDiversion
      of srkSystemdSystemDropIn, srkLinuxSysctl, srkLinuxTmpfilesRule,
         srkLinuxSysusersEntry:
        # Fragments and drop-ins are files of the add-on's own naming
        # (spec §4.1): the file rows of the decision table apply to them.
        inp.kind = tkFile
        inp.desiredContent = desiredBytes(r)
      else:
        discard
      inp.desiredSha256 = sha256Hex(inp.desiredContent)
      inp.ledgerOwns = (if r.kind == srkLinuxDpkgDiversion:
                          ("diversion:" & path) in prevOwned
                        else: path in prevOwned)
      inp.ledgerOwnsDiversion = ("diversion:" & path) in prevOwned
      inp.ledgerSha256 = prevSha.getOrDefault(path)
      inp.ledgerObservation = prevObs.getOrDefault(path)
      var dec: CollisionDecision
      var obs: TargetObservation
      if saved.found: dec = savedDecision(saved.plan)
      else:
        try: (dec, obs) = decide(driver, inp, path)
        except AddonDriftError as e:
          if relocatesClosure(r, path,
              addOnTools.getOrDefault(carrier)):
            # §9 "Migration": the unit or launcher manifest an older
            # realiser's agent wrote, bound to its prefix of the same closure.
            # Rewritten at the current prefix, its bytes kept for hand-back,
            # never refused as drift.
            let o = observeTarget(driver, path, inp.unit)
            dec = CollisionDecision(verdict: cvReconcile,
              observation: observationText(o, inp.kind),
              observedSha256: o.sha256, preWriteBytes: readFile(path),
              reason: "bound to an older closure realiser's prefix (the same " &
                "package bytes): rewritten at the store-published prefix, " &
                "not restarted")
            obs = o
            p.closureRelocated = true
          else:
            (dec, obs) = revertHeld(r, p, inp, e)
            userResources[i] = r
      if not p.closureRelocated and dec.verdict == cvUpdate and
          relocatesClosure(r, path,
            addOnTools.getOrDefault(carrier)):
        p.closureRelocated = true      # the ledger already holds those bytes
      decisions[r.address] = dec
      if r.kind == srkSystemdSystemUnit and r.suCollision != "dropIn":
        var ownedLinks = initHashSet[string]()
        for e in previous.entries:
          if e.resource == r.address and e.class == lcInstallLink:
            ownedLinks.incl(e.path)
        decideInstall(driver, r, ownedLinks, enabledUnits, targets)
      if r.kind == srkLinuxSysusersEntry and p.accountBefore.len > 0 and
          not inp.ledgerOwns:
        # Spec §4.1: an existing account of the same name with a different
        # UID, GID or shell is a collision; one that matches (or that the
        # entry does not pin) is adopted as it is.
        let fields = p.accountBefore.split(':')
        let liveId = if fields.len > 0: fields[0] else: ""
        let liveShell = if r.seKind != "group" and fields.len >= 5: fields[4]
                        else: ""
        if (r.seId.len > 0 and r.seId != liveId) or
            (r.seShell.len > 0 and r.seShell != liveShell):
          raise newException(AddonCollisionError, "refusing " & r.address &
            ": " & r.seKind & " " & r.seName & " already exists with id " &
            liveId & (if liveShell.len > 0: " and shell " & liveShell else: "") &
            ", which differs from the entry (id " &
            (if r.seId.len > 0: r.seId else: "unpinned") &
            (if r.seShell.len > 0: ", shell " & r.seShell else: "") &
            "); an existing account of the same name with a different UID, " &
            "GID or shell has no opt-in (spec §4.1)")
      p.observation = dec.observation
      p.verdict = $dec.verdict
      p.content = inp.desiredContent
      verdictByAddress[r.address] = dec.verdict
      if dec.acceptedOutOfBand:
        acceptedOutOfBand.add((p.targetPath, r.address))
      # `repro system adopt` changes the addressed resource only. Every other
      # resource is the current generation's; one the ledger owns with bytes
      # that differ from what its declaration renders (an earlier adoption
      # of a hand-written object, not converged since) would be an update,
      # i.e. a write the operator did not ask for. It is held at the bytes
      # it has instead.
      # (A unit with an apt closure is rendered from its lock, so it cannot
      # be pinned to other bytes and is not held.)
      let held = opts.adoptAddresses.len > 0 and
        r.address notin opts.adoptAddresses and dec.verdict == cvUpdate and
        not (r.kind == srkSystemdSystemUnit and r.suAptClosureLock.len > 0)
      if held:
        let current = readFile(path)
        pinToBytes(r, p, current, deferPreserve(current), opts.planOnly)
        p.verdict = $cvNoOp
        verdictByAddress[r.address] = cvNoOp
        userResources[i] = r
        p.r = r
      case (if held: cvNoOp else: dec.verdict)
      of cvAdopt:
        p.collision = "adopt"
        p.preserved = deferPreserve(dec.preWriteBytes)
        # Ask the apply for exactly the bytes that are there: nothing is
        # written, and the ledger owns them.
        pinToBytes(r, p, dec.preWriteBytes, p.preserved, opts.planOnly)
        userResources[i] = r
        p.r = r
      of cvReconcile:
        p.collision = (if p.closureRelocated: "closure-relocate"
                       else: "reconcile")
        p.preserved = deferPreserve(dec.preWriteBytes)
      of cvDivert:
        p.collision = "divert"
      of cvReplace:
        p.collision = "replace"
      of cvDropIn, cvCreate, cvUpdate, cvNoOp:
        if r.address in dropIns:
          p.collision = "dropIn"
      # The materialisation form (spec §7.2 steps 4 and 5): a link for the
      # link-form kinds, except an object adopted as it is (nothing is
      # written to it) -- a copy until its content changes -- and a file
      # taken over from a package by a diversion. The package's own tooling
      # reads the diverted path and resolves the link: ucf, run by the
      # package's postinst, wrote its `.ucf-dist` beside the store copy and
      # the upgrade failed on the read-only store (measured 2026-10-30,
      # Debian 13 and Ubuntu 24.04). Unit files are copies by kind, above.
      # A profile's copy of a generation-0 object stays a copy, as
      # generation 0's was: taking it over with the same bytes writes nothing.
      p.form = if held: prevForm.getOrDefault(path, "copy")
               elif r.address in supersedingUser: "copy"
               elif p.keepLedgerSha.len > 0: prevForm.getOrDefault(path, "copy")
               elif carrier.len > 0: "copy"
               elif r.kind in LinkFormKinds and
                  dec.verdict notin {cvAdopt, cvDivert}: "link"
               else: "copy"
      result.collisions.add(CollisionLine(address: r.address, target: path,
        observation: dec.observation,
        verdict: (if held: $cvNoOp else: $dec.verdict),
        reason: (if held: "held at its current bytes: `repro system adopt` " &
                          "changes only the resource it names"
                 else: dec.reason)))
      if dec.verdict != cvNoOp and not held:
        result.ledgerDiff.add((if p.closureRelocated: "relocate-closure"
                               else: $dec.verdict) & "\t" & path & "\t" &
                              r.address)
      targets.add(targetFor(r.address, inp, path, dec, obs, saved))
      if carrier.len > 0:
        # The tool's own operation writes this file: the write-time re-check
        # of the file's decision is the tool's too.
        targets.add(targetFor(carrier, inp, path, dec, obs, saved))
      if r.address in supersedingUser and p.collision.len == 0:
        p.collision = "supersede"
      if carrier.len > 0:
        # The tool's driver writes this file (with the wrapper's mode); the
        # carrier only decides and ledgers it.
        p.skipInfra = true
      plans.add(p)
    except CatchableError:
      # Every refusal is collected before any is raised, whatever its type:
      # nothing has been written yet (the bytes to preserve wait in
      # ``pendingPreserve``), and an operator fixing a host -- a migration
      # plan above all -- needs the whole list, not one refusal per run.
      refusals.add(getCurrentException())

  # Realising the closures is step 1's first write to the store's
  # filesystem (and, for an archive neither cached nor held by an older
  # realiser's prefix, its only fetch): a profile whose closures would not
  # fit, with the reserve left free, or whose archives the archive does not
  # serve (asked only by a plan with ``probeArchives``: the switch has no
  # network), is refused now, before anything is written (§9).
  block:
    var locks: seq[AptClosureLock]
    for r in userResources:
      try:
        if r.kind == srkSystemdSystemUnit and r.suAptClosureLock.len > 0:
          locks.add(parseAptClosureLock(r.suAptClosureLock))
        elif r.kind == srkLinuxAddOnTool:
          locks.add(parseAptClosureLock(r.atAptClosureLock))
      except CatchableError:
        discard          # the resource's own decision refused it above
    let space = closureSpace(locks,
      probe = (if opts.probeArchives: httpDebProbe() else: nil))
    if space.closures > 0:
      result.storeSpace = describe(space)
      result.closureSources = space.sources
      for u in space.unavailable:
        refusals.add(newException(AddonStoreSpaceError, "refusing the " &
          "switch: an apt closure member cannot be realised: " & u))
      if spaceIsShort(space):
        refusals.add(newException(AddonStoreSpaceError, "refusing the " &
          "switch: realising its apt closures needs more of " &
          AddOnSystemStoreRoot & "'s filesystem than is free: " &
          result.storeSpace))
  # Step 1 recomputes the store's hold from every unit, manifest and
  # hand-back record on the host (``migrateLegacyAptClosures``); one that
  # cannot be read stops it there. The plan reads them the same way, so it
  # is not clean while the switch would refuse, and the switch refuses
  # before it writes anything.
  block:
    let why = liveReferenceRefusal(@[preservedDir(stateDir)])
    if why.len > 0:
      refusals.add(newException(AddonCollisionError, "refusing the " &
        "switch: step 1 recomputes the store's hold, and " & why))
  # A tool's driver writes its wrapper only with the sandbox launcher
  # beside the engine that applies it (``addOnToolLauncherPath``); without
  # it the apply would fail after the flip.
  for r in userResources:
    if r.kind == srkLinuxAddOnTool and
        verdictByAddress.getOrDefault(r.address, cvNoOp) notin
          {cvNoOp, cvAdopt} and
        not fileExists(addOnToolLauncherPath()):
      refusals.add(newException(AddonCollisionError, "refusing " &
        r.address & ": its wrapper would be written, and the sandbox " &
        "launcher it execs is not installed beside this engine at " &
        addOnToolLauncherPath() & " (install the reprobuild bundle or " &
        "add-on artefact that carries both)"))
      break

  if refusals.len > 0:
    # The first refusal keeps its type (its typed diagnostic and exit
    # status); its message lists every other one after it, and the store
    # space the closures need.
    let first = refusals[0]
    if refusals.len > 1:
      var more = "\n" & $(refusals.len - 1) & " more refusal" &
        (if refusals.len > 2: "s" else: "") & ":"
      for e in refusals[1 .. ^1]: more.add("\n  " & e.msg)
      first.msg.add(more)
    if result.storeSpace.len > 0:
      first.msg.add("\nstore space: " & result.storeSpace)
    raise first

  # `repro system adopt`: the addressed resource must actually be claimed
  # as it is. Anything else (the target is absent, package-owned, or
  # owned with other bytes, so the apply would write) refuses here,
  # before any byte is written or a generation committed (spec §11.2).
  for a in opts.adoptAddresses:
    let v = verdictByAddress.getOrDefault(a, cvCreate)
    if v notin {cvAdopt, cvNoOp}:
      raise newException(AddonCollisionError, "refusing to adopt " & a &
        ": its target would be " & $v & ", not adopted as it is (see the " &
        "collision report); nothing was written")

  let composed = SystemProfile(addOn: user.addOn,
                               resources: own.resources & userResources,
                               secretFiles: user.secretFiles)
  # What the infra apply gets: the composition minus the resources adopted
  # as they are that it could not leave untouched (``skipInfra``), and
  # minus any dependency on them.
  var skipped = initHashSet[string]()
  for p in plans:
    if p.skipInfra: skipped.incl(p.r.address)
  var infraProfile = SystemProfile(addOn: user.addOn,
                                   secretFiles: user.secretFiles)
  for r in composed.resources:
    if r.address in skipped: continue
    var x = r
    var deps: seq[tuple[kind, name: string]]
    for dep in r.dependsOn:
      var drop = false
      for p in plans:
        if p.skipInfra and resourceKindTag(p.r) == dep.kind and
            resourceName(p.r) == dep.name:
          drop = true
      if not drop: deps.add(dep)
    x.dependsOn = deps
    infraProfile.resources.add(x)
  let composedText = renderProfileText(infraProfile)
  # The services the carried-state cross-check judges at step 6, chosen
  # now, as the refusal judged them, before anything of this switch is
  # written: each write of a unit reloads systemd, which runs the host's
  # generators, and a drop-in a generator makes from then on can turn a
  # unit the refusal let in into one the analysis would read as reaching
  # everything -- so a set chosen at step 6 left it out of the check
  # altogether (A13 round 6, the adopt gate's live probe on ubuntu-24.04).
  let preWriteLiveUnits =
    when mutated("live-units-chosen-after-writes"): newSeq[string]()
    else:
      if opts.recordOnly: newSeq[string]()
      else: liveReachUnitsFor(opts, composed.resources)
  var wanted = initHashSet[string]()
  for r in composed.resources: wanted.incl(r.address)

  # --- What left the profile, and may it be removed? (spec §4.2) ---
  # The stored profile is what the operator declared (plus what an earlier
  # removal left as drift); it is reshaped the same way, so the addresses
  # match the ledger's.
  var removed: seq[SystemResource]
  var previousUser: SystemProfile
  if previousUserText.len > 0:
    previousUser = parseStoredUserProfile(previousUserText, stateDir)
    var prevDropIns = initHashSet[string]()
    let previousShaped = reshape(previousUser, prevDropIns)
    when not mutated("retargeted-address-accepted"):
      let moved = retargetedAddresses(previousShaped, composed.resources)
      if moved.len > 0:
        let m = moved[0]
        raise newAddOnOutOfScope("address", "", m.address,
          "the resource at address `" & m.address & "` now targets " &
          m.now & ", and the current generation's targets " & m.was &
          "; an address names one object, so a renamed unit or moved file " &
          "needs a new address (the old one is then removed, and an " &
          "exclusive unit's old instance stopped and confirmed first)")
    for r in previousShaped:
      if r.address notin wanted:
        removed.add(r)
  removed.sort(proc(a, b: SystemResource): int =
    cmp(removalRank(a), removalRank(b)))
  var destroy: seq[SystemResource]        # handed to infra as destroys
  var restore: seq[LedgerEntry]           # put back from preserved bytes
  var needReloadAfterRemoval = false      # a drop-in left: systemd must see it
  var keptAddresses = initHashSet[string]()  # left as drift: still owned
  var keptPaths = initHashSet[string]()
  var keptEntries: seq[LedgerEntry]       # drifted: stay in the ledger
  var removedEntries: seq[LedgerEntry]    # everything of a removed resource
  var forgottenEntries: seq[LedgerEntry]  # unitState requirements dropped:
                                          # the state stays, accounted for
  var removedUnits: seq[SystemResource]   # units whose files go
  var handedBackUnits: seq[SystemResource] # units handed back to the base
  var removedSysctl: seq[LedgerEntry]     # keys to restore in step 6
  var handedBack = initHashSet[string]()
    # `<class> <path>` of every entry whose path a package came to own: its
    # removal hands the path back (``handback.nim``), so the commit drops
    # the entry whatever is at the path.
  var planDrift = initTable[string, string]()
    # `<class> <path>` -> what `observeDrift` said when the removal was
    # decided. Before each destroy and each restore the object is observed
    # again; a different answer means it changed since the decision, and it
    # is left in place as drift (spec §4.2 rule 1) instead of removed on
    # the strength of a stale observation.
  for r in removed:
    # A diversion whose file is kept as drift stays with it: dpkg cannot
    # move the package's copy back over a file that is still there.
    if r.kind == srkLinuxDpkgDiversion and r.ddPath in keptPaths:
      for e in previous.entries:
        if e.resource == r.address: keptEntries.add(e)
      keptAddresses.incl(r.address)
      result.drift.add(r.ddPath & ": its diversion is kept with the " &
        "drifted file")
      continue
    if r.kind in {srkPasswdUser, srkPasswdGroup}:
      # Accounts are kept for ever (§6.4), like the sysusers class's: the
      # resource is forgotten and its account stays, resource-less in the
      # ledger so the fingerprint delta still accounts for it.
      for e in previous.entries:
        if e.resource == r.address and e.class == lcAccount:
          var kept = e
          kept.resource = ""
          forgottenEntries.add(kept)
      result.removed.add(r.address)
      result.ledgerDiff.add("forget\t" & accountKeyOf(r) & "\t" & r.address)
      continue
    if r.kind == srkLinuxAddOnTool:
      # Its wrapper and manifest are its carriers' (removed with them); the
      # launcher link is in no digest and is left for the next tool.
      result.removed.add(r.address)
      continue
    if r.kind == srkSystemdUnitState:
      # Forgetting a requirement changes nothing on the host (§4.1).
      for e in previous.entries:
        if e.resource == r.address and e.class == lcUnitState:
          var kept = e
          kept.resource = ""
          forgottenEntries.add(kept)
      result.removed.add(r.address)
      result.ledgerDiff.add("forget\t" & r.usName & "\t" & r.address)
      continue
    var entries: seq[LedgerEntry]
    var primary = 0
    for e in previous.entries:
      if e.resource == r.address:
        entries.add(e)
        # Directories are shared side effects (three files can have made
        # the same parent); only the object itself says the ledger owns
        # the resource. A resource whose apply failed before its object
        # was written has directory entries and nothing else.
        if e.class in {lcEtcFile, lcUnit, lcDropIn, lcDiversion,
                       lcInstallLink, lcMount, lcSysctl}:
          inc primary
    if primary == 0:
      result.unlisted.add(r.address)
      result.ledgerDiff.add("unlisted\t" & r.address & "\t" & r.address)
      # Its directory entries go with it; a directory something else put a
      # file in is kept, as below.
      removedEntries.add(entries)
      continue
    # A path a package came to own since (spec §4.3, §7.8) is handed back
    # to it, never deleted: the entry leaves the ledger, the file stays,
    # and an add-on link there becomes a regular file with the same bytes
    # (written with the restores, from bytes read now: after the flip the
    # link no longer resolves).
    var packageNow = ""
    for e in entries:
      let pkg = newPackageOwner(e, driver)
      if pkg.len > 0:
        packageNow = pkg
        handedBack.incl(entryKeyOf(e))
        if isOwnLinkStill(e):
          var back = e
          back.preserved = deferPreserve(handBackBytes(e))
          back.replaced = "f " & (if e.mode.len > 0: e.mode else: "0644") &
            " " & (if e.owner.len > 0: e.owner else: "0:0") & " sha256:" &
            sha256Hex(handBackBytes(e))
          restore.add(back)
    if packageNow.len > 0:
      result.removed.add(r.address)
      # A resolution, not drift: the ledger diff says what happened.
      result.ledgerDiff.add("hand-back\t" & entries[^1].path & "\t" &
        r.address & " (to package " & packageNow & ")")
      removedEntries.add(entries)
      continue
    var drifted: seq[string]
    for e in entries:
      let d = observeDrift(e)
      planDrift[entryKeyOf(e)] = d
      if d.len > 0 and not d.startsWith("missing") and
          not (replaying and replayTolerates(e, d)):
        drifted.add(e.path & ": " & d)
    if drifted.len > 0 and not reconcileDrift:
      for d in drifted: result.drift.add(d & " (left in place; " &
        "--reconcile-drift removes it)")
      keptEntries.add(entries)
      keptAddresses.incl(r.address)
      for e in entries:
        if e.class in {lcEtcFile, lcUnit, lcDropIn}: keptPaths.incl(e.path)
      continue
    if drifted.len > 0:
      # Reconciled removal: what is there now is kept before it goes.
      for e in entries:
        if e.class in {lcEtcFile, lcUnit, lcDropIn} and fileExists(e.path):
          discard deferPreserve(readFile(e.path))
    # Objects that go back to what they were rather than away: anything
    # the ledger preserved bytes for (adopted, reconciled), and a
    # `replace`d package unit, whose removal must not `disable --now` the
    # package's unit the way the driver's destroy would.
    var restoresInstead = false
    for e in entries:
      if e.class in {lcEtcFile, lcUnit, lcDropIn} and
          (e.preserved.len > 0 or (e.class == lcUnit and e.collision == "replace")):
        restore.add(e)
        restoresInstead = true
      if e.class == lcSysctl:
        removedSysctl.add(e)
    # A replay finds a removal the interrupted switch already made: every
    # file of the resource gone, or the base's own file back in its place.
    # Its destroy is not dispatched again -- a destroy of the base's file
    # would remove what the removal had just put back.
    var alreadyRemoved = false
    if replaying:
      alreadyRemoved = true
      for e in entries:
        if e.class in {lcEtcFile, lcUnit, lcDropIn}:
          let gone = not fileExists(e.path) and not symlinkExists(e.path)
          if not gone and not alreadyRestored(e):
            alreadyRemoved = false
        elif e.class == lcDiversion:
          if fileExists(DpkgDiversionsDb) and
              readDpkgDiversion(readFile(DpkgDiversionsDb), e.path).present:
            alreadyRemoved = false
        elif e.class in {lcSysctl, lcInstallLink, lcMount}:
          if e.class == lcInstallLink and symlinkExists(e.path):
            alreadyRemoved = false
    if not restoresInstead and not alreadyRemoved:
      destroy.add(r)
    if r.kind == srkSystemdSystemUnit and restoresInstead:
      handedBackUnits.add(r)
      # Handed back to the base (a `replace`d package unit, an adopted or
      # reconciled hand-written one): the switch neither stops nor
      # disables it; `restoreUnitState` re-asserts the base's enablement
      # and restarts it from the base's file after the reload.
      needReloadAfterRemoval = true
    elif r.kind == srkSystemdSystemUnit:
      removedUnits.add(r)
      if r.suStopHeld:
        # Left running (§7.3 `stopOnRemoval = false`): the instance is
        # still the add-on's doing, so a resource-less state entry keeps
        # accounting for it until a later apply observes it inactive.
        for e in entries:
          if e.class == lcUnit:
            forgottenEntries.add(LedgerEntry(class: lcUnitState,
              path: e.unit, unit: e.unit, activeState: "active",
              baseActiveState: e.baseActiveState, started: true,
              hasInstall: true))
    for e in entries:
      if e.class == lcDropIn: needReloadAfterRemoval = true
    result.removed.add(r.address)
    result.ledgerDiff.add("remove\t" & (if entries.len > 0: entries[^1].path
                                        else: "") & "\t" & r.address)
    removedEntries.add(entries)

  # The profile to store: the operator's declaration, plus the resources an
  # earlier generation declared that are still owned because their removal
  # was left as drift. They leave the ledger when --reconcile-drift removes
  # them.
  var stored = SystemProfile(addOn: user.addOn, resources: user.resources,
                            secretFiles: user.secretFiles)
  for r in previousUser.resources:
    if r.address in keptAddresses and r.address notin wanted:
      stored.resources.add(r)
      # A kept unit's credentials stay declared, so the stored text parses.
      if r.kind == srkSystemdSystemUnit and r.suCredentials.len > 0:
        for d in previousUser.secretFiles:
          if d.service == credentialServiceOf(r.suName) and d notin stored.secretFiles:
            stored.secretFiles.add(d)

  # --- Secrets (milestone A7, spec §10.3). One set of declarations is
  # materialised here and at boot: the stored profile's, which keeps the
  # declarations of a unit left in place as drift. Everything they need --
  # a recipient key that passes its owner and mode check, an envelope it
  # opens, an entry per declaration -- is checked now, before anything is
  # written; a revert or a replay goes back to what was there and is not
  # refused for it. The services whose secrets will change are planned
  # into the transitions (a unit reads its credentials when it starts).
  let secretDecls = stored.secretFiles
  if purpose notin ["revert", "replay"] and not opts.recordOnly:
    try:
      checkSecretsAvailable(secretsLayout, secretDecls, secretsSource)
    except AddonSecretsFailed as e:
      if purpose == "rollback" and
          secretsSource != generationEnvelopeOf(stateDir, opts.secretsFromGeneration):
        # The target keeps no envelope copy (committed before copies were
        # kept, or its copy could not be written): the latest envelope is
        # used only when it covers the target's declarations.
        e.msg = "generation " & opts.secretsFromGeneration & " keeps no " &
          "envelope copy, and the latest envelope does not serve its " &
          "declarations: " & e.msg
      raise
  var credentialChanged: seq[string]
  try:
    credentialChanged = plannedSecretChanges(secretsLayout, secretDecls,
                                             secretsSource)
  except AddonSecretsFailed:
    if purpose notin ["revert", "replay"] and not opts.recordOnly: raise
  when mutated("credentials-not-planned"):
    # FALSIFYING MUTATION: a credential change is not planned into the
    # transitions (no restart, no exclusive stop-start).
    credentialChanged = @[]

  # Nothing is written for them, but the out-of-band write is reported on
  # every apply, a rollback's included (spec §4.3).
  result.ledgerDiff.add(acceptedOutOfBandDiff(acceptedOutOfBand))
  result.drift.add(revertHeldDrift)

  # --- The service transition list (spec §7.3). ---
  # In the composed profile's dependency order, so step 7 starts a unit
  # after what it depends on.
  let order = topologicallyOrder(composed, buildDependencyGraph(composed))
  var planByAddress = initTable[string, int]()
  for i, p in plans: planByAddress[p.r.address] = i
  var prevUnits = initTable[string, LedgerEntry]()   # unit name -> entry
  for e in previous.entries:
    if e.class == lcUnit and e.resource.len > 0: prevUnits[e.unit] = e
  var dropInsChangedFor = initHashSet[string]()     # unit names
  for p in plans:
    if p.r.kind == srkSystemdSystemDropIn and p.verdict != $cvNoOp:
      # An adopted drop-in is not written (§4.3), so it changes the unit
      # only when systemd has not loaded it yet (see `unitFileChanged`).
      if p.verdict != $cvAdopt or
          readUnitProvision(p.r.diUnit).needDaemonReload:
        dropInsChangedFor.incl(p.r.diUnit)
  for r in removed:
    if r.kind == srkSystemdSystemDropIn: dropInsChangedFor.incl(r.diUnit)
  var addressByKey = initTable[string, string]()
  for r in composed.resources:
    addressByKey[resourceKindTag(r) & ":" & resourceName(r)] = r.address
  # A unit handed back as found stays running only when nothing it loads
  # changes in this switch (``quietHandBack``): none of the drop-ins the
  # add-on wrote for it, none of its `depends_on` targets. A target still
  # declared changes unless its verdict writes nothing; a removed one
  # changes unless it, too, goes back with the bytes it has.
  var loudHandBack = initHashSet[string]()
  block:
    var removedByKey = initTable[string, SystemResource]()
    for r in removed:
      removedByKey[resourceKindTag(r) & ":" & resourceName(r)] = r
    proc restoredAsIs(address: string): bool =
      var any = false
      for e in restore:
        if e.resource != address: continue
        any = true
        if not (e.preserved.len > 0 and fileExists(e.preserved) and
                sha256Hex(readFile(e.preserved)) == e.sha256):
          return false
      for d in destroy:
        if d.address == address: return false
      any
    for r in handedBackUnits:
      var changed = r.suName in dropInsChangedFor
      for dep in r.dependsOn:
        let key = dep.kind & ":" & dep.name
        if key in addressByKey:
          if verdictByAddress.getOrDefault(addressByKey[key], cvNoOp) notin
              {cvNoOp, cvAdopt}:
            changed = true
        elif key in removedByKey:
          if not restoredAsIs(removedByKey[key].address): changed = true
      if changed: loudHandBack.incl(r.suName)
  for r in user.resources:
    # A timer is composed as a unit (``reshape``): a `depends_on` names it
    # by its own kind.
    if r.kind == srkSystemdSystemTimer:
      addressByKey[resourceKindTag(r) & ":" & resourceName(r)] = r.address
  # Units an interrupted or failed switch had running at its plan time
  # (its step 2 may have stopped them): planned as running, so they are
  # (re)started rather than left down.
  var assumeActive = initHashSet[string]()
  for u in opts.assumeActive: assumeActive.incl(u)
  if replaying:
    for u in replayPlan.activeUnits: assumeActive.incl(u)
  var facts: seq[UnitFacts]
  var unitDeps = initTable[string, seq[string]]()
  var factUnits = initHashSet[string]()
  proc observed(f: var UnitFacts) =
    ## The one place a unit's running state is read for the plan: systemd's
    ## ActiveState, and -- for an exclusive unit -- the control group's
    ## population (§7.3: "confirmed exited" is the group, not the state).
    ## Both are pinned by the plan id.
    let prov = readUnitProvision(f.unit)
    f.activeState = prov.activeState
    f.loadedAtPlan = prov.loadState == "loaded"
    # A unit an interrupted or failed switch had running is planned as
    # running, so its replay or revert starts it again (step 2 may have
    # stopped it; a restart applies only to an active unit).
    f.active = f.activeState == "active" or
      (not f.removed and f.unit in assumeActive)
    f.alive = if f.exclusive: unitAliveness(f.unit) else: uaEmpty
  for r in removedUnits:
    var f = UnitFacts(unit: r.suName, address: r.address, owned: true,
      removed: true, exclusive: isExclusiveUnit(r), stopHeld: r.suStopHeld)
    observed(f)
    facts.add(f)
    factUnits.incl(r.suName)
  for idx in order:
    let r = composed.resources[idx]
    case r.kind
    of srkSystemdSystemUnit:
      let p = plans[planByAddress[r.address]]
      let rendered = renderedSystemUnitContent(r)
      var f = UnitFacts(unit: r.suName, address: r.address, owned: true,
        enabled: r.suEnabled,
        exclusive: isExclusiveUnit(r) or
          (r.suName in prevUnits and
           unitContentDeclaresExclusive(readFile(prevUnits[r.suName].path))),
        restartHeld: r.suRestartHeld, reloadIfChanged: r.suReloadIfChanged,
        stopHeld: r.suStopHeld,
        credentialsChanged: r.suCredentials.len > 0 and
          credentialServiceOf(r.suName) in credentialChanged)
      observed(f)
      f.isNew = r.suName notin prevUnits
      let closureMissing = r.suAptClosureLock.len > 0 and
        not aptClosureRealised(AddOnSystemStoreRoot,
                               parseAptClosureLock(r.suAptClosureLock))
      f.fileChanged = not p.closureRelocated and unitFileChanged(f.isNew,
        p.verdict,
        (if f.isNew: "" else: prevUnits[r.suName].sha256), sha256Hex(rendered),
        closureMissing,
        loadedStale = f.isNew and p.verdict == $cvAdopt and
          readUnitProvision(r.suName).needDaemonReload)
      f.dropInsChanged = r.suName in dropInsChangedFor
      if f.exclusive:
        # Conflicts= as systemd reads it -- drop-ins, continuations,
        # specifiers, aliases -- failing closed on anything unresolved.
        var profileDropIns: seq[string]
        for q in plans:
          if q.r.kind == srkSystemdSystemDropIn and q.r.diUnit == r.suName:
            profileDropIns.add(q.content)
        try:
          f.predecessors = predecessorsOf(r.suName, rendered, profileDropIns)
        except CatchableError as e:
          raise newAddOnExclusiveOverlap(r.suName, "its predecessors " &
            "(Conflicts=) cannot be resolved: " & e.msg)
        # The units that can activate it (sockets, timers, paths): a
        # stop-start pauses the active ones (§7.3).
        for t in unitListProperty(r.suName, "TriggeredBy"):
          if readUnitProvision(t).activeState == "active":
            f.triggers.add(t)
        for pred in f.predecessors:
          # A predecessor the add-on does not own is never stopped or
          # disabled by it; while it runs, is enabled, or can be started
          # by an active or enabled socket, timer or path (a static
          # service behind an enabled socket), the successor cannot start
          # without overlapping it -- now or at the next boot -- so the
          # plan refuses (§7.3).
          if pred in prevUnits: continue
          let pv = readUnitProvision(pred)
          let alive = unitAliveness(pred)
          var liveTriggers: seq[string]
          for t in unitListProperty(pred, "TriggeredBy"):
            let tv = readUnitProvision(t)
            if tv.activeState == "active" or tv.unitFileState in
                ["enabled", "enabled-runtime", "linked", "linked-runtime",
                 "alias"]:
              liveTriggers.add(t & " (" & tv.activeState & ", " &
                               tv.unitFileState & ")")
          when not mutated("unmanaged-predecessor-not-refused"):
            if pv.activeState == "active" or alive != uaEmpty or
                pv.unitFileState in ["enabled", "enabled-runtime", "linked",
                                     "linked-runtime", "alias"] or
                liveTriggers.len > 0:
              raise newAddOnExclusiveOverlap(r.suName, "its predecessor " &
                pred & " (named in its Conflicts=) is not the add-on's and " &
                "is " & pv.activeState & " with its control group " &
                $alive & " and unit-file state " &
                (if pv.unitFileState.len > 0: pv.unitFileState
                 else: "unknown") &
                (if liveTriggers.len > 0: "; it can be started by " &
                   liveTriggers.join(", ") else: "") &
                "; stop and disable it (and its triggers), then apply again")
      for dep in r.dependsOn:
        let depAddress = addressByKey.getOrDefault(dep.kind & ":" & dep.name)
        if depAddress.len == 0: continue
        if isUnitDependency(dep.kind):
          unitDeps.mgetOrPut(r.address, @[]).add(depAddress)
        elif verdictByAddress.getOrDefault(depAddress, cvNoOp) notin
            {cvNoOp, cvAdopt}:
          # An adoption writes nothing (§4.3): the bytes the unit reads are
          # the ones it already had, so it is not a change for its
          # dependents. Only a write is.
          f.depsChanged = true
      facts.add(f)
      factUnits.incl(r.suName)
    of srkSystemdUnitState:
      var f = UnitFacts(unit: r.usName, address: r.address,
        unitState: true, desiredActive: r.usRunning)
      observed(f)
      facts.add(f)
      factUnits.incl(r.usName)
    else:
      discard
  # A drop-in of a unit the profile does not own: the unit is restarted
  # for the drop-in's change (§7.3) unless the drop-in holds it.
  for p in plans:
    if p.r.kind == srkSystemdSystemDropIn and p.r.diUnit notin factUnits and
        p.r.diUnit in dropInsChangedFor:
      var f = UnitFacts(unit: p.r.diUnit, address: p.r.address,
        dropInsChanged: true, restartHeld: p.r.diRestartHeld)
      observed(f)
      facts.add(f)
      factUnits.incl(p.r.diUnit)
  for r in removed:
    if r.kind == srkSystemdSystemDropIn and r.diUnit notin factUnits:
      var f = UnitFacts(unit: r.diUnit, address: r.address,
        dropInsChanged: true, restartHeld: r.diRestartHeld)
      observed(f)
      facts.add(f)
      factUnits.incl(r.diUnit)
  # The units a stop or restart propagates to (RequiredBy=, RequisiteOf=,
  # BoundBy=, ConsistsOf=, PropagatesStopTo=), with facts of their own,
  # transitively through units of every type, so the plan can carry the
  # stops and restarts systemd would otherwise make unannounced (§7.3).
  block:
    var i = 0
    while i < facts.len:
      if facts[i].activeState notin ["", "inactive"] or facts[i].removed or
          facts[i].alive != uaEmpty:
        facts[i].dependents = unitDependents(facts[i].unit)
        facts[i].stopDependents = unitStopDependents(facts[i].unit)
        facts[i].reloadDependents = unitListProperty(facts[i].unit,
                                                     "PropagatesReloadTo")
        # Its active upholders (Upholds=, §7.3), and for a removed unit the
        # ones its own ledgered UpheldBy= link makes.
        for u in unitListProperty(facts[i].unit, "UpheldBy"):
          if readUnitProvision(u).activeState in ["active", "reloading",
                                                  "activating"]:
            facts[i].upholders.add(u)
        if facts[i].removed:
          for e in previous.entries:
            if e.resource == facts[i].address and e.class == lcInstallLink:
              let dir = e.path.parentDir.extractFilename
              if dir.endsWith(".upholds") and
                  e.path.extractFilename == facts[i].unit:
                let u = dir[0 ..< dir.len - ".upholds".len]
                if u in facts[i].upholders: facts[i].ownUpholdLinks.add(u)
        for d in facts[i].dependents & facts[i].stopDependents:
          if d in factUnits: continue
          let frag = unitProperty(d, "FragmentPath")
          var dExclusive = false
          if frag.len > 0 and fileExists(frag):
            try: dExclusive = unitContentDeclaresExclusive(readFile(frag))
            except IOError, OSError: dExclusive = true   # unreadable: fail closed
          var df = UnitFacts(unit: d, address: "dependent:" & d,
            exclusive: dExclusive)
          observed(df)
          if dExclusive:
            df.triggers = @[]
            for t in unitListProperty(d, "TriggeredBy"):
              if readUnitProvision(t).activeState == "active": df.triggers.add(t)
          facts.add(df)
          factUnits.incl(d)
      inc i
  # Kept for step 2: a removed unit the re-check leaves in place whole is
  # taken out of these facts and the transitions planned again, so it is
  # neither stopped nor the cause of any dependent's stop or restart.
  let unpropagatedFacts = facts
  propagateDependencyChanges(facts, unitDeps)
  result.transitions = planTransitions(facts)
  # Upholds= (§7.3): each active upholder of a unit step 2 stops is
  # planned (its own link removed first, or paused) or the plan refuses,
  # with nothing written.
  for refusal in planUpholds(result.transitions, facts):
    if refusal.exclusive:
      raise newAddOnExclusiveOverlap(refusal.unit, refusal.detail)
    raise newException(AddonApplyError, "refusing the plan: unit " &
      refusal.unit & ": " & refusal.detail & "; nothing was written")

  # --- The plan id (spec §7.1): everything the plan was computed from. ---
  # The profile texts, the ledger it compared against, every target's
  # observation and every unit's observed state (with an exclusive unit's
  # control group and its predecessors'). A pinned apply recomputes it from
  # what it observes now and refuses before anything is written when they
  # differ: a unit that crashed, was started or was left alive since the
  # plan would otherwise get a transition nobody reviewed.
  block:
    var inputs: seq[string]
    inputs.add("own\t" & sha256Hex(ownText))
    inputs.add("user\t" & sha256Hex(opts.userProfileText))
    inputs.add("ledger\t" & sha256Hex(render(previous)))
    inputs.add("reconcile\t" & $opts.reconcileDrift)
    inputs.add("adopt\t" & opts.adoptAddresses.join(","))
    inputs.add("base\t" & sha256Hex(baseIdentityText))
    for t in targets:
      inputs.add("target\t" & t.address & "\t" & t.path & "\t" &
        t.observation & "\t" & t.observedSha256 & "\t" & $t.verdict)
    for f in facts:
      when mutated("plan-id-omits-unit-state"):
        # The falsifying mutation of the stale-plan check: the id covers
        # which units the plan considered but not the state it observed
        # them in, so a unit that crashed since the plan goes unnoticed.
        inputs.add("unit\t" & f.unit)
      else:
        inputs.add("unit\t" & f.unit & "\t" & f.activeState & "\t" & $f.alive &
          "\t" & f.triggers.join(",") & "\t" & f.dependents.join(",") &
          "\t" & f.stopDependents.join(",") & "\t" & f.upholders.join(",") &
          "\t" & $f.loadedAtPlan)
        for pred in f.predecessors:
          inputs.add("predecessor\t" & pred & "\t" &
            readUnitProvision(pred).activeState & "\t" & $unitAliveness(pred))
    result.planId = planIdOf(inputs)
  if opts.planId.len > 0 and opts.planId != result.planId:
    raisePlanStale(opts.planId, @["the add-on observations the plan was " &
      "computed from changed (the profile, the ledger, a target's " &
      "ownership or content, or a unit's state); they now give plan " &
      result.planId])

  # --- The static tree (spec §7.2 step 1): every link-form object. ---
  var treeFiles: seq[StaticFile]
  for p in plans:
    if p.form == "link":
      treeFiles.add(StaticFile(path: p.targetPath, content: p.content))
  # A link-form object left in place as drift keeps the bytes it has now:
  # its link must still resolve after the flip, or "left in place" would
  # mean "destroyed".
  for e in keptEntries:
    if e.isLink and fileExists(e.path):
      treeFiles.add(StaticFile(path: e.path, content: readFile(e.path)))
  result.staticTree = staticTreePath(treeFiles)

  result.floorExceptions = floorExceptionPlanLines(user)
  result.floorIntroduced = floorIntroducedUnits(previousUser, previous,
                                                user.resources)
  if opts.planOnly:
    return
  # An unattended (agent) apply never gives a running service its first
  # floor: the change is reviewed in an operator's plan (spec §10.1). A
  # replay or a revert of a switch already under way is not refused.
  if opts.agentSequence > 0'u64 and purpose == "apply" and not replaying and
      result.floorIntroduced.len > 0:
    raise newException(AddonNeedsOperator, "operator action required: the " &
      "hardening floor (serviceFloor) would change " &
      result.floorIntroduced.join(", ") & "; an agent apply does not " &
      "restart a running service into a floor it was not installed with. " &
      "Review `repro system addon plan` and apply this profile once " &
      "as an operator, or waive the unit's whole floor (floorExceptions = " &
      "[\"serviceFloor: <why>\"]); a named exception still changes the " &
      "unit and does not avoid this. Nothing was changed")

  # Step 1 recomputes the store's hold from every unit, manifest and
  # hand-back record on the host; the plan checked they can be read, but
  # one can have become unreadable since. Checked again here, before the
  # first byte this switch writes (the preserved bytes just below, the
  # write-ahead plan, the pending marker), so the switch refuses with
  # nothing written rather than failing in step 1.
  block:
    let why = liveReferenceRefusal(@[preservedDir(stateDir)])
    if why.len > 0:
      raise newException(AddonCollisionError, "refusing the switch: step 1 " &
        "recomputes the store's hold, and " & why & "; nothing was written")

  # The invocation id every running managed unit has just before step 2
  # (taken in `beforeSet`, under the apply lock, after realise): one that
  # differs at the commit was started during the switch (§5.2).
  var invocationsBefore = initTable[string, string]()
  # The units the switch itself starts or restarts in step 7.
  var startedBySwitch = initHashSet[string]()
  for t in result.transitions:
    if t.verb in {tvStart, tvRestart, tvStopStart}: startedBySwitch.incl(t.unit)

  # Every resource is decided and nothing refused: the bytes adoptions and
  # reconciliations displace are kept now, before the first write.
  for b in pendingPreserve:
    discard preserveBytes(stateDir, b)

  # --- Step 1: realise. ---
  # Closure prefixes an older realiser left without a receipt are adopted
  # and rooted to the generations that bind them, and to the hand-back hold
  # while a preserved record names them (the bytes just preserved above for
  # a relocated unit or manifest among them), before anything this switch
  # does can lead to a collection (a host upgraded from realiser v2;
  # ``migrateLegacyAptClosures``). Idempotent; nothing to do on most hosts.
  discard migrateLegacyAptClosures(handBack = @[preservedDir(stateDir)])
  # The tree goes into the store and is verified; the units' closures are
  # realised too, so no base path is touched before everything the
  # generation runs from exists. The apply lock is held throughout.
  var priorMarker: PendingMarker
  if replaying and hasPendingMarker(stateDir):
    priorMarker = readPendingMarker(stateDir)
  let previousStatic =
    if replaying and priorMarker.previousStatic.len > 0: priorMarker.previousStatic
    else: readStaticTarget()
  let (treePath, treePrefixId, treeDigest) =
    realiseStaticTree(treeFiles, custody)
  var closureLocks: seq[AptClosureLock]
  # The realiser reports what it publishes (each prefix's digest from the
  # bytes it staged, into the realisation index) and reuses an existing
  # member only when its bytes are the recorded ones (§13 decision 48): an
  # altered member is not linked into a new union, it is left for the
  # custody pass below to recover.
  let closureLog = AptRealisationLog(verifyReuse: proc (p: string): string =
    let exp = expectedDigests(custody).getOrDefault(p, "")
    if exp.len == 0:
      return (if custodyHost(custody): "it has no recorded digest" else: "")
    if verifiedDigest(custody, p, exp).verdict == cvVerified: ""
    else: "its bytes are altered")
  for p in plans:
    # A unit's closure, and a tool's (its driver would otherwise realise it
    # itself, from the network, which the apply unit does not have).
    let lockText =
      if p.r.kind == srkSystemdSystemUnit: p.r.suAptClosureLock
      elif p.r.kind == srkLinuxAddOnTool: p.r.atAptClosureLock
      else: ""
    if lockText.len > 0:
      let lock = parseAptClosureLock(lockText)
      try:
        discard realiseAptClosure(lock, AddOnSystemStoreRoot,
          AddOnAptDebCacheDir, custodyFetch, log = closureLog)
      except IOError as e:
        if "is not reused" notin e.msg: raise
      closureLocks.add(lock)
  for (path, digest) in closureLog.published:
    recordRealised(custody, path, digest)
  # The whole closure is rooted from here on, not only the tree: a
  # `repro store gc` between this step and the commit -- or after a crash,
  # before recovery -- must not collect what the switch is about to run.
  # Every prefix of each closure is held (the union and its members, all
  # indexed by the realiser); a member the collector already took is not
  # in the index and is not needed by the realised union. The committed
  # generation's root takes these over from the pending root in step 9
  # (``promotePendingRoot``): the ledger names only the static tree, so this
  # block is the closures' only route to a root (gate
  # ``e2e_addon_closure_prefixes_survive_gc``; falsifier
  # ``closure-prefixes-unrooted``).
  when not mutated("closure-prefixes-unrooted"):
    block:
      var closurePrefixes: seq[PrefixIdBytes]
      enterWritableStoreView()
      var st = openStore(StoreRoot)
      for lock in closureLocks:
        for id in aptClosurePrefixIds(lock):
          if st.lookupPrefix(id).found and id notin closurePrefixes:
            closurePrefixes.add(id)
      st.close()
      holdOnPendingRoot(closurePrefixes)

  # What the flip will make the host run, as realised: the static tree,
  # each bound closure, every store prefix a unit names (its commands, a
  # second command after `;`, an argument, a launcher started through a
  # shell, a bind source) and the program of each `exec:` health check.
  # Each was verified when it was realised (the tree against its files,
  # a closure against its lock, a staged output against the manifest's
  # pin). Step 1 records a cheap signature of each -- every entry's type,
  # mode, size, inode and modification and change times, no content read
  # (`storeSignature`) -- and the switch recomputes it before the flip
  # and again before step 7 starts anything (spec §10.2, A9): a store path
  # changed in between, by anything that got write access to the store,
  # is never flipped to or started. A store object that is missing is a
  # refusal, not a skip.
  #
  # Since §13 decision 48 that set is EVERY store object the generation
  # references, of any kind: the static tree; each closure's union and
  # members; every object a unit or drop-in names; every object any
  # resource names in its declaration or in the bytes it installs (a file's
  # content, a tmpfiles rule, an account's shell); every ``fs.systemFile``
  # source; each ``exec:`` health check's program; and the prefixes
  # bootstrap realised. Before its signature is taken, each is checked
  # against its recorded digest (``custodyPass``): altered ones are
  # recovered from trusted bytes or the switch refuses; one with no digest
  # refuses on a host under custody; one that is not a store prefix
  # refuses (default deny).
  var realisedStore: seq[tuple[path, signature: string]]
  var custodyObjects: seq[StoreObjectRef]
  block:
    proc add(path, referrer: string) =
      if path.len == 0: return
      # Falsifying builds: a kind of object left out of custody.
      when mutated("custody-skips-file-sources"):
        if classifyStoreObject(path) == sokFiles: return
      when mutated("custody-skips-closures"):
        if classifyStoreObject(path) == sokAptClosure: return
      for o in custodyObjects:
        if o.path == path: return
      custodyObjects.add(StoreObjectRef(path: path,
        kind: classifyStoreObject(path), referrer: referrer))
    add(treePath, "static-tree")
    for lock in closureLocks:
      add(aptClosurePrefixPath(AddOnSystemStoreRoot, lock), "apt-closure")
      for d in lock.debs:
        add(aptDebPrefixPath(AddOnSystemStoreRoot, d), "apt-closure")
    for p in plans:
      for o in switchStoreObjects(p.r):
        add(o, p.r.address)
      when not mutated("recheck-skips-dropin-prefixes"):
        # Any kind's declaration and installed bytes (default deny: a kind
        # whose store references nothing collects is still covered).
        let named = renderStanza(p.r).join("\n") & "\n" & p.content
        for o in referencedStoreObjects(named):
          add(o, p.r.address)
        for o in storeObjectsNamedIn(named):
          add(o, p.r.address)
      add(fileSourceObject(p.r).path, p.r.address)
      if p.r.kind == srkSystemdSystemUnit:
        if p.r.suHealthCheck.len > 0:
          let hc = parseHealthCheck(p.r.suHealthCheck)
          if hc.kind == hcExec:
            add(storeObjectFor(hc.argv[0]), p.r.address)
    for e in previous.entries:
      if e.class == lcStorePrefix and e.resource.len == 0:
        add(e.path, "generation-0")
    var missing: seq[string]
    for o in custodyObjects:
      # A missing closure member is recovered like an altered one (its
      # archive staged by the fetch unit); any other missing object is a
      # refusal, as before.
      if not dirExists(o.path) and o.kind != sokAptClosure: missing.add(o.path)
    if missing.len > 0:
      raise newAddOnError(adStoreChanged, "the generation runs from store " &
        "paths that do not exist after its realise step: " &
        missing.join(", ") & "; nothing was switched")
    let c = custodyPass(custody, custodyObjects,
      proc (o: StoreObjectRef): Recovery =
        storeRecovery(o, recoveryResources, closureLocks, custody, stateDir,
                      custodyFetch),
      mayRecover = true)
    if c.refusals.len > 0:
      raise newAddOnError(adStoreChanged, "the generation runs from store " &
        "objects that do not hold their realisation bytes: " &
        c.refusals.join("; ") & "; nothing was switched")
    for o in custodyObjects:
      realisedStore.add((path: o.path, signature: storeSignature(o.path)))

  # The confirm step's checks (§7.5): every unit's declared healthCheck.
  var healthChecks: seq[UnitHealthCheck]
  for r in composed.resources:
    if r.kind == srkSystemdSystemUnit and r.suHealthCheck.len > 0:
      healthChecks.add(UnitHealthCheck(unit: r.suName, address: r.address,
        raw: r.suHealthCheck, spec: parseHealthCheck(r.suHealthCheck)))
  result.healthChecks = healthChecks
  let declaredConfirm = if user.addOn.confirmTimeoutSec > 0:
                          user.addOn.confirmTimeoutSec
                        else: DefaultConfirmTimeoutSec
  let confirmTimeout = if opts.confirmCapSec > 0:
                         min(declaredConfirm, opts.confirmCapSec)
                       else: declaredConfirm
  let probeExe = if opts.reproExe.len > 0: opts.reproExe
                 else: SelfExeAtStart

  # The write-ahead plan, BEFORE the marker that makes it meaningful and
  # before anything on the base changes. A replay keeps the plan of the
  # switch it replays: only that one recorded the host as it was.
  var activeAtPlan: seq[string]
  if replaying:
    activeAtPlan = replayPlan.activeUnits
  else:
    for p in plans:
      if p.r.kind == srkSystemdSystemUnit and p.baseActiveState == "active":
        activeAtPlan.add(p.r.suName)
    for u in opts.assumeActive:
      if u notin activeAtPlan: activeAtPlan.add(u)
    var saved: seq[SavedPlan]
    var targetByAddress = initTable[string, PlannedTarget]()
    for t in targets: targetByAddress[t.address] = t
    for p in plans:
      let dec = if p.r.address in decisions: decisions[p.r.address]
                else: CollisionDecision(verdict: cvNoOp,
                                        observation: p.observation)
      saved.add(toSaved(p, dec, targetByAddress.getOrDefault(p.r.address)))
    # The own profile the switch begins from, beside the user one: a
    # revert needs both, and a generation applied before generations kept
    # their own copies (`generationProfiles`) has nowhere else to get it
    # once this switch has replaced the stored profiles.
    let previousOwnText = if fileExists(ownProfilePath(stateDir)):
                            readFile(ownProfilePath(stateDir)) else: ""
    writePendingPlan(stateDir, PendingPlan(targetOwnText: ownText,
      targetUserText: targetUserText, fromUserText: previousUserText,
      fromOwnText: previousOwnText,
      fromLedgerText: previous.render(), reconcileDrift: reconcileDrift,
      adopt: adoptAddresses, activeUnits: activeAtPlan, plans: saved,
      storedTarget: storedTarget, storedTargetRecorded: true))
  var secretsFailure = ""
  var heldAtRevert: seq[string]   # spec §10.1: what a revert keeps on hold
  if not opts.planOnly:
    writeSecretsSource(stateDir, secretsSource)
  var marker = PendingMarker(fromGeneration: committedPrevious,
    newStatic: treePath, previousStatic: previousStatic, step: ssRealise,
    status: "in-progress", purpose: purpose, revertOf: opts.revertOf,
    revertReason: opts.revertReason)
  if replaying:
    # What the interrupted switch stopped and disabled stays on record
    # until this one finishes.
    marker.stopped = priorMarker.stopped
    marker.disabled = priorMarker.disabled
    # A replayed revert stays a revert, with what it reverts, so a crash
    # during the replay is recovered as one too.
    if priorMarker.purpose.len > 0: marker.purpose = priorMarker.purpose
    if marker.revertOf.len == 0: marker.revertOf = priorMarker.revertOf
    if marker.revertReason.len == 0:
      marker.revertReason = priorMarker.revertReason
  writePendingMarker(stateDir, marker)
  seamPause(stateDir, seamPrefix & "step-1")

  # The drivers' materialisation policy: a link target for every
  # link-form object, and the switch orchestrates every transition.
  var linkTargets = initTable[string, string]()
  for p in plans:
    if p.form == "link":
      linkTargets[p.r.address] = staticLinkTargetFor(p.targetPath)
  let policy: AddOnDispatchPolicy = proc(op: PrivilegedOperation):
      AddOnMaterialisation {.gcsafe.} =
    {.cast(gcsafe).}:
      AddOnMaterialisation(linkTarget: linkTargets.getOrDefault(op.address),
                           orchestrated: true)

  let transitions = result.transitions
  var stepTransitions = transitions
    ## What steps 2 and 7 run: the plan's transitions, or -- when step 2's
    ## re-check keeps removed units in place -- those planned again
    ## without them.
  var keptAsDrift: seq[string]
    ## The removed units step 2's re-check kept in place, in the order the
    ## plan listed them: the apply's printed transition list marks them
    ## (``executedTransitions``).
  # The install links of each removed unit, decided in step 2 together
  # with the unit's own destroy (``removalDisables``).
  var removedUnitEntries: seq[tuple[unit, address: string;
                                    entries: seq[LedgerEntry]]]
  for r in removedUnits:
    var es: seq[LedgerEntry]
    for e in previous.entries:
      if e.resource == r.address: es.add(e)
    removedUnitEntries.add((unit: r.suName, address: r.address, entries: es))
  var changedSysctl: seq[string]
  for p in plans:
    if p.r.kind == srkLinuxSysctl and p.verdict != $cvNoOp and not p.skipInfra:
      changedSysctl.add(p.targetPath)
  for e in removedSysctl:
    changedSysctl.add(e.path)
  var anyUnitChange = needReloadAfterRemoval or removedUnits.len > 0
  for p in plans:
    if p.r.kind in {srkSystemdSystemUnit, srkSystemdSystemDropIn} and
        p.verdict != $cvNoOp:
      anyUnitChange = true
  # The carried-state cross-check runs in every switch (§11.1, §13
  # decision 59), not only one that writes a unit file: a switch that
  # changes only a file a confined unit ``depends_on``, or its credentials,
  # restarts that unit at step 7 (§7.3), on whatever systemd last loaded --
  # an operator's reload after a host generator changed its output
  # included. So wherever the check has units to judge, the switch holds
  # them, reloads, and judges them before step 7, whatever else it changes
  # (A13 review round 7, finding 1; ``liveCheckAtStep6``).
  let step6 = liveCheckAtStep6(anyUnitChange, replaying, opts.recordOnly,
                               preWriteLiveUnits)
  let sysctlKeys = block:
    var keys: seq[string]
    for p in plans:
      if p.r.kind == srkLinuxSysctl: keys.add(p.r.sysctlKey)
    keys

  # The ledger of this generation is built after the writes, inside the
  # commit; these are filled by the after-hook and read back below.
  var newLedger = Ledger()
  var hookRestored: seq[string]
  var hookKept = initHashSet[string]()   # addresses left in place at write time
  var hookRefused = initHashSet[string]()
    # Addresses whose operation the write-time re-check refused: nothing of
    # theirs was written, so the ledger must not claim what is there.
  var hookKeptDrift: seq[string]
  # The objects each destroy removes, for the destroy's re-observation.
  var destroyEntries = initTable[string, seq[LedgerEntry]]()
  for r in destroy:
    for e in previous.entries:
      if e.resource == r.address:
        destroyEntries.mgetOrPut(r.address, @[]).add(e)
  let destroyCheck: DestroyCheck = proc(op: PrivilegedOperation): string =
    {.cast(gcsafe).}:
      if op.address notin destroyEntries: return ""
      var why: seq[string]
      for e in destroyEntries[op.address]:
        if e.class in {lcEtcFile, lcUnit, lcDropIn, lcInstallLink}:
          let d = changedSincePlan(e, planDrift.getOrDefault(entryKeyOf(e)))
          if d.len > 0: why.add(e.path & ": " & d)
      if op.kind == pokLinuxDpkgDiversion:
        # dpkg cannot move the package's copy back over a file that is
        # still there: a diversion whose file was just kept stays with it.
        for a in hookKept:
          for e in destroyEntries.getOrDefault(a):
            if e.path == op.ddPath and e.class in FileClasses:
              why.add(op.ddPath & ": its diversion is kept with the drifted file")
      if why.len == 0: return ""
      hookKept.incl(op.address)
      for w in why:
        hookKeptDrift.add(w & " (changed after the plan; left in place, " &
          "--reconcile-drift removes it)")
      why.join("; ")
  var hookSysctl: seq[tuple[key, value: string]]
  var hookGeneration = ""
  var hookRecordedClean = false
    ## A record-only replay got through steps 4-6 with no problem of its
    ## own: its only "failure" is the not-committed note it adds itself.
  var paused: seq[string]      # triggers step 2 stopped; step 7 restarts
  var notRunning: seq[string]  # stop-start units that ended before step 2
  var hookConfirm: ConfirmOutcome
  var hookHealthFailed = false
  # A8, spec §7.5: may a failure after the flip revert to the generation
  # `current` names? Not when the signed floor is above the sequence that
  # generation was applied from. Only a fresh apply is bounded: a revert,
  # replay or rollback is already the way back.
  let floorBlocksRevert = opts.rollbackFloor > 0'u64 and
    purpose == "apply" and not replaying and
    generationAgentSequence(stateDir, committedPrevious) < opts.rollbackFloor
  var hookFailedAtFloor: seq[string]

  proc beforeSet(planId: string) {.gcsafe.} =
    ## Steps 2 and 3: pre-stop, then flip. A refusal here (an exclusive
    ## unit that will not die) leaves the host in the old generation.
    {.cast(gcsafe).}:
      when TestPauseSeam:
        testSeamPause()
      marker.planId = planId
      writePendingMarker(stateDir, marker)
      for u in runningManagedUnits(previous):
        invocationsBefore[u.unit] = u.invocationId
      # Each unit is on record BEFORE it is stopped, paused or disabled,
      # so a crash or a refusal in the middle of step 2 loses none of them.
      let onStop: PreStopObserver = proc(u: string) =
        if u.startsWith("disable:"):
          let name = u["disable:".len .. ^1]
          if name notin marker.disabled: marker.disabled.add(name)
        else:
          let name = if u.startsWith("trigger:"): u["trigger:".len .. ^1]
                     else: u
          if name notin marker.stopped: marker.stopped.add(name)
        writePendingMarker(stateDir, marker)
      # Step 2 removes the install links of the units this generation
      # removes. Each unit is observed again first (spec §4.2 rule 1): one
      # whose file or any link changed since the plan is left in place
      # whole -- its links with it -- as drift, and its destroy is kept the
      # same way by the write-time check; the rest have exactly their
      # ledgered links removed, each only while it still points where the
      # ledger says.
      var disableOnRemoval: seq[tuple[unit: string;
                                      links: seq[tuple[path, target: string]]]]
      var linkOwner = initTable[string, string]()
      for u in removedUnitEntries:
        var why: seq[string]
        when not mutated("pause-before-write-no-recheck"):
          for e in u.entries:
            if e.class in {lcUnit, lcInstallLink}:
              let d = changedSincePlan(e, planDrift.getOrDefault(entryKeyOf(e)))
              if d.len > 0: why.add(e.path & ": " & d)
        if why.len > 0:
          hookKept.incl(u.address)
          for w in why:
            hookKeptDrift.add(w & " (changed after the plan; left in " &
              "place with its unit, --reconcile-drift removes it)")
          continue
        var links: seq[tuple[path, target: string]]
        for e in u.entries:
          if e.class == lcInstallLink:
            when mutated("pause-before-write-no-recheck"):
              links.add((path: e.path, target: ""))
            else:
              links.add((path: e.path, target: e.linkTarget))
            linkOwner[e.path] = u.address
        disableOnRemoval.add((unit: u.unit, links: links))
      var keptUnits = initHashSet[string]()
      for u in removedUnitEntries:
        if u.address in hookKept:
          keptUnits.incl(u.unit)
          keptAsDrift.add(u.unit)
      if keptUnits.len > 0:
        when not mutated("kept-units-still-stopped"):
          var without: seq[UnitFacts]
          for f in unpropagatedFacts:
            if not (f.removed and f.unit in keptUnits): without.add(f)
          propagateDependencyChanges(without, unitDeps)
          stepTransitions = planTransitions(without)
          # Fewer stops than the plan: no refusal can be new here.
          discard planUpholds(stepTransitions, without)
      let pre = runPreStop(stepTransitions, disableOnRemoval, onStop)
      for kept in pre.keptLinks:
        # Changed in the instant between the re-check and the unlink.
        hookKept.incl(linkOwner.getOrDefault(kept))
        hookKeptDrift.add(kept & ": no longer the add-on's link when it " &
          "came to be removed; left in place")
      paused = pre.paused
      notRunning = pre.notRunning
      marker.step = ssPreStop
      writePendingMarker(stateDir, marker)
      seamPause(stateDir, seamPrefix & "step-2")
      # Nothing the generation runs from changed since step 1 (§10.2).
      when not mutated("flip-skips-store-recheck"):
        let changed = storeChangedSince(realisedStore)
        if changed.len > 0:
          raise newAddOnError(adStoreChanged, "the store changed between " &
            "the switch's realise step and its flip: " & changed.join(", ") &
            " no longer hold" & (if changed.len == 1: "s" else: "") &
            " what was realised; nothing was switched")
      # The flip is durable (its directory is synced) before the marker
      # says it happened; recovery never trusts the step anyway.
      flipStatic(treePath)
      marker.step = ssFlip
      writePendingMarker(stateDir, marker)
      seamPause(stateDir, seamPrefix & "step-3")

  proc afterSet(generationId: string; clean: bool): seq[string] {.gcsafe.} =
    ## Steps 4 and 5 were the drivers'; now 6 (fragment tools), 7 (start)
    ## and 8 (confirm), then the ledger. A problem is a diagnostic that
    ## withholds the commit.
    {.cast(gcsafe).}:
      var problems: seq[string]
      var reloadedAt = 0.0
      var startHolds: seq[string]   # spec §10.1: kept until the check passes
      var createdPending: seq[tuple[path, unit: string]]  # §13 decision 57
      var liveUnits: seq[string]    # §11.1: the carried-state cross-check's
        ## CLOCK_MONOTONIC seconds just after step 6's daemon-reload; 0
        ## when there was none.
      hookGeneration = generationId
      # §13 decision 72: this engine keeps the record of floored units'
      # directories, and says so in every generation it sets, so a later
      # migration can tell its generations from an older engine's.
      when not mutated("migration-ignores-engine"):
        try:
          createDir(generationDir(stateDir, generationId))
          writeFile(recordKeptMarker(stateDir, generationId), "")
        except IOError, OSError:
          problems.add("cannot mark generation " & generationId & " as written " &
                       "by an engine that keeps the record of floored units' " &
                       "directories (§13 decision 72)")
      # Steps 4 and 5 are the drivers' writes, in the profile's apply
      # order (links and copies interleave); both are complete here.
      marker.attempt = generationId
      marker.step = ssReconcileLinks
      writePendingMarker(stateDir, marker)
      seamPause(stateDir, seamPrefix & "step-4")
      marker.step = ssCopies
      writePendingMarker(stateDir, marker)
      seamPause(stateDir, seamPrefix & "step-5")
      # --- Step 6: the fragment tools. The sysusers and tmpfiles tools
      # ran per changed fragment inside their drivers; what is left is
      # the daemon reload, sysctl through the host's own service, and
      # the kernel values a removed sysctl resource leaves behind.
      try:
        if step6.reload:
          # The start holds go in before the reload: from it until the
          # effective-unit check passes, no floored unit can start (a
          # socket, a timer, D-Bus or a Wants= would otherwise start it on
          # definitions nothing has checked yet; spec §10.1, round 4).
          if not opts.recordOnly:
            liveUnits =
              when mutated("live-units-chosen-after-writes"):
                liveReachUnitsFor(opts, composed.resources)
              else: step6.judged
            startHolds = writeStartHolds(composed.resources, liveUnits)
          daemonReload()
          # From here on every start runs the generation's definitions:
          # step 7 accepts an exclusive instance started after this point
          # (an upholder's restart) as the new one (``runStart``).
          reloadedAt = monotonicSeconds()
        if replaying:
          # The interrupted switch may have written a sysusers or tmpfiles
          # fragment and died before its tool ran; the replay finds the
          # fragment already carrying the planned bytes, so its driver has
          # nothing to write and would not run the tool. Both tools are
          # idempotent: they run again for every such fragment.
          for p in plans:
            if p.targetPath.len == 0 or not fileExists(p.targetPath): continue
            case p.r.kind
            of srkLinuxSysusersEntry: rerunFragmentTool(SysusersCandidates, p.targetPath)
            of srkLinuxTmpfilesRule:
              rerunFragmentTool(TmpfilesCandidates, p.targetPath, "--create")
            else: discard
        for e in removedSysctl:
          if readLiveSysctl(e.path) == e.value:
            restoreSysctlValue(e.path, e.replaced)
        applySysctlFragments(changedSysctl)
        for k in sysctlKeys:
          hookSysctl.add((key: k, value: observeSysctlInHostNamespaces(k)))
      except CatchableError as ex:
        problems.add("step 6 (fragment tools): " & ex.msg)
      # --- Step 6, secrets (milestone A7; ``addon_secrets``): the
      # generation's declared secrets are materialised into the ramfs
      # before step 7 starts the units that load them, and what it no
      # longer declares is removed. A revert that cannot materialise them
      # still goes back, and the failure is recorded in the generation's
      # apply log (and reported by the re-assert unit as degraded); any
      # other switch reverts.
      if not opts.recordOnly:
        try:
          discard materialiseFromEnvelope(secretsLayout, secretDecls,
            secretsSource, seamStateDir = stateDir)
        except CatchableError as ex:
          # A revert, and a recovery's replay, finish whatever the secrets
          # do: going back to the old generation (or, for a replay, undoing
          # a switch the crash interrupted) over a secret that cannot be
          # materialised now would trade a recoverable degraded state for
          # a mixture. The failure is recorded in the generation's apply log,
          # the re-assert unit reports it as degraded naming the cause, and
          # the next re-assert or apply materialises the secrets again.
          let finishAnyway =
            when mutated("replay-reverts-on-secrets"): purpose == "revert"
            else: purpose == "revert" or replaying
          if finishAnyway:
            secretsFailure = "step 6 (secrets): " & ex.msg
            stderr.writeLine("repro-addon: " & secretsFailure)
          else:
            problems.add("step 6 (secrets): " & ex.msg)
      marker.step = ssFragmentTools
      writePendingMarker(stateDir, marker)
      seamPause(stateDir, seamPrefix & "step-6")
      proc restorePreservedObjects() =
        ## Objects a removed resource adopted, replaced or reconciled go
        ## back to what they were (the rest were destroyed by the infra
        ## apply); a restored unit file is reloaded and its base state put
        ## back. Before step 7 (spec §7.2): a unit of this generation may
        ## read a restored object -- a rollback to a generation whose unit
        ## reads a file the newer one reconciled -- so it starts on it.
        var needReload = needReloadAfterRemoval
        var unitsToRestore: seq[LedgerEntry]
        for e in restore:
          # Changed meanwhile: left, as drift. Not a change: the flip of
          # step 3 moved the static tree from under a link-form object the
          # new generation no longer carries, so the add-on's own link now
          # dangles; that is the removal in progress, and the restore (or
          # the deletion) replaces the link.
          if replaying and alreadyRestored(e):
            hookRestored.add(e.path)
            continue
          let d = changedSincePlan(e, planDrift.getOrDefault(entryKeyOf(e)))
          if d.len > 0:
            hookKept.incl(e.resource)
            hookKeptDrift.add(e.path & ": " & d & " (changed after the " &
              "plan; left in place, --reconcile-drift removes it)")
            continue
          try:
            if restorePreserved(e):
              hookRestored.add(e.path)
            elif e.class == lcUnit and e.collision == "replace":
              # Nothing to put back: the package's file is below /usr; the
              # shadowing copy goes away.
              if removeOwnedUnitFile(e):
                hookRestored.add(e.path)
            if e.class in {lcUnit, lcDropIn}:
              needReload = true
              if e.class == lcUnit:
                unitsToRestore.add(e)
                # The install links the add-on made for it go too (a
                # package's own link was never ledgered, so it stays).
                for li in previous.entries:
                  if li.resource == e.resource and li.class == lcInstallLink:
                    discard removeLeafNoFollow(li.path)
          except CatchableError as ex:
            problems.add("restoring " & e.path & ": " & ex.msg)
        if needReload:
          try: daemonReload()
          except CatchableError as ex:
            problems.add(ex.msg)
        for e in unitsToRestore:
          try: restoreUnitState(e, driver,
                                othersChanged = e.unit in loudHandBack)
          except CatchableError as ex:
            problems.add(ex.msg)
        # Directories the removed resources had created.
        removeEmptyDirs(removedEntries)
      when not mutated("restore-after-start"):
        restorePreservedObjects()
      seamPause(stateDir, seamPrefix & "step-6-restore")
      if opts.recordOnly:
        # Only the record of what the failed switch wrote is wanted: no
        # start, no confirm, no commit.
        hookRecordedClean = clean and problems.len == 0
        problems.add("replayed to record what the failed switch wrote; " &
          "not committed")
      # --- Step 7: start. Only after a clean step 4-6: a half-written
      # generation is not started, and neither is one whose store objects
      # changed since step 1 (§10.2): the flip's re-check left the window
      # of steps 4-6, which this one closes up to the start itself.
      when not mutated("flip-skips-store-recheck"):
        if not opts.recordOnly:
          let changedNow = storeChangedSince(realisedStore)
          if changedNow.len > 0:
            problems.add($adStoreChanged & ": the store changed after the " &
              "flip, before step 7: " & changedNow.join(", ") & " no " &
              "longer hold what was realised; nothing was started")
      # Every floored unit as systemd reads it now, after step 6's
      # daemon-reload (spec §10.1, A9 review round 3): a unit that does
      # not hold the floor it was rendered under -- by its own lines, a
      # drop-in or a default the parse-time checks did not predict -- is
      # never started, and the switch reverts.
      # The window the start holds close: reloaded, not yet checked (the
      # gate e2e_addon_floor_held_until_checked pauses here).
      seamPause(stateDir, seamPrefix & "floor-check")
      when not mutated("effective-check-skipped") and
          not mutated("floor-unchecked"):
        if not opts.recordOnly and clean and problems.len == 0:
          var ownedObjects: seq[string]
          block:
            let expected = expectedDigests(custody)
            for o in custodyObjects:
              if expected.getOrDefault(o.path, "").len > 0:
                ownedObjects.add(o.path)
          # The files the generation adopts, with the digest its ledger
          # records (§13 decision 50, amended): this switch's adoption
          # (the preserved copy is named by its sha256), or the previous
          # generation's ledger entry for an object it already owns.
          var adoptedFiles = initTable[string, string]()
          for p in plans:
            if p.r.kind != srkFsSystemFile or p.r.sfCollision != "adopt": continue
            var digest = ""
            if p.collision == "adopt" and p.preserved.len > 0:
              digest = extractFilename(p.preserved)
            else:
              for e in previous.entries:
                if e.class == lcEtcFile and e.path == p.targetPath: digest = e.sha256
            if digest.len == 64:
              adoptedFiles[normalisedPath(p.targetPath)] = digest
          # The directories the ledger records as the add-on's (§13 decision
          # 67): created for the profile, so for its units.
          var ledgerDirs = initHashSet[string]()
          for le in previous.entries:
            if le.class == lcDir: ledgerDirs.incl(normalisedPath(le.path))
          var recreated: seq[tuple[path, unit: string; v: SystemdView]]
          let notHeld = effectiveFloorCheck(composed.resources, ownedObjects,
                                            adoptedFiles, readCreatedDirs(stateDir),
                                            addr createdPending, ledgerDirs,
                                            addr recreated,
            # §13 decision 71: each directory systemd made again for its unit
            # outside a switch is recorded under its new identity and the
            # acceptance written to the generation's audit log, both before
            # it counts; either failing refuses it.
            proc (path, unit: string; v: SystemdView): bool =
              try:
                appendAuditRecord(applyLogPath(stateDir, generationId), AuditRecord(
                  timestamp: getTime().toUnix(), operationKind: "addon.floor",
                  resourceAddress: "directory:" & path,
                  outcome: "recreated-accepted",
                  diagnostic: unit & ": made again by systemd for invocation " &
                    v.invocationId & " (recorded: another), born " & $v.btime &
                    " ns, run started " & $v.invocationStart & " ns" &
                    (if v.stopped: ", ended " & $v.lastStop & " ns" else: ", running") &
                    " (§13 decision 71; §10.1 round 12, \"A directory " &
                    "made again outside a switch\", \"A stopped unit's " &
                    "directory\")",
                  recordClass: AuditClassLiveState))
                acceptRecreated(stateDir, path, unit, v.invocationId)
                true
              except CatchableError: false)
          # The carried-state reach, cross-checked against the units as
          # systemd loaded them (A13 review round 5, finding 1): wherever
          # carried state is on this host, a unit the static analysis took
          # as confined must be confined as systemd reads it too, or nothing
          # starts (a problem stops step 7, and the switch reverts).
          let reachLive = liveReachProblemsFor(opts, liveUnits,
                                               composed.resources, stateDir)
          if reachLive.len > 0:
            problems.add(reachLive.join("; ") & "; nothing was started")
          # A revert does not refuse on its own floor check (spec §10.1, A9
          # review round 12): it goes back to the generation the failed
          # switch left, whose units the switch it reverts never started.
          # Each unit the check refuses keeps its start hold and is not
          # started, so nothing hands it the tree or listener refused; the
          # revert commits with the refusals recorded, and the host is not
          # left pending. The next switch checks the unit again.
          var floorRefusals = notHeld
          let revertHolds =
            when mutated("revert-refuses-on-floor"): false
            else: (purpose == "revert" or (replaying and opts.replayOf == "revert")) and
                  reachLive.len == 0 and notHeld.len > 0
          if revertHolds:
            var genUnits = initHashSet[string]()
            for r in composed.resources:
              if r.kind == srkSystemdSystemUnit and r.suCollision != "dropIn":
                genUnits.incl(r.suName)
            let held = revertHeldUnits(notHeld, genUnits,
                                       flooredUnitNames(composed.resources))
            proc isHeld(u: string): bool =
              u in held or floorTemplateOf(u) in held
            var kept: seq[Transition]
            for t in stepTransitions:
              if t.verb in {tvStart, tvRestart, tvStopStart, tvReload} and isHeld(t.unit):
                continue
              kept.add(t)
            stepTransitions = kept
            var keepActive = initHashSet[string]()
            for u in assumeActive:
              if not isHeld(u): keepActive.incl(u)
            assumeActive = keepActive
            discard clearStaleStartHolds()
            removeStartHolds(startHolds)
            startHolds.setLen(0)
            # §13 decision 126: persistent, so a reboot does not start a
            # held unit either; only a switch whose check passes removes it.
            let holdDir =
              when mutated("revert-hold-runtime-only"): RuntimeUnitDir
              else: PersistentUnitDir
            try: discard writeHolds(held, RevertHoldName, RevertHoldText, holdDir)
            except IOError, OSError:
              problems.add("the revert's hold could not be written: " &
                           getCurrentExceptionMsg())
            try: daemonReload()
            except CatchableError as ex: problems.add(ex.msg)
            heldAtRevert = notHeld
            stderr.writeLine("repro-addon: the revert keeps " & held.join(", ") &
              " on hold, not started: its floor check refused them:\n  " &
              notHeld.join("\n  "))
            floorRefusals = @[]
          if floorRefusals.len > 0:
            # One refusal per line: each ends with its rule tag, and the
            # gate reads them line by line (A9 review round 9, finding 3).
            problems.add($adFloorNotEffective & ":\n  " & notHeld.join("\n  ") &
              "\n  nothing was started")
          if revertHolds:
            discard
          elif reachLive.len > 0 or notHeld.len > 0:
            # Refused: the holds stay until the revert's own switch has
            # checked its generation and cleared them (A13 review round 6,
            # finding 6), so no socket, timer or dependency starts a unit
            # systemd loaded unconfined in between.
            discard
          else:
            # Checked: the holds go -- this switch's, and any an earlier
            # switch left (a refused check before a revert to a generation
            # with no floored unit) -- and step 7 starts on these
            # definitions.
            let stale = clearStaleStartHolds()
            removeStartHolds(startHolds)
            # A revert's holds go once a switch's check passes (§13
            # decision 126), wherever a build wrote them.
            var revertStale: seq[string]
            for d in [PersistentUnitDir, RuntimeUnitDir]:
              try: revertStale.add(clearStaleHolds(RevertHoldName, d))
              except OSError: discard
            if startHolds.len > 0 or stale.len > 0 or revertStale.len > 0:
              try: daemonReload()
              except CatchableError as ex: problems.add(ex.msg)
            startHolds.setLen(0)
      if startHolds.len > 0 and clean and problems.len == 0:
        # The check did not run (a record-only replay, a falsifying build):
        # the holds must not outlive the switch that wrote them.
        removeStartHolds(startHolds)
        startHolds.setLen(0)
        try: daemonReload()
        except CatchableError as ex: problems.add(ex.msg)
      if clean and problems.len == 0:
        try:
          # What a floored unit's own start created is that unit's (§13
          # decisions 57 and 68), recorded right after its start and before
          # the next unit's. A queued start (--no-block, the boot-time
          # recovery of a generation an earlier switch already started)
          # records nothing. A record that cannot be written leaves the
          # directory unrecorded, so the next switch refuses it: fail closed.
          let recordAfter =
            if opts.nonBlockingStarts or createdPending.len == 0:
              (proc (u: string) {.closure.})(nil)
            else:
              proc (u: string) =
                try: recordCreatedDirs(stateDir, u, createdPending,
                                       invocation = unitInvocation(u).id)
                except IOError, OSError: discard
          runStart(stepTransitions, paused, notRunning,
                   noBlock = opts.nonBlockingStarts, reloadedAt = reloadedAt,
                   afterStart = recordAfter)
          if not opts.nonBlockingStarts and createdPending.len > 0:
            try: recordStartedSince(stateDir, createdPending, unitInvocation)
            except IOError, OSError: discard
          # A replay or a revert plans the units the interrupted switch had
          # running as running, but `try-restart` leaves a unit the crash
          # (or step 2) stopped stopped: start every such unit of this
          # generation that is down -- never one whose control group is
          # still populated (an exclusive instance that would not die).
          if assumeActive.len > 0:
            for r in composed.resources:
              if r.kind == srkSystemdSystemUnit and r.suName in assumeActive and
                  not unitIsActive(r.suName) and
                  unitAliveness(r.suName) == uaEmpty:
                startUnit(r.suName, opts.nonBlockingStarts)
        except CatchableError as ex:
          problems.add("step 7 (start): " & ex.msg)
      marker.step = ssStart
      writePendingMarker(stateDir, marker)
      seamPause(stateDir, seamPrefix & "step-7")
      # --- Step 8: confirm (§7.5). Every step above reported no problem,
      # and every declared health check passed within confirmTimeout,
      # counted from the end of step 7. A failure withholds the commit,
      # and the switch reverts below.
      if clean and problems.len == 0 and healthChecks.len > 0:
        hookConfirm = confirm(healthChecks, confirmTimeout,
                              hostNamespaceProbe(probeExe))
        if not hookConfirm.passed:
          hookHealthFailed = true
          problems.add("step 8 (confirm): " &
            failureSummary(hookConfirm, confirmTimeout))
      marker.step = ssConfirm
      writePendingMarker(stateDir, marker)
      when mutated("restore-after-start"):
        # FALSIFYING MUTATION: the order before the A13 review -- objects
        # a removed resource preserved are put back after the start.
        restorePreservedObjects()
      # The new ledger: what is on the host now, whether or not the
      # generation commits (an uncommitted attempt's objects are still the
      # add-on's to remove).
      var l = Ledger(generation: generationId)
      var seen = initHashSet[string]()
      proc put(e: LedgerEntry) =
        let k = $e.class & " " & e.path
        if k in seen: return
        seen.incl(k)
        l.entries.add(e)
      var declaredAccounts = initHashSet[string]()
      for p in plans:
        if p.accountKey.len > 0 and p.r.kind in {srkPasswdUser, srkPasswdGroup}:
          declaredAccounts.incl(p.accountKey)
      # An object a bootstrap entry of this switch names again (the keys an
      # ``evidence-enrol --rekey`` replaced, decision 52) takes the new
      # entry; the previous one is not carried.
      var restated = initHashSet[string]()
      for e in opts.bootstrapEntries: restated.incl($e.class & " " & e.path)
      for e in previous.entries:
        if e.resource.len > 0 or e.class == lcStaticLink: continue
        if ($e.class & " " & e.path) in restated: continue
        if e.class == lcAccount and e.path in declaredAccounts:
          continue      # a passwd resource holds it now (its entry below)
        if e.class == lcUnitState and e.unitState.len == 0 and
            readUnitProvision(e.unit).activeState != "active":
          continue      # the instance left running has ended: forgotten
        put(e)
      for e in opts.bootstrapEntries: put(e)
      for e in forgottenEntries: put(e)
      # The static tree: its link and its prefix, rebuilt every generation.
      put(LedgerEntry(class: lcStaticLink, path: StaticLinkPath,
        linkTarget: readStaticTarget(), resource: "static-tree",
        mode: "0777", owner: "0:0"))
      put(LedgerEntry(class: lcStorePrefix, path: treePath,
        sha256: prefixIdHex(treePrefixId), value: treeDigest,
        resource: "static-tree"))
      # Every other store object the generation references, with the
      # digest it is expected to hold (§13 decision 48): the record store
      # verification and the next switch check it against, attested with
      # the ledger. Rebuilt every generation, never carried forward.
      block:
        let expected = expectedDigests(custody)
        for o in custodyObjects:
          put(LedgerEntry(class: lcStorePrefix, path: o.path,
            value: expected.getOrDefault(o.path, ""),
            resource: "store-object"))
      for p in plans:
        if p.r.address in hookRefused:
          # The write-time re-check refused this resource's operation: what
          # is at its path now is not the add-on's doing (a package that
          # installed a file there since the plan, say), so it is not
          # claimed. What the previous ledger held for it stays.
          for e in previous.entries:
            if e.resource == p.r.address: put(e)
          continue
        for e in entriesFor(p, previous.entries, driver):
          var e = e
          if p.keepLedgerSha.len > 0 and e.path == p.targetPath and
              e.class in {lcEtcFile, lcUnit, lcDropIn}:
            e.sha256 = p.keepLedgerSha     # still drift (``revertHeld``)
          put(e)
      # A removed resource whose objects are still there stays in the
      # ledger, so nothing it created is orphaned and the add-on still
      # accounts for it: an object left in place as drift (whatever its
      # content now), and a destroy that failed -- recognised by the
      # object still carrying the ledger's digest. An object at the path
      # with other content is not the add-on's (the package's copy a
      # removed diversion put back) and is not claimed.
      for e in keptEntries:
        let stillThere = case e.class
          of lcEtcFile, lcUnit, lcDropIn: fileExists(e.path) or symlinkExists(e.path)
          of lcInstallLink: symlinkExists(e.path)
          of lcDir: dirExists(e.path)
          of lcSysctl: true
          else: false
        if stillThere: put(e)
      for e in removedEntries:
        if entryKeyOf(e) in handedBack:
          continue                 # the package's now (``handback.nim``)
        if e.resource in hookKept:
          # Left in place at write time: still the add-on's, kept in the
          # ledger like drift found at plan time.
          put(e)
          continue
        if e.path in hookRestored and clean and problems.len == 0:
          continue
        if e.path in hookRestored:
          # Restored, but the switch is not committing: the object stays
          # in the ledger (its preserved bytes named), so the revert that
          # follows recognises them as the failed switch's restore and
          # writes its own generation's bytes over them
          # (``revertOverwritesRestored``).
          put(e)
          continue
        let stillOurs = case e.class
          of lcEtcFile, lcUnit, lcDropIn, lcInstallLink: observeDrift(e).len == 0
          of lcDir: dirExists(e.path)
          of lcDiversion:
            # dpkg's record, not a file: a removal that failed leaves it.
            fileExists(DpkgDiversionsDb) and
              readDpkgDiversion(readFile(DpkgDiversionsDb), e.path).present
          of lcSysctl:
            # The key still carries the add-on's value: the restore failed.
            readLiveSysctl(e.path) == e.value and e.replaced != e.value
          else: false
        if stillOurs: put(e)
      when mutated("switch-fails-before-ledger"):
        const Trigger = "/var/tmp/repro-addon-fail-before-ledger"
        if fileExists(Trigger):
          removeFile(Trigger)
          raise newException(AddonApplyError, "injected failure before " &
            "the ledger was written (" & Trigger & ")")
      newLedger = l
      if generationId.len > 0 and generationId != previous.generation:
        createDir(parentDir(generationLedgerPath(stateDir, generationId)))
        writeLedger(generationLedgerPath(stateDir, generationId), l)
      writeLedger(ledgerCopyPath(stateDir), l)
      writeFileAtomic(ownProfilePath(stateDir), ownText, 0o600)
      # A resource whose removal was left in place at write time stays in
      # the stored profile, like one left as drift at plan time.
      var storedNow = stored
      for r in previousUser.resources:
        if r.address in hookKept and r.address notin wanted and
            r.address notin keptAddresses:
          storedNow.resources.add(r)
      writeFileAtomic(userProfilePath(stateDir), renderProfileText(storedNow),
                      0o600)
      # The generation's own copies of what it applied: `repro system
      # rollback` re-applies a retained generation from them (§7.5).
      if generationId.len > 0:
        let gd = generationDir(stateDir, generationId)
        createDir(gd)
        writeFileAtomic(gd / AddonOwnProfileName, ownText, 0o600)
        writeFileAtomic(gd / AddonUserProfileName,
                        renderProfileText(storedNow), 0o600)
        # The base it was applied on (spec §7.4).
        writeFileAtomic(gd / BaseIdentityFileName, baseIdentityText, 0o644)
        # The manifest sequence (A8's floor, §7.5) and the deploy-agent
        # record it belongs to (§7.4). One value: `runAddonApply` refuses
        # options whose two copies differ.
        if opts.agentSequence > 0'u64:
          writeFileAtomic(gd / AgentSequenceFileName,
                          $opts.agentSequence & "\n", 0o644)
        if opts.agentRecord.present:
          writeFileAtomic(gd / AgentRecordName, render(opts.agentRecord),
                          0o644)
      seamPause(stateDir, seamPrefix & "step-8")
      # A8: below the rollback floor the new generation stays, and what
      # failed is reported (`failed-at-floor`) instead of withholding the
      # commit -- which would revert to the generation the floor forbids.
      when not mutated("floor-ignored"):
        if problems.len > 0 and floorBlocksRevert:
          hookFailedAtFloor = problems
          problems = @[]
      problems

  var infraError = ""
  try:
    result.infra = runInfraApply(composedText, ApplyOptions(
      stateDir: stateDir, hostIdentity: opts.hostIdentity,
      carriedStateChecked: true,
      noPreview: true, elevationMode: emBroker,
      buildActions: opts.buildActions,
      buildActionDispatcher: opts.buildActionDispatcher,
      extraDestroyResources: destroy, destroysFirst: true,
      preWriteGuard: seamedGuard(stateDir, seamPrefix,
        (when mutated("pause-before-write-no-recheck"):
           # Falsifying build of the write-time re-check gate: every
           # operation is let through unchecked.
           PreWriteGuard(proc(op: PrivilegedOperation): string {.gcsafe.} = "")
         else: recordingRefusals(
           accountRecheck(makePreWriteGuard(newDriver, targets,
                                            destroyCheck),
                          accountChecks, reconcileDrift),
           hookRefused))),
      addOnDispatch: policy,
      phases: ApplyPhaseHooks(beforePrivilegedSet: beforeSet,
                              afterPrivilegedSet: afterSet,
                              commitOnlyWhenClean: true,
                              commitPoint: seamCommitPoint(stateDir,
                                                           seamPrefix))))
    if result.infra.errorCount > 0 or result.infra.driftCount > 0:
      infraError = "repro infra apply reported " & $result.infra.errorCount &
        " error(s) and " & $result.infra.driftCount & " drift finding(s):\n  " &
        result.infra.diagnostics.join("\n  ")
  except EAddOn as e:
    # ``marker`` is THIS run's: a replay or a revert writes a fresh one at
    # step 1, so its step says nothing about how far the switch it
    # recovers had got -- that one may well have flipped. Only a fresh
    # switch refused before its own flip may be undone and forgotten; a
    # refused replay or revert goes down the not-committed path below,
    # which keeps the marker (a revert) or reverts (a replay).
    let freshSwitch = not replaying and not opts.recordOnly and
                      purpose notin ["replay", "revert"]
    when mutated("refused-recovery-forgets-marker"):
      let undoable = marker.step < ssFlip
    else:
      let undoable = freshSwitch and marker.step < ssFlip
    if undoable:
      # A refusal decided before the flip (an exclusive unit that would
      # overlap): nothing was switched, but step 2 may already have
      # stopped or disabled units. They are put back -- the marker named
      # each before it was touched -- and the old generation stands.
      let undoProblems = undoPreStop(marker)
      clearPendingMarker(stateDir)
      clearPendingPlan(stateDir)
      releasePendingRoot()
      if undoProblems.len > 0:
        raise newException(AddonApplyError, e.msg & "\nputting back what " &
          "step 2 stopped failed: " & undoProblems.join("; "))
      raise e
    infraError = "repro infra apply failed: " & e.msg
  except CatchableError as e:
    infraError = "repro infra apply failed: " & e.msg
  result.generationId = hookGeneration
  result.ledger = newLedger
  if keptAsDrift.len > 0 and not mutated("apply-prints-reviewed-plan"):
    # What steps 2 and 7 executed, not the reviewed plan: the re-check
    # kept removed units, the rest was planned again without them.
    result.transitions = executedTransitions(stepTransitions, keptAsDrift)
  result.restored = hookRestored
  if hookKept.len > 0:
    result.drift.add(hookKeptDrift)
    var still: seq[string]
    for a in result.removed:
      if a notin hookKept: still.add(a)
    result.removed = still
  result.sysctlObserved = hookSysctl

  result.confirm = hookConfirm
  result.failedAtFloor = hookFailedAtFloor

  if not result.infra.committed:
    # Not a generation: `current` still names the one the switch began
    # from. The marker records how far the switch got and why it stopped.
    let why = if infraError.len > 0: infraError
              else: "the switch did not complete cleanly"
    marker.status = "failed"
    marker.detail = why
    writePendingMarker(stateDir, marker)
    let isRevert = purpose == "revert" or opts.replayOf == "revert"
    # A8, spec §7.5: the rollback floor bounds EVERY automatic revert, not
    # only a failed confirmation. A failure after the flip is left in
    # place -- marker and all -- and reported, never reverted below it.
    # (`floor-ignored` removes the floor altogether, this path included;
    # `floor-only-on-confirm` removes only this path.)
    when not mutated("floor-only-on-confirm") and not mutated("floor-ignored"):
      if floorBlocksRevert and marker.step >= ssFlip and not opts.recordOnly:
        writeFileAtomic(floorHoldPath(stateDir), "rollbackFloor=" &
          $opts.rollbackFloor & "\nsequence=" & $opts.agentSequence &
          "\nfrom=" & committedPrevious & "\n", 0o600)
        let attemptLog = if hookGeneration.len > 0: hookGeneration
                         else: committedPrevious
        if attemptLog.len > 0:
          appendAuditRecord(applyLogPath(stateDir, attemptLog), AuditRecord(
            timestamp: getTime().toUnix(), operationKind: "addon.switch",
            resourceAddress: "generation:" & attemptLog,
            outcome: "failed-at-floor",
            diagnostic: "rollback floor " & $opts.rollbackFloor & "; not " &
              "reverted to " & committedPrevious & "; not committed: " & why,
            recordClass: AuditClassLiveState))
        discard writeEvidenceRecord("failed-at-floor", %*{
          "attempt": hookGeneration, "previous": committedPrevious,
          "rollbackFloor": opts.rollbackFloor, "sequence": opts.agentSequence,
          "committed": false, "failures": [why]})
        raise newException(AddonFailedAtFloor, why & "\nthe switch failed " &
          "after its flip and was not reverted: the signed rollback floor " &
          $opts.rollbackFloor & " is above " & committedPrevious & "; the " &
          "pending marker at " & pendingMarkerPath(stateDir) & " stays, and " &
          "a recovery finishes the switch forward")
    if opts.recordOnly and hookRecordedClean and
        not infraError.startsWith("repro infra apply failed"):
      raise newException(AddonRecordedOnly, "the failed switch's writes " &
        "were recorded; nothing was committed (record-only replay)")
    if isRevert or opts.recordOnly or committedPrevious.len == 0:
      # A revert that fails, a record-only replay (its caller reverts), or
      # a first switch (bootstrap) with nothing to go back to (owner
      # decision 23): the marker stays for `repro system addon recover` and
      # the re-assert unit, which reports `degraded`.
      raise newException(AddonApplyError, why &
        "\nthe generation was not committed; `current` still names " &
        (if committedPrevious.len > 0: committedPrevious else: "no generation") &
        " and the pending marker at " & pendingMarkerPath(stateDir) &
        " records the step reached")
    # §7.5, and §7.2's "old or new, never a mixture": the switch goes back
    # to the generation `current` names, through the same switch, with
    # everything step 2 stopped or that was running at plan time started
    # again.
    var assume = marker.stopped
    for u in activeAtPlan:
      if u notin assume: assume.add(u)
    let back = revertProfiles(stateDir, committedPrevious, ownText,
                              previousUserText)
    var reverted: AddonApplyResult
    if not replaying and not ledgerRecordsAttempt(stateDir, committedPrevious):
      # The switch failed before it recorded what it wrote (an exception
      # out of the infra apply, or out of its own steps 6-8, ahead of the
      # ledger write -- whether or not its post-write hook had begun): the
      # ledger copy still describes the old generation while the host
      # carries some of the new one's writes, and a revert planned from it
      # could neither
      # recognise them nor remove them. The failed switch is first replayed
      # from its write-ahead plan -- its writes only, no start, no commit --
      # which brings the ledger copy up to date with what it wrote; the
      # revert then plans from that.
      try:
        discard runAddonApply(AddonApplyOptions(stateDir: stateDir,
          hostIdentity: opts.hostIdentity, replay: true, recordOnly: true,
          driver: opts.driver, reproExe: opts.reproExe))
      except AddonRecordedOnly:
        discard        # recorded, and by design not committed
      except CatchableError as e:
        # The writes could not be recorded: a revert planned from the old
        # ledger could not tell them apart, so none is attempted.
        raise newException(AddonApplyError, why & "\nthe failed switch's " &
          "writes could not be recorded, so it was not rolled back: " &
          e.msg & "\nthe pending marker at " & pendingMarkerPath(stateDir) &
          " records it; run `repro system addon recover`")
    try:
      reverted = runAddonApply(AddonApplyOptions(stateDir: stateDir,
        hostIdentity: opts.hostIdentity, ownProfileText: back.own,
        userProfileText: back.user, storedTarget: true, driver: opts.driver,
        purpose: "revert",
        assumeActive: assume, retention: opts.retention,
        reproExe: opts.reproExe, revertOf: hookGeneration, revertReason: why,
        nonBlockingStarts: opts.nonBlockingStarts,
        confirmCapSec: opts.confirmCapSec))
    except CatchableError as e:
      raise newException(AddonApplyError, why & "\nthe switch could not " &
        "be rolled back to " & committedPrevious & " either: " & e.msg &
        "\nthe pending marker at " & pendingMarkerPath(stateDir) &
        " records it; run `repro system addon recover`")
    recordRolledBack(stateDir, hookGeneration, committedPrevious,
                     reverted.generationId, why, hookHealthFailed)
    var err = newException(AddonRolledBack, "the switch was rolled back to " &
      committedPrevious & " (re-applied as generation " &
      reverted.generationId & "): " & why)
    raise err

  # A8, spec §7.5: the rollback floor kept a failed switch in place.
  # Recorded as `failed-at-floor` in the attempt's apply log and as an
  # evidence record; the caller reports the failures.
  if hookFailedAtFloor.len > 0:
    appendAuditRecord(applyLogPath(stateDir, result.generationId), AuditRecord(
      timestamp: getTime().toUnix(), operationKind: "addon.switch",
      resourceAddress: "generation:" & result.generationId,
      outcome: "failed-at-floor",
      diagnostic: "rollback floor " & $opts.rollbackFloor & " is above " &
        "sequence " & $generationAgentSequence(stateDir, committedPrevious) &
        " of " & committedPrevious & "; not reverted: " &
        hookFailedAtFloor.join("; "),
      recordClass: AuditClassLiveState))
    discard writeEvidenceRecord("failed-at-floor", %*{
      "generation": result.generationId, "previous": committedPrevious,
      "rollbackFloor": opts.rollbackFloor, "sequence": opts.agentSequence,
      "failures": hookFailedAtFloor})

  # --- Step 9: committed by the infra apply; the generation's root takes
  # over everything the pending root held, the retention policy runs, and
  # the marker goes. ---
  var prefixIds: seq[PrefixIdBytes]
  for e in newLedger.entries:
    if e.class == lcStorePrefix and e.sha256.len > 0:
      # (A referenced object's entry names no prefix id: its root is the
      # closure's or the bootstrap prefix's, held already.)
      prefixIds.add(parsePrefixIdHex(e.sha256))
  promotePendingRoot(result.generationId, prefixIds)
  # The current generation is this one; the previous is what `current`
  # named before (never an uncommitted attempt's id); and a generation a
  # running managed unit may still run from is kept too (spec §5.2).
  block:
    # Which generation each running managed instance runs: started during
    # this switch (its invocation id changed) -- this one; otherwise what
    # the table said.
    let running = runningManagedUnits(newLedger)
    let tablePath = invocationTablePath(stateDir)
    let table = invocationsAfterSwitch(readInvocationTable(tablePath),
      running, invocationsBefore, startedBySwitch, result.generationId,
      committedPrevious, tableExisted = fileExists(tablePath))
    writeInvocationTable(tablePath, table)
  result.retentionDropped = pruneGenerationRoots(result.generationId,
    committedPrevious, opts.retention.get(DefaultRetention),
    held = heldGenerations(stateDir, newLedger, result.generationId))
  marker.step = ssCommit
  writePendingMarker(stateDir, marker)
  seamPause(stateDir, seamPrefix & "step-9")
  # Secrets (A7): the committed generation keeps its own copy of the
  # envelope it materialised from, a staged section becomes the latest,
  # and a rotation whose next key opened it is completed. Before the
  # marker goes, so a crash here is finished by the recovery's re-assert
  # (``secrets_ops.reassertSecrets`` completes it from the source record).
  commitSecretsOf(stateDir, secretsLayout, result.generationId)
  result.heldAtRevert = heldAtRevert
  for l in heldAtRevert:
    appendAuditRecord(applyLogPath(stateDir, result.generationId), AuditRecord(
      timestamp: getTime().toUnix(), operationKind: "addon.floor",
      resourceAddress: "unit:" & l.split(": ")[0],
      outcome: "held-at-revert", diagnostic: l,
      recordClass: AuditClassLiveState))
  if secretsFailure.len > 0:
    appendAuditRecord(applyLogPath(stateDir, result.generationId), AuditRecord(
      timestamp: getTime().toUnix(), operationKind: "addon.secrets",
      resourceAddress: "generation:" & result.generationId,
      outcome: "secrets-failed", diagnostic: secretsFailure,
      recordClass: AuditClassLiveState))
  clearPendingMarker(stateDir)
  clearPendingPlan(stateDir)
  # A switch the rollback floor kept in place is resolved by its commit.
  if fileExists(floorHoldPath(stateDir)): removeFile(floorHoldPath(stateDir))

type
  FailedReplayRevert* = object
    reverted*: bool        ## the host is back in the generation the
                           ## interrupted switch began from
    generationId*: string  ## the revert's generation (when reverted)
    why*: string           ## why no revert was possible (when not)
    source*: string        ## what the revert re-applied (when reverted)

proc revertAfterFailedReplay*(stateDir: string; prior: PendingMarker;
                              replayError: string;
                              driver: CollisionDriver = nil;
                              nonBlockingStarts = false;
                              confirmCapSec = 0): FailedReplayRevert =
  ## A recovery whose replay of an interrupted switch failed for any reason
  ## other than rolling itself back (a plan that cannot be read or
  ## planned, a refusal, a step that raised) reverts to the generation the
  ## switch began from, through the same switch, whenever that is possible
  ## (spec §7.2, decision 23). The revert re-applies that generation's own
  ## stored profiles, so it needs nothing of the failed switch's plan --
  ## only a record of what the switch wrote, so that it can remove it.
  ## The marker is kept, with ``reverted`` false and the reason, exactly
  ## when no revert is possible:
  ##
  ## - the switch being recovered is itself a revert (or the replay's own
  ##   revert failed): a failed revert keeps its marker;
  ## - a first switch (bootstrap's): there is no generation to go back to;
  ## - ``current`` no longer names the generation the switch began from,
  ##   or no profile to go back to survives (no generation copy, none in
  ##   the write-ahead record, the stored ones already replaced);
  ## - the write-ahead record is unusable or cannot be planned AND the
  ##   switch may have written (it had passed step 2) without the ledger
  ##   recording it: no revert can tell its writes apart. (These are the
  ##   approved exceptions to always reverting; see the spec, §7.2.)
  ##
  ## A revert that is attempted and fails raises, with its own marker
  ## kept (the first case, at the next recovery).
  var now = prior
  try: now = readPendingMarker(stateDir)
  except CatchableError: discard
  if prior.purpose == "revert" or now.purpose == "revert":
    return FailedReplayRevert(why: "the switch being recovered is a " &
      "revert, and a revert that fails keeps its marker")
  let fromGen = prior.fromGeneration
  if fromGen.len == 0:
    return FailedReplayRevert(why: "a first switch (bootstrap) has no " &
      "generation to go back to")
  if fileExists(floorHoldPath(stateDir)):
    return FailedReplayRevert(why: "the signed rollback floor kept this " &
      "switch from reverting (" & floorHoldPath(stateDir) & "); finish it " &
      "with `repro system addon recover`, or apply a newer manifest")
  let current = readCurrentGenerationId(stateDir)
  if current != fromGen:
    return FailedReplayRevert(why: "`current` names " &
      (if current.len > 0: current else: "no generation") &
      ", not " & fromGen & ", the generation the switch began from")
  # What to go back to, decided before anything below can replace the
  # stored profiles: the generation's own copies; for a generation applied
  # before those were kept, the profiles the write-ahead record saved (in
  # their own files, readable even when the plan is not); failing that,
  # the stored profiles, while the ledger copy shows the interrupted switch
  # has not yet replaced them (it rewrites both together).
  var back = generationProfiles(stateDir, fromGen)
  var backFrom = "generation " & fromGen & "'s own profile copies"
  if not back.found:
    let rec = pendingFromProfiles(stateDir)
    if rec.found:
      back = (true, rec.own, rec.user)
      backFrom = "the profiles the write-ahead record saved"
    elif not ledgerRecordsAttempt(stateDir, fromGen) and
        fileExists(ownProfilePath(stateDir)) and
        fileExists(userProfilePath(stateDir)):
      back = (true, readFile(ownProfilePath(stateDir)),
              readFile(userProfilePath(stateDir)))
      backFrom = "the stored profiles, which the switch had not replaced"
  if not back.found:
    return FailedReplayRevert(why: "generation " & fromGen & " keeps no " &
      "copy of its profiles, and neither the write-ahead record nor the " &
      "stored profiles still hold them")
  # Nothing but stops (and the flip of the static tree, which the revert's
  # own flip undoes) happens before step 3's drivers write.
  let wroteNothing = prior.step <= ssPreStop and now.step <= ssPreStop
  var tracked = wroteNothing or ledgerRecordsAttempt(stateDir, fromGen)
  var planUsable = false
  var plan: PendingPlan
  if hasPendingPlan(stateDir):
    try:
      plan = readPendingPlan(stateDir)
      planUsable = true
    except CatchableError:
      discard
  if not tracked and planUsable:
    # The switch wrote but had not recorded it: replay its writes only,
    # which records them in the ledger copy (see the not-committed path
    # of `runAddonApply`).
    var recordError = ""
    try:
      discard runAddonApply(AddonApplyOptions(stateDir: stateDir,
        hostIdentity: readHostname(), replay: true, recordOnly: true,
        driver: driver))
    except AddonRecordedOnly:
      discard        # recorded, and by design not committed
    except CatchableError as e:
      recordError = e.msg
    tracked = ledgerRecordsAttempt(stateDir, fromGen)
    if not tracked and recordError.len > 0:
      # Spec §7.2 (recovery), cause 3: the report names the cause, the
      # write-ahead record (what it names could not be planned from), not
      # only the error the record-only replay raised.
      return FailedReplayRevert(why: "the write-ahead record cannot be " &
        "planned from (recording the interrupted switch's writes failed: " &
        recordError & ") and the switch had passed step 2 (" & $prior.step &
        "); no revert can tell those writes apart")
  if not tracked:
    return FailedReplayRevert(why: "the write-ahead record is " &
      (if planUsable: "usable but its writes could not be recorded"
       else: "unusable") & " and the switch had passed step 2 (" &
      $prior.step & ") without the ledger recording what it wrote; no " &
      "revert can tell those writes apart")
  var assume = prior.stopped
  if planUsable:
    for u in plan.activeUnits:
      if u notin assume: assume.add(u)
  let reason = "the replay of the interrupted switch failed: " & replayError &
    " (reverted from " & backFrom & ")"
  let r = runAddonApply(AddonApplyOptions(stateDir: stateDir,
    hostIdentity: readHostname(), ownProfileText: back.own,
    userProfileText: back.user, storedTarget: true, driver: driver,
    purpose: "revert",
    assumeActive: assume, revertOf: prior.attempt, revertReason: reason,
    nonBlockingStarts: nonBlockingStarts, confirmCapSec: confirmCapSec))
  # Step 2 disabled the units the switch was removing, recording each
  # first. When the switch got no further, their files are still the old
  # generation's and the ledger still lists them unchanged, so the revert
  # finds nothing to write and would leave them disabled: they are
  # re-enabled here, as a refused fresh switch's are (`undoPreStop`).
  var disabled = prior.disabled
  for u in now.disabled:
    if u notin disabled: disabled.add(u)
  for u in disabled:
    try:
      if fileExists(unitPath(u)) and
          runSystemctl(["is-enabled", "--", u]).output.strip() == "disabled":
        discard runSystemctl(["enable", "--", u])
    except CatchableError:
      discard        # reported by the next check as drift
  recordRolledBack(stateDir, prior.attempt, fromGen, r.generationId, reason,
                   false)
  FailedReplayRevert(reverted: true, generationId: r.generationId,
                     source: backFrom)

proc renderLedgerDiff*(r: AddonApplyResult): string =
  ## The plan's ledger diff section (spec §7.1).
  # Drift is reported even when the ledger itself does not change (a vendor
  # unit that arrived under an owned name changes nothing the add-on owns).
  if r.ledgerDiff.len == 0 and r.unlisted.len == 0 and r.drift.len == 0:
    return "ledger diff: no change\n"
  result = "ledger diff:\n"
  for line in r.ledgerDiff:
    result.add("  " & line & "\n")
  for u in r.unlisted:
    result.add("  unlisted\t" & u & "\tleft the profile but the ledger " &
               "does not list it; never removed\n")
  for d in r.drift:
    result.add("  drift\t" & d & "\n")

# ---------------------------------------------------------------------------
# Every apply's evidence record (spec §10.4, milestone A11).
# ---------------------------------------------------------------------------

var applyDepth {.threadvar.}: int
  ## A revert, a replay and a record-only pass run inside an outer apply;
  ## only the outermost one records.

proc recordApplyEvidence(opts: AddonApplyOptions; stateDir: string;
                         r: AddonApplyResult; failure: ref CatchableError) =
  ## The record of one apply: ``addon-apply`` (audit) with the attestation
  ## of the generation it committed, or, for an operator's apply that did
  ## not commit, its refusal or rollback (DET-AO-2, -5, -7). The deploy
  ## agent's own applies record their failures in the tick's record, and a
  ## switch the rollback floor kept in place has its own record. Never
  ## raises: the apply's outcome stands whatever happens here.
  var site = defaultSite(stateDir)
  let purpose = if opts.purpose.len > 0: opts.purpose else: "apply"
  var fields = @[("purpose", purpose), ("sequence", $opts.agentSequence)]
  try:
    if failure.isNil:
      fields.add(("previousGeneration", r.previousGenerationId))
      discard recordEvidence(EvidenceEvent(detector: edApply,
        category: ecAudit, trigger: "applied", kind: "apply",
        fields: fields, attest: true, attestGeneration: r.generationId), site)
      return
    if opts.agentSequence > 0'u64 or failure of AddonFailedAtFloor: return
    fields.add(("message", failure.msg))
    let (det, trig) =
      if failure of AddonRolledBack: (edRollback, "rolled-back")
      elif $adStoreChanged in failure.msg: (edStore, "store-changed")
      else: (edApplyRefusal, "apply-refused")
    discard recordEvidence(EvidenceEvent(detector: det, category: ecDetection,
      trigger: trig, fields: fields, attest: true), site)
  except CatchableError as e:
    stderr.write("repro-addon: cannot write the apply's evidence record: " &
      e.msg & "\n")

proc runAddonApply*(opts: AddonApplyOptions): AddonApplyResult =
  ## ``applyGenerationUnrecorded`` with its evidence record (spec §10.4):
  ## every apply that commits, and every operator apply that refuses or is
  ## reverted, leaves one. A plan-only run and a record-only replay change
  ## nothing and record nothing.
  inc applyDepth
  defer: dec applyDepth
  if applyDepth > 1 or opts.planOnly or opts.recordOnly:
    return applyGenerationUnrecorded(opts)
  let stateDir = if opts.stateDir.len > 0: opts.stateDir else: DefaultStateDir
  try:
    result = applyGenerationUnrecorded(opts)
  except CatchableError as e:
    recordApplyEvidence(opts, stateDir, AddonApplyResult(), e)
    raise
  recordApplyEvidence(opts, stateDir, result, nil)
