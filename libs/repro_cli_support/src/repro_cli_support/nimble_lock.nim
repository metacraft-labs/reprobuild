## Nimble packages in the lock verbs and the build (Nimble package catalog,
## NPC-M6): what `repro lock refresh` / `solve` add to a solve whose
## declarations require `nimble:` packages, the `LockedDep` rows they write,
## and what a build checks and fetches before anything compiles.
##
## * ``prepareNimbleSolve`` -- the Nimble index the solve reads (the lock's
##   pin, or under `--provisioning` the revision the import's ref names now,
##   which must descend from the pin: NPC-AREQ15), the closure of the
##   project's `nimble:` requirements read from its shards (NPC-AREQ17), and
##   that closure lowered into the solve's declarations
##   (``repro_nimble_index/resolution``). Nothing is fetched, cloned or run.
## * ``applyNimbleRows`` -- after the solve: the top-level module collision
##   check (NPC-AREQ18, threat model G16), then one `LockedDep` per chosen
##   package (NPC-AREQ19): `nimble:<canonical name>`, VCS coordinates (the
##   origin and the peeled commit), `blake3:<tree>`, the solved version, the
##   catalog import it came from and its `depends` edges.
## * ``nimbleIndexAgeLine`` -- the index revision's generation time and age,
##   printed by every refresh and diff that reads one (threat model G34). A
##   refresh moves to whatever revision the index's remote offers; it does
##   not tell whether that remote stopped publishing (residual risk R2), and
##   nothing here says it does.
## * ``prepareLockedNimbleSources`` -- the build's step: the lock's
##   `nimble-index` pin verified (``catalogsForBuild``), every `nimble:` row
##   checked against a record of the pinned index, and the trees made
##   present in the source store -- verified in place when already there,
##   so a warm build evaluates no fetch edge and opens no connection
##   (NPC-AREQ29 claim 3); otherwise fetched by `nimble.fetch` edges from the
##   index's declared mirrors (NPC-AREQ20).

import std/[algorithm, options, os, sequtils, sets, strutils, tables, times]

import repro_lock
import repro_solver/version_encoder
import repro_solver/nimble_versions
from repro_solver/version_constraints import ESemverParse
import repro_nimble_index
import repro_nimble_fetch
import repro_nimble_generator/capture
import repro_nimble_generator/source_set

import ./catalog_discovery
import ./nimble_mirror_config

export nimble_mirror_config

const
  NimbleSourceSetFile* = "nimble-sources.toml"
    ## The index repository's source set, read at the pinned revision for
    ## the mirrors it declares.
  MaxSourceSetBytes = 1 shl 20

type
  NimbleLockError* = object of CatalogDiscoveryError
    ## A Nimble resolution or source preparation refused; the message names
    ## every cause and its remedy.

  NimbleSolveSetup* = object
    active*: bool
      ## the solve's declarations require at least one `nimble:` package
    index*: DiscoveredNimbleIndex
    input*: NimbleSolverInput
    notes*: seq[string] ## a rewind ``--allow-rewind`` accepted
    shardsRead*: int ## shards the closure read (NPC-AREQ29 claim 1)
    incumbentVersions*: Table[string, string]
      ## `nimble:<name>` -> the version the existing lock row records, for
      ## the moves a refresh reports (``applyNimbleRows``)

proc nimbleError(msg: string) {.noreturn.} =
  raise newException(NimbleLockError, msg)

proc formatUtc(t: int64): string =
  fromUnix(t).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc ageText*(seconds: int64): string =
  ## A duration as the largest whole unit: `3 days`, `5 hours`, `12 minutes`.
  let s = max(seconds, 0)
  if s >= 86_400: $(s div 86_400) & " days"
  elif s >= 3_600: $(s div 3_600) & " hours"
  elif s >= 60: $(s div 60) & " minutes"
  else: $s & " seconds"

proc nimbleIndexAgeLine*(d: DiscoveredNimbleIndex; now: int64): string =
  ## The index revision's generation time -- the root's ``generated_at``,
  ## set by the generator, NOT the time of this command -- and its age
  ## (threat model G34). An index whose remote stopped publishing keeps
  ## showing an old generation time here; that is how a freeze is seen.
  let at = int64(d.root.generatedAt)
  "nimble index \"" & d.repo & "\" at " & d.revision & ": generated " &
    formatUtc(at) & " (" & ageText(now - at) & " old)"

proc indexLabel(d: DiscoveredNimbleIndex): string =
  "the Nimble index \"" & d.repo & "\" at " & d.revision & " (root " &
    d.indexIdentity[0 ..< 16] & ")"

