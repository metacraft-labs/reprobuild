## The `cargo.fetch` edges: every registry crate a `Cargo.lock` pins,
## fetched into the store root and verified against the lock's checksum.
##
## A fetch of a lock is one wave of build-graph edges, one per locked crate
## version (`crate_rows`), each of engine kind `bakSourceFetch` and network
## mode `netFetch`, declaring every location it may contact (the configured
## mirrors and the crate's origin URL) as a tracked destination, and audited
## by `auditNetworkPolicy` before the wave runs. Fetching is not building:
## the edges that later read the sources are ordinary compile edges, which
## declare no network (`netDenied`, the default) and receive nothing but
## store paths.
##
## **One edge.** `cargo.fetch/<name>@<version>` tries, in order:
##
## 1. the store: a prefix already published for the crate (`crate_store`) is
##    used as it is, and no location is contacted;
## 2. each configured mirror, in the configured order (an organization's
##    mirror first, then the catalog's), at `cargo/crates/<c0c1>/<cksum>.crate`
##    under the mirror's base: a mirror is a content-addressed store keyed by
##    the checksum, so it needs no knowledge of Cargo and holds no trust;
## 3. the origin, `<origin base><name>/<version>/download` (crates.io:
##    `https://static.crates.io/crates/`, its `config.json`'s `dl` with
##    cargo's default `/{crate}/{version}/download` suffix,
##    https://doc.rust-lang.org/cargo/reference/registry-index.html#index-configuration),
##    under the origin egress policy: `https` only, every resolved address
##    public, every redirect re-vetted before it is followed, size and time
##    bounded.
##
## Every location's bytes are hashed with SHA-256 and compared with the
## lock's checksum BEFORE they are decompressed or parsed. Bytes that differ
## are discarded, the location is downgraded (tried after every other
## mirror for the rest of the wave) and the next one is tried; there is no
## unverified fallback. Verified bytes are extracted into the store's private
## staging directory by the confined extractor and published as the crate's
## prefix (`crate_store.installCrate`). A verified archive the extractor
## refuses (an absolute or `..` name, a member outside `<name>-<version>/`,
## a link leaving the tree) fails the edge, naming the member: every mirror
## must serve the same bytes, so no other location can do better.
##
## **Cache.** The edge's declared output is a receipt in the caller's state
## directory; its key is the row (name, version, checksum), the mirror list,
## the origin base and the store root. An unchanged second run is an engine
## cache hit and contacts nothing. A receipt whose prefix the store no longer
## holds is dropped before the wave runs, so the edge runs again. A second
## checkout or project (another state directory) runs the edge, which finds
## the prefix in the store and contacts nothing.
##
## **Tool state.** Nothing here reads or writes cargo's own state: no
## `$CARGO_HOME` (`~/.cargo`), no registry cache or source directory, no
## cargo configuration. A crate that exists only there is not found.
##
## The per-crate edges of one wave run one after another: the engine runs an
## executor-backed built-in edge inline (the same limit the Nimble source
## fetch documents).

import std/[os, sets, strutils, tables]

import blake3
import nimcrypto/sha2

import repro_build_engine
import repro_lock/identity
import repro_local_store
import repro_core/zlib_inflate

import repro_nimble_generator/egress
import repro_nimble_fetch/archive_extract
import repro_nimble_fetch/https_get
import repro_nimble_fetch/mirror

import ./crate_rows
import ./crate_store

export Mirror, MirrorKind, parseMirror, EgressPolicy, ExtractLimits,
  DefaultExtractLimits

