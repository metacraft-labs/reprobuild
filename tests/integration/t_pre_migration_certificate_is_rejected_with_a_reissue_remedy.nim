## TC-7 — a pre-migration certificate is REJECTED, not silently accepted.
##
## Every difference this milestone introduced changes the SIGNED BYTES. A
## certificate issued before it carries a signature over a payload that is no
## longer the canonical form, so it cannot be verified — and it MUST NOT be
## translated into the new shape, because translating would mean re-signing a
## payload the original signer never saw. There is deliberately no
## compatibility reader.
##
## The verdict has to be REJECTED rather than merely unreadable, and the
## message has to send the operator to RE-ISSUE rather than to look for
## corruption. Those two failures have opposite remedies:
##
##   * a retired schema  → "your certificate is fine, the format moved;
##                          run 'repro certify' again"
##   * a damaged file    → "something wrote garbage here"
##   * a FUTURE schema   → "this consumer cannot read it" (unverifiable, and
##                          NOT the same as not-covered)
##
## The record below is a verbatim pre-migration ``reprobuild.test-certificate.v1``
## as reprobuild emitted it up to TC-6: flat ``repo`` / ``commit`` / ``lock``,
## no ``framework``, no ``[certificate.vcs]``, no ``[[certificate.command]]``.

import std/[strutils, unittest]

import repro_cli_support

const
  fixtureCommit = "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4"

  preMigrationRecord = """schema = "reprobuild.test-certificate.v1"

[certificate]
project = "lib-a"
repo = "lib-a"
commit = "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4"
lock = "blake3:0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
platform = "linux/amd64"
targets = ["t-unit", "t-integration"]
result = "passed"
issued_at = "2026-06-23T10:14:33Z"
issuer = "repro-test@build-host-7"
key_id = "repro-daemon-key"

[certificate.signature]
algorithm = "ed25519"
value = "c2lnbmVkLW92ZXItdGhlLW9sZC1wYXlsb2Fk"
"""

  futureSchemaRecord = """schema = "test-certificate.v2"

[certificate]
framework = "reprobuild"
project = "lib-a"
platform = "linux/amd64"
targets = ["t-integration", "t-unit"]
result = "passed"
issued_at = "2026-06-23T10:14:33Z"
issuer = "repro-test@build-host-7"

[certificate.vcs]
repo = "lib-a"
commit = "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4"
clean = true
untracked = false

[[certificate.command]]
argv = ["repro", "test"]
"""

let state = VerificationState(repo: "lib-a", commit: fixtureCommit)

proc requirement(): VerificationRequirement =
  VerificationRequirement(
    frameworksImplemented: @[reprobuildFrameworkId],
    framework: reprobuildFrameworkId,
    targets: @["t-integration", "t-unit"],
    platforms: @["linux/amd64"],
    requireSignature: false)

suite "TC-7 — the migration boundary":

  test "t_pre_migration_certificate_is_rejected_with_a_reissue_remedy":
    # --- the reader names the retirement, and the remedy ------------------
    let read = readCertificateRecord(preMigrationRecord)
    check read.status == crsRetiredSchema
    check read.schemaSeen == retiredReprobuildCertificateSchema
    # The operator is told to RE-ISSUE, and told WHY — not handed a parse
    # error that reads like a damaged file.
    check "re-issue" in read.detail.toLowerAscii()
    check "repro certify" in read.detail
    check "no longer the canonical form" in read.detail
    # …and it is emphatically NOT a translation offer.
    check "translat" in read.detail.toLowerAscii()

    # The raising reader carries the same message, so a caller that only has
    # the exception still gets the remedy.
    var raised = ""
    try:
      discard parseCertificateFromToml(preMigrationRecord)
    except TestCertificateParseError as err:
      raised = err.msg
    check "repro certify" in raised

    # --- it is REJECTED, and it does NOT cover ----------------------------
    let report = evaluateCertificates(@[FoundCertificate(
        name: "pre-migration.toml", read: read)],
      state, requirement(), RegisteredKeyStore())
    check report.outcome == voNotCovered
    check report.rejected.len == 1
    check report.rejected[0].certificate == "pre-migration.toml"
    check report.unevaluated.len == 0     # NOT "could not tell"
    check report.ignored.len == 0
    # Silently accepting it would show up right here as a covered verdict.
    check report.missing.len == 1
    check report.missing[0].targets == @["t-integration", "t-unit"]

    # --- the retired schema is not the same failure as a FUTURE one -------
    let future = readCertificateRecord(futureSchemaRecord)
    check future.status == crsUnknownSchema
    let futureReport = evaluateCertificates(@[FoundCertificate(
        name: "future.toml", read: future)],
      state, requirement(), RegisteredKeyStore())
    # A record in a schema version this build does not implement MAY be a
    # perfectly good certificate it simply cannot read, so the outcome is
    # UNVERIFIABLE — fix the configuration — while the retired one is
    # NOT-COVERED — re-issue. Collapsing the two is the defect.
    check futureReport.outcome == voUnverifiable
    check futureReport.unevaluated.len == 1
    check futureReport.rejected.len == 0

    # --- and a genuinely damaged file is a third thing --------------------
    let damaged = readCertificateRecord("schema = \"test-certificate.v1\"\n" &
      "[certificate]\nproject = \"unterminated\n")
    check damaged.status == crsMalformed
    check "repro certify" notin damaged.detail

    # --- the current schema is not the retired one ------------------------
    check testCertificateSchemaV1 == "test-certificate.v1"
    check retiredReprobuildCertificateSchema != testCertificateSchemaV1