proc parseExcludeNewer*(text: string; value: var int64): string =
  ## ``--exclude-newer`` as Unix seconds: a decimal number of seconds, a
  ## date (`2026-11-01`, the start of that day in UTC) or a UTC time
  ## (`2026-11-01T12:00:00Z`). Returns the usage error, or "".
  let t = text.strip()
  if t.len == 0:
    return "--exclude-newer needs a time"
  if t.allCharsInSet(Digits):
    try:
      value = parseBiggestInt(t)
      return ""
    except ValueError:
      return "--exclude-newer " & t.escape() & " is out of range"
  for fmt in ["yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd"]:
    try:
      value = parse(t, fmt, utc()).toTime.toUnix
      return ""
    except TimeParseError:
      discard
  "--exclude-newer " & t.escape() & " is not a time: give Unix seconds, " &
    "a date (YYYY-MM-DD) or a UTC time (YYYY-MM-DDTHH:MM:SSZ)"

proc requestsNimble*(packages: openArray[PackageDecl]): bool =
  nimbleRootsOf(packages).len > 0

proc prepareNimbleSolve*(projectRoot: string; packages: var seq[PackageDecl];
                         incumbentPins: seq[LockedCatalogImport];
                         reselect: bool; allowRewind: seq[string];
                         platform: string; excludeNewer = -1'i64;
                         incumbentRows: seq[LockedDep] = @[]):
    NimbleSolveSetup =
  ## See the module header. ``packages`` gains the closure's declarations
  ## and its `nimble:` requirements are renamed to the canonical identities.
  ## Inactive (and ``packages`` untouched) when nothing requires a `nimble:`
  ## package. Raises ``CatalogDiscoveryError`` / ``NimbleLockError``.
  let roots = nimbleRootsOf(packages)
  if roots.len == 0:
    return
  result.active = true
  let indexes = nimbleIndexesForSolve(projectRoot, incumbentPins, reselect,
    allowRewind, result.notes)
  if indexes.len == 0:
    var names: seq[string]
    for r in roots:
      if ("nimble:" & r.name) notin names: names.add "nimble:" & r.name
    nimbleError(names.join(", ") & (if names.len == 1: " is" else: " are") &
      " required, and " & projectRoot / CatalogImportsFileName &
      " imports no Nimble index (an [[import]] with kind = \"nimble-index\"); " &
      "a `nimble:` name resolves only through an imported index " &
      "(Package-Model.md § Ecosystem namespaces)")
  if indexes.len > 1:
    var repos: seq[string]
    for d in indexes: repos.add d.repo
    nimbleError("more than one Nimble index is imported (" &
      repos.join(", ") & "); choosing which one supplies a name needs a " &
      "[[policy]] for Nimble names, which is not implemented yet. Import " &
      "one Nimble index")
  result.index = indexes[0]
  var idx = openNimbleIndex(result.index)
  var names: seq[string]
  for r in roots:
    if r.name notin names: names.add r.name
  # The origin each package's existing lock row records is the one the
  # project accepted; a repoint since then is offered only as a separate,
  # excluded candidate (NPC-AREQ16).
  var accepted = initTable[string, string]()
  for d in incumbentRows:
    if d.isNimbleDep and d.catalog == result.index.repo:
      accepted[nameKey(nimbleNameOf(d.name))] = d.coordinates.url
    if d.isNimbleDep:
      result.incumbentVersions[d.name] = d.version
  # The project's `nim` toolchain package, when the solve declares one: its
  # candidates decide the records' Nim-version conditions (NPC-AREQ7).
  var hasNim = false
  var nimVersions: seq[string]
  for p in packages:
    if p.name == "nim":
      hasNim = true
      nimVersions = p.versions
  result.input = solverInput(idx, names, nimblePlatformOf(platform),
    NimbleSolveOptions(excludeNewer: excludeNewer, roots: roots,
      acceptedOrigins: accepted, nimDeclared: hasNim))
  result.shardsRead = loadedShardCount(idx)
  # A retargeted alias is resolved to its recorded target; the new target is
  # said, not taken (NPC-AREQ3, NPC-AREQ16).
  result.notes.add aliasCandidateNotes(result.input)
  let decls = lowerToSolver(result.input,
    toolchainNim = (if hasNim: "nim" else: ""), nimVersions = nimVersions)
  for p in packages.mitems:
    for d in p.depends.mitems:
      d = canonicalRequirement(result.input, d)
    for vd in p.versionDepends.mitems:
      for d in vd.depends.mitems:
        d = canonicalRequirement(result.input, d)
  var declared = initHashSet[string]()
  for p in packages: declared.incl p.name
  for d in decls:
    if d.name notin declared:
      packages.add d

