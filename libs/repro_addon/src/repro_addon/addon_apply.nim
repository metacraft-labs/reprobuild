## The add-on layer over ``repro infra apply``.
##
## On an add-on host every generation is the add-on's own objects (its
## generation-0 set, kept in ``own.profile``) plus the operator's profile.
## This module composes the two, works out what left the profile, applies
## the result through ``repro_infra.runInfraApply`` -- the same apply path
## every system-scope host uses -- and records the outcome in the ownership
## ledger.
##
## What the layer adds to a plain infra apply:
##
## - **removal by ledger.** A resource that leaves the profile is removed
##   (as an infra destroy) only when the ledger lists its objects and they
##   still carry the recorded digests. A changed object makes the whole
##   apply refuse before anything is written: it is drift for a human to
##   review, not something to delete.
## - **the objects an apply creates as a side effect**: the parent
##   directories a file needed, the ``.wants`` links and directories
##   ``systemctl enable`` made, the mount a ``.mount`` unit holds, and the
##   package file a diversion moved aside. Each is a ledger entry, so
##   uninstall removes it and the do-no-harm gates can account for it.
## - **the store roots**: after every apply the new generation is registered
##   as a ``profile`` root holding the add-on's prefixes, and the previous
##   generation's root stays registered.

import std/[algorithm, os, sets, strutils, tables]

import repro_infra
import repro_local_store/store

import ./fingerprint
import ./generation0
import ./ledger
import ./mutations
import ./store_root

type
  AddonApplyError* = object of CatchableError
  AddonDriftError* = object of AddonApplyError
    ## An object the ledger owns changed outside the add-on; nothing was
    ## written.

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

  AddonApplyResult* = object
    generationId*: string
    previousGenerationId*: string
    ledger*: Ledger
    previousLedger*: Ledger
    removed*: seq[string]          ## resource addresses removed
    infra*: ApplyResult

const
  DefaultStateDir* = "/var/lib/repro/system"

proc addonDir*(stateDir: string): string = stateDir / "addon"
proc ledgerCopyPath*(stateDir: string): string = stateDir / "addon-ledger"
proc ownProfilePath*(stateDir: string): string = addonDir(stateDir) / "own.profile"
proc userProfilePath*(stateDir: string): string = addonDir(stateDir) / "user.profile"
proc generationLedgerPath*(stateDir, generationId: string): string =
  stateDir / "generations" / generationId / "addon-ledger"

proc isAddonHost*(stateDir = DefaultStateDir): bool =
  ## An add-on host is one whose state directory holds the ledger copy.
  fileExists(ledgerCopyPath(stateDir))

proc readHostname*(): string =
  try: readFile("/proc/sys/kernel/hostname").strip()
  except IOError, OSError: "localhost"

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
  PreState = object
    replaced: string
    newDirs: seq[string]

proc preObserve(r: SystemResource): PreState =
  case r.kind
  of srkFsSystemFile:
    result.replaced = baseValue(r.sfPath)
    result.newDirs = missingParents(r.sfPath)
  of srkSystemdSystemUnit:
    result.replaced = baseValue(unitPath(r.suName))
    if r.suEnabled:
      for l in installLinkPaths(r.suName, r.suContent):
        if not dirExists(l.dir) and l.dir notin result.newDirs:
          result.newDirs.add(l.dir)
  of srkLinuxDpkgDiversion:
    result.replaced = baseValue(r.ddPath)
  else:
    discard

# ---------------------------------------------------------------------------
# Ledger construction after the apply.
# ---------------------------------------------------------------------------

proc fileEntry(class: LedgerClass; path, resource, replaced: string):
    LedgerEntry =
  let st = statOwner(path)
  LedgerEntry(class: class, path: path, sha256: sha256OfFile(path),
              mode: st.mode, owner: st.owner, replaced: replaced,
              resource: resource)

proc dirEntry(path, resource: string): LedgerEntry =
  let st = statOwner(path)
  LedgerEntry(class: lcDir, path: path, mode: st.mode, owner: st.owner,
              resource: resource)

