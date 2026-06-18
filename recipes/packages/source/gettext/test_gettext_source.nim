## Smoke test for the from-source ``gettextSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTY-FIFTH real
## production from-source recipe. gettext's unique coverage angle vs
## the prior sixty-four is being the canonical GNU i18n / l10n
## toolchain + the FIRST source recipe in the corpus with a
## THREE-executable + ONE-library mixed-kind autotools shape (prior
## precedents capped at two-of-each), with a FIVE-flag
## ``configureFlags:`` block exercising the mixed ``--disable-*`` /
## ``--without-*`` polarity convention.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the five-flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * MIXED artifact registration (M3) — three executables
##     (``dakExecutable``) + one library (``dakLibrary``) attributed
##     to ``gettextSource`` with kind discriminators preserved
##     per-artifact (unique coverage angle vs prior mixed-kind
##     autotools recipes).
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + three executable + one library
# artifacts under ``gettextSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/gettext/vendor/gettext-0.22.5.tar.xz"

const ExpectedHash =
  "fe10c37353213d78a5b83d48af231e005c4da84db5ce88037d88355938259640"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-java",
  "--disable-csharp",
  "--without-emacs",
  "--without-included-libintl",
]

suite "gettextSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("gettextSource")
    check spec.packageName == "gettextSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 10,329,748-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("gettextSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream release tarballs use.
    let spec = registeredFetchSpec("gettextSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the configure channel — the
    # FIVE-flag cardinality with mixed ``--disable-*`` /
    # ``--without-*`` polarity pins the parser's grammar-agnostic flag
    # handling against a regression that conflated the two flavours
    # (which would surface either as a flag-grammar error at configure
    # time or as a silent feature-flip).
    let flags = registeredBuildFlags("gettextSource", "", "configure")
    check flags == ExpectedConfigureFlags
    check flags.len == 5

  test "configureFlags does not leak into the meson channel":
    # Cross-channel isolation — guards against a regression that
    # flattens the registries.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("gettextSource", "", "meson") == emptyStrSeq

  test "configureFlags does not leak into the cmake channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the autotools + CMake channels.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("gettextSource", "", "cmake") == emptyStrSeq

  test "configureFlags does not leak into the make channel":
    # Cross-channel isolation #3 — guards against a regression that
    # merges autotools ``configure`` flags onto the raw-Makefile
    # ``make`` channel.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("gettextSource", "", "make") == emptyStrSeq

  test "artifacts register three executables + one library":
    # M3 artifact registry: ``msgfmt`` / ``msgmerge`` / ``xgettext``
    # all tagged ``dakExecutable`` while ``libIntl`` is tagged
    # ``dakLibrary``. The unique coverage of THIS recipe vs the prior
    # mixed-kind autotools precedents (xz at one-of-each; util-linux /
    # coreutils at varying executable cardinalities; ncurses at
    # two-libs + two-execs) is the THREE-executable + ONE-library
    # asymmetric balance — a regression that flattened the kind
    # discriminator or collapsed any of the four artifact-name
    # partitions would surface as either a missing entry, a wrong
    # ``kind`` tag, or a duplicated entry shadowing one of the others.
    let arts = registeredArtifacts("gettextSource")
    check arts.len == 4
    var seenMsgfmt = false
    var seenMsgmerge = false
    var seenXgettext = false
    var seenIntl = false
    for art in arts:
      check art.packageName == "gettextSource"
      case art.artifactName
      of "msgfmt":
        seenMsgfmt = true
        check art.kind == dakExecutable
      of "msgmerge":
        seenMsgmerge = true
        check art.kind == dakExecutable
      of "xgettext":
        seenXgettext = true
        check art.kind == dakExecutable
      of "libIntl":
        seenIntl = true
        check art.kind == dakLibrary
      else:
        discard
    check seenMsgfmt
    check seenMsgmerge
    check seenXgettext
    check seenIntl

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # savannah.gnu.org git mirror that hosts the gettext source tree.
    let vs = registeredVersions("gettextSource")
    check vs.len == 1
    check vs[0].version == "0.22.5"
    check vs[0].sourceRevision == "v0.22.5"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/gettext/gettext-0.22.5.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/gettext.git"