proc nimbleFailureText*(setup: NimbleSolveSetup): string =
  ## What a failed solve adds when Nimble packages were part of it
  ## (NPC-AREQ18): the index revision, the missing names and the excluded
  ## candidates, each with its requirement chain.
  if not setup.active: ""
  else: explainNimbleFailure(setup.input, indexLabel(setup.index))

proc snapshotMove*(oldVersion, newVersion: string): string =
  ## What a lock row's move from a snapshot is (NPC-AREQ31 item 5):
  ## `snapshot superseded` for a newer snapshot (by date, then commit),
  ## `snapshot retired` for a tag version, which every snapshot sorts
  ## below; "" for any other move.
  var od, nd: uint64
  var oc, nc: string
  if not parseSnapshotVersionText(oldVersion, od, oc):
    return ""
  if parseSnapshotVersionText(newVersion, nd, nc):
    if nd > od or (nd == od and nc > oc): "snapshot superseded"
    else: ""
  elif newVersion.len > 0 and not newVersion.startsWith("#"):
    "snapshot retired"
  else: ""

proc versionMove*(oldVersion, newVersion: string): string =
  ## What a lock row's version move is, for `repro lock diff`: the
  ## snapshot moves of ``snapshotMove``; between two tag versions,
  ## `upgrade` or `downgrade` by Nimble's order over every component
  ## (NPC-AREQ6: `0.6.0.3.1 -> 0.7.0.8.0` is an upgrade); "" otherwise.
  result = snapshotMove(oldVersion, newVersion)
  if result.len > 0:
    return
  try:
    let c = cmpNimble(parseNimbleVersion(oldVersion),
      parseNimbleVersion(newVersion))
    if c < 0: result = "upgrade"
    elif c > 0: result = "downgrade"
  except ESemverParse:
    discard

proc applyNimbleRows*(setup: NimbleSolveSetup; document: string):
    tuple[document: string; refusals: seq[string]; moves: seq[string]] =
  ## The solved lock ``document`` with one `LockedDep` per chosen Nimble
  ## package (see the module header), or the refusals -- a top-level module
  ## two chosen packages export -- with ``document`` unchanged. ``moves``
  ## names each row that moves from a snapshot (NPC-AREQ31 item 5), as
  ## `nimble:<name> <old> -> <new> (snapshot superseded|retired)`.
  result.document = document
  if not setup.active:
    return
  var ld = parseLockedDependencies(document)
  var chosenTable = initTable[string, string]()
  for p in ld.packages:
    if p.name.isNimbleIdentity:
      chosenTable[p.name] = p.version
  let chosen = chosenNimblePackages(setup.input, chosenTable)
  result.refusals = moduleCollisions(chosen)
  if result.refusals.len > 0:
    return
  # A feature's solver package (`nimble:lib[extra]`) is how the solve
  # activates a feature; it is not a package of the lock.
  ld.packages.keepItIf(not it.name.isFeatureIdentity)
  var deps: seq[LockedDep]
  for d in ld.deps:
    if not d.name.isNimbleIdentity: deps.add d
  for c in chosen:
    var row = NimbleLockRow(name: c.name, origin: c.origin.url,
      subdir: c.origin.subdir, commit: c.record.commit, tree: $c.record.tree)
    var dep = lockedDepOf(row)
    dep.version = c.version
    let before = setup.incumbentVersions.getOrDefault(c.identity)
    if before.len > 0 and before != c.version:
      let move = snapshotMove(before, c.version)
      if move.len > 0:
        result.moves.add c.identity & " " & before & " -> " & c.version &
          " (" & move & ")"
    dep.depends = c.depends
    dep.catalog = setup.index.repo
    dep.visibility = "public"
    deps.add dep
  ld.deps = deps
  result.document = serializeLockedDependencies(ld)

# ---------------------------------------------------------------------------
# The build's step
# ---------------------------------------------------------------------------

