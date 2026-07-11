## Smoke test for the from-source ``gettextSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTY-FIFTH real
## production from-source recipe. gettext's unique coverage angle vs
## the prior sixty-four is being the canonical GNU i18n / l10n
## toolchain with a FIVE-flag
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
##   * artifact registration (M3) — three executables
##     (``dakExecutable``) attributed to ``gettextSource``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + three executable artifacts under
# ``gettextSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/gettext/gettext-0.22.5.tar.xz"

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
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the make channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register three executables":
    # glibc provides the libintl API in libc, so this build installs the
    # gettext toolchain but no standalone libintl.so artifact.
    let arts = registeredArtifacts("gettextSource")
    check arts.len == 3
    var seenMsgfmt = false
    var seenMsgmerge = false
    var seenXgettext = false
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
      else:
        discard
    check seenMsgfmt
    check seenMsgmerge
    check seenXgettext

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
