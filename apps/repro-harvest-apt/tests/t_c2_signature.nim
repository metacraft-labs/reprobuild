## C2 P3 unit tests for the InRelease signature backend.
##
## Exercises:
##
##   * ``extractClearsignedPayload`` slices a clearsigned OpenPGP block
##     into payload + signature.
##   * ``verifyViaAllowlist`` accepts an InRelease whose blake3 matches
##     a vendored MANIFEST.txt fingerprint AND rejects one whose
##     fingerprint is absent (tampered).
##   * The MANIFEST parser tolerates blanks + ``#`` comments.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip

import blake3

import repro_harvest_apt/signature

const SampleInRelease = """-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

Origin: Debian
Label: Debian
Suite: stable
Version: 12.0
Codename: bookworm
Date: Sat, 01 Jun 2026 00:00:00 UTC
Valid-Until: Sat, 08 Jun 2026 00:00:00 UTC
Architectures: amd64 arm64 armhf i386 mips64el mipsel ppc64el s390x
Description: Debian 12.0 Released 10 June 2023
SHA256:
 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa     12345 main/binary-amd64/Packages.xz
-----BEGIN PGP SIGNATURE-----

iQIzBAEBCgAdFiEEfakefakefakefakefakefakefakefakeFAlxxxxx
... signature bytes here ...
-----END PGP SIGNATURE-----
"""

