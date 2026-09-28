## The REMOTE half of the portable memoization store — Cache-Scope P3.3.
##
## ``repro_local_store/portable_memo`` keeps BuildXL's
##
##   portable weak fingerprint -> candidate path sets -> portable strong
##   fingerprint -> memo record (outputs by content)
##
## on one host. This module ships the same records, and the output bytes they
## promise, through the existing signed binary-cache transport, so a record
## made on one host is found — and its outputs restored — on another host whose
## checkout sits at a different absolute path.
##
## ## Three kinds of entry
##
## The transport maps an entry key to one signed manifest and one archived
## prefix, and it cannot list keys. A lookup therefore has to be able to NAME
## every key it reads:
##
## * **Record entry** — key over (weak, path-set hash, strong); the prefix holds
##   the encoded memo record and nothing else. Metadata, like BuildXL's
##   memoization store: small, and published for every portable action, because
##   lookup without materialization (P3.4) resolves a downstream action's inputs
##   from its UPSTREAM records.
## * **Outputs entry** — the same triple under another package name; the prefix
##   holds the record again and each output's bytes. BuildXL's content store,
##   published only where the binary-cache scope publishes bytes: tagged
##   actions, or every action in an intermediate cache.
## * **Path-set slot** — key over (weak, slot number). Slot ``k`` holds one
##   encoded candidate path set. A publisher fills the first empty slot; a
##   lookup probes slots ``0, 1, …`` until the first miss.
##
## Record and outputs keys are functions of everything the record claims, so a
## republish can only write the same claim again. The server overwrites a
## republished key, so two publishers racing for one SLOT can lose a path set.
## That costs a cache MISS and nothing else: a slot only tells a consumer which
## strong fingerprint to compute, and the record it then reads is keyed by that
## computation. A publisher re-reads its slot after writing it, which narrows
## the window to near nothing.
##
## ## What makes a hit safe
##
## Nothing about a hit is taken on trust from the producer beyond its signature:
## the consumer recomputes the strong fingerprint from ITS OWN inputs (or from
## upstream records, for lookup without materialization), fetches the record
## under the key that computation names, and checks the record states that same
## weak/path-set/strong triple. Restoring checks every fetched output's BLAKE3
## content digest against the record before anything is placed in the
## checkout. A producer that published bytes other than the ones its record
## names is refused, not served — and a host does not publish a record whose
## outputs on its own disk do not match it.
##
## Entries are scoped to the concrete build platform, the same channel the
## provider-compile cache uses: the portable weak fingerprint does not hash a
## tool found in an untracked system directory, and an output made by one
## platform's tool must not be reachable from another.

import std/[algorithm, options, os, strutils]

import repro_core
import repro_local_store/portable_fingerprint
import repro_local_store/portable_memo

import ./cache_key
import ./caches_config
import ./compat_check
import ./in_process
import ./types
import ./provider_compile_cache
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../../repro_build_engine/src/repro_build_engine/platform as enginePlatform

const
  MemoCacheToolchain* = "reprobuild-memo"
  MemoCacheVersion* = "1"
  MemoRecordPackage* = "reprobuild-memo.record"
  MemoOutputsPackage* = "reprobuild-memo.outputs"
  MemoPathSetPackage* = "reprobuild-memo.pathset"
  MaxPathSetSlots* = 16
    ## Candidate path sets kept per weak fingerprint. One static action
    ## rarely observes more than a handful of distinct input sets; the bound
    ## keeps a lookup's miss path to a known number of requests.

  # Stable layout inside a published prefix.
  StagedMemoName* = "memo.rbpm"
  StagedPathSetName* = "pathset.rbps"
  StagedOutputsDir* = "outputs"

