## ReproOS-Remix-Protocol-And-Registry M3 verification
## ``e2e_remix_signature_transparency_and_revocation``.
##
## "Valid release chains verify offline, equivocation or omission is
## detectable, and revoked keys cannot publish accepted new releases."
##
## End to end within one process: real ECDSA keys, real key-log chains, a
## real Merkle log producing real RFC 9162 proofs, real signed checkpoints.
## The log is the in-memory `MerkleLog`, which is the registry's local
## double; a client only ever sees the bytes it emits (leaves, proofs and
## signed checkpoints), exactly as it would from a remote log.

import std/[algorithm, random, unittest]

import repro_remix
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32: result[i] = seed xor byte(i)

proc kid(k: PeerKeypair): Digest32 = Digest32(keyIdOf(k))

proc sortedIds(xs: seq[Digest32]): seq[Digest32] =
  result = xs
  result.sort(proc (a, b: Digest32): int =
    for i in 0 ..< 32:
      if a[i] != b[i]: return cmp(a[i], b[i])
    0)

proc refusal(f: proc ()): string =
  try:
    f()
    "accepted"
  except RemixError as e:
    $e.reason

# --- the world -------------------------------------------------------------

type World = object
  log: MerkleLog
  records: seq[seq[byte]]   # envelope bytes by position

let logKey = generateKeypair()
let policyA = generateKeypair()
let policyB = generateKeypair()
let policyC = generateKeypair()
let trust = TrustConfig(logKeys: @[kid(logKey)],
  policyKeys: @[kid(policyA), kid(policyB), kid(policyC)], policyThreshold: 2)

proc logRecord(w: var World; env: Envelope): uint64 =
  let bytes = encodeEnvelope(env)
  let pos = w.log.append(logLeaf(env.recordKind, envelopeIdentity(env), bytes))
  w.records.add bytes
  uint64(pos)

proc checkpoint(w: World; size = -1; key = logKey): Envelope =
  let n = (if size < 0: w.log.size else: size)
  result = newStatementEnvelope(Statement(kind: skLogCheckpoint,
    subjectKind: sbLog, subject: kid(key), treeSize: uint64(n),
    rootHash: w.log.root(n)))
  result.signEnvelope(key)

proc release(name: string; signer: PeerKeypair): Envelope =
  let m = Manifest(remixName: "u/" & name, version: "1.0.0",
    intent: "Release " & name & ".", license: "MIT",
    targets: @[Target(original: OriginalRef(package: "firefox",
      interfaceFingerprint: d32(1), catalogWorkspace: "reprobuild-packages",
      catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
      catalogRevision: "0123456789abcdef0123456789abcdef01234567",
      catalogInterfaceArtifact: d32(2)), constraintKind: ckExactFingerprint)],
    authors: @[kid(signer)])
  result = newManifestEnvelope(m)
  result.signEnvelope(signer)

proc logged(w: World; pos: uint64; cp: Envelope): LoggedRecord =
  let size = int(decodeStatement(cp.body).treeSize)
  LoggedRecord(envelopeBytes: w.records[pos], index: pos,
               proof: w.log.inclusionProof(int(pos), size))

proc decide(w: World; pos: uint64; principals: seq[Principal];
            policy: seq[Envelope] = @[]): Decision =
  let cp = w.checkpoint()
  acceptRelease(AcceptanceInput(release: w.logged(pos, cp), checkpoint: cp,
    principals: principals, policyStatements: policy), trust)

proc keyEntries(w: var World; envs: seq[Envelope]): seq[(Envelope, uint64)] =
  for e in envs:
    result.add (e, w.logRecord(e))

