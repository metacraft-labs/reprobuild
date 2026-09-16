## Reading backend-native evidence, and the only facts a verdict may
## rest on.
##
## ## The projection is the enforcement
##
## §5.1 of the design says ``evidence`` is the only authoritative field
## of a report and that a verdict must never be derived from the
## instance's own ``claims``. Every codebase that states that rule states
## it in a comment. Here it is a *type*: ``AuthoritativeInputs`` carries
## the envelope's non-claim fields plus whatever a reader found inside
## the evidence, and it has **no claims field at all**. The checks in
## ``verify`` are handed one of these and never the report, so a check
## that wanted to read a claim would not compile.
##
## The claims are not thrown away — they are useful when someone is
## reading a log to find out why a machine was refused — but they leave
## by a different door, as ``Verdict.claimNotes``, computed after the
## decision and invisible to the function that computes it.
##
## ## What a reader is, and what this build carries
##
## A reader turns one backend's opaque evidence blob into facts: the
## launch measurement it attests, the 64 bytes it bound, the vendor's
## TCB level. It is the only component that touches signatures.
##
## This build carries two: the **mock** reader and the **measured-boot**
## reader. For every other backend the reading is a **violation**, not a
## skip —
##
##     a verdict on evidence that nothing parsed is a verdict on
##     nothing,
##
## and reporting that as "not applicable" would let a report from a real
## SEV-SNP machine be accepted by a verifier that never looked at its
## signature. Backends acquire readers as their evidence formats are
## implemented; until then their reports are refused, which is the
## correct answer and not a placeholder.
##
## ## What the measured-boot reader establishes, and what it does not
##
## A measured-boot composite carries three artifacts: an attestation
## structure, a signature over it, and the event log firmware wrote. The
## reader turns them into the two facts a verdict rests on — the 64 bytes
## the instance bound, and the register value that says what booted — and
## the interesting work is in how the second of those is obtained.
##
## The register value does **not** come from the event log directly. The
## log is unsigned: anything can write one. What the reader does is
## replay the log, recompute the register composite the replay implies,
## and require it to equal the composite the attestation structure
## carries. Only then is the replay's own view of the registers a view of
## the boot the root of trust attested to.
##
## That join has one precondition that is easy to omit and fatal to
## omit: **the register the launch measurement is taken from must be one
## the quote actually covers.** A composite over registers 0 to 7 says
## nothing whatever about register 11, so a log could claim any value for
## 11 and still explain such a quote perfectly. The reader therefore
## refuses a quote whose selection does not name the launch register in
## the bank the manifest speaks, rather than reading a value out of the
## log that nothing signed.
##
## ## Who produced the structure, and when that can be established
##
## The join above says the log and the quote describe one boot. It says
## nothing about *who* produced the quote, and on its own a quote nobody
## signed for is a document.
##
## When the report **bundles a certificate chain**, the reader closes
## that gap: it verifies the signature over the attestation structure
## under the public key of the chain's leaf, over the bytes that arrived.
## The finding then names the key. What that establishes is bounded and
## worth stating exactly — the evidence was produced by the key in that
## certificate, and *nothing about whether that certificate is one to
## believe*, which is the certificate-chain check's question and is
## answered against the verifier's own trust store. The two halves are
## separate checks on purpose: a chain that validates for a key that
## signed nothing here, and a signature by a key nothing vouches for, are
## different failures with different remedies, and a verifier that
## reported them as one would send an operator to the wrong place.
##
## When the report bundles **no** chain there is no key to check against.
## This build fetches none — there is no field to carry one and no flag
## that would go looking — so no public-key operation is performed on the
## structure at all, the reading carries no
## ``attestationKeySubject``, and ``NoSignatureCheckedNote`` rides the
## verdict. That is an unanswered question recorded as one, not a skip.
##
## ## Why the mock reader reports NO launch measurement
##
## The mock backend's evidence carries a ``launchMeasurement`` field, and
## its value is a published constant — the SHA-256 of the ASCII string
## ``test`` — because the mock measures no boot. A reader that surfaced
## that constant as a launch measurement would invite a verifier to
## compare it against a manifest, and the comparison would be between two
## values the same repository chose. So the mock reader answers ``none``,
## the measurement check reports itself inapplicable, and the verdict
## says out loud that no measurement was compared. That is the honest
## shape, and it is why ``allow_mock`` and pinned manifests are refused
## together.
##
## ## Mocking
##
## None. The mock *backend* is a backend for a root of trust that is
## absent; reading its evidence exercises the same parse-and-recompute
## path a real reader will.

