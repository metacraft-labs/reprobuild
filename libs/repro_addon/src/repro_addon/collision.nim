## The collision observer and the decision table of add-on mode.
##
## Before the add-on writes an object into a distribution's ``/etc`` it
## asks the distribution's own records who owns the target: does an
## installed package list the path (and is it a conffile), is the path
## diverted, and does a package already provide a unit of that name. Each
## answer comes from the distribution's database, never from a guess, and
## the answers decide, per object, between creating, updating, adopting
## and refusing.
##
## **The observer is a per-distribution driver.** The decision table is
## the same on every base; only the three observations differ. The dpkg
## driver here reads ``/var/lib/dpkg/info/*.list`` and ``*.conffiles``
## (``dpkg-query -S`` semantics), the diversion database
## ``/var/lib/dpkg/diversions`` (``dpkg-divert --list`` semantics) and
## unit provision through ``systemctl show``. A pacman driver reads the
## local package database instead and has no diversions; it plugs in
## behind the same ``CollisionDriver`` record.
##
## **It runs twice.** Once at plan time, to decide and to fill the plan's
## collision report; and once more immediately before each write, as the
## apply's ``PreWriteGuard``: the same observation is taken again and a
## difference from what the plan decided on (a package installed in
## between, a link planted on the path, a changed file) refuses that
## write. Nothing is ever written on the strength of a stale observation.
##
## **Links are refused by name.** A target path with a symbolic link
## anywhere in it is refused at plan time, naming the link (threat model
## G29): the write that follows would otherwise land wherever the link
## points, outside the allowlist that checked only the path's text.
##
## Falsifying mutations (``mutations.nim``): ``observer-never-package-owned``
## answers "no package owns it" for every path, so the conffile and
## package-unit rows must go red; ``observer-checks-path-text-only``
## skips the link check, so the symlink gate must go red.

import std/[os, posix, sets, strutils, tables]

import repro_elevation
import repro_infra/addon_diagnostics
import repro_infra/profile

import ./etc_write
import ./fingerprint
import ./host_exec
import ./mutations
import ./static_tree

type
  PackageOwnership* = object
    package*: string      ## "" when no installed package lists the path
    conffile*: bool       ## the package declares it a conffile
    viaUcf*: bool         ## the package manages it through ``ucf`` (Debian:
                          ## registered in ``/var/lib/ucf/registry``, in no
                          ## dpkg record), the fourth ownership record

  DiversionRecord* = object
    present*: bool
    divertTo*: string
    package*: string      ## ":" for a local diversion

  UnitProvision* = object
    loadState*: string      ## loaded / not-found / masked / ...
    fragmentPath*: string   ## the unit file systemd loads, "" if none
    dropInPaths*: seq[string]
    unitFileState*: string  ## enabled / disabled / static / ... / ""
    activeState*: string    ## active / inactive / failed / ...
    needDaemonReload*: bool
      ## systemd's loaded definition is older than the unit's files on disk
      ## (``NeedDaemonReload``). Read fail-safe: anything but an explicit
      ## ``no`` counts as stale, because the one consumer (an adopted unit's
      ## restart decision) must restart when it cannot tell.

  CollisionDriver* = ref object
    ## The per-distribution observations (spec §4.3, §4.3.1).
    name*: string
    packageOwner*: proc(path: string): PackageOwnership {.gcsafe.}
    diversion*: proc(path: string): DiversionRecord {.gcsafe.}
    unitProvision*: proc(unit: string): UnitProvision {.gcsafe.}
    dropInHint*: proc(path: string): string {.gcsafe.}
      ## A drop-in directory the program behind ``path`` is known to
      ## read, or "".
    diversionTarget*: proc(path: string): string {.gcsafe.}
      ## Where this distribution's diversion of ``path`` sends the
      ## package's copy (dpkg: ``<path>.distrib``). "" on a base without
      ## diversions.
    supportsDiversions*: bool
      ## dpkg has ``dpkg-divert``; pacman does not, and the plan says so
      ## by name when the ``divert`` opt-in is asked for.

  AddonCollisionError* = object of CatchableError
    ## A refusal of the decision table that has no typed add-on
    ## diagnostic of its own: a symlink component, a foreign diversion,
    ## a diversion opt-in on a base without diversions.

  AddonDriftError* = object of CatchableError
    ## ``EDrift``: an object the add-on does not own differs from what the
    ## profile declares (or one it owns changed since it was written).
    ## Nothing was written.

  CollisionVerdict* = enum
    cvCreate = "create"       ## absent, unowned: write it
    cvUpdate = "update"       ## the ledger owns it, digest matches
    cvNoOp = "no-op"          ## the ledger owns it and it already matches
    cvAdopt = "adopt"         ## unowned, identical (or claimed): record only
    cvDivert = "divert"       ## package-owned, diverted first (opt-in)
    cvDropIn = "drop-in"      ## package unit, changed by a drop-in (opt-in)
    cvReplace = "replace"     ## package unit, shadowed by an /etc unit (opt-in)
    cvReconcile = "reconcile" ## differing unowned bytes replaced, preserved

  CollisionDecision* = object
    verdict*: CollisionVerdict
    observation*: string
      ## The package-ownership observation, as the ledger records it:
      ## ``absent``, ``unowned``, ``package:<pkg>``, ``conffile:<pkg>``,
      ## ``unit:<fragmentPath>``, ``diversion:<pkg>``.
    observedSha256*: string
      ## The target's content digest when it exists, else "".
    preWriteBytes*: string
      ## The bytes the write will replace, when the verdict preserves
      ## them (adopt, reconcile): the ledger keeps them.
    reason*: string
      ## One line for the collision report.

  CollisionLine* = object
    address*: string
    target*: string
    observation*: string
    verdict*: string
    reason*: string