type
  MemoRemote* = object
    endpoints*: seq[SubstituteEndpoint]
      ## Trusted endpoints consulted by lookups.
    publishEndpoint*: string
    keypair*: PeerKeypair
    canPublish*: bool
      ## A signing keypair is available. Lookups need none.
    scratchRoot*: string
      ## Where fetches are staged. Each fetch uses (and removes) its own
      ## directory beneath it.

  RemoteMemoLookup* = object
    hit*: Option[PortableMemoRecord]
    reason*: string
      ## Populated on a miss. A refused entry says why it was refused.

  MemoPublishAttempt* = object
    ok*: bool
    reason*: string
    recordKeyHex*: string
    outputsPublished*: bool
    slot*: int
      ## The path-set slot that makes the record discoverable; -1 if none.

var fetchCounter {.threadvar.}: int

proc memoRemoteFromEnv*(scratchRoot: string): Option[MemoRemote] =
  ## Trust and credentials, resolved exactly as the provider-compile cache
  ## resolves them (and disabled by the same ``REPRO_CACHE_DISABLE``).
  let cfg = resolveProviderCompileCacheConfig()
  if not cfg.configured:
    return none(MemoRemote)
  var remote = MemoRemote(endpoints: cfg.endpoints,
    publishEndpoint: cfg.publishEndpoint, scratchRoot: scratchRoot)
  if cfg.keypairOk:
    remote.keypair = peerAuth.loadOrGenerateKeypair(cfg.certPath, cfg.keyPath)
    remote.canPublish = true
  some(remote)

# --- identities --------------------------------------------------------------

proc memoIdentity(remote: MemoRemote; package, revision: string):
    CacheEntryIdentity =
  let local = detectLocalPlatform(
    if remote.scratchRoot.len > 0: remote.scratchRoot else: getTempDir())
  result = newCacheEntryIdentity(
    packageName = package,
    packageVersion = MemoCacheVersion,
    platform = PlatformTriple(cpu: local.cpu, os: local.os,
                              abi: local.abi, libcVariant: local.libcVariant),
    toolchain = ToolchainIdentity(
      name: MemoCacheToolchain,
      version: MemoCacheVersion,
      hostLdSoAbi: "",
      extraFingerprint: revision),
    providerRevision = revision)
  result.addOption(enginePlatform.CachePlatformTagOptionKey,
    enginePlatform.buildPlatformTriple())

proc tripleRevision(weakHex, pathSetHashHex, strongHex: string): string =
  weakHex & "/" & pathSetHashHex & "/" & strongHex

proc memoRecordIdentity*(remote: MemoRemote; weakHex, pathSetHashHex,
                         strongHex: string): CacheEntryIdentity =
  memoIdentity(remote, MemoRecordPackage,
    tripleRevision(weakHex, pathSetHashHex, strongHex))

proc memoOutputsIdentity*(remote: MemoRemote; weakHex, pathSetHashHex,
                          strongHex: string): CacheEntryIdentity =
  memoIdentity(remote, MemoOutputsPackage,
    tripleRevision(weakHex, pathSetHashHex, strongHex))

proc pathSetSlotIdentity*(remote: MemoRemote; weakHex: string; slot: int):
    CacheEntryIdentity =
  memoIdentity(remote, MemoPathSetPackage, weakHex & "/slot/" & $slot)

# --- staging -----------------------------------------------------------------

proc sortedOutputs(record: PortableMemoRecord): PortableMemoRecord =
  ## ``encodeMemo`` orders outputs by path; staging uses the same order so an
  ## output's index in the decoded record names its staged bytes.
  result = record
  result.outputs.sort(proc (a, b: PortableOutput): int = cmp(a.path, b.path))

proc stagedOutputPath(stageDir: string; index: int): string =
  stageDir / StagedOutputsDir / $index

proc outputDigest(path: string; directory: bool): Option[string] =
  if directory:
    if not dirExists(extendedPath(path)):
      return none(string)
    some(treeContentHex(path))
  else:
    if not fileExists(extendedPath(path)):
      return none(string)
    some(fileContentHex(path))

proc writeBytes(path: string; bytes: openArray[byte]) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), bytes)

proc copyOutput(src, dst: string; directory: bool) =
  createDir(extendedPath(parentDir(dst)))
  if directory:
    removeDir(extendedPath(dst))
    copyDirWithPermissions(extendedPath(src), extendedPath(dst))
  else:
    copyFileWithPermissions(extendedPath(src), extendedPath(dst))

