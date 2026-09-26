## A trust-domain endorsement chain is accepted only when it ends at
## Intel's key, and the rule that says so is not configuration.
##
## ## What this gate is actually asserting
##
## Three genuine provisioning chains — one per part, pulled out of the
## quotes themselves — are accepted. Then two complete, internally valid
## chains that are *not* Intel's are refused, and refused for exactly
## one reason: the key at the end of them.
##
## The two negatives are deliberately of different origins, and neither
## proves what the other does.
##
##   * **Intel's own** quote-verification library ships sample data
##     whose trust root carries Intel's distinguished name character for
##     character, is self-signed, is a certificate authority, and
##     endorses a chain that genuinely verifies under it. Nobody in this
##     workspace arranged that; it arrived that way, and any verifier
##     that matched on a name rather than on a key accepts it.
##   * The **fabricated** chain is the same shape with one difference
##     that matters more: it also carries the genuine platform
##     description, byte for byte, so the family-model-stepping value,
##     the sixteen component versions and the platform instance
##     identifier are all the real part's. Nothing distinguishes it from
##     a genuine chain except the key.
##
## Neither proves the pinned key is the RIGHT key. That is a different
## claim resting on different evidence, and the case below
## `t_tdx_the_pinned_root_is_the_one_the_vendor_publishes` is where it
## is made: the pinned point is re-derived from the vendor's own DER by
## this gate's reader, and the same DER is shown to arrive from inside
## all three quotes.
##
## ## Why "structurally, not by configuration" is checked and not said
##
## `evaluateIntelPckChain` takes no anchor parameter, and that is
## enforced by a `static` assertion in the module against a `proc` type
## that records its whole signature. A gate cannot test the absence of a
## parameter at run time — but it can test the two consequences that an
## absence has and a default would not: there is exactly ONE pinned key,
## and every element of the pinned table is reachable from the vendor's
## own bytes.
##
## ## Mocking
##
## None. Real Intel DER, real withdrawal lists, real P-256.

import std/[os, strutils, unittest]

import repro_attest_verify/tdx_chain
import repro_attest_verify/tdx_quote
import repro_attest_verify/x509

include ./tdx_vectors

# ---------------------------------------------------------------------
# Census
# ---------------------------------------------------------------------

var reachedChainKinds: set[IntelChainRejection] = {}
var reachedSetAside: seq[string] = @[]
var reachedChainSites: seq[string] = @[]

proc writeCensus() =
  ## Called from the LAST case; see the quote gate's copy for why an
  ## exit procedure could not do it.
  let path = getEnv("REPRO_REFUSAL_CENSUS")
  if path.len == 0: return
  var lines: seq[string] = @[]
  for k in IntelChainRejection:
    if k in reachedChainKinds: lines.add "tdx_chain:" & $k
  for s in reachedSetAside: lines.add "tdx_chain_setaside:" & s
  for s in reachedChainSites: lines.add "tdx_chain_site:" & s
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

proc flipBit(data: seq[byte]; offset, bit: int): seq[byte] =
  result = data
  result[offset] = result[offset] xor byte(1 shl bit)

var refusalsObserved = 0

proc expectRefusal(v: IntelChainVerdict; want: IntelChainRejection;
                   sentence: string) =
  ## The kind AND a fragment of the detail that only this rule writes.
  ## Three of the kinds below are produced by more than one rule, so a
  ## case asserting only the kind would be asserting that one of them
  ## fired and not which.
  inc refusalsObserved
  # The SITE, not the kind. Four of these kinds have more than one
  # site, so a census over kinds would report them as one rule; the
  # detail each site writes is what tells them apart.
  block:
    let marker = IntelChainMessage[want] & ": "
    let at = v.detail.find(marker)
    var words: seq[string] = @[]
    if at >= 0:
      for w in v.detail[at + marker.len .. ^1].split(' '):
        if words.len >= 6: break
        words.add w
    let site = $want & "/" & words.join(" ")
    if site notin reachedChainSites: reachedChainSites.add site
  check v.reason == want
  check IntelChainMessage[want] in v.detail
  for other in IntelChainRejection:
    if other == want: continue
    check IntelChainMessage[other] notin v.detail
  check sentence in v.detail
  reachedChainKinds.incl want

proc replaceAll(data: seq[byte]; needle, replacement: string): seq[byte] =
  ## Byte-for-byte substitution of equal-length ASCII inside DER. Used
  ## to move a common name without moving a single length octet, which
  ## is what lets a name rule be reached without disturbing anything
  ## the reader would object to first.
  doAssert needle.len == replacement.len
  result = data
  var i = 0
  while i + needle.len <= result.len:
    var hit = true
    for j in 0 ..< needle.len:
      if result[i + j] != byte(needle[j]): hit = false
    if hit:
      for j in 0 ..< needle.len:
        result[i + j] = byte(replacement[j])
      i += needle.len
    else:
      inc i

