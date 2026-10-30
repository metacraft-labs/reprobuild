## The add-on's ownership ledger.
##
## The ledger is the only answer to "does the add-on own this?". It lists
## every object an add-on generation put on the host -- the roots bootstrap
## created, every file and unit a generation applied, the links ``systemctl
## enable`` made for those units, the directories created to hold them, the
## mounts their units establish and the dpkg diversions they hold -- with
## enough recorded about each one to remove it again, to tell whether it
## changed since, and to restore what it replaced.
##
## Three consumers read it:
##
## - **removal**: an object that leaves the profile is removed only if the
##   ledger lists it and it still has the recorded digest (``observeDrift``);
## - **uninstall**: reverses every entry, in the order the add-on's
##   specification fixes;
## - **the do-no-harm gates**: ``expectedRecords`` turns a ledger into the
##   fingerprint records its objects produce, and ``expectedDelta`` turns two
##   ledgers into the exact fingerprint diff an apply between them may
##   cause. "The add-on changed only what the ledger says" is then checked
##   mechanically: ``fingerprint(after) - fingerprint(before) ==
##   expectedDelta(ledgerBefore, ledgerAfter)``.
##
## A copy of the current ledger is kept beside ``current`` in the system
## state directory, so uninstall and verify work even when the store is
## damaged.

import std/[algorithm, os, posix, sets, strutils, tables]

import ./etc_write
import ./fingerprint

type
  LedgerClass* = enum
    lcRoot = "root"
      ## A directory bootstrap created as one of the add-on's own roots
      ## (``/repro``, ``/repro/store``, ``/var/lib/repro``, ``/etc/repro``,
      ## …). ``kindHint`` is ``dir`` or ``btrfs-subvolume``.
    lcDir = "dir"
      ## A directory an apply created to hold an object (a missing parent
      ## of a file, a ``<target>.wants`` directory).
    lcEtcFile = "etcFile"
      ## A regular file a generation wrote (always a copy in this
      ## milestone). ``replaced`` holds the pre-write value when the path
      ## existed before the add-on touched it.
    lcUnit = "unit"
      ## A unit file under ``/etc/systemd/system``.
    lcDropIn = "dropIn"
      ## A drop-in of a distribution unit,
      ## ``/etc/systemd/system/<unit>.d/50-repro-<name>.conf``; ``unit``
      ## names the unit it modifies.
    lcInstallLink = "installLink"
      ## A symlink ``systemctl enable`` created from a unit's
      ## ``[Install]`` section. ``linkTarget`` is what it points at.
    lcMount = "mount"
      ## A mount point a ``.mount`` unit of the add-on establishes.
    lcDiversion = "diversion"
      ## A local dpkg diversion. ``replaced`` holds the value of the
      ## package's file, now at ``<path>.distrib``.
    lcKey = "key"
      ## Key material bootstrap created (the recipient key pair).
    lcStorePrefix = "storePrefix"
      ## A store prefix the add-on realised into ``/repro/store``.

  LedgerEntry* = object
    class*: LedgerClass
    path*: string          ## absolute path (mount point for lcMount)
    unit*: string          ## owning unit, for unit / installLink / mount
    sha256*: string        ## content digest of a file the add-on wrote
    mode*: string          ## four octal digits
    owner*: string         ## ``uid:gid``
    linkTarget*: string    ## installLink only
    kindHint*: string      ## root only: ``dir`` / ``btrfs-subvolume``
    enabled*: bool         ## unit only: enabled from its [Install] section
    started*: bool         ## unit only: left active by the apply
    hasInstall*: bool      ## unit only: has an [Install] section at all
    replaced*: string      ## fingerprint ``etc`` value the path had before
                           ## the add-on wrote it; "" when it was absent
    resource*: string      ## infra resource address that produced it
    observation*: string   ## the package-ownership observation made at
                           ## plan time (``absent``, ``unowned``,
                           ## ``package:<pkg>``, ``conffile:<pkg>``,
                           ## ``unit:<fragmentPath>``); "" for objects
                           ## the observer does not cover
    collision*: string     ## how a collision was resolved: "" (none),
                           ## ``adopt``, ``divert``, ``dropIn``,
                           ## ``replace``, ``reconcile``
    preserved*: string     ## where the pre-write bytes of an adopted,
                           ## replaced or reconciled file are kept
                           ## (``<state>/addon/preserved/<sha256>``), or ""
    unitState*: string     ## unit only: UnitFileState observed after the
                           ## apply ("" when not observed)
    activeState*: string   ## unit only: ActiveState observed after the apply
    baseUnitState*: string ## unit only: UnitFileState before the add-on
                           ## first touched the unit name ("" when none)
    baseActiveState*: string ## unit only: ActiveState before, likewise

  Ledger* = object
    generation*: string
    entries*: seq[LedgerEntry]

  LedgerError* = object of CatchableError

const
  LedgerHeader* = "# repro-addon-ledger v2"
  LedgerFields = 20

proc flag(b: bool): string = (if b: "1" else: "0")

