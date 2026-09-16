## With the emulator present, a genuine-tier policy still refuses
## emulated evidence — and not because a flag defaults off.
##
## ## What this gate is for
##
## An evidence emulator is a machine for producing attestations that look
## real. The whole value of one is that it exercises the production
## codecs, the production reader and the production verifier; the whole
## danger of one is that the same property makes its output acceptable.
## Shipping an emulator alongside a "don't accept it" setting would be
## shipping a hole with a note attached.
##
## So the refusal here has to be STRUCTURAL, and the standard for that is
## the one this repository already set for a software-root test
## hierarchy: it is not a setting, it is which binary you are running.
##
## ## The four legs, and what each is worth
##
## 1. **The mark.** Every certificate the emulator's hierarchy issues
##    carries a *critical* extension under the ``2.999`` arc ITU-T set
##    aside for examples. RFC 5280 §4.2 requires a certificate-using
##    system to reject a certificate carrying a critical extension it
##    does not recognise; a production build recognises three, none of
##    them that one. The refusal is about the certificate's own contents,
##    so installing the root in the trust store does not lift it — and
##    that is measured below rather than argued.
## 2. **No knob.** ``newEmulatedTpm2Driver`` takes a scenario and an
##    instant. There is no argument by which the hierarchy could be minted
##    unmarked — asserted about the same occurrence the name is spelled
##    at, so a typo cannot satisfy it — and the scenario has no field for
##    it either, asserted as that type's whole FIELD SET rather than as
##    the absence of one name.
## 3. **The chain is always bundled, so the rule is always reached.**
##    A bundled chain that is refused is a *violation*, and a violation is
##    a failure whatever the policy said about requiring a chain. A policy
##    cannot decline to look.
## 4. **No policy the schema admits accepts it.** Not "the default policy
##    refuses": every axis the grammar has is pushed to its most
##    permissive value, one at a time and all at once, and the answer does
##    not move.
##
## And the accepting evaluator is not in this binary at all. This file is
## compiled WITHOUT ``-d:reproAttestSoftwareRootTestTrust``, and it
## asserts that the two symbols that define brings in do not compile —
## pinning each spelling against a constant every build can read, on the
## same occurrence, because from inside a build that lacks a symbol a
## misspelling and an absence are the same thing.
##
## ## Mocking
##
## None.

import std/[options, os, strutils, times, unittest]

import repro_attest
import repro_attest_verify
import repro_cli_support/attest

import ./emulator_scenarios
import ./evidence_emulator
import ./software_root_test_pki

let nowSeconds = getTime().toUnix
let nowMillis = nowSeconds * 1000

let thisDir = currentSourcePath().parentDir
let repoRoot = thisDir.parentDir.parentDir

proc emulatedRun(mutation = emNone): (EmulatedTpm2Driver, EmulatedRun) =
  let d = newEmulatedTpm2Driver(defaultEmulatorScenario(mutation), nowSeconds)
  (d, buildRun(d, mutation, nowMillis))

proc verdictUnder(run: EmulatedRun; policyText: string): Verdict =
  var req = verificationRequestFor(run)
  req.policy = parseAttestationPolicy(policyText, "<policy under test>")
  verifyAttestationReport(req)

const
  MostPermissivePolicy = """
schema = "reproos.attestation-policy.v1"

# Every axis this grammar has, at its most permissive value: every tier,
# every backend, the tier with no root of trust admitted, no manifest
# pinned, no chain required, no challenge required and no age bound.
# There is no weaker document the parser will accept.
[accept]
tiers = ["mock", "tpm", "cvm"]
backends = ["mock", "tpm2", "sev-snp", "tdx"]
allow_mock = true

[measurements]
manifests = []
require_certificates = false

[tcb]
# The grammar refuses a policy that admits a confidential-computing
# backend and bounds no trusted computing base, so the most permissive
# document is the one whose floors are the lowest values it will take,
# not the one that omits them.
sev-snp.min_tcb = { bootloader = 0, tee = 0, snp = 0, microcode = 0 }
tdx.min_tcb_status = "OutOfDateConfigurationNeeded"
allow_grace_days = 365

[freshness]
max_challenge_age_seconds = 0
require_challenge = false
"""

  ChainRuleWording = "Its issuer said to refuse the certificate"
    ## The wording the CHAIN-element rule alone emits. The trust-store
    ## rule produces the SAME ``ChainRejection`` value, so a gate that
    ## asserted only the value could not tell which of the two refused —
    ## and would keep passing after the one it was written for was
    ## deleted. Every assertion below that names this also asserts the
    ## absence of the other's wording.
  TrustStoreRuleWording = "configured by accident"