proc replaceFirst(data: seq[byte]; needle, replacement: string): seq[byte] =
  ## The same, for the FIRST occurrence only. A self-signed certificate
  ## carries its own name twice — as issuer and as subject, in that
  ## order — and moving only the first is what makes it stop being
  ## self-issued without changing what anything else names.
  doAssert needle.len == replacement.len
  result = data
  var i = 0
  while i + needle.len <= result.len:
    var hit = true
    for j in 0 ..< needle.len:
      if result[i + j] != byte(needle[j]): hit = false
    if hit:
      for j in 0 ..< needle.len:
        result[i + j] = byte(replacement[j])
      return
    inc i
  doAssert false, "the needle is not in the document"

# ---------------------------------------------------------------------
# The fixtures
# ---------------------------------------------------------------------

const
  Now = 1_790_294_400'i64
    ## 2026-09-25T00:00:00Z. Chosen to sit inside the vendor's platform
    ## withdrawal list's own window — it states a this-update of
    ## 2026-09-21T04:02:03Z and a next-update of 2026-10-21T04:02:03Z —
    ## and inside every certificate's. Fixed rather than read from the
    ## host: a gate that consulted the real clock would pass today and
    ## start failing on 2026-10-21, which is a date nobody chose and a
    ## failure nobody would connect to this file.
  BeforeTheListIsInForce = 1_789_000_000'i64   ## 2026-09-10T02:26:40Z
  AfterTheListExpires = 1_793_000_000'i64      ## 2026-10-26T07:33:20Z
  BeforeTheLeafIsValid = 1_609_459_200'i64     ## 2021-01-01T00:00:00Z
  AfterTheV4LeafExpires = 1_900_000_000'i64    ## 2030-03-17T16:26:40Z

let intelRootDer = bytesOfHex(IntelSgxRootCaDerHex)
let platformCrl = bytesOfHex(PcsPckCrlPlatformDerHex)
let processorCrl = bytesOfHex(PcsPckCrlProcessorDerHex)
let rootCrl = bytesOfHex(IntelRootCrlDerHex)
let crlWithoutNextUpdate =
  bytesOfHex(PcsPckCrlPlatformWithoutNextUpdateDerHex)

type
  Chain = object
    label: string
    leaf, authority, root: seq[byte]
    fmspcHex: string
    leafSerialHex: string
    componentSum: int
    pceSvn: int

proc chainOf(label: string; quoteHex: string; trim: int): Chain =
  var raw = bytesOfHex(quoteHex)
  if trim > 0: raw = raw[0 ..< trim]
  let q = parseTdxQuote(raw)
  doAssert q.pckChain.len == TdxChainElements
  result.label = label
  result.leaf = q.pckChain[0]
  result.authority = q.pckChain[1]
  result.root = q.pckChain[2]

let chains = @[
  chainOf("google/go-tdx-guest Sapphire Rapids", GoTdxGuestSprQuoteHex,
    4935),
  chainOf("google/go-tdx-guest version 5", GoTdxGuestEmrQuoteHex, 0),
  chainOf("confidential-containers/trustee", TrusteeV5QuoteHex, 0)]

let intelSampleChain = Chain(label: "Intel's own sample trust hierarchy",
  leaf: bytesOfHex(IntelSampleLeafDerHex),
  authority: bytesOfHex(IntelSampleCaDerHex),
  root: bytesOfHex(IntelSampleRootDerHex))

let impostorChain = Chain(label: "the chain fabricated in this workspace",
  leaf: bytesOfHex(ImpostorLeafDerHex),
  authority: bytesOfHex(ImpostorCaDerHex),
  root: bytesOfHex(ImpostorRootDerHex))

proc judge(c: Chain; crls: seq[seq[byte]] = @[];
           now: int64 = Now): IntelChainVerdict =
  var lists = crls
  if lists.len == 0: lists = @[platformCrl]
  evaluateIntelPckChain(c.leaf, c.authority, c.root, lists, now)

# ---------------------------------------------------------------------

