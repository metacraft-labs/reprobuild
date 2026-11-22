## The `nimble.fetch` edges (NPC-AREQ20): every locked Nimble source fetched
## by its digest, verified, and installed in the local source store.
##
## A fetch of a lock's Nimble rows is a build-graph wave of `bakSourceFetch`
## edges, each `netFetch` with its mirrors and origin as tracked
## destinations, run by the engine (`fetchLocked`):
##
## | Edge | Cache key | Output |
## | --- | --- | --- |
## | `nimble.closure-index <key>` | the lock's closure key and the mirror list | the anchored closure index, or a note that none was usable |
## | `nimble.fetch <name>` | the row (name, origin, commit, tree) and the mirror list | a receipt; the tree is in the store |
##
## One `nimble.fetch` edge per row tries, in order (NPC-AREQ13's search
## order, Federation-And-Mirroring § "Mirror Search Strategy"):
##
## 1. the store: an entry that re-hashes to the row's tree is used as is,
##    with no network at all;
## 2. every configured mirror (organization-local first, then the
##    catalog's; the mirrors an anchored closure index lists for the row go
##    first): the canonical archive, its `archive_sha256` checked before
##    extraction when the caller knows it;
## 3. the origin's forge archive, when the origin's host is a known forge
##    (`defaultForges`), fetched through the origin egress policy with every
##    redirect re-vetted (threat model G5). Not for a row whose record lists
##    submodules: a forge's archive of a commit leaves submodule directories
##    empty (spec § 6.1, "Submodule sources");
## 4. the origin by git: exactly the locked commit, depth 1, into scratch,
##    through the same policy and the generator's confined git
##    (`repro_nimble_generator/origin_git`); the tree is read from objects.
##    A tree with gitlinks is composed as the generator composes it
##    (`repro_nimble_generator/submodules`): each submodule's `.gitmodules`
##    URL resolved, refused by the egress policy before any contact when it
##    is not `https` (and by `vetOrigin` when its addresses are not public),
##    fetched at its pinned commit into the same scratch, within the same
##    bounds, and placed as one tree (threat model G37-G39).
##
## Every transport ends the same way: the bytes are extracted in process
## into a fresh staging directory under C6's rules (`archive_extract`, threat
## model G11), the staged tree is re-hashed (`tree_walk`), and only a tree
## equal to the row's digest is renamed into the store. On any failure the
## staging tree is discarded and the next transport tried; nothing that was
## not verified is ever in the store (G10). A git checkout is never the
## result: the store holds no `.git` and no history.
##
## The downloads of a wave run in parallel (NPC-AREQ29 claim 2). The engine
## calls an executor-backed built-in edge inline in its scheduling loop, so
## the per-row edges themselves run one after another; the first of them to
## run therefore downloads, for every row not yet in the store whose first
## mirror is an HTTPS mirror, that mirror's object concurrently
## (`parallel_get`, at most `parallelDownloads` at a time) into private
## files. Each row's edge then takes its own download from there and checks,
## extracts, re-hashes and installs it exactly as if it had read the mirror
## itself, so what each edge decides, and what it records, does not depend
## on the order the transfers finished in. A row whose first mirror missed
## or held other bytes goes on to the next transport inside its own edge,
## as before. Running the edges themselves concurrently (the forge and git
## transports too) needs the engine to run executor-backed edges in
## parallel, which milestone NPC-M10 owns.

import std/[net, options, os, strutils, tables, tempfiles]

import blake3
from repro_domain_types/nimble_index/types import toHexLower
import nimcrypto/sha2

import repro_build_engine
import repro_lock/identity
import repro_core/zlib_inflate
import git_tool

import repro_nimble_generator/edge_objects
import repro_nimble_generator/egress
import repro_nimble_generator/origin_git
import repro_nimble_generator/source_tree
import repro_nimble_generator/submodules

import ./archive_extract
import ./closure_index
import ./https_get
import ./lock_rows
import ./mirror
import ./parallel_get
import ./store
import ./tree_walk

