## Registry client: submit records and accept releases offline from what
## the read front serves (`Remix-Registry.md` §"Read API",
## `Remix-Protocol.md` §"Acceptance").
##
## The client trusts the read front for nothing. Every byte it uses is
## checked against signatures, the release identity, a signed checkpoint
## from a trusted log key, and inclusion proofs — including the positions
## of key-log entries, which decide whether an author key was active.

import std/[algorithm, httpclient, strutils]

import repro_remix

import ./registrar

type
  Fetch* = proc (path: string): (int, seq[byte])
    ## GET `path` on the read front: (HTTP status, body).

  AcceptedRelease* = object
    decision*: Decision
    manifest*: Manifest
    envelopeBytes*: seq[byte]
    bundle*: Bundle

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(ord(c))

proc httpFetch*(base: string): Fetch =
  ## A `Fetch` over HTTP against `base` (e.g. "http://127.0.0.1:8080").
  result = proc (path: string): (int, seq[byte]) =
    let c = newHttpClient(timeout = 10_000)
    try:
      let resp = c.request(base & path, HttpGet)
      (resp.code.int, bytesOf(resp.body))
    finally:
      c.close()

proc submit*(intakeBase, kind: string; payload: openArray[byte]): (int, string) =
  ## POST one record to the intake. Returns (status, spool name).
  let c = newHttpClient(timeout = 30_000)
  try:
    var body = newString(payload.len)
    for i, b in payload: body[i] = char(b)
    let resp = c.request(intakeBase & "/v1/submit/" & kind, HttpPost, body)
    (resp.code.int, resp.body)
  finally:
    c.close()

proc must(fetch: Fetch; path: string): seq[byte] =
  let (status, body) = fetch(path)
  if status != 200:
    refuse(rrMissingBlob, "read front returned " & $status & " for " & path)
  body

proc fetchAndAccept*(fetch: Fetch; release: Digest32; trust: TrustConfig): AcceptedRelease =
  ## Fetch a release and decide acceptance offline. Raises on malformed or
  ## missing input; a policy refusal is a non-accepted `Decision`.
  let hex = toHex(release)
  let envBytes = fetch.must("/v1/release/" & hex)
  let (index, treeSize, path) = decodeProof(fetch.must("/v1/release/" & hex & "/proof"))
  let cpEnv = decodeEnvelope(fetch.must("/v1/checkpoint/" & $treeSize))
  let cp = verifyCheckpoint(cpEnv, trust.logKeys)
  let bundle = readBundle(fetch.must("/v1/bundle/" & hex))
  let v = decodeAndVerify(envBytes)
  if Digest32(v.id) != release:
    refuse(rrDigestMismatch, "served release is not the requested identity")
  # Principals: every genesis key-log entry in the bundle names one. Their
  # full logs come from the read front, each position proven by inclusion.
  var principals: seq[Principal]
  var seen: seq[Digest32]
  for e in bundle.entries:
    if e.kind != bekKeyLogEnvelope: continue
    let entry = decodeKeyLogEntry(decodeEnvelope(e.bytes).body)
    let pid =
      if entry.operation == klGenesis: Digest32(keyId(entry.algorithm, entry.publicKey))
      else: entry.principal
    if pid in seen: continue
    seen.add pid
    var chain: seq[(Envelope, uint64)]
    for item in decodeKeyLogFile(fetch.must("/v1/key-log/" & toHex(pid))):
      let env = decodeEnvelope(item.envelope)
      if item.treeSize != cp.treeSize:
        refuse(rrNotLogged, "key-log proof is not against the release's checkpoint")
      let leaf = hashLeaf(logLeaf(rkKeyLogEntry, envelopeIdentity(env), item.envelope))
      if not verifyInclusion(leaf, item.position, cp.treeSize, item.proof, cp.rootHash):
        refuse(rrNotLogged, "key-log entry position is not proven")
      chain.add (env, item.position)
    principals.add replayKeyLog(chain)
  result.decision = acceptRelease(AcceptanceInput(
    release: LoggedRecord(envelopeBytes: envBytes, index: index, proof: path),
    checkpoint: cpEnv, principals: principals), trust)
  result.manifest = v.manifest
  result.envelopeBytes = envBytes
  result.bundle = bundle