import std/[options, strutils]

import repro_attest

import ./policy
import ./verdict
import ./x509

type
  AuthoritativeInputs* = object
    ## Everything a verdict may rest on. Deliberately without the
    ## report's ``claims`` — see the module header.
    tier*: AttestationTier
    backend*: AttestationBackend
    challengeHex*: string
    reportDataHex*: string
      ## The envelope's 64 bytes.
    bindings*: ReportBindings
    bundledCertificates*: bool
    certificates*: seq[string]
      ## The bundled chain, decoded. Empty when none was bundled — and
      ## ``bundledCertificates`` is what distinguishes that from a chain
      ## of nothing, which the envelope already refuses.
    readerName*: string
      ## Which reader produced the three fields below. Named in the
      ## verdict, because a caller embedding this library may bring its
      ## own reader for a backend this build cannot parse, and a verdict
      ## should say whose reading it rests on.
    launchMeasurement*: Option[string]
      ## What the evidence says booted. ``none`` when the backend takes
      ## no launch measurement.
    reportDataInEvidence*: Option[string]
      ## The 64 bytes as they appear INSIDE the signed evidence, hex.
      ## ``none`` when the reader could not locate them, which is a
      ## reader that cannot support a verdict.
    sevSnpTcb*: Option[SevSnpTcbMinimum]
    tdxTcbStatus*: Option[string]
    attestationKeySubject*: Option[string]
      ## A description of the key whose public half the attestation
      ## structure's signature VERIFIED under, or ``none`` when no
      ## public-key operation was performed on it.
      ##
      ## It is an ``Option`` rather than a ``bool`` for the same reason
      ## ``launchMeasurement`` is: a verdict that says a signature was
      ## checked owes the reader which key it was checked against, and a
      ## flag cannot say. ``none`` is the honest answer wherever there is
      ## no key to check against, and it is what keeps
      ## ``NoSignatureCheckedNote`` attached to exactly the readings that
      ## earn it.

  EvidenceReading* = object
    ## A reader's answer: what it found, and whether it was willing to
    ## vouch for the evidence at all.
    finding*: CheckFinding
    inputs*: AuthoritativeInputs

const
  MockReaderName* = "reproos.mock-evidence.v1 reader"

  Tpm2ReaderName* = Tpm2EvidenceSchema & " reader"

  LaunchMeasurementBank* = TpmAlgSha256
    ## The bank the measurement manifest's launch expectations are
    ## written in. A manifest's ``pcr11`` is 64 hex characters, so
    ## comparing it against a register from any other bank is a
    ## comparison that cannot succeed and must not be attempted.

  LaunchMeasurementRegister* = Pcr11
    ## Where a stub leaves the image's own measurement. Named through
    ## ``measurement``'s constant rather than spelled again, so the
    ## register the build precomputes and the register the verifier
    ## reads are one declaration.

  NoSignatureCheckedNote* =
    "no signature was checked: this verifier performs no public-key " &
    "operation on an attestation structure and is given no attestation " &
    "key, so nothing here establishes WHO produced this evidence"
    ## Carried into the finding that reads measured-boot evidence, and
    ## into a caveat on any verdict that rests on it. A limit a verdict
    ## does not state is a limit its reader does not know about.
    ##
    ## It is attached to a reading in which no public-key operation was
    ## performed on the attestation structure — which is every reading of
    ## a report that bundles no certificate chain, because a signature
    ## with no key is not weak evidence, it is none. A reading that DID
    ## check one says so instead, through the two constants below, and
    ## names the key it checked against.

  SignatureCheckedNotePrefix* =
    "the signature on the attestation structure verified under the " &
    "public key of the leaf of this report's own bundled chain ("
  SignatureCheckedNoteSuffix* =
    "), so the evidence was produced by that certified key — whether " &
    "that certificate is one to believe is the certificate-chain check's " &
    "question and not this one's"
    ## Split in two so the key's description sits INSIDE the sentence
    ## rather than beside it. A note that named no key would be a claim
    ## a reader cannot check against the chain the same report carries.

  NonAnchorMarker* = "NOT-A-TRUST-ANCHOR"
    ## The literal the mock backend's root subject must contain. Written
    ## out here rather than reached for through the backend's own
    ## constant: a check that compares a value against the constant that
    ## produced it passes however that constant is renamed, and renaming
    ## this one to something that reads like a real root is exactly the
    ## change a verifier must notice.

  MockCertificateMarker* = "reproos.mock-certificate.v1"
    ## Likewise a literal. A mock chain that started spelling itself
    ## ``-----BEGIN CERTIFICATE-----`` would be a chain something might
    ## try to validate.

