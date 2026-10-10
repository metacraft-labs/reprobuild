## Confidential-computing evidence emulators: production-format
## security-processor reports and trust-domain quotes, carrying
## measurements this build's own calculators computed over real images,
## signed by keys no vendor root certifies.
##
## Named without a ``t_`` / ``test_`` prefix so the test-edge generator
## does not discover it as a test in its own right — the convention
## ``evidence_emulator.nim`` and ``software_root_test_pki.nim`` follow.
##
## ## What this is, and what half of it is real
##
## Two subclasses of the backend driver seam. Each is handed 64 bytes
## and returns the vendor's own wire format — a 1,184-byte
## security-processor attestation report, or a version-4 trust-domain
## attestation quote — assembled byte by byte against the offsets this
## repository's readers parse, and read back by those readers on the way
## in.
##
## **The measurement half is real and the signature half is not.** A
## driver is handed the launch measurement at construction; it does not
## invent one. Its callers compute it with ``snp_launch`` and
## ``tdx_launch`` — the same calculators that reproduce a real
## operator's signed ``MEASUREMENT`` and two unrelated operators'
## genuine ``MRTD``s — over firmware those operators publish. What is
## emulated is the part of the document that says *who* produced it: the
## signature, and the certificates behind it.
##
## So what a gate built on this can establish is that the readers, the
## calculators and the measurement manifest agree about a value, end to
## end, through the real protocol. What it cannot establish is that a
## host produces the value the calculator predicts. Nothing here is
## evidence about a host; see the ledger entry, which states that limit
## rather than leaving it to be inferred.
##
## ## Why it is not a verifier bypass, and why that is a stronger
## ## statement here than for the measured-boot emulator
##
## The measured-boot emulator's companion gate has to argue that an
## accepting evaluator exists only in a build compiled with a define.
## The confidential-computing tiers need no such argument, because
## **this build has no accepting evaluator for them at all**:
##
##   * ``evaluateAmdChain`` reaches exactly the three root keys in a
##     ``const`` array indexed by a three-valued enum, and
##     ``evaluateIntelPckChain`` exactly the one in its own. Neither
##     takes an anchor, a policy or an allowance; both are pinned to
##     their own parameter list by a ``static`` assertion.
##   * Neither module contains a ``when defined(...)`` at all, so there
##     is no build of this repository in which either reaches a
##     different root. A gate asserts that by reading their source.
##   * Every certificate minted here carries the same *critical*
##     extension under the ``2.999`` arc the measured-boot hierarchy
##     uses, which RFC 5280 §4.2 requires a conforming evaluator to
##     refuse — and both vendor evaluators recognise two critical
##     extensions, neither of them that one.
##
## The second and third are independent: strip the marker and the chain
## is still refused, as ``acRootIsNotAmd`` / ``tcRootIsNotIntel``, and a
## gate shows both refusals on the same hierarchy minted twice. That is
## why ``mintSnpTestHierarchy`` and ``mintIntelTestHierarchy`` DO take a
## ``marked`` argument where ``mintHierarchy``'s emulator deliberately
## does not: for the measured-boot tier an unmarked test hierarchy is
## ACCEPTED, so the argument would be the bypass; here it is refused
## either way, and offering it is how the second refusal gets an input.
##
## The drivers themselves still take none. ``newEmulatedSnpDriver`` and
## ``newEmulatedTdxDriver`` mint marked hierarchies through a ``const``,
## so "emulated evidence with no marker on it" is not a state a driver
## has.
##
## ## The scenario is taken at construction, never from a request
##
## ``QuoteRequest`` carries the 64 bytes and nothing else, and neither
## driver widens it. Measurement, platform version, registers and the
## injected fault are all fixed when the driver is built. An emulator a
## remote caller could steer would be a verifier bypass wearing a
## driver's clothes.
##
## ## Cost
##
## An AMD chain's two upper certificates are RSA-4096, because the
## evaluator refuses any other key type at those positions *before* it
## looks at the root — so a test chain carrying P-256 keys there would
## be refused as the wrong shape, which says nothing about whether the
## root is the vendor's. Generating two 4096-bit keys costs seconds, so
## the hierarchy is minted once per process and handed to every driver
## that asks for one. The Intel side is P-256 throughout and costs
## nothing.
##
## ## Mocking
##
## None. Real ECDSA P-384 and P-256 signatures, real RSASSA-PSS over
## SHA-384, real DER, real PEM, and the vendors' own byte layouts. Every
## key is drawn from the operating system's random source per process
## and written nowhere.

import std/[base64, options, strutils]

import repro_attest
import repro_attest/snp_launch
import repro_attest_verify
import repro_attest_verify/tdx_chain
import repro_attest_verify/tdx_quote

import ./software_root_test_pki

const
  SnpEmulatorDriverName* = "software-root security-processor emulator"
  TdxEmulatorDriverName* = "software-root trust-domain emulator"

  EmulatedCvmHierarchyIsMarked* = true
    ## Every certificate a DRIVER's hierarchy issues carries the
    ## RFC 5280 §4.2 marker. A ``const`` rather than a parameter: the
    ## two constructors have no argument that could set it and neither
    ## scenario has a field for it, so there is exactly one place this
    ## is decided and it is decided at compile time.

  Day = 86_400'i64

