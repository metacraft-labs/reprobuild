## AWS Nitro Enclaves attestation: five genuine documents verify through
## this build's own primitives, and the surface is measured against what
## an attested ReproOS generation would need it to say.
##
## ## The question this gate answers
##
## A Nitro attestation document is a `COSE_Sign1` over a CBOR payload
## carrying sixteen platform configuration registers, three optional
## enclave-supplied fields and an X.509 chain to a root the vendor
## publishes. It is a real root of trust and a different one from the
## two confidential-computing surfaces this repository already reads. The
## question is not whether it is genuine — it is, and the first half of
## this gate proves it cryptographically — but whether its evidence can
## carry the two things an attested-image verdict is made of: *which
## ReproOS generation booted*, and *whose workload it is*.
##
## The measured answer is that it carries the second and cannot carry the
## first, and the second half of this gate pins each half of that.
##
## ## What binds, and it is more than nothing
##
## PCR4 is the parent instance's identifier, and it is REPRODUCED here
## rather than believed: `SHA-384(48 zero bytes ‖ instance-id)` returns
## each of the five documents' own PCR4, where the instance id is read
## out of the same document's `module_id`. The same construction returns
## the vendor's two published worked examples. A one-character change to
## the identifier does not reproduce it. So an instance identity is
## bound, by the platform, in a way a build can predict.
##
## The enclave-supplied `nonce`, `user_data` and `public_key` are signed
## by the platform. The vendor's specification gives their size limits
## twice and does not agree with itself — its CDDL says all three are
## `bytes .size (0..1024)`, its validation rules say 0..512 for the first
## two and 1..1024 for the third — but the sixty-four bytes of this
## repository's binding discipline fit under either reading with room to
## spare, so nothing here depends on which is right. Freshness and
## session binding are available.
##
## ## What does not bind, and why it is structural rather than missing
##
## An attested image is identified by three outputs — a unified kernel
## image digest, an integrity-protected root image digest, and that
## image's root hash — and every backend's expectation is a launch
## measurement *of that image*. No Nitro register is a measurement of any
## of them. PCR0, PCR1 and PCR2 measure an enclave image file: a kernel,
## a bootstrap ramdisk and an application ramdisk in the vendor's own
## container format. There is no firmware in it, no unified kernel image,
## and no block device for an integrity-protected root to sit on, so the
## artifact a generation *is* cannot be the artifact an enclave launches.
##
## That is asserted three ways below and one of them is empirical rather
## than architectural: PCR1 is byte-identical between two documents from
## unrelated publishers, in different regions, one day apart, whose PCR0
## and PCR2 both differ. A register that two strangers' workloads share
## is not carrying either workload's identity.
##
## The obvious substitute — put the generation in `user_data` — is
## refused by this repository's own binding discipline, which reserves
## those bytes for freshness and session binding and says configuration
## identity rides in the measurement. `OgUsEast2026` is the measured
## reason: a genuine, chain-valid, vendor-signed document whose
## `public_key` is the five ASCII bytes `dummy`. The platform signs
## whatever the enclave hands it, so those fields are authenticated
## statements BY the workload, never statements ABOUT it.
##
## So no `nitro` backend is admitted. The enum a manifest's expectations
## are written against would gain a member with no expectation it could
## ever be written against, which is a worse outcome than an absence: an
## absence is legible. The three cases in *What the evidence does not
## bind* keep that decision honest — they fail if a `nitro` member
## appears without a manifest key, and they fail if the image outputs a
## generation is identified by ever change shape.
##
## ## What a backend would have to clear first, measured not guessed
##
## Three facts about THIS build, each observed against all five genuine
## documents:
##
##   * the `COSE_Sign1` reader requires the CBOR tag, and no genuine
##     document carries one;
##   * it requires a `kid`, and no genuine document carries one — shown
##     with the CORRECT key supplied, so the refusal is the rule and not
##     a missing key;
##   * the X.509 reader admits `ecdsa-with-SHA256` only, and every
##     certificate in the vendor's chain, root included, is
##     `ecdsa-with-SHA384` over P-384.
##
## The CBOR layer, by contrast, has NO gap: all five messages and all
## five payloads decode. That is worth measuring rather than assuming,
## because the payload map's encoding CHANGED — the two 2026 documents
## use an indefinite-length map and the three older ones do not, so a
## reader written against the older shape alone would refuse current
## output from two unrelated publishers.
##
## ## What this gate does NOT establish, stated plainly
##
## Nothing here contacted AWS and no enclave was ever launched: every
## byte came from a published corpus. PCR3's construction is reproduced
## against the vendor's published worked example only — the one document
## here with a non-zero PCR3 does not publish the role it names, so the
## formula is not confirmed against a signed document the way PCR4's is.
## No certificate CHAIN is verified by this build, because this build
## cannot read these certificates at all; the chains were verified with
## OpenSSL 3.6.1 before the corpus was pinned and that is recorded beside
## the bytes, not asserted here. And PCR0 is not reproduced from any
## input: doing so needs an enclave image file, and an enclave image file
## is precisely the artifact this gate concludes a generation cannot be.
##
## ## Mocking
##
## None.

