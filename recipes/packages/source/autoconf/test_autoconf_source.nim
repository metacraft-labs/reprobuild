## Smoke test for the from-source ``autoconfSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the M9.N Batch D build-tool
## slice. autoconf's unique coverage angles vs the prior 77 from-
## source recipes:
##
##   * FIRST recipe in the corpus to declare SEVEN ``executable``
##     artifacts sharing a single ``./configure`` + ``make`` install-
##     tree. Pins the from-source-autotools convention's per-artifact
##     stage-copy fan-out at the seven-binary cardinality.
##   * SECOND from-source-autotools consumer with a non-empty
##     ``configureFlags:`` block on the desktop-baseline
##     ``--disable-static`` flag alone (vs expat's four-flag set) —
##     pins the M9.I configure-channel registry on a minimal flag
##     set.
##   * Real sha256 on the fetch channel — the test asserts the exact
##     64-char hex hash recorded in the recipe + the algorithm tag.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the single-flag set + channel-isolation
##     spot-check (meson + cmake channels MUST be empty).
##   * SEVEN ``executable`` artifact registration (M3) — autoconf +
##     autoheader + autom4te + autoreconf + autoscan + autoupdate +
##     ifnames all tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + seven executable artifacts under
# ``autoconfSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/autoconf/autoconf-2.72.tar.xz"

# Real sha256 over the upstream autoconf-2.72.tar.xz tarball; see
# ``repro.nim``'s sha256 strategy section.
const ExpectedHash =
  "ba885c1319578d6c94d46e9b0dceb4014caafe2490e437a0dbca3f270a223f5a"

const ExpectedConfigureFlags = @[
  "--disable-static",
]

suite "autoconfSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("autoconfSource")
    check spec.packageName == "autoconfSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the real sha256 over the upstream tarball":
    # Real sha256 over the upstream ftp.gnu.org tarball; computed
    # locally + asserted exactly.
    let spec = registeredFetchSpec("autoconfSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("autoconfSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the configure channel — the
    # single ``--disable-static`` flag is preserved for consistency
    # with the other autotools recipes.
    let flags = registeredBuildFlags("autoconfSource", "", "configure")
    check flags == ExpectedConfigureFlags
    check flags.len == 1

  test "configureFlags does not leak into the meson channel":
    # Cross-channel isolation — guards against a regression that
    # flattens the registries.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("autoconfSource", "", "meson") == emptyStrSeq

  test "configureFlags does not leak into the cmake channel":
    # Cross-channel isolation #2.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("autoconfSource", "", "cmake") == emptyStrSeq

  test "configureFlags does not leak into the make channel":
    # Cross-channel isolation #3.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("autoconfSource", "", "make") == emptyStrSeq

  test "artifacts register seven executables all tagged dakExecutable":
    # M3 artifact registry: autoconf + autoheader + autom4te +
    # autoreconf + autoscan + autoupdate + ifnames are all tagged
    # ``dakExecutable``. A regression that flattened the kind
    # discriminator at the seven-artifact cardinality would surface
    # here.
    let arts = registeredArtifacts("autoconfSource")
    check arts.len == 7
    var seenAutoconf = false
    var seenAutoheader = false
    var seenAutom4te = false
    var seenAutoreconf = false
    var seenAutoscan = false
    var seenAutoupdate = false
    var seenIfnames = false
    for art in arts:
      check art.packageName == "autoconfSource"
      check art.kind == dakExecutable
      case art.artifactName
      of "autoconf":
        seenAutoconf = true
      of "autoheader":
        seenAutoheader = true
      of "autom4te":
        seenAutom4te = true
      of "autoreconf":
        seenAutoreconf = true
      of "autoscan":
        seenAutoscan = true
      of "autoupdate":
        seenAutoupdate = true
      of "ifnames":
        seenIfnames = true
      else:
        discard
    check seenAutoconf
    check seenAutoheader
    check seenAutom4te
    check seenAutoreconf
    check seenAutoscan
    check seenAutoupdate
    check seenIfnames

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source``. The repository points at
    # the canonical savannah.gnu.org mirror that hosts the autoconf
    # source tree.
    let vs = registeredVersions("autoconfSource")
    check vs.len == 1
    check vs[0].version == "2.72"
    check vs[0].sourceRevision == "v2.72"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/autoconf/autoconf-2.72.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/autoconf.git"