type
  CvmEmulatorMutation* = enum
    ## One structured fault per value. ``cemNone`` is the unmutated
    ## instance; every other value must add at least one failing check
    ## to what the unmutated one already fails.
    cemNone = "none"
    cemMeasurement = "measurement"
    cemSignature = "signature"
    cemNonce = "nonce"
    cemTcb = "tcb"
    cemChain = "chain"
    cemPolicy = "policy"
    cemTranscript = "transcript"
    cemTime = "time"
    cemReplay = "replay"

  CvmFaultSite* = enum
    ## Where a fault is injected. Not a label: it is what stops a fault
    ## being claimed as "the driver produces it" when the driver cannot.
    cfsEvidence
      ## Injected by a driver, into the bytes it returns.
    cfsVerification
      ## Injected by whoever assembles the verification.

proc cvmFaultSite*(m: CvmEmulatorMutation): CvmFaultSite =
  ## A total function over the enum, with no ``else``. A fault added
  ## without a decision about where it is injected does not compile.
  case m
  of cemNone: cfsEvidence
  of cemMeasurement: cfsEvidence
  of cemSignature: cfsEvidence
  of cemNonce: cfsEvidence
  of cemTcb: cfsEvidence
  of cemChain: cfsEvidence
  of cemPolicy: cfsVerification
  of cemTranscript: cfsVerification
  of cemTime: cfsVerification
  of cemReplay: cfsVerification

# ---------------------------------------------------------------------
# Little helpers the two wire formats share
# ---------------------------------------------------------------------

proc cvmPutLe*(buf: var seq[byte]; at: int; value: uint64; width: int) =
  for i in 0 ..< width:
    buf[at + i] = byte((value shr (8 * i)) and 0xff'u64)

proc cvmPutBytes*(buf: var seq[byte]; at: int; src: openArray[byte]) =
  for i in 0 ..< src.len: buf[at + i] = src[i]

proc cvmRawOf*(hex: string): seq[byte] =
  doAssert hex.len mod 2 == 0, "a hex string has an even length"
  result = newSeq[byte](hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))