proc checkOutputsOnDisk*(record: PortableMemoRecord;
                         roots: openArray[LogicalRoot]): string =
  ## "" when every output the record names is on THIS host with the content
  ## the record names; otherwise why not. A record is a claim about its
  ## outputs, and this host does not publish a claim it has not checked.
  for output in record.outputs:
    let physical = toPhysicalPath(roots, output.path)
    if physical.isNone:
      return "output " & output.path & " has no location on this host"
    let actual = outputDigest(physical.get(), output.directory)
    if actual.isNone:
      return "output " & output.path & " is missing"
    if actual.get() != output.digest:
      return "output " & output.path & " does not have the content the " &
        "record names"
  ""

proc stageMemoRecord*(record: PortableMemoRecord; stageDir: string) =
  removeDir(extendedPath(stageDir))
  createDir(extendedPath(stageDir))
  writeBytes(stageDir / StagedMemoName, encodeMemo(sortedOutputs(record)))

proc stageMemoOutputs*(record: PortableMemoRecord;
                       roots: openArray[LogicalRoot]; stageDir: string):
    string =
  ## Lay out an outputs entry's prefix from the outputs on THIS host. Returns
  ## "" or the reason it cannot (see ``checkOutputsOnDisk``).
  let record = sortedOutputs(record)
  let refusal = checkOutputsOnDisk(record, roots)
  if refusal.len > 0:
    return refusal
  stageMemoRecord(record, stageDir)
  for i, output in record.outputs:
    copyOutput(toPhysicalPath(roots, output.path).get(),
      stagedOutputPath(stageDir, i), output.directory)
  ""

proc verifyStagedEntry*(stageDir, weakHex, pathSetHashHex, strongHex: string;
                        requireOutputs: bool):
    tuple[record: Option[PortableMemoRecord], reason: string] =
  ## Decide whether a fetched entry may be used: its record must state the
  ## triple its key names, and — for an outputs entry — every staged output
  ## must carry the content its record promises.
  let memoPath = stageDir / StagedMemoName
  if not fileExists(extendedPath(memoPath)):
    return (none(PortableMemoRecord), "the entry carries no memo record")
  let record =
    try:
      let raw = readFile(extendedPath(memoPath))
      decodeMemo(raw.toOpenArrayByte(0, raw.high))
    except CatchableError as err:
      return (none(PortableMemoRecord), "undecodable memo record: " & err.msg)
  if record.weakHex != weakHex or record.strongHex != strongHex or
      pathSetHash(record.pathSet) != pathSetHashHex:
    return (none(PortableMemoRecord),
      "the memo record does not describe the key it was published under")
  if requireOutputs:
    for i, output in record.outputs:
      let actual = outputDigest(stagedOutputPath(stageDir, i),
        output.directory)
      if actual.isNone:
        return (none(PortableMemoRecord),
          "the entry does not carry output " & output.path)
      if actual.get() != output.digest:
        return (none(PortableMemoRecord),
          "the entry's bytes for " & output.path &
          " are not the content its record names")
  (some(record), "")

# --- transport ---------------------------------------------------------------

proc freshDir(remote: MemoRemote; label: string): string =
  inc fetchCounter
  let base = if remote.scratchRoot.len > 0: remote.scratchRoot
             else: getTempDir()
  base / "portable-memo-remote" /
    (label & "-" & $getCurrentProcessId() & "-" & $fetchCounter)

proc removeQuietly(dir: string) =
  try: removeDir(extendedPath(dir))
  except CatchableError: discard