type
  Transport* = enum
    tStore = "store"
    tMirror = "mirror"
    tForgeArchive = "forge-archive"
    tGit = "git"

  AttemptOutcome* = enum
    aoFetched = "fetched"   ## verified and installed
    aoMissing = "missing"   ## the location does not hold it
    aoRefused = "refused"   ## a policy refused: egress (G5) or extraction (G11)
    aoMismatch = "mismatch" ## bytes that are not the locked tree (G10)
    aoFailed = "failed"     ## anything else (a connection, a git failure)

  FetchAttempt* = object
    transport*: Transport
    location*: string
    outcome*: AttemptOutcome
    rule*: string   ## the egress refusal kind or the extraction rule
    detail*: string

  PackageState* = enum
    psFetched = "fetched"
    psPresent = "present"   ## already in the store, verified
    psFailed = "failed"

  PackageFetch* = object
    row*: NimbleLockRow
    state*: PackageState
    transport*: Transport
    attempts*: seq[FetchAttempt]
    storePath*: string

  ForgeRule* = object
    ## A forge whose archive endpoint the origin fallback may use. The
    ## template's `{path}` is the origin's path without `/` and `.git`,
    ## `{name}` its last component, `{commit}` the locked commit.
    host*: string
    archive*: string

  ClosureState* = enum
    csNotAsked = "not-asked"
    csAbsent = "absent"
    csAnchored = "anchored"
    csRejected = "rejected"

  ClosureOutcome* = object
    state*: ClosureState
    detail*: string
    index*: ClosureIndex

  FetchObserver* = proc(transport: Transport; url: string) {.gcsafe.}
    ## Called with every location before it is contacted. Tests use it.

  FetchConfig* = object
    stateDir*: string     ## this project's edge outputs and engine cache
    storeRoot*: string    ## "" = `defaultStoreRoot()`
    mirrors*: seq[Mirror] ## the search order
    mirrorAccess*: EgressPolicy
      ## how mirrors are reached (resolver, dialer, trust anchors, limits);
      ## no origin address rules apply to a configured mirror
    originPolicy*: EgressPolicy
      ## the origin egress policy of G5, for the forge archive and git
    forges*: seq[ForgeRule]
    gitBin*: string       ## "" resolves git from `PATH`
    useClosureIndex*: bool
    limits*: ExtractLimits
    observer*: FetchObserver
    parallelDownloads*: int
      ## concurrent mirror downloads of one wave; <= 0: the default
      ## (`DefaultParallelDownloads`)

  PrefetchedRead* = object
    ## A row's object as its first mirror answered it during the wave's
    ## concurrent downloads.
    found*: bool
    path*: string    ## the private file holding the bytes, when found
    failure*: string ## why nothing was read, when not found

  FetchResult* = object
    packages*: seq[PackageFetch]
    closure*: ClosureOutcome
    executed*: seq[string]  ## the edges whose executor ran (a cache hit is not)
    actions*: seq[BuildAction]
    ok*: bool

  FetchError* = object of CatchableError

const
  ReceiptKind = "reprobuild.nimble-fetch.v1"

proc defaultForges*(): seq[ForgeRule] =
  ## The forges whose commit archives the origin fallback uses
  ## (Nimble-Package-Catalog § 10). Each archive has one top directory.
  @[ForgeRule(host: "github.com",
      archive: "https://github.com/{path}/archive/{commit}.tar.gz"),
    ForgeRule(host: "gitlab.com",
      archive: "https://gitlab.com/{path}/-/archive/{commit}/{name}-{commit}.tar.gz"),
    ForgeRule(host: "codeberg.org",
      archive: "https://codeberg.org/{path}/archive/{commit}.tar.gz"),
    ForgeRule(host: "git.sr.ht",
      archive: "https://git.sr.ht/{path}/archive/{commit}.tar.gz")]

proc defaultFetchConfig*(stateDir: string; mirrors: seq[Mirror]): FetchConfig =
  FetchConfig(stateDir: stateDir, mirrors: mirrors,
    mirrorAccess: defaultPolicy(), originPolicy: defaultPolicy(),
    forges: defaultForges(), useClosureIndex: true,
    limits: DefaultExtractLimits)

proc storeOf(cfg: FetchConfig): string =
  if cfg.storeRoot.len > 0: cfg.storeRoot else: defaultStoreRoot()

proc observe(cfg: FetchConfig; t: Transport; url: string) =
  if cfg.observer != nil:
    {.cast(gcsafe).}: cfg.observer(t, url)

proc sha256Hex(s: string): string =
  toLowerAscii($sha256.digest(s))

