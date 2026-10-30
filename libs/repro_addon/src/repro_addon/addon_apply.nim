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

import std/[algorithm, os, sets, strutils, tables, times]

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
import ./ledger
import ./mutations
import ./static_tree
import ./store_root
import ./switch
import ./transitions

export AddonDriftError, AddonCollisionError, EAddOnExclusiveOverlap
export transitions.Transition, transitions.TransitionVerb,
  transitions.renderTransitions, transitions.parseTransitions
export switch.RetentionPolicy, switch.DefaultRetention

type
  AddonApplyError* = object of CatchableError

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
    retention*: RetentionPolicy
      ## Which generations keep their store roots after this commit
      ## (spec §5.2); zero values mean the default (last 5 or 30 days).

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

proc checkScope*(user: SystemProfile) =
  ## Refuse, with ``EAddOnOutOfScope``, what an add-on generation may not
  ## carry: a kind outside the add-on's classes, and an ``/etc`` path
  ## outside the declared managed prefixes or inside a directory a class
  ## of its own reaches. Every resource is checked BEFORE anything is
  ## observed or written: a refused kind must refuse the whole apply, not
  ## be applied by the infra layer and then fail when the ledger is built
  ## (which would leave an unledgered object behind for uninstall to miss).
  let prefixes = managedPrefixes(user)
  for r in user.resources:
    when not mutated("apply-skips-kind-check"):
      let why = unmanagedKindReason(r)
      if why.len > 0:
        raise newAddOnOutOfScope($r.kind, "", r.address, why)
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
    for d in AddOnClassDirectories:
      if path.startsWith(d):
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

proc preObserve(p: var ResourcePlan) =
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
    let u = readUnitProvision(p.r.usName)
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
    let u = readUnitProvision(p.r.suName)
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
  ## Put the bytes the ledger preserved for ``e`` back at its path, with
  ## the mode and owner the path had. False when the entry preserved
  ## nothing (a plain deletion is then the right undo).
  if e.preserved.len == 0:
    return false
  if not fileExists(e.preserved):
    raise newException(AddonApplyError, "preserved bytes for " & e.path &
      " are missing at " & e.preserved)
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

proc entriesFor(p: ResourcePlan; previous: seq[LedgerEntry]): seq[LedgerEntry] =
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
      let now = readUnitProvision(r.suName)
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
      result.add(f)
  of srkLinuxTmpfilesRule:
    if fileExists(p.targetPath):
      var f = fileEntry(lcEtcFile, p.targetPath, r.address, replaced)
      f.observation = observation
      f.collision = collisionMode
      f.preserved = preserved
      result.add(f)
  of srkLinuxSysctl:
    if fileExists(p.targetPath) or symlinkExists(p.targetPath):
      var f = fileEntry(lcEtcFile, p.targetPath, r.address, replaced)
      f.observation = observation
      f.collision = collisionMode
      result.add(f)
      # The kernel parameter itself, with the host's value before the
      # add-on first set it (what removal restores).
      var before = p.sysctlBefore
      for e in previous:
        if e.resource == r.address and e.class == lcSysctl:
          before = e.replaced
      result.add(LedgerEntry(class: lcSysctl, path: r.sysctlKey,
        value: r.sysctlValue, replaced: before, resource: r.address))
  of srkLinuxSysusersEntry:
    if fileExists(p.targetPath):
      var f = fileEntry(lcEtcFile, p.targetPath, r.address, replaced)
      f.observation = observation
      f.collision = collisionMode
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
    if dirExists(d):
      var empty = true
      for _ in walkDir(d):
        empty = false
        break
      if empty:
        removeDir(d)

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

proc restoreUnitState*(e: LedgerEntry) =
  ## After the add-on's unit file left (restored or removed), put the unit
  ## back in the state the base had it: a `replace`d package unit that was
  ## enabled and active stays so, now from the package's file; an adopted
  ## hand-written unit the add-on enabled is disabled again. Runs after
  ## `daemon-reload`.
  let now = readUnitProvision(e.unit)
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

