## Develop mode for Nimble catalog packages (Nimble-Package-Catalog.md
## NPC-AREQ27, §13.1): a checkout overrides a locked `nimble:` package,
## matched by origin identity -- automatically for a repo the workspace
## declares, through a recorded override for any other checkout.
##
## * ``declaredMatches`` -- which declared repos (the workspace's membership,
##   its `repos/*.toml` fragments and the develop set, collected by the CLI)
##   have a lock row's origin identity: the canonical remote identity of the
##   repo's fetch URL against the row's origin, and the row's `subdir`. A
##   directory or repo NAME matches nothing.
## * ``proposeNimbleOverrides`` -- which undeclared sibling checkouts could
##   override which locked packages, by one of their remotes. A directory's
##   name proposes nothing: a namesake is reported, never proposed.
## * ``runNimbleDevelopCommand`` -- `repro nimble develop`: lists the
##   automatic and recorded overrides and the proposals; records an override
##   of an undeclared checkout (or `--source`) in the workspace's
##   `.repro/develop-overrides.toml` with the identity it replaces
##   (`replaces`, schema v2); and with `--relock` writes the develop overlay
##   lock `.repro/develop.lock`.
## * ``applyNimbleDevelopOverrides`` -- the build's step. Each override in
##   effect (recorded first, then automatic) replaces its package's store
##   tree on the compile's `--path` with the checkout's source directory,
##   read from the working tree by the static `.nimble` reader (`srcDir`).
##   When the checkout's requirements differ from the locked record's, the
##   build reads the develop overlay lock when it matches, and otherwise
##   refuses. A `--locked` build applies none and names each one set aside.
##
## Nothing here runs Nimble or NimScript: a checkout's `.nimble` is read as
## data (threat model G1). No override is written into the committed lock,
## and the overlay never changes it.

import std/[algorithm, options, os, osproc, sequtils, sets, strutils, tables,
  times]

import blake3
from repro_domain_types/nimble_index/types import toHexLower

import repro_lock
import repro_solver/nimble_versions
import repro_nimble_reader
import repro_nimble_index
import repro_nimble_fetch
import repro_workspace_manifests
import shared_clones
from repro_core/ambient_execution import uncontrolledExecArgvEx
from repro_core/workspace_root import findWorkspaceRoot

import ./nimble_lock
import ./catalog_discovery

const
  NimbleOverridePrefix* = "nimble:"
    ## An override's `package` for a Nimble catalog package: the lock row's
    ## name.
  NimbleDevelopProvenancePrefix* = "repro nimble develop "

type
  SiblingCheckout* = object
    dir*: string                    ## absolute
    remotes*: seq[(string, string)] ## (remote name, fetch URL)

  NimbleDevelopProposal* = object
    package*: string   ## the canonical name
    origin*: string    ## the lock row's origin (without `?subdir=`)
    siblings*: seq[string]
      ## the checkouts one of whose remotes has the origin's identity

  NimbleNamesake* = object
    ## A checkout named like a locked package whose remotes are not its
    ## origin: not proposed (a fork is recorded with `--source`).
    package*: string
    dir*: string
    remotes*: seq[string]

  NimbleDevelopError* = object of CatchableError

proc developError(msg: string) {.noreturn.} =
  raise newException(NimbleDevelopError, msg)

proc isNimbleOverride*(entry: DevelopOverrideEntry): bool =
  ## Whether ``entry`` overrides a Nimble catalog package.
  entry.package.startsWith(NimbleOverridePrefix)

proc originIdentity*(url: string): string =
  ## The origin identity of a fetch URL: the canonical remote identity
  ## (scheme, userinfo, a trailing `.git` or `/`, host case and a default
  ## port do not count), so `https://h/o/r.git` and `git@h:o/r` are one
  ## origin. A `?subdir=` is not part of the repository.
  var u = url
  let q = u.find("?subdir=")
  if q >= 0: u.setLen(q)
  canonicalRemoteIdentity(u)

proc isCheckout(dir: string): bool =
  dirExists(dir / ".git") or fileExists(dir / ".git")

proc gitRemotes*(dir: string): seq[(string, string)] =
  ## The fetch URL of every remote of the checkout ``dir``, by remote name.
  ## A query of the checkout's configuration; it changes nothing. Run
  ## outside the build graph: it is the command's own question about a
  ## working tree, as `repro develop` asks its checkouts.
  let ran =
    try:
      uncontrolledExecArgvEx(["git", "-C", dir, "config", "--get-regexp",
        "^remote\\..*\\.url$"], options = {poUsePath})
    except CatchableError:
      return
  if ran.exitCode != 0:
    return
  for line in ran.output.splitLines():
    let l = line.strip()
    let sp = l.find(' ')
    if sp <= 0: continue
    let key = l[0 ..< sp]
    if not (key.startsWith("remote.") and key.endsWith(".url")): continue
    result.add (key["remote.".len ..< key.len - ".url".len],
      l[sp + 1 .. ^1].strip())

proc siblingCheckouts*(projectDir, workspaceRoot: string): seq[SiblingCheckout] =
  ## The checkouts beside the project (the entries of its parent directory)
  ## and in the workspace root, sorted by path; the project itself is not
  ## one.
  let project = normalizedPath(absolutePath(projectDir))
  var seen: seq[string]
  var bases = @[parentDir(project)]
  if workspaceRoot.len > 0:
    bases.add normalizedPath(absolutePath(workspaceRoot))
  for base in bases:
    if not dirExists(base): continue
    for kind, path in walkDir(base):
      if kind notin {pcDir, pcLinkToDir}: continue
      let dir = normalizedPath(path)
      if dir == project or dir in seen or not isCheckout(dir): continue
      seen.add dir
  seen.sort()
  for dir in seen:
    result.add SiblingCheckout(dir: dir, remotes: gitRemotes(dir))

proc hasOrigin(s: SiblingCheckout; identity: string): bool =
  for (_, url) in s.remotes:
    if originIdentity(url) == identity:
      return true

proc proposeNimbleOverrides*(rows: seq[NimbleLockRow];
                             siblings: seq[SiblingCheckout]):
    tuple[proposals: seq[NimbleDevelopProposal];
          namesakes: seq[NimbleNamesake]] =
  ## For each locked package, the siblings whose remote has its origin
  ## identity; and every sibling named like a package (Nimble's style-
  ## insensitive comparison) that is not one of them.
  for row in rows:
    let want = originIdentity(row.origin)
    var p = NimbleDevelopProposal(package: row.name, origin: row.origin)
    for s in siblings:
      if s.hasOrigin(want):
        p.siblings.add s.dir
    if p.siblings.len > 0:
      result.proposals.add p
    for s in siblings:
      if repro_nimble_index.nameKey(extractFilename(s.dir)) ==
          repro_nimble_index.nameKey(row.name) and s.dir notin p.siblings:
        result.namesakes.add NimbleNamesake(package: row.name, dir: s.dir,
          remotes: s.remotes.mapIt(it[1]))

# ---------------------------------------------------------------------------
# The overrides a build sees
# ---------------------------------------------------------------------------

