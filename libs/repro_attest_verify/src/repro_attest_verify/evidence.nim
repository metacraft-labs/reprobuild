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
## This build carries exactly one: the **mock** reader. For every other
## backend the reading is a **violation**, not a skip —
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

  EvidenceReading* = object
    ## A reader's answer: what it found, and whether it was willing to
    ## vouch for the evidence at all.
    finding*: CheckFinding
    inputs*: AuthoritativeInputs

const
  MockReaderName* = "reproos.mock-evidence.v1 reader"

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
  of abSevSnp, abTdx, abTpm2:
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
