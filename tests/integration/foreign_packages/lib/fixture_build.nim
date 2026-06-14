## Builds a deterministic snapshot.debian.org-style fixture under a
## supplied directory:
##
##   <root>/
##     cache/
##       snapshot.debian.org/
##         archive/debian/20260601T000000Z/
##           dists/bookworm/
##             InRelease
##             main/binary-amd64/Packages
##     keys/
##       MANIFEST.txt              (fingerprint allowlist for the
##                                  generated InRelease bytes)
##
## The fixture covers the C2 P6 t_c2_harvest_* integration tests
## without requiring live network access. The harvester runs with:
##
##   --source apt:git@debian/bookworm:20260601T000000Z
##   --output-dir <out>
##   --cache-dir <root>/cache
##   --gpg-keys <root>/keys
##   --offline
##   --signature-backend fingerprint-allowlist
##
## The Packages stanzas mirror a real (but trimmed) git-from-bookworm
## closure: git + git-man + libc6 + libcurl3-gnutls + libpcre2-8-0 +
## zlib1g + libgcc-s1 + libcrypt1 + libnghttp2-14 + gcc-12-base +
## perl-base (via the perl virtual). 11 packages: 1 root + 10
## transitive deps. The harvester writes 11 catalog files.

import std/[os, strutils]

import blake3
import nimcrypto/sha2 as nc_sha2

const FixturePackages* = """Package: git
Version: 1:2.39.5-0+deb12u2
Architecture: amd64
Section: vcs
Priority: optional
Filename: pool/main/g/git/git_2.39.5-0+deb12u2_amd64.deb
Size: 8000000
SHA256: 1111111111111111111111111111111111111111111111111111111111111111
Depends: libc6 (>= 2.34), libcurl3-gnutls (>= 7.74.0),
 libpcre2-8-0 (>= 10.32), zlib1g (>= 1:1.1.4), perl:any,
 git-man (>= 1:2.39.5-0+deb12u2)
Description: fast, scalable, distributed revision control system

Package: libc6
Version: 2.36-9+deb12u9
Architecture: amd64
Section: libs
Priority: optional
Filename: pool/main/g/glibc/libc6_2.36-9+deb12u9_amd64.deb
Size: 3000000
SHA256: 2222222222222222222222222222222222222222222222222222222222222222
Depends: libgcc-s1 (>= 3.5), libcrypt1 (>= 1:4.1.0-4)
Description: GNU C Library: Shared libraries

Package: libcurl3-gnutls
Version: 7.88.1-10+deb12u8
Architecture: amd64
Section: libs
Priority: optional
Filename: pool/main/c/curl/libcurl3-gnutls_7.88.1-10+deb12u8_amd64.deb
Size: 400000
SHA256: 3333333333333333333333333333333333333333333333333333333333333333
Depends: libc6 (>= 2.34), libnghttp2-14 (>= 1.41.0), zlib1g (>= 1:1.1.4)
Description: easy-to-use client-side URL transfer library (GnuTLS flavour)

Package: libpcre2-8-0
Version: 10.42-1
Architecture: amd64
Section: libs
Priority: optional
Filename: pool/main/p/pcre2/libpcre2-8-0_10.42-1_amd64.deb
Size: 200000
SHA256: 4444444444444444444444444444444444444444444444444444444444444444
Depends: libc6 (>= 2.34)
Description: New Perl Compatible Regular Expression Library

Package: zlib1g
Version: 1:1.2.13.dfsg-1
Architecture: amd64
Section: libs
Priority: required
Filename: pool/main/z/zlib/zlib1g_1.2.13.dfsg-1_amd64.deb
Size: 100000
SHA256: 5555555555555555555555555555555555555555555555555555555555555555
Depends: libc6 (>= 2.14)
Description: compression library - runtime

Package: libgcc-s1
Version: 12.2.0-14
Architecture: amd64
Section: libs
Priority: required
Filename: pool/main/g/gcc-12/libgcc-s1_12.2.0-14_amd64.deb
Size: 120000
SHA256: 6666666666666666666666666666666666666666666666666666666666666666
Depends: gcc-12-base (= 12.2.0-14), libc6 (>= 2.34)
Description: GCC support library

Package: libcrypt1
Version: 1:4.4.33-2
Architecture: amd64
Section: libs
Priority: optional
Filename: pool/main/libx/libxcrypt/libcrypt1_4.4.33-2_amd64.deb
Size: 80000
SHA256: 7777777777777777777777777777777777777777777777777777777777777777
Depends: libc6 (>= 2.34)
Description: libcrypt shared library

Package: libnghttp2-14
Version: 1.52.0-1+deb12u2
Architecture: amd64
Section: libs
Priority: optional
Filename: pool/main/n/nghttp2/libnghttp2-14_1.52.0-1+deb12u2_amd64.deb
Size: 90000
SHA256: 8888888888888888888888888888888888888888888888888888888888888888
Depends: libc6 (>= 2.34)
Description: library implementing HTTP/2 protocol

Package: gcc-12-base
Version: 12.2.0-14
Architecture: amd64
Section: libs
Priority: required
Filename: pool/main/g/gcc-12/gcc-12-base_12.2.0-14_amd64.deb
Size: 50000
SHA256: 9999999999999999999999999999999999999999999999999999999999999999
Description: GCC, the GNU Compiler Collection (base package)

Package: git-man
Version: 1:2.39.5-0+deb12u2
Architecture: all
Section: doc
Priority: optional
Filename: pool/main/g/git/git-man_2.39.5-0+deb12u2_all.deb
Size: 1700000
SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
Description: fast, scalable, distributed revision control system (manual pages)

Package: perl-base
Version: 5.36.0-7+deb12u1
Architecture: amd64
Section: perl
Priority: required
Filename: pool/main/p/perl/perl-base_5.36.0-7+deb12u1_amd64.deb
Size: 1500000
SHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
Depends: libc6 (>= 2.34)
Provides: perl, perl5, perlapi-5.36.0
Description: minimal Perl system

Package: vim
Version: 2:9.0.1378-2
Architecture: amd64
Section: editors
Priority: optional
Filename: pool/main/v/vim/vim_9.0.1378-2_amd64.deb
Size: 2000000
SHA256: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
Depends: libc6 (>= 2.34), libtinfo6 (>= 6), perl:any
Description: Vi IMproved - enhanced vi editor

Package: libtinfo6
Version: 6.4-4
Architecture: amd64
Section: libs
Priority: required
Filename: pool/main/n/ncurses/libtinfo6_6.4-4_amd64.deb
Size: 100000
SHA256: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
Depends: libc6 (>= 2.34)
Description: shared low-level terminfo library for terminal handling

Package: curl
Version: 7.88.1-10+deb12u8
Architecture: amd64
Section: web
Priority: optional
Filename: pool/main/c/curl/curl_7.88.1-10+deb12u8_amd64.deb
Size: 250000
SHA256: eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
Depends: libc6 (>= 2.34), libcurl4 (>= 7.74.0)
Description: command line tool for transferring data with URLs

Package: libcurl4
Version: 7.88.1-10+deb12u8
Architecture: amd64
Section: libs
Priority: optional
Filename: pool/main/c/curl/libcurl4_7.88.1-10+deb12u8_amd64.deb
Size: 410000
SHA256: ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
Depends: libc6 (>= 2.34), libnghttp2-14 (>= 1.41.0), zlib1g (>= 1:1.1.4)
Description: easy-to-use client-side URL transfer library (OpenSSL flavour)
"""