proc overrideFilesFor*(projectDir: string): seq[string] =
  ## The directories whose `.repro/develop-overrides.toml` a build of
  ## ``projectDir`` reads, in precedence order: the project's own, then the
  ## enclosing workspace root's (as the lock's dependency locator reads
  ## them).
  let dir = normalizedPath(absolutePath(projectDir))
  result.add dir
  let ws = findWorkspaceRoot(dir)
  if ws.len > 0:
    let w = normalizedPath(absolutePath(ws))
    if w != dir: result.add w

proc readOverrides(root: string): seq[DevelopOverrideEntry] =
  let doc = readDevelopOverridesFile(root)
  if doc.isSome:
    result = listOverrides(doc.get())

proc developOverridesOf*(projectDir: string):
    seq[tuple[entry: DevelopOverrideEntry; dir: string]] =
  ## Every develop override a build of ``projectDir`` sees, with its
  ## checkout as an absolute path; an entry of the project's file shadows
  ## the workspace's entry of the same package. A file that cannot be read
  ## is an error: a build must not silently build something other than what
  ## the developer recorded.
  var seen: seq[string]
  for root in overrideFilesFor(projectDir):
    var entries: seq[DevelopOverrideEntry]
    try:
      entries = readOverrides(root)
    except CatchableError as e:
      developError(developOverridesPath(root) & " cannot be read: " & e.msg)
    for e in entries:
      if e.package.len == 0 or e.local_path.len == 0 or e.package in seen:
        continue
      seen.add e.package
      var dir = normalizedPath(absolutePath(e.local_path, root))
      if dirExists(dir):
        # The physical spelling, as the compiler reports the files it reads.
        try: dir = expandFilename(dir)
        except OSError: discard
      result.add (e, dir)

proc nimDevelopSiblings*(projectDir: string): seq[(string, string)] =
  ## The overrides that are not Nimble catalog packages, as the provider
  ## receives them (``NimDevelopSiblingsEnvVar``). Unreadable override files
  ## contribute nothing here; the `nimble:` step reports them.
  try:
    for (e, dir) in developOverridesOf(projectDir):
      if not e.isNimbleOverride:
        result.add (e.package, dir)
  except NimbleDevelopError:
    discard

# ---------------------------------------------------------------------------
# What a sibling requires, against the locked record
# ---------------------------------------------------------------------------

proc requirementKey(e: RequirementEntry): string =
  var cond = ""
  for n in e.condition: cond.add $n & ";"
  [cond, $e.targetKind, e.target, e.subdir, $e.versionKind, e.constraint,
   e.features.join(",")].join("\x1f")

proc requirementLines(rec: VersionRecord):
    seq[tuple[key, text: string]] =
  ## The record's requirements as comparable keys with their text: its
  ## `requires`, its `nim` requirements and each feature's (the root-only
  ## `dev` feature included, for the package being developed).
  for e in rec.requires:
    result.add ("requires\x1e" & requirementKey(e), "requires " & e.source.escape())
  for e in rec.nim:
    result.add ("nim\x1e" & requirementKey(e), "requires " & e.source.escape())
  for f in rec.features:
    for e in f.requires:
      result.add ("feature " & f.name & (if f.rootOnly: " dev" else: "") &
        "\x1e" & requirementKey(e),
        "feature " & f.name & " requires " & e.source.escape())

proc requirementChanges*(locked, sibling: VersionRecord): seq[string] =
  ## What the sibling's `.nimble` requires that the locked record does not
  ## (`+ ...`) and what the record requires that the sibling no longer does
  ## (`- ...`). Empty when the two closures are the same.
  let a = requirementLines(locked)
  let b = requirementLines(sibling)
  let aKeys = a.mapIt(it.key)
  let bKeys = b.mapIt(it.key)
  for l in b:
    if l.key notin aKeys: result.add "+ " & l.text
  for l in a:
    if l.key notin bKeys: result.add "- " & l.text

proc siblingRecord*(packageDir: string; packageName: string):
    tuple[file: NimbleFile; record: VersionRecord] =
  ## The sibling's `.nimble`, read from its working tree by the static
  ## reader, and the record it would be. Refuses a directory with no
  ## `.nimble`, with several, and one whose requirements are not data.
  let reading = readPackageDir(packageDir)
  case reading.kind
  of prNoNimbleFile:
    developError("the develop sibling " & packageDir & " of nimble:" &
      packageName & " holds no .nimble file")
  of prAmbiguous:
    developError("the develop sibling " & packageDir & " of nimble:" &
      packageName & " holds more than one .nimble file (" &
      reading.candidates.join(", ") & "); Nimble refuses such a package")
  of prIoError:
    developError("the develop sibling " & packageDir & " of nimble:" &
      packageName & " cannot be read: " & reading.message)
  of prRead:
    discard
  if flUnreadable in reading.file.flags:
    var why: seq[string]
    for i in reading.file.issues: why.add i.detail
    developError("the develop sibling's " & reading.nimbleFile & " is not " &
      "read statically (" & why.join("; ") & "), so what it requires is " &
      "not known without running it; nimble:" & packageName &
      " cannot be developed from it")
  result.file = reading.file
  try:
    result.record = recordFromNimbleFile(reading.file, VersionFacts())
  except CatchableError as e:
    developError("the develop sibling's " & reading.nimbleFile & ": " & e.msg)

proc replacedIdentity*(row: NimbleLockRow): string =
  ## What an override of ``row`` records as the identity it replaces
  ## (`replaces`): the lock row's origin, commit and tree.
  originUrl(row) & "#" & row.commit & " blake3:" & row.tree

# ---------------------------------------------------------------------------
# The repos the workspace declares (NPC-AREQ27 item 1)
# ---------------------------------------------------------------------------

type
  DeclaredRepo* = object
    ## A repo the workspace declares: in its membership, in a `repos/*.toml`
    ## fragment, or in the develop set. Collected by the CLI, which reads
    ## the manifests; matched here by identity only.
    name*: string
    checkout*: string ## absolute
    fetchUrl*: string
    declaredBy*: string ## "membership", "fragment" or "develop set"

  NimbleOverrideKind* = enum
    nokRecorded = "recorded override"
    nokDeclared = "declared repo"

  NimbleOverride* = object
    ## One override in effect for a lock row.
    package*: string ## canonical name, without `nimble:`
    kind*: NimbleOverrideKind
    repo*: string    ## the declared repo's name (``nokDeclared``)
    checkout*: string ## absolute
    packageDir*: string ## ``checkout``, or ``checkout/<subdir>``
    entry*: DevelopOverrideEntry ## the recorded entry (``nokRecorded``)

proc how*(o: NimbleOverride): string =
  ## `declared repo <repo>` or `recorded override`, as the build and
  ## `repro.paths` say it (NPC-AREQ27 item 7).
  case o.kind
  of nokDeclared: "declared repo " & o.repo
  of nokRecorded: "recorded override"

proc relPath(dir, base: string): string =
  try: relativePath(dir, base).replace('\\', '/')
  except CatchableError: dir

proc shownDir*(o: NimbleOverride; projectDir: string): string =
  ## The checkout as the build's line names it: relative to the project.
  relPath(o.packageDir, normalizedPath(absolutePath(projectDir)))

