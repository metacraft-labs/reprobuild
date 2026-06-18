## Smoke test for the from-source ``libgcryptSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTY-THIRD real production
## from-source recipe and the THIRD recipe in the crypto-and-FFI batch
## (libffi + nettle + libgcrypt + gnutls). libgcrypt's unique coverage
## angle vs the prior fifty-two is the FIRST .tar.bz2 archive in the
## corpus — the convention layer's extract action selects the bunzip2
## decompressor based on the URL suffix. A regression that defaulted
## the decompressor selection back to gzip / xz would surface in the
## extract phase at engine time; the URL-suffix pinning below is the
## DSL-time pin for that wiring.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip + .tar.bz2 suffix.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set (three consecutive
##     ``--disable-*`` flags that pin the per-channel handling of
##     common-prefix flag names) + channel-isolation spot-check
##     (meson + cmake + make channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libGcrypt``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + library artifact under
# ``libgcryptSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/libgcrypt/vendor/libgcrypt-1.11.0.tar.bz2"

const ExpectedHash =
  "09120c9867ce7f2081d6aaa1775386b98c2f2f246135761aae47d81f58685b9c"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-doc",
  "--disable-padlock-support",
]

suite "libgcryptSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("libgcryptSource")
    check spec.packageName == "libgcryptSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 4,180,345-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("libgcryptSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is a .tar.bz2 tarball with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gnupg.org release
    # tarballs use. FIRST recipe in the corpus to vendor a .tar.bz2
    # archive — the convention layer's extract action selects the
    # bunzip2 decompressor based on the URL suffix. A regression that
    # defaulted the decompressor back to gzip / xz would surface in
    # the extract phase; the suffix check below is the DSL-time pin.
    let spec = registeredFetchSpec("libgcryptSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1
    check spec.url.endsWith(".tar.bz2")

  test "configureFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the configure channel — the
    # autotools ``./configure`` script evaluates options left-to-right
    # and a regression that reorders this seq would silently change
    # build behaviour (static on/off, doc on/off, padlock-support
    # on/off). The three consecutive ``--disable-*`` flags ALSO pin
    # the per-channel handling of common-prefix flag names — a
    # regression that collapsed them via prefix-matching would surface
    # here as a flag-count mismatch.
    let flags = registeredBuildFlags("libgcryptSource", "", "configure")
    check flags == ExpectedConfigureFlags
    check flags.len == 3

  test "configureFlags does not leak into the meson channel":
    # Cross-channel isolation — guards against a regression that
    # flattens the registries.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("libgcryptSource", "", "meson") == emptyStrSeq

  test "configureFlags does not leak into the cmake channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the autotools + CMake channels.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("libgcryptSource", "", "cmake") == emptyStrSeq

  test "configureFlags does not leak into the make channel":
    # Cross-channel isolation #3 — guards against a regression that
    # merges the autotools configure channel into the raw-Makefile
    # channel.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("libgcryptSource", "", "make") == emptyStrSeq

  test "artifacts register a single library":
    # M3 artifact registry: ``libGcrypt`` is the only artifact and
    # must be tagged ``dakLibrary``. libgcrypt's autotools build emits
    # a single shared object (``libgcrypt.so``) bundling the higher-
    # level cipher + MAC + KDF + entropy + asymmetric API on top of
    # the libgpg-error helper library. A regression that mis-tagged
    # the artifact kind would mis-route the M9.L install path
    # (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("libgcryptSource")
    check arts.len == 1
    check arts[0].packageName == "libgcryptSource"
    check arts[0].artifactName == "libGcrypt"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream gnupg.org release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical git.gnupg.org mirror that hosts the libgcrypt
    # source tree.
    let vs = registeredVersions("libgcryptSource")
    check vs.len == 1
    check vs[0].version == "1.11.0"
    check vs[0].sourceRevision == "libgcrypt-1.11.0"
    check vs[0].sourceUrl ==
      "https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.0.tar.bz2"
    check vs[0].sourceRepository ==
      "https://git.gnupg.org/cgi-bin/gitweb.cgi?p=libgcrypt.git"
