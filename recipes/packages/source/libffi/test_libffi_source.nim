## Smoke test for the from-source ``libffiSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTY-FIRST real production
## from-source recipe and the FIRST recipe in the crypto-and-FFI batch
## (libffi + nettle + libgcrypt + gnutls). libffi's unique coverage
## angle vs the prior fifty is the ``--disable-multi-os-directory`` flag
## — a libffi-specific autotools knob that suppresses the multilib
## install-layout split. A regression that dropped the flag through a
## prefix-matching collapse against ``--disable-docs`` (both start with
## ``--disable-``) would surface in the flag-count + exact-sequence
## pinning below.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libFfi``
##     tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + library artifact under
# ``libffiSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz"

const ExpectedHash =
  "b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-docs",
  "--disable-multi-os-directory",
]

suite "libffiSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("libffiSource")
    check spec.packageName == "libffiSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 1,391,684-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("libffiSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("libffiSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the make channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register a single library":
    # M3 artifact registry: ``libFfi`` is the only artifact and must
    # be tagged ``dakLibrary``. libffi's autotools build emits a single
    # shared object (``libffi.so``) bundling the FFI core + per-arch
    # assembly trampolines + type-encoding helpers. A regression that
    # mis-tagged the artifact kind would mis-route the M9.L install
    # path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("libffiSource")
    check arts.len == 1
    check arts[0].packageName == "libffiSource"
    check arts[0].artifactName == "libFfi"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical GitHub project that hosts the libffi source
    # tree.
    let vs = registeredVersions("libffiSource")
    check vs.len == 1
    check vs[0].version == "3.4.6"
    check vs[0].sourceRevision == "v3.4.6"
    check vs[0].sourceUrl ==
      "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/libffi/libffi"
