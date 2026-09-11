## The agent answers a challenge, over a socket, with a document a
## verifier can read.
##
## ## What this gate proves
##
## A challenge goes in over TCP and a ``reproos.attestation-report.v1``
## envelope comes back, and every claim made about that envelope is
## *recomputed here* rather than compared against something the agent
## also produced:
##
##   * the 64 bytes are rebuilt from the challenge and the bindings by
##     the binding discipline, and compared to the ``reportData`` the
##     document carries;
##   * the evidence is decoded, parsed as a mock document, and its own
##     copy of the 64 bytes is compared to the same value — so the
##     envelope and what the backend actually signed are checked against
##     each other, not merely each against itself;
##   * the mock signature is recomputed from the published key.
##
## The last of those is worth being precise about. Recomputing a MAC
## whose key is a literal in the source establishes that the document is
## well-formed and *nothing whatever* about whether it should be
## believed. That is the mock backend's entire point, and the gate
## asserts the worthlessness explicitly: a forged document with different
## report data verifies just as well once its MAC is recomputed, which is
## checked below.
##
## ## What it does not prove
##
## Nothing here verifies hardware, because there is none. It does not
## show that a real root of trust would place the 64 bytes where this
## backend places them — that is each backend's own gate — and it reaches
## no verdict about the report, because reaching verdicts is the
## verifier's work and lives elsewhere.
##
## ## Mocking
##
## None beyond the mock backend itself, which is the subject under test.

import std/[json, net, strutils, unittest]

import repro_attest
import repro_attest_agent

include attestation_agent_harness

