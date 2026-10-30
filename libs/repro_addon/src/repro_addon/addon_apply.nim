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

import std/[algorithm, options, os, sets, strutils, tables, times]

import repro_dsl_stdlib/packages/apt_closure
import repro_elevation
import repro_elevation/posix_system_driver
import repro_infra
import repro_infra/addon_diagnostics
import repro_infra/planner
import repro_local_store/store

import ./collision
import ./etc_write
import ./fingerprint
import ./generation0
import ./host_exec
import ./health
import ./ledger
import ./mutations
import ./pending_plan
import ./seams
import ./static_tree
import ./store_root
import ./switch
import ./sysctl_precedence
import ./transitions

export AddonDriftError, AddonCollisionError, EAddOnExclusiveOverlap
export transitions.Transition, transitions.TransitionVerb,
  transitions.renderTransitions, transitions.parseTransitions
export switch.RetentionPolicy, switch.DefaultRetention
export health.ConfirmOutcome

type
  AddonApplyError* = object of CatchableError
  AddonRolledBack* = object of AddonApplyError
    ## The switch did not complete -- a health check failed within
    ## ``confirmTimeout``, a write was refused, a step failed -- and it was
    ## reverted: the host is back in the generation ``current`` names
    ## (§7.5). The attempt's apply log records ``rolled-back``.

  AddonPaths* = object
    stateDir*: string

  AddonApplyOptions* = object
    stateDir*: string
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

const
  DefaultStateDir* = "/var/lib/repro/system"
  AddonManagedKinds* = {srkFsSystemFile, srkSystemdSystemUnit,
                        srkLinuxDpkgDiversion, srkSystemdSystemDropIn,
                        srkLinuxSysusersEntry, srkLinuxTmpfilesRule,
                        srkLinuxSysctl, srkSystemdUnitState}
    ## The resource kinds an add-on generation may carry in this release:
    ## the ``etcFile``, ``unit``, ``dropIn``, ``diversion``, ``sysusers``,
    ## ``tmpfiles``, ``sysctl`` and ``unitState`` classes of spec §4.1
    ## (``secret`` arrives with A7, ``firewall`` is opt-in and refused in
    ## agent applies until §13 Q6).
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
proc preservedDir*(stateDir: string): string = addonDir(stateDir) / "preserved"
proc generationLedgerPath*(stateDir, generationId: string): string =
  stateDir / "generations" / generationId / "addon-ledger"

proc generationUnitLookup*(stateDir: string): GenerationUnitLookup =
  ## A unit's definition (its ledger digest) in a generation's own ledger,
  ## for retention (``switch.generationsHeldBy``). A ledger that is
  ## missing or unreadable is reported as not found, which keeps the
  ## generation.
  var cache = initTable[string, Ledger]()
  var missing = initHashSet[string]()
  result = proc(generationId, unit: string):
      tuple[ledgerFound, unitFound: bool; sha256: string] =
    if generationId in missing: return (false, false, "")
    if generationId notin cache:
      try:
        cache[generationId] = readLedger(generationLedgerPath(stateDir, generationId))
      except CatchableError:
        missing.incl(generationId)
        return (false, false, "")
    for e in cache[generationId].entries:
      if e.class == lcUnit and e.unit == unit:
        return (true, true, e.sha256)
    (true, false, "")

proc isAddonHost*(stateDir = DefaultStateDir): bool =
  ## An add-on host is one whose state directory holds the ledger copy.
  fileExists(ledgerCopyPath(stateDir))

proc readHostname*(): string =
  try: readFile("/proc/sys/kernel/hostname").strip()
  except IOError, OSError: "localhost"

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
  if r.kind in AddonManagedKinds: ""
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
    else:
      discard

proc checkScope*(user: SystemProfile) =
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
    case r.kind
    of srkLinuxTmpfilesRule:
      # Spec §4.1: the tmpfiles class lives at /etc/tmpfiles.d/repro-<name>.conf.
      if not r.tmpfilesName.startsWith(AddOnFragmentPrefix):
        raise newAddOnOutOfScope($r.kind & ".name", "", r.address,
          "a tmpfiles fragment of the add-on is named repro-<name>.conf " &
          "(spec §4.1), got " & r.tmpfilesName)
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