const
  DpkgInfoDir* = "/var/lib/dpkg/info"
  UcfRegistry* = "/var/lib/ucf/registry"
    ## ``ucf``'s registry: one ``<package> <path>`` line per file a
    ## package's maintainer scripts manage through ``ucf`` (openssh-server's
    ## ``/etc/ssh/sshd_config`` on Debian 13 and Ubuntu 24.04). Such a file
    ## is package-owned without being in any dpkg record.
  PackageUnitDirs* = ["/usr/lib/systemd/system/", "/lib/systemd/system/"]
    ## Where a package's unit lives. A ``FragmentPath`` below one of
    ## these, with no ``/etc`` unit of the same name, is the
    ## ``EAddOnUnitShadows`` row. ``/usr/local/lib/systemd/system`` is the
    ## local administrator's, not a package's: a unit there is refused
    ## with no opt-in, like a transient or generated one (see
    ## ``classifyUnit``).

type
  UnitClass* = enum
    ## Where systemd loads a unit from, as the decision table sees it.
    ucNone = "none"           ## no unit of that name is loaded
    ucEtc = "etc"             ## ``/etc/systemd/system``: the add-on's or a hand-written one
    ucPackage = "package"     ## a package unit directory
    ucMasked = "masked"       ## masked (permanently or at runtime)
    ucElsewhere = "elsewhere" ## transient (``/run/systemd/system``), generated, or local
                              ## (``/usr/local/lib``): shadowing it silently is wrong,
                              ## and no opt-in covers it

proc classifyUnit*(u: UnitProvision): UnitClass =
  if u.loadState.startsWith("masked"):
    return ucMasked
  if u.fragmentPath.len == 0:
    return ucNone
  if u.fragmentPath.startsWith(SystemdSystemUnitDir & "/"):
    return ucEtc
  for d in PackageUnitDirs:
    if u.fragmentPath.startsWith(d): return ucPackage
  ucElsewhere

proc isPackageUnit*(u: UnitProvision): bool =
  ## Does a package provide the unit (its fragment is under a package
  ## unit directory)?
  for d in PackageUnitDirs:
    if u.fragmentPath.startsWith(d): return true
  false

proc dropInPath*(unit, dropInName: string): string =
  ## ``/etc/systemd/system/<unit>.d/50-repro-<name>.conf`` (spec §4.1).
  let name = if dropInName.len > 0: dropInName else: "addon"
  SystemdSystemUnitDir & "/" & unit & ".d/50-repro-" & name & ".conf"

# ---------------------------------------------------------------------------
# The dpkg driver.
# ---------------------------------------------------------------------------

type
  DpkgIndex = ref object
    owner: Table[string, string]     ## path -> package
    conffiles: HashSet[string]
    ucf: Table[string, string]       ## path -> package, from ucf's registry
    loaded: bool
    stamp: string                    ## ``indexStamp`` the tables were read at

proc parseUcfRegistry*(text: string): Table[string, string] =
  ## ``<package> <path>`` lines of ``/var/lib/ucf/registry`` -> path ->
  ## package. Blank lines and lines without an absolute path are skipped.
  for line in text.splitLines():
    let f = line.splitWhitespace()
    if f.len >= 2 and f[1].len > 1 and f[1][0] == '/':
      result[f[1]] = f[0]

proc packageNameOfInfoFile(fileName: string): string =
  ## ``bash.list`` -> ``bash``; ``libc6:amd64.list`` -> ``libc6`` (the
  ## architecture qualifier names an instance, not the package).
  var n = fileName
  n = n[0 ..< n.rfind('.')]
  let colon = n.find(':')
  if colon > 0: n = n[0 ..< colon]
  n

proc statStamp(path: string): string =
  ## Inode, size, modification and status-change times of ``path``
  ## (nanoseconds), or ``absent``.
  var st: Stat
  if lstat(path.cstring, st) != 0:
    return "absent"
  $st.st_ino & ":" & $st.st_size & ":" & $int64(st.st_mtim.tv_sec) & "." &
    $st.st_mtim.tv_nsec & ":" & $int64(st.st_ctim.tv_sec) & "." & $st.st_ctim.tv_nsec

proc indexStamp*(root: string): string =
  ## What the package index depends on, cheaply: the stamp of the
  ## ``info`` directory and of ucf's registry.
  ##
  ## Why the directory's stamp covers every ``*.list`` and ``*.conffiles``
  ## file: dpkg never rewrites one of them in place. A file list is
  ## written to ``<pkg>.list-new`` and renamed over ``<pkg>.list``
  ## (dpkg's atomic-file writer), control files such as ``*.conffiles``
  ## are unpacked to ``/var/lib/dpkg/tmp.ci`` and renamed into ``info``,
  ## and a removal unlinks them -- each of which changes the directory's
  ## entries and so its modification and status-change times
  ## (rename(2), unlink(2)). ucf's ``ucfr`` replaces its registry by
  ## writing a temporary file and renaming it, which changes the
  ## registry's inode. dpkg's ``status`` file (rewritten by rename on
  ## every package state change) and the diversion database are stamped
  ## too, so a package operation is seen even where a filesystem's
  ## coarse timestamps (one-second or worse) could leave the directory's
  ## times unchanged across two renames within the same tick: the status
  ## file's inode changes with every rewrite. Known limit (spec §4.3): an
  ## in-place edit of a ``*.list`` file that changes neither its inode,
  ## its size nor any of the stamped times is not seen until the next
  ## change of one of them; dpkg never edits a list in place.
  statStamp(root / DpkgInfoDir) & "|" & statStamp(root / UcfRegistry) &
    "|" & statStamp(root / "/var/lib/dpkg/status") & "|" &
    statStamp(root / DpkgDiversionsDb)