proc forgeArchiveUrl*(rules: seq[ForgeRule]; origin, commit: string): string =
  ## The archive URL of ``commit`` when ``origin``'s host is a known forge,
  ## else "".
  var u: OriginUrl
  try:
    u = parseOriginUrl(origin)
  except EgressError:
    return ""
  for r in rules:
    if u.host == r.host.toLowerAscii():
      var path = u.path.strip(chars = {'/'})
      if path.endsWith(".git"): path.setLen(path.len - 4)
      if path.len == 0: return ""
      let name = path.rsplit('/', maxsplit = 1)[^1]
      let authority = if u.explicitPort: r.host & ":" & $u.port else: r.host
      return r.archive.multiReplace(("{path}", path), ("{name}", name),
        ("{commit}", commit)).replace("https://" & r.host & "/",
          "https://" & authority & "/")
  ""

# ---------------------------------------------------------------------------
# One package
# ---------------------------------------------------------------------------

proc maxObjectBytes(cfg: FetchConfig; row: NimbleLockRow): int64 =
  if row.size >= 0: min(row.size, cfg.limits.maxBytes) else: cfg.limits.maxBytes

proc receiptText(row: NimbleLockRow; t: Transport; location: string): string =
  ReceiptHeader & "\n" & "tree " & enc(row.tree) & "\n" & "commit " &
    enc(row.commit) & "\n" & "transport " & $t & "\n" & "location " &
    enc(location) & "\n"

proc installFrom(cfg: FetchConfig; row: NimbleLockRow; archive: string;
                 options: ExtractOptions; t: Transport; location: string;
                 attempt: var FetchAttempt): bool =
  ## Extract ``archive`` into fresh staging, re-hash, install when equal.
  let root = storeOf(cfg)
  var staging = ""
  try:
    staging = newStaging(root)
    discard extractArchive(archive, staging, options)
    let got = treeDigestOf(staging)
    if got != row.tree:
      attempt.outcome = aoMismatch
      attempt.detail = "the tree from " & location & " hashes to " & got &
        ", the lock records " & row.tree
      discardStaging(staging)
      return false
    let (installed, detail) = installStaged(root, staging, row.tree,
      receiptText(row, t, location))
    staging = ""
    if not installed and not entryVerified(root, row.tree):
      attempt.outcome = aoFailed
      attempt.detail = detail
      return false
    attempt.outcome = aoFetched
    true
  except ExtractRefusal as e:
    attempt.outcome = aoRefused
    attempt.rule = $e.rule
    attempt.detail = e.msg
    discardStaging(staging)
    false
  except CatchableError as e:
    attempt.outcome = aoFailed
    attempt.detail = e.msg
    discardStaging(staging)
    false

proc prefetchKey(tree, mirrorLocation: string): string =
  tree & "\n" & mirrorLocation

proc tryMirror(cfg: FetchConfig; row: NimbleLockRow; m: Mirror;
               attempt: var FetchAttempt;
               prefetched: Table[string, PrefetchedRead]): bool =
  let rel = sourceObjectPath(row.tree)
  attempt.location = m.urlOf(rel)
  var r: MirrorRead
  let key = prefetchKey(row.tree, m.location)
  if key in prefetched:
    # Downloaded with the wave's other objects (observed when it was sent).
    let p = prefetched[key]
    r = if p.found: MirrorRead(found: true, bytes: readFile(p.path))
        else: MirrorRead(failure: p.failure)
  else:
    cfg.observe(tMirror, attempt.location)
    r = m.readObject(rel, cfg.maxObjectBytes(row), cfg.mirrorAccess)
  if not r.found:
    attempt.outcome = aoMissing
    attempt.detail = r.failure
    return false
  if row.archiveSha256.len > 0 and sha256Hex(r.bytes) != row.archiveSha256:
    # Before extraction (External-Package-Catalog-Adapters § "Verified
    # Tarball Acquisition"): a substituted archive is never parsed.
    attempt.outcome = aoMismatch
    attempt.rule = "archive_sha256"
    attempt.detail = "the archive from " & attempt.location & " has sha256 " &
      sha256Hex(r.bytes) & ", the index records " & row.archiveSha256
    return false
  cfg.installFrom(row, r.bytes, ExtractOptions(limits: cfg.limits), tMirror,
    attempt.location, attempt)

