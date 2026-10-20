## The registrar — the registry's Interior (`Remix-Registry.md` §"Zones",
## §"Admission").
##
## It is the only part that holds state of record: the transparency log,
## admitted records, namespace claims, key logs and the log signing key. It
## initiates every crossing: it polls the Boundary spool, hands submissions
## to the validator, and pushes published files to the read front's
## directory. Nothing calls into it.
##
## What the registrar parses itself is deliberately small: Boundary frames,
## validator verdicts, envelope frames and key-log entries — all bounded,
## fixed-schema records. Manifests, patches and blobs are parsed only by
## the validator (`validator.nim`). Authorship is still decided here, from
## the signatures the registrar verifies itself (FLOW-4).

import std/[algorithm, os, strutils, tables, times]

import ssz_serialization
import repro_remix
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

import ./boundary
import ./validator
import ./index

const
  MaxPublishedEnvelope* = MaxBodyBytes + 64 * 1024
  MaxListedEnvelopes* = 4096
  DefaultRatePerMinute* = 600
  ReservedNamespaces* = ["remix", "reproos", "metacraft"]
    ## Advertised reserved namespaces (canaries, EVID-4). A deployment adds
    ## unadvertised ones through `RegistrarConfig.extraReserved`.
  BlobExpiryTicks* = 1000
  KeptGenerations = 3
  MaxDeferTicks* = 250
    ## How long a release waiting for its blobs is held before it is
    ## refused. Uploads race; a release may reach the spool first.
  MaxDeferred* = 4096
    ## Ticks an unreferenced blob is held before it is dropped.

type
  RegistrarConfig* = object
    dataDir*, publishDir*, spoolDir*, captureDir*: string
    ratePerMinute*: int
    extraReserved*: seq[string]
    validate*: proc (payload: seq[byte]): seq[byte]
      ## Runs the validator and returns its encoded verdict. In the double,
      ## an in-process call; in a hosted registry, a sandboxed guest.

  Outcome* = object
    message*: string
    msgType*: MessageType
    admitted*: bool
    identity*: Digest32
    logIndex*: uint64
    refusal*: RemixRefusal
    detail*: string

  Registrar* = ref object
    cfg*: RegistrarConfig
    spool: Spool
    logKey: PeerKeypair
    log*: MerkleLog
    records: seq[seq[byte]]
    kinds: seq[RecordKind]
    byIdentity: Table[Digest32, int]
    manifests: Table[Digest32, Manifest]
    statements: Table[Digest32, seq[int]]
    blobs: Table[Digest32, seq[byte]]
    blobAge: Table[Digest32, int]
    referenced: Table[Digest32, bool]
    chains: Table[Digest32, seq[(Envelope, uint64)]]
    keyOwner: Table[Digest32, Digest32]
    namespaces: Table[string, Digest32]
    names: Table[string, seq[Digest32]]
    reports*: seq[(Digest32, uint8, string)]
    rate: Table[string, (int64, int)]
    publishedSizes: seq[uint64]
    genDir: string
    generations: seq[string]
    deferred: seq[(string, seq[byte], int)]
      ## Releases waiting for blobs: (message name, frame bytes, first tick).
      ## Interior-held, bounded by `MaxDeferred` and `MaxDeferTicks`.
    ticks: int
    dirty: bool

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(ord(c))