proc loadDpkgIndex(root: string; idx: DpkgIndex) =
  ## Every installed package's file list. The lists name the paths as
  ## installed (dpkg strips nothing), so a lookup is an exact match on the
  ## path text -- which is why every target path is canonical before it
  ## gets here (``nonCanonicalPathError``).
  ##
  ## The tables are read again whenever ``indexStamp`` changed since they
  ## were read, so the observer the apply keeps for its whole run still
  ## sees a package installed between the plan and a write (the guard's
  ## per-operation freshness) without re-reading every list for every
  ## operation.
  ##
  ## A missing ``info`` directory refuses (fail closed): with no file
  ## lists every path would read as unowned, and the add-on would write
  ## over package files believing nobody owns them.
  let stamp = indexStamp(root)
  if idx.loaded and stamp == idx.stamp: return
  let dir = root / DpkgInfoDir
  if not dirExists(dir):
    raise newException(AddonCollisionError, "the dpkg package database " &
      "is incomplete: " & dir & " does not exist, so package ownership " &
      "cannot be observed; nothing is decided without it")
  idx.owner = initTable[string, string]()
  idx.conffiles = initHashSet[string]()
  idx.ucf = initTable[string, string]()
  idx.loaded = true
  idx.stamp = stamp
  for f in walkFiles(dir / "*.list"):
    let pkg = packageNameOfInfoFile(extractFilename(f))
    for line in readFile(f).splitLines():
      if line.len > 1 and line[0] == '/':
        idx.owner[line] = pkg
  for f in walkFiles(dir / "*.conffiles"):
    for raw in readFile(f).splitLines():
      # A conffile line is the path, optionally preceded by a flag such as
      # ``remove-on-upgrade`` (dpkg >= 1.20) or followed by ``obsolete``.
      for tok in raw.splitWhitespace():
        if tok.len > 1 and tok[0] == '/':
          idx.conffiles.incl(tok)
          break
  let registry = root / UcfRegistry
  if fileExists(registry):
    idx.ucf = parseUcfRegistry(readFile(registry))

proc parseSystemctlShow*(text: string): Table[string, string] =
  ## ``Key=Value`` lines of ``systemctl show``.
  for line in text.splitLines():
    let eq = line.find('=')
    if eq > 0:
      result[line[0 ..< eq]] = line[eq + 1 .. ^1]

proc unitProvisionFromShow*(text: string): UnitProvision =
  let kv = parseSystemctlShow(text)
  result.loadState = kv.getOrDefault("LoadState")
  result.fragmentPath = kv.getOrDefault("FragmentPath")
  for p in kv.getOrDefault("DropInPaths").splitWhitespace():
    result.dropInPaths.add(p)
  result.unitFileState = kv.getOrDefault("UnitFileState")
  result.activeState = kv.getOrDefault("ActiveState")
  result.needDaemonReload = kv.getOrDefault("NeedDaemonReload") != "no"

proc readUnitProvision*(unit: string): UnitProvision =
  ## ``systemctl show`` for one unit. Fails closed: a missing systemctl,
  ## a non-zero exit (no bus, systemd not answering) or an answer without
  ## ``LoadState`` raises ``AddonCollisionError`` instead of reading as
  ## "no unit of that name" -- which the decision table would take for
  ## permission to create an /etc unit over whatever really provides it.
  ## (A unit that does not exist is not an error: systemctl answers 0
  ## with ``LoadState=not-found``.)
  var r: HostToolResult
  try:
    r = runSystemctl(["show", "-p",
      "LoadState,FragmentPath,DropInPaths,UnitFileState,ActiveState," &
        "NeedDaemonReload",
      "--", unit])
  except HostToolMissing as e:
    raise newException(AddonCollisionError, "cannot observe unit " & unit &
      ": " & e.msg)
  if r.exitCode != 0:
    raise newException(AddonCollisionError, "cannot observe unit " & unit &
      ": systemctl show exited " & $r.exitCode & ": " & r.output.strip())
  result = unitProvisionFromShow(r.output)
  if result.loadState.len == 0:
    raise newException(AddonCollisionError, "cannot observe unit " & unit &
      ": systemctl show reported no LoadState: " & r.output.strip())