type
  CrateTransport* = enum
    ctStore = "store"
    ctMirror = "mirror"
    ctOrigin = "origin"

  CrateAttemptOutcome* = enum
    caFetched = "fetched"   ## verified and published
    caMissing = "missing"   ## the location does not hold it
    caMismatch = "mismatch" ## bytes whose SHA-256 is not the lock's checksum
    caRefused = "refused"   ## an egress or extraction rule refused it
    caFailed = "failed"     ## anything else (a connection, the store)

  CrateAttempt* = object
    transport*: CrateTransport
    location*: string
    outcome*: CrateAttemptOutcome
    rule*: string   ## `cksum`, the extraction rule, or the egress refusal
    detail*: string

  CrateState* = enum
    csFetched = "fetched"
    csPresent = "present"   ## already in the store, verified
    csFailed = "failed"

  CrateFetch* = object
    row*: CrateRow
    state*: CrateState
    transport*: CrateTransport
    attempts*: seq[CrateAttempt]
    prefix*: string  ## the crate's store prefix, when not failed

  CrateFetchObserver* = proc(transport: CrateTransport; url: string) {.gcsafe.}
    ## Called with every location before it is contacted. Tests use it.

  CrateFetchConfig* = object
    stateDir*: string       ## this project's edge receipts and engine cache
    storeRoot*: string      ## "" = the user's store root (`resolveStoreRoot`)
    mirrors*: seq[Mirror]   ## the search order
    mirrorAccess*: EgressPolicy
      ## how mirrors are reached; no origin address rules apply to a mirror
      ## the configuration names
    originBase*: string
      ## the registry's download base, ending in `/`; "" = no origin
    originPolicy*: EgressPolicy  ## the origin egress policy
    limits*: ExtractLimits
    observer*: CrateFetchObserver

  CrateFetchResult* = object
    crates*: seq[CrateFetch]   ## one per row, in the rows' order
    executed*: seq[string]     ## edges whose executor ran (a hit is not)
    actions*: seq[BuildAction]
    ok*: bool

  CrateFetchError* = object of CatchableError

const
  CratesIoOrigin* = "https://static.crates.io/crates/"
  CrateObjectDir* = "cargo/crates"
  ReceiptKind = "reprobuild.cargo-fetch.v1"

proc crateObjectPath*(cksum: string): string =
  ## A crate's object path under a mirror's base, keyed by its checksum.
  if not isCksum(cksum):
    raise newException(ValueError, "not a crate checksum: " & cksum.escape())
  CrateObjectDir & "/" & cksum[0 .. 1] & "/" & cksum & ".crate"

proc originUrlOf*(cfg: CrateFetchConfig; row: CrateRow): string =
  ## The crate's download URL at the origin, or "" with no origin.
  if cfg.originBase.len == 0: ""
  else: cfg.originBase & row.name & "/" & row.version & "/download"

const CrateFetchEdgePrefix* = "cargo.fetch/"
  ## The id prefix of every `cargo.fetch` edge, which the executor is
  ## registered under (`registerSourceFetchExecutor`).

proc crateFetchEdgeId*(row: CrateRow): string = CrateFetchEdgePrefix & row.label

proc defaultCrateFetchConfig*(stateDir: string;
                              mirrors: seq[Mirror] = @[]): CrateFetchConfig =
  ## The configured ``mirrors``, then crates.io, under the production
  ## egress policy.
  CrateFetchConfig(stateDir: stateDir, mirrors: mirrors,
    mirrorAccess: defaultPolicy(), originBase: CratesIoOrigin,
    originPolicy: defaultPolicy(), limits: DefaultExtractLimits)

proc storeRootOf*(cfg: CrateFetchConfig): string =
  if cfg.storeRoot.len > 0: absolutePath(cfg.storeRoot)
  else: resolveStoreRoot()

proc observe(cfg: CrateFetchConfig; t: CrateTransport; url: string) =
  if cfg.observer != nil:
    {.cast(gcsafe).}: cfg.observer(t, url)

proc sha256Hex(s: string): string =
  toLowerAscii($sha256.digest(s))

proc enc(s: string): string =
  ## One receipt field: no space or newline survives unescaped.
  s.multiReplace(("%", "%25"), (" ", "%20"), ("\n", "%0A"))