proc declaredMatches*(row: NimbleLockRow; declared: seq[DeclaredRepo]):
    seq[DeclaredRepo] =
  ## The declared repos whose fetch URL has ``row``'s origin identity, each
  ## checkout once. The comparison is of canonical remote identities; the
  ## repo's name and its checkout's directory name take no part.
  let want = originIdentity(row.origin)
  var seen: seq[string]
  for d in declared:
    if d.fetchUrl.len == 0: continue
    if originIdentity(d.fetchUrl) != want: continue
    let at = normalizedPath(d.checkout)
    if at in seen: continue
    seen.add at
    result.add d

# ---------------------------------------------------------------------------
# The overrides in effect
# ---------------------------------------------------------------------------

proc nimbleFileName(reading: PackageReading): string =
  if reading.kind == prRead: splitFile(reading.nimbleFile).name else: ""

proc effectiveNimbleOverrides*(rows: seq[NimbleLockRow]; projectDir: string;
                               declared: seq[DeclaredRepo]; locked: bool):
    tuple[overrides: seq[NimbleOverride]; lines, refusals: seq[string];
          recordedUnmatched: seq[string]] =
  ## The override of each row (NPC-AREQ27): its recorded override, else the
  ## one declared repo of its origin identity. The ``lines`` the build
  ## prints (a declared repo with no checkout, item 2); the ``refusals``
  ## (two declared repos of one identity, item 3; a package directory that
  ## is missing or holds another package's `.nimble`, item 4). Under
  ## ``locked`` every override is still found -- the build names each one
  ## it sets aside -- and nothing is refused.
  var recorded = initTable[string, tuple[entry: DevelopOverrideEntry;
                                         dir: string]]()
  for (e, dir) in developOverridesOf(projectDir):
    if e.isNimbleOverride:
      recorded[e.package] = (e, dir)
  var matched: seq[string]
  for row in rows:
    let key = NimbleOverridePrefix & row.name
    if key in recorded:
      matched.add key
      let (e, dir) = recorded[key]
      result.overrides.add NimbleOverride(package: row.name,
        kind: nokRecorded, checkout: dir, entry: e,
        packageDir: if row.subdir.len > 0: dir / row.subdir else: dir)
      continue
    let found = declaredMatches(row, declared)
    if found.len == 0:
      continue
    if found.len > 1:
      if locked:
        for d in found:
          result.lines.add "--locked: " & key & " is not overridden by " &
            "declared repo " & d.name & " (" & d.checkout & ")"
        continue
      result.refusals.add key & ": the declared repos " &
        found.mapIt(it.name & " (" & it.checkout & ")").join(" and ") &
        " both have its origin identity " & originIdentity(row.origin) &
        ", so neither overrides it. Record the one to build with `repro " &
        "nimble develop " & row.name & " --source=<dir>`, or build the " &
        "locked tree with `--locked`"
      continue
    let d = found[0]
    if not (dirExists(d.checkout) and isCheckout(d.checkout)):
      result.lines.add key & ": declared repo " & d.name & " has no " &
        "checkout at " & d.checkout & "; building the locked tree"
      continue
    let packageDir =
      if row.subdir.len > 0: d.checkout / row.subdir else: d.checkout
    let o = NimbleOverride(package: row.name, kind: nokDeclared,
      repo: d.name, checkout: d.checkout, packageDir: packageDir)
    if locked:
      result.overrides.add o
      continue
    if row.subdir.len > 0 and not dirExists(packageDir):
      result.refusals.add key & ": declared repo " & d.name & " (" &
        d.checkout & ") has its origin, whose package directory is the " &
        "subdir " & row.subdir.escape() & ", and the checkout has no " &
        packageDir
      continue
    let reading = readPackageDir(packageDir)
    let named = nimbleFileName(reading)
    if reading.kind == prRead and
        repro_nimble_index.nameKey(named) != repro_nimble_index.nameKey(row.name):
      result.refusals.add key & ": declared repo " & d.name & " (" &
        d.checkout & ") has its origin, and its package directory " &
        packageDir & " holds " & extractFilename(reading.nimbleFile) &
        ", a package named " & named.escape() & ", not " & row.name.escape() &
        " (renamed, or the package lives in another subdir); record the " &
        "checkout to build with `repro nimble develop " & row.name &
        " --source=<dir>`, or build `--locked`"
      continue
    result.overrides.add o
  for key in toSeq(recorded.keys).sorted():
    if key notin matched:
      result.recordedUnmatched.add key
      result.lines.add "the develop override of " & key & " (" &
        recorded[key].dir & ") names no package the lock pins; it is not " &
        "applied"

# ---------------------------------------------------------------------------
# The develop overlay lock (spec §13.1)
# ---------------------------------------------------------------------------

const
  DevelopOverlayFile* = "develop.lock"
  OverlayHeaderTitle =
    "# reprobuild develop overlay lock: local state, never committed"
  OverlayBaseKey = "# develop-overlay-base: "
  OverlayOverrideKey = "# develop-overlay-override: "

type
  OverlayOverride* = object
    package*: string  ## `nimble:<name>`
    checkout*: string ## absolute package directory
    how*: string      ## `declared repo <repo>` / `recorded override`
    requirements*: string ## `blake3:<digest>` of what the checkout requires

  DevelopOverlay* = object
    base*: string ## `blake3:<digest>` of the committed lock's bytes
    overrides*: seq[OverlayOverride]
    lockText*: string ## the overlay's lock, in the committed lock's format

proc developOverlayPath*(lockPath: string): string =
  ## `.repro/develop.lock` in the directory of the committed lock.
  parentDir(absolutePath(lockPath)) / ".repro" / DevelopOverlayFile

proc lockDigest*(bytes: string): string =
  "blake3:" & toHexLower(blake3.digest(bytes))

proc requirementsDigest*(rec: VersionRecord): string =
  ## The digest of what a checkout's `.nimble` requires: every requirement
  ## ``requirementChanges`` compares, sorted.
  var keys = requirementLines(rec).mapIt(it.key)
  keys.sort()
  lockDigest("reprobuild.develop-overlay.requirements.v1\n" & keys.join("\n"))

proc overrideLine(o: OverlayOverride): string =
  [o.package, o.checkout, o.how, o.requirements].join("\t")

proc renderOverlay*(ov: DevelopOverlay): string =
  ## The overlay's bytes: a header of comment lines a lock reader skips,
  ## then the lock. So every lock reader reads the overlay's rows
  ## (`repro lock diff repro.lock .repro/develop.lock`), and no reader of
  ## the committed lock's format meets a key it does not know.
  result = OverlayHeaderTitle & " (Nimble-Package-Catalog §13.1).\n" &
    "# Written by `repro nimble develop --relock`; a build reads it only " &
    "while its base and\n# overrides are the ones in effect.\n"
  result.add OverlayBaseKey & ov.base & "\n"
  for o in ov.overrides:
    result.add OverlayOverrideKey & overrideLine(o) & "\n"
  result.add ov.lockText