proc tryForgeArchive(cfg: FetchConfig; row: NimbleLockRow; url: string;
                     attempt: var FetchAttempt): bool =
  attempt.location = url
  cfg.observe(tForgeArchive, url)
  var gz = ""
  try:
    var steps: seq[RequestStep]
    gz = fetchOriginArchive(cfg.originPolicy, url, cfg.limits.maxBytes, steps)
  except EgressError as e:
    attempt.outcome = aoRefused
    attempt.rule = $e.refusal.kind
    attempt.detail = e.msg
    return false
  except CatchableError as e:
    attempt.outcome = aoFailed
    attempt.detail = e.msg
    return false
  var tarBytes = ""
  try:
    let plain = gzipDecompress(gz, int(cfg.limits.maxBytes))
    tarBytes = newString(plain.len)
    if plain.len > 0: copyMem(addr tarBytes[0], unsafeAddr plain[0], plain.len)
  except InflateError as e:
    attempt.outcome = (if e.reason == "gzip-too-large": aoRefused
                       else: aoFailed)
    attempt.rule = e.reason
    attempt.detail = e.msg
    return false
  cfg.installFrom(row, tarBytes, ExtractOptions(stripComponents: 1,
    subdir: row.subdir, limits: cfg.limits), tForgeArchive, url, attempt)

proc tryGit(cfg: FetchConfig; row: NimbleLockRow;
            attempt: var FetchAttempt): bool =
  attempt.location = row.origin
  cfg.observe(tGit, row.origin)
  let scratchRoot = cfg.stateDir / "scratch"
  createDir(scratchRoot)
  let scratch = newStaging(scratchRoot)
  defer: discardStaging(scratch)
  try:
    let v = vetOrigin(cfg.originPolicy, row.origin)
    # Git through its declared PATH-only tool profile, as the generator runs
    # it, resolved only when the git transport is needed: a fetch served by a
    # mirror needs no git.
    var gitBin = cfg.gitBin
    if gitBin.len == 0:
      try:
        gitBin = resolveGitTool(tpmPathOnly, getEnv("PATH")).binaryPath
      except CatchableError as e:
        attempt.outcome = aoFailed
        attempt.detail = "git cannot be resolved: " & e.msg
        return false
    let git = OriginGit(gitBin: gitBin, caFile: cfg.originPolicy.caFile)
    let (ok, repo, failure) = fetchCommit(git, v, scratch / "fetch",
      row.commit, cfg.originPolicy.limits)
    if not ok:
      attempt.outcome = aoFailed
      attempt.detail = failure
      return false
    var tree = readTree(git, repo, row.commit, row.subdir,
      cfg.originPolicy.limits)
    if tree.hasGitlinks:
      var fetched = initTable[string, SubmoduleLookup]()
      var n = 0
      let lookup = proc(url, identity, commit: string): SubmoduleLookup =
        ## One submodule commit, fetched now (cached by URL identity and
        ## commit for this row), through the policy (G37).
        let k = identity & "@" & commit
        if k in fetched: return fetched[k]
        cfg.observe(tGit, url)
        inc n
        try:
          let sv = vetOrigin(cfg.originPolicy, url)
          let (sok, srepo, sfailure) = fetchCommit(git, sv,
            scratch / ("sub-" & $n), commit, cfg.originPolicy.limits)
          if not sok:
            result = SubmoduleLookup(state: slFailed,
              failure: fetchFailureOf(sfailure), detail: sfailure)
          else:
            result = SubmoduleLookup(state: slReady, tree: readTree(git,
              srepo, commit, "", cfg.originPolicy.limits))
        except EgressError as e:
          result = SubmoduleLookup(state: slFailed, failure: sfEgress,
            refusal: $e.refusal.kind, detail: e.refusal.detail)
        except IOError as e:
          result = SubmoduleLookup(state: slFailed, failure: sfNoAnswer,
            detail: e.msg)
        fetched[k] = result
      let c = composeSource(tree, row.subdir, row.origin, row.commit, lookup)
      if c.state != coComposed:
        attempt.outcome =
          if c.failure.failure == sfEgress: aoRefused else: aoFailed
        attempt.rule = c.failure.refusal
        attempt.detail = eventPhrase(c.failure) &
          (if c.failure.detail.len > 0: ": " & c.failure.detail else: "")
        return false
      tree = c.tree
    # The tree is materialized from its own canonical archive, so a git
    # transport ends in the same extractor and the same digest check.
    let archive = canonicalArchive(tree.entries, tree.blobs)
    cfg.installFrom(row, archive, ExtractOptions(limits: cfg.limits), tGit,
      row.origin, attempt)
  except EgressError as e:
    attempt.outcome = aoRefused
    attempt.rule = $e.refusal.kind
    attempt.detail = e.msg
    false
  except CatchableError as e:
    attempt.outcome = aoFailed
    attempt.detail = e.msg
    false