type
  NimbleSourcesOptions* = object
    stateDir*: string
      ## the fetch edges' outputs and engine cache ("" = under the project's
      ## `.repro/`)
    storeRoot*: string    ## "" = the user's source store
    offline*: bool
      ## refuse instead of fetching a tree the store lacks
    mirrorConfig*: Option[MirrorConfigPaths]
      ## where the configured mirrors (`[nimble] mirrors`, NPC-AREQ13) are
      ## read from; none = the host's files for the project
      ## (``mirrorConfigPathsFor``). Tests point every path into a private
      ## root.
    fetchTemplate*: Option[FetchConfig]
      ## how mirrors and origins are reached (resolver, trust anchors,
      ## forges, git, limits) when not the host's defaults. Its mirror list
      ## is replaced by the production order: the configured mirrors, then
      ## the index's, then the origin (tests pass their resolver here)
    fetchConfig*: Option[FetchConfig]
      ## a complete fetch configuration to use instead (its mirrors are then
      ## exactly these; tests pass their resolver and dialer here)

  LockedNimblePackage* = object
    ## One `nimble:` row of the lock with the record of the pinned index it
    ## was anchored to (NPC-AREQ21: the producer's interface comes from the
    ## record, with no provider run).
    row*: NimbleLockRow
    version*: string        ## the solver version the lock chose
    depends*: seq[string]   ## `nimble:` identities
    record*: VersionRecord
    package*: PackageEnvelope ## the record's package (origins, name)
    storePath*: string      ## the verified store tree ("" until present)
    srcPath*: string
      ## `<storePath>/<srcDir>`, the `--path` entry; under a develop
      ## override, the sibling's source directory
    developDir*: string
      ## the develop sibling that replaces the store tree on `--path`
      ## (NPC-AREQ27); "" when the store tree is built

  NimbleSourcesReport* = object
    active*: bool          ## the lock pins Nimble packages
    rows*: seq[NimbleLockRow]
    packages*: seq[LockedNimblePackage]
      ## in the build order (``nimbleBuildOrder``)
    present*: seq[string]  ## verified in the store, nothing fetched
    fetched*: seq[string]
    fetchEdges*: int       ## `nimble.fetch` edges whose executor ran
    storePaths*: Table[string, string] ## name -> verified store tree
    nimPathDirs*: seq[string]
      ## `<store tree>/<srcDir>` of every package, in the build order: the
      ## Nim source roots the compile edges receive (`--path:`) and the
      ## lines of `repro.paths`
    configuredMirrors*: seq[ConfiguredMirror]
    natives*: seq[NativeOverride]
      ## the native overrides (`[[native]]`, NPC-AREQ24) of the pinned
      ## indexes' source sets
    mirrors*: seq[Mirror]  ## the search order the fetch used
    indexLine*: string     ## the pinned index's generation time and age
    platform*: string      ## the lock's platform the records were read for
    solvedNim*: string
      ## the version the lock's solve chose for the project's `nim`
      ## toolchain package; "" when the solve declared none. The records'
      ## Nim-version conditions were decided against it (NPC-AREQ7)

proc indexSourceSet*(d: DiscoveredNimbleIndex): Option[SourceSet] =
  ## The index repository's source set at the pinned revision, read by
  ## object id; none when the revision has none.
  let (found, text) = readPublishedFile(d, NimbleSourceSetFile,
    MaxSourceSetBytes)
  if found:
    result = some(parseSourceSet(text, d.repo & ":" & NimbleSourceSetFile))

proc indexMirrors(ss: Option[SourceSet]): seq[Mirror] =
  ## The mirrors the index repository declares in its source set at the
  ## pinned revision, in its search order.
  if ss.isNone:
    return
  for m in ss.get.mirrors:
    result.add parseMirror(m.url, required = m.role == mrRequired)

proc recordSrcDir*(rec: VersionRecord; p: NimblePlatform;
                   nim = none(NimVersionValue)): string =
  ## The record's `srcDir` on platform ``p`` (at Nim ``nim``): the plain
  ## assignment, then every conditional assignment whose condition holds
  ## there, in record order (the last one wins, as in the `.nimble` file).
  ## "" = the package root. Raises ``NimbleLockError`` for an assignment
  ## whose condition depends on the Nim version when ``nim`` is none.
  let e = effectiveLayout(rec, p, nim)
  let undecided = e.undecidedText({rfSrcDir})
  if undecided.len > 0:
    raise newException(NimbleLockError, "the record's srcDir depends " &
      "on the Nim version (`" & undecided & "`), " &
      "and the lock records no Nim: declare `uses: nim` and re-lock")
  e.layout.srcDir

proc nimbleBuildOrder*(packages: seq[LockedNimblePackage]):
    seq[LockedNimblePackage] =
  ## The lock's topological order, then name (NPC-AREQ21,
  ## Nim-Package-Path-Handling.md § 5): a package comes after every package
  ## it depends on; among the packages whose dependencies are all placed,
  ## the smallest canonical name comes first. Nothing else -- no store path,
  ## no host fact -- decides it, so the order is the same on every machine
  ## that has the lock. A dependency the lock does not hold, or a cycle,
  ## does not stop the order: what remains is placed by name.
  var byName = initTable[string, LockedNimblePackage]()
  for p in packages: byName["nimble:" & p.row.name] = p
  var placed = initHashSet[string]()
  var remaining: seq[string]
  for k in byName.keys: remaining.add k
  remaining.sort()
  while remaining.len > 0:
    var next = -1
    for i, k in remaining:
      var ready = true
      for d in byName[k].depends:
        if d in byName and d notin placed and d != k:
          ready = false
          break
      if ready:
        next = i
        break
    if next < 0:
      next = 0 # a cycle: the smallest remaining name breaks it
    let k = remaining[next]
    remaining.delete(next)
    placed.incl k
    result.add byName[k]