# ---------------------------------------------------------------------------
# One crate
# ---------------------------------------------------------------------------

proc acceptBytes(cfg: CrateFetchConfig; row: CrateRow; bytes: string;
                 attempt: var CrateAttempt;
                 downgraded: var HashSet[string]; mirrorKey: string): string =
  ## Verify ``bytes`` against the lock, then publish them. Returns the
  ## prefix, or "" with ``attempt`` saying why not.
  let got = sha256Hex(bytes)
  if got != row.cksum:
    # Before anything parses the bytes (External-Package-Catalog-Adapters
    # "Verified Tarball Acquisition", step 3): a substituted archive is
    # never decompressed, let alone extracted.
    attempt.outcome = caMismatch
    attempt.rule = "cksum"
    attempt.detail = "the archive from " & attempt.location &
      " has sha256 " & got & ", Cargo.lock records " & row.cksum
    if mirrorKey.len > 0: downgraded.incl mirrorKey
    return ""
  var s = openStore(storeRootOf(cfg))
  defer: s.close()
  try:
    result = s.installCrate(row, bytes, cfg.limits)
    attempt.outcome = caFetched
  except ExtractRefusal as e:
    attempt.outcome = caRefused
    attempt.rule = $e.rule
    attempt.detail = e.msg
  except InflateError as e:
    attempt.outcome = caRefused
    attempt.rule = e.reason
    attempt.detail = e.msg
  except CatchableError as e:
    attempt.outcome = caFailed
    attempt.detail = e.msg

proc mirrorOrder(cfg: CrateFetchConfig;
                 downgraded: HashSet[string]): seq[Mirror] =
  ## The configured order, with mirrors that served wrong bytes earlier in
  ## this wave moved after every other mirror.
  for m in cfg.mirrors:
    if m.location notin downgraded: result.add m
  for m in cfg.mirrors:
    if m.location in downgraded: result.add m

proc fetchCrate*(cfg: CrateFetchConfig; row: CrateRow;
                 downgraded: var HashSet[string]): CrateFetch =
  ## One crate: the store, the mirrors, the origin (see the module
  ## docstring). ``downgraded`` carries the wave's downgraded mirrors.
  result = CrateFetch(row: row, state: csFailed)
  validateRow(row)
  block store:
    var s = openStore(storeRootOf(cfg))
    defer: s.close()
    let present = s.presentCratePrefix(row)
    if present.len > 0:
      result.state = csPresent
      result.transport = ctStore
      result.prefix = present
      return
  for m in cfg.mirrorOrder(downgraded):
    let rel = crateObjectPath(row.cksum)
    var attempt = CrateAttempt(transport: ctMirror, location: m.urlOf(rel))
    cfg.observe(ctMirror, attempt.location)
    let r = m.readObject(rel, cfg.limits.maxBytes, cfg.mirrorAccess)
    if not r.found:
      attempt.outcome = caMissing
      attempt.detail = r.failure
      result.attempts.add attempt
      continue
    let prefix = cfg.acceptBytes(row, r.bytes, attempt, downgraded,
      m.location)
    result.attempts.add attempt
    if prefix.len > 0:
      result.state = csFetched
      result.transport = ctMirror
      result.prefix = prefix
      return
    if attempt.outcome in {caRefused, caFailed}:
      # The bytes were the locked crate's: every location serves the same.
      return
  let url = cfg.originUrlOf(row)
  if url.len == 0:
    return
  var attempt = CrateAttempt(transport: ctOrigin, location: url)
  cfg.observe(ctOrigin, url)
  var bytes = ""
  try:
    var steps: seq[RequestStep]
    bytes = fetchOriginArchive(cfg.originPolicy, url, cfg.limits.maxBytes,
      steps)
  except EgressError as e:
    attempt.outcome = caRefused
    attempt.rule = $e.refusal.kind
    attempt.detail = e.msg
    result.attempts.add attempt
    return
  except CatchableError as e:
    attempt.outcome = (if " answered 404" in e.msg or
                          " answered 410" in e.msg: caMissing
                       else: caFailed)
    attempt.detail = e.msg
    result.attempts.add attempt
    return
  let prefix = cfg.acceptBytes(row, bytes, attempt, downgraded, "")
  result.attempts.add attempt
  if prefix.len > 0:
    result.state = csFetched
    result.transport = ctOrigin
    result.prefix = prefix