proc fetchEntry(remote: MemoRemote; identity: CacheEntryIdentity;
                extractDir: string): bool =
  ## Fetch one entry and extract its prefix. ``false`` on any miss or
  ## transport failure. Each fetch uses a fresh client store: a path-set slot
  ## is the one kind of key whose content can change, and a warm local index
  ## would keep answering with what it saw first.
  let store = freshDir(remote, "store")
  try:
    createDir(extendedPath(store))
    let res = substituteInProcess(deriveCacheEntryKeyHex(identity), store,
      remote.endpoints)
    if not res.ok or res.outcomes.len == 0:
      return false
    let root = res.outcomes[^1]
    if root.casPath.len == 0 or not fileExists(root.casPath):
      return false
    let archive = readFile(root.casPath)
    removeDir(extendedPath(extractDir))
    extractPrefix(archive.toOpenArrayByte(0, archive.high), extractDir)
    true
  except CatchableError:
    false
  finally:
    removeQuietly(store)

proc publishEntry(remote: MemoRemote; identity: CacheEntryIdentity;
                  stageDir: string): tuple[ok: bool, reason: string] =
  let res = publishInProcess(PublishInProcessRequest(
    entryKeyHex: deriveCacheEntryKeyHex(identity),
    prefixDir: stageDir,
    identity: identity,
    endpoint: remote.publishEndpoint,
    keypair: remote.keypair))
  if res.ok:
    (true, "")
  else:
    (false, "publish failed (status " & $res.statusCode & "): " & res.error)

proc fetchPathSetSlot(remote: MemoRemote; weakHex: string; slot: int):
    Option[PathSet] =
  let dir = freshDir(remote, "slot")
  defer: removeQuietly(dir)
  if not fetchEntry(remote, pathSetSlotIdentity(remote, weakHex, slot), dir):
    return none(PathSet)
  try:
    let raw = readFile(extendedPath(dir / StagedPathSetName))
    some(decodePathSet(raw.toOpenArrayByte(0, raw.high)))
  except CatchableError:
    # A slot that exists but does not decode is occupied, not free: report
    # an empty path set, which matches nothing a publisher would write.
    some(newSeq[PathSetEntry]())

proc remoteCandidatePathSets*(remote: MemoRemote; weakHex: string):
    seq[PathSet] =
  ## Every candidate path set published for ``weakHex``: slots are filled in
  ## order, so the first missing slot ends the walk.
  for slot in 0 ..< MaxPathSetSlots:
    let pathSet = fetchPathSetSlot(remote, weakHex, slot)
    if pathSet.isNone:
      break
    if pathSet.get().len > 0:
      result.add(pathSet.get())

# --- lookup ------------------------------------------------------------------

proc lookupRemoteMemo*(remote: MemoRemote; roots: openArray[LogicalRoot];
                       weakHex: string; resolve: IdentityResolver = nil):
    RemoteMemoLookup =
  ## BuildXL's two-phase lookup against the remote plane. For each candidate
  ## path set, compute the strong fingerprint from what is true HERE (the
  ## filesystem, or ``resolve`` — upstream records, for lookup without
  ## materialization), fetch the record that computation names, and verify it
  ## names that computation. Metadata only: executes nothing, fetches no
  ## output bytes and places nothing in the checkout.
  let candidates = remoteCandidatePathSets(remote, weakHex)
  if candidates.len == 0:
    result.reason = "no path set published for this weak fingerprint"
    return
  var refusals: seq[string] = @[]
  for pathSet in candidates:
    let strong = strongForPathSet(roots, weakHex, pathSet, resolve)
    if strong.isNone:
      continue
    let psHash = pathSetHash(pathSet)
    let dir = freshDir(remote, "record")
    defer: removeQuietly(dir)
    if not fetchEntry(remote,
        memoRecordIdentity(remote, weakHex, psHash, strong.get()), dir):
      continue
    let verdict = verifyStagedEntry(dir, weakHex, psHash, strong.get(),
      requireOutputs = false)
    if verdict.record.isNone:
      refusals.add(verdict.reason)
      continue
    result.hit = verdict.record
    return
  result.reason =
    if refusals.len > 0:
      "entry refused: " & refusals.join("; ")
    else:
      "no candidate path set matches this host's inputs"

