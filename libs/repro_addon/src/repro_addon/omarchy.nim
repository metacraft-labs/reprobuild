## Omarchy, the configuration layer on Arch that add-on mode treats as a third
## owner (spec ReproOS-Add-On-Mode §4.3.2): how the add-on recognises an
## Omarchy base, reads its version, and checks the account the profile names
## as the one Omarchy runs as (``addOn { omarchyAccount = "<name>" }``, §8.5;
## §13 decision 94).
##
## The version comes from ``os-release`` (``VERSION_ID``, ``BUILD_ID``) and
## the installed ``omarchy`` package's ``%VERSION%`` in pacman's local
## database -- what ``omarchy-version`` reports -- and never from
## ``~/.local/share/omarchy/version``, which is a file reached through a link
## into ``/usr/share/omarchy`` and can be stale (measured on Omarchy 4.0.6).
##
## The account's home is read from the password database (``getpwnam(3)``),
## never from ``$HOME``: the add-on runs as root, and whose home holds the
## hook is a property of the account, not of the shell that ran the command.
##
## **The Omarchy path set** (§4.3.2). Omarchy's install scripts and
## migrations write ``/etc`` as the user with ``sudo``, outside pacman, so
## no package database records those writes. The add-on approximates them
## by a textual match: every ``/etc/...`` token in the files the installed
## ``omarchy`` package lists under ``/usr/share/omarchy/install/`` and
## ``/usr/share/omarchy/migrations/`` (``readOmarchyPathSet``). It is a
## heuristic (§13 decision 11): a token is a path the scripts name, whether
## they write it or only read it, and a path the scripts build from a
## variable is cut where the variable starts, so it names the directory.
## Preflight records the set in its plan, and every plan of an operator
## profile refuses a managed prefix, a file or a unit that intersects it
## with ``EAddOnBaseLayerOwned``, naming the scripts (``addon_apply``'s
## base-layer pass). A file or a unit is acknowledged one at a time with
## ``collision = "overrideBaseLayer"``, and every plan lists each
## acknowledgement.
##
## Everything here only reads.

import std/[algorithm, os, posix, sequtils, sets, strutils, tables]

import repro_infra/addon_diagnostics
from repro_infra/profile import SystemProfile, SystemResource,
  SystemResourceKind

import ./mutations
import ./pacman_db

const
  OmarchyId* = "omarchy"
    ## ``os-release`` ``ID`` of an Omarchy base (with ``ID_LIKE=arch``).
  OmarchyPackage* = "omarchy"
    ## The package holding Omarchy's scripts, whose version is Omarchy's.
  OmarchyHooksRel* = ".config/omarchy/hooks"
    ## Omarchy's hook directory, relative to the account's home
    ## (``omarchy-hook`` runs ``post-update.d/*`` from it).

type
  OmarchyFacts* = object
    ## What the preflight records about an Omarchy base.
    versionId*: string        ## ``os-release`` ``VERSION_ID``
    buildId*: string          ## ``os-release`` ``BUILD_ID``
    packageVersion*: string   ## the ``omarchy`` package's ``%VERSION%``

proc isOmarchyBase*(id: string): bool =
  ## ``ID=omarchy`` (spec §4.3.2). An Arch host that merely has some
  ## Omarchy package installed is not an Omarchy base.
  id.toLowerAscii() == OmarchyId

proc omarchyFacts*(osRelease: Table[string, string]; root = "/"): OmarchyFacts =
  ## Read-only: ``os-release`` and pacman's local database.
  OmarchyFacts(versionId: osRelease.getOrDefault("VERSION_ID"),
               buildId: osRelease.getOrDefault("BUILD_ID"),
               packageVersion: pacmanInstalledVersion(OmarchyPackage, root))

proc accountHome*(name: string): tuple[found: bool; home: string] =
  ## The home directory the password database records for ``name``.
  let pw = getpwnam(name.cstring)
  if pw == nil: return (false, "")
  (true, $pw.pw_dir)

proc omarchyHooksDir*(home: string): string =
  ## ``<home>/.config/omarchy/hooks``.
  home / OmarchyHooksRel