proc newDpkgDriver*(root = "/"; unitProvision: proc(unit: string):
                    UnitProvision {.gcsafe.} = nil): CollisionDriver =
  ## The Debian/Ubuntu observer. ``root`` relocates the dpkg database for
  ## tests over a fixture tree; ``unitProvision`` replaces the
  ## ``systemctl`` query there (the build host has no guest's systemd).
  let idx = DpkgIndex()
  let rootDir = root
  result = CollisionDriver(name: "dpkg", supportsDiversions: true)
  result.packageOwner = proc(path: string): PackageOwnership =
    when mutated("observer-never-package-owned"):
      return PackageOwnership()
    else:
      loadDpkgIndex(rootDir, idx)
      if path in idx.owner:
        PackageOwnership(package: idx.owner[path],
                         conffile: path in idx.conffiles)
      elif path in idx.ucf:
        PackageOwnership(package: idx.ucf[path], conffile: true, viaUcf: true)
      else:
        PackageOwnership()
  result.diversion = proc(path: string): DiversionRecord =
    let db = rootDir / DpkgDiversionsDb
    if not fileExists(db): return DiversionRecord()
    let d = readDpkgDiversion(readFile(db), path)
    DiversionRecord(present: d.present, divertTo: d.divertTo, package: d.package)
  if unitProvision != nil:
    result.unitProvision = unitProvision
  else:
    result.unitProvision = proc(unit: string): UnitProvision =
      readUnitProvision(unit)
  when mutated("observer-never-package-owned"):
    # FALSIFYING MUTATION: no package provenance at all -- a unit a package
    # provides is reported as provided by nobody.
    let real = result.unitProvision
    result.unitProvision = proc(unit: string): UnitProvision =
      var u = real(unit)
      if isPackageUnit(u):
        u.fragmentPath = ""
        u.loadState = "not-found"
      u
  result.dropInHint = proc(path: string): string =
    # Programs that read a `.d` directory beside their file (sshd's
    # `Include /etc/ssh/sshd_config.d/*.conf`, sudoers, ...) ship it.
    if dirExists(path & ".d"): path & ".d/" else: ""
  result.diversionTarget = proc(path: string): string =
    dpkgDiversionTarget(path)

proc detectCollisionDriver*(root = "/"): CollisionDriver =
  ## The driver for the host's distribution: dpkg where its database is.
  ## A status file without the ``info`` directory is a damaged database,
  ## refused rather than read as "nothing is owned" (``loadDpkgIndex``).
  if fileExists(root / "/var/lib/dpkg/status"):
    if not dirExists(root / DpkgInfoDir):
      raise newException(AddonCollisionError, "the dpkg package database " &
        "is incomplete: " & root / DpkgInfoDir & " does not exist")
    return newDpkgDriver(root)
  raise newAddOnUnsupportedBase("unknown",
    "no package database the collision observer can read (dpkg at " &
    "/var/lib/dpkg/status); pacman support is not in this release")

# ---------------------------------------------------------------------------
# Observing one target.
# ---------------------------------------------------------------------------

type
  TargetKind* = enum
    tkFile, tkUnit, tkDiversion

  TargetObservation* = object
    ## Everything the decision table looks at for one target path.
    path*: string
    linkComponent*: string     ## a symlink on the path, or ""
    ownLink*: bool             ## the leaf is the add-on's own link into
                               ## the static tree (`/etc/X ->
                               ## /etc/repro/static/X`, spec §7.2): not a
                               ## foreign link, and observed through it
    exists*: bool
    isRegular*: bool
    sha256*: string            ## of the file, when a regular file
    etcValue*: string          ## the fingerprint ``etc`` value, "" if absent
    ownership*: PackageOwnership
    diversion*: DiversionRecord
    unit*: UnitProvision       ## units only

proc observeTarget*(d: CollisionDriver; path: string;
                    unit = ""): TargetObservation =
  ## Read-only. ``unit`` names the systemd unit a ``tkUnit`` target is.
  result.path = path
  when not mutated("observer-checks-path-text-only"):
    result.linkComponent = symlinkComponent(path)
  # The add-on's own materialisation of this very path is not a foreign
  # link: a leaf link whose target is exactly `/etc/repro/static/<rel>`
  # is the previous generation's link-form object, read through (its
  # content is what the consumer sees) and never refused. Any other
  # target, or a link on a parent component, stays a refusal.
  if result.linkComponent == path and
      isStaticLinkTarget(path, readLinkNoFollow(path)):
    result.linkComponent = ""
    result.ownLink = true
  if result.ownLink:
    result.exists = true
    if fileExists(path):
      result.isRegular = true
      result.sha256 = sha256OfFile(path)
  elif symlinkExists(path):
    result.exists = true
  elif fileExists(path):
    result.exists = true
    result.isRegular = true
    result.sha256 = sha256OfFile(path)
  elif dirExists(path):
    result.exists = true
  if result.exists:
    result.etcValue = etcEntryValue(path)
  result.ownership = d.packageOwner(path)
  result.diversion = d.diversion(path)
  if unit.len > 0:
    result.unit = d.unitProvision(unit)

proc packageOfObservation*(observation: string): string =
  ## The package an ownership observation names (``package:``,
  ## ``conffile:``, ``ucf:``, ``diversion:``), or "".
  for pfx in ["package:", "conffile:", "ucf:", "diversion:"]:
    if observation.startsWith(pfx): return observation[pfx.len .. ^1]
  ""