import std/[algorithm, sequtils, strutils, unittest]

import cbor
import nimcrypto/[hash, sha2]

import repro_attest/cose
import repro_attest/manifest
import repro_attest/report
import repro_attest_verify/x509

include ./nitro_vectors

# ---------------------------------------------------------------------
# Which refusals were reached
# ---------------------------------------------------------------------

var reachedCoseKinds: set[CoseErrorKind] = {}

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

proc bytesOfHex(h: string): seq[byte] =
  doAssert h.len mod 2 == 0
  result = newSeq[byte](h.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(h[2 * i .. 2 * i + 1]))

proc hexOfBytes(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii

proc sha256Hex(b: openArray[byte]): string =
  var ctx: sha256
  ctx.init()
  if b.len > 0: ctx.update(b)
  result = ($ctx.finish()).toLowerAscii
  ctx.clear()

proc sha384Hex(b: openArray[byte]): string =
  var ctx: sha384
  ctx.init()
  if b.len > 0: ctx.update(b)
  result = ($ctx.finish()).toLowerAscii
  ctx.clear()

proc pcrFromString(s: string): string =
  ## The register construction the vendor documents: forty-eight zero
  ## bytes, then the ASCII of the value, hashed with SHA-384.
  var buf = newSeq[byte](48)
  for c in s: buf.add byte(c)
  sha384Hex(buf)

proc flipBit(data: seq[byte]; offset, bit: int): seq[byte] =
  result = data
  result[offset] = result[offset] xor byte(1 shl bit)

proc bitsDiffering(a, b: openArray[byte]): int =
  doAssert a.len == b.len
  for i in 0 ..< a.len:
    var x = int(a[i] xor b[i])
    while x != 0:
      result += x and 1
      x = x shr 1

proc leafPointOf(der: openArray[byte]): seq[byte] =
  ## Walk to `SubjectPublicKeyInfo.subjectPublicKey` with THIS build's
  ## DER reader and return the uncompressed SEC 1 point. The certificate
  ## as a whole cannot be parsed by this build — that is one of the
  ## findings below — so the walk is explicit and bounded at every step
  ## by the enclosing structure's end, which is what `readTlv`'s `limit`
  ## parameter is for.
  var p = 0
  let cert = readTlv(der, p, "certificate", der.len)
  expectTag(cert, 0x30'u8, "certificate")
  var q = cert.contentStart
  let tbs = readTlv(der, q, "tbsCertificate", cert.fin)
  expectTag(tbs, 0x30'u8, "tbsCertificate")
  var r = tbs.contentStart
  let version = readTlv(der, r, "version", tbs.fin)
  expectTag(version, 0xa0'u8, "version")
  discard readTlv(der, r, "serialNumber", tbs.fin)
  discard readTlv(der, r, "signatureAlgorithm", tbs.fin)
  discard readTlv(der, r, "issuer", tbs.fin)
  discard readTlv(der, r, "validity", tbs.fin)
  discard readTlv(der, r, "subject", tbs.fin)
  let spki = readTlv(der, r, "subjectPublicKeyInfo", tbs.fin)
  expectTag(spki, 0x30'u8, "subjectPublicKeyInfo")
  var s = spki.contentStart
  discard readTlv(der, s, "subjectPublicKeyAlgorithm", spki.fin)
  let bits = readTlv(der, s, "subjectPublicKey", spki.fin)
  expectTag(bits, 0x03'u8, "subjectPublicKey")
  doAssert der[bits.contentStart] == 0'u8,
    "a public key BIT STRING with unused bits"
  slice(der, bits.contentStart + 1, bits.fin)

proc subjectOf(der: openArray[byte]): seq[byte] =
  ## The `subject` field's raw DER, reached by the same bounded walk.
  ## Separate from `leafPointOf` on purpose: a walk that returned two
  ## things would let one of them be right while the other silently came
  ## from the wrong TLV.
  var p = 0
  let cert = readTlv(der, p, "certificate", der.len)
  expectTag(cert, 0x30'u8, "certificate")
  var q = cert.contentStart
  let tbs = readTlv(der, q, "tbsCertificate", cert.fin)
  expectTag(tbs, 0x30'u8, "tbsCertificate")
  var r = tbs.contentStart
  discard readTlv(der, r, "version", tbs.fin)
  discard readTlv(der, r, "serialNumber", tbs.fin)
  discard readTlv(der, r, "signatureAlgorithm", tbs.fin)
  discard readTlv(der, r, "issuer", tbs.fin)
  discard readTlv(der, r, "validity", tbs.fin)
  let subject = readTlv(der, r, "subject", tbs.fin)
  expectTag(subject, 0x30'u8, "subject")
  slice(der, subject.contentStart, subject.fin)

# ---------------------------------------------------------------------
# The corpus, decoded once
# ---------------------------------------------------------------------

type
  NitroDoc = object
    label: string
    publisher: string
    raw: seq[byte]
    protectedBytes: seq[byte]
    unprotectedEntries: int
    payload: seq[byte]
    signature: seq[byte]
    moduleId: string
    instanceId: string
    digestName: string
    timestampMs: int64
    payloadKeys: seq[string]
    pcrs: seq[seq[byte]]
    leafDer: seq[byte]
    cabundle: seq[seq[byte]]
    userData: seq[byte]
    hasUserData: bool
    nonce: seq[byte]
    hasNonce: bool
    publicKey: seq[byte]
    hasPublicKey: bool
    pinnedLeafPointHex: string
    payloadIsDefiniteLength: bool
    loadError: string
      ## Non-empty when the payload could not be decoded at all. Carried
      ## as DATA rather than allowed to escape, because this corpus is
      ## built at module scope: an exception here would abort the gate
      ## before `unittest` ran a single case, and a case whose subject
      ## can only ever crash the process is a case no mutation can
      ## redden on its own. Measured — that is exactly what happened
      ## when the CBOR reader was made to refuse indefinite maps.

proc lookupText(m: CborItem; key: string): CborItem =
  for e in m.entries:
    if e.key.kind == ckText and e.key.text == key: return e.val
  nil

proc decodeDoc(label, publisher, docHex, pointHex: string): NitroDoc =
  result.label = label
  result.publisher = publisher
  result.raw = bytesOfHex(docHex)
  result.pinnedLeafPointHex = pointHex
  let top = decodeItem(result.raw)
  doAssert top.kind == ckArray and top.elems.len == 4
  result.protectedBytes = top.elems[0].bytes
  result.unprotectedEntries = top.elems[1].entries.len
  result.payload = top.elems[2].bytes
  result.signature = top.elems[3].bytes
  # `0xa9` is a definite-length map of nine entries; `0xbf` starts an
  # indefinite-length map. Read off the first byte rather than inferred,
  # and cross-checked below against the deterministic reader's refusal.
  result.payloadIsDefiniteLength = result.payload[0] == 0xa9'u8
  var p: CborItem
  try:
    p = decodeItem(result.payload)
  except CborError as e:
    result.loadError = e.msg
    return
  doAssert p.kind == ckMap
  for e in p.entries:
    doAssert e.key.kind == ckText
    result.payloadKeys.add e.key.text
  result.moduleId = p.lookupText("module_id").text
  let encAt = result.moduleId.find("-enc")
  doAssert encAt > 0
  result.instanceId = result.moduleId[0 ..< encAt]
  result.digestName = p.lookupText("digest").text
  result.timestampMs = asInt64(p.lookupText("timestamp"))
  let pcrMap = p.lookupText("pcrs")
  result.pcrs = newSeq[seq[byte]](pcrMap.entries.len)
  for e in pcrMap.entries:
    result.pcrs[int(asInt64(e.key))] = e.val.bytes
  result.leafDer = p.lookupText("certificate").bytes
  for c in p.lookupText("cabundle").elems:
    result.cabundle.add c.bytes
  let ud = p.lookupText("user_data")
  result.hasUserData = not ud.isNull
  if result.hasUserData: result.userData = ud.bytes
  let nn = p.lookupText("nonce")
  result.hasNonce = not nn.isNull
  if result.hasNonce: result.nonce = nn.bytes
  let pk = p.lookupText("public_key")
  result.hasPublicKey = not pk.isNull
  if result.hasPublicKey: result.publicKey = pk.bytes

let docs = @[
  decodeDoc("AwsSample2023", "aws-samples", AwsSample2023DocHex,
            AwsSample2023LeafPointHex),
  decodeDoc("ZkvEuWest2022", "zkVerify", ZkvEuWest2022DocHex,
            ZkvEuWest2022LeafPointHex),
  decodeDoc("ZkvEuWest2026", "zkVerify", ZkvEuWest2026DocHex,
            ZkvEuWest2026LeafPointHex),
  decodeDoc("OgUsEast2026", "OpenGradient", OgUsEast2026DocHex,
            OgUsEast2026LeafPointHex),
  decodeDoc("SyndUsEast2025", "SyndicateProtocol", SyndUsEast2025DocHex,
            SyndUsEast2025LeafPointHex)]

let rootDer = bytesOfHex(NitroRootG1DerHex)

proc keyOf(d: NitroDoc): CoseKey =
  CoseKey(curve: ccP384, point: leafPointOf(d.leafDer))

proc signatureVerifies(d: NitroDoc; payload: openArray[byte];
                       protectedBytes: openArray[byte];
                       key: CoseKey): bool =
  ecdsaSignatureIsValid(key, caEs384,
    sigStructureSign1(protectedBytes, [], payload), d.signature)

# ---------------------------------------------------------------------
# 1. The corpus is what it says it is
# ---------------------------------------------------------------------

suite "the pinned Nitro corpus":

  test "every pinned constant has its recorded length and digest":
    # Enumeration-indexed, so a constant dropped from the table is a
    # count that moved rather than a row nobody ran.
    let rows = @[
      ("AwsSample2023DocHex", bytesOfHex(AwsSample2023DocHex), 4396,
       "c9f773ce17c720028abc33639bb4ba3e61077164bbfa410510e4b545d7d1ebfe"),
      ("ZkvEuWest2022DocHex", bytesOfHex(ZkvEuWest2022DocHex), 4461,
       "8ff485d8a838b3cacf80d323ef4a1588d500032a61878833ac33f525685a351b"),
      ("ZkvEuWest2026DocHex", bytesOfHex(ZkvEuWest2026DocHex), 4617,
       "5be13c974c8c5e57a9823fc0883cb3ddcae76e59b7b07321e235c6685667b469"),
      ("OgUsEast2026DocHex", bytesOfHex(OgUsEast2026DocHex), 4556,
       "65ce3118757bd0428142776bc2d715ca0a785ac8b872fedf7edc1fbd9ad10070"),
      ("SyndUsEast2025DocHex", bytesOfHex(SyndUsEast2025DocHex), 4525,
       "7260686750e70234bdff518ff3ea77c5f58bdc18534afdcd65ab9916c1f8b531"),
      ("NitroRootG1DerHex", rootDer, 533,
       "641a0321a3e244efe456463195d606317ed7cdcc3c1756e09893f3c68f79bb5b")]
    check rows.len == 6
    for (name, bytes, wantLen, wantSha) in rows:
      check (name, bytes.len) == (name, wantLen)
      check (name, sha256Hex(bytes)) == (name, wantSha)

  test "the corpus is spread, not five copies of one shape":
    check docs.len == 5
    # Four distinct publishers of documents, one of them twice.
    # `SyndicateProtocol` also redistributes one document byte-for-byte
    # from `aws-samples`; that copy is deliberately not pinned, and this
    # count would notice if it came back and were counted again.
    var publishers: seq[string] = @[]
    for d in docs:
      if d.publisher notin publishers: publishers.add d.publisher
    check publishers.len == 4

    # No two documents are the same bytes, the same enclave or the same
    # instant.
    var raws, modules: seq[string] = @[]
    var stamps: seq[int64] = @[]
    for d in docs:
      raws.add hexOfBytes(d.raw)
      modules.add d.moduleId
      stamps.add d.timestampMs
    check raws.deduplicate().len == 5
    check modules.deduplicate().len == 5
    check stamps.deduplicate().len == 5

    # Four calendar years, so nothing here is one afternoon's output.
    var years: seq[int] = @[]
    for d in docs:
      let y = 1970 + int(d.timestampMs div 1000 div 31_557_600)
      if y notin years: years.add y
    check years.len == 4

    # Each optional field is present somewhere and absent somewhere, so
    # a reader that always answers "absent" and one that always answers
    # "present" both fail.
    check docs.countIt(it.hasUserData) == 3
    check docs.countIt(it.hasNonce) == 2
    check docs.countIt(it.hasPublicKey) == 3

    # Exactly one document is the vendor's own debug-mode sample, and it
    # is the degenerate one. Keeping it is the point; letting it be the
    # only one would be the mistake.
    check docs.countIt(it.pcrs[0].allIt(it == 0'u8)) == 1

    # Both payload encodings are present, so neither arm is untested.
    check docs.countIt(it.payloadIsDefiniteLength) == 3
    check docs.countIt(not it.payloadIsDefiniteLength) == 2

# ---------------------------------------------------------------------
# 2. Five genuine documents, verified by this build
# ---------------------------------------------------------------------

suite "the documents are genuine, and this build can say so":

  test "each is an untagged COSE_Sign1 with an ES384 protected bucket":
    for d in docs:
      # `a1013822` is `{1: -35}`: the algorithm label carrying ES384, and
      # nothing else. Pinned as the literal bytes because the bytes are
      # what the Sig_structure covers.
      check (d.label, hexOfBytes(d.protectedBytes)) == (d.label, "a1013822")
      check (d.label, d.unprotectedEntries) == (d.label, 0)
      check (d.label, d.raw[0]) == (d.label, 0x84'u8)
      check (d.label, d.signature.len) == (d.label, 96)
      check (d.label, d.digestName) == (d.label, "SHA384")

  test "this build's DER reader finds the key OpenSSL found":
    # Two transcriptions of one field. This catches a walk that lands on
    # the wrong TLV; it does not catch two readers wrong the same way,
    # and the corpus header says so.
    for d in docs:
      let point = leafPointOf(d.leafDer)
      check (d.label, point.len) == (d.label, 97)
      check (d.label, point[0]) == (d.label, 0x04'u8)
      check (d.label, hexOfBytes(point)) ==
        (d.label, d.pinnedLeafPointHex)

  test "every ES384 signature verifies through this build's own primitives":
    # The Sig_structure is built by this repository's `sigStructureSign1`
    # and the curve arithmetic is its own BearSSL path. A signature that
    # verifies is a statement about every signed byte at once: the
    # sixteen registers, the certificate, the whole chain bundle and the
    # three enclave-supplied fields.
    for d in docs:
      check (d.label, signatureVerifies(d, d.payload, d.protectedBytes,
                                        d.keyOf())) == (d.label, true)

  test "a single flipped bit anywhere in the payload breaks the signature":
    var mutations = 0
    for d in docs:
      for offset in [0, d.payload.len div 4, d.payload.len div 2,
                     (3 * d.payload.len) div 4, d.payload.len - 1]:
        let bad = flipBit(d.payload, offset, 0)
        check bitsDiffering(d.payload, bad) == 1
        check (d.label, offset,
               signatureVerifies(d, bad, d.protectedBytes, d.keyOf())) ==
          (d.label, offset, false)
        inc mutations
    check mutations == 25

  test "a flipped bit in the protected bucket breaks the signature":
    # The bucket is four bytes and it is the one part of the message a
    # verifier is most tempted to re-encode instead of using as it
    # arrived. Every bit of it is swept.
    var mutations = 0
    for d in docs:
      for offset in 0 ..< d.protectedBytes.len:
        for bit in 0 .. 7:
          let bad = flipBit(d.protectedBytes, offset, bit)
          check (d.label, offset, bit,
                 signatureVerifies(d, d.payload, bad, d.keyOf())) ==
            (d.label, offset, bit, false)
          inc mutations
    check mutations == 160

  test "no document verifies under another document's key":
    # Twenty ordered pairs of REAL keys. A verifier that ignored the key
    # it was handed, or one that read the key out of the document it was
    # checking rather than out of the one it was given, passes the
    # positive case above and fails here.
    var pairs = 0
    for i, d in docs:
      for j, other in docs:
        if i == j: continue
        check (d.label, other.label,
               signatureVerifies(d, d.payload, d.protectedBytes,
                                 other.keyOf())) ==
          (d.label, other.label, false)
        inc pairs
    check pairs == 20

  test "every document carries the published vendor root as cabundle[0]":
    for d in docs:
      check (d.label, d.cabundle.len) == (d.label, 4)
      check (d.label, hexOfBytes(d.cabundle[0])) ==
        (d.label, hexOfBytes(rootDer))
      # And the leaf is not the root wearing a different name.
      check (d.label, hexOfBytes(d.leafDer) == hexOfBytes(rootDer)) ==
        (d.label, false)

# ---------------------------------------------------------------------
# 3. What the evidence binds
# ---------------------------------------------------------------------

suite "what a Nitro document does bind":

  test "PCR4 is the parent instance's identifier, reproduced on all five":
    for d in docs:
      check (d.label, hexOfBytes(d.pcrs[4])) ==
        (d.label, pcrFromString(d.instanceId))
      # Not a constant, and not zero: five instances, five values.
      check (d.label, d.pcrs[4].allIt(it == 0'u8)) == (d.label, false)
    var values: seq[string] = @[]
    for d in docs: values.add hexOfBytes(d.pcrs[4])
    check values.deduplicate().len == 5

  test "a one-character change to the identifier does not reproduce PCR4":
    for d in docs:
      var mutated = d.instanceId
      mutated[^1] = (if mutated[^1] == '0': '1' else: '0')
      check (d.label, mutated == d.instanceId) == (d.label, false)
      check (d.label, pcrFromString(mutated) == hexOfBytes(d.pcrs[4])) ==
        (d.label, false)

  test "the vendor's own published register examples reproduce":
    # Numbers the vendor computed and printed, independent of any
    # document here. They pin the construction itself, so a formula that
    # happened to agree with five documents for some other reason would
    # still have to agree with these.
    check pcrFromString(AwsDocumentedPcr4Input) == AwsDocumentedPcr4Output
    check pcrFromString(AwsDocumentedPcr3Input) == AwsDocumentedPcr3Output
    # And they are genuinely different inputs producing different
    # outputs, so neither is satisfied by a constant.
    check AwsDocumentedPcr4Output != AwsDocumentedPcr3Output

  test "the register that is not the workload's is shared by strangers":
    # Two documents, two unrelated publishers, two regions, one day
    # apart. Their PCR1 is the same forty-eight bytes and their PCR0 and
    # PCR2 both differ. Architecture says PCR1 measures the vendor's
    # kernel and bootstrap ramdisk; this is the measurement that says so.
    let a = docs[2]   # zkVerify, eu-west-1, 2026-02-13
    let b = docs[3]   # OpenGradient, us-east-2, 2026-02-12
    check a.publisher != b.publisher
    check a.instanceId != b.instanceId
    check hexOfBytes(a.pcrs[1]) == hexOfBytes(b.pcrs[1])
    check a.pcrs[1].allIt(it == 0'u8) == false
    check hexOfBytes(a.pcrs[0]) != hexOfBytes(b.pcrs[0])
    check hexOfBytes(a.pcrs[2]) != hexOfBytes(b.pcrs[2])

  test "debug mode zeroes the image registers and leaves the host's":
    # The vendor's documentation says a debug enclave's registers are
    # "made up entirely of zeroes". Its own sample document says
    # otherwise, and the difference is the useful part: what a policy has
    # to key on to catch a debug enclave is PCR0-2, because PCR3 and PCR4
    # are facts about the parent instance and survive.
    let d = docs[0]
    check d.label == "AwsSample2023"
    for i in [0, 1, 2]:
      check (i, d.pcrs[i].allIt(it == 0'u8)) == (i, true)
    for i in [3, 4]:
      check (i, d.pcrs[i].allIt(it == 0'u8)) == (i, false)
    # Its PCR4 still reproduces from the instance id, so the register is
    # live rather than left over.
    check hexOfBytes(d.pcrs[4]) == pcrFromString(d.instanceId)
    # And every other document has non-zero image registers, so "all
    # zero" is not simply what this corpus looks like.
    for other in docs[1 .. ^1]:
      check (other.label, other.pcrs[0].allIt(it == 0'u8)) ==
        (other.label, false)

  test "sixteen registers arrive and five of them ever carry anything":
    for d in docs:
      check (d.label, d.pcrs.len) == (d.label, 16)
      for i, p in d.pcrs:
        check (d.label, i, p.len) == (d.label, i, 48)
    # Union over the whole corpus: only 0, 1, 2, 3 and 4 are ever
    # non-zero, and 5 through 15 never are. A backend that read PCR8 —
    # the register the vendor documents for a signed enclave image —
    # would have no input here, and this says so rather than leaving it
    # to be discovered.
    var everNonZero: seq[int] = @[]
    for d in docs:
      for i, p in d.pcrs:
        if not p.allIt(it == 0'u8) and i notin everNonZero:
          everNonZero.add i
    everNonZero.sort()
    check everNonZero == @[0, 1, 2, 3, 4]

  test "the parent instance and its region are bound a second time":
    # PCR4's preimage is not the only place the platform names the parent
    # instance. The leaf certificate's subject is
    # `<module_id>.<region>.aws`, and the whole certificate sits inside
    # what the signature covers, so the identifier PCR4 is computed from
    # is corroborated by a second signed field rather than resting on the
    # payload alone. The region is pinned per document, which is also
    # what makes the corpus's "two regions" a checked fact instead of a
    # line in a table nothing reads.
    let regions = @["eu-west-1", "eu-west-1", "eu-west-1",
                    "us-east-2", "us-east-2"]
    check regions.len == docs.len
    var seen: seq[string] = @[]
    for i, d in docs:
      let subject = cast[string](subjectOf(d.leafDer))
      # The WHOLE common name, not the module id on its own: the
      # instance id is a prefix of the module id, so a check that asked
      # only for a substring would be satisfied by the weaker of the
      # two. Measured — that mutation came back green before this line
      # was written this way.
      check (d.label, (d.moduleId & "." & regions[i] & ".aws") in
             subject) == (d.label, true)
      if regions[i] notin seen: seen.add regions[i]
      # The other region never appears, so the match is the document's
      # own and not a substring both spellings satisfy.
      let other = (if regions[i] == "eu-west-1": "us-east-2"
                   else: "eu-west-1")
      check (d.label, other in subject) == (d.label, false)
    check seen.len == 2
    # The certificate carries the platform's facts about the parent, and
    # none of the enclave's statements about itself.
    for d in docs:
      if not d.hasPublicKey: continue
      let subject = cast[string](subjectOf(d.leafDer))
      check (d.label, cast[string](d.publicKey) in subject) ==
        (d.label, false)

  test "the enclave-supplied fields are pass-through, not measured":
    # A genuine, vendor-signed, chain-valid document whose public key is
    # the five ASCII bytes `dummy` and whose nonce is a counting pattern.
    # The platform signs what the enclave hands it, so these fields are
    # statements BY the workload and never statements ABOUT it.
    let d = docs[3]
    check d.label == "OgUsEast2026"
    check d.hasPublicKey
    check cast[string](d.publicKey) == "dummy"
    check d.hasNonce
    check hexOfBytes(d.nonce) == "0123456789abcdef0123456789abcdef01234567"
    # It is genuine: the same document verifies above, and its signature
    # covers these exact bytes — flip one and it stops.
    check signatureVerifies(d, d.payload, d.protectedBytes, d.keyOf())
    # None of the five registers that carry anything equals either
    # field, so no measurement echoes them.
    for i in [0, 1, 2, 3, 4]:
      check (i, hexOfBytes(d.pcrs[i]) == hexOfBytes(d.publicKey)) ==
        (i, false)
      check (i, hexOfBytes(d.pcrs[i]) == hexOfBytes(d.nonce)) == (i, false)
    # The vendor's specification comments this field as "an optional
    # DER-encoded key". Not one of the three documents that populate it
    # carries DER, which would open with `0x30`: two are raw uncompressed
    # SEC 1 points at P-256 and P-521 widths and one is the ASCII above.
    # A field whose own specification is wrong about its encoding is not
    # a field a verifier can derive identity from.
    var populated = 0
    for other in docs:
      if not other.hasPublicKey: continue
      inc populated
      check (other.label, other.publicKey.len) ==
        (other.label, [133, 5, 65][populated - 1])
      check (other.label, other.publicKey[0] == 0x30'u8) ==
        (other.label, false)
    check populated == 3

# ---------------------------------------------------------------------
# 4. What the evidence does not bind
# ---------------------------------------------------------------------

suite "what a Nitro document does not bind":

  test "a generation is three image outputs and no register is one":
    # The three field names are asserted rather than described, so that
    # adding a fourth output — or renaming one — reddens this case and
    # whoever does it has to re-decide whether the conclusion still
    # holds.
    var probe: ImageOutputs
    var names: seq[string] = @[]
    for name, _ in probe.fieldPairs: names.add name
    check names == @["uki", "verityImage", "verityRootHash"]
    # A Nitro payload's key set is closed and none of those names is in
    # it, in any of the five.
    for d in docs:
      var keys = d.payloadKeys
      keys.sort()
      check (d.label, keys) == (d.label, @["cabundle", "certificate",
        "digest", "module_id", "nonce", "pcrs", "public_key", "timestamp",
        "user_data"])
      for n in names:
        check (d.label, n, n in d.payloadKeys) == (d.label, n, false)

  test "this build admits four backends and none of them is nitro":
    var known: seq[string] = @[]
    for b in AttestationBackend: known.add $b
    check known == @["sev-snp", "tdx", "tpm2", "mock"]
    check "nitro" notin known
    var raised = false
    try:
      discard parseBackend("report.backend", "nitro")
    except ReportError as e:
      raised = true
      # The full list, so the refusal cannot be satisfied by a different
      # rule that happens to mention one backend.
      check "sev-snp, tdx, tpm2, mock" in e.msg
      check "refuses one it cannot honour" in e.msg
    check raised

  test "the manifest knows three launch shapes and none of them is nitro":
    check KnownBackends.len == 3
    check @KnownBackends == @["sev-snp", "tdx", "tpm"]
    check "nitro" notin @KnownBackends
    # `manifestBackendKey` is total over the backend enum, and the only
    # member with no key is the one that takes no launch measurement. A
    # backend added without a manifest key would land in the empty
    # branch and move this count.
    var withKey, withoutKey: seq[string] = @[]
    for b in AttestationBackend:
      if manifestBackendKey(b).len == 0: withoutKey.add $b
      else: withKey.add $b
    check withKey == @["sev-snp", "tdx", "tpm2"]
    check withoutKey == @["mock"]

  test "the confidential tier is exactly two backends":
    # A partition over the tier enum, so a backend added without a tier
    # decision cannot pass quietly.
    var seen: seq[AttestationBackend] = @[]
    for t in AttestationTier:
      for b in backendsOfTier(t):
        check b notin seen
        seen.add b
        check tierOf(b) == t
    # Every member of the enum is placed by exactly one tier, so a
    # backend added without a tier decision cannot sit outside the
    # partition and go unnoticed.
    for b in AttestationBackend:
      check ($b, b in seen) == ($b, true)
    check seen.len == 4
    check backendsOfTier(atCvm) == @[abSevSnp, abTdx]

# ---------------------------------------------------------------------
# 5. What a backend would have to clear first
# ---------------------------------------------------------------------

suite "what this build would have to change to read one":

  test "the COSE reader requires the tag, and no document carries one":
    for d in docs:
      var raised = false
      try:
        discard verifyCoseSign1(d.raw, [d.keyOf()])
      except CoseError as e:
        raised = true
        reachedCoseKinds.incl e.kind
        check (d.label, e.kind) == (d.label, cxeNotTagged)
        for other in CoseErrorKind:
          if other == cxeNotTagged: continue
          check (d.label, $other, CoseErrorMessage[other] in e.msg) ==
            (d.label, $other, false)
      check (d.label, raised) == (d.label, true)

  test "the COSE reader requires a kid, with the right key in hand":
    # The key supplied here is the document's OWN leaf key, the one that
    # verifies its signature three cases up. So this refusal is the kid
    # rule and not a key the verifier could not find.
    for d in docs:
      var raised = false
      try:
        discard verifyCoseSign1(d.raw, [d.keyOf()], requireTag = false)
      except CoseError as e:
        raised = true
        reachedCoseKinds.incl e.kind
        check (d.label, e.kind) == (d.label, cxeNoKeyIdentifier)
        for other in CoseErrorKind:
          if other == cxeNoKeyIdentifier: continue
          check (d.label, $other, CoseErrorMessage[other] in e.msg) ==
            (d.label, $other, false)
      check (d.label, raised) == (d.label, true)

  test "the X.509 reader admits one signature algorithm and it is not theirs":
    var certs = @[("root", rootDer)]
    for d in docs: certs.add (d.label & " leaf", d.leafDer)
    check certs.len == 6
    for (name, der) in certs:
      var raised = false
      try:
        discard parseCertificate(der)
      except X509Error as e:
        raised = true
        # Both OIDs, so the message cannot be confused with any other
        # refusal this reader produces.
        check (name, "1.2.840.10045.4.3.3" in e.msg) == (name, true)
        check (name, "1.2.840.10045.4.3.2" in e.msg) == (name, true)
      check (name, raised) == (name, true)

  test "the CBOR reader has no gap: every message and payload decodes":
    for d in docs:
      check (d.label, d.loadError) == (d.label, "")
    for d in docs:
      let top = decodeItem(d.raw)
      check (d.label, top.kind) == (d.label, ckArray)
      check (d.label, top.elems.len) == (d.label, 4)
      let p = decodeItem(d.payload)
      check (d.label, p.kind) == (d.label, ckMap)
      check (d.label, p.entries.len) == (d.label, 9)

  test "the payload map is never deterministic, and since 2026 not definite":
    # Two different reasons, and which one applies is what dates the
    # change. A reader that handled only definite lengths would refuse
    # current output from two unrelated publishers, so this partition is
    # the warning and not a curiosity.
    var indefinite, outOfOrder: seq[string] = @[]
    for d in docs:
      var raised = false
      try:
        discard decodeItem(d.payload, DeterministicCborOptions)
      except CborError as e:
        raised = true
        case e.kind
        of cekIndefiniteNotDeterministic: indefinite.add d.label
        of cekMapKeysOutOfOrder: outOfOrder.add d.label
        else: check (d.label, $e.kind) == (d.label, "an expected refusal")
      check (d.label, raised) == (d.label, true)
    check indefinite == @["ZkvEuWest2026", "OgUsEast2026"]
    check outOfOrder ==
      @["AwsSample2023", "ZkvEuWest2022", "SyndUsEast2025"]
    # And the two arms agree with the first byte read off the wire.
    for d in docs:
      check (d.label, d.payloadIsDefiniteLength) ==
        (d.label, d.label in outOfOrder)
    # The MESSAGE, by contrast, is deterministically encoded in all
    # five: only the payload moved.
    for d in docs:
      discard decodeItem(d.raw, DeterministicCborOptions)

  test "every refusal this gate names was reached":
    check reachedCoseKinds == {cxeNotTagged, cxeNoKeyIdentifier}
