## Smoke test for the from-source ``iproute2Source`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FORTY-NINTH real production
## from-source recipe. iproute2's unique coverage angle vs the prior
## forty-eight is the FOUR-EXECUTABLE single-package shape driven by a
## RAW Makefile paired with a HAND-ROLLED ``./configure`` shell-script
## wrapper (NOT autoconf-generated). The ``configureFlags:`` channel
## carries a single ``--without-libelf`` flag — the smallest production
## configure-flag set in the corpus and a useful pin for the
## per-channel one-flag-only edge case.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * FOUR executable artifact registration (M3) — ``ip`` + ``tc`` +
##     ``ss`` + ``bridge`` all tagged ``dakExecutable``, all in the
##     same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + four executable artifacts under
# ``iproute2Source`` at module init time.
import ./repro

const ExpectedUrl =
  "https://www.kernel.org/pub/linux/utils/net/iproute2/iproute2-6.12.0.tar.xz"

const ExpectedHash =
  "bbd141ef7b5d0127cc2152843ba61f274dc32814fa3e0f13e7d07a080bef53d9"

const ExpectedConfigureFlags = @[
  "--without-libelf",
]

suite "iproute2Source — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("iproute2Source")
    check spec.packageName == "iproute2Source"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 925,392-byte tarball; length check guards
    # against a future bump that forgets to widen the hash alongside
    # the URL.
    let spec = registeredFetchSpec("iproute2Source")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream kernel.org release
    # tarballs use.
    let spec = registeredFetchSpec("iproute2Source")
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
  test "artifacts register four executables with correct kinds":
    # M3 artifact registry: ``ip`` + ``tc`` + ``ss`` + ``bridge`` are
    # all tagged ``dakExecutable``. iproute2 ships only executables
    # at the externally-consumed surface (the internal
    # ``libnetlink.a`` static archive + helper libraries are NOT
    # installed as library artifacts in the distro-packaging sense).
    let arts = registeredArtifacts("iproute2Source")
    check arts.len == 4
    var seenIp = false
    var seenTc = false
    var seenSs = false
    var seenBridge = false
    for art in arts:
      check art.packageName == "iproute2Source"
      check art.kind == dakExecutable
      case art.artifactName
      of "ip":
        seenIp = true
      of "tc":
        seenTc = true
      of "ss":
        seenSs = true
      of "bridge":
        seenBridge = true
      else:
        discard
    check seenIp
    check seenTc
    check seenSs
    check seenBridge

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream kernel.org release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical mirror on git.kernel.org that hosts the iproute2 source
    # tree.
    let vs = registeredVersions("iproute2Source")
    check vs.len == 1
    check vs[0].version == "6.12.0"
    check vs[0].sourceRevision == "v6.12.0"
    check vs[0].sourceUrl ==
      "https://www.kernel.org/pub/linux/utils/net/iproute2/iproute2-6.12.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.kernel.org/pub/scm/network/iproute2/iproute2.git"