suite "the intel root":

  test "t_tdx_chain_messages_are_distinguishable":
    check intelChainMessagesAreDistinguishable()

  test "t_tdx_the_pinned_root_is_the_one_the_vendor_publishes":
    # The pinned point is re-derived from the vendor's own DER by this
    # gate's reader rather than read out of the table it is checking.
    check IntelRootKeys.len == 1
    let root = parseCertificate(intelRootDer)
    check root.subjectCn == IntelRootKeys[0].commonName
    check hexOfBytes(root.publicKey) == IntelRootKeys[0].pointHex
    check intelRootFor(root.publicKey) == 0
    # And the SAME 659 bytes arrive inside every genuine quote, from
    # four unrelated publishers. A pinned key with one publisher is a
    # transcription; this is a corroboration.
    var routes = 0
    for c in chains:
      check hexOfBytes(c.root) == hexOfBytes(intelRootDer)
      inc routes
    check routes == 3

  test "t_tdx_a_key_that_is_not_the_pinned_one_matches_no_root":
    # Both halves: the impostor's key and Intel's own sample key are
    # refused by `intelRootFor`, and the genuine one is not. Without
    # the third line this case is satisfied by a function that always
    # says no.
    check intelRootFor(parseCertificate(impostorChain.root).publicKey) < 0
    check intelRootFor(
      parseCertificate(intelSampleChain.root).publicKey) < 0
    check intelRootFor(parseCertificate(intelRootDer).publicKey) == 0
    # A single flipped bit in the pinned point is a different key.
    var bent = intelRootDer
    let root = parseCertificate(intelRootDer)
    var point = @(root.publicKey)
    point[10] = point[10] xor 0x01'u8
    check intelRootFor(point) < 0
    discard bent

# ---------------------------------------------------------------------

proc driveTdxThreeGenuineChainsAreAccepted() =
  ## The body of test
  ##   "t_tdx_three_genuine_chains_are_accepted"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var accepted = 0
  var platforms: seq[string] = @[]
  var serials: seq[string] = @[]
  for c in chains:
    checkpoint c.label
    let v = judge(c)
    check v.isAccepted
    check v.reason == tcAccepted
    check v.rootMatched
    check v.revocationConsulted
    check v.rootCn == "Intel SGX Root CA"
    check v.leafCn == PckLeafCommonName
    check v.authorityIsPlatform
    check v.authorityCn == PckPlatformCaCommonName
    check v.platform.present
    check v.platform.tcb.hasComponents
    check v.platform.tcb.hasPceSvn
    check v.platform.fmspcHex.len == 2 * FmspcLen
    check v.platform.ppid.len == PpidLen
    check v.platform.tcb.cpuSvn.len == CpuSvnLen
    check v.leafSerialHex notin serials
    serials.add v.leafSerialHex
    if v.platform.fmspcHex notin platforms:
      platforms.add v.platform.fmspcHex
    inc accepted
  check accepted == 3
  check platforms.len == 2
  check serials.len == 3
  reachedChainKinds.incl tcAccepted

suite "genuine chains":

  test "t_tdx_three_genuine_chains_are_accepted":
    driveTdxThreeGenuineChainsAreAccepted()

  test "t_tdx_the_platform_description_is_the_part_s_own":
    # Values, not shapes. Each chain's description is compared against
    # the numbers an independent reader took out of the same DER.
    let expected = @[
      ("50806f000000", "089ddfdb9c0359c82a3bc7719239574e", 11,
       @[3, 3, 2, 2, 2, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0],
       "03030202020100020000000000000000"),
      ("90c06f000000", "2734b654f553596897eaadfb5667a954", 13,
       @[4, 4, 2, 2, 4, 1, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0],
       "04040202040100050000000000000000"),
      ("90c06f000000", "f06984c8d9343452b997c48b36d6e678", 13,
       @[1, 1, 2, 2, 3, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0],
       "01010202030100030000000000000000")]
    check expected.len == chains.len
    for i, c in chains:
      checkpoint c.label
      let v = judge(c)
      let (fmspc, ppid, pceSvn, comps, cpuSvn) = expected[i]
      check v.platform.fmspcHex == fmspc
      check hexOfBytes(v.platform.ppid) == ppid
      check v.platform.tcb.pceSvn == pceSvn
      check hexOfBytes(v.platform.tcb.cpuSvn) == cpuSvn
      for j in 0 ..< IntelTcbComponentCount:
        check v.platform.tcb.components[j] == comps[j]

  test "t_tdx_the_three_parts_share_one_authority_and_one_root":
    # Measured rather than assumed, and it decides how the negatives
    # below have to be built: all three genuine chains carry the SAME
    # authority certificate and the SAME root, byte for byte. So
    # swapping elements between them is a no-op, and what distinguishes
    # the three is the provisioning certificate alone — its serial, its
    # key and its platform description.
    for c in chains:
      check hexOfBytes(c.authority) == hexOfBytes(chains[0].authority)
      check hexOfBytes(c.root) == hexOfBytes(chains[0].root)
    var leaves: seq[string] = @[]
    var keys: seq[string] = @[]
    for c in chains:
      let leaf = parseCertificate(c.leaf)
      check hexOfBytes(c.leaf) notin leaves
      leaves.add hexOfBytes(c.leaf)
      check hexOfBytes(leaf.publicKey) notin keys
      keys.add hexOfBytes(leaf.publicKey)
      # Each one really was signed by the shared authority.
      check leaf.signatureVerifiesUnder(
        parseCertificate(chains[0].authority).publicKey)
    check leaves.len == 3
    check keys.len == 3

# ---------------------------------------------------------------------