proc configuredMirrorsFor(projectRoot: string; options: NimbleSourcesOptions):
    seq[ConfiguredMirror] =
  let paths =
    if options.mirrorConfig.isSome: options.mirrorConfig.get
    else: mirrorConfigPathsFor(projectRoot)
  try:
    configuredNimbleMirrors(paths)
  except NimbleMirrorConfigError as e:
    nimbleError("the configured Nimble mirrors cannot be read: " & e.msg)

proc prepareLockedNimbleSources*(projectRoot, lockPath: string;
                                 options: NimbleSourcesOptions):
    NimbleSourcesReport =
  ## See the module header. Raises ``NimbleLockError`` /
  ## ``CatalogDiscoveryError`` naming every cause; a build must fail with it.
  if not fileExists(lockPath):
    return
  let ld = parseLockedDependencies(readFile(lockPath))
  let rows = nimbleRowsOf(ld)
  var nimblePins: seq[LockedCatalogImport]
  let pins = ld.lockedCatalogImportPins()
  for p in pins:
    if p.kind == cikNimbleIndex: nimblePins.add p
  if rows.len == 0 and nimblePins.len == 0:
    return
  result.active = true
  result.platform = if ld.platform.len > 0: ld.platform else: currentPlatformId()
  let platform = nimblePlatformOf(result.platform)
  for p in ld.packages:
    if p.name == "nim": result.solvedNim = p.version
  let solvedNim = nimVersionValueOf(result.solvedNim)
  # The pins, verified against the declaration and re-read at the pinned
  # revision (the index identity must be the pinned one).
  let answer = catalogsForBuild(projectRoot, pins, @[])
  var byRepo = initTable[string, DiscoveredNimbleIndex]()
  var sourceSets = initTable[string, Option[SourceSet]]()
  for d in answer.nimbleIndexes:
    byRepo[d.repo] = d
    sourceSets[d.repo] = indexSourceSet(d)
    if sourceSets[d.repo].isSome:
      result.natives.add sourceSets[d.repo].get.natives
  var refusals: seq[string]
  var anchored: seq[LockedNimblePackage]
  var depOf = initTable[string, LockedDep]()
  for d in ld.deps:
    if d.isNimbleDep: depOf[d.name] = d
  for row in rows:
    let dep = depOf["nimble:" & row.name]
    if dep.catalog notin byRepo:
      refusals.add "nimble:" & row.name & " names the catalog import " &
        dep.catalog.escape() & ", which the lock does not pin as a Nimble " &
        "index"
      continue
    let d = byRepo[dep.catalog]
    var idx = openNimbleIndex(d)
    let found = lookupPackage(idx, row.name)
    var matched = false
    var pkg = LockedNimblePackage(row: row, version: dep.version,
      depends: dep.depends)
    if found.found:
      for rec in found.package.versions:
        let o = if int(rec.origin) < found.package.origins.len:
                  found.package.origins[int(rec.origin)]
                else: PackageOrigin()
        if rec.commit == row.commit and $rec.tree == row.tree and
            o.url == row.origin and o.subdir == row.subdir:
          matched = true
          pkg.row.archiveSha256 = toHexLower(rec.archiveSha256)
          pkg.row.size = int64(rec.size)
          pkg.row.submodules = rec.submodules.len > 0
          pkg.record = rec
          pkg.package = found.package
          break
    if not matched:
      refusals.add "nimble:" & row.name & " (commit " & row.commit &
        ", tree " & row.tree & ") is not a record of " & indexLabel(d) &
        "; the lock row was not written by a solve of that index. " &
        "Re-solve it with `repro lock refresh`"
      continue
    anchored.add pkg
  if refusals.len > 0:
    nimbleError(refusals.join("\n  "))
  anchored = nimbleBuildOrder(anchored)
  for p in anchored: result.rows.add p.row
  if answer.nimbleIndexes.len > 0:
    result.indexLine = nimbleIndexAgeLine(answer.nimbleIndexes[0],
      getTime().toUnix)
  let store =
    if options.fetchConfig.isSome and options.fetchConfig.get.storeRoot.len > 0:
      options.fetchConfig.get.storeRoot
    elif options.fetchTemplate.isSome and
        options.fetchTemplate.get.storeRoot.len > 0:
      options.fetchTemplate.get.storeRoot
    elif options.storeRoot.len > 0: options.storeRoot
    else: defaultStoreRoot()
  var missing: seq[NimbleLockRow]
  for p in anchored:
    if entryVerified(store, p.row.tree):
      result.present.add p.row.name
      result.storePaths[p.row.name] = entryPath(store, p.row.tree)
    else:
      missing.add p.row
  if missing.len > 0:
    if options.offline:
      var names: seq[string]
      for r in missing:
        names.add "nimble:" & r.name & " (blake3:" & r.tree & ")"
      nimbleError("the build is offline and the source store " & store &
        " does not hold " & names.join(", ") & "; fetch them with a build " &
        "that may reach the index's mirrors")
    var cfg: FetchConfig
    if options.fetchConfig.isSome:
      cfg = options.fetchConfig.get
    else:
      # NPC-AREQ13 / NPC-AREQ20: the configured mirrors, then the index's
      # own, then (inside the fetch) the origin. The list is part of every
      # `nimble.fetch` edge's cache key (``fetchLocked``).
      result.configuredMirrors = configuredMirrorsFor(projectRoot, options)
      var mirrors = fetchMirrorsOf(result.configuredMirrors)
      for d in answer.nimbleIndexes: mirrors.add indexMirrors(sourceSets[d.repo])
      let stateDir =
        if options.stateDir.len > 0: options.stateDir
        else: projectRoot / ".repro" / "nimble-fetch"
      if options.fetchTemplate.isSome:
        cfg = options.fetchTemplate.get
        cfg.mirrors = mirrors
        if cfg.stateDir.len == 0: cfg.stateDir = stateDir
      else:
        cfg = defaultFetchConfig(stateDir, mirrors)
    if cfg.storeRoot.len == 0: cfg.storeRoot = store
    if options.fetchConfig.isNone and cfg.captureLog.len == 0:
      cfg.captureLog = projectCaptureLog(projectRoot)
    result.mirrors = cfg.mirrors
    let fetched = fetchLocked(missing, cfg)
    result.fetchEdges = fetched.executed.len
    var failed: seq[string]
    for p in fetched.packages:
      if p.state == psFailed:
        var tried: seq[string]
        for a in p.attempts:
          tried.add $a.transport & " " & a.location & ": " & $a.outcome &
            (if a.detail.len > 0: " (" & a.detail & ")" else: "")
        failed.add "nimble:" & p.row.name & " (blake3:" & p.row.tree &
          ") could not be fetched:\n    " & tried.join("\n    ")
      else:
        result.fetched.add p.row.name
        result.storePaths[p.row.name] = p.storePath
    if failed.len > 0:
      nimbleError(failed.join("\n  "))
  # NPC-AREQ21: each package is its verified tree and a `--path` to its
  # source directory, in the build order.
  for p in anchored.mitems:
    p.storePath = result.storePaths.getOrDefault(p.row.name)
    var srcDir = ""
    try:
      srcDir = recordSrcDir(p.record, platform, solvedNim).replace('\\', '/')
    except NimbleLockError as e:
      refusals.add "nimble:" & p.row.name & " " & p.version & ": " & e.msg
      continue
    var parts: seq[string]
    for c in srcDir.split('/'):
      if c.len > 0 and c != ".": parts.add c
    # The record's `srcDir` is the generator's reading of a hostile
    # `.nimble`: a path that leaves the tree would hand the compile a
    # directory no digest covers.
    if srcDir.isAbsolute or ".." in parts:
      refusals.add "nimble:" & p.row.name & " " & p.version & ": the " &
        "record's srcDir " & srcDir.escape() & " leaves the package's tree"
      continue
    p.srcPath = if parts.len == 0: p.storePath
                else: p.storePath / parts.join("/")
    if not dirExists(p.srcPath):
      refusals.add "nimble:" & p.row.name & " " & p.version & ": the " &
        "record's srcDir " & srcDir.escape() & " is not a directory of " &
        "the verified tree " & p.storePath
      continue
    result.nimPathDirs.add p.srcPath
  if refusals.len > 0:
    nimbleError(refusals.join("\n  "))
  result.packages = anchored