# ---------------------------------------------------------------------------
# The edges
# ---------------------------------------------------------------------------

proc hexKey(parts: varargs[string]): string =
  var s = ""
  for p in parts: s.add p & "\0"
  let d = blake3.digest(s)
  for b in d: result.add toHex(int(b), 2).toLowerAscii()

proc mirrorList(cfg: CrateFetchConfig): string =
  var parts: seq[string]
  for m in cfg.mirrors: parts.add m.location
  parts.join("\n")

proc destinationsOf*(cfg: CrateFetchConfig; row: CrateRow): seq[string] =
  ## Every location ``row``'s edge may contact: its tracked destinations.
  for m in cfg.mirrors: result.add m.location
  let url = cfg.originUrlOf(row)
  if url.len > 0: result.add url

proc receiptPathOf(cfg: CrateFetchConfig; row: CrateRow): string =
  absolutePath(cfg.stateDir) / "edges" / "cargo-fetch" / hexKey(row.name,
    row.version, row.cksum, cfg.mirrorList, cfg.originBase, storeRootOf(cfg))

proc crateFetchEntries(row: CrateRow; cfg: CrateFetchConfig): seq[string] =
  ## What the edge's executor needs to fetch ``row`` exactly as its key says:
  ## the row, the store root, the origin base and the mirrors, in order.
  ## Carried on the action (`BuildAction.builtinEntries`) so an executor
  ## registered for a whole build (`crateFetchSourceExecutor`) needs no
  ## table of its own.
  result.add "row\t" & row.name & "\t" & row.version & "\t" & row.cksum
  result.add "store\t" & storeRootOf(cfg)
  result.add "origin\t" & cfg.originBase
  for m in cfg.mirrors: result.add "mirror\t" & m.location

proc crateFetchAction*(row: CrateRow; cfg: CrateFetchConfig;
                       receipt: string; cacheable: bool): BuildAction =
  ## The `cargo.fetch` edge of ``row``: `netFetch`, with every location it
  ## may contact as a tracked destination; its declared output is
  ## ``receipt``. Keyed on the row, the mirror list, the origin base and
  ## the store root.
  ##
  ## ``cacheable`` false is the form `repro build` runs: the edge is then
  ## executed on every build and, when the store holds the prefix, contacts
  ## nothing (step 1 of the module docstring), so a prefix removed from the
  ## store is always fetched again before anything reads it.
  validateRow(row)
  let id = crateFetchEdgeId(row)
  builtinAction(bakSourceFetch, id,
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    outputs = [receipt], cacheable = cacheable,
    weakFingerprint = weakFingerprintFromText(ReceiptKind & "\n" & id &
      "\n" & row.cksum & "\n" & cfg.mirrorList & "\n" & cfg.originBase &
      "\n" & storeRootOf(cfg)),
    text = "cargo.fetch " & row.label & " sha256:" & row.cksum,
    entries = crateFetchEntries(row, cfg),
    networkMode = netFetch, netDestinations = cfg.destinationsOf(row))

proc crateFetchActions*(rows: openArray[CrateRow];
                        cfg: CrateFetchConfig): seq[BuildAction] =
  ## One `cargo.fetch` edge per row (`crateFetchAction`), cacheable, with
  ## its receipt under the state directory.
  for r in rows:
    result.add crateFetchAction(r, cfg, cfg.receiptPathOf(r), cacheable = true)