proc observationText*(o: TargetObservation; kind: TargetKind): string =
  ## The ledger's one-word summary of who owns the target.
  if o.diversion.present and o.diversion.package != ":":
    return "diversion:" & o.diversion.package
  if o.ownership.package.len > 0:
    return (if o.ownership.viaUcf: "ucf:"
            elif o.ownership.conffile: "conffile:"
            else: "package:") & o.ownership.package
  if kind == tkUnit and o.unit.fragmentPath.len > 0 and
      not o.unit.fragmentPath.startsWith(SystemdSystemUnitDir & "/"):
    return "unit:" & o.unit.fragmentPath
  if o.exists: "unowned" else: "absent"

# ---------------------------------------------------------------------------
# The decision table (spec §4.3).
# ---------------------------------------------------------------------------

type
  DecisionInputs* = object
    address*: string
    kind*: TargetKind
    unit*: string              ## tkUnit: the unit name
    desiredSha256*: string     ## digest of the bytes the profile wants
    desiredContent*: string    ## the bytes themselves (for preservation)
    ledgerSha256*: string      ## the current ledger's digest, "" if unowned
    ledgerOwns*: bool
    ledgerObservation*: string ## the ledger entry's plan-time ownership
                               ## observation (``absent``, ``conffile:<pkg>``,
                               ## ...), "" if unowned
    ledgerOwnsDiversion*: bool ## the ledger lists a diversion of the path
    collision*: string         ## the resource's opt-in, "" for none
    divertedByProfile*: bool   ## a `linux.dpkgDiversion` of the path is declared
    reconcileDrift*: bool
    adopt*: bool               ## `repro system adopt` named this address

proc refuseLink(o: TargetObservation; address: string) =
  if o.linkComponent.len > 0:
    raise newException(AddonCollisionError, "refusing " & address & ": " &
      o.linkComponent & " is a symbolic link on the target path " & o.path &
      "; the add-on never writes through a link (threat model G29)")

proc refuseForeignDiversion(o: TargetObservation; address: string;
                            ownedByLedger: bool) =
  ## Someone else's diversion of the path: no opt-in exists. A diversion
  ## the ledger does not list is someone else's whatever its target is
  ## called -- a local diversion to ``<path>.distrib`` made by hand is not
  ## the add-on's because it spells its name the way the add-on would.
  if not o.diversion.present or ownedByLedger: return
  raise newException(AddonCollisionError, "refusing " & address & ": " &
    o.path & " is already diverted to " & o.diversion.divertTo & " by " &
    (if o.diversion.package == ":": "a local diversion the ledger does not list"
     else: "package " & o.diversion.package) &
    "; an existing diversion by someone else has no opt-in")

proc refuseUcfDivert(d: CollisionDriver; o: TargetObservation;
                     address: string) =
  ## A file a package manages through ucf cannot be diverted (owner
  ## decision 2026-10-30). ucf follows dpkg's diversions but keys its own
  ## records by the original path, so on the package's next upgrade it
  ## cannot tell the diverted copy is unmodified and withholds the new
  ## maintainer version as `<path>.distrib.ucf-dist`; undoing that on
  ## removal would mean writing ucf's private state (its hashfile and
  ## cache), which the add-on does not do. The plan refuses instead and
  ## names what does work: the program's drop-in directory when it reads
  ## one.
  if not o.ownership.viaUcf: return
  let hint = d.dropInHint(o.path)
  raise newException(AddonCollisionError, "refusing " & address & ": " &
    o.path & " is managed by package " & o.ownership.package &
    " through ucf (/var/lib/ucf/registry), and a ucf-managed file cannot " &
    "be diverted: ucf would withhold the package's next version of it " &
    "and the add-on does not write ucf's records to undo that. " &
    (if hint.len > 0: "Put the change in a drop-in under " & hint & " instead."
     else: "Change it through a drop-in or configuration directory the " &
           "program reads, or leave it to the package."))