proc parseOverlay*(text: string): Option[DevelopOverlay] =
  ## The overlay ``text`` holds, or none when its header is not one.
  if not text.startsWith(OverlayHeaderTitle):
    return none(DevelopOverlay)
  var ov: DevelopOverlay
  for line in text.splitLines():
    if line.startsWith(OverlayBaseKey):
      ov.base = line[OverlayBaseKey.len .. ^1].strip()
    elif line.startsWith(OverlayOverrideKey):
      let parts = line[OverlayOverrideKey.len .. ^1].split('\t')
      if parts.len != 4: return none(DevelopOverlay)
      ov.overrides.add OverlayOverride(package: parts[0], checkout: parts[1],
        how: parts[2], requirements: parts[3])
  if ov.base.len == 0:
    return none(DevelopOverlay)
  ov.lockText = text
  some(ov)

proc overlayMismatch*(ov: DevelopOverlay; base: string;
                      inEffect: seq[OverlayOverride]): seq[string] =
  ## What differs between the overlay and what the build has in effect:
  ## the base, the override set, a requirement digest. Empty when it
  ## matches and may be read.
  if ov.base != base:
    result.add "the committed lock changed since the re-lock (base " &
      ov.base & ", now " & base & ")"
  var want = initTable[string, OverlayOverride]()
  for o in inEffect: want[o.package] = o
  var have = initTable[string, OverlayOverride]()
  for o in ov.overrides: have[o.package] = o
  for k in toSeq(want.keys).sorted():
    if k notin have:
      result.add "the override of " & k & " (" & want[k].how &
        ") is not in the re-lock"
    elif have[k].checkout != want[k].checkout or have[k].how != want[k].how:
      result.add "the override of " & k & " is now " & want[k].checkout &
        " (" & want[k].how & "); the re-lock was for " & have[k].checkout &
        " (" & have[k].how & ")"
    elif have[k].requirements != want[k].requirements:
      result.add "the requirements of " & want[k].checkout & " (" & k &
        ") changed since the re-lock"
  for k in toSeq(have.keys).sorted():
    if k notin want:
      result.add "the re-lock was for an override of " & k &
        ", which is no longer in effect"

proc overlayDiffers*(committedText, overlayText: string): seq[string] =
  ## Each `nimble:` row of the overlay that differs from the committed
  ## lock's: `+ nimble:<name> <version>` (added), `- nimble:<name>
  ## <version>` (gone), `~ nimble:<name> <old> -> <new>` (moved), `~
  ## nimble:<name> <version> depends on ...` (its edges changed).
  var before = initTable[string, LockedDep]()
  for d in parseLockedDependencies(committedText).deps:
    if d.isNimbleDep: before[d.name] = d
  var after = initTable[string, LockedDep]()
  for d in parseLockedDependencies(overlayText).deps:
    if d.isNimbleDep: after[d.name] = d
  var names = toSeq(before.keys)
  for k in after.keys:
    if k notin names: names.add k
  names.sort()
  proc edges(d: LockedDep): string =
    let e = d.depends.sorted()
    if e.len > 0: e.join(", ") else: "nothing"
  for k in names:
    if k notin after:
      result.add "- " & k & " " & before[k].version
    elif k notin before:
      result.add "+ " & k & " " & after[k].version
    elif before[k].coordinates.revision != after[k].coordinates.revision or
        before[k].integrity != after[k].integrity:
      result.add "~ " & k & " " & before[k].version & " -> " &
        after[k].version
    elif edges(before[k]) != edges(after[k]):
      result.add "~ " & k & " " & after[k].version & " depends on " &
        edges(after[k]) & " (the committed lock: " & edges(before[k]) & ")"

# ---------------------------------------------------------------------------
# The build's step
# ---------------------------------------------------------------------------

type
  DevelopApplication* = object
    lines*: seq[string]
      ## what the build prints: each override applied and each set aside
    overlayRead*: string
      ## the overlay the build reads instead of the committed lock, when an
      ## override's requirements differ and it matches; "" otherwise
    overrides*: seq[NimbleOverride] ## the overrides applied

  ApplyCheck = object
    o: NimbleOverride
    sibling: tuple[file: NimbleFile; record: VersionRecord]
    changes: seq[string]

proc inEffectOf(checks: seq[ApplyCheck]): seq[OverlayOverride] =
  for c in checks:
    if c.changes.len > 0:
      result.add OverlayOverride(package: NimbleOverridePrefix & c.o.package,
        checkout: c.o.packageDir, how: c.o.how,
        requirements: requirementsDigest(c.sibling.record))