proc sha256HexBytes(bytes: string): string =
  var ctx: nc_sha2.sha256
  ctx.init()
  ctx.update(bytes)
  let digest = ctx.finish()
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = digest.data[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc blake3HexBytes(bytes: string): string =
  let raw = blake3.digest(bytes)
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = raw[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc buildFixture*(root: string;
                  snapshot = "20260601T000000Z";
                  suite = "bookworm") =
  ## Create a deterministic snapshot fixture under ``root``. The output
  ## is byte-stable: every invocation with the same ``root``, snapshot,
  ## and suite produces byte-identical files.
  let suiteRoot = root / "cache" / "snapshot.debian.org" / "archive" /
    "debian" / snapshot / "dists" / suite
  let pkgDir = suiteRoot / "main" / "binary-amd64"
  createDir(pkgDir)
  let pkgBytes = FixturePackages
  writeFile(pkgDir / "Packages", pkgBytes)
  let pkgSha = sha256HexBytes(pkgBytes)
  let pkgSize = pkgBytes.len

  let inReleasePayload =
    "Origin: Debian\n" &
    "Label: Debian\n" &
    "Suite: " & suite & "\n" &
    "Codename: " & suite & "\n" &
    "Date: Sat, 01 Jun 2026 00:00:00 UTC\n" &
    "Valid-Until: Sat, 01 Jun 2030 00:00:00 UTC\n" &
    "Architectures: amd64\n" &
    "Components: main\n" &
    "Description: Debian " & suite & " snapshot " & snapshot & "\n" &
    "SHA256:\n" &
    " " & pkgSha & " " & $pkgSize &
    " main/binary-amd64/Packages\n"
  let inReleaseFull =
    "-----BEGIN PGP SIGNED MESSAGE-----\n" &
    "Hash: SHA512\n\n" &
    inReleasePayload &
    "-----BEGIN PGP SIGNATURE-----\n\n" &
    "iQIzBAEBCgAdFiEE0000000000000000000000000000000000000000F" &
    "Alxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx00000000000000000000\n" &
    "-----END PGP SIGNATURE-----\n"
  writeFile(suiteRoot / "InRelease", inReleaseFull)

  let keysDir = root / "keys"
  createDir(keysDir)
  writeFile(keysDir / "MANIFEST.txt",
    "# C2 P6 integration-test fixture allowlist\n" &
    "fixture-debian-bookworm " & blake3HexBytes(inReleaseFull) & "\n")

when isMainModule:
  if paramCount() < 1:
    quit("usage: fixture_build <root>")
  buildFixture(paramStr(1))
  echo "fixture built under ", paramStr(1)