proc decideFile(d: CollisionDriver; o: TargetObservation;
                inp: DecisionInputs): CollisionDecision =
  ## The file rows of the table, shared by ``etcFile`` targets and the
  ## drop-in file a ``collision = dropIn`` unit becomes.
  result.observation = observationText(o, tkFile)
  result.observedSha256 = o.sha256
  refuseLink(o, inp.address)
  refuseForeignDiversion(o, inp.address, inp.ledgerOwnsDiversion)
  if o.exists and not o.isRegular:
    raise newException(AddonCollisionError, "refusing " & inp.address &
      ": " & o.path & " exists and is not a regular file")
  # Row 2: the ledger owns it -- unless a package came to own the path
  # since (spec §4.3, §7.6, §7.8): that is a package-owned path, refused by
  # name until the operator resolves it, never absorbed by rewriting the
  # ledger's observation to the package's name. Removing the resource
  # hands the path back to the package (``handback.nim``).
  if inp.ledgerOwns and o.ownership.package.len > 0 and
      packageOfObservation(inp.ledgerObservation) != o.ownership.package:
    when not mutated("package-owner-absorbed"):
      var e = newAddOnPackageOwned(o.path, o.ownership.package,
                                   o.ownership.conffile, d.dropInHint(o.path))
      e.msg.add(" -- package " & o.ownership.package & " came to own this " &
        "ledger path after the add-on took it (" & inp.address &
        "). Remove the resource to hand the path back to the package, " &
        "then declare it again with `collision = \"divert\"` if the " &
        "add-on should still own its content")
      raise e
  if inp.ledgerOwns:
    if o.exists and o.sha256 == inp.ledgerSha256:
      result.verdict = (if o.sha256 == inp.desiredSha256: cvNoOp else: cvUpdate)
      result.reason = "owned by the ledger, digest matches"
      return
    if not o.exists:
      result.verdict = cvCreate
      result.reason = "owned by the ledger but missing; recreated"
      return
    if o.sha256 == inp.desiredSha256:
      # Changed out of band to exactly what this apply wants (a writer
      # outside the switch applied the same profile: the deploy agent
      # before it applied through the switch, §9 "Migration"). Nothing
      # conflicts and nothing is written; the ledger records the bytes.
      result.verdict = cvNoOp
      result.reason = "owned by the ledger, changed out of band to the " &
        "profile's content; recorded as it is"
      return
    if inp.reconcileDrift:
      result.verdict = cvReconcile
      result.preWriteBytes = readFile(o.path)
      result.reason = "owned by the ledger but changed out of band; " &
        "--reconcile-drift replaces it and preserves the current bytes"
      return
    # A package that unpacked its own file over the add-on's names
    # itself here (spec §7.6: "the next plan shows actionable drift with
    # the package named").
    let byPackage =
      if o.ownership.package.len > 0: "; package " & o.ownership.package &
        " now ships this path" & (if o.ownership.conffile: " (conffile)"
                                  else: "")
      else: ""
    raise newException(AddonDriftError, "EDrift: " & o.path &
      " (" & inp.address & ") is owned by the ledger but its content " &
      "changed out of band" & byPackage & " (sha256 " & o.sha256[0 ..< 12] & ", ledger " &
      inp.ledgerSha256[0 ..< min(12, inp.ledgerSha256.len)] & "); " &
      "review it, then re-run with --reconcile-drift to replace it " &
      "(the current bytes are kept in the ledger)")
  # Package-owned rows.
  if o.ownership.package.len > 0:
    let optIn = inp.collision == "divert" or inp.divertedByProfile
    if not optIn:
      raise newAddOnPackageOwned(o.path, o.ownership.package,
                                 o.ownership.conffile, d.dropInHint(o.path))
    if not d.supportsDiversions:
      raise newException(AddonCollisionError, "refusing " & inp.address &
        ": " & o.path & " is owned by package " & o.ownership.package &
        " and the " & d.name & " base has no diversions; `collision = " &
        "\"divert\"` is unavailable here")
    refuseUcfDivert(d, o, inp.address)
    result.verdict = cvDivert
    result.reason = "owned by package " & o.ownership.package &
      (if o.ownership.conffile: " (conffile)" else: "") &
      "; diverted to " & d.diversionTarget(o.path) & " by opt-in"
    return
  # Unowned rows.
  if not o.exists:
    result.verdict = cvCreate
    result.reason = "absent, no package owns it"
    return
  if o.sha256 == inp.desiredSha256:
    result.verdict = cvAdopt
    result.preWriteBytes = readFile(o.path)
    result.reason = "present, unowned, identical to the profile: adopted " &
      "without writing"
    return
  if inp.adopt:
    result.verdict = cvAdopt
    result.preWriteBytes = readFile(o.path)
    result.reason = "present, unowned, claimed by `repro system adopt`: " &
      "its current bytes become the add-on's"
    return
  if inp.reconcileDrift:
    result.verdict = cvReconcile
    result.preWriteBytes = readFile(o.path)
    result.reason = "present, unowned, differs; --reconcile-drift replaces " &
      "it and preserves the current bytes"
    return
  raise newException(AddonDriftError, "EDrift: " & o.path & " (" &
    inp.address & ") exists, no package owns it and the ledger does not " &
    "list it, and its content differs from the profile (sha256 " &
    o.sha256[0 ..< 12] & "); `repro system adopt " & inp.address &
    "` claims it as it is, or --reconcile-drift replaces it and keeps " &
    "the old bytes in the ledger")