proc cvmHexOf*(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii

proc cvmStringOf*(b: openArray[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

proc cvmBytesOf*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len: result[i] = byte(s[i])

proc cvmPemOf*(der: string): string =
  ## One certificate, in the wrapping a trust-domain quote carries its
  ## endorsement chain in.
  result = "-----BEGIN CERTIFICATE-----\n"
  let body = base64.encode(der)
  var i = 0
  while i < body.len:
    let stop = min(i + 64, body.len)
    result.add body[i ..< stop] & "\n"
    i = stop
  result.add "-----END CERTIFICATE-----\n"

# =====================================================================
# The security-processor side
# =====================================================================

const
  SnpTestArkCn* = "software-root test ARK"
  SnpTestAskCn* = "software-root test SEV-Milan"
  SnpTestVcekCn* = VcekCommonName
    ## The leaf HAS to be called this: the evaluator refuses a leaf that
    ## is not one of the two endorsement-key names, and a chain refused
    ## for the wrong reason proves nothing about the right one.

  SnpTestProductName* = "Milan-B0"
  SnpTestStructVersion* = 0

  SnpTestBootloaderSpl* = 3
  SnpTestTeeSpl* = 0
  SnpTestSnpSpl* = 22
  SnpTestUcodeSpl* = 213
    ## A platform version the vendor actually ships, so a policy floor
    ## written against a plausible number has something plausible to
    ## compare with. Below-floor is the ``cemTcb`` fault's business.

  SnpTestGuestPolicy* = 0x0003_0000'u64
  SnpTestVmpl* = 0'u32
  SnpTestVersion* = 2'u32

type
  SnpTestHierarchy* = object
    ## An AMD-shaped endorsement chain whose root is not AMD's.
    marked*: bool
    arkKey*, askKey*: TestRsaKey
    vcekKey*: TestP384Key
    arkDer*, askDer*, vcekDer*: string
    arkName*, askName*: seq[byte]
    askSerial*: seq[byte]
    crlDer*: string
    now*: int64

proc pssAlgBlock(): seq[byte] =
  ## The certificate spelling of the RSASSA-PSS/SHA-384 identifier, as
  ## the profile reader admits it — taken from the reader's own pinned
  ## pair rather than re-encoded here, so a chain this module mints and
  ## a chain that module reads cannot come to disagree about which of
  ## the two spellings is which.
  admittedPssAlgorithmIdentifiers()[0]

proc pssCrlAlgBlock(): seq[byte] =
  ## The revocation-list spelling: the same parameters with
  ## ``trailerField`` omitted, which is what the vendor's own lists
  ## carry.
  admittedPssAlgorithmIdentifiers()[1]

proc amdIntExt(oid: string; value: int): seq[byte] =
  ## One of the vendor's platform-version components: a DER INTEGER
  ## nested inside the extension's OCTET STRING.
  extension(oid, false, derSmallInt(value))

proc amdStringExt(oid: string; value: string): seq[byte] =
  extension(oid, false, derIa5(value))

proc amdRawExt(oid: string; value: openArray[byte]): seq[byte] =
  ## The chip-identity extension, whose content is the 64 bytes
  ## themselves with no nested DER value — measured on a real
  ## endorsement certificate and recorded in the reader beside it.
  var v: seq[byte] = @[]
  for b in value: v.add b
  extension(oid, false, v)

proc mintAmdCert(subjectSpki: seq[byte]; subjectCn: string;
                 issuerName: seq[byte]; issuerKey: var TestRsaKey;
                 serial: seq[byte]; notBefore, notAfter: int64;
                 extensions: seq[seq[byte]]):
                tuple[der: string, subjectName: seq[byte]] =
  ## One certificate of AMD's profile, signed by an RSA-4096 issuer.
  let subject = nameWithCn(subjectCn)
  let issuer = (if issuerName.len == 0: subject else: issuerName)
  var extBytes: seq[byte] = @[]
  for e in extensions:
    for b in e: extBytes.add b
  let tbs = derSeq(
    tlv(0xa0'u8, derSmallInt(2)),
    derInteger(serial),
    pssAlgBlock(),
    issuer,
    derSeq(derUtcTime(notBefore), derUtcTime(notAfter)),
    subject,
    subjectSpki,
    tlv(0xa3'u8, tlv(0x30'u8, extBytes)))
  let sig = signRsaPssSha384(issuerKey, tbs)
  let der = derSeq(tbs, pssAlgBlock(), derBitString(sig))
  (der: cvmStringOf(der), subjectName: subject)

proc mintAmdCrl(issuerKey: var TestRsaKey; issuerName: seq[byte];
                thisUpdate, nextUpdate: int64;
                revokedSerials: openArray[seq[byte]]): string =
  var entries: seq[byte] = @[]
  for serial in revokedSerials:
    for b in derSeq(derInteger(serial), derUtcTime(thisUpdate)):
      entries.add b
  var parts: seq[seq[byte]] = @[
    derSmallInt(1), pssCrlAlgBlock(), issuerName,
    derUtcTime(thisUpdate), derUtcTime(nextUpdate)]
  if revokedSerials.len > 0:
    parts.add tlv(0x30'u8, entries)
  var body: seq[byte] = @[]
  for p in parts:
    for b in p: body.add b
  let tbs = tlv(0x30'u8, body)
  let sig = signRsaPssSha384(issuerKey, tbs)
  cvmStringOf(derSeq(tbs, pssCrlAlgBlock(), derBitString(sig)))

proc mintSnpTestHierarchy*(now: int64; marked: bool;
                           chipId: seq[byte] = @[]): SnpTestHierarchy =
  ## A root, a signing authority and an endorsement key, in AMD's own
  ## profile and algorithms.
  ##
  ## ``marked`` exists because the two refusals it tells apart are
  ## independent — see this module's header. A driver never calls this
  ## with ``false``.
  result.marked = marked
  result.now = now
  result.arkKey = newTestRsa4096Key()
  result.askKey = newTestRsa4096Key()
  result.vcekKey = newTestP384Key()

  var marker: seq[seq[byte]] = @[]
  if marked: marker.add markerExt()

  let arkSerial = randomSerial()
  let minted = mintAmdCert(spkiOfRsa(result.arkKey), SnpTestArkCn, @[],
    result.arkKey, arkSerial, now - 30 * Day, now + 3650 * Day,
    @[basicConstraintsExt(true), keyUsageExt(@[5, 6])] & marker)
  result.arkDer = minted.der
  result.arkName = minted.subjectName

  result.askSerial = randomSerial()
  let askMinted = mintAmdCert(spkiOfRsa(result.askKey), SnpTestAskCn,
    result.arkName, result.arkKey, result.askSerial,
    now - 20 * Day, now + 1825 * Day,
    @[basicConstraintsExt(true), keyUsageExt(@[5, 6])] & marker)
  result.askDer = askMinted.der
  result.askName = askMinted.subjectName

  var identity = chipId
  if identity.len == 0:
    identity = newSeq[byte](HwIdLen)
    let seed = cvmRawOf(sha256Hex("software-root test part identity"))
    for i in 0 ..< HwIdLen: identity[i] = seed[i mod seed.len]
  doAssert identity.len == HwIdLen

  let vcekMinted = mintAmdCert(spkiOfP384(result.vcekKey), SnpTestVcekCn,
    result.askName, result.askKey, randomSerial(),
    now - Day, now + 365 * Day,
    @[basicConstraintsExt(false), keyUsageExt(@[0]),
      amdIntExt(OidAmdStructVersion, SnpTestStructVersion),
      amdStringExt(OidAmdProductName, SnpTestProductName),
      amdIntExt(OidAmdBlSpl, SnpTestBootloaderSpl),
      amdIntExt(OidAmdTeeSpl, SnpTestTeeSpl),
      amdIntExt(OidAmdSnpSpl, SnpTestSnpSpl),
      amdIntExt(OidAmdUcodeSpl, SnpTestUcodeSpl),
      amdRawExt(OidAmdHwId, identity)] & marker)
  result.vcekDer = vcekMinted.der

  result.crlDer = mintAmdCrl(result.arkKey, result.arkName,
    now - Day, now + 30 * Day, [])

proc snpChain*(h: SnpTestHierarchy): seq[string] =
  ## Leaf first, as a report bundles it.
  @[h.vcekDer, h.askDer, h.arkDer]

# ---------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------

type
  SnpReportFields* = object
    ## Everything a composed report carries that a caller decides.
    measurement*: seq[byte]       ## 48 bytes — the calculator's answer.
    reportData*: seq[byte]        ## 64 bytes — the binding discipline's.
    bootloader*, tee*, snp*, microcode*: int
    chipId*: seq[byte]

proc tcbWord(bootloader, tee, snpv, microcode: int): uint64 =
  ## ``TCB_VERSION``: the four security-patch levels, with the four
  ## bytes between them reserved and zero — which the reader checks, so
  ## they are written as zero here rather than left to chance.
  uint64(bootloader and 0xff) or
    (uint64(tee and 0xff) shl 8) or
    (uint64(snpv and 0xff) shl 48) or
    (uint64(microcode and 0xff) shl 56)

proc composeSnpReport*(key: TestP384Key; f: SnpReportFields;
                       corruptSignature = false;
                       boundBytes: seq[byte] = @[]): string =
  ## A version-2 security-processor attestation report, signed over its
  ## own first ``SnpSignedPrefixLen`` bytes.
  doAssert f.measurement.len == LenMeasurement
  doAssert f.reportData.len == LenReportData
  doAssert f.chipId.len == LenChipId
  var raw = newSeq[byte](SnpReportLen)
  cvmPutLe(raw, OffVersion, uint64(SnpTestVersion), 4)
  cvmPutLe(raw, OffGuestSvn, 0'u64, 4)
  cvmPutLe(raw, OffPolicy, SnpTestGuestPolicy, 8)
  cvmPutLe(raw, OffVmpl, uint64(SnpTestVmpl), 4)
  cvmPutLe(raw, OffSignatureAlgo, uint64(SnpSignatureAlgoEcdsaP384Sha384), 4)
  let tcb = tcbWord(f.bootloader, f.tee, f.snp, f.microcode)
  cvmPutLe(raw, OffCurrentTcb, tcb, 8)
  cvmPutLe(raw, OffReportedTcb, tcb, 8)
  cvmPutLe(raw, OffCommittedTcb, tcb, 8)
  cvmPutLe(raw, OffLaunchTcb, tcb, 8)
  cvmPutLe(raw, OffPlatformInfo, 0'u64, 8)
  # KEY_INFO: signing key 0 (VCEK), no author key, chip key unmasked.
  cvmPutLe(raw, OffKeyInfo, 0'u64, 4)
  cvmPutBytes(raw, OffReportData,
    (if boundBytes.len > 0: boundBytes else: f.reportData))
  cvmPutBytes(raw, OffMeasurement, f.measurement)
  cvmPutBytes(raw, OffChipId, f.chipId)
  cvmPutLe(raw, OffCurrentBuild, 0x00_16_03'u64, 4)
  cvmPutLe(raw, OffCommittedBuild, 0x00_16_03'u64, 4)

  var signed = newSeq[byte](SnpSignedPrefixLen)
  for i in 0 ..< SnpSignedPrefixLen: signed[i] = raw[i]
  var sig = signRawEcdsaP384(key, signed)
  if corruptSignature:
    sig.s[^1] = sig.s[^1] xor 0x01'u8
  # Big-endian to the curve, little-endian in the document: the
  # reverse of the single reversal the reader performs.
  for i in 0 ..< SnpP384ScalarLen:
    raw[SnpSignatureOffset + i] = sig.r[SnpP384ScalarLen - 1 - i]
    raw[SnpSignatureOffset + SnpScalarFieldLen + i] =
      sig.s[SnpP384ScalarLen - 1 - i]
  cvmStringOf(raw)

# ---------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------

type
  SnpEmulatorScenario* = object
    ## Everything the security-processor driver is told, and all of it
    ## at construction. There is deliberately no ``marked`` field.
    mutation*: CvmEmulatorMutation
    measurementHex*: string
      ## 96 lower-case hex characters: what ``snp_launch`` computed for
      ## the image this emulated instance is pretending to have booted.
    bootloader*, tee*, snp*, microcode*: int

  EmulatedSnpDriver* = ref object of AttestationDriver
    scenario: SnpEmulatorScenario
    hierarchy: SnpTestHierarchy

proc defaultSnpEmulatorScenario*(measurementHex: string;
                                 mutation = cemNone): SnpEmulatorScenario =
  SnpEmulatorScenario(
    mutation: mutation, measurementHex: measurementHex,
    bootloader: SnpTestBootloaderSpl, tee: SnpTestTeeSpl,
    snp: SnpTestSnpSpl, microcode: SnpTestUcodeSpl)

var cachedSnpHierarchy: SnpTestHierarchy
var cachedSnpHierarchyAt: int64 = 0

proc sharedSnpTestHierarchy*(now: int64): SnpTestHierarchy =
  ## One marked hierarchy per process. See this module's header for why
  ## it is cached and why caching it weakens nothing.
  if cachedSnpHierarchyAt != now:
    cachedSnpHierarchy =
      mintSnpTestHierarchy(now, marked = EmulatedCvmHierarchyIsMarked)
    cachedSnpHierarchyAt = now
  cachedSnpHierarchy

proc flipFirstByte(b: seq[byte]): seq[byte] =
  result = b
  result[0] = result[0] xor 0xff'u8

method driverProbe*(d: EmulatedSnpDriver): BackendReadiness =
  BackendReadiness(ready: true,
    detail: "software-root security-processor emulator: a " &
      "production-format attestation report over a real launch " &
      "measurement, signed by a key certified by a hierarchy no vendor " &
      "root reaches; injected fault: " & $d.scenario.mutation)

method driverQuote*(d: EmulatedSnpDriver; req: QuoteRequest): QuoteResult =
  let m = d.scenario.mutation
  var measurement = cvmRawOf(d.scenario.measurementHex)
  var bound: seq[byte] = @[]
  var corrupt = false
  var chain = snpChain(d.hierarchy)
  var tcbMicrocode = d.scenario.microcode
  case m
  of cemNone: discard
  of cemMeasurement: measurement = flipFirstByte(measurement)
  of cemSignature: corrupt = true
  of cemNonce: bound = flipFirstByte(cvmBytesOf(req.reportData))
  of cemTcb: tcbMicrocode = 0
  of cemChain:
    # The vendor's signing key is withheld. What is left is an
    # endorsement key and a root that do not meet by name — the shape a
    # chain takes when an element is lost in transit.
    chain = @[d.hierarchy.vcekDer, d.hierarchy.arkDer]
  of cemPolicy, cemTranscript, cemTime, cemReplay:
    doAssert cvmFaultSite(m) == cfsVerification,
      "this driver injects nothing for " & $m
    discard
  var identity = newSeq[byte](LenChipId)
  let seed = cvmRawOf(sha256Hex("software-root test part identity"))
  for i in 0 ..< LenChipId: identity[i] = seed[i mod seed.len]
  let evidence = composeSnpReport(d.hierarchy.vcekKey, SnpReportFields(
    measurement: measurement,
    reportData: cvmBytesOf(req.reportData),
    bootloader: d.scenario.bootloader, tee: d.scenario.tee,
    snp: d.scenario.snp, microcode: tcbMicrocode,
    chipId: identity), corruptSignature = corrupt, boundBytes = bound)
  QuoteResult(evidence: evidence, certificates: some(chain))

proc newEmulatedSnpDriver*(scenario: SnpEmulatorScenario;
                           nowSeconds: int64): EmulatedSnpDriver =
  ## The only constructor. Two arguments: what to emulate, and when.
  ## There is no third by which the hierarchy could be minted unmarked.
  if scenario.measurementHex.len != 2 * LenMeasurement:
    raise newException(DriverError,
      "a security-processor emulator is handed the launch measurement " &
      "its caller computed; " & $scenario.measurementHex.len &
      " hex characters is not the " & $(2 * LenMeasurement) & " a " &
      "MEASUREMENT field carries")
  result = EmulatedSnpDriver(
    scenario: scenario, hierarchy: sharedSnpTestHierarchy(nowSeconds))
  initAttestationDriver(result, abSevSnp, SnpEmulatorDriverName)

proc snpEmulatorScenario*(d: EmulatedSnpDriver): SnpEmulatorScenario =
  d.scenario

proc snpEmulatedChain*(d: EmulatedSnpDriver): seq[string] =
  snpChain(d.hierarchy)

proc snpEmulatedCrl*(d: EmulatedSnpDriver): seq[string] =
  @[d.hierarchy.crlDer]

# =====================================================================
# The trust-domain side
# =====================================================================

const
  IntelTestRootCn* = "Intel SGX Root CA"
    ## The name the evaluator compares against the key it matched. A
    ## test root that called itself something else would be refused as
    ## a name/key disagreement rather than as a foreign root, and a
    ## chain refused for the wrong reason proves nothing.
  IntelTestAuthorityCn* = "Intel SGX PCK Platform CA"
  IntelTestLeafCn* = "Intel SGX PCK Certificate"

  IntelTestFmspcHex* = "00606a000000"
  IntelTestPceSvn* = 13
  IntelTestTcbComponents*: array[IntelTcbComponentCount, int] =
    [2, 2, 2, 2, 3, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

type
  IntelTestHierarchy* = object
    ## An Intel-shaped provisioning chain whose root is not Intel's.
    marked*: bool
    rootKey*, authorityKey*, leafKey*: TestKey
    attestationKey*: TestKey
      ## The quoting enclave's attestation key. It belongs to the
      ## emulated MACHINE rather than to one driver instance, so two
      ## drivers built from one hierarchy are two readings of one
      ## machine and a byte comparison between their quotes is a
      ## comparison of one attestation. A key minted per driver would
      ## make every such comparison fail for a reason that has nothing
      ## to do with what is being compared.
    rootDer*, authorityDer*, leafDer*: string
    rootName*, authorityName*: seq[byte]
    crlDer*: string
    now*: int64

proc intelSgxExtension(marked: bool): seq[byte] =
  ## The provisioning certificate's platform description: a SEQUENCE of
  ## ``{ OID, value }`` pairs, read by OID rather than by position.
  var ppid = newSeq[byte](PpidLen)
  let ppidSeed = cvmRawOf(sha256Hex("software-root test platform instance"))
  for i in 0 ..< PpidLen: ppid[i] = ppidSeed[i]
  var cpuSvn = newSeq[byte](CpuSvnLen)
  for i in 0 ..< CpuSvnLen: cpuSvn[i] = byte(IntelTestTcbComponents[i])
  var tcbParts: seq[seq[byte]] = @[]
  for i in 0 ..< IntelTcbComponentCount:
    tcbParts.add derSeq(derOid(OidIntelTcb & "." & $(i + 1)),
                        derSmallInt(IntelTestTcbComponents[i]))
  tcbParts.add derSeq(derOid(OidIntelPceSvn), derSmallInt(IntelTestPceSvn))
  tcbParts.add derSeq(derOid(OidIntelCpuSvn), derOctets(cpuSvn))
  var tcbBody: seq[byte] = @[]
  for p in tcbParts:
    for b in p: tcbBody.add b
  let body = derSeq(
    derSeq(derOid(OidIntelPpid), derOctets(ppid)),
    derSeq(derOid(OidIntelTcb), tlv(0x30'u8, tcbBody)),
    derSeq(derOid(OidIntelPceId), derOctets([0x00'u8, 0x00'u8])),
    derSeq(derOid(OidIntelFmspc), derOctets(cvmRawOf(IntelTestFmspcHex))),
    derSeq(derOid(OidIntelSgxType), derSmallInt(0)))
  discard marked
  extension(IntelSgxArc, false, body)

proc mintIntelCert(subjectKey, issuerKey: TestKey; subjectCn: string;
                   issuerName: seq[byte]; serial: seq[byte];
                   notBefore, notAfter: int64;
                   extensions: seq[seq[byte]]):
                  tuple[der: string, subjectName: seq[byte]] =
  let subject = nameWithCn(subjectCn)
  let issuer = (if issuerName.len == 0: subject else: issuerName)
  var extBytes: seq[byte] = @[]
  for e in extensions:
    for b in e: extBytes.add b
  let tbs = derSeq(
    tlv(0xa0'u8, derSmallInt(2)),
    derInteger(serial),
    derSeq(derOid(OidEcdsaWithSha256)),
    issuer,
    derSeq(derUtcTime(notBefore), derUtcTime(notAfter)),
    subject,
    spkiOf(subjectKey),
    tlv(0xa3'u8, tlv(0x30'u8, extBytes)))
  let sig = signDer(issuerKey, tbs)
  let der = derSeq(tbs, derSeq(derOid(OidEcdsaWithSha256)),
                   derBitString(sig))
  (der: cvmStringOf(der), subjectName: subject)

proc mintIntelTestHierarchy*(now: int64; marked: bool): IntelTestHierarchy =
  ## A root, a provisioning authority and a provisioning certificate, in
  ## Intel's own profile.
  result.marked = marked
  result.now = now
  result.rootKey = newTestKey()
  result.authorityKey = newTestKey()
  result.leafKey = newTestKey()
  result.attestationKey = newTestKey()

  var marker: seq[seq[byte]] = @[]
  if marked: marker.add markerExt()

  let root = mintIntelCert(result.rootKey, result.rootKey, IntelTestRootCn,
    @[], randomSerial(), now - 30 * Day, now + 3650 * Day,
    @[basicConstraintsExt(true), keyUsageExt(@[5, 6])] & marker)
  result.rootDer = root.der
  result.rootName = root.subjectName

  let authority = mintIntelCert(result.authorityKey, result.rootKey,
    IntelTestAuthorityCn, result.rootName, randomSerial(),
    now - 20 * Day, now + 1825 * Day,
    @[basicConstraintsExt(true), keyUsageExt(@[5, 6])] & marker)
  result.authorityDer = authority.der
  result.authorityName = authority.subjectName

  let leaf = mintIntelCert(result.leafKey, result.authorityKey,
    IntelTestLeafCn, result.authorityName, randomSerial(),
    now - Day, now + 365 * Day,
    @[basicConstraintsExt(false), keyUsageExt(@[0]),
      intelSgxExtension(marked)] & marker)
  result.leafDer = leaf.der

  result.crlDer = mintCrl(result.authorityKey, result.authorityName,
    now - Day, now + 30 * Day, [])

proc intelChain*(h: IntelTestHierarchy): seq[string] =
  @[h.leafDer, h.authorityDer, h.rootDer]

# ---------------------------------------------------------------------
# The quote
# ---------------------------------------------------------------------

type
  TdxQuoteFields* = object
    mrTd*: seq[byte]              ## 48 bytes.
    rtmr*: array[TdxRtMrCount, seq[byte]]
    reportData*: seq[byte]        ## 64 bytes.

const
  TdxEmulatedVendorIdHex* = "939a7233f79c4ca9940a0db3957f0607"
    ## Intel's own quoting-library vendor identifier, which every
    ## genuine quote in this repository's corpus carries. Copied so the
    ## emulated document is the same SHAPE; nothing reads it to reach a
    ## verdict, and a gate asserts that the value a reader returns for
    ## it is the one written here rather than a constant.

proc composeTdxQuote*(attestationKey: TestKey; pckKey: TestKey;
                      f: TdxQuoteFields;
                      pckChainPem: string;
                      corruptSignature = false;
                      boundBytes: seq[byte] = @[]): string =
  ## A version-4 trust-domain attestation quote.
  doAssert f.mrTd.len == LenTeeMeasurement
  doAssert f.reportData.len == LenTeeReportData

  var body = newSeq[byte](TdReportLen)
  cvmPutBytes(body, OffMrTd, f.mrTd)
  for i in 0 ..< TdxRtMrCount:
    doAssert f.rtmr[i].len == LenTeeMeasurement
    cvmPutBytes(body, OffRtMr + i * LenTeeMeasurement, f.rtmr[i])
  cvmPutBytes(body, OffTdReportData,
    (if boundBytes.len > 0: boundBytes else: f.reportData))

  var head = newSeq[byte](TdxQuoteHeaderLen)
  cvmPutLe(head, OffQuoteVersion, uint64(TdxQuoteVersion4), 2)
  cvmPutLe(head, OffQuoteAttestationKeyType,
        uint64(TdxAttestationKeyTypeEcdsaP256), 2)
  cvmPutLe(head, OffQuoteTeeType, uint64(TdxTeeType), 4)
  cvmPutBytes(head, OffQuoteVendorId, cvmRawOf(TdxEmulatedVendorIdHex))

  var signed: seq[byte] = @[]
  for b in head: signed.add b
  for b in body: signed.add b

  var akPoint: seq[byte] = @[]
  for i in 1 ..< P256PointLen: akPoint.add attestationKey.pub[i]
  doAssert akPoint.len == EcdsaP256PublicKeyLen

  let quoteSig = signRawEcdsa(attestationKey, signed)
  var quoteSigBytes = cvmBytesOf(quoteSig.r) & cvmBytesOf(quoteSig.s)
  doAssert quoteSigBytes.len == EcdsaP256SignatureLen
  if corruptSignature:
    quoteSigBytes[^1] = quoteSigBytes[^1] xor 0x01'u8

  # The quoting enclave's report, and the binding that makes the two
  # signatures one statement: its report data is the digest of this
  # quote's own attestation key followed by the authentication data,
  # with the remaining 32 bytes zero.
  let authData = cvmBytesOf("software-root test quoting enclave")
  var preimage = akPoint
  for b in authData: preimage.add b
  let bound = snp_launch.sha256Of(preimage)

  var qe = newSeq[byte](SgxReportBodyLen)
  cvmPutLe(qe, OffQeMiscSelect, 0'u64, 4)
  for i in 0 ..< 32:
    qe[OffQeMrEnclave + i] = byte((i * 7 + 11) and 0xff)
    qe[OffQeMrSigner + i] = byte((i * 13 + 3) and 0xff)
  cvmPutLe(qe, OffQeIsvProdId, 2'u64, 2)
  cvmPutLe(qe, OffQeIsvSvn, 4'u64, 2)
  for i in 0 ..< bound.len: qe[OffQeReportData + i] = bound[i]

  let qeSig = signRawEcdsa(pckKey, qe)
  let qeSigBytes = cvmBytesOf(qeSig.r) & cvmBytesOf(qeSig.s)

  let pckPayload = cvmBytesOf(pckChainPem)
  var pckBlock = newSeq[byte](6 + pckPayload.len)
  cvmPutLe(pckBlock, 0, uint64(PckCertificateChainDataType), 2)
  cvmPutLe(pckBlock, 2, uint64(pckPayload.len), 4)
  cvmPutBytes(pckBlock, 6, pckPayload)

  var qeData: seq[byte] = @[]
  for b in qe: qeData.add b
  for b in qeSigBytes: qeData.add b
  var authLen = newSeq[byte](2)
  cvmPutLe(authLen, 0, uint64(authData.len), 2)
  for b in authLen: qeData.add b
  for b in authData: qeData.add b
  for b in pckBlock: qeData.add b

  var sigData: seq[byte] = @[]
  for b in quoteSigBytes: sigData.add b
  for b in akPoint: sigData.add b
  var qeHeader = newSeq[byte](6)
  cvmPutLe(qeHeader, 0, uint64(QeReportCertificationDataType), 2)
  cvmPutLe(qeHeader, 2, uint64(qeData.len), 4)
  for b in qeHeader: sigData.add b
  for b in qeData: sigData.add b

  var raw: seq[byte] = @[]
  for b in signed: raw.add b
  var lenField = newSeq[byte](4)
  cvmPutLe(lenField, 0, uint64(sigData.len), 4)
  for b in lenField: raw.add b
  for b in sigData: raw.add b
  cvmStringOf(raw)

# ---------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------

type
  TdxEmulatorScenario* = object
    ## Everything the trust-domain driver is told.
    mutation*: CvmEmulatorMutation
    mrtdHex*: string
    rtmrHex*: array[TdxRtMrCount, string]

  EmulatedTdxDriver* = ref object of AttestationDriver
    scenario: TdxEmulatorScenario
    hierarchy: IntelTestHierarchy

proc zeroRegisterHex*(): string = repeat('0', 2 * LenTeeMeasurement)

proc defaultTdxEmulatorScenario*(mrtdHex: string;
                                 rtmr0, rtmr1, rtmr2, rtmr3: string;
                                 mutation = cemNone): TdxEmulatorScenario =
  result.mutation = mutation
  result.mrtdHex = mrtdHex
  result.rtmrHex = [rtmr0, rtmr1, rtmr2, rtmr3]

var cachedIntelHierarchy: IntelTestHierarchy
var cachedIntelHierarchyAt: int64 = 0

proc sharedIntelTestHierarchy*(now: int64): IntelTestHierarchy =
  if cachedIntelHierarchyAt != now:
    cachedIntelHierarchy =
      mintIntelTestHierarchy(now, marked = EmulatedCvmHierarchyIsMarked)
    cachedIntelHierarchyAt = now
  cachedIntelHierarchy

method driverProbe*(d: EmulatedTdxDriver): BackendReadiness =
  BackendReadiness(ready: true,
    detail: "software-root trust-domain emulator: a production-format " &
      "attestation quote over a real initial-memory measurement, signed " &
      "by a key certified by a hierarchy no vendor root reaches; " &
      "injected fault: " & $d.scenario.mutation)

method driverQuote*(d: EmulatedTdxDriver; req: QuoteRequest): QuoteResult =
  let m = d.scenario.mutation
  var mrTd = cvmRawOf(d.scenario.mrtdHex)
  var bound: seq[byte] = @[]
  var corrupt = false
  var chain = intelChain(d.hierarchy)
  case m
  of cemNone: discard
  of cemMeasurement: mrTd = flipFirstByte(mrTd)
  of cemSignature: corrupt = true
  of cemNonce: bound = flipFirstByte(cvmBytesOf(req.reportData))
  of cemTcb:
    # A trust domain's trusted-computing-base status comes from the
    # vendor's own signed documents, which are the VERIFIER's and are
    # reached through the same pinned root this chain cannot match. So
    # there is no status for a driver to lower, and this fault has no
    # trust-domain expression. Declared, not silently skipped.
    discard
  of cemChain:
    # The ENVELOPE's bundle loses an element; the quote's own PEM chain
    # is left whole. The two are different carriers of the same three
    # certificates, and shrinking both at once would break the reader
    # as well as the count rule — which would make this fault two
    # faults and leave the count rule with no isolated input.
    chain = @[d.hierarchy.leafDer, d.hierarchy.rootDer]
  of cemPolicy, cemTranscript, cemTime, cemReplay:
    doAssert cvmFaultSite(m) == cfsVerification,
      "this driver injects nothing for " & $m
    discard
  var f = TdxQuoteFields(mrTd: mrTd, reportData: cvmBytesOf(req.reportData))
  for i in 0 ..< TdxRtMrCount:
    f.rtmr[i] = cvmRawOf(d.scenario.rtmrHex[i])
  var pem = ""
  for der in intelChain(d.hierarchy): pem.add cvmPemOf(der)
  let evidence = composeTdxQuote(d.hierarchy.attestationKey,
    d.hierarchy.leafKey, f, pem, corruptSignature = corrupt,
    boundBytes = bound)
  QuoteResult(evidence: evidence, certificates: some(chain))

proc newEmulatedTdxDriver*(scenario: TdxEmulatorScenario;
                           nowSeconds: int64): EmulatedTdxDriver =
  ## The only constructor.
  if scenario.mrtdHex.len != 2 * LenTeeMeasurement:
    raise newException(DriverError,
      "a trust-domain emulator is handed the initial-memory measurement " &
      "its caller computed; " & $scenario.mrtdHex.len &
      " hex characters is not the " & $(2 * LenTeeMeasurement) &
      " an MRTD carries")
  for i in 0 ..< TdxRtMrCount:
    if scenario.rtmrHex[i].len != 2 * LenTeeMeasurement:
      raise newException(DriverError,
        "runtime register " & $i & " was handed " &
        $scenario.rtmrHex[i].len & " hex characters")
  result = EmulatedTdxDriver(
    scenario: scenario, hierarchy: sharedIntelTestHierarchy(nowSeconds))
  initAttestationDriver(result, abTdx, TdxEmulatorDriverName)

proc tdxEmulatorScenario*(d: EmulatedTdxDriver): TdxEmulatorScenario =
  d.scenario

proc tdxEmulatedChain*(d: EmulatedTdxDriver): seq[string] =
  intelChain(d.hierarchy)

proc tdxEmulatedCrl*(d: EmulatedTdxDriver): seq[string] =
  @[d.hierarchy.crlDer]
