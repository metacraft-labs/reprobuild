## TC-7 — ``targets`` are sorted and deduplicated in the SIGNED payload.
##
## Before this milestone reprobuild emitted targets in observed/run order,
## which made the signed bytes a function of SCHEDULING rather than of the
## claim: the same suite, the same commit and the same result could produce a
## different order on the next run and therefore a different signature for an
## identical claim.
##
## The load-bearing assertion is therefore not "the array looks sorted" but
## "two runs that attest the same thing produce the same SIGNATURE": the test
## signs both orderings with a real ed25519 key and compares the signature
## bytes. ed25519 is deterministic under RFC 8032 and OpenSSH's framing adds
## nothing random, so identical payloads must give identical signatures — and
## a producer that emitted run order would give two different ones.
##
## It also pins the three things the sort is NOT, each of which is some
## language's default:
##   * not locale collation (``Zebra`` must not sort next to ``zebra``);
##   * not UTF-16 code-unit order (an astral character encodes as a surrogate
##     pair that compares BELOW ``E000``–``FFFF`` and reverses byte order);
##   * not a sort of the ESCAPED rendering (a value containing TAB sorts by
##     ``09``; its rendering ``\t`` would sort by ``5C``).
## and that NO Unicode normalization happens anywhere, and that ``argv`` is
## neither sorted nor deduplicated because an argument vector is ordered by
## nature.
##
## Skip rule: ``ssh-keygen`` missing (the signature-stability sub-case needs
## the real signer).

import std/[os, strutils, tempfiles, unittest]

import repro_cli_support

include tc5_cert_signing_helpers

const sortKeyId = "tc7-sort-key"

proc certWithTargets(targets: seq[string]): TestCertificate =
  TestCertificate(
    schema: testCertificateSchemaV1,
    framework: reprobuildFrameworkId,
    project: "example",
    platform: "linux/amd64",
    targets: targets,
    result: tcrPassed,
    issuedAt: "2026-06-23T10:14:33Z",
    issuer: "repro-test@build-host-7",
    vcs: TestCertificateVcs(repo: "example",
      commit: "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4",
      clean: true, untracked: false),
    commands: @[TestCertificateCommand(argv: @["repro", "test"])])

proc targetsLine(cert: TestCertificate): string =
  for line in canonicalCertificatePayload(cert).splitLines():
    if line.startsWith("targets = "): return line
  ""

suite "TC-7 — targets are sorted and deduplicated":

  test "t_targets_are_sorted_and_deduplicated_in_the_signed_payload":
    # --- run order in, sorted order out -----------------------------------
    check targetsLine(certWithTargets(@["t-unit", "t-integration", "t-bench"])) ==
      "targets = [\"t-bench\", \"t-integration\", \"t-unit\"]"

    # --- duplicates removed BEFORE sorting --------------------------------
    check targetsLine(certWithTargets(@["t-unit", "t-bench", "t-unit"])) ==
      "targets = [\"t-bench\", \"t-unit\"]"

    # --- one target, no separator -----------------------------------------
    check targetsLine(certWithTargets(@["t-unit"])) == "targets = [\"t-unit\"]"

    # --- byte order, NOT locale collation ---------------------------------
    # 'Z' is 0x5A and 'a' is 0x61, so ``Zebra`` sorts FIRST. Collation would
    # fold case and put it next to ``zebra``.
    check targetsLine(certWithTargets(@["apple", "zebra", "Zebra"])) ==
      "targets = [\"Zebra\", \"apple\", \"zebra\"]"

    # --- byte order, NOT UTF-16 code-unit order ---------------------------
    # The bytes are spelled out so nothing about this case depends on how an
    # editor or a locale renders it.
    #   U+1F600 GRINNING FACE : UTF-8 F0 9F 98 80 ; UTF-16 D83D DE00
    #   U+FFFD  REPLACEMENT   : UTF-8 EF BF BD    ; UTF-16 FFFD
    # By BYTES, F0 > EF, so the replacement character sorts FIRST. By UTF-16
    # CODE UNITS, D83D < FFFD, so the emoji would sort first — a surrogate
    # pair reverses the order for every astral character.
    const emoji = "t-\xF0\x9F\x98\x80"
    const replacement = "t-\xEF\xBF\xBD"
    check targetsLine(certWithTargets(@[emoji, replacement])) ==
      "targets = [\"" & replacement & "\", \"" & emoji & "\"]"

    # --- sorting happens BEFORE escaping ----------------------------------
    # TAB is 0x09 and '!' is 0x21, so the tabbed value sorts first. Sorting
    # the RENDERED forms would compare "\\t" (0x5C) against "!" (0x21) and
    # reverse them.
    check targetsLine(certWithTargets(@["t-a!b", "t-a\tb"])) ==
      "targets = [\"t-a\\tb\", \"t-a!b\"]"

    # --- no Unicode normalization anywhere --------------------------------
    # A PRECOMPOSED e-acute (U+00E9, UTF-8 C3 A9) and a DECOMPOSED e + U+0301
    # (UTF-8 65 CC 81) are DIFFERENT values: not folded together, not
    # deduplicated against each other, and sorted by their bytes — 0x65 ('e')
    # is below 0xC3, so the decomposed form comes first. Normalizing would
    # silently change what a signature covers, which is why the bytes are
    # written out here rather than typed as characters.
    const precomposed = "t-\xC3\xA9"
    const decomposed = "t-e\xCC\x81"
    check precomposed != decomposed
    let mixed = certWithTargets(@[precomposed, decomposed, decomposed])
    check targetsLine(mixed) ==
      "targets = [\"" & decomposed & "\", \"" & precomposed & "\"]"

    # --- argv is NEITHER sorted NOR deduplicated --------------------------
    var withArgv = certWithTargets(@["t-unit"])
    withArgv.commands = @[TestCertificateCommand(
      argv: @["repro", "test", "--select", "b", "--select", "a", ""])]
    let payload = canonicalCertificatePayload(withArgv)
    check ("argv = [\"repro\", \"test\", \"--select\", \"b\", " &
      "\"--select\", \"a\", \"\"]") in payload
    # Command ENTRIES stay in execution order too.
    withArgv.commands = @[
      TestCertificateCommand(argv: @["second-in-name-only"]),
      TestCertificateCommand(argv: @["first-in-name-only"])]
    let ordered = canonicalCertificatePayload(withArgv)
    check ordered.find("second-in-name-only") < ordered.find("first-in-name-only")

    # --- THE POINT: the same claim signs to the same bytes ----------------
    if findExe("ssh-keygen").len == 0:
      checkpoint("ssh-keygen absent; skipping the signature-stability case")
    else:
      let scratch = createTempDir("repro-tc7-sort-", "")
      defer: removeDir(scratch)
      let key = genEd25519Key(scratch / "keys", "tc7-sort", sortKeyId)
      var runOrderA = certWithTargets(@["t-unit", "t-integration"])
      var runOrderB = certWithTargets(@["t-integration", "t-unit", "t-unit"])
      check canonicalCertificatePayload(runOrderA) ==
        canonicalCertificatePayload(runOrderB)
      signCertificateOnIssuance(runOrderA, sortKeyId, key.priv)
      signCertificateOnIssuance(runOrderB, sortKeyId, key.priv)
      check runOrderA.signature.value == runOrderB.signature.value
      # And both verify against the registered key, so the equality is not an
      # artefact of two equally broken signatures.
      var store: RegisteredKeyStore
      store.registerKey(sortKeyId, key.pub)
      check verifyCertificateSignature(runOrderA, store) == svValid
      check verifyCertificateSignature(runOrderB, store) == svValid