proc mirrorOrder(cfg: FetchConfig; closureRow: Option[ClosureRow]):
    seq[Mirror] =
  ## The mirrors a row tries, in order: those an anchored closure index
  ## lists for it first, then the rest of the configuration's.
  if closureRow.isSome:
    result = usableUrls(closureRow.get, cfg.mirrors)
  for m in cfg.mirrors:
    var listed = false
    for x in result:
      if x.location == m.location: listed = true
    if not listed: result.add m

proc fetchPackage*(cfg: FetchConfig; row: NimbleLockRow;
                   closureRow = none(ClosureRow);
                   prefetched = initTable[string, PrefetchedRead]()):
    PackageFetch =
  ## Fetch one row (see the module docstring for the order). ``prefetched``
  ## holds downloads the wave already made, by `prefetchKey`.
  result = PackageFetch(row: row, state: psFailed)
  let root = storeOf(cfg)
  result.storePath = entryPath(root, row.tree)
  if hasEntry(root, row.tree):
    if entryVerified(root, row.tree):
      result.state = psPresent
      result.transport = tStore
      return
    result.attempts.add FetchAttempt(transport: tStore,
      location: result.storePath, outcome: aoMismatch,
      detail: "the store entry does not re-hash to its name; it is not " &
        "used (run `repro nimble verify`, and remove the entry)")
    return
  for m in cfg.mirrorOrder(closureRow):
    var a = FetchAttempt(transport: tMirror)
    let ok = cfg.tryMirror(row, m, a, prefetched)
    result.attempts.add a
    if ok:
      result.state = psFetched
      result.transport = tMirror
      return
  # A forge's archive of a commit has empty submodule directories, so it is
  # never the source object of a record that lists submodules.
  let archiveUrl =
    if row.submodules: ""
    else: forgeArchiveUrl(cfg.forges, row.origin, row.commit)
  if archiveUrl.len > 0:
    var a = FetchAttempt(transport: tForgeArchive)
    let ok = cfg.tryForgeArchive(row, archiveUrl, a)
    result.attempts.add a
    if ok:
      result.state = psFetched
      result.transport = tForgeArchive
      return
  var a = FetchAttempt(transport: tGit)
  let ok = cfg.tryGit(row, a)
  result.attempts.add a
  if ok:
    result.state = psFetched
    result.transport = tGit

proc closureRowOf(outcome: ClosureOutcome; name: string): Option[ClosureRow] =
  if outcome.state == csAnchored:
    for r in outcome.index.rows:
      if r.name == name: return some(r)
  none(ClosureRow)

proc prefetchMirrors*(cfg: FetchConfig; rows: seq[NimbleLockRow];
                      closure: ClosureOutcome; dir: string):
    Table[string, PrefetchedRead] =
  ## The wave's concurrent downloads (see the module docstring): for every
  ## row not in the store whose first mirror is an HTTPS mirror, that
  ## mirror's object, into a file under ``dir``. A row whose first mirror
  ## is a directory reads it in its own edge, as a local read needs no
  ## overlap. Failures are recorded as `readObject` words them.
  let root = storeOf(cfg)
  var jobs: seq[GetJob]
  var keys, urls: seq[string]
  for row in rows:
    if hasEntry(root, row.tree): continue
    let order = cfg.mirrorOrder(closureRowOf(closure, row.name))
    if order.len == 0 or order[0].kind != mkHttps: continue
    let m = order[0]
    let key = prefetchKey(row.tree, m.location)
    if key in result or key in keys: continue
    let url = m.urlOf(sourceObjectPath(row.tree))
    cfg.observe(tMirror, url)
    var u: OriginUrl
    var ip: IpAddress
    try:
      u = parseOriginUrl(url)
      ip = dialed(cfg.mirrorAccess, resolveHost(cfg.mirrorAccess, u)[0])
    except EgressError as e:
      result[key] = PrefetchedRead(failure: e.msg)
      continue
    except CatchableError as e:
      result[key] = PrefetchedRead(failure: url & ": " & e.msg)
      continue
    jobs.add GetJob(url: u, connectTo: ip, caFile: cfg.mirrorAccess.caFile,
      limits: cfg.mirrorAccess.limits, maxBytes: cfg.maxObjectBytes(row),
      dest: dir / $jobs.len & ".tar")
    keys.add key
    urls.add url
  let workers = if cfg.parallelDownloads > 0: cfg.parallelDownloads
                else: DefaultParallelDownloads
  let outcomes = getAll(jobs, workers)
  for i, o in outcomes:
    result[keys[i]] =
      if o.answered and o.status == 200:
        PrefetchedRead(found: true, path: jobs[i].dest)
      elif o.answered:
        PrefetchedRead(failure: urls[i] & " answered " & $o.status)
      elif o.refused:
        PrefetchedRead(failure: o.failure)
      else:
        PrefetchedRead(failure: urls[i] & ": " & o.failure)

