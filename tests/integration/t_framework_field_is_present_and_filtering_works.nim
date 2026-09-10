## TC-7 — the ``framework`` field is present, and filtering by it works.
##
## A repository may be tested by several frameworks — a Nim suite under one
## runner, a Python suite under another, an integration suite under a build
## system. Their certificates coexist in the same git note, and NONE of them
## can evaluate the others: the fields are shared, their framework-specific
## meaning is not.
##
## So ``framework`` is REQUIRED (a record without it is decidably invalid),
## and a consumer MUST filter by it BEFORE applying any framework-specific
## rule. Critically, a certificate from a framework this consumer does not
## implement is IGNORED, not REJECTED: it is not evidence FOR this consumer,
## and it is not evidence AGAINST anything either. Reporting it as a rejection
## would send an operator to fix a certificate that was never theirs.
##
## Sub-cases:
##   1. the record carries ``framework`` and a record without it is malformed;
##   2. an unimplemented framework's certificate is IGNORED and contributes
##      nothing — the gap is still reported, naming the framework required;
##   3. an IMPLEMENTED but different framework's certificate contributes
##      nothing to THIS requirement and is not a fault to report either;
##   4. the same certificate under reprobuild's own framework id DOES cover;
##   5. ``certificateMatches`` — the single relevance predicate the push gate,
##      the CI plan and the gateway all share — refuses a foreign framework.

import std/[strutils, unittest]

import repro_cli_support

const fixtureCommit = "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4"

proc cert(framework: string; targets: seq[string]): TestCertificate =
  TestCertificate(
    schema: testCertificateSchemaV1,
    framework: framework,
    project: "example",
    platform: "linux/amd64",
    targets: targets,
    result: tcrPassed,
    issuedAt: "2026-06-23T10:14:33Z",
    issuer: "repro-test@build-host-7",
    vcs: TestCertificateVcs(repo: "example", commit: fixtureCommit,
      clean: true, untracked: false),
    commands: @[TestCertificateCommand(argv: @["repro", "test"])])

proc found(name: string; c: TestCertificate): FoundCertificate =
  FoundCertificate(name: name,
    read: CertificateReadResult(status: crsOk, cert: c,
      schemaSeen: c.schema))

let state = VerificationState(repo: "example", commit: fixtureCommit)

proc requirement(): VerificationRequirement =
  VerificationRequirement(
    frameworksImplemented: @[reprobuildFrameworkId],
    framework: reprobuildFrameworkId,
    targets: @["t-integration", "t-unit"],
    platforms: @["linux/amd64"],
    requireSignature: false)

suite "TC-7 — framework identification and filtering":

  test "t_framework_field_is_present_and_filtering_works":
    # --- 1. the field is in the record, and is required -------------------
    let mine = cert(reprobuildFrameworkId, @["t-integration", "t-unit"])
    check "framework = \"reprobuild\"" in canonicalCertificatePayload(mine)
    var noFramework = mine
    noFramework.framework = ""
    check certificateStructuralDefect(noFramework) == "framework"
    let readBack = readCertificateRecord(
      serializeCertificateToToml(noFramework))
    check readBack.status == crsMalformed
    check "framework" in readBack.detail

    # --- 2. an unimplemented framework is IGNORED, not rejected -----------
    let foreign = cert("ct-test", @["t-integration", "t-unit"])
    let onlyForeign = evaluateCertificates(@[found("ct.toml", foreign)],
      state, requirement(), RegisteredKeyStore())
    check onlyForeign.outcome == voNotCovered
    check onlyForeign.ignored.len == 1
    check onlyForeign.ignored[0].certificate == "ct.toml"
    check onlyForeign.rejected.len == 0
    check onlyForeign.unevaluated.len == 0
    # The gap is still named — which target, on which platform, for which
    # framework — rather than reported as a bare failure.
    check onlyForeign.missing.len == 1
    check onlyForeign.missing[0].framework == reprobuildFrameworkId
    check onlyForeign.missing[0].platform == "linux/amd64"
    check onlyForeign.missing[0].targets == @["t-integration", "t-unit"]

    # --- 3. an IMPLEMENTED but different framework contributes nothing ----
    var req = requirement()
    req.frameworksImplemented = @[reprobuildFrameworkId, "ct-test"]
    let bothImplemented = evaluateCertificates(@[found("ct.toml", foreign)],
      state, req, RegisteredKeyStore())
    check bothImplemented.outcome == voNotCovered
    check bothImplemented.ignored.len == 0     # we DO implement it…
    check bothImplemented.rejected.len == 0    # …and it is not at fault…
    check bothImplemented.missing.len == 1     # …but it covers another claim.

    # --- 4. reprobuild's own certificate covers ---------------------------
    let covered = evaluateCertificates(@[found("mine.toml", mine)],
      state, requirement(), RegisteredKeyStore())
    check covered.outcome == voCovered
    check covered.missing.len == 0

    # A partial certificate from each framework does NOT union across
    # frameworks: two frameworks may use the same target name for different
    # things.
    let split = evaluateCertificates(@[
        found("mine.toml", cert(reprobuildFrameworkId, @["t-unit"])),
        found("ct.toml", cert("ct-test", @["t-integration"]))],
      state, requirement(), RegisteredKeyStore())
    check split.outcome == voNotCovered
    check split.missing[0].targets == @["t-integration"]

    # --- 5. the shared relevance predicate refuses a foreign framework ----
    let platformReq = CoverageRequirement(
      framework: reprobuildFrameworkId, repo: "example", commit: fixtureCommit,
      platform: "linux/amd64", requiredTargets: @["t-unit"])
    check certificateMatches(mine, platformReq)
    check not certificateMatches(foreign, platformReq)
    check verifyCoverage(@[foreign], platformReq).matchingCerts == 0
    check verifyCoverage(@[mine], platformReq).covered