proc applyNimbleDevelopOverrides*(report: var NimbleSourcesReport;
    projectDir, lockPath: string; locked: bool;
    declared: seq[DeclaredRepo] = @[];
    reprepare: proc (lockPath: string): NimbleSourcesReport = nil):
    DevelopApplication =
  ## The build's step (see the module header). ``lockPath`` is the
  ## committed lock the report was prepared from; ``reprepare`` prepares
  ## the sources of another lock (the overlay's). Raises
  ## ``NimbleDevelopError`` for an override that cannot be applied.
  if not report.active:
    return
  let overlayPath = if lockPath.len > 0: developOverlayPath(lockPath) else: ""
  let eff = effectiveNimbleOverrides(report.rows, projectDir, declared, locked)
  result.lines.add eff.lines
  if locked:
    for o in eff.overrides:
      var tree = ""
      for p in report.packages:
        if p.row.name == o.package: tree = p.row.tree
      result.lines.add "--locked: the develop override of " &
        NimbleOverridePrefix & o.package & " (" & o.shownDir(projectDir) &
        ", " & o.how & ") is not applied; building blake3:" & tree
    if overlayPath.len > 0 and fileExists(overlayPath):
      result.lines.add "--locked: the develop overlay lock " & overlayPath &
        " is not read"
    return
  var refusals = eff.refusals
  var byName = initTable[string, NimbleOverride]()
  for o in eff.overrides: byName[o.package] = o
  var checks: seq[ApplyCheck]
  for p in report.packages:
    if p.row.name notin byName: continue
    let o = byName[p.row.name]
    let key = NimbleOverridePrefix & p.row.name
    if o.kind == nokRecorded:
      # The override says which locked identity it replaced. When the lock
      # has moved since, the record is stale: say so, rather than let it
      # name an identity the build no longer replaces.
      let now = replacedIdentity(p.row)
      if o.entry.replaces.isSome and o.entry.replaces.get().len > 0 and
          o.entry.replaces.get() != now:
        result.lines.add "the develop override of " & key & " was recorded " &
          "replacing " & o.entry.replaces.get() & "; the lock now pins " &
          now & ": record it again with `repro nimble develop " &
          p.row.name & "`"
      if not dirExists(o.checkout):
        refusals.add "the develop override of " & key & " names " &
          o.checkout & ", which does not exist; record it again with " &
          "`repro nimble develop " & p.row.name & "` or drop it with " &
          "`repro develop --drop " & key & "`"
        continue
    var sibling: tuple[file: NimbleFile; record: VersionRecord]
    try:
      sibling = siblingRecord(o.packageDir, p.row.name)
    except NimbleDevelopError as e:
      refusals.add e.msg & " (" & o.how & ")"
      continue
    checks.add ApplyCheck(o: o, sibling: sibling,
      changes: requirementChanges(p.record, sibling.record))
  if refusals.len > 0:
    developError(refusals.join("\n  "))
  # §13.1: an override whose checkout requires what its record does not is
  # built from the develop overlay lock when that matches what is in
  # effect, and refused otherwise.
  let inEffect = inEffectOf(checks)
  if inEffect.len > 0:
    var why: seq[string]
    var overlay = none(DevelopOverlay)
    if overlayPath.len > 0 and fileExists(overlayPath):
      overlay = parseOverlay(readFile(overlayPath))
      if overlay.isNone:
        why.add overlayPath & " is not a develop overlay lock"
      else:
        why.add overlayMismatch(overlay.get(),
          lockDigest(readFile(lockPath)), inEffect)
    else:
      why.add "there is no develop overlay lock (" & overlayPath & ")"
    if why.len > 0:
      var diffs: seq[string]
      for c in checks:
        if c.changes.len > 0:
          diffs.add "the develop checkout " & c.o.packageDir & " of " &
            NimbleOverridePrefix & c.o.package & " (" & c.o.how &
            ") requires what the locked record does not:\n    " &
            c.changes.join("\n    ")
      developError("re-lock required: " & diffs.join("\n  ") &
        "\n  The committed lock no longer describes this closure, and the " &
        "develop overlay lock is not read: " & why.join("; ") &
        ".\n  Write it with `repro nimble develop --relock`, build the lock " &
        "with `--locked`, or drop the override")
    if reprepare == nil:
      developError("re-lock required: the develop overlay lock " &
        overlayPath & " matches, but this caller cannot read it")
    var fromOverlay = reprepare(overlayPath)
    let moved = overlayDiffers(readFile(lockPath), readFile(overlayPath)).len
    result.overlayRead = overlayPath
    result.lines.add "building from the develop overlay lock (" & $moved &
      " rows differ from " & lockPath & ")"
    report = fromOverlay
  elif overlayPath.len > 0 and fileExists(overlayPath):
    result.lines.add "the develop overlay lock " & overlayPath & " is " &
      "unused: no override in effect requires what its record does not"
  refusals = @[]
  for c in checks:
    let key = NimbleOverridePrefix & c.o.package
    var idx = -1
    for i, p in report.packages:
      if p.row.name == c.o.package: idx = i
    if idx < 0:
      continue
    var parts: seq[string]
    for part in c.sibling.file.srcDir.replace('\\', '/').split('/'):
      if part.len > 0 and part != ".": parts.add part
    # The same rule as for a store tree: a `srcDir` that leaves the
    # package hands the compile a directory the override did not name.
    if c.sibling.file.srcDir.isAbsolute or ".." in parts:
      refusals.add "the develop sibling " & c.o.packageDir & " of " & key &
        ": its srcDir " & c.sibling.file.srcDir.escape() & " leaves the " &
        "package's tree"
      continue
    let src = sourceDir(c.sibling.file, c.o.packageDir)
    if not dirExists(src):
      refusals.add "the develop sibling " & c.o.packageDir & " of " & key &
        ": its srcDir " & c.sibling.file.srcDir.escape() &
        " is not a directory"
      continue
    report.packages[idx].developDir = c.o.packageDir
    report.packages[idx].srcPath = src
    result.overrides.add c.o
    result.lines.add key & " <- " & c.o.shownDir(projectDir) & " (" &
      c.o.how & "); lock pins " & report.packages[idx].row.commit
  if refusals.len > 0:
    developError(refusals.join("\n  "))
  report.nimPathDirs = report.packages.mapIt(it.srcPath)

proc pathsNote*(o: NimbleOverride; projectDir: string): string =
  ## What `repro.paths` says before the line of ``o``'s package.
  o.shownDir(projectDir) & " (" & o.how & ")"

# ---------------------------------------------------------------------------
# The re-lock (spec §13.1, "Who writes it")
# ---------------------------------------------------------------------------

type
  RelockChosen = object
    name: string ## canonical
    envelope: PackageEnvelope
    cand: NimbleCandidate
    requires: seq[SolverRequirement]
    overriddenBy: string ## the checkout whose requirements these are

  RelockOutcome* = object
    refusals*: seq[string]
    overlay*: DevelopOverlay
    differs*: seq[string] ## each row that differs from the committed lock

proc admitsCandidate(r: SolverRequirement; c: NimbleCandidate): bool =
  if c.version.len == 0: return false
  if isPseudoRequirement(r.entry): return false # decided by ``matchPseudo``
  if r.range.len == 0:
    return not c.version.startsWith("#") or c.version.startsWith("#snapshot/")
  if c.version.startsWith("#"): return false
  nimbleRangeAdmits(r.range, c.version)

