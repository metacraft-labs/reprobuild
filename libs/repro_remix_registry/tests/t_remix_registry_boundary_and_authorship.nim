## ReproOS-Remix-Protocol-And-Registry M3a verifications that the local
## double can host:
## ``test_boundary_refuses_a_message_outside_its_vocabulary`` and
## ``test_author_identity_is_decided_by_the_interior``.
##
## Both run at the Interior end, the way a compromised Edge would reach it:
## frames are written straight into the Boundary spool, bypassing the
## intake's own checks. The registrar under test is the real one; the only
## substitution is one deliberately *lying* validator in the authorship
## case, standing in for a compromised validator guest (threat model T13) —
## that substitution is the attack being tested, not a convenience.
##
## The network-level M3a verifications (Edge egress, VM escape layering,
## confinement scores, canary alert latency) need hosts and VMs and are not
## here.

import std/[os, sequtils, tempfiles, unittest]

import repro_remix
import repro_remix_registry
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc bytesOf(s: string): seq[byte] = s.mapIt(byte(ord(it)))

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32: result[i] = seed xor byte(i)

proc kid(k: PeerKeypair): Digest32 = Digest32(keyIdOf(k))

let logKey = generateKeypair()

proc newDouble(root: string; rate = 0;
               validate: proc (p: seq[byte]): seq[byte] = nil): (Registrar, Spool) =
  var cfg = dirs(root)
  cfg.ratePerMinute = rate
  cfg.validate = validate
  (newRegistrar(cfg, logKey), initSpool(cfg.spoolDir))

proc frame(t: MessageType; payload: seq[byte]; rateKey = "client-1";
           intake = "intake-0"): seq[byte] =
  encodeMessage(BoundaryMessage(msgType: t, receivedAt: 1, intake: intake,
                                rateKey: rateKey, payload: payload))

proc genesis(k: PeerKeypair): seq[byte] =
  encodeEnvelope(entrySigned(KeyLogEntry(operation: klGenesis,
    algorithm: saEcdsaP256, publicKey: @(k.publicKey), roles: {roleAuthor}), @[k]))

proc manifestBytes(name: string; signer: PeerKeypair; listed: seq[Digest32]): seq[byte] =
  let m = Manifest(remixName: name, version: "1.0.0", intent: "Fixture.",
    license: "MIT", targets: @[Target(original: OriginalRef(package: "firefox",
      interfaceFingerprint: d32(1), catalogWorkspace: "reprobuild-packages",
      catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
      catalogRevision: "0123456789abcdef0123456789abcdef01234567",
      catalogInterfaceArtifact: d32(2)), constraintKind: ckExactFingerprint)],
    authors: listed)
  var env = newManifestEnvelope(m)
  env.signEnvelope(signer)
  encodeEnvelope(env)