# ---------------------------------------------------------------------------
# Offline bundles (`Remix-Registry.md` §"Federation and mirrors (M7)").
# ---------------------------------------------------------------------------

proc fetchPolicySnapshot*(fetch: Fetch; trust: TrustConfig; now, maxAge: int64;
                          size = -1): (Envelope, seq[Envelope]) =
  ## The checkpoint (latest, or at `size`) and the policy list it commits
  ## to, both verified: quorum on every statement, digest against the
  ## commitment. Freshness is judged by the caller's gate.
  let which = (if size < 0: "latest" else: $size)
  let cpEnv = decodeEnvelope(fetch.must("/v1/checkpoint/" & which))
  let cpSize = decodeStatement(cpEnv.body).treeSize
  var policy: seq[Envelope]
  for b in decodeEnvelopeList(fetch.must("/v1/policy/" & $cpSize)):
    policy.add decodeEnvelope(b)
  discard buildPolicySnapshot(cpEnv, policy, @[], trust, now, maxAge)
  (cpEnv, policy)

proc exportOffline*(fetch: Fetch; release: Digest32; trust: TrustConfig;
                    now: int64): seq[byte] =
  ## One self-contained file: the release bundle (lineage, blobs, key logs,
  ## publication statements) plus the latest checkpoint, the policy list it
  ## commits to, and inclusion proofs for every manifest and key-log entry
  ## against that checkpoint.
  let (cpEnv, policy) = fetchPolicySnapshot(fetch, trust, now, 0)
  let cpSize = decodeStatement(cpEnv.body).treeSize
  let inner = readBundle(fetch.must("/v1/bundle/" & toHex(release)))
  var entries: seq[(BundleEntryKind, seq[byte])]
  for e in inner.entries:
    entries.add (e.kind, e.bytes)
  entries.add (bekStatementEnvelope, encodeEnvelope(cpEnv))
  for p in policy:
    entries.add (bekStatementEnvelope, encodeEnvelope(p))
  # Proofs: manifests from the release's proof files (re-fetched at the
  # checkpoint's size), key-log entries from the key-log files.
  for v in inner.manifests:
    let hex = toHex(Digest32(v.id))
    let (index, treeSize, path) = decodeProof(fetch.must("/v1/release/" & hex & "/proof"))
    if treeSize != cpSize:
      refuse(rrNotLogged, "release proof is not against the exported checkpoint")
    entries.add (bekTransparencyProof, encodeProofRecord(ProofRecord(
      recordKind: rkManifest, identity: Digest32(v.id), leafIndex: index,
      treeSize: treeSize, path: path)))
  var principals: seq[Digest32]
  for e in inner.entries:
    if e.kind != bekKeyLogEnvelope: continue
    let entry = decodeKeyLogEntry(decodeEnvelope(e.bytes).body)
    let pid =
      if entry.operation == klGenesis: Digest32(keyId(entry.algorithm, entry.publicKey))
      else: entry.principal
    if pid notin principals: principals.add pid
  for pid in principals:
    for item in decodeKeyLogFile(fetch.must("/v1/key-log/" & toHex(pid))):
      if item.treeSize != cpSize:
        refuse(rrNotLogged, "key-log proof is not against the exported checkpoint")
      entries.add (bekKeyLogEnvelope, item.envelope)
      entries.add (bekTransparencyProof, encodeProofRecord(ProofRecord(
        recordKind: rkKeyLogEntry, identity: envelopeIdentity(decodeEnvelope(item.envelope)),
        leafIndex: item.position, treeSize: item.treeSize, path: item.proof)))
  writeBundle(entries)