proc nimConditionsOf(rec: VersionRecord):
    seq[tuple[what: string; nodes: seq[ConditionNode]]] =
  ## Every condition of a record with its subject, for the build's check of
  ## the Nim-version conditions (NPC-AREQ7).
  for r in rec.requires:
    result.add ("requires " & r.source.escape(), r.condition)
  for r in rec.nim:
    result.add ("requires " & r.source.escape(), r.condition)
  for f in rec.features:
    if f.rootOnly: continue
    for r in f.requires:
      result.add ("feature " & f.name & " requires " & r.source.escape(),
        r.condition)
  for c in rec.layout.conditional:
    result.add ($c.field, c.condition)
  for d in rec.foreign:
    result.add ("foreignDep " & d.name.escape(), d.condition)

proc nimVersionRefusals*(report: NimbleSourcesReport; nimVersion: string):
    seq[string] =
  ## M6-P12 (NPC-AREQ7, NPC-AREQ17): the Nim the build compiles with,
  ## against the `nim` range of every chosen record, whether or not the
  ## solve declared a `nim` package. One line per range that does not admit
  ## ``nimVersion``, naming the package, its version, the range and the Nim
  ## version. A range is evaluated for the lock's platform, as the solve
  ## evaluated it.
  ##
  ## NPC-M14 (A3): every condition of a chosen record that depends on the
  ## Nim version is evaluated at ``nimVersion`` and at the Nim the lock was
  ## solved for (``report.solvedNim``); where they differ the build is
  ## refused, naming the package, the condition and both Nim versions. A
  ## record with such a condition in a lock that records no solved Nim is
  ## refused too. Every condition of the record is checked, a feature's
  ## included, as the lock does not record which features were active.
  let platform = nimblePlatformOf(report.platform)
  let build = nimVersionValueOf(nimVersion)
  let solved = nimVersionValueOf(report.solvedNim)
  for p in report.packages:
    var opts = NimbleSolveOptions(excludeNewer: -1, nimDeclared: true)
    let c = candidate(p.package, p.record, platform, opts)
    let who = "nimble:" & p.row.name & " " & p.version
    for r in c.nim:
      if not rangeAdmits(r, nimVersion):
        result.add who & " requires nim " & r & "; the build's Nim is " &
          nimVersion
    for r in c.nimGatedNim:
      if build.isSome and activeOn(r.entry.condition, platform, build) and
          r.range.len > 0 and not rangeAdmits(r.range, nimVersion):
        result.add who & " requires nim " & r.range & " when `" &
          renderCondition(r.entry.condition) & "`; the build's Nim is " &
          nimVersion
    for (what, nodes) in nimConditionsOf(p.record):
      if decideOn(nodes, platform) != tUnknown:
        continue
      let cond = "`" & renderCondition(nodes) & "` (" & what & ")"
      if solved.isNone:
        result.add who & ": " & cond & " depends on the Nim version, and " &
          "the lock records no Nim it was solved for: declare `uses: nim` " &
          "and re-lock"
        continue
      if build.isNone:
        result.add who & ": " & cond & " depends on the Nim version, and " &
          "the build's Nim version " & nimVersion.escape() & " does not " &
          "read as <major>.<minor>.<patch>"
        continue
      let atSolved = decideOn(nodes, platform, solved)
      let atBuild = decideOn(nodes, platform, build)
      if atSolved != atBuild:
        result.add who & ": " & cond & " is " &
          (if atSolved == tTrue: "true" else: "false") & " at Nim " &
          report.solvedNim & ", which the lock was solved for, and " &
          (if atBuild == tTrue: "true" else: "false") & " at the build's " &
          "Nim " & nimVersion & "; build with Nim " & report.solvedNim &
          ", or re-lock with the build's Nim"

