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
  MaxTickMessages* = 256
  MaxTickBytes* = 64 * 1024 * 1024
    ## A tick claims at most this many messages / bytes; the rest wait in
    ## the spool for the next tick, so a flood cannot exhaust Interior
    ## memory in one pass.
  MaxDeferTicks* = 250
    ## How long a release waiting for its blobs or its author's key log is
    ## held before it is refused. Uploads race; a release may reach the
    ## spool first.
  MaxDeferred* = 4096
    ## Ticks an unreferenced blob is held before it is dropped.

type
  RegistrarConfig* = object
    dataDir*, publishDir*, spoolDir*, captureDir*: string
    policyInbox*: string
      ## Interior-only directory the policy service drops quorum-signed
      ## policy statements into. Never reachable from the Edge.
    policyKeys*: seq[Digest32]
    policyThreshold*: int
    checkpointRefreshSeconds*: int64
      ## A checkpoint is re-signed when the tree grows, the policy set
      ## changes, or it is older than this (default one hour), so a quiet
      ## log stays fresh for clients' freshness bound and an Edge-triggered
      ## republish cannot make the log key sign at will.
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
    blobSizes: Table[Digest32, uint64]
      ## Blobs live on disk under `dataDir/blobs`; only sizes are in memory.
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
    lastCheckpoint: (uint64, string, int64, seq[byte])
      ## (tree size, policy scope, signed at, envelope bytes).
    policyIds: seq[Digest32]
    policyRecords: seq[int]
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

proc blobPath(r: Registrar; id: Digest32): string =
  r.cfg.dataDir / "blobs" / toHex(id)

proc hasBlob(r: Registrar; id: Digest32): bool = id in r.blobSizes

proc blobBytes(r: Registrar; id: Digest32): seq[byte] =
  bytesOf(readFile(r.blobPath(id)))

proc storeBlob(r: Registrar; id: Digest32; data: openArray[byte]) =
  ## Write aside, then rename, so a crash never leaves a partial blob.
  createDir(r.cfg.dataDir / "blobs")
  let tmp = r.blobPath(id) & ".tmp"
  writeFile(tmp, strOf(data))
  moveFile(tmp, r.blobPath(id))
  r.blobSizes[id] = uint64(data.len)

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
    for b in refs: entries.add (bekBlob, r.blobBytes(b.id))
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
  # Unique across restarts: a repeated name would make `removeDir` below
  # delete a generation readers may still be using.
  let genName = "gen-" & $size & "-" & $getTime().toUnix & "-" &
                $getTime().nanosecond & "-" & $getCurrentProcessId()
  r.genDir = r.cfg.publishDir / genName
  removeDir(r.genDir)
  createDir(r.genDir)
  # The checkpoint commits to every policy statement logged so far and
  # says, under the log's signature, when it was current.
  let scope = policyScope(r.policyIds)
  let now = getTime().toUnix
  var cpBytes: seq[byte]
  let (lastSize, lastScope, lastAt, lastBytes) = r.lastCheckpoint
  if lastBytes.len > 0 and lastSize == uint64(size) and lastScope == scope and
     now - lastAt < r.cfg.checkpointRefreshSeconds:
    cpBytes = lastBytes                  # nothing new to commit to
  else:
    var cp = newStatementEnvelope(Statement(kind: skLogCheckpoint,
      subjectKind: sbLog, subject: r.logKeyId, treeSize: uint64(size),
      rootHash: r.log.root(), scope: @[scope], issuedAt: uint64(now)))
    cp.signEnvelope(r.logKey)
    cpBytes = encodeEnvelope(cp)
    r.lastCheckpoint = (uint64(size), scope, now, cpBytes)
  for prev in r.publishedSizes:
    if prev < uint64(size):
      r.publishFile("v1/consistency/" & $prev & "-" & $size,
        encodeProof(prev, uint64(size), r.log.consistencyProof(int(prev), size)))
  # Blobs first, then records and proofs, then the checkpoint last, so a
  # client that sees a checkpoint finds everything it commits to.
  for id, _ in r.blobSizes:
    if r.referenced.getOrDefault(id):
      r.publishFile("v1/blob/" & toHex(id), r.blobBytes(id))
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
  var policyEnvs: seq[seq[byte]]
  for j in r.policyRecords: policyEnvs.add r.records[j]
  let policyBytes = encodeEnvelopeList(policyEnvs)
  r.publishFile("v1/policy/" & $size, policyBytes)
  r.publishFile("v1/policy/latest", policyBytes)
  let indexBytes = encodeIndex(index)
  r.publishFile("v1/index/" & $size, indexBytes)
  r.publishFile("v1/index/latest", indexBytes)
  r.publishFile("v1/checkpoint/" & $size, cpBytes)
  r.publishFile("v1/checkpoint/latest", cpBytes)
  # Earlier checkpoints and consistency proofs stay servable.
  let prevCurrent = r.cfg.publishDir / "current"
  if symlinkExists(prevCurrent):
    let prevGen = r.cfg.publishDir / expandSymlink(prevCurrent)
    for sub in ["v1/checkpoint", "v1/consistency", "v1/index", "v1/policy"]:
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

