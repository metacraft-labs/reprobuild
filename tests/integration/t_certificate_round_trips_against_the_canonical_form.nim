## TC-7 / TC-8b — a certificate round-trips against the standard's canonical
## form, in the content-bound shape of the standard's 2026-10-09 revision.
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
##   3. an omitted key and an empty key are different payloads: ``key_id``,
##      ``paths`` and ``base`` are omitted entirely rather than emitted empty;
##   4. ``/`` is an ordinary character and is never escaped;
##   5. ``[certificate.vcs]`` keys render in the revised fixed order — ``repo``,
##      ``paths``, ``content``, ``untracked``, ``base`` — with ``base`` LAST
##      when present and ABSENT (not empty) when there is no commit to name;
##      ``content`` is emitted verbatim, unvalidated. (TC-8b replaced the
##      former case 5, the ``[certificate.vcs.worktree]`` table, which the
##      revision removed from the format.) A received ``base = ""`` is
##      malformed rather than read as absent;
##   6. a DELIBERATELY NON-CANONICAL rendering of the same field values —
##      CRLF, aligned ``=``, reordered tables, a TOML literal string,
##      ``\uXXXX`` escapes, an inline ``vcs`` table, quoted keys, a
##      multi-line string, an empty signature block — parses to exactly the
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
  fixtureContent = "git-tree-sha1:9f8e7d6c5b4a3928170695e4d3c2b1a099887766"

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
content = "git-tree-sha1:9f8e7d6c5b4a3928170695e4d3c2b1a099887766"
untracked = false
base = "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4"

[[certificate.command]]
argv = ["repro", "test", "--targets", "t-integration,t-unit"]
"""

  # The SAME field values, rendered as badly as the standard still allows.
  nonCanonical = "# a deliberately non-canonical rendering\r\n" &
    "schema   = 'test-certificate.v1'\r\n" &
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
    "vcs = { untracked = false, base = '" & fixtureCommit & "', " &
      "\"content\" = \"" & fixtureContent & "\", repo = \"\"\"example\"\"\", " &
      "paths = [] }\r\n" &
    "\"key_id\"   = \"repro-sign-2026-q2\"\r\n" &
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
      repo: "example", content: fixtureContent, untracked: false,
      base: fixtureCommit),
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
    # ``base`` likewise: no commit to name means no ``base`` line at all.
    var noBase = cert
    noBase.vcs.base = ""
    let noBasePayload = canonicalCertificatePayload(noBase)
    check "base" notin noBasePayload
    check noBasePayload == expectedPayload.replace(
      "base = \"" & fixtureCommit & "\"\n", "")

    # --- 4. ``/`` is an ordinary character --------------------------------
    # A JSON encoder is PERMITTED to write ``\/``, which is valid JSON,
    # invalid here, and a different signature.
    check "platform = \"linux/amd64\"" in payload
    check "\\/" notin payload

    # --- 5. the revised [certificate.vcs] order ---------------------------
    # repo, paths, content, untracked, base — not alphabetical, and with the
    # scope between repo and content (sorted and deduplicated), base last.
    var scoped = cert
    scoped.vcs.paths = @["src/db-backend", "Cargo.lock", "src/db-backend"]
    scoped.vcs.untracked = true
    check ("[certificate.vcs]\n" &
      "repo = \"example\"\n" &
      "paths = [\"Cargo.lock\", \"src/db-backend\"]\n" &
      "content = \"" & fixtureContent & "\"\n" &
      "untracked = true\n" &
      "base = \"" & fixtureCommit & "\"\n\n" &
      "[[certificate.command]]\n") in canonicalCertificatePayload(scoped)
    # ``content`` is emitted VERBATIM: the serializer neither validates nor
    # re-cases it (a malformed id is the verifier's finding, not a value to
    # rewrite before signing).
    var odd = cert
    odd.vcs.content = "Git-Tree-SHA1:ABC"
    check "content = \"Git-Tree-SHA1:ABC\"\n" in canonicalCertificatePayload(odd)
    # The commit-bound keys of the earlier draft appear nowhere.
    for gone in ["commit = ", "clean = ", "worktree", "patch_digest"]:
      check gone notin payload
    # A received ``base = ""`` is not "absent": a producer MUST omit it
    # (Standard §3.2.3), and reading it as absent would be a repair.
    let emptyBase = readCertificateRecord(serializeCertificateToToml(cert).replace(
      "base = \"" & fixtureCommit & "\"", "base = \"\""))
    check emptyBase.status == crsMalformed
    check "base" in emptyBase.detail
    # Input that is not TOML is refused, never read as something close to it:
    # a JSON ``\/`` escape, and a bare word that is no TOML value.
    let jsonEscape = readCertificateRecord(serializeCertificateToToml(cert).replace(
      "platform = \"linux/amd64\"", "platform = \"linux\\/amd64\""))
    check jsonEscape.status == crsMalformed
    let bareWord = readCertificateRecord(serializeCertificateToToml(cert).replace(
      "[certificate.vcs]\n", "[certificate.vcs]\nextra = nonsense\n"))
    check bareWord.status == crsMalformed
    let unknownNumber = readCertificateRecord(serializeCertificateToToml(cert).replace(
      "[certificate.vcs]\n", "[certificate.vcs]\nextra = 1_000\n"))
    # Valid TOML under a key the v1 schema does not define: since Standard
    # §3.4 (spec 5b43c20) the record is closed to extensions, so this is
    # malformed too — for the unknown key, not for the number.
    check unknownNumber.status == crsMalformed
    check "unknown key or table 'certificate.vcs.extra'" in
      unknownNumber.detail

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
