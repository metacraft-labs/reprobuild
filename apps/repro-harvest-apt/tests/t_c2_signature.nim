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

import std/[os, strutils, tempfiles, unittest]

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
