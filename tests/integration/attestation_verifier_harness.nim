## Shared fixtures for the `repro attest verify` gates.
##
## Named without a ``t_`` / ``test_`` prefix so the test-edge generator
## does not discover it as a test in its own right, and ``include``d
## rather than imported, so each gate compiles one binary with no extra
## edge — the convention ``attestation_agent_harness.nim`` follows.
##
## ## What is a fixture here, and what is not
##
## The policy documents below are fixtures: real bytes in the real
## grammar, fed to the real parser. The measurement manifest is built as
## a record and rendered by the library, so its bytes are the canonical
## spelling of its own schema rather than a literal that could drift away
## from it — and its ``pcr11`` is *replayed* from its event-log template
## by the library rather than typed in, so the two halves cannot
## disagree by transcription.
##
## The reports the gates verify come from the real agent over a real
## socket (the end-to-end gate) or from the real report renderer (the
## rest). Nothing here writes report JSON by hand.
##
## ## Mocking
##
## None. The mock *backend* is an implementation of the driver seam for a
## root of trust that is absent, which is the thing under test rather
## than a substitute for it.

import std/[options, os, strutils]

import repro_attest
import repro_attest_verify

const
  SampleGeneration = "gen-2026-09-11-0001"
  SampleFingerprint = "reproos-attested-uefi:sample"
  SampleVerityRootHash =
    "2222222222222222222222222222222222222222222222222222222222222222"
  OtherVerityRootHash =
    "3333333333333333333333333333333333333333333333333333333333333333"

  # 32 bytes, comfortably over the 128-bit floor.
  HarnessChallenge = "a1b2c3d4e5f60718293a4b5c6d7e8f90" &
                     "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
  OtherChallenge = "0011223344556677" & "8899aabbccddeeff" &
                   "ffeeddccbbaa9988" & "7766554433221100"

  SampleTimestamp = "2026-09-11T09:00:00Z"

# ---------------------------------------------------------------------
# A measurement manifest with a real TPM expectation
# ---------------------------------------------------------------------

proc sampleEventLogTemplate(): string =
  ## Six sections in the order a stub measures them, each with a content
  ## digest of its own. The digests are of fixture strings; what matters
  ## is that the template is well formed and replays, which the library
  ## decides, not this file.
  result = EventLogTemplateId & ";bank=sha256"
  for section in [".linux", ".osrel", ".cmdline", ".initrd", ".uname",
                  ".sbat"]:
    result.add ";" & section & "=" & sha256Hex("fixture-content:" & section)

proc sampleManifest(rootHash = SampleVerityRootHash): AttestedImageManifest =
  let tmpl = sampleEventLogTemplate()
  AttestedImageManifest(
    configFingerprint: SampleFingerprint,
    imageOutputs: ImageOutputs(
      uki: DigestPrefix & sha256Hex("fixture-uki"),
      verityImage: DigestPrefix & sha256Hex("fixture-verity-image"),
      verityRootHash: rootHash),
    tpm: @[TpmExpectation(pcr11: replayEventLogTemplate(tmpl),
                          eventLogTemplate: tmpl)])

proc sampleManifestText(rootHash = SampleVerityRootHash): string =
  renderAttestedImageManifest(sampleManifest(rootHash))

proc sampleManifestDigest(rootHash = SampleVerityRootHash): string =
  DigestPrefix & sha256Hex(sampleManifestText(rootHash))

proc sampleExpectedPcr11(): string = replayEventLogTemplate(
  sampleEventLogTemplate())

# ---------------------------------------------------------------------
# Policies
# ---------------------------------------------------------------------

const
  MockDevPolicy* = """
schema = "reproos.attestation-policy.v1"

# A development policy: it admits the tier that has no root of trust, and
# says so twice, which is the only way this parser lets it be said.
[accept]
tiers = ["mock"]
backends = ["mock"]
allow_mock = true

[measurements]
manifests = []
require_certificates = false

[freshness]
max_challenge_age_seconds = 120
require_challenge = true
"""

  ProductionPolicyTemplate* = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["cvm"]