proc solveDevelopOverlay*(projectDir, lockPath: string;
    checkouts: seq[tuple[o: NimbleOverride; record: VersionRecord]]):
    RelockOutcome =
  ## The develop overlay lock's solve: from the committed lock's pins, with
  ## each overridden package's record requirements replaced by those its
  ## checkout's `.nimble` states. A row stays at its pin unless a
  ## requirement no longer admits it; a package a requirement newly names
  ## is added at the newest offered version every requirement on it admits.
  ## A requirement no imported index offers is refused, naming it and the
  ## checkout that added it.
  let text = readFile(lockPath)
  var ld = parseLockedDependencies(text)
  let rows = nimbleRowsOf(ld)
  var pins: seq[LockedCatalogImport]
  for p in ld.lockedCatalogImportPins():
    pins.add p
  let answer = catalogsForBuild(projectDir, pins, @[])
  if answer.nimbleIndexes.len != 1:
    result.refusals.add "the re-lock reads exactly one Nimble index; the " &
      "lock pins " & $answer.nimbleIndexes.len
    return
  let index = answer.nimbleIndexes[0]
  var idx = openNimbleIndex(index)
  let platform = nimblePlatformOf(
    if ld.platform.len > 0: ld.platform else: currentPlatformId())
  var solvedNim = ""
  for p in ld.packages:
    if p.name == "nim": solvedNim = p.version
  var options = NimbleSolveOptions(excludeNewer: -1,
    nimDeclared: solvedNim.len > 0, indexRepo: index.repo,
    catalogsFile: projectDir / CatalogImportsFileName)
  # The project's acceptances decide the origin as they do for the
  # committed lock's solve (NPC-AREQ16); without one, the lock row's URL and
  # commit name the entry (a revival entry shares its URL with the origin it
  # revives).
  var acceptRefusals: seq[string]
  options.acceptances = nimbleAcceptances(projectDir, index, acceptRefusals)
  acceptRefusals.add acceptanceRefusals(idx, options,
    "the Nimble index \"" & index.repo & "\" at " & index.revision)
  if acceptRefusals.len > 0:
    result.refusals.add acceptRefusals
    return
  var depOf = initTable[string, LockedDep]()
  for d in ld.deps:
    if d.isNimbleDep:
      depOf[d.name] = d
      let k = repro_nimble_index.nameKey(d.name[NimbleOverridePrefix.len .. ^1])
      options.acceptedOrigins[k] = d.coordinates.url
      options.acceptedCommits[k] = d.coordinates.revision
  let nimValue = nimVersionValueOf(solvedNim)
  proc active(reqs: seq[SolverRequirement]): seq[SolverRequirement] =
    for r in reqs:
      if not r.nimGated or (nimValue.isSome and
          activeOn(r.entry.condition, platform, nimValue)):
        result.add r
  var envelopes = initTable[string, PackageEnvelope]()
  proc envelopeOf(name: string; found: var bool): PackageEnvelope =
    let k = repro_nimble_index.nameKey(name)
    if k in envelopes:
      found = true
      return envelopes[k]
    let l = lookupPackage(idx, name)
    found = l.found
    if l.found:
      envelopes[k] = l.package
      envelopes[repro_nimble_index.nameKey(l.package.name)] = l.package
      result = l.package
  var chosen = initOrderedTable[string, RelockChosen]()
  var overriddenOf = initTable[string, (NimbleOverride, VersionRecord)]()
  for (o, rec) in checkouts:
    overriddenOf[repro_nimble_index.nameKey(o.package)] = (o, rec)
  for row in rows:
    var found = false
    let env = envelopeOf(row.name, found)
    if not found:
      result.refusals.add "nimble:" & row.name & " is not a package of " &
        "the pinned index; re-solve the committed lock with `repro lock " &
        "refresh`"
      continue
    var c = RelockChosen(name: env.name, envelope: env)
    var hit = false
    for cand in candidatesOf(env, platform, options):
      if cand.record.commit == row.commit and $cand.record.tree == row.tree:
        c.cand = cand
        hit = true
        break
    if not hit:
      result.refusals.add "nimble:" & row.name & " (commit " & row.commit &
        ") is not a record of the pinned index; re-solve the committed " &
        "lock with `repro lock refresh`"
      continue
    c.requires = c.cand.requires
    let k = repro_nimble_index.nameKey(env.name)
    if k in overriddenOf:
      let (o, rec) = overriddenOf[k]
      var sib = rec
      sib.commit = row.commit
      sib.version = c.cand.record.version
      let sc = candidate(env, sib, platform, options)
      c.requires = sc.requires
      c.cand.features = sc.features
      c.overriddenBy = o.packageDir
    chosen[k] = c
  if result.refusals.len > 0:
    return
  var refused = initHashSet[string]()
  for round in 0 ..< 64:
    var changed = false
    # Every requirement of every chosen row, with the features requirers
    # name added to their targets' requirements.
    var features = initTable[string, HashSet[string]]()
    for c in chosen.values:
      for r in active(c.requires):
        if r.features.len > 0:
          let k = repro_nimble_index.nameKey(requirementTargetName(r.entry))
          for f in r.features:
            features.mgetOrPut(k, initHashSet[string]()).incl f
    var on = initOrderedTable[string,
      seq[tuple[r: SolverRequirement; by: string]]]()
    for k, c in chosen.pairs:
      var reqs = active(c.requires)
      for (f, fr) in c.cand.features:
        if f in features.getOrDefault(k): reqs.add active(fr)
      let by = "nimble:" & c.name & " " & c.cand.version &
        (if c.overriddenBy.len > 0: " (checkout " & c.overriddenBy & ")"
         else: "")
      for r in reqs:
        let target = requirementTargetName(r.entry)
        var found = false
        let env = envelopeOf(target, found)
        if not found:
          let what = "requires " & r.entry.source.escape()
          if (by & what) notin refused:
            refused.incl by & what
            result.refusals.add by & " " & what & ", which no imported " &
              "index offers (" & index.repo & " at " & index.revision & ")"
          continue
        on.mgetOrPut(repro_nimble_index.nameKey(env.name), @[]).add (r, by)
    if result.refusals.len > 0:
      return
    for k, reqs in on.pairs:
      var env: PackageEnvelope
      var found = false
      env = envelopeOf(reqs[0].r.entry.requirementTargetName, found)
      var cands = candidatesOf(env, platform, options)
      var pkg = NimbleSolverPackage(name: env.name,
        identity: "nimble:" & env.name, origins: env.origins,
        candidates: cands)
      var pseudoPick = -1
      var pseudoWhy = ""
      for (r, by) in reqs:
        if isPseudoRequirement(r.entry):
          let m = admitPseudo(pkg, r.entry)
          if m.found and (pseudoPick < 0 or pseudoPick == m.index):
            pseudoPick = m.index
          else:
            pseudoWhy = (if m.found: "two pseudo-version requirements " &
              "name different records" else: m.why)
      cands = pkg.candidates
      proc fits(i: int): bool =
        if not cands[i].offered: return false
        for (r, _) in reqs:
          if isPseudoRequirement(r.entry):
            if i != pseudoPick: return false
          elif not admitsCandidate(r, cands[i]): return false
        true
      if k in chosen:
        var at = -1
        for i, c in cands:
          if c.record.commit == chosen[k].cand.record.commit and
              $c.record.tree == $chosen[k].cand.record.tree and
              c.version == chosen[k].cand.version:
            at = i
        if at >= 0 and fits(at):
          continue
        # The pinned record satisfies every range that is not a
        # pseudo-version's: it is held.
        if at < 0 and reqs.allIt(not isPseudoRequirement(it.r.entry) and
            admitsCandidate(it.r, chosen[k].cand)):
          continue
      if pseudoWhy.len > 0:
        result.refusals.add "nimble:" & env.name & ": " & pseudoWhy
        return
      var best = -1
      for i in 0 ..< cands.len:
        if not fits(i): continue
        if best < 0:
          best = i
        elif not cands[i].version.startsWith("#") and
            not cands[best].version.startsWith("#") and
            cmpNimbleText(cands[i].version, cands[best].version) > 0:
          best = i
      if best < 0:
        result.refusals.add "no version of nimble:" & env.name &
          " the index offers satisfies " &
          reqs.mapIt(it.r.entry.source.escape() & " (" & it.by & ")").join(", ")
        return
      var c = RelockChosen(name: env.name, envelope: env, cand: cands[best],
        requires: cands[best].requires)
      if k in overriddenOf:
        c.requires = chosen[k].requires
        c.overriddenBy = chosen[k].overriddenBy
      chosen[k] = c
      changed = true
    if not changed:
      break
  # The overlay's lock: the committed lock with its `nimble:` rows replaced.
  var deps: seq[LockedDep]
  for d in ld.deps:
    if not d.isNimbleDep: deps.add d
  var newDeps: seq[LockedDep]
  for k, c in chosen.pairs:
    let identity = "nimble:" & c.name
    var dependsOn: seq[string]
    for r in active(c.requires):
      var found = false
      let env = envelopeOf(requirementTargetName(r.entry), found)
      if found and ("nimble:" & env.name) notin dependsOn:
        dependsOn.add "nimble:" & env.name
    dependsOn.sort()
    let old = depOf.getOrDefault(identity)
    if old.name.len > 0 and old.coordinates.revision == c.cand.record.commit and
        c.overriddenBy.len == 0:
      newDeps.add old
      continue
    var o = 0
    if int(c.cand.record.origin) < c.envelope.origins.len:
      o = int(c.cand.record.origin)
    let origin = if c.envelope.origins.len > 0: c.envelope.origins[o]
                 else: PackageOrigin()
    var row = NimbleLockRow(name: c.name, origin: origin.url,
      subdir: origin.subdir, commit: c.cand.record.commit,
      tree: $c.cand.record.tree)
    var dep = lockedDepOf(row)
    dep.version = c.cand.version
    dep.depends = dependsOn
    dep.catalog = index.repo
    dep.visibility = "public"
    if old.name.len > 0 and old.coordinates.revision == dep.coordinates.revision:
      dep.version = old.version
    newDeps.add dep
  newDeps.sort(proc (a, b: LockedDep): int = cmp(a.name, b.name))
  deps.add newDeps
  ld.deps = deps
  for p in ld.packages.mitems:
    for d in newDeps:
      if p.name == d.name: p.version = d.version
  for d in newDeps:
    if not ld.packages.anyIt(it.name == d.name) and
        ld.packages.anyIt(it.name.startsWith("nimble:")):
      var lp = ld.packages.filterIt(it.name.startsWith("nimble:"))[0]
      lp.source = if lp.source == lp.name: d.name else: ""
      lp.name = d.name
      lp.version = d.version
      ld.packages.add lp
  result.overlay.base = lockDigest(text)
  result.overlay.lockText = serializeLockedDependencies(ld)
  result.differs = overlayDiffers(text, result.overlay.lockText)
  for (o, rec) in checkouts:
    result.overlay.overrides.add OverlayOverride(
      package: NimbleOverridePrefix & o.package, checkout: o.packageDir,
      how: o.how, requirements: requirementsDigest(rec))
  result.overlay.overrides.sort(proc (a, b: OverlayOverride): int =
    cmp(a.package, b.package))