proc projectEnvelope*(r: AttestationReport): AuthoritativeInputs =
  ## The non-claim half of a report. This is the only function that sees
  ## an ``AttestationReport`` and produces inputs, and it copies no
  ## claim.
  result.tier = r.tier
  result.backend = r.backend
  result.challengeHex = r.challenge
  result.reportDataHex = r.reportData
  result.bindings = r.bindings
  result.bundledCertificates = r.hasBundledCertificates
  result.certificates = r.certificatesForCrossCheck

proc readMockEvidence(r: AttestationReport;
                      inputs: var AuthoritativeInputs): CheckFinding =
  inputs.readerName = MockReaderName
  var ev: MockEvidence
  try:
    ev = parseMockEvidence(authoritativeEvidence(r))
  except MockEvidenceError as err:
    return violated("the mock evidence did not verify: " & err.msg)
  except CatchableError as err:
    return violated("the mock evidence could not be decoded: " & err.msg)
  inputs.reportDataInEvidence = some(ev.reportDataHex)
  # Deliberately not `some(ev.launchMeasurement)`; see the module header.
  inputs.launchMeasurement = none(string)
  satisfied("the evidence is a " & MockEvidenceSchema &
    " document whose message authentication code recomputes under the key " &
    "it publishes in the clear — which establishes that the document is " &
    "well formed and nothing whatever about who wrote it")

proc quoteCoversLaunchRegister(q: Tpm2Quote): bool =
  ## Whether the quote's own selection names the register the launch
  ## measurement is read out of, in the bank the manifest speaks.
  ##
  ## Read off the wire — `selectedPcrs` decodes the selection the TPM
  ## signed — and never off a configured expectation, because the
  ## question is what THIS quote covers and not what some driver was set
  ## up to quote.
  for s in selectedPcrs(q.attest.quote.pcrSelect):
    if s.bank == LaunchMeasurementBank and
       s.index == LaunchMeasurementRegister:
      return true
  false