suite "Remix M3 — signatures, transparency and revocation":

  test "a valid release chain verifies offline, and survives key rotation":
    var w: World
    let k1 = generateKeypair()
    let k2 = generateKeypair()
    let genesis = entrySigned(KeyLogEntry(operation: klGenesis,
      algorithm: saEcdsaP256, publicKey: @(k1.publicKey), roles: {roleAuthor}), @[k1])
    var chain = w.keyEntries(@[genesis])
    let v1 = w.logRecord(release("v1", k1))
    # Rotate: add k2 (signed by k1), then remove k1 (signed by k2).
    let add2 = entrySigned(KeyLogEntry(principal: kid(k1), sequence: 1,
      previous: envelopeIdentity(genesis), operation: klAddKey,
      algorithm: saEcdsaP256, publicKey: @(k2.publicKey), roles: {roleAuthor}), @[k1, k2])
    chain.add w.keyEntries(@[add2])
    let rm1 = entrySigned(KeyLogEntry(principal: kid(k1), sequence: 2,
      previous: envelopeIdentity(add2), operation: klRemoveKey, target: kid(k1)), @[k2])
    chain.add w.keyEntries(@[rm1])
    let v2 = w.logRecord(release("v2", k2))
    let late = w.logRecord(release("late", k1))
    let p = replayKeyLog(chain)
    check p.id == kid(k1)
    check w.decide(v1, @[p]).accepted          # history is not rewritten
    check w.decide(v2, @[p]).accepted
    let d = w.decide(late, @[p])
    check not d.accepted
    check d.reason == rrInactiveKey

  test "revoked keys cannot publish accepted new releases":
    var w: World
    let k = generateKeypair()
    let backup = generateKeypair()
    let genesis = entrySigned(KeyLogEntry(operation: klGenesis,
      algorithm: saEcdsaP256, publicKey: @(k.publicKey), roles: {roleAuthor}), @[k])
    var chain = w.keyEntries(@[genesis])
    let addB = entrySigned(KeyLogEntry(principal: kid(k), sequence: 1,
      previous: envelopeIdentity(genesis), operation: klAddKey,
      algorithm: saEcdsaP256, publicKey: @(backup.publicKey), roles: {roleAuthor}), @[k, backup])
    chain.add w.keyEntries(@[addB])
    let before = w.logRecord(release("before", k))
    let compromisedFrom = uint64(w.log.size)
    let stolen = w.logRecord(release("stolen", k))
    let revoke = entrySigned(KeyLogEntry(principal: kid(k), sequence: 2,
      previous: envelopeIdentity(addB), operation: klRevokeKey, target: kid(k),
      compromisedFrom: compromisedFrom), @[backup])
    chain.add w.keyEntries(@[revoke])
    let after = w.logRecord(release("after", k))
    let fixed = w.logRecord(release("fixed", backup))
    let p = replayKeyLog(chain)
    check w.decide(before, @[p]).accepted
    check w.decide(stolen, @[p]).reason == rrRevokedKey    # inside the window
    check w.decide(after, @[p]).reason == rrRevokedKey     # after revocation
    check w.decide(fixed, @[p]).accepted

  test "recovery needs the recovery quorum, not one recovery key":
    var w: World
    let lost = generateKeypair()
    let r1 = generateKeypair()
    let r2 = generateKeypair()
    let r3 = generateKeypair()
    let fresh = generateKeypair()
    let genesis = entrySigned(KeyLogEntry(operation: klGenesis,
      algorithm: saEcdsaP256, publicKey: @(lost.publicKey), roles: {roleAuthor},
      recoveryKeys: sortedIds(@[kid(r1), kid(r2), kid(r3)]), recoveryThreshold: 2), @[lost])
    let base = w.keyEntries(@[genesis])
    proc addFresh(signers: seq[PeerKeypair]): Envelope =
      entrySigned(KeyLogEntry(principal: kid(lost), sequence: 1,
        previous: envelopeIdentity(genesis), operation: klAddKey,
        algorithm: saEcdsaP256, publicKey: @(fresh.publicKey), roles: {roleAuthor}),
        signers & @[fresh])
    let one = addFresh(@[r1])
    check refusal(proc () = discard replayKeyLog(base & @[(one, 5'u64)])) == $rrMissingAuthorSignature
    let two = addFresh(@[r1, r3])
    let chain = base & w.keyEntries(@[two])
    let rel = w.logRecord(release("recovered", fresh))
    check w.decide(rel, @[replayKeyLog(chain)]).accepted
    # A stranger's signature on a key-log entry is refused outright.
    let stranger = generateKeypair()
    let forged = addFresh(@[stranger])
    check refusal(proc () = discard replayKeyLog(base & @[(forged, 5'u64)])) == $rrForbiddenContent

  test "equivocation is detectable and the evidence is self-verifying":
    var honest, fork: World
    for i in 0 ..< 5:
      discard honest.logRecord(release("r" & $i, logKey))
      discard fork.logRecord(release("r" & $i, logKey))
    discard honest.logRecord(release("a", logKey))
    discard fork.logRecord(release("b", logKey))       # same size, other leaf
    let a = verifyCheckpoint(honest.checkpoint(), trust.logKeys)
    let b = verifyCheckpoint(fork.checkpoint(), trust.logKeys)
    let (consistent, evidence) = checkConsistency(a, b, @[])
    check not consistent
    check verifyEquivocationEvidence(evidence, trust.logKeys)
    # Two checkpoints of one honest log are consistent and are not evidence.
    let early = verifyCheckpoint(honest.checkpoint(3), trust.logKeys)
    let (ok, notEvidence) = checkConsistency(early, a, honest.log.consistencyProof(3, 6))
    check ok
    check not verifyEquivocationEvidence(notEvidence, trust.logKeys)

  test "omission is detectable: a log that drops a seen record cannot prove consistency":
    var w: World
    for i in 0 ..< 4: discard w.logRecord(release("x" & $i, logKey))
    let seen = verifyCheckpoint(w.checkpoint(), trust.logKeys)
    # The log later rewrites history without record 2.
    var dropped: World
    for i in [0, 1, 3, 4, 5]: discard dropped.logRecord(release("x" & $i, logKey))
    let later = verifyCheckpoint(dropped.checkpoint(), trust.logKeys)
    let (ok, _) = checkConsistency(seen, later, dropped.log.consistencyProof(4, 5))
    check not ok
    # The honest continuation is consistent.
    for i in 4 ..< 6: discard w.logRecord(release("x" & $i, logKey))
    let (ok2, _) = checkConsistency(seen, verifyCheckpoint(w.checkpoint(), trust.logKeys),
                                    w.log.consistencyProof(4, 6))
    check ok2

  test "checkpoints, inclusion proofs and policy quorum are enforced":
    var w: World
    let k = generateKeypair()
    let chain = w.keyEntries(@[entrySigned(KeyLogEntry(operation: klGenesis,
      algorithm: saEcdsaP256, publicKey: @(k.publicKey), roles: {roleAuthor}), @[k])])
    let pos = w.logRecord(release("q", k))
    let p = replayKeyLog(chain)
    # A checkpoint signed by a key that is not a trusted log.
    let rogue = generateKeypair()
    let cp = w.checkpoint()
    check refusal(proc () = discard acceptRelease(AcceptanceInput(
      release: w.logged(pos, cp), checkpoint: w.checkpoint(key = rogue),
      principals: @[p]), trust)) == $rrForbiddenContent
    # A tampered inclusion proof.
    var bad = w.logged(pos, cp)
    bad.proof[0][0] = bad.proof[0][0] xor 1
    check acceptRelease(AcceptanceInput(release: bad, checkpoint: cp,
      principals: @[p]), trust).reason == rrNotLogged
    # A 2-of-3 block verdict blocks; one signature is not a quorum.
    let id = decodeAndVerify(w.records[pos]).id
    var verdict = newStatementEnvelope(Statement(kind: skVerdict,
      subjectKind: sbRelease, subject: Digest32(id), scope: @["block"]))
    verdict.signEnvelope(policyA)
    check refusal(proc () = discard w.decide(pos, @[p], @[verdict])) == $rrMissingAuthorSignature
    verdict.signEnvelope(policyC)
    check w.decide(pos, @[p], @[verdict]).reason == rrBlockedByPolicy
    # An author cannot add their own signature to a policy statement.
    verdict.signEnvelope(k)
    check refusal(proc () = discard w.decide(pos, @[p], @[verdict])) == $rrForbiddenContent

  test "a key cannot be added without proving possession, nor grafted between principals":
    var w: World
    let victim = generateKeypair()
    let thief = generateKeypair()
    let stranger = generateKeypair()
    let vg = entrySigned(KeyLogEntry(operation: klGenesis, algorithm: saEcdsaP256,
      publicKey: @(victim.publicKey), roles: {roleAuthor}), @[victim])
    let tg = entrySigned(KeyLogEntry(operation: klGenesis, algorithm: saEcdsaP256,
      publicKey: @(thief.publicKey), roles: {roleAuthor}), @[thief])
    let vChain = w.keyEntries(@[vg])
    let tChain = w.keyEntries(@[tg])
    # Without the added key's signature, an add-key is refused.
    let claim = entrySigned(KeyLogEntry(principal: kid(thief), sequence: 1,
      previous: envelopeIdentity(tg), operation: klAddKey, algorithm: saEcdsaP256,
      publicKey: @(stranger.publicKey), roles: {roleAuthor}), @[thief])
    check refusal(proc () = discard replayKeyLog(tChain & @[(claim, 9'u64)])) ==
      $rrMissingAuthorSignature
    # A thief holding the victim's key can co-sign it into their own log,
    # but a release by that key is refused once both logs are known.
    let graft = entrySigned(KeyLogEntry(principal: kid(thief), sequence: 1,
      previous: envelopeIdentity(tg), operation: klAddKey, algorithm: saEcdsaP256,
      publicKey: @(victim.publicKey), roles: {roleAuthor}), @[thief, victim])
    let tChain2 = tChain & w.keyEntries(@[graft])
    let pos = w.logRecord(release("grafted", victim))
    let d = w.decide(pos, @[replayKeyLog(vChain), replayKeyLog(tChain2)])
    check not d.accepted
    check d.reason == rrForbiddenContent

suite "Remix M3 — RFC 9162 proofs over many tree shapes":

  test "every inclusion and consistency proof verifies, and every tampered one fails":
    var log: MerkleLog
    var rng = initRand(9162)
    var checked = 0
    for n in 1 .. 48:
      discard log.append(@[byte(n), byte(n shr 8)])
      let root = log.root()
      for i in 0 ..< n:
        let proof = log.inclusionProof(i, n)
        check verifyInclusion(log.leaves[i], uint64(i), uint64(n), proof, root)
        if proof.len > 0:
          var t = proof
          let j = rng.rand(t.high)
          let b = rng.rand(31)
          t[j][b] = t[j][b] xor 0x80
          check not verifyInclusion(log.leaves[i], uint64(i), uint64(n), t, root)
        inc checked
      for m in 1 .. n:
        let proof = log.consistencyProof(m, n)
        check verifyConsistency(uint64(m), uint64(n), log.root(m), root, proof)
        check not verifyConsistency(uint64(m), uint64(n), log.root(m), log.leaves[0], proof) or n == 1
        inc checked
    check checked > 2000
