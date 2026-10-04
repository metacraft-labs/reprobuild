## A software-root confidential-computing hierarchy cannot satisfy a
## genuine-tier policy, and the reason is structural rather than
## configured.
##
## ## The claim, and why the usual demonstration is not one
##
## The easy version of this case installs a test root, leaves some flag
## off, observes a rejection and calls it proof. It is not. A rejection
## that happens because a switch defaults to off is a rejection one
## edit away from an acceptance.
##
## So this file does the opposite of leaving things off. It turns
## everything *on*: the emulated evidence is correct in every other
## respect — its signature verifies under the key its own chain
## endorses, its measurement is the one the manifest publishes, its 64
## bound bytes are the ones the challenge produces, the challenge is
## fresh — and the policy is run in **six** shapes including the most
## permissive one the schema admits for a confidential-computing
## report.
##
## Every one of them rejects, and every one of them rejects at the
## certificate chain.
##
## ## The five structural legs
##
## Behaviour under six policies is evidence, not proof. The legs below
## are the proof, and the fourth and fifth are stronger than anything
## the measured-boot tier can say:
##
##   1. **Two independent refusals, not one.** A MARKED hierarchy is
##      refused for carrying a critical extension RFC 5280 §4.2 says a
##      conforming system must not ignore. An UNMARKED one — minted
##      here, deliberately, because the argument exists — is refused
##      anyway, because the key it ends at is not one of the vendor
##      roots this build was compiled with. Stripping the mark does not
##      launder the chain, and the gate shows both refusals on the same
##      hierarchy minted twice.
##   2. **The root tables are compile-time constants with nowhere to
##      put another key.** Asserted inside ``static:`` blocks — a value
##      the compiler must produce is a value no environment can have
##      contributed to — and the test roots' own keys are required to
##      be absent from them at run time, which is the half a ``static``
##      cannot make.
##   3. **The evaluators have no lever to pull.** Each takes five
##      arguments and none of them is a policy, an anchor or a set of
##      extension identifiers; passing a sixth does not compile. Each
##      is additionally pinned to its own parameter list by a
##      ``static`` assertion in its own module.
##   4. **There is no accepting evaluator in ANY build.** The
##      measured-boot tier has one, compiled in only under a define.
##      The confidential-computing tiers have none: the three modules
##      that hold the root decision contain no ``when defined`` at all,
##      and nothing else in the libraries has either evaluator's
##      signature. Both are asserted by reading the sources.
##   5. **The policy grammar has no clause for it.** Nine spellings of
##      "trust this root anyway" are fed to the real policy parser and
##      every one is refused as a key the schema does not define.
##
## ## The positive controls
##
## Two, and they are different claims. First, the evaluators are not
## refusing everything: a GENUINE vendor chain — the security
## processor's from the vendor's own distribution service, the trust
## domain's out of a real quote — is ACCEPTED by the same procedure at
## the same instant. Second, the emulated report fails NO ROW OUTSIDE
## the structural set its backend declares — the chain alone for the
## security processor, the chain and the trusted-computing-base floor
## for the trust domain, whose status is established under the same
## pinned root the chain cannot reach. That is what makes "the chain is
## the only thing wrong with it that this build could help" a
## measurement rather than a hope.
##
## ## Mocking
##
## None.

import std/[base64, options, os, sequtils, strutils, unittest]

import repro_attest
import repro_attest_verify
import repro_attest_verify/tdx_chain
import repro_attest_verify/tdx_quote

import ./cvm_evidence_emulator
import ./cvm_emulator_scenarios
import ./software_root_test_pki

include ./snp_vectors
include ./tdx_vectors