suite "Remix M3a — the Boundary is a vocabulary":

  test "all five declared types round-trip (positive control)":
    let root = createTempDir("remix-boundary-", "")
    defer: removeDir(root)
    let (reg, spool) = newDouble(root)
    let alice = generateKeypair()
    var report = @(d32(7))
    report.add 1'u8
    report.add bytesOf("spam")
    discard spool.deliver("intake-0", frame(mtSubmitBlob, bytesOf("blob")))
    discard spool.deliver("intake-0", frame(mtSubmitRelease, genesis(alice)))
    discard spool.deliver("intake-0", frame(mtRequestIndexUpdate, @[]))
    discard spool.deliver("intake-0", frame(mtReportContent, report))
    discard spool.deliver("intake-0", frame(mtModerationQuery, @(d32(7))))
    let outcomes = reg.tick()
    check outcomes.len == 5
    check outcomes.allIt(it.admitted)
    check outcomes.mapIt(it.msgType).deduplicate.len == 5

  test "an undeclared type, an oversize message and a rate burst are refused and recorded":
    let root = createTempDir("remix-boundary-", "")
    defer: removeDir(root)
    let (reg, spool) = newDouble(root, rate = 3)
    # Undeclared type 9: byte 2 of the SSZ frame is the type tag.
    var undeclared = frame(mtSubmitBlob, bytesOf("x"))
    undeclared[2] = 9
    discard spool.deliver("intake-0", undeclared)
    # Oversize for its type: a 100-byte payload relabelled as a
    # moderation query, whose bound is 32 bytes.
    var oversize = frame(mtSubmitBlob, newSeq[byte](100), rateKey = "client-2")
    oversize[2] = byte(ord(mtModerationQuery))
    discard spool.deliver("intake-0", oversize)
    # Five well-formed messages from one rate key, limit three per minute.
    for i in 0 ..< 5:
      discard spool.deliver("intake-0", frame(mtSubmitBlob, bytesOf("b" & $i),
                                              rateKey = "burst"))
    let outcomes = reg.tick()
    # Blobs are processed first within a tick, so match by refusal.
    check outcomes.countIt(not it.admitted and it.refusal == rrUnknownVocabulary) == 1
    check outcomes.countIt(not it.admitted and it.refusal == rrOversize) == 1
    check outcomes.filterIt(it.admitted).len == 3
    check outcomes.filterIt(not it.admitted and it.detail == "rate limit").len == 2
    let events = capturedEvents(dirs(root).captureDir)
    check events.countIt(it[1] == "boundary-refused") == 2
    check events.countIt(it[1] == "rate-limit" and it[2] == "burst") == 2

suite "Remix M3a — author identity is decided by the Interior":

  test "Edge metadata asserting an author is never used; the signature decides":
    let root = createTempDir("remix-authorship-", "")
    defer: removeDir(root)
    let (reg, spool) = newDouble(root)
    let alice = generateKeypair()
    let mallory = generateKeypair()
    for k in [alice, mallory]:
      discard spool.deliver("intake-0", frame(mtSubmitRelease, genesis(k)))
    discard reg.tick()
    # Straight into the spool, every Edge field claiming to be alice, for a
    # release mallory signed: it is logged, and attributed to mallory.
    let rel = manifestBytes("mallory/tool", mallory, @[kid(mallory)])
    discard spool.deliver("alice", frame(mtSubmitRelease, rel,
                                         rateKey = "alice", intake = "alice"))
    let o = reg.tick()
    check o.len == 1
    check o[0].admitted
    let v = decodeAndVerify(rel)
    check v.authors == @[keyIdOf(mallory)]
    # And mallory cannot publish into alice's namespace, whatever she claims.
    discard spool.deliver("intake-0", frame(mtSubmitRelease,
      manifestBytes("alice/first", alice, @[kid(alice)])))
    discard reg.tick()
    discard spool.deliver("alice", frame(mtSubmitRelease,
      manifestBytes("alice/second", mallory, @[kid(mallory)]), rateKey = "alice"))
    check reg.tick()[0].refusal == rrForbiddenContent

  test "a lying validator cannot change who authored a release":
    let root = createTempDir("remix-authorship-", "")
    defer: removeDir(root)
    let alice = generateKeypair()
    let mallory = generateKeypair()
    # The compromised validator reports every manifest as authored by alice.
    let liar = proc (p: seq[byte]): seq[byte] =
      var v = validateSubmission(p)
      if v.ok and v.recordKind == rkManifest:
        v.authors = @[kid(alice)]
      encodeVerdict(v)
    let (reg, spool) = newDouble(root, validate = liar)
    for k in [alice, mallory]:
      discard spool.deliver("intake-0", frame(mtSubmitRelease, genesis(k)))
    discard reg.tick()
    discard spool.deliver("intake-0", frame(mtSubmitRelease,
      manifestBytes("alice/hijack", mallory, @[kid(mallory)])))
    let o = reg.tick()
    check not o[0].admitted
    check o[0].refusal == rrForbiddenContent
    check capturedEvents(dirs(root).captureDir).anyIt(it[1] == "validator-author-mismatch")
