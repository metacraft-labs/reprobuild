## A local evidence emulator: production-format measured-boot evidence,
## signed by a key nothing in production trusts, with one structured
## fault injected at a time.
##
## Named without a ``t_`` / ``test_`` prefix so the test-edge generator
## does not discover it as a test in its own right — the convention
## ``software_root_test_pki.nim`` follows.
##
## ## What it is
##
## A subclass of the backend driver seam. It is handed 64 bytes and it
## returns a ``reproos.tpm2-evidence.v1`` composite — the same encoding a
## machine with a TPM produces, assembled by the same composer, carrying
## a real ``TPMS_ATTEST``, a real ``TPMT_SIGNATURE`` over it, and a real
## crypto-agile TCG event log that replays to the register digest the
## structure carries. Every byte of it goes through the production codecs
## on the way out and the production reader on the way in. Nothing about
## the FORMAT is emulated; what is emulated is the root of trust.
##
## ## Why it is not a verifier bypass
##
## It cannot be one, and the reason is structural rather than a setting:
##
##   * **It produces evidence and never a verdict.** There is no code
##     here that any verifier calls, and this file names no verifier
##     symbol at all — not in its imports and not in its body, which a
##     gate asserts both ways.
##
##     Stated at that width on purpose, because the wider claim would be
##     false: ``./software_root_test_pki`` imports the verification
##     library for the certificate types it mints into, so that package
##     IS one hop away and "nothing is reachable from here" is not a
##     thing this module can say. What it can say is that it names
##     nothing of it, and a module that names no verifier symbol cannot
##     reach a verdict however it is linked. The claim that carries the
##     weight is the other one below: no product binary imports this file
##     at all.
##
##     The gate that asserts this reads the whole source and not only the
##     import lines — which is also why the sentence above spells no
##     package name. A comment that named one would satisfy the search it
##     is describing, and this file has to keep being the file that names
##     none.
##   * **It signs with a key certified only by a MARKED hierarchy.**
##     ``mintHierarchy(..., marked = true)`` gives every certificate a
##     *critical* extension under the ``2.999`` arc ITU-T set aside for
##     examples, and RFC 5280 §4.2 requires a certificate-using system to
##     refuse a certificate carrying a critical extension it does not
##     recognise. A production build recognises three, none of them that
##     one, so it refuses the chain at every position — including when an
##     operator has installed this hierarchy's root in the trust store by
##     hand, because the refusal is about the certificate's contents and
##     not about whether anything trusts it.
##   * **There is no spelling of the constructor that mints an unmarked
##     one.** ``newEmulatedTpm2Driver`` takes a scenario and an instant
##     and nothing else; the scenario has no field for it. The mark is
##     not a scenario knob, so "emulated evidence a production verifier
##     accepts" is not a state this type has.
##   * **It always bundles the chain.** The driver returns
##     ``some(chain)`` on every path, so the chain check is always
##     REACHED — and a bundled chain that is refused is a violation
##     rather than a skip, whatever the policy says about requiring one.
##     A policy cannot decline to look.
##
## The consequence worth stating plainly: a build that accepts this
## emulator's evidence is a build compiled with
## ``-d:reproAttestSoftwareRootTestTrust``, which brings the evaluator
## that recognises the marker into existence. In every other build that
## symbol does not exist. The difference is which binary is running.
##
## ## The scenario is taken at construction, never from a request
##
## ``QuoteRequest`` carries the 64 bytes and nothing else, and this
## driver does not widen it. Measurement, firmware version, quoted
## register set and the injected fault are all fixed when the driver is
## built. An emulator a remote caller could steer would be a verifier
## bypass wearing a driver's clothes; this one answers the same way to
## everybody, and differs only between processes.
##
## ## The eleven faults
##
## ``EmulatorMutation`` names one fault per value. Six of them are
## injected here, because they are properties of the evidence: the
## signature, the bundled chain, the measured image, the event log, the
## firmware version, and the bytes the structure binds. The other five —
## the policy the verifier is handed, the ephemeral key the envelope
## claims, the transcript on the wire, the instant of verification and a
## replayed challenge — are not the driver's to inject, because they are
## not in the evidence. They are applied by whoever assembles the
## verification, and a gate that pretended a driver could produce them
## would be testing a fiction.
##
## ``applyEvidenceFault`` is a ``case`` over the whole enum with no
## ``else``, so a fault added without a decision about where it is
## injected does not compile.
##
## ## Mocking
##
## None. Real ECDSA-P256 signatures over real structures, a real event
## log, real DER, and real replay. The key is drawn from the operating
## system's random source per process and written nowhere.