proc isRealDirectory(path: string): bool =
  ## A directory at ``path`` itself, not a symbolic link to one.
  var st: Stat
  lstat(path.cstring, st) == 0 and S_ISDIR(st.st_mode)

type
  OmarchyAccountProblem* = object
    ## Why the profile's ``omarchyAccount`` cannot stand on this base;
    ## ``detail`` "" when it can.
    diagnostic*: AddOnDiagnostic
    detail*: string

proc omarchyAccountProblem*(baseId, account: string;
                            lookup: proc(name: string): tuple[found: bool;
                              home: string] = accountHome):
    OmarchyAccountProblem =
  ## The profile's ``omarchyAccount`` against the base (spec §8.5; §13
  ## decisions 94 and 101):
  ##
  ## * an Omarchy base with no ``omarchyAccount``, an account the password
  ##   database does not know, or one whose home has no Omarchy hook
  ##   directory: ``EAddOnBaseLayerOwned`` (§8.4), naming what is missing;
  ## * an ``omarchyAccount`` on a base that is not Omarchy:
  ##   ``EAddOnOutOfScope`` -- the setting has no meaning there.
  ##
  ## ``lookup`` replaces the password database in the unit tests.
  template refuse(d: AddOnDiagnostic; why: string) =
    return OmarchyAccountProblem(diagnostic: d, detail: why)
  if not isOmarchyBase(baseId):
    if account.len > 0:
      refuse(adOutOfScope, "addOn.omarchyAccount \"" & account & "\" is " &
        "declared, but the base is ID=" & baseId & ", not Omarchy; the " &
        "setting names the account Omarchy runs as and is refused on any " &
        "other base (spec §8.5)")
    return
  if account.len == 0:
    refuse(adBaseLayerOwned, "the base is Omarchy and the profile names no " &
      "`addOn { omarchyAccount = \"<name>\" }`: the account Omarchy runs " &
      "as, whose home holds Omarchy's hook directory, must be declared " &
      "(spec §4.3.2, §8.5)")
  let (found, home) = lookup(account)
  if not found:
    refuse(adBaseLayerOwned, "omarchyAccount \"" & account & "\" is not " &
      "an account in the password database")
  if home.len == 0 or not home.isAbsolute:
    refuse(adBaseLayerOwned, "omarchyAccount \"" & account & "\" has no " &
      "absolute home directory in the password database ('" & home & "')")
  let hooks = omarchyHooksDir(home)
  if not isRealDirectory(hooks):
    refuse(adBaseLayerOwned, "omarchyAccount \"" & account & "\": " &
      hooks & " is not a directory; Omarchy's hook directory must exist " &
      "in the account's home (spec §4.3.2)")

proc omarchyAccountChecked*(purpose: string; recordOnly, generationZero,
                            hasOperatorProfile: bool): bool =
  ## Whether an apply checks the profile's ``omarchyAccount`` against the
  ## base (spec §8.5; §13 decision 131): on every operator profile's apply,
  ## an empty profile included, and not on a replay, a revert or a
  ## record-only pass, which finish or undo a switch already decided and are
  ## never refused for the base. ``generationZero`` is an apply of the
  ## add-on's own objects that the caller supplies itself (bootstrap,
  ## ``ownProfileText``): it is checked only when it also carries an
  ## operator profile (``hasOperatorProfile``, the stored profile a re-pin
  ## or enrolment applies again).
  if purpose in ["revert", "replay"] or recordOnly: return false
  not generationZero or hasOperatorProfile

proc omarchyAccountRefusal*(baseId, account: string;
                            lookup: proc(name: string): tuple[found: bool;
                              home: string] = accountHome): string =
  ## ``omarchyAccountProblem`` as one message starting with its
  ## diagnostic's name, or "".
  let p = omarchyAccountProblem(baseId, account, lookup)
  if p.detail.len == 0: "" else: diagnosticMessage(p.diagnostic, p.detail)

