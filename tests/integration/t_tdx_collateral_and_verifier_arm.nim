## Intel's signed collateral verifies, the trusted-computing-base
## evaluation is the vendor's own algorithm, and the verifier's
## trust-domain arm reports what the chain and the evidence actually
## said.
##
## ## The three things this gate exists for
##
## **One.** Seven vendor-signed documents — two vintages of two
## platforms' trusted-computing-base information, two quoting-enclave
## identities, and one identity for the *wrong* enclave — verify under
## the key in the certificate Intel's own service serves, and that
## certificate chains to the one root this build holds. Then every one
## of them stops verifying when a single bit of the signed span moves.
##
## **Two.** The evaluation is Intel's, transcribed from Intel's
## reference implementation, and the corpus exercises both of its
## branches: a part whose module major version is zero, where all
## sixteen component versions are compared, and two parts whose module
## major version is one, where the first two are skipped and a separate
## module identity answers for them instead. The two branches give
## different answers on the same evidence, which is why the choice
## between them is a decision rather than a detail.
##
## **Three, and it is the one this tree has been caught by twice.**
## An integration arm that reports the same thing whatever happened
## underneath is not wired, however much code sits behind it. So the
## last suite runs the whole verifier over a genuine quote and asserts
## that the trust-domain rows *change* with what they are about: the
## chain row passes with the genuine endorsement and fails with the
## fabricated one; the evidence row passes on a genuine quote and fails
## on one with a bit moved; the measurement row passes against a
## manifest carrying this quote's own initial measurement and fails
## against one that does not; and the floor row is a failure when this
## verifier holds no vendor collateral and a pass when it does.
##
## ## Mocking
##
## None. Real Intel-signed documents, real quotes, real curve
## arithmetic.

import std/[base64, options, os, strutils, unittest]

import repro_attest
import repro_attest_verify
import repro_attest_verify/tdx_chain
import repro_attest_verify/tdx_collateral
import repro_attest_verify/tdx_quote

include ./tdx_vectors

# ---------------------------------------------------------------------
# Census
# ---------------------------------------------------------------------

var reachedCollateralKinds: set[TdxCollateralErrorKind] = {}
var reachedCollateralOutcomes: set[TdxCollateralOutcome] = {}
var reachedTcbOutcomes: set[TdxTcbOutcome] = {}
var reachedEnclaveOutcomes: set[EnclaveMatchOutcome] = {}
var reachedCollateralSites: seq[string] = @[]

proc writeCensus() =
  ## Called from the LAST case; see the quote gate's copy for why an
  ## exit procedure could not do it.
  let path = getEnv("REPRO_REFUSAL_CENSUS")
  if path.len == 0: return
  var lines: seq[string] = @[]
  for k in TdxCollateralErrorKind:
    if k in reachedCollateralKinds: lines.add "tdx_collateral:" & $k
  for k in TdxCollateralOutcome:
    if k in reachedCollateralOutcomes: lines.add "tdx_bundle:" & $k
  for k in TdxTcbOutcome:
    if k in reachedTcbOutcomes: lines.add "tdx_tcb:" & $k
  for k in EnclaveMatchOutcome:
    if k in reachedEnclaveOutcomes: lines.add "tdx_enclave:" & $k
  for s in reachedCollateralSites: lines.add "tdx_collateral_site:" & s
  writeFile(path, lines.join("\n") & "\n")



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

var refusalsObserved = 0

template expectCollateralRefusal(want: TdxCollateralErrorKind;
                                 body: untyped) =
  var raised = false
  try:
    body
  except TdxCollateralError as err:
    raised = true
    inc refusalsObserved
    block:
      let marker = TdxCollateralMessage[want] & ": "
      let at = err.msg.find(marker)
      var words: seq[string] = @[]
      if at >= 0:
        for w in err.msg[at + marker.len .. ^1].split(' '):
          if words.len >= 6: break
          words.add w
      let site = $want & "/" & words.join(" ")
      if site notin reachedCollateralSites: reachedCollateralSites.add site
    check err.kind == want
    check TdxCollateralMessage[want] in err.msg
    for other in TdxCollateralErrorKind:
      if other == want: continue
      check TdxCollateralMessage[other] notin err.msg
    reachedCollateralKinds.incl want
  check raised

const
  Now = 1_790_294_400'i64                 ## 2026-09-25T00:00:00Z.
  NowMs = Now * 1000'i64

let signerDer = bytesOfHex(IntelTcbSigningCertDerHex)
let rootDer = bytesOfHex(IntelSgxRootCaDerHex)
let signerKey = parseCertificate(signerDer).publicKey

type
  Document = object
    label: string
    body: string
    member: string

let documents = @[
  Document(label: "go-tdx-guest 2023 platform document, fmspc 50806f000000",
    body: GtgTcbInfoSprJson, member: TcbInfoMemberName),
  Document(label: "go-tdx-guest 2026 platform document, fmspc 90c06f000000",
    body: GtgTcbInfoEmrJson, member: TcbInfoMemberName),
  Document(label: "go-tdx-guest 2023 quoting-enclave identity",
    body: GtgQeIdentityJson, member: EnclaveIdentityMemberName),
  Document(label: "Intel's service, platform document 50806f000000",
    body: PcsTcbInfoSprJson, member: TcbInfoMemberName),
  Document(label: "Intel's service, platform document 90c06f000000",
    body: PcsTcbInfoEmrJson, member: TcbInfoMemberName),
  Document(label: "Intel's service, trust-domain quoting-enclave identity",
    body: PcsTdxQeIdentityJson, member: EnclaveIdentityMemberName),
  Document(label: "Intel's service, SGX quoting-enclave identity",
    body: PcsSgxQeIdentityJson, member: EnclaveIdentityMemberName)]

type
  Part = object
    label: string
    quote: TdxQuote
    platform: IntelPlatformDescription
    tcbInfoVintages: seq[string]
    expectedStatus: string
    expectedOutcome: TdxCollateralOutcome

proc quoteOf(hex: string; trim: int): TdxQuote =
  var raw = bytesOfHex(hex)
  if trim > 0: raw = raw[0 ..< trim]
  parseTdxQuote(raw)

proc platformOf(q: TdxQuote): IntelPlatformDescription =
  intelPlatformOf(parseCertificate(q.pckChain[0]))

let sprQuote = quoteOf(GoTdxGuestSprQuoteHex, 4935)
let gtgV5Quote = quoteOf(GoTdxGuestEmrQuoteHex, 0)
let trusteeQuote = quoteOf(TrusteeV5QuoteHex, 0)

let parts = @[
  Part(label: "Sapphire Rapids, module major version 0",
    quote: sprQuote, platform: platformOf(sprQuote),
    tcbInfoVintages: @[GtgTcbInfoSprJson, PcsTcbInfoSprJson],
    expectedStatus: "", expectedOutcome: tcoNoLevelCoversThisPlatform),
  Part(label: "go-tdx-guest version 5, module major version 1",
    quote: gtgV5Quote, platform: platformOf(gtgV5Quote),
    tcbInfoVintages: @[GtgTcbInfoEmrJson, PcsTcbInfoEmrJson],
    expectedStatus: TdxStatusUpToDate, expectedOutcome: tcoEstablished),
  Part(label: "trustee version 5, module major version 1",
    quote: trusteeQuote, platform: platformOf(trusteeQuote),
    tcbInfoVintages: @[GtgTcbInfoEmrJson, PcsTcbInfoEmrJson],
    expectedStatus: "", expectedOutcome: tcoNoLevelCoversThisPlatform)]

