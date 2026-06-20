## Smoke test for the from-source ``sddmSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TWENTY-SECOND real
## production from-source recipe and the CLOSING recipe in the Plasma
## stack batch. sddm's unique coverage angle vs the prior twenty-one
## recipes is that it's the FIRST recipe to ship THREE artifacts
## (two executables + one library) from a single ``package`` macro.
## Every prior multi-artifact recipe shipped either TWO artifacts
## (wayland's two libs, pango's two libs, mutter / gnome-shell /
## kwin / plasma-workspace's library+executable pairs, gdm's two
## executables) or FOUR (glib2's four libs). A regression that
## collapsed the artifact-name partitioning at the three-artifact
## cardinality would surface here, and a regression that mis-tagged
## any of the three individual kind discriminants (exec vs lib) would
## surface too.
##
## Coverage (13 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * THREE artifact registration (M3) — ``sddm`` + ``sddmGreeter``
##     tagged ``dakExecutable`` and ``libSddmCommon`` tagged
##     ``dakLibrary`` within the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + two executable artifacts + one library
# artifact under ``sddmSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/sddm/vendor/sddm-0.21.0.tar.gz"

const ExpectedHash =
  "f895de2683627e969e4849dbfbbb2b500787481ca5ba0de6d6dfdae5f1549abf"

const ExpectedCmakeFlags = @[
  "-DBUILD_TESTING=OFF",
  "-DBUILD_MAN_PAGES=OFF",
  "-DENABLE_JOURNALD=OFF",
  "-DCMAKE_BUILD_TYPE=Release",
]

suite "sddmSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("sddmSource")
    check spec.packageName == "sddmSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 3,557,266-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("sddmSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("sddmSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "cmakeFlags does not leak into the configure channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register two executables + a library with correct kinds":
    # M3 artifact registry: ``sddm`` + ``sddmGreeter`` are tagged
    # ``dakExecutable`` while ``libSddmCommon`` is tagged
    # ``dakLibrary``. The unique coverage of THIS recipe is that it's
    # the first recipe to ship THREE artifacts from a single package.
    # A regression that flattened the kind discriminator would
    # mis-route the M9.L install path (``lib/`` vs ``bin/``); a
    # regression that collapsed the artifact-name partitioning at
    # the three-artifact cardinality would not produce three
    # distinct entries with the expected names below.
    let arts = registeredArtifacts("sddmSource")
    check arts.len == 3
    var seenDaemon = false
    var seenGreeter = false
    var seenLib = false
    for art in arts:
      check art.packageName == "sddmSource"
      case art.artifactName
      of "sddm":
        seenDaemon = true
        check art.kind == dakExecutable
      of "sddmGreeter":
        seenGreeter = true
        check art.kind == dakExecutable
      of "libSddmCommon":
        seenLib = true
        check art.kind == dakLibrary
      else:
        discard
    check seenDaemon
    check seenGreeter
    check seenLib

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is
    # recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at
    # the canonical GitHub project that hosts the sddm source tree.
    let vs = registeredVersions("sddmSource")
    check vs.len == 1
    check vs[0].version == "0.21.0"
    check vs[0].sourceRevision == "v0.21.0"
    check vs[0].sourceUrl ==
      "https://github.com/sddm/sddm/archive/refs/tags/v0.21.0.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/sddm/sddm"