# ---------------------------------------------------------------------------
# The Omarchy path set (spec §4.3.2): what the base layer writes in /etc.
# ---------------------------------------------------------------------------

const
  OmarchyShareDir* = "/usr/share/omarchy"
    ## Where the ``omarchy`` package installs its scripts.
  OmarchyScriptDirs* = ["install", "migrations"]
    ## The two trees under ``OmarchyShareDir`` whose files write ``/etc``
    ## outside pacman: the installer's steps and the migrations
    ## ``omarchy-migrate`` runs after an update.
  OverrideBaseLayer* = "overrideBaseLayer"
    ## The ``collision`` value that acknowledges one path or unit the base
    ## layer writes (spec §4.3.2, §8.4).
  EtcTokenChars = {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '@', '+', '-', '/'}
    ## The characters an ``/etc`` token runs over. Anything else ends it: a
    ## quote, white space, ``$`` (a variable: the token names the directory
    ## before it), ``*`` (a glob: likewise), ``:`` (a list separator).

type
  OmarchyPath* = object
    ## One path of the set.
    path*: string            ## canonical: no ``//``, no trailing ``/``
    scripts*: seq[string]    ## every file naming it (absolute, sorted)
    owners*: seq[string]     ## every package whose ``%FILES%`` lists it
                             ## (the second owner, §4.3.2), sorted

  OmarchyPathSet* = object
    ## What ``readOmarchyPathSet`` found. ``problem`` is non-empty when the
    ## set could not be read; every caller then refuses, since an empty set
    ## would let every path through.
    packageVersion*: string  ## the ``omarchy`` package's ``%VERSION%``
    scriptCount*: int        ## files read
    paths*: seq[OmarchyPath] ## sorted by path
    problem*: string

proc etcPathTokens*(text: string): seq[string] =
  ## The ``/etc`` paths ``text`` names, canonical and in order of first
  ## appearance, each once. Every occurrence of ``/etc/`` starts a token,
  ## whatever precedes it (``$target_root/etc/...`` in an installer step
  ## is the installed system's ``/etc``). A token runs over
  ## ``EtcTokenChars``; repeated ``/`` collapse to one, and trailing ``/``
  ## and ``.`` (a sentence's full stop) are dropped. A token with a ``.``
  ## or ``..`` segment, or that is ``/etc`` itself, is not a path the set
  ## can hold: the first is not canonical, and the second would make every
  ## path intersect.
  var seen = initHashSet[string]()
  var i = text.find("/etc/")
  while i >= 0:
    var j = i + "/etc/".len
    while j < text.len and text[j] in EtcTokenChars: inc j
    var t = newStringOfCap(j - i)
    for k in i ..< j:
      if text[k] == '/' and t.len > 0 and t[^1] == '/': continue
      t.add(text[k])
    while t.len > 0 and t[^1] in {'/', '.'}: t.setLen(t.len - 1)
    var canonical = t.len > "/etc".len
    for seg in t.split('/'):
      if seg in [".", ".."]: canonical = false
    if canonical and t notin seen:
      seen.incl(t)
      result.add(t)
    i = text.find("/etc/", j)

proc omarchyScriptFiles*(filesEntry: string): seq[string] =
  ## The files a ``files`` entry of the ``omarchy`` package lists under
  ## ``OmarchyScriptDirs`` (``/``-rooted, directories excluded: they end
  ## in ``/`` in ``%FILES%``), sorted.
  for raw in pacmanFilesSection(filesEntry):
    if raw.endsWith("/"): continue
    let p = "/" & raw
    for d in OmarchyScriptDirs:
      if p.startsWith(OmarchyShareDir & "/" & d & "/"):
        result.add(p)
  result.sort(system.cmp)

