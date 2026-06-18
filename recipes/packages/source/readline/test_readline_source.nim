## Smoke test for the from-source ``readlineSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTY-FOURTH real
## production from-source recipe. readline's unique coverage angle vs
## the prior sixty-three is being the canonical line-editing library
## paired with bash + gdb + every interactive CLI, plus a TWO-library
## autotools shape (``libreadline`` + ``libhistory``) — the prior
## two-library autotools precedents (nettle's ``libnettle`` +
## ``libhogweed``; ncurses's ``libNcursesw`` + ``libTinfow``) used
## different upstream SONAME pairings, and readline's pair pins the
## paired-history-library convention.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the two-flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * TWO-library artifact registration (M3) — ``libReadline`` +
##     ``libHistory`` both tagged ``dakLibrary``, kind discriminator
##     preserved per-artifact.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + two library artifacts under
# ``readlineSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/readline/vendor/readline-8.2.tar.gz"

const ExpectedHash =
  "3feb7171f16a84ee82ca18a36d7b9be109a52c04f492a5f6d5fd58b2f2c5f4ec"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--enable-shared",
]

suite "readlineSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("readlineSource")
    check spec.packageName == "readlineSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 3,043,945-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("readlineSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream release tarballs use.
    let spec = registeredFetchSpec("readlineSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the configure channel — the
    # TWO-flag cardinality pins the autotools ``--disable-X`` /
    # ``--enable-X`` polarity pair convention against a regression
    # that collapses the two into a single flag.
    let flags = registeredBuildFlags("readlineSource", "", "configure")
    check flags == ExpectedConfigureFlags
    check flags.len == 2

  test "configureFlags does not leak into the meson channel":
    # Cross-channel isolation — guards against a regression that
    # flattens the registries.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("readlineSource", "", "meson") == emptyStrSeq

  test "configureFlags does not leak into the cmake channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the autotools + CMake channels.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("readlineSource", "", "cmake") == emptyStrSeq

  test "configureFlags does not leak into the make channel":
    # Cross-channel isolation #3 — guards against a regression that
    # merges autotools ``configure`` flags onto the raw-Makefile
    # ``make`` channel.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("readlineSource", "", "make") == emptyStrSeq

  test "artifacts register two libraries tagged dakLibrary":
    # M3 artifact registry: ``libReadline`` + ``libHistory`` BOTH
    # tagged ``dakLibrary``. The unique coverage of THIS recipe vs the
    # prior two-library autotools precedents (nettle's ``libnettle`` +
    # ``libhogweed``; ncurses's ``libNcursesw`` + ``libTinfow``) is
    # the canonical ``libreadline`` + ``libhistory`` SONAME pair —
    # readline-binding consumers (bash, gdb) link against both, but a
    # regression that collapsed the artifact-name partitioning at the
    # two-of-a-kind cardinality would surface as either a missing
    # entry or one entry shadowing the other.
    let arts = registeredArtifacts("readlineSource")
    check arts.len == 2
    var seenReadline = false
    var seenHistory = false
    for art in arts:
      check art.packageName == "readlineSource"
      check art.kind == dakLibrary
      case art.artifactName
      of "libReadline":
        seenReadline = true
      of "libHistory":
        seenHistory = true
      else:
        discard
    check seenReadline
    check seenHistory

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # savannah.gnu.org git mirror that hosts the readline source tree.
    let vs = registeredVersions("readlineSource")
    check vs.len == 1
    check vs[0].version == "8.2"
    check vs[0].sourceRevision == "readline-8.2"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/readline/readline-8.2.tar.gz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/readline.git"
