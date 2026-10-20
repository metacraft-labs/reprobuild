## Registry client: submit records and accept releases offline from what
## the read front serves (`Remix-Registry.md` §"Read API",
## `Remix-Protocol.md` §"Acceptance").
##
## The client trusts the read front for nothing. Every byte it uses is
## checked against signatures, the release identity, a signed checkpoint
## from a trusted log key, and inclusion proofs — including the positions
## of key-log entries, which decide whether an author key was active.

import std/[httpclient, strutils]

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