const
  SnpInstant = 1_790_121_600'i64
    ## 2026-09-23T00:00:00Z — the instant at which every genuine
    ## security-processor artifact this gate judges is in force. Fixed
    ## rather than read from the host, by the clock rule `snp_vectors`
    ## states.
  TdxInstant = 1_790_985_600'i64
    ## 2026-10-03T00:00:00Z — the same rule for the trust domain's
    ## corpus, whose withdrawal lists came into force later.

  PermissiveSnpPolicy = """
schema = "reproos.attestation-policy.v1"

# The most permissive document this schema admits for a
# security-processor report: nothing pinned, no age bound, and a
# platform-version floor of zero in every component — which is the
# lowest a floor can be stated as, because the grammar requires one.
[accept]
tiers = ["cvm"]
backends = ["sev-snp"]
allow_mock = false

[measurements]
manifests = []
require_certificates = false

[tcb]
sev-snp.min_tcb = { bootloader = 0, tee = 0, snp = 0, microcode = 0 }
allow_grace_days = 0

[freshness]
max_challenge_age_seconds = 0
require_challenge = false
"""

  PermissiveTdxPolicy = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["cvm"]
backends = ["tdx"]
allow_mock = false

[measurements]
manifests = []
require_certificates = false

[tcb]
tdx.min_tcb_status = "OutOfDate"
allow_grace_days = 0