proc runAddonApply*(opts: AddonApplyOptions): AddonApplyResult =
  ## Apply one add-on generation (or, with ``planOnly``, decide and report
  ## it). Raises a typed refusal with nothing written when the scope or
  ## collision pass refuses, and ``AddonApplyError`` when the infra apply
  ## reports an error -- after recording, in the ledger, every object that
  ## apply did create, so uninstall still finds them.
  let stateDir = if opts.stateDir.len > 0: opts.stateDir else: DefaultStateDir
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

  let ownText =
    if opts.ownProfileText.len > 0: opts.ownProfileText
    elif fileExists(ownProfilePath(stateDir)): readFile(ownProfilePath(stateDir))
    else: raise newException(AddonApplyError,
      "not an add-on host: " & ownProfilePath(stateDir) & " is missing")
  let previous =
    if fileExists(ledgerCopyPath(stateDir)): readLedger(ledgerCopyPath(stateDir))
    else: Ledger()
  result.previousLedger = previous
  result.previousGenerationId = previous.generation
  let previousUserText =
    if fileExists(userProfilePath(stateDir)): readFile(userProfilePath(stateDir))
    else: ""

  let own = parseSystemProfile(ownText)
  let user = parseSystemProfile(opts.userProfileText)
  checkScope(user)
  var ownAddresses = initHashSet[string]()
  for r in own.resources: ownAddresses.incl(r.address)
  for r in user.resources:
    if r.address in ownAddresses:
      raise newException(AddonApplyError, "the profile declares " &
        r.address & ", which is one of the add-on's own objects")
  for a in opts.adoptAddresses:
    var declared = false
    for r in user.resources:
      if r.address == a: declared = true
    if not declared:
      raise newException(AddonApplyError, "cannot adopt " & a &
        ": the profile declares no resource with that address")

  let driver = if opts.driver != nil: opts.driver else: detectCollisionDriver()
  var dropIns = initHashSet[string]()
  var userResources = reshape(user, dropIns)
  for r in userResources:
    # A pre-bootstrap input is kept as found, by no resource; a resource
    # at its path would silently displace the carried-forward entry.
    let why = keptPathRefusal(previous, targetPathOf(r))
    if why.len > 0:
      raise newException(AddonCollisionError, "refusing " & r.address & ": " & why)

  var prevSha = initTable[string, string]()   # target path -> ledger digest
  var prevOwned = initHashSet[string]()
  for e in previous.entries:
    if e.class in {lcEtcFile, lcUnit, lcDropIn} and e.resource.len > 0:
      prevSha[e.path] = e.sha256
      prevOwned.incl(e.path)
    elif e.class == lcDiversion:
      prevOwned.incl("diversion:" & e.path)

  # --- The collision pass (plan time). ---
  var plans: seq[ResourcePlan]
  var targets: seq[PlannedTarget]
  var verdictByAddress = initTable[string, CollisionVerdict]()
  for r in own.resources:
    var p = ResourcePlan(r: r, own: true, form: "copy")
    preObserve(p)
    p.content = desiredBytes(r)
    verdictByAddress[r.address] = cvNoOp
    plans.add(p)
  for i in 0 ..< userResources.len:
    var r = userResources[i]
    var p = ResourcePlan(r: r)
    preObserve(p)
    if r.kind == srkSystemdUnitState:
      # Nothing of the add-on's on the host: no target, no collision row.
      # A missing or masked unit is refused by its driver.
      p.form = "copy"
      p.verdict = $cvNoOp
      verdictByAddress[r.address] = cvNoOp
      plans.add(p)
      continue
    var inp = DecisionInputs(address: r.address,
      reconcileDrift: opts.reconcileDrift,
      adopt: r.address in opts.adoptAddresses)
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
    inp.ledgerSha256 = prevSha.getOrDefault(path)
    let (dec, _) = decide(driver, inp, path)
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
    case dec.verdict
    of cvAdopt:
      p.collision = "adopt"
      if not opts.planOnly:
        p.preserved = preserveBytes(stateDir, dec.preWriteBytes)
      # Ask the apply for exactly the bytes that are there: nothing is
      # written, and the ledger owns them.
      if r.kind == srkFsSystemFile:
        r.sfContent = ""
        r.sfSourceLocal = if opts.planOnly: r.sfSourceLocal else: p.preserved
        if opts.planOnly and r.sfSourceLocal.len == 0:
          r.sfContent = dec.preWriteBytes
      elif r.kind == srkSystemdSystemUnit:
        inlineSafeOrRefuse("unit " & r.suName, dec.preWriteBytes)
        r.suContent = dec.preWriteBytes
      elif r.kind == srkSystemdSystemDropIn:
        r.diContent = dec.preWriteBytes
      elif r.kind == srkLinuxTmpfilesRule:
        r.tmpfilesContent = dec.preWriteBytes
      p.content = dec.preWriteBytes
      userResources[i] = r
      p.r = r
    of cvReconcile:
      p.collision = "reconcile"
      if not opts.planOnly:
        p.preserved = preserveBytes(stateDir, dec.preWriteBytes)
    of cvDivert:
      p.collision = "divert"
    of cvReplace:
      p.collision = "replace"
    of cvDropIn, cvCreate, cvUpdate, cvNoOp:
      if r.address in dropIns:
        p.collision = "dropIn"
    # The materialisation form (spec §7.2 steps 4 and 5): a link for the
    # link-form kinds, except an object adopted as it is (nothing is
    # written to it) -- a copy until its content changes.
    p.form = if r.kind in LinkFormKinds and dec.verdict != cvAdopt: "link"
             else: "copy"
    result.collisions.add(CollisionLine(address: r.address, target: path,
      observation: dec.observation, verdict: $dec.verdict, reason: dec.reason))
    if dec.verdict != cvNoOp:
      result.ledgerDiff.add($dec.verdict & "\t" & path & "\t" & r.address)
    targets.add(PlannedTarget(address: r.address, path: path, kind: inp.kind,
      unit: inp.unit, observation: dec.observation,
      observedSha256: dec.observedSha256, desiredSha256: inp.desiredSha256,
      verdict: dec.verdict))
    plans.add(p)

  let composed = SystemProfile(addOn: user.addOn,
                               resources: own.resources & userResources)
  let composedText = renderProfileText(composed)
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
      if d.len > 0 and not d.startsWith("missing"):
        drifted.add(e.path & ": " & d)
    if drifted.len > 0 and not opts.reconcileDrift:
      for d in drifted: result.drift.add(d & " (left in place; " &
        "--reconcile-drift removes it)")
      keptEntries.add(entries)
      keptAddresses.incl(r.address)
      for e in entries:
        if e.class in {lcEtcFile, lcUnit, lcDropIn}: keptPaths.incl(e.path)
      continue
    if drifted.len > 0 and not opts.planOnly:
      # Reconciled removal: what is there now is kept before it goes.
      for e in entries:
        if e.class in {lcEtcFile, lcUnit, lcDropIn} and fileExists(e.path):
          discard preserveBytes(stateDir, readFile(e.path))
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
    if r.kind == srkSystemdSystemUnit:
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
  let userText = renderProfileText(stored)

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
  var facts: seq[UnitFacts]
  var unitDeps = initTable[string, seq[string]]()
  var factUnits = initHashSet[string]()
  for r in removedUnits:
    let u = readUnitProvision(r.suName)
    facts.add(UnitFacts(unit: r.suName, address: r.address, owned: true,
      removed: true, active: u.activeState == "active",
      exclusive: isExclusiveUnit(r), stopHeld: r.suStopHeld))
    factUnits.incl(r.suName)
  for idx in order:
    let r = composed.resources[idx]
    case r.kind
    of srkSystemdSystemUnit:
      let p = plans[planByAddress[r.address]]
      let u = readUnitProvision(r.suName)
      let rendered = renderedSystemUnitContent(r)
      var f = UnitFacts(unit: r.suName, address: r.address, owned: true,
        active: u.activeState == "active", enabled: r.suEnabled,
        exclusive: isExclusiveUnit(r) or
          (r.suName in prevUnits and
           unitContentDeclaresExclusive(readFile(prevUnits[r.suName].path))),
        restartHeld: r.suRestartHeld, reloadIfChanged: r.suReloadIfChanged,
        stopHeld: r.suStopHeld)
      f.isNew = r.suName notin prevUnits
      let closureMissing = r.suAptClosureLock.len > 0 and
        not aptClosureRealised(AddOnSystemStoreRoot,
                               parseAptClosureLock(r.suAptClosureLock))
      f.fileChanged = f.isNew or closureMissing or
        prevUnits[r.suName].sha256 != sha256Hex(rendered) or
        p.verdict in [$cvCreate, $cvUpdate, $cvReconcile, $cvReplace]
      f.dropInsChanged = r.suName in dropInsChangedFor
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
      let u = readUnitProvision(r.usName)
      facts.add(UnitFacts(unit: r.usName, address: r.address,
        unitState: true, active: u.activeState == "active",
        desiredActive: r.usRunning))
      factUnits.incl(r.usName)
    else:
      discard
  # A drop-in of a unit the profile does not own: the unit is restarted
  # for the drop-in's change (§7.3) unless the drop-in holds it.
  for p in plans:
    if p.r.kind == srkSystemdSystemDropIn and p.r.diUnit notin factUnits and
        p.r.diUnit in dropInsChangedFor:
      let u = readUnitProvision(p.r.diUnit)
      facts.add(UnitFacts(unit: p.r.diUnit, address: p.r.address,
        active: u.activeState == "active", dropInsChanged: true,
        restartHeld: p.r.diRestartHeld))
      factUnits.incl(p.r.diUnit)
  for r in removed:
    if r.kind == srkSystemdSystemDropIn and r.diUnit notin factUnits:
      let u = readUnitProvision(r.diUnit)
      facts.add(UnitFacts(unit: r.diUnit, address: r.address,
        active: u.activeState == "active", dropInsChanged: true,
        restartHeld: r.diRestartHeld))
      factUnits.incl(r.diUnit)
  propagateDependencyChanges(facts, unitDeps)
  result.transitions = planTransitions(facts)

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

  # --- Step 1: realise. ---
  # The tree goes into the store and is verified; the units' closures are
  # realised too, so no base path is touched before everything the
  # generation runs from exists. The apply lock is held throughout.
  let previousStatic = readStaticTarget()
  let (treePath, treePrefixId) = realiseStaticTree(treeFiles)
  var closurePaths: seq[string]
  for p in plans:
    if p.r.kind == srkSystemdSystemUnit and p.r.suAptClosureLock.len > 0:
      closurePaths.add(realiseAptClosure(
        parseAptClosureLock(p.r.suAptClosureLock), AddOnSystemStoreRoot,
        AddOnAptDebCacheDir))
  var marker = PendingMarker(fromGeneration: previous.generation,
    newStatic: treePath, previousStatic: previousStatic, step: ssRealise,
    status: "in-progress")
  writePendingMarker(stateDir, marker)

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
    if p.r.kind == srkLinuxSysctl and p.verdict != $cvNoOp:
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
  var hookSysctl: seq[tuple[key, value: string]]
  var hookGeneration = ""

  proc beforeSet(planId: string) {.gcsafe.} =
    ## Steps 2 and 3: pre-stop, then flip. A refusal here (an exclusive
    ## unit that will not die) leaves the host in the old generation.
    {.cast(gcsafe).}:
      marker.planId = planId
      writePendingMarker(stateDir, marker)
      marker.stopped = runPreStop(transitions, disableOnRemoval)
      marker.step = ssPreStop
      writePendingMarker(stateDir, marker)
      flipStatic(treePath)
      marker.step = ssFlip
      writePendingMarker(stateDir, marker)

  proc afterSet(generationId: string; clean: bool): seq[string] {.gcsafe.} =
    ## Steps 4 and 5 were the drivers'; now 6 (fragment tools), 7 (start)
    ## and 8 (confirm), then the ledger. A problem is a diagnostic that
    ## withholds the commit.
    {.cast(gcsafe).}:
      var problems: seq[string]
      hookGeneration = generationId
      marker.step = ssCopies
      writePendingMarker(stateDir, marker)
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
      # --- Step 7: start. Only after a clean step 4-6: a half-written
      # generation is not started.
      if clean and problems.len == 0:
        try:
          runStart(transitions)
        except CatchableError as ex:
          problems.add("step 7 (start): " & ex.msg)
      marker.step = ssStart
      writePendingMarker(stateDir, marker)
      # --- Step 8: confirm. No health checks in this release (A5): the
      # confirmation is that every step above reported no problem.
      marker.step = ssConfirm
      writePendingMarker(stateDir, marker)
      # Objects a removed resource adopted or replaced go back to what they
      # were; the rest were destroyed by the infra apply.
      var needReload = needReloadAfterRemoval
      var unitsToRestore: seq[LedgerEntry]
      for e in restore:
        if observeDrift(e).len > 0:
          continue                 # changed meanwhile: left, as drift
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
            if e.class == lcUnit: unitsToRestore.add(e)
        except CatchableError as ex:
          problems.add("restoring " & e.path & ": " & ex.msg)
      if needReload:
        try: daemonReload()
        except CatchableError as ex:
          problems.add(ex.msg)
      for e in unitsToRestore:
        try: restoreUnitState(e)
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
        for e in entriesFor(p, previous.entries):
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
      writeFileAtomic(userProfilePath(stateDir), userText, 0o600)
      problems

  var infraError = ""
  try:
    result.infra = runInfraApply(composedText, ApplyOptions(
      stateDir: stateDir, hostIdentity: opts.hostIdentity,
      noPreview: true, elevationMode: emBroker,
      extraDestroyResources: destroy,
      preWriteGuard: makePreWriteGuard(driver, targets),
      addOnDispatch: policy,
      phases: ApplyPhaseHooks(beforePrivilegedSet: beforeSet,
                              afterPrivilegedSet: afterSet,
                              commitOnlyWhenClean: true)))
    if result.infra.errorCount > 0 or result.infra.driftCount > 0:
      infraError = "repro infra apply reported " & $result.infra.errorCount &
        " error(s) and " & $result.infra.driftCount & " drift finding(s):\n  " &
        result.infra.diagnostics.join("\n  ")
  except EAddOn as e:
    # A refusal decided before anything was switched (an exclusive unit
    # that would overlap): the old generation stands, the marker goes.
    clearPendingMarker(stateDir)
    releasePendingRoot()
    raise e
  except CatchableError as e:
    infraError = "repro infra apply failed: " & e.msg
  result.generationId = hookGeneration
  result.ledger = newLedger
  result.restored = hookRestored
  result.sysctlObserved = hookSysctl

  if not result.infra.committed:
    # Not a generation: `current` names the previous one, the marker
    # records how far the switch got and why it stopped, for the operator
    # and the re-assert unit. The ledger copy already describes what is
    # on the host.
    marker.status = "failed"
    marker.detail = infraError
    writePendingMarker(stateDir, marker)
    raise newException(AddonApplyError,
      (if infraError.len > 0: infraError else: "the switch did not " &
       "complete cleanly") & "\nthe generation was not committed; " &
      "`current` still names " & previous.generation &
      " and the pending marker at " & pendingMarkerPath(stateDir) &
      " records the step reached")

  # --- Step 9: committed by the infra apply; register the roots, apply
  # the retention policy, and clear the marker. ---
  var prefixIds: seq[PrefixIdBytes]
  for e in newLedger.entries:
    if e.class == lcStorePrefix:
      prefixIds.add(parsePrefixIdHex(e.sha256))
  block:
    enterWritableStoreView()
    var s = openStore(StoreRoot)
    defer: s.close()
    for path in closurePaths:
      let found = s.lookupPrefixByRealizedPath(path)
      if found.found: prefixIds.add(found.row.prefixId)
  registerGenerationRoot(result.generationId, prefixIds)
  releasePendingRoot()
  let retention = if opts.retention.keepGenerations == 0 and
                     opts.retention.keepDays == 0: DefaultRetention
                  else: opts.retention
  result.retentionDropped = pruneGenerationRoots(result.generationId,
    previous.generation, retention)
  marker.step = ssCommit
  writePendingMarker(stateDir, marker)
  clearPendingMarker(stateDir)

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