proc savedDecision(s: SavedPlan): CollisionDecision =
  ## The interrupted switch's decision, as it made it. The bytes an
  ## adoption or reconciliation displaced were preserved at plan time.
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
  if result.verdict in {cvAdopt, cvReconcile}:
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

proc alreadyRestored(e: LedgerEntry): bool =
  ## A replay finds the removals the interrupted switch already made:
  ## an object that had preserved bytes now carries exactly them (its
  ## restore ran), or is gone when it was the add-on's creation.
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
  if e.isLink and symlinkExists(e.path) and expandSymlink(e.path) == e.linkTarget:
    # The add-on's own link into the static tree (the ledger names its
    # target; the restore loop checked nothing else moved it). The writer
    # below rightly refuses a link on the leaf, so the link goes first:
    # the restored bytes are a regular file where the link was.
    discard removeLeafNoFollow(e.path)
  let (mode, owner) = parseEtcFileValue(e.replaced)
  let (uid, gid) = parseOwner(owner)
  writeFileNoFollow(e.path, readFile(e.preserved), parseOctInt(mode), uid, gid)
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
      if e.class in {lcEtcFile, lcUnit, lcDropIn, lcDiversion, lcUnitState} and
          (e.path == p.targetPath or e.class == lcUnitState):
        known = true
        prevMain = e
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

proc reshape(user: SystemProfile; dropIns: var HashSet[string]):
    seq[SystemResource] =
  ## The operator's resources as the apply carries them: a
  ## ``collision = dropIn`` unit becomes the drop-in file it writes
  ## (keeping the resource's address, which ``dropIns`` collects), and a
  ## ``collision = divert`` file gains the ``linux.dpkgDiversion`` it
  ## depends on unless the profile already declares one for the path.
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

proc restoreUnitState*(e: LedgerEntry; driver: CollisionDriver) =
  ## After the add-on's unit file left (restored or removed), put the unit
  ## back in the state the base had it: a `replace`d package unit that was
  ## enabled and active stays so, now from the package's file; an adopted
  ## hand-written unit the add-on enabled is disabled again. Runs after
  ## `daemon-reload`.
  let now = driver.unitProvision(e.unit)
  let nowEnabled = now.unitFileState in ["enabled", "enabled-runtime"]
  if e.baseUnitState == "enabled" and not nowEnabled and
      now.loadState == "loaded":
    systemctlOrRaise(["enable", "--", e.unit])
  elif e.baseUnitState != "enabled" and nowEnabled:
    systemctlOrRaise(["disable", "--", e.unit])
  if e.baseActiveState == "active" and now.loadState == "loaded":
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
                         addresses: openArray[string]): SystemProfile =
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
  let current = if currentText.len > 0: parseSystemProfile(currentText)
                else: SystemProfile()
  result.addOn = current.addOn
  result.addOn.declared = current.addOn.declared or given.addOn.declared
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
    try: startUnit(u)
    except CatchableError as e: result.add(e.msg)

proc recordRolledBack(stateDir, attempt, backTo, asGeneration, why: string;
                      healthFailed: bool) =
  ## The attempt's apply log records the outcome (§7.5: "records the
  ## apply as rolled-back"), so `repro system audit` and the evidence
  ## trail show it under the id the attempt would have had.
  if attempt.len == 0: return
  appendAuditRecord(applyLogPath(stateDir, attempt), AuditRecord(
    timestamp: getTime().toUnix(), operationKind: "addon.switch",
    resourceAddress: "generation:" & attempt, outcome: "rolled-back",
    diagnostic: (if healthFailed: "confirm failed: " else: "") & why &
      " -> back to " & backTo & " as " & asGeneration,
    recordClass: AuditClassLiveState))