# ---------------------------------------------------------------------------
# `repro nimble develop`
# ---------------------------------------------------------------------------

proc lockedRecordsOf*(projectDir, lockPath: string):
    Table[string, VersionRecord] =
  ## The record of the pinned index each `nimble:` row of the lock was
  ## solved to, by canonical name. Reads the index; fetches no tree.
  let ld = parseLockedDependencies(readFile(lockPath))
  let rows = nimbleRowsOf(ld)
  let answer = catalogsForBuild(projectDir, ld.lockedCatalogImportPins(), @[])
  for d in answer.nimbleIndexes:
    var idx = openNimbleIndex(d)
    for row in rows:
      if row.name in result: continue
      let found = lookupPackage(idx, row.name)
      if not found.found: continue
      for rec in found.package.versions:
        if rec.commit == row.commit and $rec.tree == row.tree:
          result[row.name] = rec
          break

const OlderReaderNote* = "a repro that reads only schema v1 of this file " &
  "refuses it, and its build reads it as holding no overrides"

proc runRelock(verb, projectDir, lockPath: string; rows: seq[NimbleLockRow];
               declared: seq[DeclaredRepo]; dryRun: bool): int =
  let overlayPath = developOverlayPath(lockPath)
  let eff = effectiveNimbleOverrides(rows, projectDir, declared, false)
  for l in eff.lines: echo l
  if eff.refusals.len > 0:
    for r in eff.refusals: stderr.writeLine(verb & ": error: " & r)
    return 1
  var records: Table[string, VersionRecord]
  try:
    records = lockedRecordsOf(projectDir, lockPath)
  except CatchableError as e:
    stderr.writeLine(verb & ": error: " & e.msg)
    return 2
  var needs: seq[tuple[o: NimbleOverride; record: VersionRecord]]
  for o in eff.overrides:
    if o.package notin records:
      stderr.writeLine(verb & ": error: nimble:" & o.package & " of " &
        lockPath & " is not a record of the pinned index; re-solve the lock " &
        "with `repro lock refresh`")
      return 2
    var sibling: tuple[file: NimbleFile; record: VersionRecord]
    try:
      sibling = siblingRecord(o.packageDir, o.package)
    except NimbleDevelopError as e:
      stderr.writeLine(verb & ": error: " & e.msg)
      return 1
    if requirementChanges(records[o.package], sibling.record).len > 0:
      needs.add (o, sibling.record)
  if needs.len == 0:
    if fileExists(overlayPath):
      if dryRun:
        echo "would remove " & overlayPath & ": no override in effect " &
          "requires what its record does not"
      else:
        removeFile(overlayPath)
        echo "removed " & overlayPath & ": no override in effect requires " &
          "what its record does not"
    else:
      echo "no override in effect requires what its record does not; " &
        "nothing written"
    return 0
  var outcome: RelockOutcome
  try:
    outcome = solveDevelopOverlay(projectDir, lockPath, needs)
  except CatchableError as e:
    stderr.writeLine(verb & ": error: " & e.msg)
    return 2
  if outcome.refusals.len > 0:
    for r in outcome.refusals: stderr.writeLine(verb & ": error: " & r)
    return 1
  for d in outcome.differs: echo d
  if dryRun:
    echo "would write " & overlayPath & " (" & $outcome.differs.len &
      " rows differ from " & lockPath & ")"
    return 0
  try:
    createDir(parentDir(overlayPath))
    writeFile(overlayPath, renderOverlay(outcome.overlay))
  except CatchableError as e:
    stderr.writeLine(verb & ": error: " & overlayPath & ": " & e.msg)
    return 2
  echo "wrote " & overlayPath & " (" & $outcome.differs.len &
    " rows differ from " & lockPath & "); it is local state: never commit it"
  0