proc bundleFor(tcbInfo, identity: string): TdxCollateralBundle =
  TdxCollateralBundle(tcbInfoJson: tcbInfo, enclaveIdentityJson: identity,
    signerDer: signerDer, signerIssuerDer: rootDer)

# ---------------------------------------------------------------------

suite "the vendor's signature over its own collateral":

  test "t_tdx_collateral_messages_are_distinguishable":
    check tdxCollateralMessagesAreDistinguishable()

  test "t_tdx_the_collateral_signer_chains_to_the_one_pinned_root":
    let signer = parseCertificate(signerDer)
    let root = parseCertificate(rootDer)
    check signer.subjectCn == "Intel SGX TCB Signing"
    check signer.issuerDn == root.subjectDn
    check signer.signatureVerifiesUnder(root.publicKey)
    check root.signatureVerifiesUnder(root.publicKey)
    # The SAME root the endorsement chain ends at, and there is one.
    check intelRootFor(root.publicKey) == 0
    check IntelRootKeys.len == 1
    check intelRootFor(signer.publicKey) < 0

  test "t_tdx_all_seven_vendor_documents_verify_under_that_key":
    var verified = 0
    var spans: seq[int] = @[]
    for d in documents:
      checkpoint d.label
      let v = verifyCollateral(d.body, d.member, signerKey)
      check v.isVerified
      check v.memberName == d.member
      check v.signature.len == CollateralSignatureLen
      check v.signedSpan.len > 0
      spans.add v.signedSpan.len
      # The span is the document's own bytes, lifted verbatim.
      var text = ""
      for b in v.signedSpan: text.add char(b)
      check text in d.body
      check text[0] == '{'
      check text[^1] == '}'
      inc verified
    check verified == 7
    # Seven distinct documents, so a loop reading one of them seven
    # times is visible.
    for i in 0 ..< spans.len:
      for j in 0 ..< spans.len:
        if i == j: continue
        check documents[i].body != documents[j].body

  test "t_tdx_one_bit_in_a_signed_span_stops_it_verifying":
    # A sweep over every document, and for each one a byte inside the
    # span it covers rather than a byte anywhere in the file.
    var mutations = 0
    for d in documents:
      checkpoint d.label
      let good = verifyCollateral(d.body, d.member, signerKey)
      var text = ""
      for b in good.signedSpan: text.add char(b)
      let at = d.body.find(text)
      check at >= 0
      for start in [10, text.len div 2, text.len - 8]:
        # Move one bit of a byte that is NOT structural. A brace, a
        # quote or a backslash changes where the span ENDS, which is a
        # different experiment: this one is about the signature, so the
        # document has to stay the shape it was.
        var offset = start
        while offset < text.len - 1 and
              text[offset] in {'{', '}', '"', '\\', '[', ']', ':', ','}:
          inc offset
        var bent = d.body
        bent[at + offset] = char(byte(bent[at + offset]) xor 0x01'u8)
        check bent.len == d.body.len
        let v = verifyCollateral(bent, d.member, signerKey)
        check not v.isVerified
        # And it is the SPAN that moved, not the signature.
        check hexOfBytes(v.signature) == hexOfBytes(good.signature)
        check hexOfBytes(v.signedSpan) != hexOfBytes(good.signedSpan)
        inc mutations
    check mutations == 21

  test "t_tdx_a_document_signed_by_somebody_else_does_not_verify":
    # The signer's own key, and every other key in reach, so the
    # positive above is not satisfied by any key at all.
    let d = documents[0]
    check verifyCollateral(d.body, d.member, signerKey).isVerified
    for (label, key) in {
        "the vendor's root": parseCertificate(rootDer).publicKey,
        "a provisioning certificate":
          parseCertificate(sprQuote.pckChain[0]).publicKey,
        "the fabricated root":
          parseCertificate(bytesOfHex(ImpostorRootDerHex)).publicKey,
        "Intel's own sample root":
          parseCertificate(bytesOfHex(IntelSampleRootDerHex)).publicKey}:
      checkpoint label
      check not verifyCollateral(d.body, d.member, key).isVerified

  test "t_tdx_the_document_reader_cannot_be_reached_without_a_signature":
    # `VerifiedCollateral`'s payload is not exported, so a record built
    # outside the module carries no document — and every reader refuses
    # it by name. This is the barrier the module's header claims, and
    # it is asserted rather than described.
    let unsigned = VerifiedCollateral(memberName: TcbInfoMemberName)
    check documentOf(unsigned).len == 0
    check not unsigned.isVerified
    var unsignedMsg = ""
    try:
      discard parseTdxTcbInfo(unsigned)
    except TdxCollateralError as err:
      unsignedMsg = err.msg
    expectCollateralRefusal(tceDocumentDoesNotDecode):
      discard parseTdxTcbInfo(unsigned)
    # The KIND alone is not enough: with the payload check deleted the
    # empty span reaches the decoder and earns the SAME kind from the
    # rule below it. The sentence is what says which rule fired.
    check "whose signature was never established" in unsignedMsg
    check "only `verifyCollateral` produces one" in unsignedMsg
    # A record that DID verify, but for the other member, is refused
    # too: a reader that read whatever it was handed would read an
    # enclave identity as a platform document.
    let identity = verifyCollateral(PcsTdxQeIdentityJson,
      EnclaveIdentityMemberName, signerKey)
    check identity.isVerified
    expectCollateralRefusal(tceDocumentDoesNotDecode):
      discard parseTdxTcbInfo(identity)

  test "t_tdx_every_locating_rule_refuses_its_own_input":
    let good = PcsTcbInfoSprJson
    let before = refusalsObserved
    expectCollateralRefusal(tceEmptyDocument):
      discard signedSpanOf("", TcbInfoMemberName)
    expectCollateralRefusal(tceSignedMemberNotFound):
      discard signedSpanOf(good, "notAMemberOfThisDocument")
    expectCollateralRefusal(tceSignedMemberIsNotAnObject):
      discard signedSpanOf(good, "id")
    expectCollateralRefusal(tceSignedMemberUnterminated):
      discard signedSpanOf(good[0 ..< good.len div 2], TcbInfoMemberName)
    expectCollateralRefusal(tceSignatureMemberNotFound):
      discard detachedSignatureOf("{\"tcbInfo\":{}}")
    expectCollateralRefusal(tceSignatureWrongWidth):
      discard detachedSignatureOf("{\"signature\":\"abcd\"}")
    expectCollateralRefusal(tceSignatureIsNotHexadecimal):
      discard detachedSignatureOf("{\"signature\":" &
        repeat("\"zz", 1) & repeat("zz", 63) & "\"}")
    expectCollateralRefusal(tceSignatureIsNotHexadecimal):
      discard detachedSignatureOf("{\"signature\":12345}")
    check refusalsObserved == before + 8

  test "t_tdx_a_member_name_appearing_as_a_value_is_not_a_member":
    # The locator scans for the quoted name and then REQUIRES a colon
    # after it. Without that requirement the first occurrence wins, and
    # the first occurrence may be a value rather than a member — so the
    # span would be taken from the wrong place in a document whose
    # signature verifies over the right one.
    #
    # No genuine document carries the name anywhere but as a member, so
    # the rule had no input until this one was built. Everything after
    # the decoy is the vendor's own document, byte for byte.
    let genuine = verifyCollateral(PcsTcbInfoEmrJson, TcbInfoMemberName,
      signerKey)
    var span = ""
    for b in genuine.signedSpan: span.add char(b)
    let decoyed = "{\"note\":\"tcbInfo\"," &
      PcsTcbInfoEmrJson[1 .. ^1]
    check decoyed.find("\"tcbInfo\"") <
      decoyed.find("\"tcbInfo\":")
    var decoySpan = ""
    for b in signedSpanOf(decoyed, TcbInfoMemberName):
      decoySpan.add char(b)
    check decoySpan == span
    # And it still verifies, because the bytes the signature covers are
    # the ones the locator found.
    let v = verifyCollateral(decoyed, TcbInfoMemberName, signerKey)
    check v.isVerified
    check parseTdxTcbInfo(v).fmspcHex == "90c06f000000"

  test "t_tdx_a_brace_inside_a_string_does_not_close_the_span":
    # The matcher knows about strings and about escapes, and a document
    # that did not need it would not prove that. So the property is
    # asserted on a document built for it, and then on the vendor's,
    # whose advisory identifiers really do carry punctuation.
    let doc = "{\"tcbInfo\":{\"a\":\"}}}\",\"b\":\"\\\"}\"},\"signature\":\"" &
      repeat("ab", 64) & "\"}"
    var span = ""
    for b in signedSpanOf(doc, TcbInfoMemberName): span.add char(b)
    check span == "{\"a\":\"}}}\",\"b\":\"\\\"}\"}"
    # And a naive matcher would have stopped at the first `}`.
    check span.len > doc.find('}') - doc.find('{')

# ---------------------------------------------------------------------

suite "what the vendor's documents say":

  test "t_tdx_the_platform_documents_are_read_as_published":
    let expected = @[
      (GtgTcbInfoSprJson, "50806f000000", 3, 2, 0, "2023-06-18T08:42:58Z"),
      (GtgTcbInfoEmrJson, "90c06f000000", 3, 3, 2, "2026-02-01T14:49:26Z"),
      (PcsTcbInfoSprJson, "50806f000000", 3, 6, 2, "2026-09-21T04:19:36Z"),
      (PcsTcbInfoEmrJson, "90c06f000000", 3, 4, 2, "2026-09-21T03:25:24Z")]
    var levelCounts: seq[int] = @[]
    for (body, fmspc, version, levels, modules, issued) in expected:
      checkpoint fmspc & " issued " & issued
      let info = parseTdxTcbInfo(
        verifyCollateral(body, TcbInfoMemberName, signerKey))
      check info.id == TdxTcbInfoIdTdx
      check info.version == version
      check info.fmspcHex == fmspc
      check info.issueDate == issued
      check info.levels.len == levels
      check info.moduleIdentities.len == modules
      for lv in info.levels:
        check lv.status in PlatformLevelStatuses
        check lv.pceSvn >= 0
      levelCounts.add levels
    # Four documents with four DIFFERENT level counts. A walk that
    # stopped after the first level, or never reached a second, is
    # visible against this corpus and would not be against one where
    # every document had the same shape.
    check levelCounts == @[2, 3, 6, 4]

  test "t_tdx_the_enclave_identities_are_read_as_published":
    let tdQe = parseEnclaveIdentity(verifyCollateral(PcsTdxQeIdentityJson,
      EnclaveIdentityMemberName, signerKey))
    check tdQe.id == EnclaveIdentityIdTdQe
    check tdQe.isvProdId == 2
    check tdQe.levels.len == 1
    check tdQe.levels[0].status == TdxStatusUpToDate
    let sgxQe = parseEnclaveIdentity(verifyCollateral(PcsSgxQeIdentityJson,
      EnclaveIdentityMemberName, signerKey))
    check sgxQe.id == "QE"
    check sgxQe.isvProdId == 1
    # SIX levels, five of them out of date. The only non-degenerate
    # level list in the corpus, and the reason it is here.
    check sgxQe.levels.len == 6
    var outOfDate = 0
    for lv in sgxQe.levels:
      if lv.status == TdxStatusOutOfDate: inc outOfDate
    check outOfDate == 5
    check sgxQe.levels[0].status == TdxStatusUpToDate
    check sgxQe.mrSignerHex != tdQe.mrSignerHex

  test "t_tdx_the_quoting_enclave_must_be_the_one_the_identity_describes":
    let tdQe = parseEnclaveIdentity(verifyCollateral(PcsTdxQeIdentityJson,
      EnclaveIdentityMemberName, signerKey))
    let sgxQe = parseEnclaveIdentity(verifyCollateral(PcsSgxQeIdentityJson,
      EnclaveIdentityMemberName, signerKey))
    for p in parts:
      checkpoint p.label
      let r = p.quote.qeReport
      let v = quotingEnclaveMatches(tdQe, hexOfBytes(r.mrSigner),
        int(r.isvProdId), toHex(int(r.miscSelect), 8).toLowerAscii,
        hexOfBytes(r.attributes))
      check v.matches
      reachedEnclaveOutcomes.incl v.outcome
      # The vendor's OWN identity for its other quoting enclave is a
      # perfectly valid signed document about a different enclave, and
      # the rule that notices has a real input because of it.
      let w = quotingEnclaveMatches(sgxQe, hexOfBytes(r.mrSigner),
        int(r.isvProdId), toHex(int(r.miscSelect), 8).toLowerAscii,
        hexOfBytes(r.attributes))
      check not w.matches
      check w.outcome == emoMeasurerDisagrees
      reachedEnclaveOutcomes.incl w.outcome
    # The three other ways it can disagree, each over the genuine
    # identity with one input moved.
    let r = parts[0].quote.qeReport
    let p = quotingEnclaveMatches(tdQe, hexOfBytes(r.mrSigner),
      int(r.isvProdId) + 1, toHex(int(r.miscSelect), 8).toLowerAscii,
      hexOfBytes(r.attributes))
    check p.outcome == emoProductDisagrees
    reachedEnclaveOutcomes.incl p.outcome
    let m = quotingEnclaveMatches(tdQe, hexOfBytes(r.mrSigner),
      int(r.isvProdId), "ffffffff", hexOfBytes(r.attributes))
    check m.outcome == emoMiscSelectDisagrees
    reachedEnclaveOutcomes.incl m.outcome
    var attrs = hexOfBytes(r.attributes)
    attrs[1] = 'a'
    let a = quotingEnclaveMatches(tdQe, hexOfBytes(r.mrSigner),
      int(r.isvProdId), toHex(int(r.miscSelect), 8).toLowerAscii, attrs)
    check a.outcome == emoAttributesDisagrees
    reachedEnclaveOutcomes.incl a.outcome
    var missingOutcome: seq[string] = @[]
    for k in EnclaveMatchOutcome:
      if k notin reachedEnclaveOutcomes: missingOutcome.add $k
    check missingOutcome.len == 0

# ---------------------------------------------------------------------

suite "the vendor's evaluation":

  test "t_tdx_both_branches_of_the_module_rule_are_exercised":
    # The branch is decided by one byte of the report and by nothing
    # else, and the two branches compare different numbers of
    # components. Both are in the corpus and both are asserted.
    var skips: seq[int] = @[]
    for p in parts:
      let info = parseTdxTcbInfo(verifyCollateral(p.tcbInfoVintages[1],
        TcbInfoMemberName, signerKey))
      var svns: seq[int] = @[]
      for b in p.quote.body.teeTcbSvn: svns.add int(b)
      var comps: seq[int] = @[]
      for c in p.platform.tcb.components: comps.add c
      let identity = parseEnclaveIdentity(verifyCollateral(
        PcsTdxQeIdentityJson, EnclaveIdentityMemberName, signerKey))
      let e = evaluateTdxTcb(info, comps, p.platform.tcb.pceSvn, svns,
        int(p.quote.qeReport.isvSvn), identity, true)
      reachedTcbOutcomes.incl e.outcome
      check e.skippedLeadingComponents ==
        (if svns[TdxModuleMajorSvnIndex] > 0: 2 else: 0)
      if e.skippedLeadingComponents notin skips:
        skips.add e.skippedLeadingComponents
      if svns[TdxModuleMajorSvnIndex] > 0 and e.isDetermined:
        check e.moduleId == moduleIdFor(svns[TdxModuleMajorSvnIndex])
        check e.moduleId == "TDX_01"
      if svns[TdxModuleMajorSvnIndex] == 0:
        check e.moduleId.len == 0
    check skips.len == 2
    check 0 in skips
    check 2 in skips

  test "t_tdx_each_part_gets_the_status_the_vendor_s_document_implies":
    # The values, pinned, against both vintages of the vendor's
    # document for each part — so a build that read one of them and
    # ignored the other is visible.
    var evaluated = 0
    var outcomes: seq[TdxCollateralOutcome] = @[]
    for p in parts:
      for vintage in p.tcbInfoVintages:
        checkpoint p.label
        let v = establishTdxTcbStatus(
          bundleFor(vintage, PcsTdxQeIdentityJson), p.quote, p.platform)
        check v.outcome == p.expectedOutcome
        check v.status == p.expectedStatus
        reachedCollateralOutcomes.incl v.outcome
        if v.outcome notin outcomes: outcomes.add v.outcome
        if v.isEstablished:
          # A report carrying two version arrays is evaluated twice, and
          # the second answer is reported separately. A build that
          # evaluated one array twice would still fill both fields, so
          # the case pins the arrays' own difference as well.
          check p.quote.body.hasPreservedTcb
          check v.currentStatus.len > 0
          check v.launchStatus == TdxStatusUpToDate
        else:
          check v.status.len == 0
        inc evaluated
    check evaluated == 6
    # Two different outcomes over three parts: a corpus in which every
    # part answered the same way would exercise one path.
    check outcomes.len == 2

  test "t_tdx_the_relaunch_rule_is_the_vendor_s":
    # Reachable only for a report carrying two version arrays, and the
    # corpus has one whose arrays DIFFER and one whose arrays are the
    # same — so "was the second array read at all" is answerable.
    check gtgV5Quote.body.hasPreservedTcb
    check trusteeQuote.body.hasPreservedTcb
    check not sprQuote.body.hasPreservedTcb
    check hexOfBytes(gtgV5Quote.body.teeTcbSvn2) !=
      hexOfBytes(gtgV5Quote.body.teeTcbSvn)
    check hexOfBytes(trusteeQuote.body.teeTcbSvn2) ==
      hexOfBytes(trusteeQuote.body.teeTcbSvn)
    # The rule itself, over every pair the vendor's statuses can form.
    check checkForRelaunch(TdxStatusOutOfDate, TdxStatusUpToDate) ==
      TdxStatusTdRelaunchAdvised
    check checkForRelaunch(TdxStatusOutOfDate,
      TdxStatusConfigurationNeeded) ==
      TdxStatusTdRelaunchAdvisedConfigurationNeeded
    check checkForRelaunch(TdxStatusOutOfDateConfigurationNeeded,
      TdxStatusUpToDate) == TdxStatusTdRelaunchAdvisedConfigurationNeeded
    check checkForRelaunch(TdxStatusOutOfDate, TdxStatusOutOfDate) ==
      TdxStatusOutOfDate
    check checkForRelaunch(TdxStatusUpToDate, TdxStatusUpToDate) ==
      TdxStatusUpToDate
    check checkForRelaunch(TdxStatusUpToDate, TdxStatusOutOfDate) ==
      TdxStatusUpToDate
    check checkForRelaunch(TdxStatusRevoked, TdxStatusUpToDate) ==
      TdxStatusRevoked

  test "t_tdx_a_component_can_only_make_the_platform_s_verdict_worse":
    # Convergence, over the statuses the vendor's own documents carry.
    check convergeTcbStatuses(TdxStatusUpToDate, []) == TdxStatusUpToDate
    check convergeTcbStatuses(TdxStatusUpToDate,
      [TdxStatusUpToDate]) == TdxStatusUpToDate
    check convergeTcbStatuses(TdxStatusUpToDate,
      [TdxStatusOutOfDate]) == TdxStatusOutOfDate
    check convergeTcbStatuses(TdxStatusSwHardeningNeeded,
      [TdxStatusOutOfDate]) == TdxStatusOutOfDate
    check convergeTcbStatuses(TdxStatusConfigurationNeeded,
      [TdxStatusOutOfDate]) == TdxStatusOutOfDateConfigurationNeeded
    check convergeTcbStatuses(TdxStatusConfigurationAndSwHardeningNeeded,
      [TdxStatusOutOfDate]) == TdxStatusOutOfDateConfigurationNeeded
    check convergeTcbStatuses(TdxStatusUpToDate,
      [TdxStatusRevoked]) == TdxStatusRevoked
    check convergeTcbStatuses(TdxStatusOutOfDate,
      [TdxStatusUpToDate]) == TdxStatusOutOfDate
    # And it really is reachable through the evaluation: the vendor's
    # own module identity for this part publishes an out-of-date level,
    # and a report at that version converges the platform's UpToDate
    # down to it.
    let info = parseTdxTcbInfo(verifyCollateral(PcsTcbInfoEmrJson,
      TcbInfoMemberName, signerKey))
    let identity = parseEnclaveIdentity(verifyCollateral(
      PcsTdxQeIdentityJson, EnclaveIdentityMemberName, signerKey))
    var comps: seq[int] = @[]
    for c in parts[1].platform.tcb.components: comps.add c
    var svns: seq[int] = @[]
    for b in gtgV5Quote.body.teeTcbSvn: svns.add int(b)
    let asPublished = evaluateTdxTcb(info, comps,
      parts[1].platform.tcb.pceSvn, svns,
      int(gtgV5Quote.qeReport.isvSvn), identity, true)
    check asPublished.status == TdxStatusUpToDate
    check asPublished.componentStatuses == @[TdxStatusUpToDate,
      TdxStatusUpToDate]
    # The same platform with an older module: the vendor publishes
    # `TDX_01` levels at 11, 6, 4 and 2, and 6 is `OutOfDate`.
    var older = svns
    older[TdxModuleMinorSvnIndex] = 6
    let demoted = evaluateTdxTcb(info, comps,
      parts[1].platform.tcb.pceSvn, older,
      int(gtgV5Quote.qeReport.isvSvn), identity, true)
    check demoted.platformStatus == TdxStatusUpToDate
    check TdxStatusOutOfDate in demoted.componentStatuses
    check demoted.status == TdxStatusOutOfDate

  test "t_tdx_four_rules_the_mutation_table_found_with_no_input":
    # Each of these held as code and was never asked a question this
    # corpus could answer. The inputs are query points over the
    # vendor's own genuine documents; the documents are not touched.
    let info = parseTdxTcbInfo(verifyCollateral(PcsTcbInfoEmrJson,
      TcbInfoMemberName, signerKey))
    let identity = parseEnclaveIdentity(verifyCollateral(
      PcsTdxQeIdentityJson, EnclaveIdentityMemberName, signerKey))
    var comps: seq[int] = @[]
    for c in parts[1].platform.tcb.components: comps.add c
    var svns: seq[int] = @[]
    for b in gtgV5Quote.body.teeTcbSvn: svns.add int(b)
    let qeSvn = int(gtgV5Quote.qeReport.isvSvn)
    let pceSvn = parts[1].platform.tcb.pceSvn

    # 1. The configuration enclave's version is compared against the
    #    level. Every part in the corpus meets it or fails the
    #    component comparison first, so the rule had no input; the
    #    level it would otherwise match states 13 and this asks at 12.
    check info.levels[0].pceSvn == 13
    check pceSvn == 13
    let atFloor = evaluateTdxTcb(info, comps, 13, svns, qeSvn,
      identity, true)
    check atFloor.isDetermined
    check atFloor.levelIndex == 0
    let belowFloor = evaluateTdxTcb(info, comps, 12, svns, qeSvn,
      identity, true)
    # A different level, and a different ANSWER: three of the four this
    # vendor publishes for this platform state 13, and the fourth —
    # which states 5 — is out of date. So the comparison is not merely
    # made, it decides.
    check belowFloor.levelIndex == 3
    check belowFloor.isDetermined
    check atFloor.platformStatus == TdxStatusUpToDate
    check belowFloor.platformStatus == TdxStatusOutOfDate
    check belowFloor.status != atFloor.status

    # 2. The module identity is named the way the vendor names it. The
    #    only version in the corpus is 1, whose two hexadecimal digits
    #    carry no letter, so a build that lower-cased the name produced
    #    the same string. Asked at a version that does.
    check moduleIdFor(1) == "TDX_01"
    check moduleIdFor(10) == "TDX_0A"
    check moduleIdFor(255) == "TDX_FF"
    var letteredVersion = svns
    letteredVersion[TdxModuleMajorSvnIndex] = 10
    let lettered = evaluateTdxTcb(info, comps, pceSvn, letteredVersion,
      qeSvn, identity, true)
    check lettered.outcome == ttoModuleIdentityNotPublished
    check "TDX_0A" in lettered.detail
    reachedTcbOutcomes.incl lettered.outcome

    # 3. The second version array is READ, and it is the second one.
    #    Both arrays of both wider reports answer alike in this corpus,
    #    so a build that evaluated the first one twice agreed with one
    #    that evaluated both. Asked at a launch version the vendor
    #    calls out of date and a current one it calls up to date, which
    #    is the shape the relaunch rule exists for.
    var launchOld = svns
    launchOld[TdxModuleMinorSvnIndex] = 6
    let launchVerdict = evaluateTdxTcb(info, comps, pceSvn, launchOld,
      qeSvn, identity, true)
    let currentVerdict = evaluateTdxTcb(info, comps, pceSvn, svns,
      qeSvn, identity, true)
    check launchVerdict.status == TdxStatusOutOfDate
    check currentVerdict.status == TdxStatusUpToDate
    check checkForRelaunch(launchVerdict.status, currentVerdict.status) ==
      TdxStatusTdRelaunchAdvised
    # …and reading the launch array twice would say something else.
    check checkForRelaunch(launchVerdict.status, launchVerdict.status) ==
      TdxStatusOutOfDate

    # 3b. …and the same, THROUGH the bundle, because the rule that
    #     reads the second array lives there and a case that evaluates
    #     twice from here never touches it. The report is built in this
    #     gate rather than mutated on the wire: the two arrays have to
    #     differ in their ANSWER, and editing them in a quote's bytes
    #     would break the signature that quote's reader checks.
    var twoArrays = gtgV5Quote
    twoArrays.body.teeTcbSvn[TdxModuleMinorSvnIndex] = 6'u8
    twoArrays.body.teeTcbSvn2[TdxModuleMinorSvnIndex] = 13'u8
    check twoArrays.body.hasPreservedTcb
    let relaunch = establishTdxTcbStatus(
      bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson), twoArrays,
      platformOf(gtgV5Quote))
    check relaunch.isEstablished
    check relaunch.launchStatus == TdxStatusOutOfDate
    check relaunch.currentStatus == TdxStatusUpToDate
    check relaunch.relaunchApplied
    check relaunch.status == TdxStatusTdRelaunchAdvised
    reachedCollateralOutcomes.incl relaunch.outcome

    # 4. The collateral signer verifies under its issuer. Nothing in
    #    the corpus was a signer the root had not signed, so the rule
    #    had no input; one moved bit gives it one.
    var bentSigner = signerDer
    bentSigner[bentSigner.len - 10] = bentSigner[bentSigner.len - 10] xor
      0x08'u8
    check parseCertificate(bentSigner).publicKey ==
      parseCertificate(signerDer).publicKey
    var b = bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson)
    b.signerDer = bentSigner
    let v = establishTdxTcbStatus(b, gtgV5Quote, platformOf(gtgV5Quote))
    check v.outcome == tcoSignerChainIsNotIntels
    check "does not verify under" in v.detail
    reachedCollateralOutcomes.incl v.outcome

  test "t_tdx_every_bundle_refusal_has_an_input":
    let good = parts[1]
    var outcomes = 0

    # The platform document is for a different part.
    block:
      let v = establishTdxTcbStatus(
        bundleFor(PcsTcbInfoSprJson, PcsTdxQeIdentityJson),
        good.quote, good.platform)
      check v.outcome == tcoTcbInfoIsNotForThisPlatform
      check "50806f000000" in v.detail
      check "90c06f000000" in v.detail
      reachedCollateralOutcomes.incl v.outcome
      inc outcomes

    # The identity document describes the vendor's OTHER enclave.
    block:
      let v = establishTdxTcbStatus(
        bundleFor(PcsTcbInfoEmrJson, PcsSgxQeIdentityJson),
        good.quote, good.platform)
      check v.outcome == tcoEnclaveIdentityIsNotForTrustDomainQuoting
      check "\"QE\"" in v.detail
      reachedCollateralOutcomes.incl v.outcome
      inc outcomes

    # The signing chain is not the vendor's.
    block:
      var b = bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson)
      b.signerIssuerDer = bytesOfHex(ImpostorRootDerHex)
      let v = establishTdxTcbStatus(b, good.quote, good.platform)
      check v.outcome == tcoSignerChainIsNotIntels
      check "not the one root this build was built with" in v.detail
      reachedCollateralOutcomes.incl v.outcome
      inc outcomes

    # A platform document the vendor's signer did not sign.
    block:
      var b = bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson)
      b.tcbInfoJson = b.tcbInfoJson.replace("\"UpToDate\"", "\"OutOfDate\"")
      check b.tcbInfoJson != PcsTcbInfoEmrJson
      let v = establishTdxTcbStatus(b, good.quote, good.platform)
      check v.outcome == tcoTcbInfoNotSignedByTheSigner
      reachedCollateralOutcomes.incl v.outcome
      inc outcomes

    # An identity document the vendor's signer did not sign.
    block:
      var b = bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson)
      b.enclaveIdentityJson =
        b.enclaveIdentityJson.replace("\"UpToDate\"", "\"OutOfDate\"")
      let v = establishTdxTcbStatus(b, good.quote, good.platform)
      check v.outcome == tcoEnclaveIdentityNotSignedByTheSigner
      reachedCollateralOutcomes.incl v.outcome
      inc outcomes

    # No level covers the part. A GENUINE outcome: the Sapphire Rapids
    # part is below every level the vendor publishes for its platform,
    # under both vintages, and this is what a verifier says about it.
    block:
      let v = establishTdxTcbStatus(
        bundleFor(PcsTcbInfoSprJson, PcsTdxQeIdentityJson),
        sprQuote, parts[0].platform)
      check v.outcome == tcoNoLevelCoversThisPlatform
      check "none of the 6 levels" in v.detail
      reachedCollateralOutcomes.incl v.outcome
      inc outcomes

    # A quoting enclave the identity does not describe, reached through
    # the bundle rather than through the rule alone.
    block:
      var q = good.quote
      q.qeReport.mrSigner[0] = q.qeReport.mrSigner[0] xor 0xff'u8
      let v = establishTdxTcbStatus(
        bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson), q,
        good.platform)
      check v.outcome == tcoQuotingEnclaveDisagreesWithItsIdentity
      reachedCollateralOutcomes.incl v.outcome
      inc outcomes

    check outcomes == 7

  test "t_tdx_the_three_remaining_evaluation_refusals_have_inputs":
    # The three the case above sets aside, each given an input here so
    # that none of them is a rule with no reachable input.
    let info = parseTdxTcbInfo(verifyCollateral(PcsTcbInfoEmrJson,
      TcbInfoMemberName, signerKey))
    let identity = parseEnclaveIdentity(verifyCollateral(
      PcsTdxQeIdentityJson, EnclaveIdentityMemberName, signerKey))
    var comps: seq[int] = @[]
    for c in parts[1].platform.tcb.components: comps.add c
    var svns: seq[int] = @[]
    for b in gtgV5Quote.body.teeTcbSvn: svns.add int(b)
    let pceSvn = parts[1].platform.tcb.pceSvn

    # A module major version for which the vendor publishes no identity.
    var unknownModule = svns
    unknownModule[TdxModuleMajorSvnIndex] = 9
    let a = evaluateTdxTcb(info, comps, pceSvn, unknownModule,
      int(gtgV5Quote.qeReport.isvSvn), identity, true)
    check a.outcome == ttoModuleIdentityNotPublished
    check "TDX_09" in a.detail
    reachedTcbOutcomes.incl a.outcome

    # A module minor version below every level the identity publishes.
    var oldModule = svns
    oldModule[TdxModuleMinorSvnIndex] = 1
    let b = evaluateTdxTcb(info, comps, pceSvn, oldModule,
      int(gtgV5Quote.qeReport.isvSvn), identity, true)
    check b.outcome == ttoNoModuleLevelCoversThisVersion
    reachedTcbOutcomes.incl b.outcome

    # A quoting enclave below every level ITS identity publishes.
    let c = evaluateTdxTcb(info, comps, pceSvn, svns, 0, identity, true)
    check c.outcome == ttoNoEnclaveLevelCoversThisVersion
    reachedTcbOutcomes.incl c.outcome

    var missing: seq[string] = @[]
    for k in TdxTcbOutcome:
      if k notin reachedTcbOutcomes: missing.add $k
    check missing.len == 0