proc strOf(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc cmpD(a, b: Digest32): int =
  for i in 0 ..< 32:
    if a[i] != b[i]: return cmp(a[i], b[i])
  0

proc logKeyId*(r: Registrar): Digest32 = Digest32(keyIdOf(r.logKey))

# ---------------------------------------------------------------------------
# Evidence capture (EVID-1/2 in shape; the double's sink is an append-only
# file plus payload files named by digest).
# ---------------------------------------------------------------------------

proc capture*(r: Registrar; trigger, token: string; payload: openArray[byte]) =
  createDir(r.cfg.captureDir)
  let digest = toHex(blobId(payload))
  let payloadPath = r.cfg.captureDir / ("payload-" & digest)
  if not fileExists(payloadPath):
    writeFile(payloadPath, strOf(payload))
  var f = open(r.cfg.captureDir / "events.log", fmAppend)
  try:
    f.writeLine($getTime().toUnix & "\t" & trigger & "\t" & token & "\t" & digest)
  finally:
    f.close()

proc capturedEvents*(captureDir: string): seq[seq[string]] =
  let path = captureDir / "events.log"
  if not fileExists(path): return
  for line in readFile(path).splitLines:
    if line.len > 0: result.add line.split('\t')

# ---------------------------------------------------------------------------
# Publishing (the Interior pushes; the read front only serves).
# ---------------------------------------------------------------------------

type
  ProofW = object
    leafIndex: uint64
    treeSize: uint64
    path: List[Digest32, 64]

  EnvelopeListW = object
    items: List[List[byte, MaxPublishedEnvelope], MaxListedEnvelopes]

  KeyLogItemW = object
    position: uint64
    treeSize: uint64
    proof: List[Digest32, 64]
      ## Inclusion of this entry at `position`, so a client verifies the
      ## position instead of trusting the read front for it.
    envelope: List[byte, 65536]

  KeyLogFileW = object
    items: List[KeyLogItemW, MaxListedEnvelopes]

  NameFileW = object
    releases: List[Digest32, 65536]

proc encodeProof*(leafIndex, treeSize: uint64; path: seq[Digest32]): seq[byte] =
  SSZ.encode(ProofW(leafIndex: leafIndex, treeSize: treeSize,
                    path: List[Digest32, 64].init(path)))

proc decodeProof*(b: openArray[byte]): (uint64, uint64, seq[Digest32]) =
  try:
    let w = SSZ.decode(b, ProofW)
    (w.leafIndex, w.treeSize, asSeq(w.path))
  except SerializationError as e:
    refuse(rrMalformed, "proof: " & e.msg)

proc encodeEnvelopeList*(items: seq[seq[byte]]): seq[byte] =
  var ls: seq[List[byte, MaxPublishedEnvelope]]
  for i in items: ls.add List[byte, MaxPublishedEnvelope].init(i)
  SSZ.encode(EnvelopeListW(items: List[List[byte, MaxPublishedEnvelope], MaxListedEnvelopes].init(ls)))

proc decodeEnvelopeList*(b: openArray[byte]): seq[seq[byte]] =
  try:
    for i in asSeq(SSZ.decode(b, EnvelopeListW).items): result.add asSeq(i)
  except SerializationError as e:
    refuse(rrMalformed, "envelope list: " & e.msg)

type
  KeyLogItem* = object
    envelope*: seq[byte]
    position*: uint64
    treeSize*: uint64
    proof*: seq[Digest32]

proc encodeKeyLogFile*(items: seq[KeyLogItem]): seq[byte] =
  var ls: seq[KeyLogItemW]
  for it in items:
    ls.add KeyLogItemW(position: it.position, treeSize: it.treeSize,
      proof: List[Digest32, 64].init(it.proof),
      envelope: List[byte, 65536].init(it.envelope))
  SSZ.encode(KeyLogFileW(items: List[KeyLogItemW, MaxListedEnvelopes].init(ls)))

proc decodeKeyLogFile*(b: openArray[byte]): seq[KeyLogItem] =
  try:
    for i in asSeq(SSZ.decode(b, KeyLogFileW).items):
      result.add KeyLogItem(envelope: asSeq(i.envelope), position: i.position,
                            treeSize: i.treeSize, proof: asSeq(i.proof))
  except SerializationError as e:
    refuse(rrMalformed, "key-log file: " & e.msg)

proc encodeNameFile*(ids: seq[Digest32]): seq[byte] =
  SSZ.encode(NameFileW(releases: List[Digest32, 65536].init(ids)))

proc decodeNameFile*(b: openArray[byte]): seq[Digest32] =
  try:
    asSeq(SSZ.decode(b, NameFileW).releases)
  except SerializationError as e:
    refuse(rrMalformed, "name file: " & e.msg)

proc publishFile(r: Registrar; rel: string; data: openArray[byte]) =
  ## Write into the generation being assembled (`r.genDir`). Nothing in it
  ## is visible until `publish` swings `current` to it.
  let path = r.genDir / rel
  createDir(path.parentDir)
  writeFile(path, strOf(data))

proc bundleFor(r: Registrar; id: Digest32): seq[byte] =
  ## The release, its whole lineage, every blob they reference, their
  ## authors' key logs and their statements: everything a client needs to
  ## reconstruct and accept the release offline.
  var entries: seq[(BundleEntryKind, seq[byte])]
  var todo = @[id]
  var seen: seq[Digest32]
  while todo.len > 0:
    let cur = todo.pop()
    if cur in seen: continue
    seen.add cur
    entries.add (bekManifestEnvelope, r.records[r.byIdentity[cur]])
    let m = r.manifests[cur]
    var refs: seq[BlobRef]
    for p in m.patches: refs.add p.blob
    for c in m.configuration: refs.add c.value
    refs.add m.graphFragments
    refs.add m.assets
    for b in refs: entries.add (bekBlob, r.blobs[b.id])
    for j in r.statements.getOrDefault(cur):
      entries.add (bekStatementEnvelope, r.records[j])
    for a in m.authors:
      for (env, _) in r.chains[r.keyOwner[a]]:
        entries.add (bekKeyLogEnvelope, encodeEnvelope(env))
    for p in m.parents: todo.add p
  writeBundle(entries)

proc publish(r: Registrar) =
  ## Push everything the read front serves for the current tree size.
  ##
  ## Publication is atomic per generation: every file is written into a
  ## fresh `gen-<n>` directory, then the `current` symlink is replaced by a
  ## rename, so a client never sees a release without its proof, or a
  ## proof without its checkpoint.
  let size = r.log.size
  if size == 0: return
  let genName = "gen-" & $size & "-" & $r.ticks
  r.genDir = r.cfg.publishDir / genName
  removeDir(r.genDir)
  createDir(r.genDir)
  var cp = newStatementEnvelope(Statement(kind: skLogCheckpoint,
    subjectKind: sbLog, subject: r.logKeyId, treeSize: uint64(size),
    rootHash: r.log.root()))
  cp.signEnvelope(r.logKey)
  let cpBytes = encodeEnvelope(cp)
  for prev in r.publishedSizes:
    if prev < uint64(size):
      r.publishFile("v1/consistency/" & $prev & "-" & $size,
        encodeProof(prev, uint64(size), r.log.consistencyProof(int(prev), size)))
  # Blobs first, then records and proofs, then the checkpoint last, so a
  # client that sees a checkpoint finds everything it commits to.
  for id, data in r.blobs:
    if r.referenced.getOrDefault(id):
      r.publishFile("v1/blob/" & toHex(id), data)
  var index = IndexSnapshot(treeSize: uint64(size))
  for i, bytes in r.records:
    let id = envelopeIdentity(decodeEnvelope(bytes))
    case r.kinds[i]
    of rkManifest:
      r.publishFile("v1/release/" & toHex(id), bytes)
      r.publishFile("v1/release/" & toHex(id) & ".proof",
        encodeProof(uint64(i), uint64(size), r.log.inclusionProof(i, size)))
      var sts: seq[seq[byte]]
      for j in r.statements.getOrDefault(id): sts.add r.records[j]
      r.publishFile("v1/release/" & toHex(id) & ".statements", encodeEnvelopeList(sts))
      index.entries.add entryFor(r.manifests[id], id, uint64(i))
      r.publishFile("v1/bundle/" & toHex(id), r.bundleFor(id))
    else: discard
  for principal, chain in r.chains:
    var items: seq[KeyLogItem]
    for (env, pos) in chain:
      items.add KeyLogItem(envelope: encodeEnvelope(env), position: pos,
        treeSize: uint64(size), proof: r.log.inclusionProof(int(pos), size))
    r.publishFile("v1/key-log/" & toHex(principal), encodeKeyLogFile(items))
  for name, ids in r.names:
    r.publishFile("v1/name/" & name, encodeNameFile(ids))
  let indexBytes = encodeIndex(index)
  r.publishFile("v1/index/" & $size, indexBytes)
  r.publishFile("v1/index/latest", indexBytes)
  r.publishFile("v1/checkpoint/" & $size, cpBytes)
  r.publishFile("v1/checkpoint/latest", cpBytes)
  # Earlier checkpoints and consistency proofs stay servable.
  let prevCurrent = r.cfg.publishDir / "current"
  if symlinkExists(prevCurrent):
    let prevGen = r.cfg.publishDir / expandSymlink(prevCurrent)
    for sub in ["v1/checkpoint", "v1/consistency", "v1/index"]:
      if dirExists(prevGen / sub):
        for kind, f in walkDir(prevGen / sub):
          let dst = r.genDir / sub / f.extractFilename
          if kind == pcFile and not fileExists(dst):
            copyFile(f, dst)
  let link = r.cfg.publishDir / ("current.tmp-" & $getCurrentProcessId())
  if symlinkExists(link): removeFile(link)
  createSymlink(genName, link)
  moveFile(link, prevCurrent)            # rename(2): atomic replace
  # Keep the newest generations so a reader mid-request on an older one
  # can finish; drop the rest.
  r.generations.add genName
  while r.generations.len > KeptGenerations:
    removeDir(r.cfg.publishDir / r.generations[0])
    r.generations.delete(0)
  r.publishedSizes.add uint64(size)

# ---------------------------------------------------------------------------
# Construction and persistence.
# ---------------------------------------------------------------------------

proc newRegistrar*(cfg: RegistrarConfig; logKey: PeerKeypair): Registrar =
  var c = cfg
  if c.ratePerMinute <= 0: c.ratePerMinute = DefaultRatePerMinute
  if c.validate.isNil:
    c.validate = proc (payload: seq[byte]): seq[byte] =
      encodeVerdict(validateSubmission(payload))
  for d in [c.dataDir, c.publishDir, c.captureDir]:
    createDir(d)
  Registrar(cfg: c, spool: initSpool(c.spoolDir), logKey: logKey)

proc appendRecord(r: Registrar; env: Envelope): uint64 =
  let bytes = encodeEnvelope(env)
  let id = envelopeIdentity(env)
  let pos = r.log.append(logLeaf(env.recordKind, id, bytes))
  r.records.add bytes
  r.kinds.add env.recordKind
  r.byIdentity[id] = pos
  createDir(r.cfg.dataDir / "log")
  writeFile(r.cfg.dataDir / "log" / align($pos, 12, '0'), strOf(bytes))
  r.dirty = true
  uint64(pos)

# ---------------------------------------------------------------------------
# Admission.
# ---------------------------------------------------------------------------

proc isReserved(r: Registrar; ns: string): (bool, string) =
  for x in ReservedNamespaces:
    if ns == x: return (true, "reserved-namespace:" & x)
  for x in r.cfg.extraReserved:
    if ns == x: return (true, "reserved-namespace:" & x)
  (false, "")

proc principalOf(r: Registrar; key: Digest32): (bool, Digest32) =
  if key in r.keyOwner: (true, r.keyOwner[key]) else: (false, key)

proc admitKeyLog(r: Registrar; env: Envelope; o: var Outcome) =
  let e = decodeKeyLogEntry(env.body)
  let principal =
    if e.operation == klGenesis: Digest32(keyId(e.algorithm, e.publicKey))
    else: e.principal
  let pos = uint64(r.log.size)
  var chain = r.chains.getOrDefault(principal)
  chain.add (env, pos)
  let p = replayKeyLog(chain)            # refuses an invalid extension
  o.logIndex = r.appendRecord(env)
  r.chains[principal] = chain
  for k in p.keys.keys:
    r.keyOwner[k] = principal
  o.admitted = true

proc admitManifest(r: Registrar; env: Envelope; v: Verdict; payload: seq[byte];
                   o: var Outcome) =
  # Authorship is decided here, from signatures the registrar verifies.
  var signers = verifiedSigners(env)
  var authors = v.authors
  signers.sort(cmpD)
  authors.sort(cmpD)
  if signers != authors or authors.len == 0:
    r.capture("validator-author-mismatch", "", payload)
    refuse(rrForbiddenContent, "signers differ from the validator's author list")
  let slash = v.remixName.find('/')
  if slash <= 0:
    refuse(rrInvalidText, "remix name")
  let ns = v.remixName[0 ..< slash]
  let (reserved, token) = r.isReserved(ns)
  if reserved:
    r.capture("canary", token, payload)
    refuse(rrForbiddenContent, "namespace " & ns & " is reserved")
  for b in v.blobs:
    if b.id notin r.blobs or uint64(r.blobs[b.id].len) != b.size:
      refuse(rrMissingBlob, "blob " & toHex(b.id) & " has not been submitted")
  for p in v.parents:
    if p notin r.byIdentity:
      refuse(rrIncompleteLineage, "parent " & toHex(p) & " is not in this registry")
  let pos = uint64(r.log.size)
  var owners: seq[Digest32]
  for a in authors:
    let (known, principal) = r.principalOf(a)
    if not known:
      refuse(rrMissingAuthorSignature, "no key log for author " & toHex(a))
    let p = replayKeyLog(r.chains[principal])
    let h = p.keys[a]
    if h.revoked and pos >= h.compromisedFrom:
      refuse(rrRevokedKey, "author key revoked")
    if not p.keyActiveAt(a, pos, {roleAuthor, roleMaintainer}):
      refuse(rrInactiveKey, "author key not active with an authoring role")
    owners.add principal
  if ns in r.namespaces:
    if r.namespaces[ns] notin owners:
      refuse(rrForbiddenContent, "namespace " & ns & " belongs to another principal")
  else:
    r.namespaces[ns] = owners[0]
  # The manifest body is decoded here only to build the index and the
  # bundle after admission; the validator has already checked it.
  let manifest = decodeManifest(env.body)
  o.logIndex = r.appendRecord(env)
  r.manifests[v.identity] = manifest
  var pub = newStatementEnvelope(Statement(kind: skPublication,
    subjectKind: sbRelease, subject: v.identity, scope: @["namespace:" & ns]))
  pub.signEnvelope(r.logKey)
  let pubPos = r.appendRecord(pub)
  r.statements.mgetOrPut(v.identity, @[]).add int(pubPos)
  r.names.mgetOrPut(v.remixName, @[]).insert(v.identity, 0)
  for b in v.blobs:
    r.referenced[b.id] = true
  o.admitted = true

proc rateLimited(r: Registrar; key: string): bool =
  let now = getTime().toUnix
  var (start, count) = r.rate.getOrDefault(key, (now, 0))
  if now - start >= 60:
    (start, count) = (now, 0)
  inc count
  r.rate[key] = (start, count)
  count > r.cfg.ratePerMinute

proc process(r: Registrar; name: string; bytes: seq[byte]): Outcome =
  result.message = name
  var msg: BoundaryMessage
  try:
    msg = decodeMessage(bytes)
  except RemixError as e:
    r.capture("boundary-refused", $e.reason, bytes)
    result.refusal = e.reason
    result.detail = e.msg
    return
  result.msgType = msg.msgType
  if r.rateLimited(msg.rateKey):
    r.capture("rate-limit", msg.rateKey, bytes)
    result.refusal = rrBound
    result.detail = "rate limit"
    return
  try:
    case msg.msgType
    of mtSubmitBlob:
      let id = blobId(msg.payload)
      if id notin r.blobs:
        r.blobs[id] = msg.payload
        r.blobAge[id] = r.ticks
      result.identity = id
      result.admitted = true
    of mtSubmitRelease:
      let verdict = decodeVerdict(r.cfg.validate(msg.payload))
      if not verdict.ok:
        if verdict.refusal in {rrBadSignature, rrKeyMismatch, rrOversize, rrBound,
                               rrUnknownCriticalExtension, rrNonCanonical}:
          r.capture("submission-refused", $verdict.refusal, msg.payload)
        refuse(verdict.refusal, verdict.detail)
      let env = decodeEnvelope(msg.payload)
      if envelopeIdentity(env) != verdict.identity or env.recordKind != verdict.recordKind:
        r.capture("validator-identity-mismatch", "", msg.payload)
        refuse(rrForbiddenContent, "validator verdict does not match the submission")
      result.identity = verdict.identity
      if verdict.identity in r.byIdentity:
        # Idempotent: the same bytes never fork an identity or log twice.
        result.admitted = true
        result.logIndex = uint64(r.byIdentity[verdict.identity])
        return
      case env.recordKind
      of rkKeyLogEntry: r.admitKeyLog(env, result)
      of rkManifest: r.admitManifest(env, verdict, msg.payload, result)
      else: refuse(rrForbiddenContent, "record kind not accepted here")
    of mtRequestIndexUpdate:
      r.dirty = true
      result.admitted = true
    of mtReportContent:
      if msg.payload.len < 33:
        refuse(rrMalformed, "report")
      var subject: Digest32
      for i in 0 ..< 32: subject[i] = msg.payload[i]
      let text = strOf(msg.payload[33 .. ^1])
      r.reports.add (subject, msg.payload[32], text)
      result.admitted = true
    of mtModerationQuery:
      # Answered only from published moderation state; nothing to record
      # beyond the audit line.
      result.admitted = true
  except RemixError as e:
    result.admitted = false
    result.refusal = e.reason
    result.detail = e.msg

proc tick*(r: Registrar): seq[Outcome] =
  ## Claim and process every delivered message, then publish once.
  ## Releases still waiting for blobs are retried first, then new
  ## messages; a release that only lacks blobs is deferred, not refused,
  ## until `MaxDeferTicks` pass.
  inc r.ticks
  var waiting = r.deferred
  r.deferred = @[]
  var work: seq[(string, seq[byte], int)]
  for name in r.spool.pending:
    let bytes = r.spool.claim(name)
    r.spool.retire(name)
    work.add (name, bytes, r.ticks)
  # New blobs in this batch must be seen before the releases that wait on
  # them, wherever they sit in the spool order.
  var ordered: seq[(string, seq[byte], int)]
  for w in work:
    try:
      if decodeMessage(w[1]).msgType == mtSubmitBlob: ordered.add w
    except RemixError: discard
  for w in work:
    if w notin ordered: ordered.add w
  for (name, bytes, firstTick) in waiting & ordered:
    let o = r.process(name, bytes)
    if not o.admitted and o.refusal == rrMissingBlob and
       r.ticks - firstTick < MaxDeferTicks and r.deferred.len < MaxDeferred:
      r.deferred.add (name, bytes, firstTick)
      continue
    result.add o
  var expired: seq[Digest32]
  for id, age in r.blobAge:
    if not r.referenced.getOrDefault(id) and r.ticks - age > BlobExpiryTicks:
      expired.add id
  for id in expired:
    r.blobs.del id
    r.blobAge.del id
  if r.dirty:
    r.publish()
    r.dirty = false