proc restoreMemoOutputs*(remote: MemoRemote; record: PortableMemoRecord;
                         roots: openArray[LogicalRoot]): string =
  ## Fetch a record's output bytes, check each against the record, and place
  ## them at the paths THIS host's roots give them. Returns "" or the reason
  ## nothing was placed — every output is verified before the first is
  ## written, so a refusal leaves the checkout as it was.
  let psHash = pathSetHash(record.pathSet)
  let dir = freshDir(remote, "outputs")
  defer: removeQuietly(dir)
  if not fetchEntry(remote, memoOutputsIdentity(remote, record.weakHex,
      psHash, record.strongHex), dir):
    return "no outputs published for this record"
  let verdict = verifyStagedEntry(dir, record.weakHex, psHash,
    record.strongHex, requireOutputs = true)
  if verdict.record.isNone:
    return "outputs refused: " & verdict.reason
  let staged = verdict.record.get()
  var targets: seq[string] = @[]
  for output in staged.outputs:
    let physical = toPhysicalPath(roots, output.path)
    if physical.isNone:
      return "output " & output.path & " has no location on this host"
    targets.add(physical.get())
  for i, output in staged.outputs:
    try:
      copyOutput(stagedOutputPath(dir, i), targets[i], output.directory)
    except CatchableError as err:
      return "cannot restore " & output.path & ": " & err.msg
  ""

# --- publish -----------------------------------------------------------------

proc publishMemo*(remote: MemoRemote; roots: openArray[LogicalRoot];
                  record: PortableMemoRecord; withOutputs = true):
    MemoPublishAttempt =
  ## Publish a record — with its output bytes when ``withOutputs`` — then make
  ## it discoverable through a path-set slot. Outputs go first and the slot
  ## last, so a consumer that finds a slot finds a record, and one that finds
  ## a record finds the bytes it was published with. Best-effort: every
  ## failure is reported, none raises.
  result.slot = -1
  if not remote.canPublish:
    result.reason = "no publisher keypair"
    return
  let psHash = pathSetHash(record.pathSet)
  let recordId = memoRecordIdentity(remote, record.weakHex, psHash,
    record.strongHex)
  result.recordKeyHex = deriveCacheEntryKeyHex(recordId)
  let stage = freshDir(remote, "publish")
  defer: removeQuietly(stage)
  try:
    let refusal = checkOutputsOnDisk(record, roots)
    if refusal.len > 0:
      result.reason = "refusing to publish: " & refusal
      return
    if withOutputs:
      let staged = stageMemoOutputs(record, roots, stage)
      if staged.len > 0:
        result.reason = "refusing to publish: " & staged
        return
      let outputs = publishEntry(remote, memoOutputsIdentity(remote,
        record.weakHex, psHash, record.strongHex), stage)
      if not outputs.ok:
        result.reason = outputs.reason
        return
      result.outputsPublished = true
    stageMemoRecord(record, stage)
    let published = publishEntry(remote, recordId, stage)
    if not published.ok:
      result.reason = published.reason
      return
    # Discoverability.
    removeDir(extendedPath(stage))
    createDir(extendedPath(stage))
    writeBytes(stage / StagedPathSetName, encodePathSet(record.pathSet))
    for slot in 0 ..< MaxPathSetSlots:
      let held = fetchPathSetSlot(remote, record.weakHex, slot)
      if held.isSome:
        if pathSetHash(held.get()) == psHash:
          result.ok = true
          result.slot = slot
          return
        continue
      let written = publishEntry(remote,
        pathSetSlotIdentity(remote, record.weakHex, slot), stage)
      if not written.ok:
        result.reason = "record published, path set not: " & written.reason
        return
      # Another publisher may have taken the same free slot a moment
      # earlier or later; only a slot that reads back as ours counts.
      let confirm = fetchPathSetSlot(remote, record.weakHex, slot)
      if confirm.isSome and pathSetHash(confirm.get()) == psHash:
        result.ok = true
        result.slot = slot
        return
    result.reason = "record published, but all " & $MaxPathSetSlots &
      " path-set slots for its weak fingerprint hold other path sets"
  except CatchableError as err:
    result.ok = false
    result.reason = "publish error: " & err.msg