proc readTpm2Evidence(r: AttestationReport;
                      inputs: var AuthoritativeInputs): CheckFinding =
  ## Read a ``reproos.tpm2-evidence.v1`` composite.
  ##
  ## Every failure below is a VIOLATION rather than an inapplicable
  ## result. A measured-boot report whose evidence could not be read is
  ## not a report about which less is known; it is a report about which
  ## nothing is known, and the only honest verdict on it is a rejection.
  inputs.readerName = Tpm2ReaderName

  var ev: Tpm2Evidence
  try:
    ev = parseTpm2Evidence(authoritativeEvidence(r))
  except Tpm2EvidenceError as err:
    return violated("the measured-boot evidence did not parse: " & err.msg)
  except CatchableError as err:
    return violated("the measured-boot evidence could not be decoded: " &
      err.msg)

  var q: Tpm2Quote
  try:
    q = tpm2EvidenceQuote(ev)
  except Tpm2EvidenceError as err:
    return violated("the attestation structure in this evidence does not " &
      "decode: " & err.msg)
  except CatchableError as err:
    return violated("the attestation structure in this evidence could not " &
      "be read: " & err.msg)

  # The 64 bytes as they appear INSIDE the structure the root of trust
  # produced. `verify.checkReportDataBinding` recomputes the envelope's
  # own from the challenge and the bindings and compares the two, so this
  # is one side of that comparison and never both.
  inputs.reportDataInEvidence = some(bytesToHex(qualifyingData(q)))

  # THE JOIN BETWEEN A CHAIN AND A QUOTE.
  #
  # Until now a bundled chain was walked by one check and the attestation
  # structure was read by another, and nothing connected them: a report
  # could carry a perfectly valid chain for a key that had nothing to do
  # with its evidence, and both checks would pass. That is not a
  # hypothetical — it is the whole of what an evidence forger has to do,
  # because chains are public and quotes are not.
  #
  # So when a chain is bundled, the signature over the attestation
  # structure is verified under the LEAF certificate's public key. What
  # each half then establishes is worth separating: this one says the
  # evidence was produced by the key in that certificate; the chain check
  # says whether that certificate is one this verifier has any reason to
  # believe. Neither is sufficient and the report is refused unless both
  # hold.
  #
  # When no chain is bundled there is no key to check against — a report
  # is not required to carry one, and this build fetches nothing — so the
  # reading says so, through `attestationKeySubject` and through
  # `NoSignatureCheckedNote`. An absent key is recorded as an unanswered
  # question rather than passed over.
  if r.hasBundledCertificates:
    let chain = r.certificatesForCrossCheck
    if chain.len == 0:
      return violated("this report declares a bundled certificate chain " &
        "and carries no element of one, so the key that signed its " &
        "attestation structure cannot be identified")
    var leaf: X509Cert
    try:
      leaf = parseCertificateBytes(chain[0])
    except X509Error as err:
      return violated("the leaf of this report's bundled chain did not " &
        "read as a certificate, so there is no public key to check its " &
        "attestation structure against: " & err.msg)
    if q.signature.sigAlg != TpmAlgEcdsa or
       q.signature.hashAlg != LaunchMeasurementBank:
      return violated("this evidence's attestation structure is signed " &
        "with scheme " & $q.signature.sigAlg & " over " &
        $q.signature.hashAlg & ", and the one public-key operation this " &
        "build performs is ECDSA-P256 over " & $LaunchMeasurementBank &
        "; an algorithm this verifier cannot check is refused rather " &
        "than accepted unchecked")
    var message = newSeq[byte](q.attestBytes.len)
    for i in 0 ..< q.attestBytes.len: message[i] = byte(q.attestBytes[i])
    var rr = newSeq[byte](q.signature.signatureR.len)
    for i in 0 ..< q.signature.signatureR.len:
      rr[i] = byte(q.signature.signatureR[i])
    var ss = newSeq[byte](q.signature.signatureS.len)
    for i in 0 ..< q.signature.signatureS.len:
      ss[i] = byte(q.signature.signatureS[i])
    # Over `attestBytes`, which are the bytes that ARRIVED. Verifying a
    # re-serialisation would make a codec bug into a forgery oracle.
    if not verifyEcdsaSha256Raw(message, rr, ss, leaf.publicKey):
      return violated("the signature on this evidence's attestation " &
        "structure does not verify under the public key of the leaf of " &
        "its own bundled chain (" &
        describeName(leaf.subjectDn, leaf.subjectCn) &
        "); whatever produced this quote, that certified key did not")
    inputs.attestationKeySubject =
      some(describeName(leaf.subjectDn, leaf.subjectCn))

  var log: TcgEventLog
  try:
    log = tpm2EvidenceLog(ev)
  except Tpm2EvidenceError as err:
    return violated("the event log in this evidence does not decode: " &
      err.msg)
  except CatchableError as err:
    return violated("the event log in this evidence could not be read: " &
      err.msg)

  # THE PRECONDITION OF THE WHOLE JOIN. See the module header: a log can
  # claim anything about a register the quote does not cover, and a
  # verifier that read the launch measurement out of such a log would be
  # reading an unsigned number.
  if not quoteCoversLaunchRegister(q):
    var covered: seq[string] = @[]
    for s in selectedPcrs(q.attest.quote.pcrSelect):
      covered.add $s.bank & ":" & $s.index
    return violated("this quote covers " &
      (if covered.len == 0: "no register at all"
       else: covered.join(", ")) &
      ", and not " & $LaunchMeasurementBank & ":" &
      $LaunchMeasurementRegister &
      " — the register a launch measurement is taken from. A log can " &
      "claim any value for a register nothing signed, so the " &
      "measurement is refused rather than read out of it")

  var explains = false
  try:
    explains = explainsQuote(log, q)
  except TcgEventLogError as err:
    return violated("this evidence's event log cannot answer for its own " &
      "attestation structure: " & err.msg)
  except CatchableError as err:
    return violated("this evidence's event log could not be replayed: " &
      err.msg)
  if not explains:
    return violated("replaying this evidence's event log does not " &
      "reproduce the register digest its own attestation structure " &
      "carries, so the log does not describe the boot that was attested " &
      "to and nothing in it may be read as a measurement of this machine")

  var bank: ReplayedBank
  try:
    bank = replayBank(log, LaunchMeasurementBank)
  except TcgEventLogError as err:
    return violated("this evidence's event log carries no " &
      $LaunchMeasurementBank & " bank to read a launch measurement from: " &
      err.msg)
  if bank.pcrs[LaunchMeasurementRegister].state != prExtended:
    # Reachable even after the join succeeds: the quote may cover the
    # register while nothing in the log ever extended it, in which case
    # the register holds its reset value — the same on every machine.
    return violated("nothing in this evidence's event log extended " &
      $LaunchMeasurementBank & ":" & $LaunchMeasurementRegister &
      ", so its value is the reset value every machine shares and says " &
      "nothing about what this one booted")

  inputs.launchMeasurement =
    some(bytesToHex(pcrValue(bank, LaunchMeasurementRegister)))

  satisfied("the evidence is a " & Tpm2EvidenceSchema &
    " composite whose event log REPLAYS to the register digest its own " &
    "attestation structure carries, and whose quote covers " &
    $LaunchMeasurementBank & ":" & $LaunchMeasurementRegister &
    ", so the launch measurement read out of the replay is a value that " &
    "structure speaks for; " &
    (if inputs.attestationKeySubject.isSome:
       SignatureCheckedNotePrefix & inputs.attestationKeySubject.get &
         SignatureCheckedNoteSuffix
     else: NoSignatureCheckedNote))