proc readOmarchyPathSet*(root = "/"): OmarchyPathSet =
  ## The Omarchy path set of the base at ``root`` (spec §4.3.2): read from
  ## the files the installed ``omarchy`` package lists under
  ## ``OmarchyScriptDirs``, each path with the scripts naming it and the
  ## packages that also own it. Read-only. Fails closed: the package not
  ## installed, a listed file missing, not a regular file (a link is not
  ## followed), or unreadable, no file listed at all, or a damaged package
  ## database each leave ``problem`` set.
  template fail(why: string) =
    result.paths = @[]
    result.problem = why
    return
  when mutated("omarchy-path-set-empty"):
    # FALSIFYING MUTATION (e2e_omarchy_addon_base_layer_refusal): the set
    # is read as empty, so preflight records no path and no plan refuses.
    result.packageVersion = pacmanInstalledVersion(OmarchyPackage, root)
    return
  var entry: tuple[found: bool; entry: string]
  try:
    entry = pacmanPackageFilesEntry(OmarchyPackage, root)
    result.packageVersion = pacmanInstalledVersion(OmarchyPackage, root)
  except IOError, OSError:
    fail("the " & OmarchyPackage & " package's database entry cannot be " &
      "read: " & getCurrentExceptionMsg())
  if not entry.found:
    fail("the base is Omarchy, and the " & OmarchyPackage & " package, " &
      "whose scripts under " & OmarchyShareDir & " the path set is read " &
      "from, is not installed")
  let files = omarchyScriptFiles(entry.entry)
  if files.len == 0:
    fail("the " & OmarchyPackage & " package lists no file under " &
      OmarchyShareDir & "/{" & OmarchyScriptDirs.join(",") & "}/")
  var byPath = initTable[string, seq[string]]()
  var order: seq[string]
  for f in files:
    let onDisk = (if root == "/" or root.len == 0: f else: root & f)
    var st: Stat
    if lstat(onDisk.cstring, st) != 0:
      fail(f & ", which the " & OmarchyPackage & " package lists, is " &
        "missing; reinstall the package")
    if not S_ISREG(st.st_mode):
      fail(f & ", which the " & OmarchyPackage & " package lists, is not " &
        "a regular file (a link is not followed)")
    var text: string
    try: text = readFile(onDisk)
    except IOError, OSError:
      fail(f & " cannot be read: " & getCurrentExceptionMsg())
    inc result.scriptCount
    for t in etcPathTokens(text):
      if t notin byPath:
        byPath[t] = @[]
        order.add(t)
      byPath[t].add(f)
  var owners: Table[string, seq[string]]
  try: owners = pacmanOwnersOf(order, root)
  except IOError, OSError, ValueError:
    fail("the package owners of the Omarchy path set cannot be read: " &
      getCurrentExceptionMsg())
  order.sort(system.cmp)
  for p in order:
    result.paths.add(OmarchyPath(path: p, scripts: byPath[p],
                                 owners: owners.getOrDefault(p)))

# ---------------------------------------------------------------------------
# Intersections (spec §4.3.2 "Plan time").
# ---------------------------------------------------------------------------

proc isBelow(path, dir: string): bool =
  ## ``path`` is strictly inside the directory ``dir`` (path text).
  path.len > dir.len + 1 and path.startsWith(dir) and path[dir.len] == '/'

proc fileIntersections*(s: OmarchyPathSet; file: string): seq[OmarchyPath] =
  ## The set's paths a file at ``file`` intersects: the path itself, or a
  ## directory of the set the file is inside (``/etc/sudoers.d`` for
  ## ``/etc/sudoers.d/x``).
  for e in s.paths:
    if e.path == file or isBelow(file, e.path): result.add(e)

proc prefixIntersections*(s: OmarchyPathSet; prefix: string): seq[OmarchyPath] =
  ## The set's paths a managed prefix covers (§4.4: with or without a
  ## trailing ``/``, a prefix covers its path and everything below it). A
  ## prefix inside a directory of the set covers none of the set's paths by
  ## itself; each file declared under it meets ``fileIntersections``.
  var p = prefix
  while p.len > 1 and p[^1] == '/': p.setLen(p.len - 1)
  for e in s.paths:
    if e.path == p or isBelow(e.path, p): result.add(e)

const EtcSystemUnitDir = "/etc/systemd/system"
  ## The one directory a set path names a system unit in.