proc render*(l: Ledger): string =
  ## Canonical text. Entries keep the order they were recorded in: removal
  ## and uninstall walk it backwards, so order is meaning, not noise.
  result = LedgerHeader & "\n"
  result.add("generation\t" & escapeField(l.generation) & "\n")
  for e in l.entries:
    let fields = [$e.class, e.path, e.unit, e.sha256, e.mode, e.owner,
                  e.linkTarget, e.kindHint, flag(e.enabled), flag(e.started),
                  flag(e.hasInstall), e.replaced, e.resource, e.observation,
                  e.collision, e.preserved, e.unitState, e.activeState,
                  e.baseUnitState, e.baseActiveState]
    var line = ""
    for i, f in fields:
      if i > 0: line.add('\t')
      line.add(escapeField(f))
    result.add(line & "\n")

proc classFromString(s: string): LedgerClass =
  for c in LedgerClass:
    if $c == s: return c
  raise newException(LedgerError, "unknown ledger class: " & s)

proc parseLedger*(text: string): Ledger =
  ## Strict inverse of ``render``.
  let lines = text.splitLines()
  if lines.len < 2 or lines[0] != LedgerHeader:
    raise newException(LedgerError, "not a repro-addon ledger")
  let g = lines[1].split('\t')
  if g.len != 2 or g[0] != "generation":
    raise newException(LedgerError, "ledger has no generation line")
  result.generation = unescapeField(g[1])
  for i in 2 ..< lines.len:
    if lines[i].len == 0: continue
    let f = lines[i].split('\t')
    if f.len != LedgerFields:
      raise newException(LedgerError, "malformed ledger line " & $(i + 1))
    var u: seq[string]
    for x in f: u.add(unescapeField(x))
    result.entries.add(LedgerEntry(class: classFromString(u[0]), path: u[1],
      unit: u[2], sha256: u[3], mode: u[4], owner: u[5], linkTarget: u[6],
      kindHint: u[7], enabled: u[8] == "1", started: u[9] == "1",
      hasInstall: u[10] == "1", replaced: u[11], resource: u[12],
      observation: u[13], collision: u[14], preserved: u[15],
      unitState: u[16], activeState: u[17], baseUnitState: u[18],
      baseActiveState: u[19]))

proc readLedger*(path: string): Ledger =
  if not fileExists(path):
    raise newException(LedgerError, "no add-on ledger at " & path)
  parseLedger(readFile(path))

proc writeFileAtomic*(path, content: string; mode = 0o644) =
  ## Write to a temporary file in the same directory, fsync, then rename:
  ## a crash leaves either the old or the new file, never a torn one. The
  ## write never follows a link on the path (``etc_write``).
  writeFileNoFollow(path, content, mode)

proc writeLedger*(path: string; l: Ledger) =
  writeFileAtomic(path, l.render(), 0o600)

# ---------------------------------------------------------------------------
# Observing the objects an entry describes.
# ---------------------------------------------------------------------------

proc statOwner*(path: string): tuple[ok: bool; mode, owner: string] =
  var st: Stat
  if lstat(path.cstring, st) != 0:
    return (false, "", "")
  (true, toOct(int(st.st_mode) and 0o7777, 4), $st.st_uid & ":" & $st.st_gid)

proc observeDrift*(e: LedgerEntry): string =
  ## "" when the object is exactly as the ledger recorded it, otherwise a
  ## one-line description of the difference. Used before every removal and
  ## by ``verify``. Classes whose state is not a file (mounts, diversions,
  ## store prefixes) are checked by their own owners and report "" here.
  case e.class
  of lcEtcFile, lcUnit, lcDropIn, lcKey:
    if not fileExists(e.path) or symlinkExists(e.path):
      return "missing (or no longer a regular file)"
    let digest = sha256OfFile(e.path)
    if digest != e.sha256:
      return "content changed (sha256 " & digest[0 ..< 12] & ", ledger " &
             e.sha256[0 ..< min(12, e.sha256.len)] & ")"
    ""
  of lcInstallLink:
    if not symlinkExists(e.path):
      return "missing (or no longer a symlink)"
    let t = expandSymlink(e.path)
    if t != e.linkTarget:
      return "points at " & t & ", ledger " & e.linkTarget
    ""
  of lcRoot, lcDir:
    if not dirExists(e.path) or symlinkExists(e.path):
      return "missing (or no longer a directory)"
    ""
  of lcMount, lcDiversion, lcStorePrefix:
    ""

# ---------------------------------------------------------------------------
# Ledger -> fingerprint expectations.
# ---------------------------------------------------------------------------

type
  ExpectedRecord* = object
    component*: FingerprintComponent
    key*: string
    value*: string          ## "*" when the add-on cannot predict it
    baseValue*: string      ## the value before the add-on, "" when absent

proc fileValue(e: LedgerEntry): string =
  "f " & e.mode & " " & e.owner & " sha256:" & e.sha256

proc isEtcPath(p: string): bool = p == "/etc" or p.startsWith("/etc/")

proc isLiveState(s: string): bool = s == "active" or s == "failed"
  ## The ``active-units`` component records units in these states.