# ---------------------------------------------------------------------------
# The closure index
# ---------------------------------------------------------------------------

proc readClosureIndex*(cfg: FetchConfig; rows: seq[NimbleLockRow]):
    ClosureOutcome =
  ## One request per mirror, in order, until one answers; the first answer
  ## is anchored against the lock and used, or rejected.
  let key = lockClosureKey(rows)
  result.state = csAbsent
  for m in cfg.mirrors:
    let rel = closureIndexPath(key)
    cfg.observe(tMirror, m.urlOf(rel))
    let r = m.readObject(rel, MaxClosureIndexBytes, cfg.mirrorAccess)
    if not r.found:
      result.detail.add m.location & ": " & r.failure & "; "
      continue
    try:
      let ci = decodeClosureIndex(r.bytes)
      let (verdict, reason) = anchor(ci, rows)
      if verdict == avAnchored:
        return ClosureOutcome(state: csAnchored, index: ci)
      return ClosureOutcome(state: csRejected, detail: m.location & ": " &
        reason)
    except ClosureIndexError as e:
      return ClosureOutcome(state: csRejected, detail: m.location & ": " &
        e.msg)

# ---------------------------------------------------------------------------
# The edges
# ---------------------------------------------------------------------------

proc keyOf(parts: varargs[string]): string =
  var s = ""
  for p in parts: s.add p & "\0"
  toHexLower(blake3.digest(s))

proc mirrorList(cfg: FetchConfig): string =
  var parts: seq[string]
  for m in cfg.mirrors: parts.add m.location
  parts.join("\n")

proc encodeReceipt(p: PackageFetch): string =
  result = ReceiptKind & "\n"
  result.add "row " & enc(p.row.name) & " " & enc(p.row.tree) & " " &
    enc(p.row.commit) & "\n"
  result.add "state " & $p.state & " " & $p.transport & "\n"
  for a in p.attempts:
    result.add "attempt " & $a.transport & " " & enc(a.location) & " " &
      $a.outcome & " " & enc(a.rule) & " " & enc(a.detail) & "\n"

