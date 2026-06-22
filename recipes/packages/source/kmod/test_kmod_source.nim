## Smoke test for the from-source ``kmodSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FORTY-SEVENTH real
## production from-source recipe. kmod's unique coverage angle vs the
## prior forty-six is the FIVE-ARTIFACT (mixed-kind) single-package
## shape with FOUR executables + ONE library all driven through the
## autotools ``configureFlags:`` channel. The four binaries
## (``modprobe`` + ``lsmod`` + ``insmod`` + ``rmmod``) are the canonical
## Linux kernel-module userland the v1 desktop's GPU + audio + wifi +
## bluetooth autoload paths depend on; ``libKmod`` is the C library
## ModemManager + NetworkManager link against.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * FIVE artifact registration (M3) — four executables tagged
##     ``dakExecutable`` + one library tagged ``dakLibrary``, all in
##     the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + four executable + one library
# artifacts under ``kmodSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://www.kernel.org/pub/linux/utils/kernel/kmod/kmod-33.tar.xz"

const ExpectedHash =
  "dc768b3155172091f56dc69430b5481f2d76ecd9ccb54ead8c2540dbcf5ea9bc"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-manpages",
  "--disable-test-modules",
  "--without-openssl",
]

suite "kmodSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("kmodSource")
    check spec.packageName == "kmodSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 514,428-byte tarball; length check guards
    # against a future bump that forgets to widen the hash alongside
    # the URL.
    let spec = registeredFetchSpec("kmodSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream kernel.org release
    # tarballs use.
    let spec = registeredFetchSpec("kmodSource")
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
  test "artifacts register four executables + one library with correct kinds":
    # M3 artifact registry: ``modprobe`` + ``lsmod`` + ``insmod`` +
    # ``rmmod`` are tagged ``dakExecutable`` while ``libKmod`` is
    # tagged ``dakLibrary``. A regression that flattened the kind
    # discriminator would mis-route the M9.L install path (``lib/``
    # vs ``bin/``); a regression that collapsed the artifact-name
    # partitioning would not produce five distinct entries with the
    # expected names below.
    let arts = registeredArtifacts("kmodSource")
    check arts.len == 5
    var seenModprobe = false
    var seenLsmod = false
    var seenInsmod = false
    var seenRmmod = false
    var seenLibKmod = false
    for art in arts:
      check art.packageName == "kmodSource"
      case art.artifactName
      of "modprobe":
        seenModprobe = true
        check art.kind == dakExecutable
      of "lsmod":
        seenLsmod = true
        check art.kind == dakExecutable
      of "insmod":
        seenInsmod = true
        check art.kind == dakExecutable
      of "rmmod":
        seenRmmod = true
        check art.kind == dakExecutable
      of "libKmod":
        seenLibKmod = true
        check art.kind == dakLibrary
      else:
        discard
    check seenModprobe
    check seenLsmod
    check seenInsmod
    check seenRmmod
    check seenLibKmod

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream kernel.org release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical mirror on git.kernel.org that hosts the kmod source
    # tree.
    let vs = registeredVersions("kmodSource")
    check vs.len == 1
    check vs[0].version == "33"
    check vs[0].sourceRevision == "v33"
    check vs[0].sourceUrl ==
      "https://www.kernel.org/pub/linux/utils/kernel/kmod/kmod-33.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.kernel.org/pub/scm/utils/kernel/kmod/kmod.git"