proc crateFetchOf*(action: BuildAction): tuple[row: CrateRow,
                                              cfg: CrateFetchConfig] =
  ## The row and configuration a `cargo.fetch` edge was made with
  ## (`crateFetchEntries`). Raises `CrateFetchError` for an action that is
  ## not one.
  proc bad(why: string) {.noreturn.} =
    raise newException(CrateFetchError, action.id & " is not a cargo.fetch " &
      "edge: " & why)
  if action.kind != bakSourceFetch or
      not action.id.startsWith(CrateFetchEdgePrefix):
    bad("wrong kind or id")
  if action.outputs.len != 1:
    bad("it must declare exactly its receipt as output")
  result.cfg = defaultCrateFetchConfig("", @[])
  result.cfg.originBase = ""
  var sawRow, sawStore, sawOrigin = false
  for entry in action.builtinEntries:
    let f = entry.split('\t')
    case f[0]
    of "row":
      if f.len != 4 or sawRow: bad("malformed row entry")
      result.row = CrateRow(name: f[1], version: f[2], cksum: f[3])
      sawRow = true
    of "store":
      if f.len != 2 or sawStore or not f[1].isAbsolute:
        bad("malformed store entry")
      result.cfg.storeRoot = f[1]
      sawStore = true
    of "origin":
      if f.len != 2 or sawOrigin: bad("malformed origin entry")
      result.cfg.originBase = f[1]
      sawOrigin = true
    of "mirror":
      if f.len != 2: bad("malformed mirror entry")
      try: result.cfg.mirrors.add parseMirror(f[1])
      except CatchableError as e: bad("mirror " & f[1] & ": " & e.msg)
    else:
      bad("unknown entry " & f[0].escape())
  if not (sawRow and sawStore and sawOrigin):
    bad("it lacks its row, store or origin entry")
  try: validateRow(result.row)
  except CatchableError as e: bad(e.msg)
  if crateFetchEdgeId(result.row) != action.id:
    bad("its id does not name its row")

proc encodeReceipt(p: CrateFetch): string =
  result = ReceiptKind & "\n"
  result.add "row " & enc(p.row.name) & " " & enc(p.row.version) & " " &
    p.row.cksum & "\n"
  result.add "state " & $p.state & " " & $p.transport & "\n"
  result.add "prefix " & enc(p.prefix) & "\n"
  for a in p.attempts:
    result.add "attempt " & $a.transport & " " & enc(a.location) & " " &
      $a.outcome & " " & enc(a.rule) & " " & enc(a.detail) & "\n"

proc failureText*(p: CrateFetch): string =
  ## Why ``p`` failed: every location tried and what it answered.
  var lines: seq[string]
  for a in p.attempts:
    lines.add $a.transport & " " & a.location & ": " & $a.outcome &
      (if a.rule.len > 0: " (" & a.rule & ")" else: "") & ": " & a.detail
  if lines.len == 0:
    lines.add "no mirror and no origin is configured"
  "cargo.fetch " & p.row.label & " (sha256:" & p.row.cksum &
    ") failed:\n  " & lines.join("\n  ")

var executorDowngraded {.threadvar.}: HashSet[string]
  ## The mirrors `crateFetchSourceExecutor` has seen serve wrong bytes in
  ## this build (tried last from then on, as in one wave).

proc crateFetchSourceExecutor*(): SourceFetchExecutor =
  ## (Each call starts a new build's record of downgraded mirrors.)
  ## The executor of `cargo.fetch` edges in a build of their own graph
  ## (`repro build`), registered under `CrateFetchEdgePrefix`: each edge is
  ## fetched from what it carries (`crateFetchOf`), and its receipt is
  ## written only when its content changes, so an unchanged prefix does not
  ## touch it.
  executorDowngraded.clear()
  result = proc(action: BuildAction): ActionResult {.gcsafe.} =
    {.cast(gcsafe).}:
      result = ActionResult(id: action.id, status: asSucceeded, exitCode: 0,
        launched: true)
      try:
        let (row, cfg) = crateFetchOf(action)
        let p = cfg.fetchCrate(row, executorDowngraded)
        if p.state == csFailed:
          result.status = asFailed
          result.exitCode = 1
          result.stderr = p.failureText()
          return
        let receipt = action.outputs[0]
        let text = encodeReceipt(p)
        if not fileExists(receipt) or readFile(receipt) != text:
          createDir(parentDir(receipt))
          writeFile(receipt, text)
      except CatchableError as e:
        result.status = asFailed
        result.exitCode = 1
        result.stderr = action.id & ": " & e.msg