# ---------------------------------------------------------------------
# The verifier's trust-domain arm
# ---------------------------------------------------------------------

const
  TdxPolicy = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["cvm"]
backends = ["tdx"]
allow_mock = false

[measurements]
manifests = []
require_certificates = true

[freshness]
max_challenge_age_seconds = 0
require_challenge = false

[tcb]
allow_grace_days = 0

[tcb.tdx]
min_tcb_status = "UpToDate"
"""

  Challenge = "a1b2c3d4e5f60718293a4b5c6d7e8f90" &
              "0f1e2d3c4b5a69788796a5b4c3d2e1f0"

proc base64Of(b: openArray[byte]): string =
  ## The encoder the report envelope's own reader inverts, reached
  ## through the library rather than written again here.
  var s = newString(b.len)
  for i in 0 ..< b.len: s[i] = char(b[i])
  base64.encode(s)

proc reportFor(q: TdxQuote; chain: seq[seq[byte]];
               evidence: seq[byte]): string =
  var certs: seq[string] = @[]
  for der in chain: certs.add base64Of(der)
  renderAttestationReport(AttestationReport(
    tier: atCvm, backend: abTdx,
    timestampInformational: "2026-09-25T00:00:00Z",
    challenge: Challenge,
    reportData: reportDataHexFor(
      ReportBindings(purpose: bpAttest), Challenge),
    bindings: ReportBindings(purpose: bpAttest),
    evidence: base64Of(evidence),
    certificates: some(certs),
    claims: UnverifiedClaims(
      unverifiedGeneration: "gen-2026-09-25-0001",
      unverifiedConfigFingerprint: "reproos-attested-tdx:fixture",
      unverifiedVerityRootHash: repeat("22", 32))))

proc manifestFor(mrtdHex: string): string =
  renderAttestedImageManifest(AttestedImageManifest(
    configFingerprint: "reproos-attested-tdx:fixture",
    imageOutputs: ImageOutputs(
      uki: DigestPrefix & sha256Hex("fixture-uki"),
      verityImage: DigestPrefix & sha256Hex("fixture-verity-image"),
      verityRootHash: repeat("22", 32)),
    tdx: @[TdxExpectation(mrtd: mrtdHex,
      rtmr0: repeat("00", 48), rtmr1: repeat("00", 48),
      rtmr2: repeat("00", 48))]))

proc verdictFor(reportText, manifestText: string;
                collateral: TdxCollateralBundle;
                haveCollateral: bool;
                crls: seq[string]): Verdict =
  verifyAttestationReport(VerificationRequest(
    reportText: reportText, reportSource: "<fixture>",
    policy: parseAttestationPolicy(TdxPolicy, "<fixture policy>"),
    policySource: "<fixture policy>",
    manifestText: some(manifestText),
    manifestSource: "<verifier's own manifest>",
    nowMs: NowMs,
    vendorRevocationLists: crls,
    vendorCollateral: collateral,
    hasVendorCollateral: haveCollateral))

proc stringOf(b: openArray[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

suite "the verifier's trust-domain arm":

  test "t_tdx_the_arm_reports_what_the_chain_said":
    # The headline. The SAME quote, the SAME policy, the SAME clock —
    # and two different endorsement chains. A row that reported one
    # answer whatever happened underneath would be identical in both.
    let q = gtgV5Quote
    let crls = @[stringOf(bytesOfHex(PcsPckCrlPlatformDerHex))]
    let manifest = manifestFor(hexOfBytes(q.body.mrTd))

    let genuine = verdictFor(reportFor(q, q.pckChain, q.raw), manifest,
      bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson), true, crls)
    check genuine.checks[vcCertificateChain].outcome == coPassed
    check "reaches this build's vendor root" in
      genuine.checks[vcCertificateChain].detail

    let fabricated = @[bytesOfHex(ImpostorLeafDerHex),
                       bytesOfHex(ImpostorCaDerHex),
                       bytesOfHex(ImpostorRootDerHex)]
    let impostor = verdictFor(reportFor(q, fabricated, q.raw), manifest,
      bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson), true, crls)
    check impostor.checks[vcCertificateChain].outcome == coFailed
    check $tcRootIsNotIntel in impostor.checks[vcCertificateChain].detail
    check vcCertificateChain in impostor.failedChecks
    check not impostor.decision.isAcceptance

    # Intel's own sample hierarchy, through the same arm.
    let sample = @[bytesOfHex(IntelSampleLeafDerHex),
                   bytesOfHex(IntelSampleCaDerHex),
                   bytesOfHex(IntelSampleRootDerHex)]
    let sampled = verdictFor(reportFor(q, sample, q.raw), manifest,
      bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson), true, crls)
    check sampled.checks[vcCertificateChain].outcome == coFailed
    check $tcRootIsNotIntel in sampled.checks[vcCertificateChain].detail

    # And a bundle of the wrong LENGTH is refused as that, by the arm
    # itself rather than by the chain evaluator.
    let short = verdictFor(reportFor(q, q.pckChain[0 .. 1], q.raw),
      manifest, bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson), true,
      crls)
    check short.checks[vcCertificateChain].outcome == coFailed
    check "bundles 2" in short.checks[vcCertificateChain].detail

    # No withdrawal list at all is a refusal, not a pass.
    let noCrl = verdictFor(reportFor(q, q.pckChain, q.raw), manifest,
      bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson), true, @[])
    check noCrl.checks[vcCertificateChain].outcome == coFailed
    check $tcNoRevocationData in noCrl.checks[vcCertificateChain].detail

  test "t_tdx_the_arm_reads_the_evidence_rather_than_trusting_it":
    let q = gtgV5Quote
    let crls = @[stringOf(bytesOfHex(PcsPckCrlPlatformDerHex))]
    let manifest = manifestFor(hexOfBytes(q.body.mrTd))
    let bundle = bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson)

    let good = verdictFor(reportFor(q, q.pckChain, q.raw), manifest,
      bundle, true, crls)
    check good.checks[vcNativeEvidence].outcome == coPassed
    check good.checks[vcMeasurementMatch].outcome == coPassed
    check good.checks[vcTcbFloor].outcome == coPassed
    check "trust-domain attestation quote" in
      good.checks[vcNativeEvidence].detail
    # The reader SHIPS, so the verdict must not caveat itself as
    # resting on a caller's reading. That caveat was attached to every
    # trust-domain verdict until `BuiltInReaders` was told this reader
    # exists.
    check TdxReaderName in BuiltInReaders
    for caveat in good.caveats:
      check "which is not a reader this build carries" notin caveat

    # One bit inside the trust domain's own report: the evidence row
    # fails and the chain row does not, because the chain is untouched.
    var bent = q.raw
    let bodyAt = TdxQuoteHeaderLen + 6 + OffMrTd
    bent[bodyAt] = bent[bodyAt] xor 0x01'u8
    let tampered = verdictFor(reportFor(q, q.pckChain, bent), manifest,
      bundle, true, crls)
    check tampered.checks[vcNativeEvidence].outcome == coFailed
    check tampered.checks[vcCertificateChain].outcome == coPassed
    check "does not verify under the attestation key" in
      tampered.checks[vcNativeEvidence].detail
    check not tampered.decision.isAcceptance

    # One bit inside the QUOTING ENCLAVE's report: the enclave
    # signature fails and the other two do not. Without this the
    # reader's first check has no input at all — the mutation table
    # found exactly that.
    var bentQe = q.raw
    let sigAt = TdxQuoteHeaderLen + 6 + 648 + 4
    let qeAt = sigAt + EcdsaP256SignatureLen + EcdsaP256PublicKeyLen + 6
    bentQe[qeAt + OffQeMrSigner] = bentQe[qeAt + OffQeMrSigner] xor 0x01'u8
    let qeTampered = verdictFor(reportFor(q, q.pckChain, bentQe), manifest,
      bundle, true, crls)
    check qeTampered.checks[vcNativeEvidence].outcome == coFailed
    check "the quoting enclave's report does not verify under" in
      qeTampered.checks[vcNativeEvidence].detail
    check qeTampered.checks[vcCertificateChain].outcome == coPassed

    # One bit inside the ATTESTATION KEY: the binding fails, and the
    # message says so rather than saying a signature did.
    var bentKey = q.raw
    let keyAt = sigAt + EcdsaP256SignatureLen + 5
    bentKey[keyAt] = bentKey[keyAt] xor 0x04'u8
    let keyTampered = verdictFor(reportFor(q, q.pckChain, bentKey),
      manifest, bundle, true, crls)
    check keyTampered.checks[vcNativeEvidence].outcome == coFailed
    check "is not about this quote's attestation key" in
      keyTampered.checks[vcNativeEvidence].detail

    # The three failures are three, not one: each names a different
    # thing and no two share a sentence.
    check tampered.checks[vcNativeEvidence].detail !=
      qeTampered.checks[vcNativeEvidence].detail
    check qeTampered.checks[vcNativeEvidence].detail !=
      keyTampered.checks[vcNativeEvidence].detail
    check keyTampered.checks[vcNativeEvidence].detail !=
      tampered.checks[vcNativeEvidence].detail

    # Evidence that is not a quote at all.
    let garbage = verdictFor(
      reportFor(q, q.pckChain, @[0x04'u8, 0x00'u8, 0x81'u8]), manifest,
      bundle, true, crls)
    check garbage.checks[vcNativeEvidence].outcome == coFailed

  test "t_tdx_the_measurement_row_compares_against_the_verifier_s_manifest":
    let q = gtgV5Quote
    let crls = @[stringOf(bytesOfHex(PcsPckCrlPlatformDerHex))]
    let bundle = bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson)
    let reportText = reportFor(q, q.pckChain, q.raw)

    let matching = verdictFor(reportText,
      manifestFor(hexOfBytes(q.body.mrTd)), bundle, true, crls)
    check matching.checks[vcMeasurementMatch].outcome == coPassed
    check hexOfBytes(q.body.mrTd) in
      matching.checks[vcMeasurementMatch].detail

    # Another genuine part's measurement, so the negative is a real
    # value rather than a string of zeroes.
    let other = verdictFor(reportText,
      manifestFor(hexOfBytes(sprQuote.body.mrTd)), bundle, true, crls)
    check other.checks[vcMeasurementMatch].outcome == coFailed
    check hexOfBytes(sprQuote.body.mrTd) in
      other.checks[vcMeasurementMatch].detail
    check not other.decision.isAcceptance

  test "t_tdx_the_floor_row_is_a_failure_without_vendor_collateral":
    # A verifier holding no collateral establishes no status, and for a
    # confidential-computing tier that is a failure rather than a skip.
    # The fail-closed direction, asserted rather than assumed.
    let q = gtgV5Quote
    let crls = @[stringOf(bytesOfHex(PcsPckCrlPlatformDerHex))]
    let manifest = manifestFor(hexOfBytes(q.body.mrTd))
    let reportText = reportFor(q, q.pckChain, q.raw)

    let without = verdictFor(reportText, manifest,
      TdxCollateralBundle(), false, crls)
    check without.checks[vcTcbFloor].outcome == coFailed
    check "no reader supplied a TDX TCB status" in
      without.checks[vcTcbFloor].detail
    check vcTcbFloor in without.failedChecks
    check not without.decision.isAcceptance

    # With it, the status the vendor's documents imply, and the row
    # passes because the policy's floor is met.
    let withIt = verdictFor(reportText, manifest,
      bundleFor(PcsTcbInfoEmrJson, PcsTdxQeIdentityJson), true, crls)
    check withIt.checks[vcTcbFloor].outcome == coPassed
    check TdxStatusUpToDate in withIt.checks[vcTcbFloor].detail

    # A part the vendor's document does not cover produces no status at
    # all, and the EVIDENCE row is what refuses — a verifier that read
    # the quote and could not place its platform has not read it.
    let spr = sprQuote
    let sprReport = reportFor(spr, spr.pckChain, spr.raw)
    let unsupported = verdictFor(sprReport,
      manifestFor(hexOfBytes(spr.body.mrTd)),
      bundleFor(PcsTcbInfoSprJson, PcsTdxQeIdentityJson), true, crls)
    check unsupported.checks[vcNativeEvidence].outcome == coFailed
    check $tcoNoLevelCoversThisPlatform in
      unsupported.checks[vcNativeEvidence].detail
    check not unsupported.decision.isAcceptance

# ---------------------------------------------------------------------

suite "the reader is behind the signature":

  test "t_tdx_a_duplicated_member_is_read_from_the_span_that_was_signed":
    # A document may carry the same member name twice. The span is
    # taken from the FIRST occurrence, because that is where the
    # vendor's signature starts — and a reader that looked the name up
    # again in the whole document would get the LAST, which is bytes
    # the signature does not cover inside a document whose signature
    # verifies.
    let genuine = verifyCollateral(PcsTcbInfoEmrJson, TcbInfoMemberName,
      signerKey)
    check genuine.isVerified
    var span = ""
    for b in genuine.signedSpan: span.add char(b)
    # The genuine document with a SECOND `tcbInfo` appended, describing
    # a different platform. Its signature still verifies, because the
    # span it covers has not moved.
    let doubled = PcsTcbInfoEmrJson[0 ..< PcsTcbInfoEmrJson.len - 1] &
      ",\"tcbInfo\":{\"id\":\"TDX\",\"version\":3," &
      "\"fmspc\":\"ffffffffffff\",\"pceId\":\"0000\"," &
      "\"issueDate\":\"1970-01-01T00:00:00Z\"," &
      "\"nextUpdate\":\"1970-01-01T00:00:00Z\"," &
      "\"tcbEvaluationDataNumber\":0,\"tcbLevels\":[]}}"
    let v = verifyCollateral(doubled, TcbInfoMemberName, signerKey)
    check v.isVerified
    check hexOfBytes(v.signedSpan) == hexOfBytes(genuine.signedSpan)
    let info = parseTdxTcbInfo(v)
    check info.fmspcHex == "90c06f000000"
    check info.fmspcHex != "ffffffffffff"
    check info.levels.len == 4

  test "t_tdx_the_vendor_s_document_for_the_other_environment_is_refused":
    # A genuine, vendor-signed platform document whose execution
    # environment is not a trust domain: its levels carry no
    # trust-domain component array, so reading it as one names the
    # field that is absent rather than guessing at a default.
    let sgx = verifyCollateral(PcsSgxTcbInfoJson, TcbInfoMemberName,
      signerKey)
    check sgx.isVerified
    let before = refusalsObserved
    expectCollateralRefusal(tceRequiredFieldMissing):
      discard parseTdxTcbInfo(sgx)
    check refusalsObserved == before + 1
    # Its own `id` says which environment it describes, and that is
    # read out of the signed span BEFORE the reader for one environment
    # runs — so the bundle refuses on the identity and not on a field
    # that happens to be missing from it.
    check statedCollateralId(sgx) == "SGX"
    check statedCollateralId(verifyCollateral(PcsTcbInfoEmrJson,
      TcbInfoMemberName, signerKey)) == TdxTcbInfoIdTdx
    check statedCollateralId(VerifiedCollateral()) == ""
    var b = bundleFor(PcsSgxTcbInfoJson, PcsTdxQeIdentityJson)
    let verdict = establishTdxTcbStatus(b, gtgV5Quote,
      platformOf(gtgV5Quote))
    check verdict.outcome == tcoTcbInfoIsNotForTrustDomains
    check "\"SGX\"" in verdict.detail
    check "tdxtcbcomponents" notin verdict.detail
    reachedCollateralOutcomes.incl verdict.outcome

  test "t_tdx_every_collateral_refusal_kind_that_can_be_reached_was":
    # Three kinds are NOT reached, and the reason is one reason, stated
    # once: every one of them is a rule about the SHAPE of a document
    # the vendor signed, and the reader they live in cannot be called
    # without a record `verifyCollateral` produced — which it produces
    # only when a signature verified. Manufacturing a malformed
    # vendor-signed document means holding the vendor's private key.
    #
    # That is the same shape as the withdrawal refusal one module over,
    # and it is recorded here rather than papered over with a reader
    # entry point that skips the signature.
    var missing: seq[string] = @[]
    for k in TdxCollateralErrorKind:
      if k in {tceFieldHasTheWrongShape, tceComponentCountDisagrees,
               tceUnrecognisedStatus}: continue
      if k notin reachedCollateralKinds: missing.add $k
    check missing.len == 0
    check tceFieldHasTheWrongShape notin reachedCollateralKinds
    check tceComponentCountDisagrees notin reachedCollateralKinds
    check tceUnrecognisedStatus notin reachedCollateralKinds
    # Nine of twelve, and the three are named above.
    check card(reachedCollateralKinds) == 9
    writeCensus()

  test "t_tdx_every_outcome_that_can_be_reached_offline_was":
    var missing: seq[string] = @[]
    for k in TdxCollateralOutcome:
      if k == tcoCollateralIsNotCurrent: continue
      if k notin reachedCollateralOutcomes: missing.add $k
    check missing.len == 0
    # ONE is not reached, and it has no producer at all:
    # `tcoCollateralIsNotCurrent`. This module reads `issueDate` and
    # `nextUpdate` and does not compare them to a clock, because the
    # caller is the one that knows what it is verifying and when. The
    # value exists for a caller that will.
    check tcoCollateralIsNotCurrent notin reachedCollateralOutcomes
    var missingTcb: seq[string] = @[]
    for k in TdxTcbOutcome:
      if k in {ttoModuleIdentityNotPublished,
               ttoNoModuleLevelCoversThisVersion,
               ttoNoEnclaveLevelCoversThisVersion}: continue
      if k notin reachedTcbOutcomes: missingTcb.add $k
    check missingTcb.len == 0