backends = ["sev-snp", "tdx"]
allow_mock = false

[measurements]
manifests = ["@DIGEST@"]
require_certificates = true

[tcb]
sev-snp.min_tcb = { bootloader = 4, tee = 0, snp = 22, microcode = 213 }
tdx.min_tcb_status = "UpToDate"
allow_grace_days = 14

[freshness]
max_challenge_age_seconds = 120
require_challenge = true
"""

  TpmPolicyTemplate* = """
schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["tpm"]
backends = ["tpm2"]
allow_mock = false

[measurements]
manifests = ["@DIGEST@"]
require_certificates = false

[freshness]
max_challenge_age_seconds = 120
require_challenge = true
"""

proc productionPolicyText(digest = sampleManifestDigest()): string =
  ProductionPolicyTemplate.replace("@DIGEST@", digest)

proc tpmPolicyText(digest = sampleManifestDigest()): string =
  TpmPolicyTemplate.replace("@DIGEST@", digest)

proc mockPolicy(): AttestationPolicy =
  parseAttestationPolicy(MockDevPolicy, "<mock-dev-policy>")

proc tpmPolicy(digest = sampleManifestDigest()): AttestationPolicy =
  parseAttestationPolicy(tpmPolicyText(digest), "<tpm-policy>")

# ---------------------------------------------------------------------
# Reports, built by the real renderer
# ---------------------------------------------------------------------

proc sampleClaims(rootHash = SampleVerityRootHash): UnverifiedClaims =
  UnverifiedClaims(
    unverifiedGeneration: SampleGeneration,
    unverifiedConfigFingerprint: SampleFingerprint,
    unverifiedVerityRootHash: rootHash)

proc mockReportText(challengeHex = HarnessChallenge;
                    claims = sampleClaims()): string =
  ## What the mock backend's driver produces for one challenge, put
  ## through the report renderer — the same two calls the agent makes.
  let bindings = ReportBindings(purpose: bpAttest, ephemeralPub: "")
  let reportDataHex = reportDataHexFor(bindings, challengeHex)
  let quote = acquireQuote(newMockDriver(),
    hexToBytes("reportData", reportDataHex))
  renderAttestationReport(attestationReport(abMock, SampleTimestamp,
    challengeHex, bindings, quote.evidence, claims, quote.certificates))

proc tpm2ReportText(challengeHex = HarnessChallenge;
                    claims = sampleClaims()): string =
  ## A TPM-tier envelope. This build carries no reader for tpm2 evidence,
  ## so the evidence bytes are opaque here on purpose: the gates that use
  ## this report either expect the native-evidence check to REFUSE it, or
  ## supply their own reading through the embedding seam.
  let bindings = ReportBindings(purpose: bpAttest, ephemeralPub: "")
  renderAttestationReport(attestationReport(abTpm2, SampleTimestamp,
    challengeHex, bindings, "opaque-tpm2-evidence-bytes", claims))

proc sevSnpReportText(challengeHex = HarnessChallenge): string =
  let bindings = ReportBindings(purpose: bpAttest, ephemeralPub: "")
  renderAttestationReport(attestationReport(abSevSnp, SampleTimestamp,
    challengeHex, bindings, "opaque-snp-evidence-bytes", sampleClaims()))

# ---------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------

proc verificationRequest(reportText: string; policy: AttestationPolicy;
                         manifestText = none(string);
                         challengeHex = HarnessChallenge;
                         issuedAtMs = some(0'i64);
                         nowMs = 0'i64): VerificationRequest =
  VerificationRequest(
    reportText: reportText,
    reportSource: "<harness report>",
    policy: policy,
    policySource: "<harness policy>",
    manifestText: manifestText,
    manifestSource: "<harness manifest>",
    expectedChallengeHex: challengeHex,
    challengeIssuedAtMs: issuedAtMs,
    nowMs: nowMs)

# ---------------------------------------------------------------------
# The embedding seam
#
# A tier with a root of trust, verified through the reading a downstream
# caller brought. This build carries no reader for tpm2 evidence, so this
# is the only way the `measurement-match` and identity branches are
# reachable at all — which is what that seam is for. Shared by every gate
# that drives them, so two gates cannot come to disagree about what a
# caller-supplied reading looks like.
# ---------------------------------------------------------------------

proc tpmReading(measurement: string; reportDataHex: string;
                reader = "downstream tpm2 reader"): EvidenceReading =
  ## What a caller that brought its own TPM reader would hand in.
  var inputs: AuthoritativeInputs
  inputs.readerName = reader
  inputs.launchMeasurement = some(measurement)
  inputs.reportDataInEvidence = some(reportDataHex)
  EvidenceReading(
    finding: satisfied("a quote over PCR 11 verified under an attestation " &
      "key certified by the test's own root"),
    inputs: inputs)

proc tpmVerdict(measurement: string; manifestText: string;
                policy: AttestationPolicy): Verdict =
  let text = tpm2ReportText()
  let report = parseAttestationReport(text, "<tpm report>")
  var req = verificationRequest(text, policy, some(manifestText))
  verifyWithReading(req, report,
    tpmReading(measurement, report.reportData))

# ---------------------------------------------------------------------
# The module-closure walk
#
# Used by the enumeration gate to hold the package boundary this library
# exists for. It follows `import` / `from` / `include` statements and
# RESOLVES each to a file, so a module that has been renamed drops out of
# the walk loudly rather than silently.
# ---------------------------------------------------------------------

proc libModulePath(libRoot, module: string): string =
  ## Resolve one in-repo module reference to a file, or "" for anything
  ## outside the repository's ``libs/`` tree (the standard library, and
  ## the vendored packages the dev shell supplies).
  let parts = module.split('/')
  if parts.len == 0 or parts[0].len == 0: return ""
  let direct = libRoot / parts[0] / "src" / (module & ".nim")
  if fileExists(direct): return direct
  let pkg = libRoot / parts[0] / "src" / parts[0] / (parts[^1] & ".nim")
  if parts.len > 1 and fileExists(pkg): return pkg
  ""

proc importedModules(path: string): seq[string] =
  ## Every module name a file imports or includes. Comments are stripped
  ## first, so a module named only in prose is not counted as an edge.
  var pending = ""
  for rawLine in readFile(path).splitLines:
    var line = rawLine
    let hash = line.find('#')
    if hash >= 0: line = line[0 ..< hash]
    line = line.strip()
    if line.len == 0: continue
    var body = ""
    if pending.len > 0:
      body = pending & " " & line
      pending = ""
    elif line.startsWith("import ") or line.startsWith("include "):
      body = line[line.find(' ') + 1 .. ^1]
    elif line.startsWith("from "):
      let importAt = line.find(" import ")
      body = (if importAt > 0: line[5 ..< importAt] else: line[5 .. ^1])
    else:
      continue
    if body.strip().endsWith(","):
      pending = body
      continue
    for item in body.split(','):
      var name = item.strip()
      if name.len == 0: continue
      if name.startsWith("./"): name = name[2 .. ^1]
      if '[' in name:
        # `import std/[a, b]` — the bracket form, already comma-split.
        let open = name.find('[')
        let prefix = name[0 ..< open]
        name = prefix & name[open + 1 .. ^1].replace("]", "")
      name = name.replace("]", "").strip()
      if name.len > 0: result.add name

proc moduleClosure*(libRoot, entry: string): seq[string] =
  ## Every in-repo library module reachable from ``entry``, as repository
  ## relative paths. Modules outside ``libs/`` are not followed.
  var seen: seq[string] = @[]
  var queue = @[entry]
  while queue.len > 0:
    let path = queue.pop()
    if path in seen: continue
    seen.add path
    for module in importedModules(path):
      var resolved = libModulePath(libRoot, module)
      if resolved.len == 0:
        # A relative submodule of the file being read.
        let sibling = path.parentDir / (module & ".nim")
        if fileExists(sibling): resolved = sibling
      if resolved.len > 0 and resolved notin seen:
        queue.add resolved
  seen