proc unitsNamedBy*(path: string): seq[string] =
  ## The system units a set path names: the unit file
  ## (``/etc/systemd/system/<unit>``), its drop-in directory or a file in it
  ## (``<unit>.d/...``), or a dependency link (``<target>.wants/<unit>``,
  ## ``.requires``, ``.upholds``). A component without a ``.`` is no unit
  ## name.
  if not isBelow(path, EtcSystemUnitDir): return
  let parts = path[EtcSystemUnitDir.len + 1 .. ^1].split('/')
  let first = parts[0]
  if first.endsWith(".d") and first.len > 2:
    result.add(first[0 ..< first.len - 2])
  elif parts.len >= 2 and (first.endsWith(".wants") or
      first.endsWith(".requires") or first.endsWith(".upholds")):
    result.add(parts[1])
  else:
    result.add(first)
  result.keepItIf('.' in it)

proc unitTemplate(unit: string): string =
  ## ``foo@bar.service`` -> ``foo@.service``; "" for a unit that is not an
  ## instance.
  let at = unit.find('@')
  let dot = unit.rfind('.')
  if at < 0 or dot < at or dot == at + 1: return ""
  unit[0 .. at] & unit[dot .. ^1]

proc unitIntersections*(s: OmarchyPathSet; unit: string): seq[OmarchyPath] =
  ## The set's paths naming ``unit`` (``unitsNamedBy``): the same name, an
  ## instance of the template ``unit`` is, or the template of the instance
  ## ``unit`` is -- a template's file and drop-ins apply to every instance
  ## (systemd.unit(5) "Description").
  for e in s.paths:
    for n in unitsNamedBy(e.path):
      if n == unit or unitTemplate(n) == unit or unitTemplate(unit) == n:
        result.add(e)
        break

proc describe*(e: OmarchyPath): string =
  ## ``<path> (named by <scripts>; also owned by package <p>)``.
  result = e.path & " (named by " & e.scripts.join(", ")
  if e.owners.len > 0:
    result.add("; also owned by package" &
      (if e.owners.len > 1: "s " else: " ") & e.owners.join(", "))
  result.add(")")

# ---------------------------------------------------------------------------
# The plan-time check (spec §4.3.2, §8.4).
# ---------------------------------------------------------------------------

type
  BaseLayerCheck* = object
    ## What ``baseLayerCheck`` found in an operator profile.
    refusals*: seq[string]
      ## One line per declaration intersecting the set without an
      ## acknowledgement; any refuses the plan (``EAddOnBaseLayerOwned``).
    overrides*: seq[string]
      ## One line per ``collision = "overrideBaseLayer"``: what it
      ## acknowledges, listed in every plan.

proc overrideHint(collision: string): string =
  ## How a refused file or unit is acknowledged, given the opt-in it has.
  if collision.len == 0:
    "; acknowledge it with `collision = \"" & OverrideBaseLayer & "\"`"
  else:
    "; its `collision = \"" & collision & "\"` answers another owner, " &
      "and one `collision` value acknowledges one owner, so no opt-in " &
      "covers both"