proc driveTdxIntelSOwnSampleHierarchyIsRefusedForItsKey() =
  ## The body of test
  ##   "t_tdx_intel_s_own_sample_hierarchy_is_refused_for_its_key"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Everything about it is right except the key, and the gate
  # establishes that rather than assuming it.
  let leaf = parseCertificate(intelSampleChain.leaf)
  let authority = parseCertificate(intelSampleChain.authority)
  let root = parseCertificate(intelSampleChain.root)
  check leaf.subjectCn == PckLeafCommonName
  # Its authority is the PROCESSOR one, not the platform one — so
  # the corpus reaches both names in `IntelPckAuthorityCommonNames`
  # and neither entry of that list is unused.
  check authority.subjectCn == PckProcessorCaCommonName
  check root.subjectCn == "Intel SGX Root CA"
  check root.isCa
  check authority.isCa
  check root.subjectDn == root.issuerDn
  check authority.issuerDn == root.subjectDn
  check leaf.issuerDn == authority.subjectDn
  check root.signatureVerifiesUnder(root.publicKey)
  check authority.signatureVerifiesUnder(root.publicKey)
  check leaf.signatureVerifiesUnder(authority.publicKey)
  # Its name is Intel's and its key is not.
  check root.subjectDn == parseCertificate(intelRootDer).subjectDn
  check hexOfBytes(root.publicKey) !=
    hexOfBytes(parseCertificate(intelRootDer).publicKey)
  check root.serialHex == "1a5865019d18b04e045af82d06c08550e20eb476"
  expectRefusal(judge(intelSampleChain), tcRootIsNotIntel,
    "1a5865019d18b04e045af82d06c08550e20eb476")

proc driveTdxTheFabricatedHierarchyIsRefusedForItsKey() =
  ## The body of test
  ##   "t_tdx_the_fabricated_hierarchy_is_refused_for_its_key"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The same, plus the genuine platform description, so not even the
  # part identity distinguishes it.
  let leaf = parseCertificate(impostorChain.leaf)
  let root = parseCertificate(impostorChain.root)
  check leaf.subjectCn == PckLeafCommonName
  check root.subjectDn == parseCertificate(intelRootDer).subjectDn
  check root.signatureVerifiesUnder(root.publicKey)
  check leaf.signatureVerifiesUnder(
    parseCertificate(impostorChain.authority).publicKey)
  let platform = intelPlatformOf(leaf)
  check platform.present
  check platform.fmspcHex ==
    judge(chains[0]).platform.fmspcHex
  check hexOfBytes(platform.ppid) ==
    hexOfBytes(judge(chains[0]).platform.ppid)
  expectRefusal(judge(impostorChain), tcRootIsNotIntel,
    "P-256 key that is none of the 1 this build was built with")

proc driveTdxTheGenuineRootUnderADifferentNameIsRefused() =
  ## The body of test
  ##   "t_tdx_the_genuine_root_under_a_different_name_is_refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The one rule below the key rule: the key IS the pinned one and
  # the name beside it is not. Reached by moving the common name in
  # place — same length, so no length octet moves — in the root and
  # in the authority's view of it, so the names still link and the
  # rule the case is about is the one that fires.
  var c = chains[0]
  c.root = replaceAll(c.root, "Intel SGX Root CA", "Intel SGX Root CB")
  c.authority = replaceAll(c.authority, "Intel SGX Root CA",
    "Intel SGX Root CB")
  check parseCertificate(c.root).subjectCn == "Intel SGX Root CB"
  check hexOfBytes(parseCertificate(c.root).publicKey) ==
    IntelRootKeys[0].pointHex
  expectRefusal(judge(c), tcRootNameDisagreesWithKey,
    "\"Intel SGX Root CB\"")

suite "chains rooted elsewhere":

  test "t_tdx_intel_s_own_sample_hierarchy_is_refused_for_its_key":
    driveTdxIntelSOwnSampleHierarchyIsRefusedForItsKey()

  test "t_tdx_the_fabricated_hierarchy_is_refused_for_its_key":
    driveTdxTheFabricatedHierarchyIsRefusedForItsKey()

  test "t_tdx_the_genuine_root_under_a_different_name_is_refused":
    driveTdxTheGenuineRootUnderADifferentNameIsRefused()

# ---------------------------------------------------------------------

