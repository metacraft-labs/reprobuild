## TC-7 — a certificate round-trips against the standard's canonical form.
##
## The canonical payload is the exact byte sequence a signature covers, and it
## is the most unforgiving part of the standard: two implementations that
## disagree here by a single byte produce signatures neither can verify while
## agreeing perfectly about everything else. So this test asserts the BYTES,
## not the shape — the literal below is the payload spelled out, so any change
## to key order, spacing, blank lines, escaping or omission is a red diff
## rather than a silent divergence.
##
## Sub-cases:
##   1. the canonical payload of a fully-populated certificate is EXACTLY the
##      documented bytes, and satisfies the encoding rules (UTF-8, LF, no BOM,
##      no trailing whitespace, exactly one closing newline);
##   2. the signature block is EXCLUDED from the payload, and the on-disk
##      record is the payload plus that block;
##   3. an omitted key and an empty key are different payloads: ``key_id`` and
##      ``paths`` are omitted entirely rather than emitted empty;
##   4. ``/`` is an ordinary character and is never escaped;
##   5. the modified-worktree table renders in its fixed order, after
##      ``[certificate.vcs]`` and before the commands;
##   6. a DELIBERATELY NON-CANONICAL rendering of the same field values —
##      CRLF, aligned ``=``, reordered tables, a TOML literal string,
##      ``\uXXXX`` escapes, an empty signature block — parses to exactly the
##      same payload. That is the property that lets a cosmetically
##      reformatted certificate still verify against its own signature.
##
## The fixture's ``targets`` are deliberately ALREADY SORTED so that this test
## does not also fail for a sorting regression: sorting is owned by
## ``t_targets_are_sorted_and_deduplicated_in_the_signed_payload``.

import std/[strutils, unittest]

import repro_cli_support

const
  fixtureCommit = "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4"

  expectedPayload = """schema = "test-certificate.v1"

[certificate]
framework = "reprobuild"
project = "example"
platform = "linux/amd64"
targets = ["t-integration", "t-unit"]
result = "passed"
issued_at = "2026-06-23T10:14:33Z"
issuer = "repro-test@build-host-7"
key_id = "repro-sign-2026-q2"

[certificate.vcs]
repo = "example"
commit = "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4"
clean = true
untracked = false

[[certificate.command]]
argv = ["repro", "test", "--targets", "t-integration,t-unit"]
"""

  # The SAME field values, rendered as badly as the standard still allows.
  nonCanonical = "# a deliberately non-canonical rendering\r\n" &
    "schema   = 'test-certificate.v1'\r\n" &
    "\r\n" &
    "[certificate.vcs]\r\n" &
    "untracked = false\r\n" &
    "clean     = true\r\n" &
    "commit    = \"a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4\"\r\n" &
    "repo      = \"example\"\r\n" &
    "paths     = []\r\n" &
    "\r\n" &
    "[[certificate.command]]\r\n" &
    "argv = [\r\n" &
    "  \"repro\",\r\n" &
    "  \"test\",\r\n" &
    "  \"--targets\",\r\n" &
    "  \"t-integration,t-unit\",\r\n" &
    "]\r\n" &
    "\r\n" &
    "[certificate]\r\n" &
    "key_id     = \"repro-sign-2026-q2\"\r\n" &
    "issuer     = \"repro-test@build-host-7\"\r\n" &
    "result     = \"passed\"\r\n" &
    "targets    = [ \"t-integration\", \"t-\\u0075nit\" ]\r\n" &
    "issued_at  = \"2026-06-23T10:14:33Z\"\r\n" &
    "platform   = \"linux/amd64\"\r\n" &
    "project    = 'example'\r\n" &
    "framework  = \"reprobuild\"\r\n" &
    "\r\n" &
    "[certificate.signature]\r\n" &
    "algorithm = \"\"\r\n" &
    "value     = \"\"\r\n"

proc fixtureCertificate(): TestCertificate =
  TestCertificate(
    schema: testCertificateSchemaV1,
    framework: reprobuildFrameworkId,
    project: "example",
    platform: "linux/amd64",
    targets: @["t-integration", "t-unit"],
    result: tcrPassed,
    issuedAt: "2026-06-23T10:14:33Z",
    issuer: "repro-test@build-host-7",
    keyId: "repro-sign-2026-q2",
    vcs: TestCertificateVcs(
      repo: "example", commit: fixtureCommit, clean: true, untracked: false),
    commands: @[TestCertificateCommand(
      argv: @["repro", "test", "--targets", "t-integration,t-unit"])],
    signature: TestCertificateSignature(
      algorithm: "ed25519", value: "c2lnbmF0dXJlLWJ5dGVz"))

