## `reproos.attestation-policy.v1` — the parser refuses what it cannot
## honour, and what it cannot honour includes documents that are well
## formed.
##
## ## What this gate is worth
##
## A measurement policy is the only hand-edited document in the
## attestation chain, so it is the only one whose author can make a
## mistake nothing else catches. Two classes of mistake are covered here
## and they are not the same:
##
##   * **Unreadable** — an unknown key, an unknown tier, a schema version
##     this build does not implement, a value of the wrong type. A parser
##     that skipped these would apply a policy the author did not write.
##   * **Incoherent** — accepting a backend whose tier is rejected,
##     bounding the age of a challenge that is not required, pinning
##     production measurements while admitting a backend that measures
##     nothing. Each of these reads as strict and is not, and each is
##     refused *at parse time* so it cannot be discovered one report at a
##     time.
##
## Every case below states the phrase the refusal must contain, so a
## document refused for the *wrong* reason does not pass as a refusal.
## The first case is the positive control: three real policies that must
## parse. Without it every refusal below could be satisfied by a parser
## that refused everything.
##
## ## Mocking
##
## None.

import std/[strutils, unittest]

import repro_attest
import repro_attest_verify

include ./attestation_verifier_harness

proc policyWith(base, old, replacement: string): string =
  ## Mutate exactly one occurrence, and refuse to run if the pattern is
  ## not unique. A mutation that lands somewhere other than where it was
  ## aimed is how a falsification harness comes to believe a check is
  ## strong.
  doAssert base.count(old) == 1,
    "the pattern " & old.escape() & " occurs " & $base.count(old) &
      " times; a mutation must be unambiguous"
  base.replace(old, replacement)

template refuses(label, text, mustSay: string) =
  test label:
    var raised = false
    var message = ""
    try:
      discard parseAttestationPolicy(text, "<case>")
    except PolicyError as err:
      raised = true
      message = err.msg
    check raised
    if raised:
      check mustSay in message
      if mustSay notin message:
        echo "  refusal said: " & message