proc expectedRecords*(l: Ledger): seq[ExpectedRecord] =
  ## The fingerprint records the ledger's objects account for.
  var etcFiles = initHashSet[string]()
  for e in l.entries:
    if e.class == lcEtcFile: etcFiles.incl(e.path)
  for e in l.entries:
    case e.class
    of lcRoot:
      if isEtcPath(e.path):
        result.add(ExpectedRecord(component: fcEtc, key: e.path,
          value: "d " & e.mode & " " & e.owner))
      elif e.path in AddonRootPaths:
        result.add(ExpectedRecord(component: fcAddonRoots, key: e.path,
          value: e.kindHint & " " & e.mode & " " & e.owner,
          baseValue: "absent"))
    of lcDir:
      if isEtcPath(e.path):
        result.add(ExpectedRecord(component: fcEtc, key: e.path,
          value: "d " & e.mode & " " & e.owner))
    of lcEtcFile, lcDropIn:
      result.add(ExpectedRecord(component: fcEtc, key: e.path,
        value: fileValue(e), baseValue: e.replaced))
    of lcUnit:
      result.add(ExpectedRecord(component: fcEtc, key: e.path,
        value: fileValue(e), baseValue: e.replaced))
      # Unit states are what systemd reported after the apply, when the
      # apply recorded them; a ledger written without that observation
      # (generation 0 of an older binary) derives them from the flags.
      let state =
        if e.unitState.len > 0: e.unitState
        elif e.enabled: "enabled"
        elif e.hasInstall: "disabled"
        else: "static"
      result.add(ExpectedRecord(component: fcUnitFiles, key: e.unit,
        value: state, baseValue: e.baseUnitState))
      let live =
        if e.activeState.len > 0: (if isLiveState(e.activeState): e.activeState
                                   else: "")
        elif e.started: "active"
        else: ""
      let baseLive = if isLiveState(e.baseActiveState): e.baseActiveState
                     else: ""
      if live.len > 0 or baseLive.len > 0:
        result.add(ExpectedRecord(component: fcActiveUnits, key: e.unit,
          value: live, baseValue: baseLive))
    of lcInstallLink:
      result.add(ExpectedRecord(component: fcEtc, key: e.path,
        value: "l 0777 0:0 -> " & e.linkTarget))
    of lcMount:
      result.add(ExpectedRecord(component: fcMounts, key: e.path, value: "*"))
    of lcDiversion:
      result.add(ExpectedRecord(component: fcDiversions, key: e.path,
        value: e.path & ".distrib :"))
      # The package's file moved aside...
      result.add(ExpectedRecord(component: fcEtc, key: e.path & ".distrib",
        value: e.replaced))
      # ...and, unless a generation put its own file there, the path itself
      # is gone.
      if e.path notin etcFiles:
        result.add(ExpectedRecord(component: fcEtc, key: e.path, value: "",
          baseValue: e.replaced))
    of lcKey, lcStorePrefix:
      discard  # under /var/lib/repro and /repro: not fingerprinted

proc expectedDelta*(before, after: Ledger): seq[Expectation] =
  ## The exact fingerprint diff an apply from ``before`` to ``after`` may
  ## cause.
  ##
  ## For every record either ledger accounts for, the value it had before
  ## the apply is the ``before`` ledger's value, or -- when ``before`` did
  ## not own it -- the base's (``baseValue``); the value after is the
  ## ``after`` ledger's, or the base's again when ``after`` released it.
  ## "" means "no such record" (the path does not exist); ``addon-roots``
  ## records always exist, with ``absent`` as the value of a missing root.
  ## "*" (a value the add-on cannot predict, such as a mount's source
  ## device) matches any value.
  var a = initOrderedTable[(FingerprintComponent, string), ExpectedRecord]()
  var b = initOrderedTable[(FingerprintComponent, string), ExpectedRecord]()
  for r in expectedRecords(before): a[(r.component, r.key)] = r
  for r in expectedRecords(after): b[(r.component, r.key)] = r
  var keys: seq[(FingerprintComponent, string)]
  for k in a.keys: keys.add(k)
  for k in b.keys:
    if k notin a: keys.add(k)
  for k in keys:
    let base = if k in b: b[k].baseValue else: a[k].baseValue
    let fromV = if k in a: a[k].value else: base
    let toV = if k in b: b[k].value else: base
    if fromV == toV and toV != "*": continue
    if fromV == "*" and toV == "*": continue
    let comp = k[0]
    if comp == fcAddonRoots:
      result.add(Expectation(op: doChanged, component: comp, key: k[1],
                             value: toV))
    elif fromV.len == 0:
      result.add(Expectation(op: doAdded, component: comp, key: k[1],
                             value: toV))
    elif toV.len == 0:
      result.add(Expectation(op: doRemoved, component: comp, key: k[1],
                             value: fromV))
    else:
      result.add(Expectation(op: doChanged, component: comp, key: k[1],
                             value: toV))
  result.sort(proc(x, y: Expectation): int =
    result = cmp(ord(x.component), ord(y.component))
    if result == 0: result = cmp(x.key, y.key))