import std/[options, strutils]

import repro_attest

import ./software_root_test_pki

const
  EmulatorDriverName* = "software-root-evidence-emulator"

  EmulatedHierarchyIsMarked* = true
    ## Every certificate this emulator's hierarchy issues carries the
    ## RFC 5280 §4.2 marker. A ``const`` rather than a parameter: the
    ## constructor has no argument that could set it and the scenario has
    ## no field for it, so there is exactly one place this is decided and
    ## it is decided at compile time.

  EmulatedQuotedRegisters* = [0, 2, 4, 7, Pcr11]
    ## The firmware-owned registers plus the one a stub extends with the
    ## image's sections. Register 11 must be in the set or the quote says
    ## nothing about the measurement — the verifier refuses a quote whose
    ## selection does not cover it, and an emulator whose quote could not
    ## be read would exercise nothing.

  EmulatedFirmwareVersion* = 0x2024012500120000'u64
    ## The value ``tpm2_getcap properties-fixed`` reports for the
    ## reference software TPM this repository's pinned quote vectors were
    ## taken from. A plausible value rather than a round number, so a TCB
    ## downgrade is visibly a downgrade.

  EmulatedSections* = [".linux", ".osrel", ".cmdline", ".initrd", ".uname",
                       ".sbat"]
    ## The sections a stub measures, in the order it measures them. Six
    ## of them, which is what a real unified kernel image carries.

  TamperedSection* = ".cmdline"
    ## Which section the measurement fault re-measures. The command line
    ## is the realistic choice: it is the section an attacker changes to
    ## alter what a kernel does without replacing the kernel.

type
  EmulatorMutation* = enum
    ## One structured fault per value. ``emNone`` is the unmutated
    ## instance and must be accepted by a build that recognises the
    ## marker; every other value must be refused, or — for the one fault
    ## nothing in this build can catch — must be declared as uncaught.
    emNone = "none"
    emSignature = "signature"
    emChain = "chain"
    emMeasurement = "measurement"
    emEventLog = "event-log"
    emTcb = "tcb"
    emPolicy = "policy"
    emNonce = "nonce"
    emEphemeralKey = "ephemeral-key"
    emTranscript = "transcript"
    emTime = "time"
    emReplay = "replay"

  EmulatorFaultSite* = enum
    ## Where a fault is injected. Not a label: it is what stops a fault
    ## being claimed as "the driver produces it" when the driver cannot.
    fsEvidence
      ## Injected by this driver, into the bytes it returns.
    fsVerification
      ## Injected by whoever assembles the verification — the document on
      ## the wire, the policy, the expected challenge or the clock.

  EmulatorScenario* = object
    ## Everything this driver is told, and all of it at construction.
    ##
    ## There is deliberately no ``marked`` field and no trust-store
    ## field. A scenario that could unmark the hierarchy would be the
    ## one setting that turns the emulator into a verifier bypass.
    mutation*: EmulatorMutation
    firmwareVersion*: uint64
    quotedRegisters*: seq[int]

  EmulatedTpm2Driver* = ref object of AttestationDriver
    scenario: EmulatorScenario
    hierarchy: TestHierarchy

proc faultSite*(m: EmulatorMutation): EmulatorFaultSite =
  ## A total function over the enum, with no ``else``. A fault added
  ## without a decision about where it is injected does not compile, and
  ## ``applyEvidenceFault`` below reads this rather than keeping a second
  ## list that could come to disagree with it.
  case m
  of emNone: fsEvidence
  of emSignature: fsEvidence
  of emChain: fsEvidence
  of emMeasurement: fsEvidence
  of emEventLog: fsEvidence
  of emTcb: fsEvidence
  of emNonce: fsEvidence
  of emPolicy: fsVerification
  of emEphemeralKey: fsVerification
  of emTranscript: fsVerification
  of emTime: fsVerification
  of emReplay: fsVerification

proc defaultEmulatorScenario*(mutation = emNone): EmulatorScenario =
  EmulatorScenario(
    mutation: mutation,
    firmwareVersion: EmulatedFirmwareVersion,
    quotedRegisters: @EmulatedQuotedRegisters)