# ---------------------------------------------------------------------------
# `repro lock diff`
# ---------------------------------------------------------------------------

proc nimbleLockDiff*(oldText, newText, anchor: string; now: int64):
    tuple[changed: bool; lines: seq[string]] =
  ## The Nimble part of `repro lock diff` (NPC-AREQ19, threat model G34):
  ##
  ## * every `nimble:` package added, removed, or changed in version,
  ##   commit, tree digest or origin;
  ## * for each `nimble-index` pin, its revision change, and the
  ##   generation time and age of the index each lock pins -- read from the
  ##   shared clone at the pinned revision, or said to be unreadable;
  ## * the origin events every generation published after the old pin up
  ##   to the new one records for a package either lock names.
  ##
  ## ``changed`` is true when a row or a pin differs. Empty for two locks
  ## without Nimble packages or pins. A lock that cannot be read yields no
  ## Nimble lines (the provisioning diff refuses it first).
  var a, b: LockedDependencies
  try:
    a = parseLockedDependencies(oldText)
    b = parseLockedDependencies(newText)
  except CatchableError:
    return
  var oldRows, newRows: Table[string, LockedDep]
  for d in a.deps:
    if d.isNimbleDep: oldRows[d.name] = d
  for d in b.deps:
    if d.isNimbleDep: newRows[d.name] = d
  var oldPins, newPins: seq[LockedCatalogImport]
  try:
    for p in a.lockedCatalogImportPins():
      if p.kind == cikNimbleIndex: oldPins.add p
    for p in b.lockedCatalogImportPins():
      if p.kind == cikNimbleIndex: newPins.add p
  except CatchableError:
    discard
  if oldRows.len == 0 and newRows.len == 0 and oldPins.len == 0 and
      newPins.len == 0:
    return
  var names: seq[string]
  for k in oldRows.keys: names.add k
  for k in newRows.keys:
    if k notin oldRows: names.add k
  names.sort()
  var rowLines: seq[string]
  for n in names:
    if n notin newRows:
      let o = oldRows[n]
      rowLines.add "  - " & n & " " & o.version & " (removed)"
    elif n notin oldRows:
      let x = newRows[n]
      rowLines.add "  + " & n & " " & x.version & " (commit " &
        x.coordinates.revision & ", " & x.integrity & ", " &
        x.coordinates.url & ")"
    else:
      let o = oldRows[n]
      let x = newRows[n]
      var parts: seq[string]
      if o.version != x.version:
        let move = versionMove(o.version, x.version)
        parts.add "version " & o.version & " -> " & x.version &
          (if move.len > 0: " (" & move & ")" else: "")
      if o.coordinates.revision != x.coordinates.revision:
        parts.add "commit " & o.coordinates.revision & " -> " &
          x.coordinates.revision
      if o.integrity != x.integrity:
        parts.add "digest " & o.integrity & " -> " & x.integrity
      if o.coordinates.url != x.coordinates.url:
        parts.add "origin " & o.coordinates.url & " -> " & x.coordinates.url
      if o.catalog != x.catalog:
        parts.add "catalog " & o.catalog & " -> " & x.catalog
      if parts.len > 0:
        rowLines.add "  ~ " & n & ": " & parts.join(", ")
  var lines: seq[string]
  if rowLines.len > 0:
    result.changed = true
    lines.add "nimble packages:"
    lines.add rowLines
  var repos: seq[string]
  for p in oldPins & newPins:
    if p.repo notin repos: repos.add p.repo
  repos.sort()
  var watched = initHashSet[string]()
  for n in names: watched.incl nameKey(n["nimble:".len .. ^1])
  for repo in repos:
    var o, x: Option[LockedCatalogImport]
    for p in oldPins:
      if p.repo == repo: o = some(p)
    for p in newPins:
      if p.repo == repo: x = some(p)
    if o.isSome and x.isSome and o.get.revision != x.get.revision:
      result.changed = true
      lines.add "nimble index \"" & repo & "\": revision " &
        o.get.revision & " -> " & x.get.revision
    elif o.isNone or x.isNone:
      result.changed = true
    var newIndex: Option[DiscoveredNimbleIndex]
    for (label, pin) in [("old", o), ("new", x)]:
      if pin.isNone:
        lines.add "nimble index \"" & repo & "\" (" & label &
          " lock): not pinned"
        continue
      let p = pin.get
      try:
        let d = discoverNimbleIndexAt(p.repo, p.remote, p.gitRef, p.revision,
          anchor)
        lines.add "nimble index (" & label & " lock): " &
          nimbleIndexAgeLine(d, now)
        if label == "new": newIndex = some(d)
      except CatchableError as err:
        lines.add "nimble index \"" & repo & "\" at " & p.revision & " (" &
          label & " lock): its generation time cannot be read: " &
          err.msg.splitLines()[0]
    if o.isSome and newIndex.isSome and o.get.revision != x.get.revision:
      var events: seq[string]
      for gen in nimbleIndexHistory(newIndex.get, o.get.revision, anchor):
        try:
          let idx = openNimbleIndex(gen)
          for e in loadEvents(idx).events:
            # An alias's retarget concerns the packages it named before and
            # names now, which is what a lock row records.
            if nameKey(e.package) notin watched and not
                (e.kind == oeAliasRetargeted and (nameKey(e.before) in watched or
                  nameKey(e.after) in watched)):
              continue
            events.add "  " & $e.kind & " nimble:" & e.package &
              (if e.version.len > 0: " " & e.version else: "") &
              (if e.before.len > 0 or e.after.len > 0:
                 ": " & e.before & " -> " & e.after else: "") &
              " (observed " & formatUtc(int64(e.observedAt)) & ", revision " &
              gen.revision & ")"
        except CatchableError as err:
          events.add "  the events of revision " & gen.revision &
            " cannot be read: " & err.msg.splitLines()[0]
      if events.len > 0:
        lines.add "origin events since " & o.get.revision & ":"
        lines.add events
  result.lines = lines