proc planFromOffline*(bundleBytes: openArray[byte]; release: Digest32;
                      trust: TrustConfig; now, maxAge: int64;
                      allowStaleOffline = false; source = srcBundle;
                      grantedPermissions: seq[Permission] = @[];
                      admittedLicenses: seq[string] = @[]): PlanResult =
  ## Install planning with no network: everything comes from the bundle,
  ## every position is proven, and the result goes through the same gate
  ## as every other install path.
  let b = readBundle(bundleBytes)
  var checkpoint: Envelope
  var haveCheckpoint = false
  var policy: seq[Envelope]
  for e in b.entries:
    if e.kind != bekStatementEnvelope: continue
    let env = decodeEnvelope(e.bytes)
    let st = decodeStatement(env.body)
    case st.kind
    of skLogCheckpoint:
      if st.subject in trust.logKeys:
        if haveCheckpoint:
          refuse(rrDuplicate, "an offline bundle carries one checkpoint per trusted log")
        checkpoint = env
        haveCheckpoint = true
    of skVerdict, skRevocation, skModeration:
      policy.add env
    else: discard
  if not haveCheckpoint:
    refuse(rrNotLogged, "offline bundle has no checkpoint from a trusted log")
  let cp = verifyCheckpoint(checkpoint, trust.logKeys)
  var proofs: seq[ProofRecord]
  for e in b.entries:
    if e.kind == bekTransparencyProof:
      proofs.add decodeProofRecord(e.bytes)
  proc proofFor(kind: RecordKind; id: Digest32): ProofRecord =
    for p in proofs:
      if p.recordKind == kind and p.identity == id and p.treeSize == cp.treeSize:
        return p
    refuse(rrNotLogged, "offline bundle lacks an inclusion proof for a record")
  # Principals from key-log entries, each position proven.
  var chains: seq[(Digest32, seq[(Envelope, uint64)])]
  for e in b.entries:
    if e.kind != bekKeyLogEnvelope: continue
    let env = decodeEnvelope(e.bytes)
    let id = envelopeIdentity(env)
    let p = proofFor(rkKeyLogEntry, id)
    let leaf = hashLeaf(logLeaf(rkKeyLogEntry, id, e.bytes))
    if not verifyInclusion(leaf, p.leafIndex, cp.treeSize, p.path, cp.rootHash):
      refuse(rrNotLogged, "key-log entry position is not proven")
    let entry = decodeKeyLogEntry(env.body)
    let pid =
      if entry.operation == klGenesis: Digest32(keyId(entry.algorithm, entry.publicKey))
      else: entry.principal
    var found = false
    for c in chains.mitems:
      if c[0] == pid:
        c[1].add (env, p.leafIndex)
        found = true
    if not found: chains.add (pid, @[(env, p.leafIndex)])
  var principals: seq[Principal]
  for (_, chain) in chains:
    var sorted = chain
    sorted.sort(proc (a, b: (Envelope, uint64)): int = cmp(a[1], b[1]))
    principals.add replayKeyLog(sorted)
  let snap = buildPolicySnapshot(checkpoint, policy, principals, trust, now, maxAge,
                                 allowStaleOffline)
  var candidates: seq[Candidate]
  var ancestors: seq[LoggedRecord]
  for e in b.entries:
    if e.kind != bekManifestEnvelope: continue
    let v = decodeAndVerify(e.bytes)
    let p = proofFor(rkManifest, Digest32(v.id))
    let rec = LoggedRecord(envelopeBytes: e.bytes, index: p.leafIndex, proof: p.path)
    if Digest32(v.id) == release: candidates.add Candidate(record: rec)
    else: ancestors.add rec
  if candidates.len != 1:
    refuse(rrMissingBlob, "the requested release is not in the bundle")
  let blobs = b.entries
  planInstall(source, candidates, ancestors, snap, default(Digest32), now,
    blobs = proc (id: Digest32): (bool, seq[byte]) =
      for e in blobs:
        if e.kind == bekBlob and e.digest == id: return (true, e.bytes)
      (false, newSeq[byte]()),
    grantedPermissions = grantedPermissions, admittedLicenses = admittedLicenses)