proc reload(r: Registrar) =
  ## Rebuild every piece of state from the registrar's own persisted log,
  ## in log order, so a restarted registrar signs a checkpoint that extends
  ## the history it signed before rather than a different one, and keeps
  ## its namespace claims. Records were admitted before they were written,
  ## so nothing here re-validates; a record that no longer decodes is a
  ## corrupt store and stops the registrar rather than being skipped.
  let logDir = r.cfg.dataDir / "log"
  if not dirExists(logDir): return
  var files: seq[string]
  for kind, path in walkDir(logDir):
    if kind == pcFile: files.add path
  files.sort(cmp)
  for i, path in files:
    if path.extractFilename != align($i, 12, '0'):
      raise newException(IOError, "registrar log is not contiguous at " & $i)
    let bytes = bytesOf(readFile(path))
    let env = decodeEnvelope(bytes)
    let id = envelopeIdentity(env)
    let pos = r.log.append(logLeaf(env.recordKind, id, bytes))
    r.records.add bytes
    r.kinds.add env.recordKind
    r.byIdentity[id] = pos
    case env.recordKind
    of rkKeyLogEntry:
      let e = decodeKeyLogEntry(env.body)
      let principal =
        if e.operation == klGenesis: Digest32(keyId(e.algorithm, e.publicKey))
        else: e.principal
      r.chains.mgetOrPut(principal, @[]).add (env, uint64(pos))
      for k in replayKeyLog(r.chains[principal]).keys.keys:
        r.keyOwner[k] = principal
    of rkManifest:
      let m = decodeManifest(env.body)
      r.manifests[id] = m
      r.names.mgetOrPut(m.remixName, @[]).insert(id, 0)
      for p in m.patches: r.referenced[p.blob.id] = true
      for c in m.configuration: r.referenced[c.value.id] = true
      for b in m.graphFragments: r.referenced[b.id] = true
      for b in m.assets: r.referenced[b.id] = true
    of rkStatement:
      let st = decodeStatement(env.body)
      case st.kind
      of skPublication:
        r.statements.mgetOrPut(st.subject, @[]).add pos
        for item in st.scope:
          if item.startsWith("namespace:"):
            let ns = item["namespace:".len .. ^1]
            if ns notin r.namespaces and st.subject in r.manifests:
              let a = r.manifests[st.subject].authors[0]
              r.namespaces[ns] = r.keyOwner.getOrDefault(a, a)
      of skVerdict, skRevocation, skModeration:
        r.policyIds.add id
        r.policyRecords.add pos
        if st.subjectKind == sbRelease:
          r.statements.mgetOrPut(st.subject, @[]).add pos
      else:
        if st.subjectKind == sbRelease:
          r.statements.mgetOrPut(st.subject, @[]).add pos
    else: discard
  let blobDir = r.cfg.dataDir / "blobs"
  if dirExists(blobDir):
    for kind, path in walkDir(blobDir):
      let name = path.extractFilename
      if kind != pcFile or name.endsWith(".tmp") or name.len != 64: continue
      var d: Digest32
      for j in 0 ..< 32: d[j] = byte(parseHexInt(name[2 * j .. 2 * j + 1]))
      r.blobSizes[d] = uint64(getFileSize(path))
      r.blobAge[d] = 0
  r.dirty = r.records.len > 0

proc newRegistrar*(cfg: RegistrarConfig; logKey: PeerKeypair): Registrar =
  var c = cfg
  if c.ratePerMinute <= 0: c.ratePerMinute = DefaultRatePerMinute
  if c.checkpointRefreshSeconds <= 0: c.checkpointRefreshSeconds = 3600
  if c.validate.isNil:
    c.validate = proc (payload: seq[byte]): seq[byte] =
      encodeVerdict(validateSubmission(payload))
  for d in [c.dataDir, c.publishDir, c.captureDir]:
    createDir(d)
  if c.policyInbox.len > 0:
    createDir(c.policyInbox)
  result = Registrar(cfg: c, spool: initSpool(c.spoolDir), logKey: logKey)
  result.reload()
  result.spool.recoverClaimed()

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
  # A key belongs to one principal. Without this, a thief holding a key
  # its owner revoked could add it to a log of their own and keep
  # publishing with it (threat model T7).
  for k in p.keys.keys:
    if k in r.keyOwner and r.keyOwner[k] != principal:
      refuse(rrForbiddenContent, "key " & toHex(k) & " already belongs to another principal")
  o.logIndex = r.appendRecord(env)
  r.chains[principal] = chain
  for k in p.keys.keys:
    r.keyOwner[k] = principal
  o.admitted = true