const AddonManagedKinds* = {srkFsSystemFile, srkSystemdSystemUnit,
                            srkLinuxDpkgDiversion}
  ## The resource kinds an add-on generation may declare in this release:
  ## the ``etcFile``, ``unit`` and ``diversion`` ownership classes. The other
  ## classes (drop-ins, sysusers, tmpfiles, sysctl, firewall, network) are
  ## added by the milestones that implement their ledger semantics.

proc unmanagedKindReason*(r: SystemResource): string =
  ## "" when the add-on manages ``r.kind``; otherwise the refusal text.
  if r.kind in AddonManagedKinds: ""
  else: "resource kind " & $r.kind & " is not managed by the add-on in " &
        "this release (" & r.address & "); nothing was applied"

proc entriesFor(r: SystemResource; pre: PreState;
                previous: seq[LedgerEntry]): seq[LedgerEntry] =
  ## The ledger entries of one applied resource. Entries the previous
  ## ledger already holds for the same resource keep what was recorded
  ## when the add-on first touched the object (the replaced value, the
  ## directories it created), because only that first observation saw the
  ## base.
  var prevDirs: seq[LedgerEntry]
  var prevReplaced = ""
  var known = false
  for e in previous:
    if e.resource == r.address:
      known = true
      if e.class == lcDir: prevDirs.add(e)
      if e.class in {lcEtcFile, lcUnit, lcDiversion}: prevReplaced = e.replaced
  let replaced = if known: prevReplaced else: pre.replaced
  if known:
    for d in prevDirs:
      if dirExists(d.path): result.add(d)
  else:
    for d in pre.newDirs:
      if dirExists(d): result.add(dirEntry(d, r.address))
  case r.kind
  of srkFsSystemFile:
    if fileExists(r.sfPath):
      result.add(fileEntry(lcEtcFile, r.sfPath, r.address, replaced))
  of srkSystemdSystemUnit:
    let p = unitPath(r.suName)
    if fileExists(p):
      var u = fileEntry(lcUnit, p, r.address, replaced)
      u.unit = r.suName
      u.enabled = r.suEnabled
      u.started = r.suEnabled
      u.hasInstall = hasInstallSection(r.suContent)
      result.add(u)
      if r.suEnabled:
        for l in installLinkPaths(r.suName, r.suContent):
          if symlinkExists(l.link):
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
                           replaced: replaced, resource: r.address))
  else:
    # Unreachable after the kind check above; kept so a future kind cannot
    # be applied without a ledger entry.
    raise newException(AddonApplyError, unmanagedKindReason(r))

# ---------------------------------------------------------------------------
# The apply.
# ---------------------------------------------------------------------------

proc removalRank(r: SystemResource): int =
  ## Destroy order: units stop first (nothing still uses their files),
  ## then files, then the diversions those files filled (a diversion can
  ## only be removed once the path it diverts is free again).
  case r.kind
  of srkSystemdSystemUnit: 0
  of srkFsSystemFile: 1
  of srkLinuxDpkgDiversion: 2
  else: 3

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