[freshness]
max_challenge_age_seconds = 0
require_challenge = false
"""

  WideningClauses = [
    "\n[accept]\nsoftware_roots = [\"anything\"]\n",
    "\n[accept]\ntrust_anchors = [\"anything\"]\n",
    "\n[accept]\nallow_software_roots = true\n",
    "\n[accept]\nrecognised_critical_extensions = [\"2.999.1.1\"]\n",
    "\n[trust]\nanchors = [\"anything\"]\n",
    "\n[trust]\nallow_test_roots = true\n",
    "\n[measurements]\nallow_software_root = true\n",
    "\n[measurements]\nextra_critical_oids = [\"2.999.1.1\"]\n",
    "\n[tcb]\nignore_unrecognised_vendor_roots = true\n"]

  RootDecisionModules = [
    "libs/repro_attest_verify/src/repro_attest_verify/snp_chain.nim",
    "libs/repro_attest_verify/src/repro_attest_verify/tdx_chain.nim",
    "libs/repro_attest_verify/src/repro_attest_verify/tdx_collateral.nim"]
    ## The three modules that decide which root a confidential-computing
    ## chain may reach. The third is here because a trusted-computing-base
    ## status is established under the SAME pinned root, so a define
    ## there would move the answer just as surely as one next door.

  EnvNames = [
    "REPRO_ATTEST_ALLOW_SOFTWARE_ROOT",
    "REPRO_ATTEST_TEST_TRUST",
    "REPRO_ATTEST_SOFTWARE_ROOT_TEST_TRUST",
    "REPROBUILD_ATTEST_ALLOW_TEST_ROOTS",
    "REPRO_ATTEST_RECOGNISED_CRITICAL_OIDS",
    "REPRO_ATTEST_VENDOR_ROOTS",
    "REPRO_ATTEST_INSECURE",
    "REPRO_TRUST_ANY_ROOT",
    "REPROOS_ATTEST_DEV_MODE"]

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc bytesOfHexLocal(h: string): seq[byte] =
  result = newSeq[byte](h.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(h[2 * i .. 2 * i + 1]))

proc base64Decode(text: string): seq[byte] =
  const Alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  var acc = 0
  var bits = 0
  for c in text:
    if c == '=': break
    let at = Alphabet.find(c)
    if at < 0: continue
    acc = (acc shl 6) or at
    bits += 6
    if bits >= 8:
      bits -= 8
      result.add byte((acc shr bits) and 0xff)

proc pemCertificates(text: string): seq[seq[byte]] =
  const Begin = "-----BEGIN CERTIFICATE-----"
  const End = "-----END CERTIFICATE-----"
  var pos = 0
  while true:
    let b = text.find(Begin, pos)
    if b < 0: break
    let e = text.find(End, b)
    if e < 0: break
    result.add base64Decode(text[b + Begin.len ..< e])
    pos = e + End.len

# The genuine security-processor chain: the vendor's own distribution
# service, and an endorsement certificate a real part was issued.
let milanChain = pemCertificates(KdsMilanChainPem)
let genuineVcek = bytesOfHexLocal(VirteeMilanVcekDerHex)
let milanAsk = milanChain[0]
let milanArk = milanChain[1]
let milanCrl = @[bytesOfHexLocal(KdsMilanCrlDerHex)]

# The genuine trust-domain chain: the one inside a real quote.
let genuineTdxQuote = parseTdxQuote(
  bytesOfHexLocal(GoTdxGuestSprQuoteHex)[0 ..< 4935])
let genuinePlatformCrl = @[bytesOfHexLocal(PcsPckCrlPlatformDerHex)]

# The emulated hierarchies, minted at each backend's own instant so the
# positive control below is at the SAME instant as the refusal.
let markedSnp = sharedSnpTestHierarchy(SnpInstant)
let unmarkedSnp = mintSnpTestHierarchy(SnpInstant, marked = false)
let markedTdx = sharedIntelTestHierarchy(TdxInstant)
let unmarkedTdx = mintIntelTestHierarchy(TdxInstant, marked = false)

proc snpVerdictFor(h: SnpTestHierarchy): AmdChainVerdict =
  evaluateAmdChain(cvmBytesOf(h.vcekDer), cvmBytesOf(h.askDer),
    cvmBytesOf(h.arkDer), @[cvmBytesOf(h.crlDer)], SnpInstant)

proc tdxVerdictFor(h: IntelTestHierarchy): IntelChainVerdict =
  evaluateIntelPckChain(cvmBytesOf(h.leafDer), cvmBytesOf(h.authorityDer),
    cvmBytesOf(h.rootDer), @[cvmBytesOf(h.crlDer)], TdxInstant)

proc policyShapes(backend: CvmBackendUnderTest;
                  digest: string): seq[(string, string)] =
  ## Six documents, from the most permissive the schema admits to the
  ## strictest this harness can write — and SIX DISTINCT ONES. The
  ## caller asserts that, because a list that named six shapes and
  ## contained five documents would be reporting a breadth it does not
  ## have, and the gate next door that this one is modelled on does
  ## exactly that.
  let permissive =
    (case backend
     of cbSnp: PermissiveSnpPolicy
     of cbTdx: PermissiveTdxPolicy)
  result.add ("most permissive the schema admits", permissive)
  result.add ("pinned manifest, certificates required, age bound",
    cvmPolicyText(backend, digest))
  result.add ("pinned manifest, certificates not required",
    cvmPolicyText(backend, digest).replace(
      "require_certificates = true", "require_certificates = false"))
  result.add ("unpinned manifest, certificates required",
    permissive.replace("require_certificates = false",
                       "require_certificates = true"))
  result.add ("challenge required, no age bound",
    permissive.replace("require_challenge = false",
                       "require_challenge = true"))
  result.add ("pinned manifest, no age bound, nothing else required",
    permissive.replace("manifests = []",
                       "manifests = [\"" & digest & "\"]"))

suite "a software root cannot satisfy a genuine-tier policy":

  test "the marked hierarchy is refused under every policy shape":
    for backend in CvmBackendUnderTest:
      let instant = (case backend
                     of cbSnp: SnpInstant
                     of cbTdx: TdxInstant)
      let m = CvmMeasurements(
        snpMeasurementHex: repeat('a', 96),
        tdxMrtdHex: repeat('b', 96),
        tdxRtmrHex: [repeat('1', 96), repeat('2', 96), repeat('3', 96),
                     repeat('4', 96)],
        ovmfDigest: DigestPrefix & repeat('c', 64),
        vcpus: 1, vcpuType: "Milan")
      let digest = cvmManifestDigest(backend, m)
      let shapes = policyShapes(backend, digest)
      check shapes.len == 6
      # Six LABELS and five documents would be a breadth this case does
      # not have, so the documents are required to be distinct.
      var seen: seq[string] = @[]
      for (label, policyText) in shapes:
        check policyText notin seen
        seen.add policyText
      for (label, policyText) in shapes:
        checkpoint($backend & ": " & label)
        var run = buildCvmRun(backend, m, cemNone, instant)
        run.policyText = policyText
        let v = verifyAttestationReport(cvmVerificationRequestFor(run))
        check not v.decision.isAcceptance
        check v.checks[vcCertificateChain].outcome == coFailed
        checkpoint(v.checks[vcCertificateChain].detail)
        check SoftwareRootMarkerTestOid in
          v.checks[vcCertificateChain].detail
        # And the chain is the ONLY thing wrong that this backend can
        # help: the rows outside the structural set all pass, which is
        # the premise the claim rests on.
        var failed: set[VerifierCheck]
        for c in VerifierCheck:
          if v.checks[c].outcome == coFailed: failed.incl c
        check failed <= cvmBaselineFailures(backend)

  test "stripping the mark does not launder the chain":
    ## Leg 1's second half, and the thing the measured-boot tier cannot
    ## say: an UNMARKED test hierarchy is refused anyway, by a different
    ## rule, with wording the marker's refusal does not produce.
    let marked = snpVerdictFor(markedSnp)
    checkpoint("marked: " & $marked.reason & ": " & marked.detail)
    check marked.reason == acUnrecognisedCriticalExtension
    check SoftwareRootMarkerTestOid in marked.detail

    let unmarked = snpVerdictFor(unmarkedSnp)
    checkpoint("unmarked: " & $unmarked.reason & ": " & unmarked.detail)
    check unmarked.reason == acRootIsNotAmd
    check SoftwareRootMarkerTestOid notin unmarked.detail
    check not unmarked.rootMatched
    # The two refusals are different sites with different wording, so a
    # gate asserting one cannot be satisfied by the other.
    check AmdChainMessage[acUnrecognisedCriticalExtension] !=
      AmdChainMessage[acRootIsNotAmd]

    let markedIntel = tdxVerdictFor(markedTdx)
    checkpoint("marked: " & $markedIntel.reason & ": " & markedIntel.detail)
    check markedIntel.reason == tcUnrecognisedCriticalExtension
    check SoftwareRootMarkerTestOid in markedIntel.detail

    let unmarkedIntel = tdxVerdictFor(unmarkedTdx)
    checkpoint("unmarked: " & $unmarkedIntel.reason & ": " &
      unmarkedIntel.detail)
    check unmarkedIntel.reason == tcRootIsNotIntel
    check SoftwareRootMarkerTestOid notin unmarkedIntel.detail
    check not unmarkedIntel.rootMatched
    check IntelChainMessage[tcUnrecognisedCriticalExtension] !=
      IntelChainMessage[tcRootIsNotIntel]

  test "the same evaluators accept a genuine vendor chain":
    ## The positive control, and it is a different claim from every
    ## other case here: without it, each refusal above would also be
    ## produced by an evaluator that refuses everything.
    let snp = evaluateAmdChain(genuineVcek, milanAsk, milanArk, milanCrl,
                               SnpInstant)
    checkpoint("snp: " & $snp.reason & ": " & snp.detail)
    check snp.isAccepted
    check snp.rootMatched
    check snp.rootLine == aplMilan

    let tdx = evaluateIntelPckChain(genuineTdxQuote.pckChain[0],
      genuineTdxQuote.pckChain[1], genuineTdxQuote.pckChain[2],
      genuinePlatformCrl, TdxInstant)
    checkpoint("tdx: " & $tdx.reason & ": " & tdx.detail)
    check tdx.isAccepted
    check tdx.rootMatched

  test "every certificate of each hierarchy carries the mark":
    ## The refusal is not a property of the leaf. There is no position
    ## in either chain at which a test certificate is invisible.
    for (name, der) in [("snp root", markedSnp.arkDer),
                        ("snp signing key", markedSnp.askDer),
                        ("snp endorsement key", markedSnp.vcekDer)]:
      checkpoint(name)
      let c = parseAmdCertificate(cvmBytesOf(der))
      var oids: seq[string] = @[]
      for ext in c.extensions:
        if ext.critical: oids.add ext.oid
      check SoftwareRootMarkerTestOid in oids
    for (name, der) in [("snp root", unmarkedSnp.arkDer),
                        ("snp signing key", unmarkedSnp.askDer),
                        ("snp endorsement key", unmarkedSnp.vcekDer)]:
      checkpoint(name & " (unmarked)")
      let c = parseAmdCertificate(cvmBytesOf(der))
      var oids: seq[string] = @[]
      for ext in c.extensions:
        if ext.critical: oids.add ext.oid
      check SoftwareRootMarkerTestOid notin oids
    for (name, der) in [("tdx root", markedTdx.rootDer),
                        ("tdx authority", markedTdx.authorityDer),
                        ("tdx provisioning key", markedTdx.leafDer)]:
      checkpoint(name)
      check SoftwareRootMarkerTestOid in
        parseCertificate(cvmBytesOf(der)).criticalOids
    for (name, der) in [("tdx root", unmarkedTdx.rootDer),
                        ("tdx authority", unmarkedTdx.authorityDer),
                        ("tdx provisioning key", unmarkedTdx.leafDer)]:
      checkpoint(name & " (unmarked)")
      check SoftwareRootMarkerTestOid notin
        parseCertificate(cvmBytesOf(der)).criticalOids

  test "the root tables are compile-time constants with no room in them":
    ## Leg 2. A value the compiler had to produce cannot have been read
    ## from an environment variable, a file or a flag — and the run-time
    ## half, which a ``static`` cannot make, is that the keys these
    ## hierarchies actually hold are not in those tables.
    static:
      doAssert AmdRootKeys.len == 3
      doAssert AmdRootKeys[aplMilan].commonName == "ARK-Milan"
      doAssert AmdRootKeys[aplGenoa].commonName == "ARK-Genoa"
      doAssert AmdRootKeys[aplTurin].commonName == "ARK-Turin"
      doAssert IntelRootKeys.len == 1
      doAssert IntelRootKeys[0].commonName == "Intel SGX Root CA"
      doAssert RecognisedAmdCriticalOids.len == 2
      doAssert RecognisedIntelCriticalOids.len == 2
      doAssert "2.999.1.1" notin RecognisedAmdCriticalOids
      doAssert "2.999.1.1" notin RecognisedIntelCriticalOids
    for h in [markedSnp, unmarkedSnp]:
      let root = parseAmdCertificate(cvmBytesOf(h.arkDer))
      check root.keyKind == akRsa4096
      check amdRootFor(root.rsaModulus, root.rsaExponent) < 0
    for h in [markedTdx, unmarkedTdx]:
      let root = parseCertificate(cvmBytesOf(h.rootDer))
      check intelRootFor(root.publicKey) < 0
    # The tables are not empty of everything, which is what makes the
    # four refusals above statements about these keys rather than about
    # a lookup that always fails.
    let genuineRoot = parseAmdCertificate(milanArk)
    check amdRootFor(genuineRoot.rsaModulus, genuineRoot.rsaExponent) >= 0
    check intelRootFor(
      parseCertificate(genuineTdxQuote.pckChain[2]).publicKey) >= 0

  test "neither evaluator has an argument that could widen it":
    ## Leg 3. Five arguments, none of them a policy or an anchor; a
    ## sixth does not compile. The type pins in the modules themselves
    ## are the other half, and they are asserted from here too so that
    ## renaming either procedure without renaming its signature type is
    ## red in two places.
    let extra = @[SoftwareRootMarkerTestOid]
    let leaf = cvmBytesOf(markedSnp.vcekDer)
    let mid = cvmBytesOf(markedSnp.askDer)
    let root = cvmBytesOf(markedSnp.arkDer)
    let crls = @[cvmBytesOf(markedSnp.crlDer)]
    check compiles(evaluateAmdChain(leaf, mid, root, crls, SnpInstant))
    check not compiles(
      evaluateAmdChain(leaf, mid, root, crls, SnpInstant, extra))
    let tleaf = cvmBytesOf(markedTdx.leafDer)
    let tmid = cvmBytesOf(markedTdx.authorityDer)
    let troot = cvmBytesOf(markedTdx.rootDer)
    let tcrls = @[cvmBytesOf(markedTdx.crlDer)]
    check compiles(
      evaluateIntelPckChain(tleaf, tmid, troot, tcrls, TdxInstant))
    check not compiles(
      evaluateIntelPckChain(tleaf, tmid, troot, tcrls, TdxInstant, extra))
    static:
      doAssert typeof(evaluateAmdChain) is AmdChainSignature
      doAssert typeof(evaluateIntelPckChain) is IntelPckChainSignature

  test "no build of this repository reaches a different root":
    ## Leg 4, and the one that makes this stronger than the
    ## measured-boot tier's equivalent. There is no accepting evaluator
    ## behind a define because there is no define at all in the three
    ## modules that hold the root decision — and nothing else in either
    ## attestation library declares a procedure of either evaluator's
    ## signature type.
    ##
    ## Read as text rather than argued, and in both directions: the scan
    ## is required to have FOUND the modules and to have found the
    ## evaluators in them, so a path that stopped resolving would be red
    ## rather than vacuously green.
    var seenEvaluators = 0
    for rel in RootDecisionModules:
      let path = repoRoot() / rel
      checkpoint(rel)
      check fileExists(path)
      let text = readFile(path)
      check text.len > 0
      check "when defined(" notin text
      check "when not defined(" notin text
      if "proc evaluateAmdChain*(" in text: inc seenEvaluators
      if "proc evaluateIntelPckChain*(" in text: inc seenEvaluators
    check seenEvaluators == 2

    # And no second declaration of either, anywhere in the two
    # attestation libraries. A `when`-guarded twin in another module
    # would be exactly the shape this case exists to refuse.
    var declarations = 0
    for lib in ["libs/repro_attest/src", "libs/repro_attest_verify/src"]:
      for path in walkDirRec(repoRoot() / lib):
        if not path.endsWith(".nim"): continue
        let text = readFile(path)
        declarations += text.count("proc evaluateAmdChain")
        declarations += text.count("proc evaluateIntelPckChain")
    check declarations == 2

  test "no environment variable moves the refusal, byte for byte":
    ## The behavioural half of leg 2. Nine plausible spellings are set,
    ## and the refusal is compared for BYTE equality rather than for
    ## outcome — a gate that only compared the reason would miss a
    ## verifier that had quietly changed its mind about why.
    let beforeSnp = snpVerdictFor(markedSnp).detail
    let beforeTdx = tdxVerdictFor(markedTdx).detail
    for name in EnvNames:
      putEnv(name, "1")
    for name in EnvNames:
      putEnv(name, "true")
    putEnv("REPRO_ATTEST_RECOGNISED_CRITICAL_OIDS",
           SoftwareRootMarkerTestOid)
    let afterSnp = snpVerdictFor(markedSnp).detail
    let afterTdx = tdxVerdictFor(markedTdx).detail
    for name in EnvNames:
      delEnv(name)
    check beforeSnp.len > 0
    check beforeTdx.len > 0
    check afterSnp == beforeSnp
    check afterTdx == beforeTdx

  test "no policy document can name a vendor root or widen the set":
    ## Leg 5. The schema defines no clause for this, and the parser
    ## refuses a clause it does not define rather than ignoring it — so
    ## the nine spellings below are not "unsupported", they are
    ## unspellable.
    for base in [PermissiveSnpPolicy, PermissiveTdxPolicy]:
      for clause in WideningClauses:
        checkpoint(clause.strip())
        var refused = false
        try:
          discard parseAttestationPolicy(base & clause, "<widened>")
        except PolicyError as err:
          refused = true
          checkpoint(err.msg)
          check ("is not part of" in err.msg) or ("is set twice" in err.msg)
        check refused
    # And the unmodified documents, which differ only by the absence of
    # the clause, parse — so the refusals above are about the clause.
    check parseAttestationPolicy(PermissiveSnpPolicy,
      "<permissive>").backends == @[abSevSnp]
    check parseAttestationPolicy(PermissiveTdxPolicy,
      "<permissive>").backends == @[abTdx]