proc blake3Hex(bytes: string): string =
  let raw = blake3.digest(bytes)
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = raw[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

suite "C2 P3 InRelease signature":

  test "extractClearsignedPayload slices the body":
    let parts = extractClearsignedPayload(SampleInRelease)
    check parts.payload.startsWith("Origin: Debian")
    check parts.payload.contains("SHA256:")
    check parts.payload.contains(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    check parts.signature.startsWith("-----BEGIN PGP SIGNATURE-----")
    check parts.signature.endsWith("-----END PGP SIGNATURE-----")

  test "extractClearsignedPayload rejects malformed input":
    expect SignatureVerificationError:
      discard extractClearsignedPayload("nothing here")
    expect SignatureVerificationError:
      discard extractClearsignedPayload(
        "-----BEGIN PGP SIGNED MESSAGE-----\nbut no sig\n")

  test "verifyViaAllowlist accepts matching fingerprint":
    let dir = createTempDir("c2-sig-allow-", "")
    let manifest = "# allowlist\n" &
      "debian-bookworm " & blake3Hex(SampleInRelease) & "\n"
    writeFile(dir / "MANIFEST.txt", manifest)
    let v = verifyViaAllowlist(SampleInRelease, dir)
    check v.backend == sbFingerprintAllowlist
    check v.signerKeyId == "debian-bookworm"
    check v.payload.contains("SHA256:")
    removeDir(dir)

  test "verifyViaAllowlist rejects tampered bytes":
    let dir = createTempDir("c2-sig-reject-", "")
    let manifest = "debian-bookworm " & blake3Hex(SampleInRelease) & "\n"
    writeFile(dir / "MANIFEST.txt", manifest)
    var tampered = SampleInRelease
    tampered = tampered.replace("Codename: bookworm",
      "Codename: bookwerm")  # one-byte flip
    expect SignatureVerificationError:
      discard verifyViaAllowlist(tampered, dir)
    removeDir(dir)

  test "verifyViaAllowlist refuses on missing MANIFEST":
    let dir = createTempDir("c2-sig-nomf-", "")
    expect SignatureVerificationError:
      discard verifyViaAllowlist(SampleInRelease, dir)
    removeDir(dir)

  test "verifyInRelease falls back to allowlist when gpg unavailable":
    # Force the allowlist backend by passing preferredBackend
    # =sbFingerprintAllowlist.
    let dir = createTempDir("c2-sig-fall-", "")
    let manifest = "x " & blake3Hex(SampleInRelease) & "\n"
    writeFile(dir / "MANIFEST.txt", manifest)
    let v = verifyInRelease(SampleInRelease, dir,
      preferredBackend = sbFingerprintAllowlist)
    check v.backend == sbFingerprintAllowlist
    removeDir(dir)

# ---------------------------------------------------------------------------
# External-gpg verdict: the exit code is not the answer
# ---------------------------------------------------------------------------
#
# gpg 2.4 exits 0 for a good signature made by a key that has since EXPIRED
# (status ``EXPKEYSIG`` next to ``VALIDSIG``), and documents the same for a
# revoked key (``REVKEYSIG``). A verifier that trusts the exit code therefore
# accepts an archive signed by a key its operator retired. The verdict is
# read from the ``--status-fd`` lines instead.

suite "C2 P3 gpg status verdict":

  test "GOODSIG + VALIDSIG with no refusal is good":
    let v = gpgStatusVerdict("""[GNUPG:] NEWSIG
[GNUPG:] KEY_CONSIDERED AAAA 0
[GNUPG:] SIG_ID abc 2026-10-30 1761800000
[GNUPG:] GOODSIG 9165938D90FDDD2E Raspbian
[GNUPG:] VALIDSIG A0DA38D0D76E8B5D638872819165938D90FDDD2E 2026-10-30 1 0 4 1 8 00 A0DA
[GNUPG:] TRUST_UNDEFINED 0 pgp
""")
    check v.good
    check v.signerKeyId == "A0DA38D0D76E8B5D638872819165938D90FDDD2E"

  test "an expired or revoked key, or a bad signature, is refused":
    for status in [
        "[GNUPG:] EXPKEYSIG 9165938D90FDDD2E Raspbian\n" &
          "[GNUPG:] VALIDSIG A0DA 2026-10-30 1 0 4 1 8 00 A0DA\n" &
          "[GNUPG:] KEYEXPIRED 1700000000\n",
        "[GNUPG:] REVKEYSIG 9165938D90FDDD2E Raspbian\n" &
          "[GNUPG:] VALIDSIG A0DA 2026-10-30 1 0 4 1 8 00 A0DA\n",
        "[GNUPG:] GOODSIG 9165938D90FDDD2E Raspbian\n" &
          "[GNUPG:] VALIDSIG A0DA 2026-10-30 1 0 4 1 8 00 A0DA\n" &
          "[GNUPG:] BADSIG 0000000000000001 Other\n",
        "[GNUPG:] BADSIG 9165938D90FDDD2E Raspbian\n",
        "[GNUPG:] ERRSIG 9165938D90FDDD2E 1 8 00 1761800000 9 FPR\n" &
          "[GNUPG:] NO_PUBKEY 9165938D90FDDD2E\n",
        "[GNUPG:] GOODSIG 9165938D90FDDD2E Raspbian\n",
        ""]:
      let v = gpgStatusVerdict(status)
      check not v.good
      check v.reason.len > 0

  test "a real expired key is refused by verifyInReleaseWithKeyring":
    # A deterministic expired-key fixture: a key generated under a faked
    # clock in 2020 with a one-day validity, and a clearsigned InRelease made
    # under the same clock. Verified under the real clock, gpg reports
    # EXPKEYSIG and exits 0. The positive control is a never-expiring key
    # made the same way, whose signature must be accepted.
    let gpgBin = resolveGpgBin()
    if gpgBin.len == 0:
      skip("no gpg on PATH (set REPRO_GPG_BIN)")
    else:
      proc fixture(expiry: string): (string, string) =
        ## (InRelease bytes, keyring file) for a key that expires ``expiry``.
        let home = createTempDir("c2-sig-gpg-", "")
        setFilePermissions(home, {fpUserRead, fpUserWrite, fpUserExec})
        let env = newStringTable()
        env["GNUPGHOME"] = home
        let faked = " --faked-system-time 20200101T000000! "
        let common = gpgBin & " --batch --yes --pinentry-mode loopback" &
          " --passphrase '' --quiet" & faked
        var (output, code) = execCmdEx(common & "--quick-gen-key " &
          "'Fixture <fixture@example.invalid>' default default " & expiry,
          env = env)
        doAssert code == 0, output
        let payload = home / "payload"
        writeFile(payload, "Origin: Fixture\nSuite: test\nSHA256:\n")
        (output, code) = execCmdEx(common & "--clearsign --output " &
          quoteShell(home / "InRelease") & " " & quoteShell(payload),
          env = env)
        doAssert code == 0, output
        (output, code) = execCmdEx(common & "--export --output " &
          quoteShell(home / "keyring.gpg"), env = env)
        doAssert code == 0, output
        (readFile(home / "InRelease"), home / "keyring.gpg")
      let (expiredRelease, expiredKeyring) = fixture("1d")
      let (goodRelease, goodKeyring) = fixture("never")
      # Positive control: the same construction with a valid key passes.
      let ok = verifyInReleaseWithKeyring(goodRelease, goodKeyring)
      check ok.backend == sbExternalGpg
      check ok.payload.startsWith("Origin: Fixture")
      check ok.signerKeyId.len == 40
      # The expired key is refused although gpg exits 0 for it (the log
      # carries the EXPKEYSIG status line that decided it).
      var refused = false
      try:
        discard verifyInReleaseWithKeyring(expiredRelease, expiredKeyring)
      except SignatureVerificationError as ex:
        refused = true
        check "EXPKEYSIG" in ex.msg or "KEYEXPIRED" in ex.msg
        check "verify exit=0" in ex.backendLog
      check refused
      # A signature by one key checked against the other's keyring: NO_PUBKEY.
      expect SignatureVerificationError:
        discard verifyInReleaseWithKeyring(goodRelease, expiredKeyring)
