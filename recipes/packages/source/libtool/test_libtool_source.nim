## Smoke test for the from-source ``libtoolSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the M9.N Batch D build-tool
## slice. libtool's unique coverage angles vs the prior 79 from-
## source recipes:
##
##   * SECOND from-source-autotools consumer with a MIXED-KIND
##     artifact set (two executables + one library sharing a single
##     ``./configure`` + ``make`` install-tree) vs the xz precedent
##     (one executable + one library). Pins the per-artifact stage-
##     copy fan-out at the (2, 1) mixed cardinality.
##   * Real sha256 on the fetch channel — the test asserts the exact
##     64-char hex hash recorded in the recipe + the algorithm tag.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality + channel-isolation spot-check.
##   * MIXED-KIND artifact registration (M3) — libtool + libtoolize
##     tagged ``dakExecutable``, libltdl tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + two executable + one library
# artifacts under ``libtoolSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/libtool/libtool-2.5.4.tar.xz"

# Real sha256 over the upstream libtool-2.5.4.tar.xz tarball; see
# ``repro.nim``'s sha256 strategy section.
const ExpectedHash =
  "f81f5860666b0bc7d84baddefa60d1cb9fa6fceb2398cc3baca6afaa60266675"

const ExpectedConfigureFlags = @[
  "--disable-static",
]

suite "libtoolSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("libtoolSource")
    check spec.packageName == "libtoolSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the real sha256 over the upstream tarball":
    # Real sha256 over the upstream ftp.gnu.org ``.tar.xz`` tarball;
    # computed locally + asserted exactly.
    let spec = registeredFetchSpec("libtoolSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("libtoolSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the configure channel.
    let flags = registeredBuildFlags("libtoolSource", "", "configure")
    check flags == ExpectedConfigureFlags
    check flags.len == 1

  test "configureFlags does not leak into the meson channel":
    # Cross-channel isolation.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("libtoolSource", "", "meson") == emptyStrSeq

  test "configureFlags does not leak into the cmake channel":
    # Cross-channel isolation #2.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("libtoolSource", "", "cmake") == emptyStrSeq

  test "configureFlags does not leak into the make channel":
    # Cross-channel isolation #3.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("libtoolSource", "", "make") == emptyStrSeq

  test "artifacts register two executables + one library mixed-kind":
    # M3 artifact registry: libtool + libtoolize tagged
    # ``dakExecutable``; libltdl tagged ``dakLibrary``. The unique
    # coverage of THIS recipe vs the xz precedent (one exec + one
    # lib) is the (2, 1) mixed cardinality from a single autotools
    # ``./configure`` + ``make`` invocation. A regression that
    # flattened the kind discriminator would mis-route the M9.L
    # install path (``lib/`` vs ``bin/``) for one of the three.
    let arts = registeredArtifacts("libtoolSource")
    check arts.len == 3
    var seenLibtool = false
    var seenLibtoolize = false
    var seenLibltdl = false
    for art in arts:
      check art.packageName == "libtoolSource"
      case art.artifactName
      of "libtool":
        seenLibtool = true
        check art.kind == dakExecutable
      of "libtoolize":
        seenLibtoolize = true
        check art.kind == dakExecutable
      of "libltdl":
        seenLibltdl = true
        check art.kind == dakLibrary
      else:
        discard
    check seenLibtool
    check seenLibtoolize
    check seenLibltdl

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source``. The repository points at
    # the canonical savannah.gnu.org mirror.
    let vs = registeredVersions("libtoolSource")
    check vs.len == 1
    check vs[0].version == "2.5.4"
    check vs[0].sourceRevision == "v2.5.4"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/libtool/libtool-2.5.4.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/libtool.git"