proc unreadableBackend(backend: AttestationBackend): CheckFinding =
  violated("this build carries no reader for " & ($backend).escape() &
    " evidence, so nothing parsed the only authoritative field this " &
    "report has; a verdict on evidence nothing read would be a verdict " &
    "on nothing")

proc readAuthoritativeEvidence*(r: AttestationReport): EvidenceReading =
  ## Read one report's evidence with the reader for its backend.
  ##
  ## The dispatch is an exhaustive ``case`` over the backend enum rather
  ## than a table something can register into. A registry would be the
  ## seam through which a caller installs a reader that vouches for
  ## anything, which is a verifier bypass wearing a reader's clothes.
  result.inputs = projectEnvelope(r)
  case r.backend
  of abMock:
    result.finding = readMockEvidence(r, result.inputs)
  of abTpm2:
    result.finding = readTpm2Evidence(r, result.inputs)
  of abSevSnp, abTdx:
    result.inputs.readerName = "none"
    result.finding = unreadableBackend(r.backend)

proc describeMockChain*(inputs: AuthoritativeInputs): CheckFinding =
  ## What a bundled mock chain is worth, checked against literals of this
  ## module's own rather than against the backend's constants.
  if inputs.certificates.len < 2:
    return violated("the bundled chain has " & $inputs.certificates.len &
      " element(s); the published non-genuine chain is a leaf, an " &
      "intermediate and a self-signed root")
  for i, cert in inputs.certificates:
    if not cert.startsWith(MockCertificateMarker):
      return violated("element " & $i & " of the bundled chain does not " &
        "begin " & MockCertificateMarker.escape() &
        "; a mock report bundling something that parses as a certificate " &
        "is a mock report offering a chain someone might try to validate")
  let root = inputs.certificates[^1]
  if NonAnchorMarker notin root:
    return violated("the root of the bundled chain does not name itself " &
      NonAnchorMarker.escape() & "; it is " & root.strip().escape())
  satisfied("the bundled chain is the published non-genuine one and " &
    "anchors in a root that names itself " & NonAnchorMarker &
    ", so it vouches for nothing and says so")
