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
import repro_nimble_index
import repro_nimble_fetch
import repro_nimble_generator/source_set

import ./catalog_discovery

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
  result.input = solverInput(idx, names, nimblePlatformOf(platform),
    NimbleSolveOptions(excludeNewer: excludeNewer, roots: roots,
      acceptedOrigins: accepted))
  result.shardsRead = loadedShardCount(idx)
  var hasNim = false
  for p in packages:
    if p.name == "nim": hasNim = true
  let decls = lowerToSolver(result.input,
    toolchainNim = (if hasNim: "nim" else: ""))
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

proc applyNimbleRows*(setup: NimbleSolveSetup; document: string):
    tuple[document: string; refusals: seq[string]] =
  ## The solved lock ``document`` with one `LockedDep` per chosen Nimble
  ## package (see the module header), or the refusals -- a top-level module
  ## two chosen packages export -- with ``document`` unchanged.
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
    extraMirrors*: seq[Mirror]
      ## organization-local mirrors, searched before the index's own
    fetchConfig*: Option[FetchConfig]
      ## a complete fetch configuration to use instead (its mirrors are then
      ## exactly these; tests pass their resolver and dialer here)

  NimbleSourcesReport* = object
    active*: bool          ## the lock pins Nimble packages
    rows*: seq[NimbleLockRow]
    present*: seq[string]  ## verified in the store, nothing fetched
    fetched*: seq[string]
    fetchEdges*: int       ## `nimble.fetch` edges whose executor ran
    storePaths*: Table[string, string] ## name -> verified store tree
    indexLine*: string     ## the pinned index's generation time and age

proc indexMirrors(d: DiscoveredNimbleIndex): seq[Mirror] =
  ## The mirrors the index repository declares in its source set at the
  ## pinned revision, in its search order.
  let (found, text) = readPublishedFile(d, NimbleSourceSetFile,
    MaxSourceSetBytes)
  if not found:
    return
  let ss = parseSourceSet(text, d.repo & ":" & NimbleSourceSetFile)
  for m in ss.mirrors:
    result.add parseMirror(m.url, required = m.role == mrRequired)

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
  # The pins, verified against the declaration and re-read at the pinned
  # revision (the index identity must be the pinned one).
  let answer = catalogsForBuild(projectRoot, pins, @[])
  var byRepo = initTable[string, DiscoveredNimbleIndex]()
  for d in answer.nimbleIndexes: byRepo[d.repo] = d
  var refusals: seq[string]
  var anchored: seq[NimbleLockRow]
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
    var r = row
    if found.found:
      for rec in found.package.versions:
        let o = if int(rec.origin) < found.package.origins.len:
                  found.package.origins[int(rec.origin)]
                else: PackageOrigin()
        if rec.commit == row.commit and $rec.tree == row.tree and
            o.url == row.origin and o.subdir == row.subdir:
          matched = true
          r.archiveSha256 = toHexLower(rec.archiveSha256)
          r.size = int64(rec.size)
          break
    if not matched:
      refusals.add "nimble:" & row.name & " (commit " & row.commit &
        ", tree " & row.tree & ") is not a record of " & indexLabel(d) &
        "; the lock row was not written by a solve of that index. " &
        "Re-solve it with `repro lock refresh`"
      continue
    anchored.add r
  if refusals.len > 0:
    nimbleError(refusals.join("\n  "))
  result.rows = anchored
  if answer.nimbleIndexes.len > 0:
    result.indexLine = nimbleIndexAgeLine(answer.nimbleIndexes[0],
      getTime().toUnix)
  let store =
    if options.fetchConfig.isSome and options.fetchConfig.get.storeRoot.len > 0:
      options.fetchConfig.get.storeRoot
    elif options.storeRoot.len > 0: options.storeRoot
    else: defaultStoreRoot()
  var missing: seq[NimbleLockRow]
  for r in anchored:
    if entryVerified(store, r.tree):
      result.present.add r.name
      result.storePaths[r.name] = entryPath(store, r.tree)
    else:
      missing.add r
  if missing.len == 0:
    return
  if options.offline:
    var names: seq[string]
    for r in missing: names.add "nimble:" & r.name & " (blake3:" & r.tree & ")"
    nimbleError("the build is offline and the source store " & store &
      " does not hold " & names.join(", ") & "; fetch them with a build " &
      "that may reach the index's mirrors")
  var cfg =
    if options.fetchConfig.isSome: options.fetchConfig.get
    else:
      var mirrors = options.extraMirrors
      for d in answer.nimbleIndexes: mirrors.add indexMirrors(d)
      defaultFetchConfig(
        if options.stateDir.len > 0: options.stateDir
        else: projectRoot / ".repro" / "nimble-fetch", mirrors)
  if cfg.storeRoot.len == 0: cfg.storeRoot = store
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
        parts.add "version " & o.version & " -> " & x.version
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
            if nameKey(e.package) notin watched: continue
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