proc fetchLocked*(rows: seq[NimbleLockRow]; cfg: FetchConfig): FetchResult =
  ## Fetch every row as one wave of edges (see the module docstring).
  if cfg.stateDir.len == 0:
    raise newException(FetchError, "a fetch needs a state directory")
  let stateDir = absolutePath(cfg.stateDir)
  createDir(stateDir)
  var jobs = initTable[string, NimbleLockRow]()
  var closureId = ""
  var closurePath = ""
  var outcome = ClosureOutcome(state: csNotAsked)
  var packages = initTable[string, PackageFetch]()
  var executed: seq[string]
  var actions: seq[BuildAction]
  var destinations: seq[string]
  for m in cfg.mirrors: destinations.add m.location
  var prefetched = initTable[string, PrefetchedRead]()
  var prefetchDir = ""
  if cfg.useClosureIndex and cfg.mirrors.len > 0 and rows.len > 0:
    let key = lockClosureKey(rows)
    closureId = "nimble.closure-index/" & key
    closurePath = stateDir / "edges" / "closure-index" / keyOf(key,
      cfg.mirrorList)
    actions.add builtinAction(bakSourceFetch, closureId,
      governingLockIdentity = lockIdentityOutsideSolvedGraph(),
      outputs = [closurePath], cacheable = true,
      weakFingerprint = weakFingerprintFromText(closureId & "\n" &
        cfg.mirrorList),
      text = "nimble closure index " & key,
      networkMode = netFetch, netDestinations = destinations)
  for r in rows:
    let id = "nimble.fetch/" & r.name
    jobs[id] = r
    var dests = destinations
    dests.add r.originUrl
    # The edge's effect is a tree installed in ``storeOf(cfg)``: its key
    # names that store, so a project whose user cache directory (and so
    # store) changed does not take a cached receipt for a tree the new
    # store lacks.
    let outPath = stateDir / "edges" / "fetch" / keyOf(r.name, r.origin,
      r.subdir, r.commit, r.tree, cfg.mirrorList, storeOf(cfg))
    # A receipt says the tree WAS installed; a store that no longer holds
    # it (an entry removed by hand or by a cleanup) must not be answered
    # from that receipt, so the edge runs again.
    if not hasEntry(storeOf(cfg), r.tree) and fileExists(outPath):
      removeFile(outPath)
    actions.add builtinAction(bakSourceFetch, id,
      governingLockIdentity = lockIdentityOutsideSolvedGraph(),
      deps = (if closureId.len > 0: @[closureId] else: @[]),
      outputs = [outPath], cacheable = true,
      weakFingerprint = weakFingerprintFromText(id & "\n" & r.tree & "\n" &
        r.commit & "\n" & r.originUrl & "\n" & cfg.mirrorList & "\n" &
        storeOf(cfg)),
      text = "nimble.fetch " & r.name & " " & r.tree,
      networkMode = netFetch, netDestinations = dests)
  result.actions = actions
  if actions.len == 0:
    result.ok = true
    return
  let g = graph(actions)
  let findings = auditNetworkPolicy(g)
  if findings.len > 0:
    raise newException(FetchError, formatNetworkPolicyAudit(findings))
  let executor = proc(action: BuildAction): ActionResult {.gcsafe.} =
    {.cast(gcsafe).}:
      result = ActionResult(id: action.id, status: asSucceeded, exitCode: 0,
        launched: true)
      executed.add action.id
      let outPath = action.outputs[0]
      createDir(parentDir(outPath))
      try:
        if action.id == closureId:
          outcome = cfg.readClosureIndex(rows)
          writeFile(outPath, $outcome.state & "\n" & (
            if outcome.state == csAnchored: encodeClosureIndex(outcome.index)
            else: enc(outcome.detail) & "\n"))
        else:
          let row = jobs[action.id]
          if prefetchDir.len == 0:
            # The first fetch edge to run downloads the wave's objects
            # concurrently; each edge then takes its own.
            prefetchDir = createTempDir(".prefetch-", "", stateDir)
            prefetched = cfg.prefetchMirrors(rows, outcome, prefetchDir)
          let p = cfg.fetchPackage(row, closureRowOf(outcome, row.name),
            prefetched)
          packages[row.name] = p
          if p.state == psFailed:
            result.status = asFailed
            result.exitCode = 1
            var lines: seq[string]
            for a in p.attempts:
              lines.add $a.transport & " " & a.location & ": " & $a.outcome &
                (if a.rule.len > 0: " (" & a.rule & ")" else: "") & ": " &
                a.detail
            result.stderr = "nimble.fetch " & row.name & " " & row.tree &
              " failed:\n  " & lines.join("\n  ")
          else:
            writeFile(outPath, encodeReceipt(p))
      except CatchableError as e:
        result.status = asFailed
        result.exitCode = 1
        result.stderr = action.id & ": " & e.msg
  registerSourceFetchExecutor(executor)
  var failures: seq[string]
  try:
    var ecfg = defaultBuildEngineConfig(stateDir / "engine-cache")
    ecfg.maxParallelism = 1
    ecfg.bypassRunQuota = true
    ecfg.deferLocalOutputBlobs = false
    let run = runBuild(g, ecfg)
    for res in run.results:
      if res.status == asFailed:
        failures.add res.stderr
  finally:
    clearSourceFetchExecutor()
    if prefetchDir.len > 0:
      # Plain files the workers wrote, in a directory private to this run.
      removeDir(prefetchDir)
  result.closure = outcome
  result.executed = executed
  for r in rows:
    if r.name in packages:
      result.packages.add packages[r.name]
    else:
      # A cache hit: the receipt is the engine's; the tree is the store's.
      let root = storeOf(cfg)
      result.packages.add PackageFetch(row: r, transport: tStore,
        state: (if hasEntry(root, r.tree): psPresent else: psFailed),
        storePath: entryPath(root, r.tree))
  result.ok = failures.len == 0
  for p in result.packages:
    if p.state == psFailed: result.ok = false