suite "the measurement policy parser is fail-closed":

  test "the three shipped shapes parse, so every refusal below is a refusal":
    # The positive control. A parser that refused everything would pass
    # all thirty cases beneath this one.
    let dev = parseAttestationPolicy(MockDevPolicy, "<dev>")
    check dev.allowMock
    check dev.tiers == @[atMock]
    check dev.backends == @[abMock]
    check dev.measurements.manifests.len == 0
    check dev.freshness.maxChallengeAgeSeconds == 120
    check dev.freshness.requireChallenge
    check not dev.tcb.present

    let prod = parseAttestationPolicy(productionPolicyText(), "<prod>")
    check not prod.allowMock
    check prod.tiers == @[atCvm]
    check prod.backends == @[abSevSnp, abTdx]
    check prod.measurements.manifests == @[sampleManifestDigest()]
    check prod.measurements.requireCertificates
    check prod.tcb.present
    check prod.tcb.hasSevSnpMinTcb
    check prod.tcb.sevSnpMinTcb.bootloader == 4
    check prod.tcb.sevSnpMinTcb.tee == 0
    check prod.tcb.sevSnpMinTcb.snp == 22
    check prod.tcb.sevSnpMinTcb.microcode == 213
    check prod.tcb.hasTdxMinTcbStatus
    check prod.tcb.tdxMinTcbStatus == "UpToDate"
    check prod.tcb.allowGraceDays == 14

    let tpm = parseAttestationPolicy(tpmPolicyText(), "<tpm>")
    check tpm.tiers == @[atTpm]
    check tpm.backends == @[abTpm2]
    check not tpm.tcb.present

  test "the accessors agree with the document rather than restating it":
    let prod = parseAttestationPolicy(productionPolicyText(), "<prod>")
    check prod.acceptsTier(atCvm)
    check not prod.acceptsTier(atMock)
    check not prod.acceptsTier(atTpm)
    check prod.acceptsBackend(abSevSnp)
    check prod.acceptsBackend(abTdx)
    check not prod.acceptsBackend(abTpm2)
    check not prod.acceptsBackend(abMock)
    check prod.pinsManifests
    let dev = parseAttestationPolicy(MockDevPolicy, "<dev>")
    check dev.acceptsTier(atMock)
    check dev.acceptsBackend(abMock)
    check not dev.pinsManifests

  # -- unreadable ----------------------------------------------------

  refuses "an unknown top-level key is refused",
    MockDevPolicy & "\nunexpected_key = 1\n",
    "unexpected_key"

  refuses "an unknown key inside a known table is refused",
    policyWith(MockDevPolicy, "allow_mock = true",
               "allow_mock = true\nallow_everything = true"),
    "accept.allow_everything"

  refuses "an unknown table is refused",
    MockDevPolicy & "\n[telemetry]\nendpoint = \"https://example\"\n",
    "telemetry.endpoint"

  refuses "a schema this build does not implement is refused",
    policyWith(MockDevPolicy, "reproos.attestation-policy.v1",
               "reproos.attestation-policy.v2"),
    "reproos.attestation-policy.v1"

  refuses "an unknown tier name is refused",
    policyWith(MockDevPolicy, "tiers = [\"mock\"]",
               "tiers = [\"mock\", \"enclave\"]"),
    "enclave"

  refuses "an unknown backend name is refused",
    policyWith(MockDevPolicy, "backends = [\"mock\"]",
               "backends = [\"mock\", \"sgx\"]"),
    "sgx"

  refuses "a repeated tier is refused",
    policyWith(MockDevPolicy, "tiers = [\"mock\"]",
               "tiers = [\"mock\", \"mock\"]"),
    "repeats"

  refuses "a key set twice is refused rather than resolved",
    policyWith(MockDevPolicy, "allow_mock = true",
               "allow_mock = true\nallow_mock = false"),
    "set twice"

  refuses "a missing required key is refused",
    policyWith(MockDevPolicy, "require_certificates = false", ""),
    "measurements.require_certificates"

  refuses "a value of the wrong type is refused",
    policyWith(MockDevPolicy, "tiers = [\"mock\"]", "tiers = \"mock\""),
    "must be an array"

  refuses "a boolean spelled as a string is refused",
    policyWith(MockDevPolicy, "allow_mock = true", "allow_mock = \"true\""),
    "must be true or false"

  # -- grammar -------------------------------------------------------

  refuses "an array of tables is refused",
    MockDevPolicy & "\n[[rebuilders]]\nname = \"a\"\n",
    "array of tables"

  refuses "a float is refused",
    policyWith(MockDevPolicy, "max_challenge_age_seconds = 120",
               "max_challenge_age_seconds = 12.5"),
    "not a quoted string, an integer, or true/false"

  refuses "a single-quoted literal string is refused",
    policyWith(MockDevPolicy, "tiers = [\"mock\"]", "tiers = ['mock']"),
    "not a quoted string"

  refuses "an array of non-strings is refused",
    policyWith(MockDevPolicy, "manifests = []", "manifests = [1, 2]"),
    "not a quoted string"

  refuses "an unterminated string is refused",
    policyWith(MockDevPolicy, "allow_mock = true",
               "allow_mock = true\nnote = \"unterminated"),
    "unterminated string"

  refuses "trailing text after a value is refused",
    policyWith(MockDevPolicy, "allow_mock = true", "allow_mock = true junk"),
    "trailing text"

  refuses "a key with no '=' is refused",
    policyWith(MockDevPolicy, "allow_mock = true",
               "allow_mock = true\nbarekey"),
    "has no '='"

  # -- incoherent, which is the half a lenient parser gets wrong ------

  refuses "an empty tier list is refused",
    policyWith(MockDevPolicy, "tiers = [\"mock\"]", "tiers = []"),
    "accept.tiers is empty"

  refuses "an empty backend list is refused",
    policyWith(MockDevPolicy, "backends = [\"mock\"]", "backends = []"),
    "accept.backends is empty"

  refuses "a backend whose tier is not accepted is refused",
    policyWith(tpmPolicyText(), "backends = [\"tpm2\"]",
               "backends = [\"tpm2\", \"sev-snp\"]"),
    "accept.tiers does not accept that tier"

  refuses "an accepted tier with no backend to serve it is refused",
    policyWith(tpmPolicyText(), "tiers = [\"tpm\"]",
               "tiers = [\"tpm\", \"cvm\"]"),
    "could never be reached"

  refuses "allow_mock without the mock tier is refused",
    policyWith(tpmPolicyText(), "allow_mock = false", "allow_mock = true"),
    "accept.tiers does not name"

  refuses "the mock tier without allow_mock is refused",
    policyWith(MockDevPolicy, "allow_mock = true", "allow_mock = false"),
    "has to be said twice"

  refuses "the evidence-backed posture is refused, not silently ignored",
    MockDevPolicy & "\n[measurements.evidence]\nmin_signatures = 2\n",
    "this build cannot evaluate"

  refuses "a manifest pin that is not a sha256 digest is refused",
    policyWith(tpmPolicyText(), sampleManifestDigest(), "sha256:short"),
    "64 lower-case hex characters"

  refuses "a repeated manifest pin is refused",
    policyWith(tpmPolicyText(), "\"" & sampleManifestDigest() & "\"",
               "\"" & sampleManifestDigest() & "\", \"" &
                 sampleManifestDigest() & "\""),
    "repeats"

  refuses "a confidential-computing backend with no [tcb] table is refused",
    policyWith(productionPolicyText(), """
[tcb]
sev-snp.min_tcb = { bootloader = 4, tee = 0, snp = 22, microcode = 213 }
tdx.min_tcb_status = "UpToDate"
allow_grace_days = 14
""", ""),
    "carries no [tcb] table"

  refuses "a [tcb] table with no confidential-computing backend is refused",
    tpmPolicyText() & "\n[tcb]\nallow_grace_days = 14\n",
    "accept.backends names none"

  refuses "a TCB component outside one byte is refused",
    policyWith(productionPolicyText(), "microcode = 213", "microcode = 300"),
    "is one byte"

  refuses "a TCB status this build cannot order is refused",
    policyWith(productionPolicyText(), "\"UpToDate\"", "\"Revoked\""),
    "refuses one it cannot order"

  refuses "a grace window of a year and a day is refused",
    policyWith(productionPolicyText(), "allow_grace_days = 14",
               "allow_grace_days = 400"),
    "allow_grace_days"

  refuses "a negative challenge age is refused",
    policyWith(MockDevPolicy, "max_challenge_age_seconds = 120",
               "max_challenge_age_seconds = -1"),
    "zero waives the age bound"

  refuses "an age bound on a challenge that is not required is refused",
    policyWith(MockDevPolicy, "require_challenge = true",
               "require_challenge = false"),
    "there would be nothing to measure the age of"

  refuses "a sev-snp TCB floor for a backend that is not accepted is refused",
    policyWith(productionPolicyText(), "backends = [\"sev-snp\", \"tdx\"]",
               "backends = [\"tdx\"]"),
    "does not name it"

  test "acceptsTier refuses the mock tier on its own, not only via the parser":
    # The parser refuses a document whose `allow_mock` and tier list
    # disagree, so the guard inside `acceptsTier` can never be reached
    # through `parseAttestationPolicy`. It is still the predicate a
    # verdict is derived from, and an embedding caller assembles the
    # record directly. Checked here against a record built in code, so
    # the guard has a way to fail.
    var byHand = AttestationPolicy(tiers: @[atMock], backends: @[abMock],
                                   allowMock: false)
    check not byHand.acceptsTier(atMock)
    check not byHand.acceptsBackend(abMock)
    byHand.allowMock = true
    check byHand.acceptsTier(atMock)
    check byHand.acceptsBackend(abMock)
    # And the tier list still governs: allow_mock does not admit a tier
    # the policy never named.
    check not byHand.acceptsTier(atCvm)
    check not byHand.acceptsBackend(abSevSnp)

  test "waiving the age bound is spelled, and then it parses":
    # The other polarity of the two freshness refusals above: a policy
    # that genuinely wants no age bound writes zero AND stops requiring
    # a challenge, and that document is accepted. Without this case the
    # two refusals could be a parser that rejects every freshness table.
    let text = policyWith(
      policyWith(MockDevPolicy, "max_challenge_age_seconds = 120",
                 "max_challenge_age_seconds = 0"),
      "require_challenge = true", "require_challenge = false")
    let p = parseAttestationPolicy(text, "<waived>")
    check p.freshness.maxChallengeAgeSeconds == 0
    check not p.freshness.requireChallenge

  test "a policy larger than the ceiling is refused before it is parsed":
    var big = MockDevPolicy
    while big.len <= MaxPolicyBytes: big.add "# padding padding padding\n"
    var raised = false
    try:
      discard parseAttestationPolicy(big, "<big>")
    except PolicyError as err:
      raised = true
      check "at most" in err.msg
    check raised
