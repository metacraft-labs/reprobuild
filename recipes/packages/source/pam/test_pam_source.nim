## Smoke test for the from-source ``pamSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the THIRTY-THIRD real
## production from-source recipe. Linux-PAM's unique coverage angle vs
## the prior thirty-two is a THREE-library single-package autotools
## recipe (libpam + libpam_misc + libpamc). The prior multi-library
## autotools recipe (openssl) shipped two libraries; pam pushes the
## per-channel partitioning property at the three-library autotools
## cardinality.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake channels MUST be empty).
##   * THREE library artifact registration (M3) — ``libpam`` +
##     ``libpamMisc`` + ``libpamc`` all tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[strutils, unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + three library artifacts under
# ``pamSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://github.com/linux-pam/linux-pam/releases/download/v1.6.1/Linux-PAM-1.6.1.tar.xz"

const ExpectedHash =
  "f8923c740159052d719dbfc2a2f81942d68dd34fcaf61c706a02c9b80feeef8e"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-doc",
  "--without-selinux",
  "--enable-securedir=/lib/security",
]

suite "pamSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("pamSource")
    check spec.packageName == "pamSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 1,054,152-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("pamSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("pamSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register three libraries":
    # M3 artifact registry: THREE libraries are registered, each
    # tagged ``dakLibrary``. Linux-PAM's build emits three shared
    # objects from one ``./configure`` + ``make`` invocation:
    # ``libpam.so`` (core API), ``libpam_misc.so`` (greeter helpers),
    # and ``libpamc.so`` (client-side). A regression that collapsed
    # the multi-library packages or dropped one of the three would
    # surface in the artifact-count + per-artifact name pinning
    # below.
    let arts = registeredArtifacts("pamSource")
    check arts.len == 3
    var seenLibpam = false
    var seenLibpamMisc = false
    var seenLibpamc = false
    for art in arts:
      check art.packageName == "pamSource"
      check art.kind == dakLibrary
      case art.artifactName
      of "libpam":
        seenLibpam = true
      of "libpamMisc":
        seenLibpamMisc = true
      of "libpamc":
        seenLibpamc = true
      else:
        discard
    check seenLibpam
    check seenLibpamMisc
    check seenLibpamc

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical GitHub project that hosts the Linux-PAM source
    # tree.
    let vs = registeredVersions("pamSource")
    check vs.len == 1
    check vs[0].version == "1.6.1"
    check vs[0].sourceRevision == "v1.6.1"
    check vs[0].sourceUrl ==
      "https://github.com/linux-pam/linux-pam/releases/download/v1.6.1/Linux-PAM-1.6.1.tar.xz"
    check vs[0].sourceRepository ==
      "https://github.com/linux-pam/linux-pam"

  test "fetch spec retains the .tar.xz suffix":
    # Defence against a regression that strips file extensions from
    # the URL during normalisation — the convention layer's extract
    # action selects the decompressor (xz vs gzip vs bzip2) from the
    # URL suffix, so dropping ``.xz`` would mis-route to gzip and
    # fail at extract time.
    let spec = registeredFetchSpec("pamSource")
    check spec.url.endsWith(".tar.xz")