proc driveTdxEveryStructuralRuleRefusesItsOwnInput() =
  ## The body of test
  ##   "t_tdx_every_structural_rule_refuses_its_own_input"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let good = chains[0]
  let before = refusalsObserved

  expectRefusal(judge(Chain(leaf: @[0x30'u8, 0x02'u8, 0x00'u8, 0x00'u8],
    authority: good.authority, root: good.root)), tcMalformed,
    "certificate")

  # An element carrying a critical extension this build cannot act on.
  expectRefusal(judge(Chain(
    leaf: bytesOfHex(ImpostorLeafWithUnknownCriticalDerHex),
    authority: good.authority, root: good.root)),
    tcUnrecognisedCriticalExtension, "2.5.29.30")

  # The leaf is not a provisioning certificate: the authority in its
  # place.
  expectRefusal(judge(Chain(leaf: good.authority,
    authority: good.authority, root: good.root)),
    tcLeafIsNotAProvisioningCertificate, "\"" &
    PckPlatformCaCommonName & "\"")

  # The authority is neither of the two the vendor operates: the root
  # in its place.
  expectRefusal(judge(Chain(leaf: good.leaf, authority: good.root,
    root: good.root)), tcAuthorityIsNotOneIntelIssues,
    "\"Intel SGX Root CA\"")

  # The three platform-description rules, each over a leaf that is
  # otherwise a provisioning certificate.
  expectRefusal(judge(Chain(
    leaf: bytesOfHex(ImpostorLeafWithoutPlatformDerHex),
    authority: good.authority, root: good.root)),
    tcLeafCarriesNoPlatformExtension, IntelSgxArc)
  expectRefusal(judge(Chain(
    leaf: bytesOfHex(ImpostorLeafWithoutFmspcDerHex),
    authority: good.authority, root: good.root)),
    tcLeafCarriesNoPlatformIdentifier, "holds 0 bytes")
  expectRefusal(judge(Chain(
    leaf: bytesOfHex(ImpostorLeafWithoutTcbDerHex),
    authority: good.authority, root: good.root)),
    tcLeafCarriesNoPlatformTcb, "fewer than sixteen components")

  # Both name links.
  expectRefusal(judge(Chain(leaf: chains[1].leaf,
    authority: bytesOfHex(ImpostorCaNotAnAuthorityDerHex),
    root: good.root)), tcNotACertificateAuthority,
    "does not carry basicConstraints cA TRUE")
  expectRefusal(judge(Chain(leaf: chains[1].leaf,
    authority: bytesOfHex(ImpostorCaWithoutCertSignDerHex),
    root: good.root)), tcNotACertificateAuthority,
    "does not include keyCertSign")

  # The root is not self-issued. Reached by moving the FIRST
  # occurrence of its own name — which is its issuer, because DER
  # writes issuer before subject — so the authority still names the
  # subject it names and the link above this rule still holds.
  var notSelfIssued = good
  notSelfIssued.root = replaceFirst(good.root, "Intel SGX Root CA",
    "Intel SGX Root CB")
  check parseCertificate(notSelfIssued.root).issuerCn ==
    "Intel SGX Root CB"
  check parseCertificate(notSelfIssued.root).subjectCn ==
    "Intel SGX Root CA"
  expectRefusal(judge(notSelfIssued), tcNotSelfIssued,
    "it is issued by")

  check refusalsObserved == before + 10

proc driveTdxANameLinkThatDoesNotLinkIsRefusedAsThat() =
  ## The body of test
  ##   "t_tdx_a_name_link_that_does_not_link_is_refused_as_that"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Both links, and each names the element it is about. Reached by
  # moving a common name in place inside ONE element so the other's
  # view of it no longer matches.
  let good = chains[0]
  let before = refusalsObserved
  var leafSide = good
  leafSide.leaf = replaceAll(good.leaf, "Intel SGX PCK Platform CA",
    "Intel SGX PCK Platform CB")
  check parseCertificate(leafSide.leaf).issuerCn ==
    "Intel SGX PCK Platform CB"
  check parseCertificate(leafSide.leaf).subjectCn == PckLeafCommonName
  expectRefusal(judge(leafSide), tcNameMismatch,
    "the provisioning certificate names")
  var rootSide = good
  rootSide.authority = replaceAll(good.authority, "Intel SGX Root CA",
    "Intel SGX Root CB")
  check parseCertificate(rootSide.authority).issuerCn ==
    "Intel SGX Root CB"
  check parseCertificate(rootSide.authority).subjectCn ==
    PckPlatformCaCommonName
  expectRefusal(judge(rootSide), tcNameMismatch, "the authority names")
  check refusalsObserved == before + 2

proc driveTdxEachElementSSignatureIsCheckedUnderTheOneAbove() =
  ## The body of test
  ##   "t_tdx_each_element_s_signature_is_checked_under_the_one_above"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Three sites, each reached by bending the signature of exactly one
  # element and leaving the other two alone.
  let good = chains[0]
  let before = refusalsObserved
  let leafSigAt = good.leaf.len - 10
  expectRefusal(judge(Chain(leaf: flipBit(good.leaf, leafSigAt, 3),
    authority: good.authority, root: good.root)), tcBadSignature,
    "the provisioning certificate does not verify under")
  expectRefusal(judge(Chain(leaf: good.leaf,
    authority: flipBit(good.authority, good.authority.len - 10, 3),
    root: good.root)), tcBadSignature,
    "the authority does not verify under")
  expectRefusal(judge(Chain(leaf: good.leaf, authority: good.authority,
    root: flipBit(good.root, good.root.len - 10, 3))), tcBadSignature,
    "the root does not verify under its own key")
  check refusalsObserved == before + 3
  # And the fabricated authority, which links by name to the genuine
  # root and to the genuine leaf and whose key is not the one that
  # signed either.
  expectRefusal(judge(Chain(leaf: good.leaf,
    authority: bytesOfHex(ImpostorCaDerHex), root: good.root)),
    tcBadSignature, "the provisioning certificate does not verify under")