suite "TC-7 — canonical form":

  test "t_certificate_round_trips_against_the_canonical_form":
    let cert = fixtureCertificate()
    let payload = canonicalCertificatePayload(cert)

    # --- 1. the exact bytes ------------------------------------------------
    if payload != expectedPayload:
      checkpoint("canonical payload diverged:\n--- produced ---\n" & payload &
        "\n--- expected ---\n" & expectedPayload)
    check payload == expectedPayload

    # Encoding rules (Canonical-Payload §1). LF only, no trailing whitespace
    # on any line, ends with exactly ONE newline.
    check '\r' notin payload
    check payload.endsWith("\n")
    check not payload.endsWith("\n\n")
    for line in payload.split('\n'):
      check line == line.strip(leading = false, trailing = true)

    # --- 2. the signature block is excluded, and only appended -------------
    let record = serializeCertificateToToml(cert)
    check record == payload & "\n[certificate.signature]\n" &
      "algorithm = \"ed25519\"\nvalue = \"c2lnbmF0dXJlLWJ5dGVz\"\n"
    check "[certificate.signature]" notin payload

    # --- 3. omitted is not empty ------------------------------------------
    var unsigned = cert
    unsigned.keyId = ""
    unsigned.signature = TestCertificateSignature()
    let unsignedPayload = canonicalCertificatePayload(unsigned)
    check "key_id" notin unsignedPayload
    check "key_id = \"\"" notin unsignedPayload
    # ``paths`` is absent here and must not appear as an empty array.
    check "paths" notin payload
    var emptyScope = cert
    emptyScope.vcs.paths = @[]
    check "paths" notin canonicalCertificatePayload(emptyScope)

    # --- 4. ``/`` is an ordinary character --------------------------------
    # A JSON encoder is PERMITTED to write ``\/``, which is valid JSON,
    # invalid here, and a different signature.
    check "platform = \"linux/amd64\"" in payload
    check "\\/" notin payload

    # --- 5. the modified-worktree table, in its fixed order ---------------
    var dirty = cert
    dirty.vcs.clean = false
    dirty.vcs.worktree = TestCertificateWorktree(present: true,
      tree: "9f8e7d6c5b4a3928170695e4d3c2b1a099887766",
      format: "git-diff --no-renames -U3",
      patchDigest: "blake3:4a1b")
    let dirtyPayload = canonicalCertificatePayload(dirty)
    check ("clean = false\nuntracked = false\n\n" &
      "[certificate.vcs.worktree]\n" &
      "tree = \"9f8e7d6c5b4a3928170695e4d3c2b1a099887766\"\n" &
      "format = \"git-diff --no-renames -U3\"\n" &
      "patch_digest = \"blake3:4a1b\"\n\n" &
      "[[certificate.command]]\n") in dirtyPayload

    # --- 6. reconstruct FROM THE PARSED FIELDS, not from the bytes --------
    let reread = readCertificateRecord(record)
    check reread.status == crsOk
    check canonicalCertificatePayload(reread.cert) == payload

    let reformatted = readCertificateRecord(nonCanonical)
    if reformatted.status != crsOk:
      checkpoint("non-canonical rendering did not parse: " & reformatted.detail)
    check reformatted.status == crsOk
    let recovered = canonicalCertificatePayload(reformatted.cert)
    if recovered != payload:
      checkpoint("reformatted rendering produced different bytes:\n" &
        recovered & "\n--- expected ---\n" & payload)
    check recovered == payload
    # An empty signature block means UNSIGNED, exactly like an absent one.
    check not reformatted.cert.isSigned

    # A value with no canonical form (an unescapable control character) is
    # refused rather than repaired.
    var hostile = cert
    hostile.issuer = "runner\x01"
    check not certificateValueIsRepresentable(hostile.issuer)
    expect CertificateSerializationError:
      discard canonicalCertificatePayload(hostile)