proc fetchLockedCrates*(rows: seq[CrateRow];
                        cfg: CrateFetchConfig): CrateFetchResult =
  ## Fetch every row as one wave of edges (see the module docstring).
  if cfg.stateDir.len == 0:
    raise newException(CrateFetchError, "a crate fetch needs a state " &
      "directory")
  for r in rows: validateRow(r)
  let stateDir = absolutePath(cfg.stateDir)
  createDir(stateDir)
  var jobs = initTable[string, CrateRow]()
  for r in rows:
    jobs[crateFetchEdgeId(r)] = r
  let actions = crateFetchActions(rows, cfg)
  result.actions = actions
  if actions.len == 0:
    result.ok = true
    return
  block dropStaleReceipts:
    # A receipt says the prefix WAS published; one the store no longer
    # holds (removed by `repro store gc` or by hand) must not be answered
    # from that receipt, so the edge runs again.
    var s = openStore(storeRootOf(cfg))
    defer: s.close()
    for r in rows:
      let receipt = cfg.receiptPathOf(r)
      if fileExists(receipt) and s.presentCratePrefix(r).len == 0:
        removeFile(receipt)
  let g = graph(actions)
  let findings = auditNetworkPolicy(g)
  if findings.len > 0:
    raise newException(CrateFetchError, formatNetworkPolicyAudit(findings))
  var fetched = initTable[string, CrateFetch]()
  var executed: seq[string]
  var downgraded = initHashSet[string]()
  let executor = proc(action: BuildAction): ActionResult {.gcsafe.} =
    {.cast(gcsafe).}:
      result = ActionResult(id: action.id, status: asSucceeded, exitCode: 0,
        launched: true)
      executed.add action.id
      try:
        let row = jobs[action.id]
        let p = cfg.fetchCrate(row, downgraded)
        fetched[action.id] = p
        if p.state == csFailed:
          result.status = asFailed
          result.exitCode = 1
          result.stderr = p.failureText()
        else:
          let outPath = action.outputs[0]
          createDir(parentDir(outPath))
          writeFile(outPath, encodeReceipt(p))
      except CatchableError as e:
        result.status = asFailed
        result.exitCode = 1
        result.stderr = action.id & ": " & e.msg
  registerSourceFetchExecutor(CrateFetchEdgePrefix, executor)
  try:
    var ecfg = defaultBuildEngineConfig(stateDir / "engine-cache")
    ecfg.maxParallelism = 1
    ecfg.bypassRunQuota = true
    ecfg.deferLocalOutputBlobs = false
    discard runBuild(g, ecfg)
  finally:
    clearSourceFetchExecutor(CrateFetchEdgePrefix)
  result.executed = executed
  result.ok = true
  var s = openStore(storeRootOf(cfg))
  defer: s.close()
  for r in rows:
    let id = crateFetchEdgeId(r)
    var p: CrateFetch
    if id in fetched:
      p = fetched[id]
    else:
      # An engine cache hit: the receipt is the engine's, the prefix the
      # store's.
      let present = s.presentCratePrefix(r)
      p = CrateFetch(row: r, transport: ctStore,
        state: (if present.len > 0: csPresent else: csFailed),
        prefix: present)
    if p.state == csFailed: result.ok = false
    result.crates.add p