proc driveTdxEveryElementSValidityWindowIsChecked() =
  ## The body of test
  ##   "t_tdx_every_element_s_validity_window_is_checked"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Six sites: two directions on each of three elements. The leaf's
  # two are reached with a clock; the authority's and the root's are
  # reached by moving their own `notAfter` in place, because no clock
  # exists that is inside the leaf's window and outside theirs —
  # measured, not assumed, and the first two checks say so.
  let good = chains[0]
  let before = refusalsObserved
  let leaf = parseCertificate(good.leaf)
  let authority = parseCertificate(good.authority)
  let root = parseCertificate(good.root)
  check leaf.notAfter < authority.notAfter
  check leaf.notAfter < root.notAfter
  check authority.notBefore < leaf.notBefore
  check root.notBefore < leaf.notBefore

  expectRefusal(judge(good, now = BeforeTheLeafIsValid), tcExpired,
    "the provisioning certificate is not valid until")
  expectRefusal(judge(good, now = AfterTheV4LeafExpires), tcExpired,
    "the provisioning certificate stopped being valid at")

  # `330521105010Z` -> `240521105010Z`: the same thirteen octets, a
  # window that closed before this gate's clock.
  var pastAuthority = good
  pastAuthority.authority = replaceAll(good.authority,
    "330521105010Z", "240521105010Z")
  check parseCertificate(pastAuthority.authority).notAfter <
    parseCertificate(good.authority).notAfter
  expectRefusal(judge(pastAuthority), tcExpired,
    "the authority stopped being valid at")

  var futureAuthority = good
  futureAuthority.authority = replaceAll(good.authority,
    "180521105010Z", "320521105010Z")
  expectRefusal(judge(futureAuthority), tcExpired,
    "the authority is not valid until")

  var pastRoot = good
  pastRoot.root = replaceAll(good.root, "491231235959Z",
    "241231235959Z")
  expectRefusal(judge(pastRoot), tcExpired,
    "the root stopped being valid at")

  var futureRoot = good
  futureRoot.root = replaceAll(good.root, "180521104510Z",
    "400521104510Z")
  expectRefusal(judge(futureRoot), tcExpired,
    "the root is not valid until")

  check refusalsObserved == before + 6

suite "chain structure refusals":

  test "t_tdx_every_structural_rule_refuses_its_own_input":
    driveTdxEveryStructuralRuleRefusesItsOwnInput()

  test "t_tdx_a_name_link_that_does_not_link_is_refused_as_that":
    driveTdxANameLinkThatDoesNotLinkIsRefusedAsThat()

  test "t_tdx_each_element_s_signature_is_checked_under_the_one_above":
    driveTdxEachElementSSignatureIsCheckedUnderTheOneAbove()

  test "t_tdx_every_element_s_validity_window_is_checked":
    driveTdxEveryElementSValidityWindowIsChecked()

# ---------------------------------------------------------------------

