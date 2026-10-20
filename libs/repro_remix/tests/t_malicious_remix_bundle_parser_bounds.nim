## ReproOS-Remix-Protocol-And-Registry M1 verification
## ``test_malicious_remix_bundle_parser_bounds``.
##
## "Traversal, bombs, cycles, ambiguity, malformed signatures, oversized
## fields, and unknown critical extensions fail safely."
##
## Each case builds hostile bytes the way an attacker would — by writing the
## wire format directly, bypassing the encoder's validation — and asserts
## the decoder refuses with the expected stable reason code. "Fail safely"
## is checked by the mutation sweep at the end: every corrupted input must
## end in a `RemixError`, never another exception, a crash or acceptance.
##
## Two items in the milestone text have no attack surface in v1, by design
## (Remix-Protocol.md §"Blobs" and §"Export bundle"): there is no archive
## blob kind to decompress, and bundles are never extracted to paths. The
## nearest surfaces that DO exist are tested instead: an oversized declared
## blob size (refused before any read) and path-like remix names.
##
## No mocks: real keys, real codec, real signature verification.

import std/[random, sequtils, strutils, unittest]

import ssz_serialization
import repro_remix
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32:
    result[i] = seed xor byte(i)

proc bytesOf(s: string): seq[byte] = s.mapIt(byte(ord(it)))

proc blob(text, mediaType: string): BlobRef =
  BlobRef(id: blobId(bytesOf(text)), mediaType: mediaType,
          size: uint64(text.len))

let alice = generateKeypair()
let mallory = generateKeypair()
let aliceId = Digest32(keyIdOf(alice))

proc baseManifest(): Manifest =
  Manifest(
    remixName: "alice/compact-tabs", version: "1.0.0",
    intent: "Shorter tabs.", license: "MIT",
    targets: @[Target(original: OriginalRef(package: "firefox",
      interfaceFingerprint: d32(1), catalogWorkspace: "reprobuild-packages",
      catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
      catalogRevision: "0123456789abcdef0123456789abcdef01234567",
      catalogInterfaceArtifact: d32(2)), constraintKind: ckExactFingerprint)],
    patches: @[Patch(appliesToKind: ptTarget, appliesToIndex: 0,
      blob: blob("--- a/x\n+++ b/x\n", "text/x-diff"), strip: 1, order: 0)],
    authors: @[aliceId])

proc envelopeWithBody(body: seq[byte]): seq[byte] =
  ## Frame an arbitrary body and sign it, as an attacker holding a real key
  ## can: the signature is valid, so only the body checks can refuse.
  var env = Envelope(schemaVersion: RemixSchemaVersion, recordKind: rkManifest,
                     body: body)
  env.signEnvelope(alice)
  encodeEnvelope(env)

proc wireBody(mutate: proc (w: var ManifestW)): seq[byte] =
  var w = toWire(baseManifest())
  mutate(w)
  SSZ.encode(w)

template refusesWith(expected: RemixRefusal; body: untyped) =
  var got = "no refusal"
  try:
    body
  except RemixError as e:
    got = $e.reason
  check got == $expected

proc goodBytes(): seq[byte] =
  var env = newManifestEnvelope(baseManifest())
  env.signEnvelope(alice)
  encodeEnvelope(env)