proc decide*(d: CollisionDriver; inp: DecisionInputs;
             path: string): tuple[decision: CollisionDecision,
                                  observed: TargetObservation] =
  ## Observe ``path`` for the resource ``inp`` describes and decide. Raises
  ## a typed refusal; nothing is written by this proc or on its account.
  case inp.kind
  of tkFile:
    let o = observeTarget(d, path)
    (decideFile(d, o, inp), o)
  of tkDiversion:
    let o = observeTarget(d, path)
    var dec = CollisionDecision(observation: observationText(o, tkFile),
                                observedSha256: o.sha256)
    refuseLink(o, inp.address)
    refuseForeignDiversion(o, inp.address, inp.ledgerOwns)
    if not d.supportsDiversions:
      raise newException(AddonCollisionError, "refusing " & inp.address &
        ": the " & d.name & " base has no diversions")
    if o.ownership.package.len == 0:
      raise newException(AddonCollisionError, "refusing " & inp.address &
        ": no installed package owns " & path & "; a diversion is only " &
        "for a package-owned path (declare the file as an fs.systemFile)")
    refuseUcfDivert(d, o, inp.address)
    if o.diversion.present:
      # Only reachable when the ledger owns it (a foreign one was refused).
      dec.verdict = cvNoOp
      dec.reason = "the add-on's diversion to " & o.diversion.divertTo
    else:
      dec.verdict = cvCreate
      dec.reason = "owned by package " & o.ownership.package & "; diverted"
    (dec, o)
  of tkUnit:
    let o = observeTarget(d, path, inp.unit)
    var dec = CollisionDecision(observation: observationText(o, tkUnit),
                                observedSha256: o.sha256)
    refuseLink(o, inp.address)
    # Someone else's diversion of the /etc unit path refuses it whether or
    # not a file is there now (a diversion of an absent path is still
    # dpkg's promise to put the package's file elsewhere).
    refuseForeignDiversion(o, inp.address, inp.ledgerOwnsDiversion)
    if o.ownership.package.len > 0:
      raise newAddOnPackageOwned(o.path, o.ownership.package,
                                 o.ownership.conffile, "")
    let cls = classifyUnit(o.unit)
    let packageUnit = cls == ucPackage
    case cls
    of ucMasked:
      raise newException(AddonCollisionError, "refusing " & inp.address &
        ": " & inp.unit & " is masked (" & o.unit.loadState &
        "); the add-on does not write over a mask")
    of ucElsewhere:
      raise newException(AddonCollisionError, "refusing " & inp.address &
        ": " & inp.unit & " is loaded from " & o.unit.fragmentPath &
        ", a transient, generated or local unit outside the package and " &
        "/etc directories; an /etc unit would shadow it silently and no " &
        "opt-in covers that")
    else:
      discard
    if inp.collision == "dropIn":
      # The unit itself is not written; the drop-in file is decided by
      # the file rows. Here: what the drop-in modifies, which must exist.
      if cls == ucNone:
        raise newException(AddonCollisionError, "refusing " & inp.address &
          ": nothing provides " & inp.unit & ", so a drop-in has nothing " &
          "to modify; declare the unit itself")
      dec.verdict = cvDropIn
      dec.reason =
        if packageUnit: "package unit at " & o.unit.fragmentPath &
          "; changed by a drop-in"
        else: "unit at " & o.unit.fragmentPath & "; changed by a drop-in"
      return (dec, o)
    if o.exists:
      # An /etc unit of that name exists: the file rows apply to it.
      var fileInp = inp
      fileInp.kind = tkFile
      var fdec = decideFile(d, o, fileInp)
      fdec.observation = dec.observation
      if inp.collision == "replace" and packageUnit and
          fdec.verdict in {cvCreate, cvUpdate, cvNoOp, cvAdopt, cvReconcile}:
        fdec.reason.add("; shadows the package unit at " & o.unit.fragmentPath)
      return (fdec, o)
    if packageUnit:
      if inp.collision != "replace":
        raise newAddOnUnitShadows(inp.unit, o.unit.fragmentPath)
      dec.verdict = cvReplace
      dec.reason = "package unit at " & o.unit.fragmentPath &
        "; shadowed by an /etc unit by opt-in"
      return (dec, o)
    dec.verdict = cvCreate
    dec.reason = "absent, no package provides the unit"
    (dec, o)

proc renderCollisionReport*(lines: seq[CollisionLine]): string =
  ## The plan's collision report (spec §7.1): one line per target with
  ## the observation that justifies its verdict.
  if lines.len == 0:
    return "collision report: no targets\n"
  result = "collision report:\n"
  for l in lines:
    result.add("  " & l.verdict & "\t" & l.target & "\t" & l.observation &
               "\t" & l.address & "\n    " & l.reason & "\n")

# ---------------------------------------------------------------------------
# The before-each-write re-check.
# ---------------------------------------------------------------------------

proc diversionText*(d: DiversionRecord): string =
  ## A diversion as the guard compares it: "" when there is none, else
  ## ``<diverted to> <by>`` (``:`` for a local diversion).
  if d.present: d.divertTo & " " & d.package else: ""

type
  PlannedTarget* = object
    ## What the plan decided for one privileged operation, kept so the
    ## guard can compare. An operation may carry more than one: a drop-in
    ## also carries the unit it modifies.
    address*: string
    path*: string
    kind*: TargetKind
    unit*: string
    observation*: string
    observedSha256*: string
    desiredSha256*: string
      ## What the switch's flip (step 3, between the plan and this
      ## guard) legitimately puts behind the add-on's own link.
    verdict*: CollisionVerdict
    diversion*: string
      ## ``diversionText`` of the path at plan time. The ledger's
      ## observation text leaves a local diversion out (the add-on's own
      ## diversion must not change how the file it fills is recorded), so
      ## the guard compares the diversion itself: a local diversion made
      ## by hand between the plan and the write is a change like any other.
    unitClass*: UnitClass
      ## tkUnit: where systemd loaded the unit from at plan time; a unit
      ## masked, or moved to a transient or package fragment, since then
      ## refuses the write (a drop-in's unit included).
    replay*: bool
      ## The plan is an interrupted switch's, replayed (spec §7.7): the
      ## switch may already have written this target before it stopped.

proc plannedTarget*(address: string; inp: DecisionInputs; path: string;
                    dec: CollisionDecision; o: TargetObservation):
    PlannedTarget =
  ## The guard's record of one decision.
  PlannedTarget(address: address, path: path, kind: inp.kind,
    unit: inp.unit, observation: dec.observation,
    observedSha256: dec.observedSha256, desiredSha256: inp.desiredSha256,
    verdict: dec.verdict, diversion: diversionText(o.diversion),
    unitClass: (if inp.kind == tkUnit: classifyUnit(o.unit) else: ucNone))

