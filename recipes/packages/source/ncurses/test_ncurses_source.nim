## Smoke test for the from-source ``ncursesSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTY-SECOND real
## production from-source recipe. ncurses's unique coverage angle vs
## the prior sixty-one is being THE canonical Unix terminal-UI library
## + the FIRST source recipe in the corpus to ship a TWO-library +
## TWO-executable mixed-kind shape from a single autotools
## ``./configure`` + ``make`` invocation (the prior precedents — libcap
## one-lib + three-exec, procps one-lib + five-exec — covered the
## library/executable mix at different cardinalities but not the
## TWO-of-each balance).
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production six-flag set +
##     channel-isolation spot-check (meson + cmake + make channels
##     MUST be empty).
##   * FOUR artifact registration (M3) — ``libNcursesw`` + ``libTinfow``
##     tagged ``dakLibrary`` + ``tic`` + ``infocmp`` tagged
##     ``dakExecutable``, all in the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + two library + two executable
# artifacts under ``ncursesSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/ncurses/vendor/ncurses-6.5.tar.gz"

const ExpectedHash =
  "136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--with-shared",
  "--without-debug",
  "--without-ada",
  "--enable-widec",
  "--with-termlib",
]

suite "ncursesSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("ncursesSource")
    check spec.packageName == "ncursesSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 3,688,489-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("ncursesSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("ncursesSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the configure channel — the
    # autotools ``./configure`` script evaluates options left-to-right
    # and a regression that reorders this seq would silently change
    # build behaviour (static on/off, shared on/off, debug build,
    # Ada bindings, widec ABI, termlib split). The mixed
    # ``--disable-``/``--with-``/``--without-``/``--enable-`` prefixes
    # pin the parser's grammar-agnostic flag handling and the
    # six-flag cardinality fills a gap in the corpus between the
    # five-flag (libcap, bash) and seven-flag (vim) recipes.
    let flags = registeredBuildFlags("ncursesSource", "", "configure")
    check flags == ExpectedConfigureFlags
    check flags.len == 6

  test "configureFlags does not leak into the meson channel":
    # Cross-channel isolation — guards against a regression that
    # flattens the registries.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("ncursesSource", "", "meson") == emptyStrSeq

  test "configureFlags does not leak into the cmake channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the autotools + CMake channels.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("ncursesSource", "", "cmake") == emptyStrSeq

  test "configureFlags does not leak into the make channel":
    # Cross-channel isolation #3 — guards against a regression that
    # merges autotools ``configure`` flags onto the raw-Makefile
    # ``make`` channel.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("ncursesSource", "", "make") == emptyStrSeq

  test "artifacts register two libraries + two executables with correct kinds":
    # M3 artifact registry: ``libNcursesw`` + ``libTinfow`` are tagged
    # ``dakLibrary`` while ``tic`` + ``infocmp`` are tagged
    # ``dakExecutable``. The unique coverage of THIS recipe is being
    # the FIRST source recipe to ship a TWO-library + TWO-executable
    # mixed-kind shape from a single autotools ``./configure`` +
    # ``make`` invocation (the prior precedents — libcap one-lib +
    # three-exec, procps one-lib + five-exec — covered the
    # library/executable mix at different cardinalities but not the
    # TWO-of-each balance). A regression that flattened the kind
    # discriminator would mis-route the M9.L install path (``lib/`` vs
    # ``bin/``); a regression that collapsed the artifact-name
    # partitioning would not produce four distinct entries with the
    # expected names below.
    let arts = registeredArtifacts("ncursesSource")
    check arts.len == 4
    var seenLibNcursesw = false
    var seenLibTinfow = false
    var seenTic = false
    var seenInfocmp = false
    for art in arts:
      check art.packageName == "ncursesSource"
      case art.artifactName
      of "libNcursesw":
        seenLibNcursesw = true
        check art.kind == dakLibrary
      of "libTinfow":
        seenLibTinfow = true
        check art.kind == dakLibrary
      of "tic":
        seenTic = true
        check art.kind == dakExecutable
      of "infocmp":
        seenInfocmp = true
        check art.kind == dakExecutable
      else:
        discard
    check seenLibNcursesw
    check seenLibTinfow
    check seenTic
    check seenInfocmp

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical github.com mirror that hosts the ncurses source tree.
    let vs = registeredVersions("ncursesSource")
    check vs.len == 1
    check vs[0].version == "6.5"
    check vs[0].sourceRevision == "v6.5"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/mirror/ncurses.git"