suite "attestation agent — mock roundtrip":

  test "challenge to a schema-valid envelope with recomputable report data":
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let response = get(h.port, "/attestation?challenge=" & ChallengeA)
    check response.status == 200

    # Parsed by the strict parser, from the bytes on the wire. If the
    # agent had emitted anything the schema refuses, this raises.
    let report = parseAttestationReport(response.body, "over the wire")

    check report.tier == atMock
    check report.backend == abMock
    check report.challenge == ChallengeA
    check report.bindings.purpose == bpAttest
    check report.bindings.ephemeralPub.len == 0
    check report.claims.unverifiedGeneration == SampleGeneration
    check report.claims.unverifiedConfigFingerprint == SampleFingerprint
    check report.claims.unverifiedVerityRootHash == SampleVerityRootHash

    # The 64 bytes, rebuilt here from the discipline rather than taken
    # from the document that is under test.
    let recomputed = reportDataHexFor(
      ReportBindings(purpose: bpAttest, ephemeralPub: ""), ChallengeA)
    check report.reportData == recomputed
    check report.bindsChallenge(ChallengeA)

    # And the same value inside the evidence the backend produced, so
    # the envelope and the signed bytes are checked against each other.
    let evidence = parseMockEvidence(report.authoritativeEvidence)
    check evidence.reportDataHex == recomputed
    check evidence.signatureHex == mockEvidenceSignatureFor(recomputed)

    # The document names ITSELF a mock, as a literal. `parseMockEvidence`
    # compares the first line against the constant that wrote it, so it
    # accepts whatever that constant says — including the name of a real
    # backend's format. The mock's whole safety argument is that nothing
    # it produces can claim to be anything else, and that argument is
    # only worth something if a claim is what is checked.
    let evidenceText = report.authoritativeEvidence
    check evidenceText.startsWith("reproos.mock-evidence.v1\n")
    check MockEvidenceSchema == "reproos.mock-evidence.v1"
    check "mock" in MockEvidenceSchema
    # The launch measurement is a published non-measurement, and pinning
    # it is what stops the mock quietly publishing a plausible one. It is
    # the SHA-256 of the ASCII string `test`, regenerable outside this
    # code entirely.
    check evidence.launchMeasurement ==
      "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    check MockLaunchMeasurement ==
      "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

    # The chain arrives, is decodable, and names its own root as one
    # nothing should anchor to.
    #
    # The phrase is pinned as a LITERAL, not as `MockRootName`. Comparing
    # the chain against the same constant that produced it passes however
    # that constant is spelled — including as the name of a real vendor
    # root — which makes the check a tautology rather than a claim about
    # what the bytes say.
    check report.hasBundledCertificates
    let chain = report.certificatesForCrossCheck
    check chain.len == 3
    check "NOT-A-TRUST-ANCHOR" in chain[^1]
    check "NOT-A-TRUST-ANCHOR" in MockRootName
    # The certificate schema, pinned as a LITERAL for the same reason the
    # root name is. `cert.startsWith(MockCertificateSchema)` alone is a
    # tautology: it holds for every value that constant could take,
    # including `-----BEGIN CERTIFICATE-----`, which is precisely the
    # spelling the module says this chain must never have — a chain that
    # parsed as a certificate is a chain something might try to validate.
    for cert in chain:
      check cert.startsWith("reproos.mock-certificate.v1 ")
    check MockCertificateSchema == "reproos.mock-certificate.v1"
    check not MockCertificateSchema.startsWith("-----BEGIN")

  test "the mock signature is verifiable and worth nothing, and both matter":
    # Recomputing the MAC proves well-formedness. It must not be mistaken
    # for evidence of anything, so the gate constructs a document that is
    # a lie about which challenge was answered, gives it a correctly
    # recomputed MAC under the published key, and shows it passing the
    # same check the genuine one passed.
    let honest = reportDataHexFor(
      ReportBindings(purpose: bpAttest, ephemeralPub: ""), ChallengeA)
    let forged = reportDataHexFor(
      ReportBindings(purpose: bpAttest, ephemeralPub: ""), ChallengeB)
    check honest != forged

    let forgedDoc = renderMockEvidence(forged)
    let parsed = parseMockEvidence(forgedDoc)
    check parsed.reportDataHex == forged
    check parsed.signatureHex == mockEvidenceSignatureFor(forged)

    # The key is a literal in the library, which is why the forgery cost
    # one line. Pinned as a literal string rather than as the constant:
    # asserting that the document contains `MockSigningKey` is true for
    # every possible value of `MockSigningKey`, including a real one, and
    # a check that cannot distinguish those is not checking anything.
    check "reproos-mock-attestation-key-not-secret" in forgedDoc
    check MockSigningKey == "reproos-mock-attestation-key-not-secret"

  test "two challenges bind differently, so the binding is live":
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let a = parseAttestationReport(
      get(h.port, "/attestation?challenge=" & ChallengeA).body, "a")
    let b = parseAttestationReport(
      get(h.port, "/attestation?challenge=" & ChallengeB).body, "b")
    check a.reportData != b.reportData
    check a.evidence != b.evidence
    # Each answers its own challenge and not the other's — which is the
    # property that makes a report an answer rather than a broadcast.
    check a.bindsChallenge(ChallengeA)
    check not a.bindsChallenge(ChallengeB)
    check b.bindsChallenge(ChallengeB)
    check not b.bindsChallenge(ChallengeA)

  test "health reports the tier, the backend and the driver separately":
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let response = get(h.port, "/health")
    check response.status == 200
    let doc = parseJson(response.body)
    # Literals throughout. Every one of these fields is read by something
    # outside this repository, so the value is the contract; comparing
    # each against the constant that produced it would pass whatever the
    # constant became.
    check doc["schema"].getStr == "reproos.attestation-agent-health.v1"
    check AgentHealthSchema == "reproos.attestation-agent-health.v1"
    check doc["tier"].getStr == "mock"
    check doc["backend"].getStr == "mock"
    check doc["driver"].getStr == "mock"
    check doc["backendReady"].getBool
    check doc["measurementManifest"].getStr == "absent"

    # The key-agreement field names the mechanism, and it must not name
    # one it does not implement: a verifier reading "x25519" here would
    # encapsulate a secret to a key with no private half, and the secret
    # would be destroyed rather than delivered.
    check doc["keyAgreement"].getStr == "mock-not-a-kem"
    for realKem in ["x25519", "X25519", "p256", "P-256", "kyber"]:
      check realKem notin doc["keyAgreement"].getStr

  test "health reports the driver and the backend as separate facts":
    # `driver` and `backend` coincide for the mock, so the mock alone
    # cannot show they are two fields. A driver whose name differs from
    # the evidence it produces can — and that asymmetry is not a curiosity,
    # it is the shape a software-root emulator takes: it produces
    # SEV-SNP-shaped evidence and is not the SEV-SNP driver.
    var agent = newAttestationAgent(driver = newLyingDriver(),
      identity = sampleIdentity())
    var h = startHarness(agent)
    defer: stopHarness(h)

    let doc = parseJson(get(h.port, "/health").body)
    check doc["driver"].getStr == "lying-mock"
    check doc["backend"].getStr == "mock"
    check doc["driver"].getStr != doc["backend"].getStr

  test "a key agreement binds the public key it just minted":
    var h = startHarness(sampleAgent())
    defer: stopHarness(h)

    let response = post(h.port, "/key-agreement",
      $(%*{"challenge": ChallengeA}))
    check response.status == 200
    let report = parseAttestationReport(response.body, "key agreement")
    check report.bindings.purpose == bpKeyAgreement
    check report.bindings.ephemeralPub.len > 0
    check isLowerHex(report.bindings.ephemeralPub)

    # The 64 bytes cover the key, so a quote cannot be moved onto a
    # different one. Recomputed here from the discipline.
    check report.reportData == reportDataHexFor(report.bindings, ChallengeA)
    # And the key is genuinely in them: the same challenge with the key
    # removed produces different bytes.
    check report.reportData != reportDataHexFor(
      ReportBindings(purpose: bpAttest, ephemeralPub: ""), ChallengeA)

    let evidence = parseMockEvidence(report.authoritativeEvidence)
    check evidence.reportDataHex == report.reportData

  test "the driver cannot write the field that says what was bound":
    # The agent computes `reportData` from the request, and hands the
    # driver the resulting bytes. A driver that embeds different bytes in
    # its evidence therefore produces a report whose envelope is still
    # correct and whose evidence disagrees with it — which is the failure
    # a verifier exists to catch, and is not one this agent can be
    # induced to hide.
    let lyingDriver = newLyingDriver()
    var agent = newAttestationAgent(driver = lyingDriver,
      identity = sampleIdentity())
    var h = startHarness(agent)
    defer: stopHarness(h)

    let response = get(h.port, "/attestation?challenge=" & ChallengeA)
    check response.status == 200
    let report = parseAttestationReport(response.body, "from a lying driver")
    let honest = reportDataHexFor(
      ReportBindings(purpose: bpAttest, ephemeralPub: ""), ChallengeA)
    check report.reportData == honest
    let evidence = parseMockEvidence(report.authoritativeEvidence)
    check evidence.reportDataHex != honest

  test "the measurement manifest is served byte for byte as published":
    let manifest = sampleManifestText()
    var agent = newAttestationAgent(
      driver = newMockDriver(),
      identity = AgentIdentity(generation: SampleGeneration),
      manifestText = manifest)
    var h = startHarness(agent)
    defer: stopHarness(h)

    let response = get(h.port, "/measurement-manifest")
    check response.status == 200
    check response.body == manifest

    # And the claims came from the manifest rather than from a second
    # opinion on the command line.
    let report = parseAttestationReport(
      get(h.port, "/attestation?challenge=" & ChallengeA).body, "with manifest")
    let parsedManifest = parseAttestedImageManifest(manifest, "sample")
    check report.claims.unverifiedConfigFingerprint ==
      parsedManifest.configFingerprint
    check report.claims.unverifiedVerityRootHash ==
      parsedManifest.imageOutputs.verityRootHash

  test "an agent configured to contradict its own manifest does not start":
    let manifest = sampleManifestText()
    let parsedManifest = parseAttestedImageManifest(manifest, "sample")
    expect AgentError:
      discard newAttestationAgent(
        driver = newMockDriver(),
        identity = AgentIdentity(generation: SampleGeneration,
          verityRootHash:
            "2222222222222222222222222222222222222222222222222222222222222222"),
        manifestText = manifest)
    # The positive polarity, so the refusal above is discriminating
    # rather than universal: repeating what the manifest says is fine.
    discard newAttestationAgent(
      driver = newMockDriver(),
      identity = AgentIdentity(generation: SampleGeneration,
        verityRootHash: parsedManifest.imageOutputs.verityRootHash),
      manifestText = manifest)

  test "the seam refuses a driver that misbehaves, naming it":
    let d = newMockDriver()
    # Wrong number of bytes in: the discipline binds exactly 64.
    expect DriverError:
      discard acquireQuote(d, "short")
    expect DriverError:
      discard acquireQuote(newEmptyEvidenceDriver(),
        repeat('\x00', ReportDataSize))
    expect DriverError:
      discard acquireQuote(newEmptyChainDriver(),
        repeat('\x00', ReportDataSize))
    # Evidence the envelope could not carry is refused HERE, so the
    # message names the driver rather than surfacing later as a schema
    # complaint about a document nobody meant to build.
    expect DriverError:
      discard acquireQuote(newHugeEvidenceDriver(),
        repeat('\x00', ReportDataSize))
    # A driver with no name, and a key source with no algorithm: both are
    # refused when the thing is CONSTRUCTED, because a driver's identity
    # is what an operator reads when a machine will not attest, and a
    # party encrypting to an ephemeral key has to know what it is.
    expect DriverError:
      initAttestationDriver(MockDriver(), abMock, "")
    expect DriverError:
      initEphemeralKeySource(MockKeySource(), "")
    # The positive polarity: a well-behaved driver passes the same seam.
    let ok = acquireQuote(d, repeat('\x00', ReportDataSize))
    check ok.evidence.len > 0
    check ok.certificates.isSome

  test "the tier follows the backend, and no driver can raise its own":
    # The mock alone cannot show this: `tierOf(abMock)` is `atMock`, so a
    # seam that returned a constant tier and one that derived it agree on
    # every mock-backed check. A driver producing evidence of another
    # backend's shape is what tells them apart — and it is not a
    # curiosity, it is the shape a software-root emulator takes.
    let emulator = newCvmShapedDriver()
    check emulator.driverName == "software-root-emulator"
    check emulator.backend == abSevSnp
    check emulator.tier == atCvm
    check emulator.tier == tierOf(emulator.backend)
    check emulator.tier != newMockDriver().tier

    # The mock's own pair, so the derivation is shown in both directions.
    check newMockDriver().backend == abMock
    check newMockDriver().tier == atMock

    # And an agent over that driver reports the driver's tier rather than
    # a tier of its own choosing.
    let agent = newAttestationAgent(driver = emulator,
      identity = sampleIdentity())
    check agent.tier == atCvm
    check agent.backend == abSevSnp

  test "a manifest that is not in its canonical spelling is refused":
    # The agent serves the published BYTES of the manifest, so it must
    # refuse to hold bytes it would not itself have written — otherwise
    # `/measurement-manifest` serves a re-spelling and a verifier holding
    # a digest of the build's document sees a mismatch it cannot explain.
    let manifest = sampleManifestText()
    let respelled = manifest.replace("\n", "\n ")
    check respelled != manifest
    expect AgentError:
      discard newAttestationAgent(
        driver = newMockDriver(),
        identity = AgentIdentity(generation: SampleGeneration),
        manifestText = respelled)
    # The positive polarity, so the refusal is about the spelling and not
    # about manifests.
    discard newAttestationAgent(
      driver = newMockDriver(),
      identity = AgentIdentity(generation: SampleGeneration),
      manifestText = manifest)