proc preWriteRefusal*(d: CollisionDriver; t: PlannedTarget): string =
  ## Re-observe ``t`` and return the reason to refuse the write, or "".
  ## The plan's decision stands only while the host still matches what
  ## it was decided on.
  let o = observeTarget(d, t.path, t.unit)
  if o.linkComponent.len > 0:
    return "refusing " & t.address & " at write time: " & o.linkComponent &
      " is now a symbolic link on " & t.path
  let kind = if t.kind == tkDiversion: tkFile else: t.kind
  if t.replay and t.kind != tkDiversion and o.exists and
      o.sha256 == t.desiredSha256 and o.ownership.package.len == 0 and
      not o.diversion.present:
    # The interrupted switch already wrote exactly the planned bytes here
    # (a copy, or the add-on's own link reading through the new tree), on
    # a path no package claims: its own work, not a change under the plan.
    return ""
  let obsNow = observationText(o, kind)
  if obsNow != t.observation:
    return "refusing " & t.address & " at write time: the ownership " &
      "observation changed since the plan (" & t.observation & " -> " &
      obsNow & ")"
  if t.kind == tkUnit:
    let cls = classifyUnit(o.unit)
    if cls != t.unitClass:
      return "refusing " & t.address & " at write time: " & t.unit &
        " is now " & $cls & " (" & o.unit.loadState & ", " &
        (if o.unit.fragmentPath.len > 0: o.unit.fragmentPath else: "no fragment") &
        "), planned " & $t.unitClass
  # The diversion of the path. The one change the plan itself makes is
  # the add-on's own diversion that a `divert` verdict depends on: the
  # diversion operation ran first (the file depends on it) and moved the
  # package's copy to the diversion target, so the path is now absent.
  var expectedSha = t.observedSha256
  let divNow = diversionText(o.diversion)
  if divNow != t.diversion:
    let ownDiversionAppeared = t.verdict == cvDivert and
      t.diversion.len == 0 and o.diversion.package == ":" and
      o.diversion.divertTo == d.diversionTarget(t.path)
    if not ownDiversionAppeared:
      return "refusing " & t.address & " at write time: the diversion of " &
        t.path & " changed since the plan (" &
        (if t.diversion.len > 0: t.diversion else: "none") & " -> " &
        (if divNow.len > 0: divNow else: "none") & ")"
    expectedSha = ""
  elif t.verdict == cvDivert and t.diversion.len == 0:
    return "refusing " & t.address & " at write time: the diversion the " &
      "plan decided for " & t.path & " is not in place"
  if o.ownLink and o.sha256 == t.desiredSha256:
    # The static tree was flipped after the plan: the add-on's own link
    # now shows the planned bytes. That is the switch, not a change.
    return ""
  if o.sha256 != expectedSha:
    return "refusing " & t.address & " at write time: " & t.path &
      " changed since the plan (sha256 " &
      (if o.sha256.len > 0: o.sha256[0 ..< 12] else: "absent") & ", planned " &
      (if expectedSha.len > 0: expectedSha[0 ..< 12] else: "absent") & ")"
  ""

type
  DriverFactory* = proc(): CollisionDriver {.gcsafe.}
    ## The observer the guard uses for an operation. The dpkg driver
    ## re-reads its package index whenever the database changed since it
    ## was read (``indexStamp``), so one driver kept for the whole apply
    ## still sees a package installed between the plan and the write; a
    ## factory may hand out that one driver.

  DestroyCheck* = proc(op: PrivilegedOperation): string {.gcsafe.}
    ## Re-observe what a destroy would remove, immediately before it is
    ## dispatched: "" to let it go, or why the object must be left as it
    ## is (it changed since the plan decided to remove it).

proc isDestroy*(op: PrivilegedOperation): bool =
  ## The destroy direction of the kinds an add-on generation carries.
  case op.kind
  of pokFsSystemFile: op.sfDestroy
  of pokSystemdSystemUnit: op.suDestroy
  of pokLinuxDpkgDiversion: op.ddDestroy
  of pokSystemdSystemDropIn: op.diDestroy
  of pokLinuxSysctl: op.sysctlDestroy
  of pokLinuxTmpfilesRule: op.tmpfilesDestroy
  of pokLinuxSysusersEntry: op.seDestroy
  else: false

proc makePreWriteGuard*(newDriver: DriverFactory;
                        targets: seq[PlannedTarget];
                        destroyCheck: DestroyCheck = nil): PreWriteGuard =
  ## The apply's ``PreWriteGuard`` over the plan's targets. Every
  ## operation of an add-on apply was decided on at plan time; one the
  ## plan did not decide on is refused, never let through. A destroy is
  ## not a plan target: ``destroyCheck`` re-observes the object it would
  ## remove, and an object changed since the plan is left in place
  ## (answered with ``PreWriteKeepPrefix``: drift, not a failure; spec
  ## §4.2 rule 1). With no ``destroyCheck`` a destroy is let through.
  var byAddress = initTable[string, seq[PlannedTarget]]()
  for t in targets: byAddress.mgetOrPut(t.address, @[]).add(t)
  result = proc(op: PrivilegedOperation): string =
    if isDestroy(op):
      if destroyCheck == nil: return ""
      let why = destroyCheck(op)
      return (if why.len > 0: PreWriteKeepPrefix & why else: "")
    if op.address notin byAddress:
      return "refusing " & op.address & ": the plan decided nothing about " &
        "it, so it cannot be written"
    let d = newDriver()
    for t in byAddress[op.address]:
      let why = preWriteRefusal(d, t)
      if why.len > 0: return why
    ""