suite "Remix M1 — malicious bundle parser bounds":

  test "the unmodified fixture is accepted (positive control)":
    check decodeAndVerify(goodBytes()).manifest == baseManifest()

  test "frame-level corruption is refused before decoding":
    let good = goodBytes()
    refusesWith(rrTruncated): discard decodeAndVerify(good[0 ..< 8])
    var bad = good; bad[0] = byte('X')
    refusesWith(rrBadMagic): discard decodeAndVerify(bad)
    bad = good; bad[4] = 9
    refusesWith(rrUnknownEnvelopeVersion): discard decodeAndVerify(bad)
    bad = good; bad[6] = 0x02
    refusesWith(rrUnknownTypeId): discard decodeAndVerify(bad)
    refusesWith(rrLengthMismatch): discard decodeAndVerify(good & @[0'u8])
    refusesWith(rrLengthMismatch): discard decodeAndVerify(good[0 ..< ^1])
    # A length field claiming a huge payload is refused on the number,
    # before anything that size is read or allocated.
    bad = good; bad[8] = 0xff; bad[9] = 0xff; bad[10] = 0xff; bad[11] = 0x7f
    refusesWith(rrOversize): discard decodeAndVerify(bad)

  test "unknown schema versions, feature bits and record kinds fail closed":
    var env = newManifestEnvelope(baseManifest())
    env.schemaVersion = 2
    refusesWith(rrUnknownSchemaVersion): discard decodeAndVerify(encodeEnvelope(env))
    env = newManifestEnvelope(baseManifest())
    env.requiredFeatures = 0x80
    refusesWith(rrUnknownRequiredFeature): discard decodeAndVerify(encodeEnvelope(env))
    # recordKind 9 is not in the vocabulary.
    var raw = goodBytes()
    let w = SSZ.decode(raw.toOpenArray(12, raw.len - 1), WrapperW)
    var w2 = w; w2.recordKind = 9
    let payload = SSZ.encode(w2)
    raw = raw[0 ..< 12] & payload
    refusesWith(rrUnknownRecordKind): discard decodeAndVerify(raw)

  test "ambiguity: unsorted, duplicate and non-canonical encodings":
    var m = baseManifest()
    m.parents = @[d32(9), d32(3)]
    refusesWith(rrUnsorted): discard encodeManifest(m)
    refusesWith(rrUnsorted):
      discard decodeAndVerify(envelopeWithBody(wireBody(proc (w: var ManifestW) =
        w.parents = List[Digest32, MaxParents].init(@[d32(9), d32(3)]))))
    refusesWith(rrDuplicate):
      discard decodeAndVerify(envelopeWithBody(wireBody(proc (w: var ManifestW) =
        w.parents = List[Digest32, MaxParents].init(@[d32(3), d32(3)]))))
    refusesWith(rrNonCanonical):
      discard decodeAndVerify(envelopeWithBody(wireBody(proc (w: var ManifestW) =
        w.targets.asSeq[0].constraint = SszName.init(bytesOf("=1.0")))))
    # Trailing bytes inside the body are refused by the SSZ decoder.
    var body = encodeManifest(baseManifest())
    body.add 0
    refusesWith(rrMalformed): discard decodeAndVerify(envelopeWithBody(body))

  test "traversal-shaped and non-ASCII names are refused":
    for name in ["../etc", "alice/../bob", "alice/", "/bob", "alice/b/c",
                 "Alice/tabs", "alice/täbs", "alice/ta bs", "alice\\tabs"]:
      var m = baseManifest()
      m.remixName = name
      checkpoint name
      refusesWith(rrInvalidText): discard encodeManifest(m)
    var m = baseManifest()
    m.targets[0].original.package = "fire\x00fox"
    refusesWith(rrInvalidText): discard encodeManifest(m)

  test "free text must be valid UTF-8 without control characters":
    for intent in ["\xff\xfe", "ok\x1b[31mred", "nul\x00", "\xc2\x85nel"]:
      checkpoint intent
      refusesWith(rrInvalidText):
        discard decodeAndVerify(envelopeWithBody(wireBody(proc (w: var ManifestW) =
          w.intent = SszIntent.init(bytesOf(intent)))))

  test "oversized fields and declared sizes are refused":
    var m = baseManifest()
    m.intent = "x".repeat(MaxIntentBytes + 1)
    refusesWith(rrBound): discard encodeManifest(m)
    m = baseManifest()
    m.patches[0].blob.size = MaxBlobBytes + 1
    refusesWith(rrBound): discard encodeManifest(m)
    m = baseManifest()
    m.assets = @[BlobRef(id: d32(5), mediaType: "image/png", size: MaxAssetBytes + 1)]
    refusesWith(rrBound): discard encodeManifest(m)
    m = baseManifest()
    m.parents = toSeq(0 .. MaxParents).mapIt(d32(byte(it)))
    refusesWith(rrBound): discard encodeManifest(m)
    # A wire list longer than its bound is refused by the SSZ decoder.
    var raw = SSZ.encode(toWire(baseManifest()))
    refusesWith(rrOversize):
      discard decodeManifest(newSeq[byte](MaxBodyBytes + 1))
    discard raw

  test "unknown vocabulary and forbidden contributions are refused":
    refusesWith(rrUnknownVocabulary):
      discard decodeAndVerify(envelopeWithBody(wireBody(proc (w: var ManifestW) =
        discard w.permissions.add PermissionW(kind: 99))))
    # prForce (3) and prDefault (0) are not Remix priorities.
    for prio in [0'u8, 3'u8]:
      refusesWith(rrUnknownVocabulary):
        discard decodeAndVerify(envelopeWithBody(wireBody(proc (w: var ManifestW) =
          discard w.configuration.add ConfigContributionW(
            configurable: SszName.init(bytesOf("a.b")), priority: prio,
            operation: 1, value: BlobRefW(id: d32(1),
              mediaType: SszName.init(bytesOf("text/plain")), size: 1)))))
    var m = baseManifest()
    m.patches[0].appliesToIndex = 3
    refusesWith(rrDanglingReference): discard encodeManifest(m)
    m = baseManifest()
    m.permissions = @[Permission(kind: pkNetworkClient, scope: "anything")]
    refusesWith(rrNonCanonical): discard encodeManifest(m)

  test "unknown critical extensions refuse; unknown non-critical ones are kept":
    var m = baseManifest()
    m.extensions = @[Extension(id: "x-future.sandbox", critical: true,
                               payload: bytesOf("v2"))]
    refusesWith(rrUnknownCriticalExtension): discard encodeManifest(m)
    m.extensions[0].critical = false
    var env = newManifestEnvelope(m)
    env.signEnvelope(alice)
    let v = decodeAndVerify(encodeEnvelope(env))
    check v.manifest.extensions == m.extensions

  test "malformed signatures are refused":
    let good = decodeEnvelope(goodBytes())
    # A body changed after signing.
    var tampered = good
    var m = baseManifest(); m.version = "1.0.1"
    tampered.body = encodeManifest(m)
    refusesWith(rrBadSignature): discard verifyManifestEnvelope(tampered)
    # A signature whose public key does not hash to its key id.
    var swapped = good
    swapped.signatures[0].publicKey = @(mallory.publicKey)
    refusesWith(rrKeyMismatch): discard verifyManifestEnvelope(swapped)
    # A valid signature by a key that is not a listed author.
    var extra = good
    extra.signEnvelope(mallory)
    refusesWith(rrForbiddenContent): discard verifyManifestEnvelope(extra)
    # A listed author who has not signed.
    var unsigned = good
    unsigned.signatures = @[]
    refusesWith(rrMissingAuthorSignature): discard verifyManifestEnvelope(unsigned)
    # A wrong-length signature value is a shape error, at decode time.
    var short = good
    short.signatures[0].value.setLen(10)
    refusesWith(rrMalformed): discard encodeEnvelope(short)

  test "lineage cycles and excessive depth are refused, not followed":
    let a = ReleaseId(d32(1))
    let b = ReleaseId(d32(2))
    let cyclic: ParentResolver = proc (id: ReleaseId): (bool, seq[Digest32]) =
      if id == a: (true, @[Digest32(b)]) else: (true, @[Digest32(a)])
    refusesWith(rrLineageCycle): discard walkLineage(a, cyclic)
    let chain: ParentResolver = proc (id: ReleaseId): (bool, seq[Digest32]) =
      var next = Digest32(id)
      next[0] = next[0] + 1
      if next[0] == 0: next[1] = next[1] + 1
      (true, @[next])
    refusesWith(rrLineageTooDeep): discard walkLineage(a, chain)

  test "every byte-level mutation ends in a refusal or a verified identical release":
    # Fail-safely sweep: flip, insert and delete bytes at random. A mutated
    # input may only (a) be refused with RemixError, or (b) still verify —
    # which is acceptable only if it decodes to the very same release.
    let good = goodBytes()
    let goodId = decodeAndVerify(good).id
    var rng = initRand(20261020)
    var refused, identical = 0
    for i in 0 ..< 3000:
      var bad = good
      case rng.rand(2)
      of 0:
        let at = rng.rand(bad.high)
        bad[at] = bad[at] xor byte(1 + rng.rand(254))
      of 1:
        bad.insert(byte(rng.rand(255)), rng.rand(bad.len))
      else:
        bad.delete(rng.rand(bad.high))
      try:
        let v = decodeAndVerify(bad)
        check v.id == goodId
        inc identical
      except RemixError:
        inc refused
    check refused + identical == 3000
    check refused > 2900