proc admitManifest(r: Registrar; env: Envelope; v: Verdict; payload: seq[byte];
                   o: var Outcome) =
  # Every fact the registrar acts on comes from the manifest it decodes
  # itself, never from the validator's verdict: the validator is in the
  # Edge zone, and a verdict that disagrees with the bytes is captured as
  # an attack (threat model T13). The decoder is bounded and fail-closed;
  # running it here is the residual the threat model records.
  let manifest = decodeManifest(env.body)
  var verdictBlobs, manifestBlobs: seq[Digest32]
  for b in v.blobs: verdictBlobs.add b.id
  var refs: seq[BlobRef]
  for p in manifest.patches: refs.add p.blob
  for c in manifest.configuration: refs.add c.value
  refs.add manifest.graphFragments
  refs.add manifest.assets
  for b in refs:
    if b.id notin manifestBlobs: manifestBlobs.add b.id
  verdictBlobs.sort(cmpD)
  manifestBlobs.sort(cmpD)
  if v.remixName != manifest.remixName or v.parents != manifest.parents or
     verdictBlobs != manifestBlobs:
    r.capture("validator-verdict-mismatch", "", payload)
    refuse(rrForbiddenContent, "the validator's verdict does not match the manifest")
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
    if not r.hasBlob(b.id) or r.blobSizes[b.id] != b.size:
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

proc lineageAuthorPrincipals(r: Registrar; release: Digest32): seq[Digest32] =
  ## Principals that authored the release or any ancestor.
  var todo = @[release]
  var seen: seq[Digest32]
  while todo.len > 0:
    let cur = todo.pop()
    if cur in seen or cur notin r.manifests: continue
    seen.add cur
    for a in r.manifests[cur].authors:
      let (known, p) = r.principalOf(a)
      if known and p notin result: result.add p
    for p in r.manifests[cur].parents: todo.add p

proc admitStatement(r: Registrar; env: Envelope; v: Verdict; o: var Outcome) =
  ## Statements from the Boundary, each kind gated on its signer's role at
  ## the position it would be logged.
  var signers = verifiedSigners(env)
  signers.sort(cmpD)
  var claimed = v.authors
  claimed.sort(cmpD)
  if signers != claimed:
    refuse(rrForbiddenContent, "statement signers differ from the validator's list")
  # Kind, subject and issuer come from the statement the registrar decodes
  # itself (a small fixed-schema record), not from the verdict.
  let st = decodeStatement(env.body)
  if st.kind notin SubmittableStatements or st.subjectKind != sbRelease or
     uint8(ord(st.kind)) != v.statementKind or st.subject != v.subject:
    refuse(rrForbiddenContent, "the statement is not what the validator reported")
  if signers != @[st.issuer]:
    refuse(rrForbiddenContent, "a personal statement is signed by its issuer alone")
  if st.subject notin r.manifests:
    refuse(rrDanglingReference, "statement about a release this registry does not hold")
  let kind = st.kind
  let pos = uint64(r.log.size)
  let lineageAuthors = r.lineageAuthorPrincipals(v.subject)
  for s in signers:
    let (known, principal) = r.principalOf(s)
    if not known:
      refuse(rrMissingAuthorSignature, "no key log for signer " & toHex(s))
    let p = replayKeyLog(r.chains[principal])
    case kind
    of skYank:
      if s notin r.manifests[v.subject].authors or
         not p.keyActiveAt(s, pos, {roleAuthor, roleMaintainer}):
        refuse(rrForbiddenContent, "only an active author of the release may yank it")
    of skReview, skVouch:
      if not p.keyActiveAt(s, pos, {roleReviewer}):
        refuse(rrInactiveKey, "reviews need an active reviewer key")
      if principal in lineageAuthors:
        refuse(rrForbiddenContent, "authors cannot review their own lineage")
    of skVulnerabilityClaim:
      if not p.keyActiveAt(s, pos, {roleReviewer, roleVulnerabilityVerifier}):
        refuse(rrInactiveKey, "claims need an active reviewer or verifier key")
    of skBuildEvidence, skTestEvidence:
      if not p.keyActiveAt(s, pos, {roleBuilder}):
        refuse(rrInactiveKey, "evidence needs an active builder key")
    of skAttestedInference:
      if not p.keyActiveAt(s, pos, {roleAttestedInference}):
        refuse(rrInactiveKey, "attested inference needs its role")
    else:
      refuse(rrForbiddenContent, $kind & " is not submitted through the Boundary")
  o.logIndex = r.appendRecord(env)
  r.statements.mgetOrPut(v.subject, @[]).add int(o.logIndex)
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
      if not r.hasBlob(id):
        r.storeBlob(id, msg.payload)
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
      of rkStatement: r.admitStatement(env, verdict, result)
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
  except CatchableError as e:
    # Anything else is a registrar fault on hostile input: capture it and
    # refuse the message, never let it stop the registrar.
    r.capture("registrar-fault", $e.name, bytes)
    result.admitted = false
    result.refusal = rrMalformed
    result.detail = "registrar fault: " & e.msg

