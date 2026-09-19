## Shared driving code for the secret-provisioning gates.
##
## Named without a ``t_`` / ``test_`` prefix so the test-edge generator
## does not discover it as a test in its own right, and ``include``d
## rather than imported — the convention the two attestation harnesses
## beside it follow. It includes NEITHER of them: the binding gate needs
## the agent's socket and the policy gate needs the verifier's fixtures,
## and a harness that dragged in both would make each gate carry the
## other's. Each gate includes the one it needs, and then this.
##
## ## What is real here
##
## Everything the protocol is about:
##
##   * the daemon, on a real socket, answering real HTTP;
##   * ``newX25519KeySource()`` — the shipped mechanism, drawing its seed
##     from the operating system, not a published placeholder;
##   * a **real tmpfs**, discovered on the machine running the gate, and
##     a **real non-volatile directory** beside it. Both are checked to
##     be what the gate needs them to be *before* they are used, so a
##     machine where ``/tmp`` happened to be a tmpfs makes the negative
##     case fail loudly instead of passing vacuously;
##   * the real verifier, the real policy parser and the real release
##     helper.
##
## ## Mocking
##
## One stand-in, and it is the *root of trust*, not a mock of anything
## this file owns: ``newMockDriver()`` is a backend for a machine
## that has none. Every gate that uses it opts in explicitly
## (``allowNoRootOfTrust``), and the gate for the policy half uses a
## caller-supplied reading from a tier that does have one — which is the
## seam a downstream broker with its own reader uses.
##
## The audit sinks below are not mocks either: one appends to a real
## file, one collects in memory so a gate can read what was recorded,
## and one raises on purpose because "a sink that raises withholds the
## secret" is a rule that needs an input.

import std/[json, options, os, posix, strutils]

import repro_attest
import repro_attest/hpke
import repro_attest/x25519_kem
import repro_attest_agent/secrets
import repro_attest_verify

const
  ProvisionDevPolicy = """
schema = "reproos.attestation-policy.v1"

# The development policy the binding gate runs under: it admits the tier
# that has NO root of trust, and it says so twice, which is the only way
# the parser lets it be said. Releasing against it still needs the
# release helper's own opt-in, which is the point of having both.
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

  TmpfsCandidates = ["/dev/shm", "/run/user"]
  PersistentCandidates = ["/tmp", "/var/tmp"]

  SampleSecret = "reproos-provision-released-secret-32-byte"

# ---------------------------------------------------------------------
# Directories, chosen by measurement rather than by convention
# ---------------------------------------------------------------------

proc firstDirectoryWhere(candidates: openArray[string];
                         wantVolatile: bool): string =
  ## The first candidate that is a directory AND is (or is not) on a
  ## filesystem with no backing store. Returns "" when none is.
  ##
  ## The property is measured with the same predicate the daemon uses,
  ## so a gate cannot end up asserting a refusal against a directory that
  ## would not have produced one.
  for base in candidates:
    var dir = base
    if base == "/run/user":
      dir = base / $getuid()
    if not dirExists(dir): continue
    let volatile =
      try: isVolatileFilesystem(filesystemMagic(dir))
      except CatchableError: continue
    if volatile == wantVolatile: return dir
  ""

var scratchCounter = 0

proc makeScratch(parent, tag: string): string =
  inc scratchCounter
  result = parent / ("reproos-provision-" & tag & "-" & $getCurrentProcessId() &
                     "-" & $scratchCounter)
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc volatileScratch(tag: string): string =
  let parent = firstDirectoryWhere(TmpfsCandidates, wantVolatile = true)
  doAssert parent.len > 0,
    "this gate needs a filesystem with no backing store and found none " &
    "among " & TmpfsCandidates.join(", ") & "; it will not pretend to " &
    "have proved that a secret stayed in memory"
  makeScratch(parent, tag)

proc persistentScratch(tag: string): string =
  let parent = firstDirectoryWhere(PersistentCandidates, wantVolatile = false)
  doAssert parent.len > 0,
    "this gate needs a directory that is NOT on a filesystem with no " &
    "backing store, so the refusal it asserts has a real input, and " &
    "found none among " & PersistentCandidates.join(", ")
  makeScratch(parent, tag)

# ---------------------------------------------------------------------
# Audit sinks
# ---------------------------------------------------------------------

type
  CollectingSink = ref object of AuditSink
    ## Keeps every record a gate's decisions produced, in order.
    records: seq[AuditRecord]

  RefusingSink = ref object of AuditSink
    ## Raises. The input the rule "a sink that raises withholds the
    ## secret" needs in order to be a rule.
    calls: int

method recordReleaseDecision(s: CollectingSink; rec: AuditRecord) =
  s.records.add rec

method recordReleaseDecision(s: RefusingSink; rec: AuditRecord) =
  inc s.calls
  raise newException(ReleaseError,
    "this sink cannot write, and a release nobody could record is a " &
    "release that does not happen")

proc newCollectingSink(): CollectingSink = CollectingSink(records: @[])
proc newRefusingSink(): RefusingSink = RefusingSink()

# ---------------------------------------------------------------------
# Release requests
# ---------------------------------------------------------------------

proc provisionRelease(reportText, policyText, challengeHex: string;
                      secret = SampleSecret;
                      secretName = "";
                      allowNoRootOfTrust = false;
                      allowUnauthenticatedManifest = false;
                      manifestText = none(string);
                      nowMs = 0'i64): ReleaseRequest =
  ReleaseRequest(
    verification: VerificationRequest(
      reportText: reportText,
      reportSource: "<harness report>",
      policy: parseAttestationPolicy(policyText, "<harness policy>"),
      policySource: "<harness policy>",
      manifestText: manifestText,
      manifestSource: "<harness manifest>",
      expectedChallengeHex: challengeHex,
      challengeIssuedAtMs: some(0'i64),
      nowMs: nowMs),
    policyText: policyText,
    secretName: secretName,
    secret: secret,
    allowNoRootOfTrust: allowNoRootOfTrust,
    allowUnauthenticatedManifest: allowUnauthenticatedManifest)

proc fixedSeed(tag: char): string =
  ## A sender seed of the full width, constant per tag. The sender's
  ## ephemeral key is not what any of these gates is about — the
  ## instance's is — and a constant one makes a failure reproducible.
  ## `drawSenderSeed()` is what a deployment passes, and the roundtrip
  ## harness passes it.
  repeat(tag, SeedBytes)