proc runNimbleDevelopCommand*(package, source, lockFlag,
    workspaceRootFlag: string; dryRun: bool; relock = false;
    declaredOf: proc (projectDir, lockPath: string): seq[DeclaredRepo] = nil):
    int =
  ## The verb: 0 when the overrides and proposals are listed, the override
  ## is recorded, the package is already overridden by a declared repo, or
  ## the overlay was written (or found unneeded); 1 when there is no
  ## checkout to record (none proposed, several, a `--source` that is not a
  ## package checkout) or `--relock` meets a requirement no imported index
  ## offers; 2 when the lock cannot be read or the package is not one of
  ## its `nimble:` packages. ``declaredOf`` answers the repos the workspace
  ## declares (the CLI reads the manifests).
  const verb = "repro nimble develop"
  let lockPath = absolutePath(if lockFlag.len > 0: lockFlag
                              else: getCurrentDir() / "repro.lock")
  var rows: seq[NimbleLockRow]
  try:
    if not fileExists(lockPath):
      raise newException(ValueError, "no lock at " & lockPath)
    rows = nimbleRowsOf(parseLockedDependencies(readFile(lockPath)))
  except CatchableError as e:
    stderr.writeLine(verb & ": error: " & e.msg)
    return 2
  if rows.len == 0:
    stderr.writeLine(verb & ": error: " & lockPath & " pins no nimble: " &
      "package")
    return 2
  let projectDir = parentDir(lockPath)
  let declared =
    if declaredOf != nil: declaredOf(projectDir, lockPath) else: @[]
  if relock:
    if package.len > 0 or source.len > 0:
      stderr.writeLine(verb & ": error: --relock takes no package and no " &
        "--source: it re-locks for every override in effect")
      return 2
    return runRelock(verb, projectDir, lockPath, rows, declared, dryRun)
  let wsFound = findWorkspaceRoot(projectDir)
  let workspaceRoot =
    if workspaceRootFlag.len > 0: absolutePath(workspaceRootFlag)
    elif wsFound.len > 0: absolutePath(wsFound)
    else: projectDir
  proc samePlace(a, b: string): bool =
    try: sameFile(a, b)
    except OSError: normalizedPath(a) == normalizedPath(b)
  if workspaceRootFlag.len > 0 and not overrideFilesFor(projectDir).anyIt(
      samePlace(it, workspaceRoot)):
    stderr.writeLine(verb & ": error: --workspace-root " & workspaceRootFlag &
      ": a build of " & projectDir & " reads the develop overrides of " &
      overrideFilesFor(projectDir).join(" and ") & ", not of " &
      workspaceRoot & "; an override recorded there would not be applied")
    return 2
  # A declared repo is never proposed: it overrides its package already.
  var siblings: seq[SiblingCheckout]
  for sib in siblingCheckouts(projectDir, workspaceRoot):
    if not declared.anyIt(samePlace(it.checkout, sib.dir)):
      siblings.add sib
  let (proposals, namesakes) = proposeNimbleOverrides(rows, siblings)
  var eff: tuple[overrides: seq[NimbleOverride]; lines, refusals: seq[string];
                 recordedUnmatched: seq[string]]
  try:
    eff = effectiveNimbleOverrides(rows, projectDir, declared, false)
  except NimbleDevelopError as e:
    stderr.writeLine(verb & ": error: " & e.msg)
    return 2

  if package.len == 0:
    for o in eff.overrides:
      echo "nimble:" & o.package & " <- " & o.shownDir(projectDir) & " (" &
        o.how & ")"
    for l in eff.lines: echo l
    for r in eff.refusals: echo "not overridden: " & r
    for p in proposals:
      if eff.overrides.anyIt(it.package == p.package and
          it.kind == nokRecorded):
        continue
      if p.siblings.len == 1:
        echo "propose nimble:" & p.package & " <- " &
          relPath(p.siblings[0], projectDir) & " (a remote is its origin " &
          originIdentity(p.origin) & ")"
      else:
        echo "ambiguous nimble:" & p.package & ": " &
          p.siblings.mapIt(relPath(it, projectDir)).join(", ") &
          " each have its origin " & originIdentity(p.origin) &
          " as a remote; record one with `" & verb & " " & p.package &
          " --source=<dir>`"
    for n in namesakes:
      echo "not proposed: " & relPath(n.dir, projectDir) &
        " is named like nimble:" & n.package & ", but its remotes (" &
        (if n.remotes.len > 0: n.remotes.join(", ") else: "none") &
        ") are not its origin " & originIdentity(
          rows.filterIt(it.name == n.package)[0].origin) &
        "; if it is a fork, record it with `" & verb & " " & n.package &
        " --source=" & relPath(n.dir, projectDir) & "`"
    if proposals.len == 0 and eff.overrides.len == 0:
      echo "no declared repo and no sibling checkout has the origin of a " &
        "nimble: package of " & lockPath
    elif proposals.len > 0:
      echo "nothing recorded: record a proposal with `" & verb &
        " <package>`"
    return 0

  var name = package
  if name.startsWith(NimbleOverridePrefix):
    name = name[NimbleOverridePrefix.len .. ^1]
  var row: NimbleLockRow
  var found = false
  for r in rows:
    if repro_nimble_index.nameKey(r.name) == repro_nimble_index.nameKey(name):
      row = r
      found = true
  if not found:
    stderr.writeLine(verb & ": error: " & package & " is not a nimble: " &
      "package of " & lockPath & " (it pins " &
      rows.mapIt("nimble:" & it.name).join(", ") & ")")
    return 2
  if source.len == 0:
    for o in eff.overrides:
      if o.package == row.name and o.kind == nokDeclared:
        echo "nimble:" & row.name & " is overridden by declared repo " &
          o.repo & " (" & o.shownDir(projectDir) & ") without a recorded " &
          "override; nothing recorded. Record another checkout with `" &
          verb & " " & row.name & " --source=<dir>`"
        return 0
  var dir = ""
  var how = ""
  if source.len > 0:
    dir = normalizedPath(absolutePath(source))
    if not dirExists(dir):
      stderr.writeLine(verb & ": error: --source " & source & ": " & dir &
        " is not a directory")
      return 1
    let identity = originIdentity(row.origin)
    let sib = SiblingCheckout(dir: dir, remotes: gitRemotes(dir))
    how =
      if sib.hasOrigin(identity): "a remote is its origin " & identity
      else: "named explicitly: its remotes are not the origin " & identity &
             " (a fork or another remote)"
  else:
    var candidates: seq[string]
    for p in proposals:
      if p.package == row.name: candidates = p.siblings
    if candidates.len == 0:
      var tip = ""
      for n in namesakes:
        if n.package == row.name:
          tip = "; " & relPath(n.dir, projectDir) & " is named like it, " &
            "but its remotes are not its origin. If it is a fork, name it " &
            "with --source"
      stderr.writeLine(verb & ": error: no undeclared sibling checkout has " &
        "the origin " & originIdentity(row.origin) & " of nimble:" &
        row.name & " as a remote" & tip)
      stderr.writeLine("tip: `" & verb & " " & row.name &
        " --source=<checkout>` records a checkout with another remote")
      return 1
    if candidates.len > 1:
      stderr.writeLine(verb & ": error: " &
        candidates.mapIt(relPath(it, projectDir)).join(", ") &
        " each have the origin of nimble:" & row.name & " as a remote; " &
        "name the one to develop with --source")
      return 1
    dir = candidates[0]
    how = "a remote is its origin " & originIdentity(row.origin)
  let packageDir = if row.subdir.len > 0: dir / row.subdir else: dir
  try:
    discard siblingRecord(packageDir, row.name)
  except NimbleDevelopError as e:
    stderr.writeLine(verb & ": error: " & e.msg)
    return 1
  let entry = DevelopOverrideEntry(
    package: NimbleOverridePrefix & row.name,
    local_path: relPath(dir, workspaceRoot),
    state: "editable",
    created_at: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    provenance: some(NimbleDevelopProvenancePrefix & row.name &
      (if source.len > 0: " --source=" & source else: "")),
    replaces: some(replacedIdentity(row)))
  let file = developOverridesPath(workspaceRoot)
  if dryRun:
    echo "would record nimble:" & row.name & " <- " & dir & " (" & how &
      ") in " & file
    return 0
  var written: DevelopOverrides
  try:
    let existing = readDevelopOverridesFile(workspaceRoot)
    let doc = if existing.isSome: existing.get() else: newDevelopOverrides()
    written = addOverride(doc, entry)
    writeDevelopOverridesFile(workspaceRoot, written)
  except CatchableError as e:
    stderr.writeLine(verb & ": error: " & file & ": " & e.msg)
    return 2
  echo "recorded nimble:" & row.name & " <- " & dir & " (" & how & ") in " &
    file
  if developOverridesSchemaFor(written) == schemaDevelopOverridesV2:
    echo "note: " & file & " is now schema " & schemaDevelopOverridesV2 &
      " (its entries record `replaces`); " & OlderReaderNote
  0