proc addPolicyStatement*(r: Registrar; env: Envelope): bool =
  ## Interior-only: log a quorum-signed policy statement. Returns false if
  ## it was already logged. Refuses anything that does not meet the
  ## configured quorum.
  discard verifyQuorum(env, r.cfg.policyKeys, r.cfg.policyThreshold)
  let id = statementId(env)
  if id in r.byIdentity: return false
  let pos = r.appendRecord(env)
  r.policyIds.add id
  r.policyRecords.add int(pos)
  # Also list it with the release it is about, so a surface reading a
  # release's statements sees the verdict.
  let st = decodeStatement(env.body)
  if st.subjectKind == sbRelease:
    r.statements.mgetOrPut(st.subject, @[]).add int(pos)
  true

proc drainPolicyInbox(r: Registrar) =
  if r.cfg.policyInbox.len == 0 or not dirExists(r.cfg.policyInbox): return
  var names: seq[string]
  for kind, path in walkDir(r.cfg.policyInbox):
    if kind == pcFile and path.endsWith(".stmt"): names.add path
  names.sort(cmp)
  for path in names:
    try:
      discard r.addPolicyStatement(decodeEnvelope(bytesOf(readFile(path))))
    except RemixError as e:
      r.capture("policy-refused", $e.reason, bytesOf(readFile(path)))
    removeFile(path)

proc tick*(r: Registrar): seq[Outcome] =
  ## Claim and process every delivered message, then publish once.
  ## Releases still waiting for blobs are retried first, then new
  ## messages; a release that only lacks blobs is deferred, not refused,
  ## until `MaxDeferTicks` pass.
  inc r.ticks
  r.drainPolicyInbox()
  var waiting = r.deferred
  r.deferred = @[]
  var work: seq[(string, seq[byte], int)]
  var used = 0
  for name in r.spool.pending:
    if work.len >= MaxTickMessages or used >= MaxTickBytes: break
    let bytes = r.spool.claim(name)
    used += bytes.len
    work.add (name, bytes, r.ticks)
  # Forget rate windows that have closed, so the table stays bounded by
  # the senders of the last minute.
  let now = getTime().toUnix
  var stale: seq[string]
  for k, (start, _) in r.rate:
    if now - start >= 60: stale.add k
  for k in stale: r.rate.del k
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
    # Blobs and key logs may race the release that needs them.
    if not o.admitted and o.refusal in {rrMissingBlob, rrMissingAuthorSignature} and
       r.ticks - firstTick < MaxDeferTicks and r.deferred.len < MaxDeferred:
      r.deferred.add (name, bytes, firstTick)
      continue
    # Retired only once it has a final outcome: a crash before this point
    # leaves the message in `cur/`, and `recoverClaimed` replays it.
    r.spool.retire(name)
    # Every final refusal of a submitted record is evidence (DET/EVID):
    # revoked keys, namespace conflicts and role refusals are the
    # highest-signal ones.
    if not o.admitted and o.msgType == mtSubmitRelease:
      r.capture("admission-refused", $o.refusal, bytes)
    result.add o
  var expired: seq[Digest32]
  for id, age in r.blobAge:
    if not r.referenced.getOrDefault(id) and r.ticks - age > BlobExpiryTicks:
      expired.add id
  for id in expired:
    removeFile(r.blobPath(id))
    r.blobSizes.del id
    r.blobAge.del id
  let (_, _, signedAt, cpb) = r.lastCheckpoint
  if cpb.len > 0 and getTime().toUnix - signedAt >= r.cfg.checkpointRefreshSeconds:
    r.dirty = true                       # refresh a quiet log's checkpoint
  if r.dirty:
    try:
      r.publish()
      r.dirty = false
    except CatchableError as e:
      # The previous generation stays current; the fault is evidence.
      r.capture("publish-fault", $e.name, @[])