proc runAddonApply*(opts: AddonApplyOptions): AddonApplyResult =
  ## Apply one add-on generation. Raises ``AddonDriftError`` (nothing
  ## written) when a removal would delete a changed object, and
  ## ``AddonApplyError`` when the infra apply reports an error -- after
  ## recording, in the ledger, every object that apply did create, so
  ## uninstall still finds them.
  let stateDir = if opts.stateDir.len > 0: opts.stateDir else: DefaultStateDir
  enterWritableStoreView()
  createDir(addonDir(stateDir))
  # One apply at a time per state directory (the same lock `repro infra
  # apply` takes). A caller that already holds it -- the full engine's CLI
  # -- is not asked to take it twice.
  var ownLock = false
  if applyLockOwner(stateDir) != getCurrentProcessId():
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
  var ownAddresses = initHashSet[string]()
  for r in own.resources: ownAddresses.incl(r.address)
  for r in user.resources:
    if r.address in ownAddresses:
      raise newException(AddonApplyError, "the profile declares " &
        r.address & ", which is one of the add-on's own objects")
  let composedText = ownText & "\n" & opts.userProfileText
  let composed = parseSystemProfile(composedText)
  # Every kind is checked BEFORE anything is observed or written: a kind the
  # add-on does not manage must refuse the whole apply, not be applied by
  # the infra layer and then fail when the ledger is built (which would
  # leave an unledgered object behind for uninstall to miss).
  when not mutated("apply-skips-kind-check"):
    for r in composed.resources:
      let why = unmanagedKindReason(r)
      if why.len > 0:
        raise newException(AddonApplyError, why)
  var wanted = initHashSet[string]()
  for r in composed.resources: wanted.incl(r.address)

  # What left the profile, and may it be removed?
  var removed: seq[SystemResource]
  if previousUserText.len > 0:
    for r in parseSystemProfile(previousUserText).resources:
      if r.address notin wanted:
        removed.add(r)
  removed.sort(proc(a, b: SystemResource): int =
    cmp(removalRank(a), removalRank(b)))
  var drift: seq[string]
  for r in removed:
    for e in previous.entries:
      if e.resource == r.address:
        let d = observeDrift(e)
        if d.len > 0:
          drift.add(e.path & ": " & d)
  if drift.len > 0:
    raise newException(AddonDriftError,
      "refusing to remove objects that changed since the add-on wrote them " &
      "(actionable drift; nothing was written):\n  " & drift.join("\n  "))
  for r in removed: result.removed.add(r.address)

  # Observe what each newly declared resource will displace or create.
  var pre = initTable[string, PreState]()
  for r in composed.resources:
    pre[r.address] = preObserve(r)

  var infraError = ""
  try:
    result.infra = runInfraApply(composedText, ApplyOptions(
      stateDir: stateDir, hostIdentity: opts.hostIdentity,
      noPreview: true, elevationMode: emBroker,
      extraDestroyResources: removed))
    if result.infra.errorCount > 0 or result.infra.driftCount > 0:
      infraError = "repro infra apply reported " & $result.infra.errorCount &
        " error(s) and " & $result.infra.driftCount & " drift finding(s):\n  " &
        result.infra.diagnostics.join("\n  ")
  except CatchableError as e:
    infraError = "repro infra apply failed: " & e.msg
  result.generationId = readCurrentGenerationId(stateDir)

  # Directories the removed resources had created.
  var removedEntries: seq[LedgerEntry]
  var removedSet = initHashSet[string]()
  for a in result.removed: removedSet.incl(a)
  for e in previous.entries:
    if e.resource in removedSet: removedEntries.add(e)
  removeEmptyDirs(removedEntries)

  # The new ledger.
  var l = Ledger(generation: result.generationId)
  for e in previous.entries:
    if e.resource.len == 0: l.entries.add(e)
  for e in opts.bootstrapEntries: l.entries.add(e)
  for r in composed.resources:
    for e in entriesFor(r, pre.getOrDefault(r.address), previous.entries):
      l.entries.add(e)
  # A removed resource whose objects are still there (a destroy that
  # failed) stays in the ledger, so nothing it created is orphaned.
  for e in removedEntries:
    let stillThere = case e.class
      of lcEtcFile, lcUnit: fileExists(e.path)
      of lcInstallLink: symlinkExists(e.path)
      of lcDir: dirExists(e.path)
      else: false
    if stillThere: l.entries.add(e)
  result.ledger = l

  if result.generationId.len > 0 and
      result.generationId != previous.generation:
    createDir(parentDir(generationLedgerPath(stateDir, result.generationId)))
    writeLedger(generationLedgerPath(stateDir, result.generationId), l)
  writeLedger(ledgerCopyPath(stateDir), l)
  writeFileAtomic(ownProfilePath(stateDir), ownText, 0o600)
  writeFileAtomic(userProfilePath(stateDir), opts.userProfileText, 0o600)

  if infraError.len > 0:
    raise newException(AddonApplyError, infraError)

  # Store roots: the new generation holds every prefix the ledger names.
  var prefixIds: seq[PrefixIdBytes]
  for e in l.entries:
    if e.class == lcStorePrefix:
      var id: PrefixIdBytes
      if e.sha256.len != 2 * id.len:
        raise newException(AddonApplyError, "malformed store prefix id in " &
          "the ledger: " & e.sha256)
      for i in 0 ..< id.len:
        id[i] = byte(parseHexInt(e.sha256[2 * i .. 2 * i + 1]))
      prefixIds.add(id)
  registerGenerationRoot(result.generationId, prefixIds)