proc seamedGuard(stateDir: string; inner: PreWriteGuard): PreWriteGuard =
  ## The pre-write guard, with the two write-time test seams in front of
  ## it (a no-op outside a ``-d:reproAddonTestSeams`` build).
  when AddonTestSeams:
    var calls = 0
    result = proc(op: PrivilegedOperation): string {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
        if calls == 1: seamPause(stateDir, "pre-write")
        elif calls == 2: seamPause(stateDir, "mid-write")
        inner(op)
  else:
    inner

proc runAddonApply*(opts: AddonApplyOptions): AddonApplyResult =
  ## Apply one add-on generation (or, with ``planOnly``, decide and report
  ## it). Raises a typed refusal with nothing written when the scope or
  ## collision pass refuses, and ``AddonApplyError`` when the infra apply
  ## reports an error -- after recording, in the ledger, every object that
  ## apply did create, so uninstall still finds them.
  let stateDir = if opts.stateDir.len > 0: opts.stateDir else: DefaultStateDir
  if not opts.planOnly:
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
    raise newException(AddonApplyError, "an interrupted switch is pending " &
      "(" & pendingMarkerPath(stateDir) & "); run `repro system addon " &
      "recover` to finish or revert it first")
  var replayPlan: PendingPlan
  if opts.replay:
    replayPlan = readPendingPlan(stateDir)
  let replaying = opts.replay
  let ownText =
    if replaying: replayPlan.targetOwnText
    elif opts.ownProfileText.len > 0: opts.ownProfileText
    elif fileExists(ownProfilePath(stateDir)): readFile(ownProfilePath(stateDir))
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

  let own = parseSystemProfile(ownText)
  let user =
    if adoptAddresses.len > 0:
      scopedAdoptProfile(parseSystemProfile(targetUserText),
                         previousUserText, adoptAddresses)
    else: parseSystemProfile(targetUserText)
  checkScope(user)
  var ownAddresses = initHashSet[string]()
  for r in own.resources: ownAddresses.incl(r.address)
  for r in user.resources:
    if r.address in ownAddresses:
      raise newException(AddonApplyError, "the profile declares " &
        r.address & ", which is one of the add-on's own objects")
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

  var prevForm = initTable[string, string]()  # target path -> link / copy
  for e in previous.entries:
    if e.class in FileClasses and e.resource.len > 0:
      prevForm[e.path] = (if e.isLink: "link" else: "copy")
  var prevSha = initTable[string, string]()   # target path -> ledger digest
  var prevOwned = initHashSet[string]()
  for e in previous.entries:
    if e.class in {lcEtcFile, lcUnit, lcDropIn} and e.resource.len > 0:
      prevSha[e.path] = e.sha256
      prevOwned.incl(e.path)
    elif e.class == lcDiversion:
      prevOwned.incl("diversion:" & e.path)

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
  var plans: seq[ResourcePlan]
  var targets: seq[PlannedTarget]
  var verdictByAddress = initTable[string, CollisionVerdict]()
  # The add-on's own objects go through the same table as the operator's:
  # a link planted on one of their paths, or a package that came to own
  # one, is met the same way, and the pre-write guard knows them.
  for r in own.resources:
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
    var dec: CollisionDecision
    var obs: TargetObservation
    if saved.found: dec = savedDecision(saved.plan)
    else: (dec, obs) = decide(driver, inp, p.targetPath)
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
    result.collisions.add(CollisionLine(address: r.address, target: p.targetPath,
      observation: dec.observation, verdict: $dec.verdict, reason: dec.reason))
    targets.add(targetFor(r.address, inp, p.targetPath, dec, obs, saved))
    plans.add(p)
  for i in 0 ..< userResources.len:
    var r = userResources[i]
    var p = ResourcePlan(r: r)
    preObserve(p, driver)
    let saved = if replaying: replayPlan.savedPlanFor(r.address)
                else: (found: false, plan: SavedPlan())
    if saved.found: overlaySaved(p, saved.plan)
    if r.kind == srkSystemdSystemDropIn and not saved.found:
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
    var inp = DecisionInputs(address: r.address,
      reconcileDrift: reconcileDrift,
      adopt: r.address in adoptAddresses)
    var path = p.targetPath
    case r.kind
    of srkFsSystemFile:
      inp.kind = tkFile
      inp.collision = r.sfCollision
      inp.divertedByProfile = hasDiversionFor(userResources, r.sfPath)
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
    var dec: CollisionDecision
    var obs: TargetObservation
    if saved.found: dec = savedDecision(saved.plan)
    else: (dec, obs) = decide(driver, inp, path)
    decisions[r.address] = dec
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
      p.collision = "reconcile"
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
    p.form = if held: prevForm.getOrDefault(path, "copy")
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
      result.ledgerDiff.add($dec.verdict & "\t" & path & "\t" & r.address)
    targets.add(targetFor(r.address, inp, path, dec, obs, saved))
    plans.add(p)

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
                               resources: own.resources & userResources)
  # What the infra apply gets: the composition minus the resources adopted
  # as they are that it could not leave untouched (``skipInfra``), and
  # minus any dependency on them.
  var skipped = initHashSet[string]()
  for p in plans:
    if p.skipInfra: skipped.incl(p.r.address)
  var infraProfile = SystemProfile(addOn: user.addOn)
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
  var wanted = initHashSet[string]()
  for r in composed.resources: wanted.incl(r.address)

  # --- What left the profile, and may it be removed? (spec §4.2) ---
  # The stored profile is what the operator declared (plus what an earlier
  # removal left as drift); it is reshaped the same way, so the addresses
  # match the ledger's.
  var removed: seq[SystemResource]
  var previousUser: SystemProfile
  if previousUserText.len > 0:
    previousUser = parseSystemProfile(previousUserText)
    var prevDropIns = initHashSet[string]()
    for r in reshape(previousUser, prevDropIns):
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
  var removedSysctl: seq[LedgerEntry]     # keys to restore in step 6
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
    if not restoresInstead:
      destroy.add(r)
    if r.kind == srkSystemdSystemUnit and restoresInstead:
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
  var stored = SystemProfile(addOn: user.addOn, resources: user.resources)
  for r in previousUser.resources:
    if r.address in keptAddresses and r.address notin wanted:
      stored.resources.add(r)

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
      dropInsChangedFor.incl(p.r.diUnit)
  for r in removed:
    if r.kind == srkSystemdSystemDropIn: dropInsChangedFor.incl(r.diUnit)
  var addressByKey = initTable[string, string]()
  for r in composed.resources:
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
    f.activeState = readUnitProvision(f.unit).activeState
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
        stopHeld: r.suStopHeld)
      observed(f)
      f.isNew = r.suName notin prevUnits
      let closureMissing = r.suAptClosureLock.len > 0 and
        not aptClosureRealised(AddOnSystemStoreRoot,
                               parseAptClosureLock(r.suAptClosureLock))
      f.fileChanged = f.isNew or closureMissing or
        prevUnits[r.suName].sha256 != sha256Hex(rendered) or
        p.verdict in [$cvCreate, $cvUpdate, $cvReconcile, $cvReplace]
      f.dropInsChanged = r.suName in dropInsChangedFor
      if f.exclusive:
        f.predecessors = conflictsServices(rendered)
        # The units that can activate it (sockets, timers, paths): a
        # stop-start pauses the active ones (§7.3).
        for t in unitProperty(r.suName, "TriggeredBy").splitWhitespace():
          if readUnitProvision(t).activeState == "active":
            f.triggers.add(t)
        for pred in f.predecessors:
          # A predecessor the add-on does not own is never stopped or
          # disabled by it; while it runs or is enabled, the successor
          # cannot start without overlapping it (now, or at the next
          # boot), so the plan refuses (§7.3).
          if pred in prevUnits: continue
          let pv = readUnitProvision(pred)
          let alive = unitAliveness(pred)
          when not mutated("exclusive-as-plain-restart"):
            if pv.activeState == "active" or alive != uaEmpty or
                pv.unitFileState in ["enabled", "enabled-runtime", "linked",
                                     "linked-runtime", "alias"]:
              raise newAddOnExclusiveOverlap(r.suName, "its predecessor " &
                pred & " (named in its Conflicts=) is not the add-on's and " &
                "is " & pv.activeState & " with its control group " &
                $alive & " and unit-file state " &
                (if pv.unitFileState.len > 0: pv.unitFileState
                 else: "unknown") &
                "; stop and disable it, then apply again")
      for dep in r.dependsOn:
        let depAddress = addressByKey.getOrDefault(dep.kind & ":" & dep.name)
        if depAddress.len == 0: continue
        if dep.kind == $srkSystemdSystemUnit:
          unitDeps.mgetOrPut(r.address, @[]).add(depAddress)
        elif verdictByAddress.getOrDefault(depAddress, cvNoOp) != cvNoOp:
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
  propagateDependencyChanges(facts, unitDeps)
  result.transitions = planTransitions(facts)

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
          "\t" & f.triggers.join(","))
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

  if opts.planOnly:
    return

  # Every resource is decided and nothing refused: the bytes adoptions and
  # reconciliations displace are kept now, before the first write.
  for b in pendingPreserve:
    discard preserveBytes(stateDir, b)

  # --- Step 1: realise. ---
  # The tree goes into the store and is verified; the units' closures are
  # realised too, so no base path is touched before everything the
  # generation runs from exists. The apply lock is held throughout.
  var priorMarker: PendingMarker
  if replaying and hasPendingMarker(stateDir):
    priorMarker = readPendingMarker(stateDir)
  let previousStatic =
    if replaying and priorMarker.previousStatic.len > 0: priorMarker.previousStatic
    else: readStaticTarget()
  let (treePath, treePrefixId) = realiseStaticTree(treeFiles)
  var closurePaths: seq[string]
  for p in plans:
    if p.r.kind == srkSystemdSystemUnit and p.r.suAptClosureLock.len > 0:
      closurePaths.add(realiseAptClosure(
        parseAptClosureLock(p.r.suAptClosureLock), AddOnSystemStoreRoot,
        AddOnAptDebCacheDir))
  # The whole closure is rooted from here on, not only the tree: a
  # `repro store gc` between this step and the commit -- or after a crash,
  # before recovery -- must not collect what the switch is about to run.
  block:
    var closurePrefixes: seq[PrefixIdBytes]
    enterWritableStoreView()
    var st = openStore(StoreRoot)
    for path in closurePaths:
      let found = st.lookupPrefixByRealizedPath(path)
      if found.found: closurePrefixes.add(found.row.prefixId)
    st.close()
    holdOnPendingRoot(closurePrefixes)

  # The confirm step's checks (§7.5): every unit's declared healthCheck.
  var healthChecks: seq[UnitHealthCheck]
  for r in composed.resources:
    if r.kind == srkSystemdSystemUnit and r.suHealthCheck.len > 0:
      healthChecks.add(UnitHealthCheck(unit: r.suName, address: r.address,
        raw: r.suHealthCheck, spec: parseHealthCheck(r.suHealthCheck)))
  result.healthChecks = healthChecks
  let confirmTimeout = if user.addOn.confirmTimeoutSec > 0:
                         user.addOn.confirmTimeoutSec
                       else: DefaultConfirmTimeoutSec
  let probeExe = if opts.reproExe.len > 0: opts.reproExe
                 else: getAppFilename()

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
    writePendingPlan(stateDir, PendingPlan(targetOwnText: ownText,
      targetUserText: targetUserText, fromUserText: previousUserText,
      fromLedgerText: previous.render(), reconcileDrift: reconcileDrift,
      adopt: adoptAddresses, activeUnits: activeAtPlan, plans: saved))
  var marker = PendingMarker(fromGeneration: committedPrevious,
    newStatic: treePath, previousStatic: previousStatic, step: ssRealise,
    status: "in-progress", purpose: purpose)
  if replaying:
    # What the interrupted switch stopped and disabled stays on record
    # until this one finishes.
    marker.stopped = priorMarker.stopped
    marker.disabled = priorMarker.disabled
  writePendingMarker(stateDir, marker)
  seamPause(stateDir, "step-1")

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
  var disableOnRemoval: seq[string]
  for r in removedUnits:
    disableOnRemoval.add(r.suName)
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
  var paused: seq[string]      # triggers step 2 stopped; step 7 restarts
  var hookConfirm: ConfirmOutcome
  var hookHealthFailed = false

  proc beforeSet(planId: string) {.gcsafe.} =
    ## Steps 2 and 3: pre-stop, then flip. A refusal here (an exclusive
    ## unit that will not die) leaves the host in the old generation.
    {.cast(gcsafe).}:
      when TestPauseSeam:
        testSeamPause()
      marker.planId = planId
      writePendingMarker(stateDir, marker)
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
      let pre = runPreStop(transitions, disableOnRemoval, onStop)
      paused = pre.paused
      marker.step = ssPreStop
      writePendingMarker(stateDir, marker)
      seamPause(stateDir, "step-2")
      # The flip is durable (its directory is synced) before the marker
      # says it happened; recovery never trusts the step anyway.
      flipStatic(treePath)
      marker.step = ssFlip
      writePendingMarker(stateDir, marker)
      seamPause(stateDir, "step-3")

  proc afterSet(generationId: string; clean: bool): seq[string] {.gcsafe.} =
    ## Steps 4 and 5 were the drivers'; now 6 (fragment tools), 7 (start)
    ## and 8 (confirm), then the ledger. A problem is a diagnostic that
    ## withholds the commit.
    {.cast(gcsafe).}:
      var problems: seq[string]
      hookGeneration = generationId
      # Steps 4 and 5 are the drivers' writes, in the profile's apply
      # order (links and copies interleave); both are complete here.
      marker.attempt = generationId
      marker.step = ssReconcileLinks
      writePendingMarker(stateDir, marker)
      seamPause(stateDir, "step-4")
      marker.step = ssCopies
      writePendingMarker(stateDir, marker)
      seamPause(stateDir, "step-5")
      # --- Step 6: the fragment tools. The sysusers and tmpfiles tools
      # ran per changed fragment inside their drivers; what is left is
      # the daemon reload, sysctl through the host's own service, and
      # the kernel values a removed sysctl resource leaves behind.
      try:
        if anyUnitChange: daemonReload()
        for e in removedSysctl:
          if readLiveSysctl(e.path) == e.value:
            restoreSysctlValue(e.path, e.replaced)
        applySysctlFragments(changedSysctl)
        for k in sysctlKeys:
          hookSysctl.add((key: k, value: observeSysctlInHostNamespaces(k)))
      except CatchableError as ex:
        problems.add("step 6 (fragment tools): " & ex.msg)
      marker.step = ssFragmentTools
      writePendingMarker(stateDir, marker)
      seamPause(stateDir, "step-6")
      # --- Step 7: start. Only after a clean step 4-6: a half-written
      # generation is not started.
      if clean and problems.len == 0:
        try:
          runStart(transitions, paused)
        except CatchableError as ex:
          problems.add("step 7 (start): " & ex.msg)
      marker.step = ssStart
      writePendingMarker(stateDir, marker)
      seamPause(stateDir, "step-7")
      # --- Step 8: confirm (§7.5). Every step above reported no problem,
      # and every declared health check passed within confirmTimeout,
      # counted from the end of step 7. A failure withholds the commit,
      # and the switch reverts below.
      if clean and problems.len == 0 and healthChecks.len > 0:
        hookConfirm = confirm(healthChecks, confirmTimeout,
                              hostNamespaceProbe(probeExe))
        if not hookConfirm.passed:
          hookHealthFailed = true
          problems.add("step 8 (confirm): " & $hookConfirm.failures.len &
            " health check(s) did not pass within confirmTimeout (" &
            $confirmTimeout & " s): " & hookConfirm.failures.join("; "))
      marker.step = ssConfirm
      writePendingMarker(stateDir, marker)
      # Objects a removed resource adopted or replaced go back to what they
      # were; the rest were destroyed by the infra apply.
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
        try: restoreUnitState(e, driver)
        except CatchableError as ex:
          problems.add(ex.msg)
      # Directories the removed resources had created.
      removeEmptyDirs(removedEntries)
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
      for e in previous.entries:
        if e.resource.len > 0 or e.class == lcStaticLink: continue
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
        sha256: prefixIdHex(treePrefixId), resource: "static-tree"))
      for p in plans:
        for e in entriesFor(p, previous.entries, driver):
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
        if e.resource in hookKept:
          # Left in place at write time: still the add-on's, kept in the
          # ledger like drift found at plan time.
          put(e)
          continue
        if e.path in hookRestored:
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
      seamPause(stateDir, "step-8")
      problems

  var infraError = ""
  try:
    result.infra = runInfraApply(composedText, ApplyOptions(
      stateDir: stateDir, hostIdentity: opts.hostIdentity,
      noPreview: true, elevationMode: emBroker,
      extraDestroyResources: destroy,
      preWriteGuard: seamedGuard(stateDir,
        (when mutated("pause-before-write-no-recheck"):
           # Falsifying build of the write-time re-check gate: every
           # operation is let through unchecked.
           PreWriteGuard(proc(op: PrivilegedOperation): string {.gcsafe.} = "")
         else: makePreWriteGuard(newDriver, targets, destroyCheck))),
      addOnDispatch: policy,
      phases: ApplyPhaseHooks(beforePrivilegedSet: beforeSet,
                              afterPrivilegedSet: afterSet,
                              commitOnlyWhenClean: true)))
    if result.infra.errorCount > 0 or result.infra.driftCount > 0:
      infraError = "repro infra apply reported " & $result.infra.errorCount &
        " error(s) and " & $result.infra.driftCount & " drift finding(s):\n  " &
        result.infra.diagnostics.join("\n  ")
  except EAddOn as e:
    if marker.step < ssFlip:
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
  result.restored = hookRestored
  if hookKept.len > 0:
    result.drift.add(hookKeptDrift)
    var still: seq[string]
    for a in result.removed:
      if a notin hookKept: still.add(a)
    result.removed = still
  result.sysctlObserved = hookSysctl

  result.confirm = hookConfirm

  if not result.infra.committed:
    # Not a generation: `current` still names the one the switch began
    # from. The marker records how far the switch got and why it stopped.
    let why = if infraError.len > 0: infraError
              else: "the switch did not complete cleanly"
    marker.status = "failed"
    marker.detail = why
    writePendingMarker(stateDir, marker)
    if purpose == "revert" or committedPrevious.len == 0:
      # A revert that fails, or a first switch (bootstrap) with nothing to
      # go back to: the marker stays for `repro system addon recover` and
      # the re-assert unit.
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
    try:
      reverted = runAddonApply(AddonApplyOptions(stateDir: stateDir,
        hostIdentity: opts.hostIdentity, ownProfileText: back.own,
        userProfileText: back.user, driver: opts.driver, purpose: "revert",
        assumeActive: assume, retention: opts.retention,
        reproExe: opts.reproExe))
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

  # --- Step 9: committed by the infra apply; the generation's root takes
  # over everything the pending root held, the retention policy runs, and
  # the marker goes. ---
  var prefixIds: seq[PrefixIdBytes]
  for e in newLedger.entries:
    if e.class == lcStorePrefix:
      prefixIds.add(parsePrefixIdHex(e.sha256))
  promotePendingRoot(result.generationId, prefixIds)
  # The current generation is this one; the previous is what `current`
  # named before (never an uncommitted attempt's id); and a generation a
  # running managed unit may still run from is kept too (spec §5.2).
  result.retentionDropped = pruneGenerationRoots(result.generationId,
    committedPrevious, opts.retention.get(DefaultRetention),
    running = runningManagedUnits(newLedger),
    lookup = generationUnitLookup(stateDir))
  marker.step = ssCommit
  writePendingMarker(stateDir, marker)
  seamPause(stateDir, "step-9")
  clearPendingMarker(stateDir)
  clearPendingPlan(stateDir)

proc renderLedgerDiff*(r: AddonApplyResult): string =
  ## The plan's ledger diff section (spec §7.1).
  if r.ledgerDiff.len == 0:
    return "ledger diff: no change\n"
  result = "ledger diff:\n"
  for line in r.ledgerDiff:
    result.add("  " & line & "\n")
  for u in r.unlisted:
    result.add("  unlisted\t" & u & "\tleft the profile but the ledger " &
               "does not list it; never removed\n")
  for d in r.drift:
    result.add("  drift\t" & d & "\n")
