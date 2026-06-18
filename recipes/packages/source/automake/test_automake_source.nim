## Smoke test for the from-source ``automakeSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the M9.N Batch D build-tool
## slice. automake's unique coverage angles vs the prior 78 from-
## source recipes:
##
##   * From-source-autotools consumer with TWO executable artifacts
##     sharing a single ``./configure`` + ``make`` install-tree.
##     Pins the per-artifact stage-copy fan-out at the
##     two-executable cardinality (vs the seven-executable autoconf
##     sibling in this same batch).
##   * Real sha256 on the fetch channel — the test asserts the exact
##     64-char hex hash recorded in the recipe + the algorithm tag.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality + channel-isolation spot-check.
##   * TWO ``executable`` artifact registration (M3) — automake +
##     aclocal both tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + two executable artifacts under
# ``automakeSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/automake/automake-1.17.tar.xz"

# Real sha256 over the upstream automake-1.17.tar.xz tarball; see
# ``repro.nim``'s sha256 strategy section.
const ExpectedHash =
  "b069564d4361e50dfe31956fb1982f43201c558588fd1f9142a00b3db6aeecc2"

const ExpectedConfigureFlags = @[
  "--disable-static",
]

suite "automakeSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("automakeSource")
    check spec.packageName == "automakeSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the real sha256 over the upstream tarball":
    # Real sha256 over the upstream ftp.gnu.org tarball; computed
    # locally + asserted exactly.
    let spec = registeredFetchSpec("automakeSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("automakeSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the configure channel.
    let flags = registeredBuildFlags("automakeSource", "", "configure")
    check flags == ExpectedConfigureFlags
    check flags.len == 1

  test "configureFlags does not leak into the meson channel":
    # Cross-channel isolation.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("automakeSource", "", "meson") == emptyStrSeq

  test "configureFlags does not leak into the cmake channel":
    # Cross-channel isolation #2.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("automakeSource", "", "cmake") == emptyStrSeq

  test "configureFlags does not leak into the make channel":
    # Cross-channel isolation #3.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("automakeSource", "", "make") == emptyStrSeq

  test "artifacts register two executables all tagged dakExecutable":
    # M3 artifact registry: automake + aclocal are both tagged
    # ``dakExecutable``.
    let arts = registeredArtifacts("automakeSource")
    check arts.len == 2
    var seenAutomake = false
    var seenAclocal = false
    for art in arts:
      check art.packageName == "automakeSource"
      check art.kind == dakExecutable
      case art.artifactName
      of "automake":
        seenAutomake = true
      of "aclocal":
        seenAclocal = true
      else:
        discard
    check seenAutomake
    check seenAclocal

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source``. The repository points at
    # the canonical savannah.gnu.org mirror.
    let vs = registeredVersions("automakeSource")
    check vs.len == 1
    check vs[0].version == "1.17"
    check vs[0].sourceRevision == "v1.17"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/automake/automake-1.17.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/automake.git"