# ---------------------------------------------------------------------
# What the emulated image measures
# ---------------------------------------------------------------------

proc sectionContentDigest*(section: string; tampered = false): string =
  ## The content digest a stub would log for one section, as 64 lower-case
  ## hex characters. Derived from the section's name so the whole image is
  ## reproducible from this file and nothing has to be pinned.
  sha256Hex((if tampered: "emulated-uki-content-ALTERED:"
             else: "emulated-uki-content:") & section)

proc emulatedEventLogTemplate*(tampered = false): string =
  ## The ``systemd-stub-uki-sections.v1`` replay template describing what
  ## this emulator measures. A measurement manifest built from it has a
  ## ``pcr11`` the library REPLAYS rather than a value typed in, so the
  ## manifest and the emulated boot cannot disagree by transcription.
  result = EventLogTemplateId & ";bank=sha256"
  for section in EmulatedSections:
    result.add ";" & section & "=" &
      sectionContentDigest(section,
        tampered and section == TamperedSection)

# ---------------------------------------------------------------------
# A crypto-agile TCG event log, written from the format
# ---------------------------------------------------------------------

proc rawOfHex(hex: string): string =
  result = newString(hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(hex[2 * i .. 2 * i + 1]))

proc specIdHeaderEntry(): string =
  ## Entry 0. It is a TCG 1.2 ``TCG_PCR_EVENT`` in both shapes — that is
  ## the TCG's own arrangement, and it is what lets a 1.2-era parser walk
  ## past a crypto-agile header instead of choking on it. One bank is
  ## declared, because every later entry carries exactly one digest and a
  ## header declaring a bank no entry uses would describe a log this
  ## emulator does not write.
  var spec = initTpm2Writer("TCG_EfiSpecIdEvent")
  spec.writeBytes(SpecIdSignature)
  spec.writeU32Le(0'u32)                    # platformClass
  spec.writeU8(0'u8)                        # specVersionMinor
  spec.writeU8(2'u8)                        # specVersionMajor
  spec.writeU8(0'u8)                        # specErrata
  spec.writeU8(2'u8)                        # uintnSize: 64-bit
  spec.writeU32Le(1'u32)                    # numberOfAlgorithms
  spec.writeU16Le(uint16(TpmAlgSha256))
  spec.writeU16Le(uint16(digestSize(TpmAlgSha256)))
  spec.writeU8(0'u8)                        # vendorInfoSize
  let payload = spec.bytes

  var w = initTpm2Writer("TCG_PCR_EVENT")
  w.writeU32Le(0'u32)
  w.writeU32Le(uint32(EvNoAction))
  w.writeBytes(repeat('\0', LegacyDigestBytes))
  w.writeU32Le(uint32(payload.len))
  w.writeBytes(payload)
  w.bytes

proc agileEntry(pcr: int; eventType: TcgEventType; digestHex, data: string):
               string =
  var w = initTpm2Writer("TCG_PCR_EVENT2")
  w.writeU32Le(uint32(pcr))
  w.writeU32Le(uint32(eventType))
  w.writeU32Le(1'u32)                       # one digest, one bank
  w.writeU16Le(uint16(TpmAlgSha256))
  w.writeBytes(rawOfHex(digestHex))
  w.writeU32Le(uint32(data.len))
  w.writeBytes(data)
  w.bytes

proc buildEmulatedEventLog(tampered: bool): string =
  ## Firmware's measurements, then the stub's.
  ##
  ## The firmware half is what makes registers 0, 2, 4 and 7 say
  ## something: a quote over registers the log never touched is a quote
  ## over reset values, which are identical on every machine, and the
  ## replay refuses to answer for a selection in which nothing was
  ## extended.
  result = specIdHeaderEntry()
  for (pcr, eventType, label) in [
      (0, EvSCrtmVersion, "emulated CRTM version"),
      (2, EvEfiBootServicesDriver, "emulated option ROM"),
      (4, EvEfiBootServicesApplication, "emulated boot manager"),
      (7, EvEfiVariableDriverConfig, "emulated SecureBoot variable")]:
    result.add agileEntry(pcr, eventType,
      sha256Hex("emulated-firmware:" & label), label)
  # The stub's half: two events per section, the name and then the
  # content, both extending PCR 11 — which is the order and the pairing
  # `measurement.replayEventLogTemplate` folds, so the two agree by
  # construction rather than by a constant kept in step.
  for section in EmulatedSections:
    result.add agileEntry(Pcr11, EvEventTag,
      sectionNameEventDigest(section), section & "\0")
    result.add agileEntry(Pcr11, EvIpl,
      sectionContentDigest(section, tampered and section == TamperedSection),
      "emulated " & section & " content")

# ---------------------------------------------------------------------
# The quote
# ---------------------------------------------------------------------

proc emulatedQualifiedSigner(h: TestHierarchy): string =
  ## A well-formed ``TPM2B_NAME``: the two-byte name algorithm followed
  ## by a digest of that length.
  ##
  ## It is NOT a TPM's Name for this key — a TPM Name digests a
  ## ``TPMT_PUBLIC`` and this emulator has no ``TPMT_PUBLIC`` — and
  ## nothing in this system reads it. It is here because the field is not
  ## optional on the wire and a structure that omitted it would not be
  ## production-format.
  var name = newString(2)
  name[0] = char(uint8((uint16(TpmAlgSha256) shr 8) and 0xFF'u16))
  name[1] = char(uint8(uint16(TpmAlgSha256) and 0xFF'u16))
  var pub = ""
  for b in h.ak.key.pub: pub.add char(b)
  name & rawOfHex(sha256Hex(pub))

proc flipLastByte(s: string): string =
  result = s
  if result.len > 0:
    result[^1] = char(uint8(result[^1]) xor 0x01'u8)

proc flipReportData(reportData: string): string =
  result = reportData
  result[0] = char(uint8(result[0]) xor 0xFF'u8)

proc applyEvidenceFault(d: EmulatedTpm2Driver; reportData: string):
                       tuple[evidence: string, chain: seq[string]] =
  ## Build the evidence, with this driver's one fault injected.
  ##
  ## The ``case`` is over the whole enum with no ``else``, so a fault
  ## added to ``EmulatorMutation`` without a decision here does not
  ## compile. ``faultSite`` says which arms are this driver's, and the
  ## ``doAssert`` below ties the two together: an arm that injected a
  ## fault ``faultSite`` calls somebody else's would be a driver claiming
  ## to produce what it cannot.
  let m = d.scenario.mutation

  var boundBytes = reportData
  var tamperedMeasurement = false
  var firmware = d.scenario.firmwareVersion
  var corruptSignature = false
  var corruptLog = false
  var chain = d.hierarchy.akChain

  case m
  of emNone: discard
  of emSignature: corruptSignature = true
  of emChain:
    # The intermediate is withheld. What is left is a leaf and a root
    # that do not meet by name — the shape a chain takes when an element
    # is lost in transit, and one the leaf's own signature cannot repair.
    chain = @[d.hierarchy.ak.der, d.hierarchy.root.der]
  of emMeasurement: tamperedMeasurement = true
  of emEventLog: corruptLog = true
  of emTcb: firmware = 0'u64
  of emNonce:
    # The backend signs bytes other than the ones it was handed. Nothing
    # else about the evidence is wrong, which is what makes this the
    # fault the envelope alone cannot catch.
    boundBytes = flipReportData(reportData)
  of emPolicy, emEphemeralKey, emTranscript, emTime, emReplay:
    doAssert faultSite(m) == fsVerification,
      "this driver injects nothing for " & $m
    discard

  var logBytes = buildEmulatedEventLog(tamperedMeasurement)
  let sel = pcrSelection(TpmAlgSha256, d.scenario.quotedRegisters)
  let parsed = parseEventLog(logBytes)
  let digest = pcrComposite(TpmAlgSha256, sel, selectedFromReplay(parsed, sel))

  let attest = TpmsAttest(
    magic: TpmGeneratedValue,
    attestType: TpmStAttestQuote,
    qualifiedSigner: emulatedQualifiedSigner(d.hierarchy),
    extraData: boundBytes,
    clockInfo: TpmsClockInfo(clock: 1_700_000'u64, resetCount: 1'u32,
                             restartCount: 0'u32, safe: true),
    firmwareVersion: firmware,
    quote: TpmsQuoteInfo(pcrSelect: sel, pcrDigest: digest))
  let attestBytes = serializeAttest(attest)

  # Signed over the bytes that will travel, never over a re-serialisation
  # of a record — which is the same rule the codec states for reading.
  var message = newSeq[byte](attestBytes.len)
  for i in 0 ..< attestBytes.len: message[i] = byte(attestBytes[i])
  let raw = signRawEcdsa(d.hierarchy.ak.key, message)
  let signature = TpmtSignature(
    sigAlg: TpmAlgEcdsa, hashAlg: TpmAlgSha256, kind: tskEcc,
    signatureR: raw.r,
    signatureS: (if corruptSignature: flipLastByte(raw.s) else: raw.s))

  if corruptLog:
    # One byte of ONE measurement's digest, inside the log, AFTER the
    # quote was signed. The structure still verifies under the key; the
    # replay no longer reaches the digest the structure carries. That is
    # the difference between a forged quote and a forged log, and the two
    # have to be separable or the gate cannot say which rule fired.
    let target = logBytes.find(
      rawOfHex(sectionContentDigest(TamperedSection)))
    doAssert target >= 0, "the log does not carry the digest it measured"
    logBytes[target] = char(uint8(logBytes[target]) xor 0x01'u8)

  result.evidence = composeTpm2Evidence(Tpm2Evidence(
    attestBytes: attestBytes,
    signatureBytes: serializeSignature(signature),
    eventLogBytes: logBytes))
  result.chain = chain

# ---------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------

method driverProbe*(d: EmulatedTpm2Driver): BackendReadiness =
  BackendReadiness(ready: true,
    detail: "software-root evidence emulator: production-format " &
      "measured-boot evidence signed by a key certified by a hierarchy " &
      "a production verifier refuses; injected fault: " &
      $d.scenario.mutation)

method driverQuote*(d: EmulatedTpm2Driver; req: QuoteRequest): QuoteResult =
  let built = applyEvidenceFault(d, req.reportData)
  # `some(chain)` on every path, including the faulted ones. A driver
  # that could withhold the chain could put its evidence in front of a
  # verifier that never reaches the rule that refuses it.
  QuoteResult(evidence: built.evidence, certificates: some(built.chain))

proc newEmulatedTpm2Driver*(scenario: EmulatorScenario;
                            nowSeconds: int64): EmulatedTpm2Driver =
  ## The only constructor.
  ##
  ## Two arguments: what to emulate, and when. There is no third by which
  ## the hierarchy could be minted unmarked, and adding one is the
  ## mutation the bypass gate runs.
  if scenario.quotedRegisters.len == 0:
    raise newException(DriverError,
      "an emulator configured to quote no register would sign the digest " &
      "of the empty string, which is the same on every machine")
  result = EmulatedTpm2Driver(
    scenario: scenario,
    hierarchy: mintHierarchy(nowSeconds, marked = EmulatedHierarchyIsMarked))
  initAttestationDriver(result, abTpm2, EmulatorDriverName)

proc emulatorScenario*(d: EmulatedTpm2Driver): EmulatorScenario = d.scenario

proc emulatedChain*(d: EmulatedTpm2Driver): seq[string] =
  ## What this driver bundles, in DER, leaf first.
  d.hierarchy.akChain

proc emulatedAnchorDer*(d: EmulatedTpm2Driver): string =
  ## The hierarchy's root, as an operator would install it. Exposed so a
  ## gate can put it in the trust store — which is the strongest form of
  ## the bypass question: a verifier that has been TOLD to trust this
  ## root still refuses, because the refusal is about the certificates.
  d.hierarchy.root.der

proc emulatedCrlDer*(d: EmulatedTpm2Driver): seq[string] =
  @[d.hierarchy.rootCrl, d.hierarchy.intermediateCrl]

proc emulatedAkPublicKey*(d: EmulatedTpm2Driver): seq[byte] =
  ## The public half of the key this emulator signs with, as raw bytes.
  ##
  ## A gate uses it to establish BY VALUE that the certificate the reader
  ## verifies a signature under is the certificate for THIS key, and not
  ## merely some certificate that parsed. Returned as a ``seq`` rather
  ## than in the reader's own fixed-width point type on purpose: this
  ## module names no symbol of the verifier, and a gate asserts that.
  result = @[]
  for b in d.hierarchy.ak.key.pub: result.add b