proc driveTdxEachConditionThatSetsAListAsideNamesItself() =
  ## The body of test
  ##   "t_tdx_each_condition_that_sets_a_list_aside_names_itself"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Five conditions decide whether a list answers the question, and
  # every one of them has an input here. Four of the five are real
  # vendor documents or the real clock; the fifth is the vendor's own
  # list with one field deleted.
  let good = chains[0]
  let before = refusalsObserved

  # 1. Issued by a different authority. The vendor publishes exactly
  #    this: a platform list and a processor list, and every chain in
  #    the corpus runs through the platform one.
  expectRefusal(judge(good, crls = @[processorCrl]),
    tcNoRevocationData, "and not by the authority under test")
  reachedSetAside.add "wrong-authority"

  # 2. No next update at all.
  expectRefusal(judge(good, crls = @[crlWithoutNextUpdate]),
    tcNoRevocationData, "states no next update at all")
  reachedSetAside.add "no-next-update"

  # 3. Not yet in force.
  expectRefusal(judge(good, crls = @[platformCrl],
    now = BeforeTheListIsInForce), tcNoRevocationData,
    "is not in force until")
  reachedSetAside.add "not-yet-in-force"

  # 4. No longer current. The clock is past the list's own next
  #    update AND still inside every certificate's window, which the
  #    two checks below establish rather than assume.
  let leaf = parseCertificate(good.leaf)
  check AfterTheListExpires < leaf.notAfter
  check AfterTheListExpires > leaf.notBefore
  expectRefusal(judge(good, crls = @[platformCrl],
    now = AfterTheListExpires), tcNoRevocationData,
    "stopped being current at")
  reachedSetAside.add "no-longer-current"

  # 5. A signature this authority did not make.
  expectRefusal(judge(good,
    crls = @[flipBit(platformCrl, platformCrl.len - 10, 3)]),
    tcNoRevocationData, "carries a signature this authority did not make")
  reachedSetAside.add "bad-signature"

  # And the two absences: none supplied at all, and one that does not
  # read as a list.
  expectRefusal(judge(good, crls = @[rootCrl]), tcNoRevocationData,
    "and not by the authority under test")
  expectRefusal(judge(good, crls = @[@[0x30'u8, 0x01'u8, 0x00'u8]]),
    tcNoRevocationData, "did not read at all")

  check refusalsObserved == before + 7
  check reachedSetAside.len == 5

proc driveTdxTheVendorSListNamesASerialAndTheRuleReadsIt() =
  ## The body of test
  ##   "t_tdx_the_vendor_s_list_names_a_serial_and_the_rule_reads_it"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The withdrawal REFUSAL has no input that can be manufactured
  # offline: reaching it needs a list that is both signed by the
  # authority under test and names the serial of a certificate beside
  # it, and making that pair means holding the vendor's private key.
  # Said out loud rather than implied.
  #
  # The RULE does have an input. The vendor's platform list names a
  # serial, so the comparison is exercised in both directions against
  # a real document — and the case asserts the list is not empty,
  # because a rule tested against an empty list is a rule tested
  # against nothing.
  let crl = parseCrl(platformCrl)
  check crl.revoked.len > 0
  check crl.issuerCn == PckPlatformCaCommonName
  check crl.hasNextUpdate
  var named = ""
  for entry in crl.revoked:
    if named.len == 0: named = entry.serialHex
  check named.len > 0
  check serialIsWithdrawn(crl, named)
  for c in chains:
    let v = judge(c)
    check v.isAccepted
    check not serialIsWithdrawn(crl, v.leafSerialHex)
    check v.leafSerialHex != named
  # A list that names nothing answers no differently, and the vendor
  # publishes one of those too.
  let empty = parseCrl(rootCrl)
  check empty.revoked.len == 0
  check not serialIsWithdrawn(empty, named)
  check tcRevoked notin reachedChainKinds

proc driveTdxSerialNumbersAreReadAsValuesAndNotAsEncodings() =
  ## The body of test
  ##   "t_tdx_serial_numbers_are_read_as_values_and_not_as_encodings"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  let good = chains[0]
  # The reader's bound was on the ENCODING and Intel's serials are
  # twenty octets with the top bit set, so DER writes twenty-one — and
  # every genuine provisioning certificate here was refused by it.
  # Both branches are in the corpus and both are asserted.
  check MaxSerialValueOctets == 20
  var padded = 0
  var bare = 0
  for c in chains:
    let serial = parseCertificate(c.leaf).serialHex
    if serial.len == 42:
      check serial[0 .. 1] == "00"
      inc padded
    elif serial.len == 40:
      check serial[0 .. 1] != "00"
      inc bare
  check padded == 2
  check bare == 1
  # And the two rules the fix added refuse what they are for, over a
  # GENUINE certificate edited by one byte each time — so the serial
  # is the only thing that moved and the length octets did not move
  # at all. Both edits break the signature; neither ever reaches it,
  # because a serial is read while the document is being parsed.
  let genuineSerial = bytesOfHex(
    "00bba6c175d838b8df3900cc3411f24f512d104102")
  var at = -1
  for i in 0 .. good.leaf.len - genuineSerial.len:
    var hit = true
    for j in 0 ..< genuineSerial.len:
      if good.leaf[i + j] != genuineSerial[j]: hit = false
    if hit and at < 0: at = i
  check at > 0
  check good.leaf[at - 2] == 0x02'u8          ## INTEGER
  check int(good.leaf[at - 1]) == genuineSerial.len

  # Twenty-one octets of VALUE: the leading zero stops being a pad.
  var tooWide = good.leaf
  tooWide[at] = 0x01'u8
  var wideMsg = ""
  try:
    discard parseCertificate(tooWide)
  except X509Error as err:
    wideMsg = err.msg
  check "21 octets of value" in wideMsg
  check "bounds it at 20" in wideMsg

  # A leading zero DER did not require: the octet after it has its
  # top bit clear, so the pad is a second spelling of one number.
  var redundant = good.leaf
  redundant[at + 1] = 0x05'u8
  var redundantMsg = ""
  try:
    discard parseCertificate(redundant)
  except X509Error as err:
    redundantMsg = err.msg
  check "second spelling of one number" in redundantMsg
  check "begins 0x00 0x05" in redundantMsg
  check wideMsg != redundantMsg

  # An empty INTEGER. One byte again: the serial's LENGTH octet set to
  # zero, which the reader meets before it meets anything else about
  # the serial. The mutation table found this rule with no input at
  # all — no certificate anybody issues carries `02 00` — and this is
  # the cheapest honest way to give it one.
  var emptySerial = good.leaf
  emptySerial[at - 1] = 0x00'u8
  var emptyMsg = ""
  try:
    discard parseCertificate(emptySerial)
  except X509Error as err:
    emptyMsg = err.msg
  check "the serial number is an empty INTEGER" in emptyMsg
  check emptyMsg != wideMsg
  check emptyMsg != redundantMsg

  # The unedited certificate reads, so neither refusal is something
  # this reader says about every serial.
  check parseCertificate(good.leaf).serialHex ==
    "00bba6c175d838b8df3900cc3411f24f512d104102"

  # And through the chain evaluator, both are `tcMalformed` — the
  # kind a document that is not of the shape the vendor issues earns.
  let beforeSerial = refusalsObserved
  expectRefusal(judge(Chain(leaf: tooWide, authority: good.authority,
    root: good.root)), tcMalformed, "octets of value")
  expectRefusal(judge(Chain(leaf: redundant, authority: good.authority,
    root: good.root)), tcMalformed, "second spelling")
  expectRefusal(judge(Chain(leaf: emptySerial, authority: good.authority,
    root: good.root)), tcMalformed, "an empty INTEGER")
  check refusalsObserved == beforeSerial + 3

# Every case whose outcomes the coverage case(s) below observe. The
# suite runner executes each case in its own process (`--run
# suite::test`), so the coverage case drives these itself rather than
# reading what earlier cases left in process-global state.
const ChainDrivers: seq[(string, proc () {.nimcall.})] = @[
  ("t_tdx_three_genuine_chains_are_accepted",
    driveTdxThreeGenuineChainsAreAccepted),
  ("t_tdx_intel_s_own_sample_hierarchy_is_refused_for_its_key",
    driveTdxIntelSOwnSampleHierarchyIsRefusedForItsKey),
  ("t_tdx_the_fabricated_hierarchy_is_refused_for_its_key",
    driveTdxTheFabricatedHierarchyIsRefusedForItsKey),
  ("t_tdx_the_genuine_root_under_a_different_name_is_refused",
    driveTdxTheGenuineRootUnderADifferentNameIsRefused),
  ("t_tdx_every_structural_rule_refuses_its_own_input",
    driveTdxEveryStructuralRuleRefusesItsOwnInput),
  ("t_tdx_a_name_link_that_does_not_link_is_refused_as_that",
    driveTdxANameLinkThatDoesNotLinkIsRefusedAsThat),
  ("t_tdx_each_element_s_signature_is_checked_under_the_one_above",
    driveTdxEachElementSSignatureIsCheckedUnderTheOneAbove),
  ("t_tdx_every_element_s_validity_window_is_checked",
    driveTdxEveryElementSValidityWindowIsChecked),
  ("t_tdx_each_condition_that_sets_a_list_aside_names_itself",
    driveTdxEachConditionThatSetsAListAsideNamesItself),
  ("t_tdx_the_vendor_s_list_names_a_serial_and_the_rule_reads_it",
    driveTdxTheVendorSListNamesASerialAndTheRuleReadsIt),
  ("t_tdx_serial_numbers_are_read_as_values_and_not_as_encodings",
    driveTdxSerialNumbersAreReadAsValuesAndNotAsEncodings)]

suite "withdrawal":

  test "t_tdx_each_condition_that_sets_a_list_aside_names_itself":
    driveTdxEachConditionThatSetsAListAsideNamesItself()

  test "t_tdx_the_vendor_s_list_names_a_serial_and_the_rule_reads_it":
    driveTdxTheVendorSListNamesASerialAndTheRuleReadsIt()

  test "t_tdx_serial_numbers_are_read_as_values_and_not_as_encodings":
    driveTdxSerialNumbersAreReadAsValuesAndNotAsEncodings()

  test "t_tdx_every_refusal_kind_was_reached_by_some_case":
    # Driven HERE, from reset state: the runner executes every case in
    # its own process, so this case observes only what it runs itself.
    reachedChainKinds = {}
    reachedSetAside = @[]
    reachedChainSites = @[]
    for (name, drive) in ChainDrivers:
      checkpoint("driving " & name)
      drive()
    var missing: seq[string] = @[]
    for k in IntelChainRejection:
      if k == tcRevoked: continue
      if k notin reachedChainKinds: missing.add $k
    check missing.len == 0
    # Seventeen values, sixteen of them reached. `tcRevoked` is the one
    # that is not, and the case above says why.
    check card(reachedChainKinds) == 16
    check tcRevoked notin reachedChainKinds
    writeCensus()