proc baseLayerCheck*(s: OmarchyPathSet; user: SystemProfile): BaseLayerCheck =
  ## The operator profile ``user`` against the base layer's path set (spec
  ## §4.3.2): a managed prefix covering a path of the set, an
  ## ``fs.systemFile`` at or inside one, and a unit the set names -- a
  ## ``systemd.systemUnit`` or ``systemd.systemTimer`` it defines, a
  ## ``systemd.systemDropIn`` or ``systemd.unitState`` acting on it -- each
  ## is a refusal naming the scripts, unless it is a file or a unit with
  ## ``collision = "overrideBaseLayer"``, which is listed instead. A prefix
  ## carries no ``collision``: it is refused for each path of the set it
  ## covers that no acknowledged file intersects. A timer, a drop-in and a
  ## unit state carry none either, and have no acknowledgement. A unit file is matched by its name, never
  ## by its path: every unit lives in ``/etc/systemd/system``, which the
  ## scripts name as a directory.
  proc hits(es: seq[OmarchyPath]): string =
    es.map(describe).join("; ")
  # The set's paths the profile's files acknowledge: a prefix needs no
  # acknowledgement of its own for those (the narrowest prefix that lets a
  # profile write a file of the set is that file's path, and it covers it).
  var acknowledged = initHashSet[string]()
  for r in user.resources:
    if r.kind == SystemResourceKind.srkFsSystemFile and
        r.sfCollision == OverrideBaseLayer:
      for e in fileIntersections(s, r.sfPath): acknowledged.incl(e.path)
  for pfx in user.addOn.managedEtcPrefixes:
    var es: seq[OmarchyPath]
    for e in prefixIntersections(s, pfx):
      if e.path notin acknowledged: es.add(e)
    if es.len > 0:
      result.refusals.add("managed prefix " & pfx & " covers " & hits(es) &
        "; a prefix carries no `collision`, so each path of the set it " &
        "covers must be acknowledged by an fs.systemFile there with " &
        "`collision = \"" & OverrideBaseLayer & "\"`: narrow the prefix to " &
        "the paths the profile writes")
  for r in user.resources:
    var subject, collision, what: string
    var acknowledgeable = true
    var es: seq[OmarchyPath]
    case r.kind
    of SystemResourceKind.srkFsSystemFile:
      subject = r.sfPath
      collision = r.sfCollision
      what = "is written by the base layer"
      es = fileIntersections(s, r.sfPath)
    of SystemResourceKind.srkSystemdSystemUnit:
      subject = r.suName
      collision = r.suCollision
      what = "is a unit the base layer installs or configures"
      es = unitIntersections(s, r.suName)
    of SystemResourceKind.srkSystemdSystemTimer:
      subject = r.stName
      acknowledgeable = false
      what = "is a unit the base layer installs or configures"
      es = unitIntersections(s, r.stName)
    of SystemResourceKind.srkSystemdSystemDropIn:
      subject = r.diUnit
      acknowledgeable = false
      what = "is a unit the base layer installs or configures, and this " &
        "drop-in changes it"
      es = unitIntersections(s, r.diUnit)
    of SystemResourceKind.srkSystemdUnitState:
      subject = r.usName
      acknowledgeable = false
      what = "is a unit the base layer installs or configures, and this " &
        "resource sets its state"
      es = unitIntersections(s, r.usName)
    else:
      continue
    let overriding = collision == OverrideBaseLayer
    if es.len == 0:
      if overriding:
        result.overrides.add(r.address & "\t" & subject & "\tacknowledges " &
          "nothing: no path of the Omarchy path set names it")
      continue
    if overriding:
      result.overrides.add(r.address & "\t" & subject & "\t" & hits(es))
    elif acknowledgeable:
      result.refusals.add(r.address & ": " & subject & " " & what & ": " &
        hits(es) & overrideHint(collision))
    else:
      result.refusals.add(r.address & ": " & subject & " " & what & ": " &
        hits(es) & "; a " & $r.kind & " carries no `collision`, so it " &
        "has no acknowledgement")

proc baseLayerRefusalDetail*(s: OmarchyPathSet; c: BaseLayerCheck): string =
  ## ``EAddOnBaseLayerOwned``'s detail for a check with refusals, or for a
  ## set that could not be read; "" otherwise.
  if s.problem.len > 0:
    return s.problem & "; the Omarchy path set is checked by every plan " &
      "(spec §4.3.2), so nothing was planned or changed"
  if c.refusals.len == 0: return ""
  "Omarchy " & s.packageVersion & "'s install and migration scripts write " &
    "what the profile declares (spec §4.3.2); nothing was planned or " &
    "changed:\n  " & c.refusals.join("\n  ")

proc baseLayerRefusal*(s: OmarchyPathSet; c: BaseLayerCheck): string =
  ## ``baseLayerRefusalDetail`` as one message starting with
  ## ``EAddOnBaseLayerOwned``, or "".
  let d = baseLayerRefusalDetail(s, c)
  if d.len == 0: "" else: diagnosticMessage(adBaseLayerOwned, d)