proc importLinesOf(path: string): seq[string] =
  ## Every import/include line of a Nim file, with comments stripped
  ## first so a module named only in prose is not read as an edge.
  for rawLine in readFile(path).splitLines:
    var line = rawLine
    let hash = line.find('#')
    if hash >= 0: line = line[0 ..< hash]
    line = line.strip()
    if line.startsWith("import ") or line.startsWith("include ") or
       line.startsWith("from "):
      result.add line

suite "the evidence emulator is not a verifier bypass":

  test "a production build refuses valid emulated evidence":
    ## The headline. Nothing is wrong with this attestation: the
    ## signature verifies under the certified key, the log replays to the
    ## digest the structure carries, the measurement is the manifest's,
    ## the challenge is fresh and the envelope is consistent. It is
    ## refused because of what certified the key.
    let (_, run) = emulatedRun()
    let v = verifyAttestationReport(verificationRequestFor(run))
    checkpoint($v.decision & " failed: " & $v.failedChecks)
    checkpoint(v.checks[vcCertificateChain].detail)
    check not v.decision.isAcceptance
    check v.failedChecks == @[vcCertificateChain]
    check SoftwareRootMarkerTestOid in v.checks[vcCertificateChain].detail
    check ProductionEvaluatorName in v.checks[vcCertificateChain].detail
    check ChainRuleWording in v.checks[vcCertificateChain].detail
    check TrustStoreRuleWording notin v.checks[vcCertificateChain].detail
    # Everything else passed, which is what makes the refusal a statement
    # about the hierarchy and not about the emulator being unconvincing.
    check v.checks[vcNativeEvidence].outcome == coPassed
    check v.checks[vcReportDataBinding].outcome == coPassed
    check v.checks[vcMeasurementMatch].outcome == coPassed
    check v.checks[vcChallengeMatch].outcome == coPassed
    check v.checks[vcManifestPinned].outcome == coPassed
    # And the signature WAS checked: the refusal is not a reader that
    # gave up early.
    check SignatureCheckedNotePrefix in v.checks[vcNativeEvidence].detail

  test "no policy this schema admits accepts it":
    ## Not "the default policy refuses".
    ##
    ## Six documents: the most permissive one the grammar will accept,
    ## the strict one, and every axis moved to its permissive end ONE AT A
    ## TIME from the strict document — because an all-at-once sweep and a
    ## one-at-a-time sweep fail differently, and only the second says
    ## which axis was tried. Each axis is a list of edits rather than one,
    ## because the grammar couples two of them: a document that bounds a
    ## challenge age it does not require is refused by the parser, and so
    ## is one whose ``allow_mock`` and ``tiers`` disagree, and so is one
    ## naming a tier no admitted backend serves, and so is one that admits
    ## the mock tier while pinning a manifest that tier can never be
    ## compared against. Those axes therefore move two and four keys, or
    ## they are not policies at all.
    ##
    ## That the grammar has these couplings is itself worth recording:
    ## "the most permissive policy" is a smaller set of documents than a
    ## reader of the schema would guess, and a sweep written without
    ## running it would have swept documents the parser refuses and called
    ## the refusals a result.
    ##
    ## "Every tier" and "every backend" are not among the one-at-a-time
    ## edits for the same reason: the parser refuses a document that
    ## admits a confidential-computing backend and bounds no trusted
    ## computing base. Both are exercised by the most permissive document,
    ## which carries the ``[tcb]`` table that makes them spellable.
    let (_, run) = emulatedRun()
    var policies: seq[(string, string)] = @[
      ("most permissive", MostPermissivePolicy),
      ("strict", run.policyText)]
    for (name, edits) in [
        ("no chain required",
         @[("require_certificates = true", "require_certificates = false")]),
        ("no manifest pinned",
         @[("manifests = [\"" & emulatorManifestDigest() & "\"]",
            "manifests = []")]),
        ("no challenge at all",
         @[("require_challenge = true", "require_challenge = false"),
           ("max_challenge_age_seconds = 120",
            "max_challenge_age_seconds = 0")]),
        ("mock tier admitted",
         @[("allow_mock = false", "allow_mock = true"),
           ("tiers = [\"tpm\"]", "tiers = [\"mock\", \"tpm\"]"),
           ("backends = [\"tpm2\"]", "backends = [\"mock\", \"tpm2\"]"),
           ("manifests = [\"" & emulatorManifestDigest() & "\"]",
            "manifests = []")])]:
      var text = run.policyText
      for (needle, replacement) in edits:
        # The needle must be PRESENT, or the "edit" is a no-op and this
        # row is the strict policy under another name.
        check needle in text
        text = text.replace(needle, replacement)
      check text != run.policyText
      policies.add (name, text)
    check policies.len == 6

    for (name, text) in policies:
      checkpoint(name)
      # The document is a document: refused by the verifier rather than
      # by its own parser, which is the difference between "no policy
      # accepts it" and "no policy was read".
      let parsed = parseAttestationPolicy(text, "<policy under test>")
      check parsed.tiers.len > 0
      let v = verdictUnder(run, text)
      checkpoint($v.decision & " failed: " & $v.failedChecks)
      check not v.decision.isAcceptance
      check vcCertificateChain in v.failedChecks
      check v.checks[vcCertificateChain].outcome == coFailed
      check SoftwareRootMarkerTestOid in v.checks[vcCertificateChain].detail
      check ChainRuleWording in v.checks[vcCertificateChain].detail
      check TrustStoreRuleWording notin v.checks[vcCertificateChain].detail

  test "the refusal survives the operator installing the root by hand":
    ## The strongest form of the question. A trust store is the one place
    ## an operator gets to say "trust this" — and the refusal is about the
    ## certificate's own contents, so saying it changes nothing.
    ##
    ## The control is in the same case: with an EMPTY trust store the
    ## refusal is a different one, so "refused" above is not a verifier
    ## that refuses everything handed to it.
    let (d, run) = emulatedRun()
    check run.anchorDer == @[d.emulatedAnchorDer]
    let installed = verifyAttestationReport(verificationRequestFor(run))
    check not installed.decision.isAcceptance
    check ChainRuleWording in installed.checks[vcCertificateChain].detail

    var empty = run
    empty.anchorDer = @[]
    let unanchored = verifyAttestationReport(verificationRequestFor(empty))
    check not unanchored.decision.isAcceptance
    # A DIFFERENT refusal, and the marker rule is what fires first in
    # both — so the two are told apart by the anchor count the message
    # carries rather than by the rule.
    check "trust store of 0 anchor(s)" notin
      unanchored.checks[vcCertificateChain].detail
    check ChainRuleWording in unanchored.checks[vcCertificateChain].detail

    # And with the marker rule out of reach, an empty store IS the
    # refusal — established by asking the evaluator directly about a
    # chain minted without the mark, which is the only way to show that
    # the trust store is load-bearing at all in this build.
    let unmarked = mintHierarchy(nowSeconds, marked = false)
    let reached = evaluateProductionChain(unmarked.akChain,
      newSeq[X509Cert](), unmarked.crlsOf, akExpectation(nowSeconds))
    check reached.reason == crUnknownRoot
    let anchored = evaluateProductionChain(unmarked.akChain,
      unmarked.anchorsOf, unmarked.crlsOf, akExpectation(nowSeconds))
    check anchored.isAccepted

  test "every certificate the emulator issues carries the mark, by value":
    ## Decoded from DER by the production reader, not read off the
    ## minting side's intent. The marker is asserted present on every
    ## element AND asserted to be one this build does not recognise, so a
    ## build that quietly started recognising it reddens here.
    let (d, _) = emulatedRun()
    let chain = d.emulatedChain
    check chain.len == 3
    for i, der in chain:
      checkpoint("element " & $i)
      let cert = parseCertificateBytes(der)
      check SoftwareRootMarkerTestOid in cert.criticalOids
      var found = false
      for ext in cert.extensions:
        if ext.oid == SoftwareRootMarkerTestOid:
          found = true
          check ext.critical
          check MarkerText in cast[string](ext.value)
      check found
    check SoftwareRootMarkerTestOid notin RecognisedCriticalOids
    static:
      # A value the compiler had to produce cannot have come from an
      # environment variable, a file or a flag.
      doAssert RecognisedCriticalOids.len == 3
      doAssert "2.999.1.1" notin RecognisedCriticalOids
    # The trust anchor carries it too, which is why installing it cannot
    # help: the store is examined before the chain is matched against it.
    check SoftwareRootMarkerTestOid in
      parseCertificateBytes(d.emulatedAnchorDer).criticalOids

  test "the mark cannot be edited out of the bytes without breaking them":
    ## What somebody holding an emulated report can do to it is change
    ## bytes; they do not hold the issuer's key. The criticality flag is
    ## one byte and editing it is the cheapest possible attempt, so it is
    ## the one tried here — and the refusal MOVES rather than
    ## disappearing.
    let (d, run) = emulatedRun()
    var chain = d.emulatedChain
    # DER TRUE is 0xFF inside a one-byte BOOLEAN. The marker extension is
    # located by its own OID encoding, so this finds the flag rather than
    # a byte at a guessed offset.
    let markerOidDer = derOid(SoftwareRootMarkerTestOid)
    var oidBytes = ""
    for b in markerOidDer: oidBytes.add char(b)
    let at = chain[0].find(oidBytes)
    check at >= 0
    let flagAt = at + oidBytes.len + 2   # 0x01 0x01 <value>
    check chain[0][flagAt - 2] == '\x01'
    check chain[0][flagAt] == '\xFF'
    chain[0][flagAt] = '\x00'
    let report = parseAttestationReport(run.reportText, "<emulated>")
    var laundered = run
    laundered.reportText = renderAttestationReport(attestationReport(
      report.backend, EmulatorTimestamp, report.challenge, report.bindings,
      authoritativeEvidence(report), report.claims, some(chain)))
    let v = verifyAttestationReport(verificationRequestFor(laundered))
    checkpoint(v.checks[vcCertificateChain].detail)
    check not v.decision.isAcceptance
    check vcCertificateChain in v.failedChecks
    # It is no longer the marker rule that refuses — the edit worked, as
    # an edit — and the certificate is refused anyway, because the byte
    # sits inside the signed body and because DER has one spelling of a
    # default.
    # It is no longer the MARKER rule that refuses — the edit worked, as
    # an edit — and the certificate is refused anyway, one rule earlier:
    # the flag sits inside the signed body, and DER has exactly one
    # spelling of a default, so a criticality written as an explicit
    # FALSE is not a certificate this reader will read at all.
    check ChainRuleWording notin v.checks[vcCertificateChain].detail
    check "did not read as a certificate" in
      v.checks[vcCertificateChain].detail
    check "DER writes TRUE as 0xFF and omits FALSE" in
      v.checks[vcCertificateChain].detail
    # The unedited chain reaches a DIFFERENT rule, so the two refusals
    # are distinguishable and this one is about the edit.
    let untouched = verifyAttestationReport(verificationRequestFor(run))
    check ChainRuleWording in untouched.checks[vcCertificateChain].detail
    check "did not read as a certificate" notin
      untouched.checks[vcCertificateChain].detail

  test "the accepting evaluator and report driver are not in this binary":
    ## The spelling and the absence are asserted about the SAME
    ## occurrence, through a template that reads the call's own text.
    ## Split across two lines, a typo goes on the ``compiles`` line and
    ## the line above it still spells the name correctly — which is a
    ## vacuous pin, and was measured as one when this technique was first
    ## written.
    template mustNotCompile(symbol: string; call: untyped) =
      check astToStr(call).startsWith(symbol & "(")
      check not compiles(call)

    let (d, run) = emulatedRun()
    let chain = d.emulatedChain
    var anchors: seq[X509Cert] = @[]
    for der in run.anchorDer: anchors.add parseCertificateBytes(der)
    var crls: seq[X509Crl] = @[]
    for der in run.crlDer: crls.add parseCrlBytes(der)
    let expect = akExpectation(nowSeconds)
    check compiles(evaluateProductionChain(chain, anchors, crls, expect))
    mustNotCompile(SoftwareRootTestChainSymbol,
      evaluateSoftwareRootTestChain(chain, anchors, crls, expect))

    let report = parseAttestationReport(run.reportText, "<emulated>")
    let reading = readAuthoritativeEvidence(report)
    var req = verificationRequestFor(run)
    check compiles(verifyWithReading(req, report, reading))
    mustNotCompile(SoftwareRootTestReportSymbol,
      verifySoftwareRootTestReport(req, report, reading))

    # And the surface entry point — the one the command line calls — is
    # reached by name, in this binary, and refuses. That behavioural fact
    # is what carries the claim; an arity assertion about it would be one
    # more `not compiles` whose vacuity this file has already had to work
    # around twice, and is not worth a third.
    check compiles(verifyAttestationReport(req))
    check not verifyAttestationReport(req).decision.isAcceptance

  test "the emulator offers no spelling that mints an unmarked hierarchy":
    ## The knob that does not exist, pinned the same way: the spelling and
    ## the absence on one occurrence.
    template mustNotCompile(symbol: string; call: untyped) =
      check astToStr(call).startsWith(symbol & "(")
      check not compiles(call)

    let scenario = defaultEmulatorScenario()
    check compiles(newEmulatedTpm2Driver(scenario, nowSeconds))
    mustNotCompile("newEmulatedTpm2Driver",
      newEmulatedTpm2Driver(scenario, nowSeconds, marked = false))
    mustNotCompile("newEmulatedTpm2Driver",
      newEmulatedTpm2Driver(scenario, nowSeconds, false))
    # The scenario has no field for it either, so there is no route in
    # through the argument that IS there. Asserted as the type's FIELD
    # SET rather than as ``not compiles(EmulatorScenario(marked: ...))``:
    # a field that does not exist and a field whose name was mistyped
    # produce the same compile error, so that pin would pass however it
    # were misspelled. A field list the compiler had to produce cannot.
    static:
      var fields: seq[string] = @[]
      for name, _ in EmulatorScenario().fieldPairs: fields.add name
      doAssert fields == @["mutation", "firmwareVersion", "quotedRegisters"],
        "EmulatorScenario carries " & $fields
    # And the decision is a compile-time constant of the emulator's own.
    static:
      doAssert EmulatedHierarchyIsMarked

  test "no environment variable moves the answer, byte for byte":
    ## The behavioural half. It is a demonstration and not the proof —
    ## the proof is the ``static:`` blocks above and the symbols that are
    ## not in this binary — but a refusal that DID read the environment
    ## would be caught here, and the comparison is byte for byte rather
    ## than by outcome, because "still refused" would survive a refusal
    ## that had changed its reason.
    let (_, run) = emulatedRun()
    let before = verifyAttestationReport(verificationRequestFor(run))
    let baseline = renderVerdictText(before)
    check not before.decision.isAcceptance
    for name in ["REPRO_ATTEST_ALLOW_SOFTWARE_ROOT",
                 "REPRO_ATTEST_TEST_TRUST",
                 "REPRO_ATTEST_EMULATOR",
                 "REPRO_ATTEST_ACCEPT_EMULATED_EVIDENCE",
                 "REPROOS_ATTESTATION_TEST_MODE",
                 "REPROBUILD_ATTEST_INSECURE",
                 "REPRO_ATTEST_RECOGNISE_CRITICAL_OIDS",
                 "REPRO_ATTEST_TRUST_ANYTHING"]:
      putEnv(name, "1")
    putEnv("REPRO_ATTEST_RECOGNISE_CRITICAL_OIDS", SoftwareRootMarkerTestOid)
    let after = verifyAttestationReport(verificationRequestFor(run))
    check renderVerdictText(after) == baseline

  test "the command line refuses it too, and says so in its exit status":
    ## The surface a script reads. A library that refused and a command
    ## that exited 0 would be the same defect this repository has already
    ## found once, in the other direction.
    let (_, run) = emulatedRun()
    let dir = getTempDir() / "repro-emulator-bypass-" &
      $getCurrentProcessId() & "-" & $nowSeconds
    createDir(dir)
    try:
      writeFile(dir / "report.json", run.reportText)
      writeFile(dir / "policy.toml", run.policyText)
      writeFile(dir / "manifest.toml", run.manifestText)
      var args = @["verify", "--report-file", dir / "report.json",
                   "--policy", dir / "policy.toml",
                   "--manifest", dir / "manifest.toml",
                   "--challenge", run.expectedChallengeHex,
                   "--out", dir / "verdict.txt"]
      for i, der in run.anchorDer:
        writeFile(dir / ("anchor-" & $i & ".der"), der)
        args.add @["--trust-anchor", dir / ("anchor-" & $i & ".der")]
      for i, der in run.crlDer:
        writeFile(dir / ("crl-" & $i & ".der"), der)
        args.add @["--revocation-list", dir / ("crl-" & $i & ".der")]
      check runAttestCommand(args) == AttestExitRejected
      let verdict = readFile(dir / "verdict.txt")
      check ("verdict: " & $vdRejected) in verdict
      check SoftwareRootMarkerTestOid in verdict
      # The most permissive policy the grammar admits, through the same
      # command: the exit status does not move either.
      writeFile(dir / "policy.toml", MostPermissivePolicy)
      check runAttestCommand(args) == AttestExitRejected

      # And a trust store the command cannot read is a REFUSAL rather
      # than a smaller trust store. Without a case that presents one,
      # that rule has no reachable input and nothing proves it fires —
      # and a verifier that silently dropped an anchor an operator named
      # would be trusting a set nobody configured.
      writeFile(dir / "anchor-bad.der", "not a certificate at all")
      var withBad = args
      withBad.add @["--trust-anchor", dir / "anchor-bad.der"]
      check runAttestCommand(withBad) == AttestExitUsage
      # The same shape on the other flag, because the two are separate
      # loops and one can be repaired without the other.
      writeFile(dir / "crl-bad.der", "not a revocation list at all")
      var withBadCrl = args
      withBadCrl.add @["--revocation-list", dir / "crl-bad.der"]
      check runAttestCommand(withBadCrl) == AttestExitUsage
      # A path that does not exist is refused too, and distinguishably:
      # "unreadable" and "absent" are different things to tell an
      # operator.
      var missing = args
      missing.add @["--trust-anchor", dir / "anchor-absent.der"]
      check runAttestCommand(missing) == AttestExitUsage
      # The revocation-list flag has its own pair of refusals, in its own
      # loop; one can be repaired without the other, so both are reached.
      var missingCrl = args
      missingCrl.add @["--revocation-list", dir / "crl-absent.der"]
      check runAttestCommand(missingCrl) == AttestExitUsage
      # The positive control: with every named file present and readable,
      # the same command reaches a VERDICT rather than a usage error, so
      # the four refusals above are about the files and not about the
      # flags existing.
      check runAttestCommand(args) == AttestExitRejected
    finally:
      removeDir(dir)

  test "the hole this does NOT close: a report that bundles no chain":
    ## Recorded as an assertion rather than as a sentence, because an
    ## absence nobody measures is an absence nobody notices.
    ##
    ## The refusal above rests on the chain. Strip the chain from the
    ## envelope — which the holder of a report can do, since nothing signs
    ## the envelope — and there is no key left to check the attestation
    ## structure against; this build fetches none, so no public-key
    ## operation is performed, and under a policy that does not require a
    ## bundled chain the same emulated evidence is ACCEPTED on its
    ## measurement alone.
    ##
    ## That is the pre-existing limit this work narrows and does not
    ## close. It is asserted here so that a build which closes it reddens
    ## and forces this row to be rewritten, instead of leaving a stale
    ## paragraph claiming a hole that is no longer there.
    let (_, run) = emulatedRun()
    let report = parseAttestationReport(run.reportText, "<emulated>")
    var chainless = run
    chainless.reportText = renderAttestationReport(attestationReport(
      report.backend, EmulatorTimestamp, report.challenge, report.bindings,
      authoritativeEvidence(report), report.claims, none(seq[string])))
    chainless.policyText = run.policyText.replace(
      "require_certificates = true", "require_certificates = false")
    check chainless.policyText != run.policyText
    let v = verdictUnder(chainless, chainless.policyText)
    checkpoint($v.decision & " failed: " & $v.failedChecks)
    check v.decision.isAcceptance
    check v.checks[vcCertificateChain].outcome == coSkipped
    # And the verdict SAYS so, in the channel a reader of an acceptance
    # has: no key was checked, and the skipped check is named.
    #
    # Read off the CAVEAT LIST rather than off the rendering. The note has
    # two producers — the caveat and the reader's own finding — so a
    # search of the rendered verdict is satisfied by either, and deleting
    # the caveat left such a search green when it was measured.
    var statedAsCaveat = false
    for c in v.caveats:
      if NoSignatureCheckedNote in c: statedAsCaveat = true
    check statedAsCaveat
    check "certificate-chain" in renderVerdictText(v)
    # Under the policy that DOES require a chain, the same document is
    # refused — so the hole is exactly "a policy that does not ask".
    let asked = verdictUnder(chainless, run.policyText)
    check not asked.decision.isAcceptance
    check asked.failedChecks == @[vcCertificateChain]

  test "the reader's new refusals are reached rather than merely written":
    ## Four refusal sites were added to the measured-boot reader by the
    ## join between a chain and a quote. A refusal with no reachable input
    ## is a constant with a message attached, and this repository has
    ## found that shape often enough to stop taking it on trust — so each
    ## is reached here, from a report built for the purpose, and each is
    ## required to be told apart from the others by a phrase the other
    ## three do not carry.
    let (d, run) = emulatedRun()
    let good = parseAttestationReport(run.reportText, "<emulated>")
    let evidence = authoritativeEvidence(good)
    let ev = parseTpm2Evidence(evidence)

    proc readingOf(r: AttestationReport): string =
      let reading = readAuthoritativeEvidence(r)
      check reading.finding.kind == fkViolated
      reading.finding.detail

    proc reportWith(evidenceBytes: string;
                    chain: Option[seq[string]]): AttestationReport =
      result = attestationReport(good.backend, EmulatorTimestamp,
        good.challenge, good.bindings, evidenceBytes, good.claims, chain)

    # 1. A record declaring a chain and carrying no element of one. The
    #    envelope's parser refuses that document, so this site is
    #    reachable only from a report a CALLER assembled — which the
    #    embedding seam permits, which is why the rule is there.
    var emptyChain = reportWith(evidence, some(d.emulatedChain))
    emptyChain.certificates = some(newSeq[string]())
    let d1 = readingOf(emptyChain)
    checkpoint(d1)
    check "carries no element of one" in d1

    # 2. A leaf that is not a certificate.
    let d2 = readingOf(reportWith(evidence,
      some(@["not a certificate at all", d.emulatedChain[1],
             d.emulatedChain[2]])))
    checkpoint(d2)
    check "did not read as a certificate" in d2

    # 3. A structure signed under a scheme this build cannot check. The
    #    refusal has to exist: accepting it unchecked would be a verifier
    #    that treats "I cannot verify this" as "this verified".
    let wrongScheme = composeTpm2Evidence(Tpm2Evidence(
      attestBytes: ev.attestBytes,
      signatureBytes: serializeSignature(TpmtSignature(
        sigAlg: TpmAlgEcdsa, hashAlg: TpmAlgSha384, kind: tskEcc,
        signatureR: tpm2EvidenceQuote(ev).signature.signatureR,
        signatureS: tpm2EvidenceQuote(ev).signature.signatureS)),
      eventLogBytes: ev.eventLogBytes))
    let d3 = readingOf(reportWith(wrongScheme, some(d.emulatedChain)))
    checkpoint(d3)
    check "an algorithm this verifier cannot check" in d3

    # 4. A signature that does not verify.
    let q = tpm2EvidenceQuote(ev)
    var flipped = q.signature.signatureS
    flipped[^1] = char(uint8(flipped[^1]) xor 0x01'u8)
    let badSig = composeTpm2Evidence(Tpm2Evidence(
      attestBytes: ev.attestBytes,
      signatureBytes: serializeSignature(TpmtSignature(
        sigAlg: TpmAlgEcdsa, hashAlg: TpmAlgSha256, kind: tskEcc,
        signatureR: q.signature.signatureR, signatureS: flipped)),
      eventLogBytes: ev.eventLogBytes))
    let d4 = readingOf(reportWith(badSig, some(d.emulatedChain)))
    checkpoint(d4)
    check "does not verify under the public key" in d4

    # No two of the four hide behind one another.
    let phrases = ["carries no element of one", "did not read as a certificate",
                   "an algorithm this verifier cannot check",
                   "does not verify under the public key"]
    let details = [d1, d2, d3, d4]
    for i in 0 ..< phrases.len:
      for j in 0 ..< details.len:
        if i == j: continue
        check phrases[i] notin details[j]

    # And the unmutated report still READS, so none of the above is a
    # reader that has simply stopped working.
    check readAuthoritativeEvidence(good).finding.kind == fkSatisfied

  test "the signature is checked over the MESSAGE, not only under a key":
    ## The case above moves the SIGNATURE, and the companion gate's
    ## cross-check moves the KEY. Both leave the signed bytes alone, so
    ## both stay green under a verifier that checks a real signature by a
    ## real key over the wrong message — which is the third way a join
    ## can be written and not have joined anything.
    ##
    ## Here the MESSAGE is what moves: one byte inside the structure the
    ## signature covers, with the signature and the chain untouched. The
    ## moved bytes are required to still PARSE, and to parse to something
    ## DIFFERENT, so the refusal is the signature's and not the codec's —
    ## the reader would otherwise have refused this on its way in and the
    ## case would prove nothing about the public-key operation.
    ##
    ## What it does not separate, stated so nobody reads it as more: a
    ## verifier checking a FAITHFUL re-serialisation of the record it
    ## parsed would still refuse this, because the re-serialisation would
    ## carry the moved byte too. The bytes-that-arrived rule is there for
    ## a codec that round-trips to something else, and no input this
    ## repository has reaches that.
    let (d, run) = emulatedRun()
    let good = parseAttestationReport(run.reportText, "<emulated>")
    let ev = parseTpm2Evidence(authoritativeEvidence(good))
    let bound = tpm2EvidenceQuote(ev).attest.extraData
    check bound.len == 64
    let at = ev.attestBytes.find(bound)
    check at >= 0
    var moved = ev.attestBytes
    moved[at] = char(uint8(moved[at]) xor 0xFF'u8)
    check moved != ev.attestBytes
    check moved.len == ev.attestBytes.len
    let reparsed = parseQuote(moved, ev.signatureBytes)
    check qualifyingData(reparsed) != bound
    let tampered = attestationReport(good.backend, EmulatorTimestamp,
      good.challenge, good.bindings,
      composeTpm2Evidence(Tpm2Evidence(attestBytes: moved,
        signatureBytes: ev.signatureBytes, eventLogBytes: ev.eventLogBytes)),
      good.claims, some(d.emulatedChain))
    let reading = readAuthoritativeEvidence(tampered)
    checkpoint(reading.finding.detail)
    check reading.finding.kind == fkViolated
    check "does not verify under the public key" in reading.finding.detail
    # The positive control: the same chain and the same signature over the
    # UNMOVED bytes read fine, so the refusal is about the one byte.
    check readAuthoritativeEvidence(good).finding.kind == fkSatisfied

  test "the signature converter's scalar bound is pinned AT the bound":
    ## A ``TPMT_SIGNATURE`` may carry a 128-byte ECC parameter, so a
    ## signature wider than a P-256 scalar arrives through the codec
    ## intact and the converter has to refuse it rather than truncate —
    ## a truncated scalar still verifies against SOMETHING.
    ##
    ## Pinned at 32 and 33 rather than at 32 and 128: a bound tested with
    ## a value far past it is satisfied by an off-by-many, and the
    ## off-by-one is the error a reviewer is looking for.
    var r32 = newSeq[byte](32)
    var s32 = newSeq[byte](32)
    for i in 0 ..< 32:
      r32[i] = byte(i + 1)
      s32[i] = byte(64 - i)
    check ecdsaSigValueDer(r32, s32).len > 0
    var r33 = r32
    r33.insert(0x01'u8, 0)
    check r33.len == 33
    check ecdsaSigValueDer(r33, s32).len == 0
    var s33 = s32
    s33.insert(0x01'u8, 0)
    check ecdsaSigValueDer(r32, s33).len == 0
    check ecdsaSigValueDer(newSeq[byte](0), s32).len == 0
    check ecdsaSigValueDer(r32, newSeq[byte](0)).len == 0

  test "the emulator is in no product binary and names no verifier symbol":
    ## Two directions of one claim, both read off the source tree.
    ##
    ## A module that no shipped code imports cannot be reached from one,
    ## whatever it contains; and a module that names no verifier symbol
    ## cannot be a verifier however it is reached. Each is asserted
    ## separately because each can be broken without the other.
    let emulator = thisDir / "evidence_emulator.nim"
    check fileExists(emulator)
    for line in importLinesOf(emulator):
      checkpoint(line)
      check "repro_attest_verify" notin line
      check "repro_cli_support" notin line
    # The positive control: the file DOES import something, so the loop
    # above is not passing over an empty sequence.
    check importLinesOf(emulator).len >= 2

    # And the import list is NOT the whole of it, which is why the check
    # above is not the claim. ``software_root_test_pki`` imports
    # ``repro_attest_verify`` for the types it mints into, so the verifier
    # package is one hop away and an import-line sweep would call that
    # clean. What actually holds is that this file names no verifier
    # symbol ANYWHERE — asserted over the whole source, imports and body
    # alike, so a call inlined beside an untouched import list is caught.
    let emulatorText = readFile(emulator)
    for symbol in ["verifyAttestationReport", "verifyWithReading",
                   "evaluateProductionChain", "evaluateSoftwareRootTestChain",
                   "verifySoftwareRootTestReport", "readAuthoritativeEvidence",
                   "renderVerdictText", "VerifierCheck", "X509Cert",
                   "repro_attest_verify", "repro_cli_support"]:
      checkpoint(symbol)
      check symbol notin emulatorText
    # The positive control for THAT sweep, and it is deliberately NOT
    # "the same symbols are found in this file". They would be: the list
    # above is in this file, as string literals, so such a control is
    # satisfied by the search term rather than by anything it searched.
    # (Written that way first, and measured as vacuous.) The control that
    # works is over the SAME text the sweep reads: a symbol the emulator
    # really does contain has to be found, and the text has to be the
    # file rather than an empty read.
    check emulatorText.len > 5_000
    for present in ["EmulatedTpm2Driver", "newEmulatedTpm2Driver",
                    "applyEvidenceFault"]:
      checkpoint(present)
      check present in emulatorText
    # And the hop is real rather than assumed, so the paragraph above is
    # not describing a situation that has quietly gone away.
    var pkiReachesVerifier = false
    for line in importLinesOf(thisDir / "software_root_test_pki.nim"):
      if "repro_attest_verify" in line: pkiReachesVerifier = true
    check pkiReachesVerifier

    var importers: seq[string] = @[]
    for root in ["libs", "apps"]:
      let dir = repoRoot / root
      check dirExists(dir)
      for path in walkDirRec(dir):
        if not path.endsWith(".nim"): continue
        for line in importLinesOf(path):
          if "evidence_emulator" in line or "emulator_scenarios" in line:
            importers.add path
    check importers.len == 0
    # And the walk really walked: a sweep that visited nothing would
    # report the same zero.
    var scanned = 0
    for root in ["libs", "apps"]:
      for path in walkDirRec(repoRoot / root):
        if path.endsWith(".nim"): inc scanned
    check scanned > 100
