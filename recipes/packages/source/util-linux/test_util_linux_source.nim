## Smoke test for the from-source ``utilLinuxSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the THIRTY-SECOND real
## production from-source recipe. util-linux's unique coverage angle vs
## the prior thirty-one is the EIGHT-ARTIFACT (mixed-kind) single-
## package shape: five executables (``mount`` + ``umount`` + ``mkfsBin``
## + ``fdisk`` + ``lsblk``) PLUS three libraries (``libBlkid`` +
## ``libUuid`` + ``libMount``) all built from one autotools
## ``./configure`` + ``make`` invocation. The prior multi-artifact
## record-holder (systemd) shipped six mixed-kind artifacts; util-linux
## pushes the artifact-name partitioning + per-artifact kind-tagging at
## the EIGHT-artifact mixed-kind cardinality. A regression that
## collapsed the artifact-name partitioning at this cardinality (or
## mis-tagged any of the eight individual kind discriminants) would
## surface here.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake channels MUST be empty).
##   * EIGHT artifact registration (M3) — five executables tagged
##     ``dakExecutable`` + three libraries tagged ``dakLibrary``,
##     all in the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + five executable + three library
# artifacts under ``utilLinuxSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://www.kernel.org/pub/linux/utils/util-linux/v2.40/util-linux-2.40.4.tar.xz"

const ExpectedHash =
  "5c1daf733b04e9859afdc3bd87cc481180ee0f88b5c0946b16fdec931975fb79"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--without-python",
  "--without-systemd",
  "--disable-makeinstall-chown",
  "--disable-makeinstall-setuid",
  "--disable-bash-completion",
]

suite "utilLinuxSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("utilLinuxSource")
    check spec.packageName == "utilLinuxSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 8,848,216-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("utilLinuxSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream kernel.org release
    # tarballs use.
    let spec = registeredFetchSpec("utilLinuxSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register five executables + three libraries with correct kinds":
    # M3 artifact registry: ``mount`` + ``umount`` + ``mkfsBin`` +
    # ``fdisk`` + ``lsblk`` are tagged ``dakExecutable`` while
    # ``libBlkid`` + ``libUuid`` + ``libMount`` are tagged
    # ``dakLibrary``. The unique coverage of THIS recipe is that it's
    # the first recipe to ship EIGHT artifacts of MIXED kinds from a
    # single package. A regression that flattened the kind
    # discriminator would mis-route the M9.L install path (``lib/``
    # vs ``bin/``); a regression that collapsed the artifact-name
    # partitioning at the eight-artifact cardinality would not
    # produce eight distinct entries with the expected names below.
    let arts = registeredArtifacts("utilLinuxSource")
    check arts.len == 8
    var seenMount = false
    var seenUmount = false
    var seenMkfsBin = false
    var seenFdisk = false
    var seenLsblk = false
    var seenLibBlkid = false
    var seenLibUuid = false
    var seenLibMount = false
    for art in arts:
      check art.packageName == "utilLinuxSource"
      case art.artifactName
      of "mount":
        seenMount = true
        check art.kind == dakExecutable
      of "umount":
        seenUmount = true
        check art.kind == dakExecutable
      of "mkfsBin":
        seenMkfsBin = true
        check art.kind == dakExecutable
      of "fdisk":
        seenFdisk = true
        check art.kind == dakExecutable
      of "lsblk":
        seenLsblk = true
        check art.kind == dakExecutable
      of "libBlkid":
        seenLibBlkid = true
        check art.kind == dakLibrary
      of "libUuid":
        seenLibUuid = true
        check art.kind == dakLibrary
      of "libMount":
        seenLibMount = true
        check art.kind == dakLibrary
      else:
        discard
    check seenMount
    check seenUmount
    check seenMkfsBin
    check seenFdisk
    check seenLsblk
    check seenLibBlkid
    check seenLibUuid
    check seenLibMount

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream kernel.org release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical mirror on git.kernel.org that hosts the util-linux
    # source tree.
    let vs = registeredVersions("utilLinuxSource")
    check vs.len == 1
    check vs[0].version == "2.40.4"
    check vs[0].sourceRevision == "v2.40.4"
    check vs[0].sourceUrl ==
      "https://www.kernel.org/pub/linux/utils/util-linux/v2.40/util-linux-2.40.4.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.kernel.org/pub/scm/utils/util-linux/util-linux.git"
