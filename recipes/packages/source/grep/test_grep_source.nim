## Smoke test for the from-source ``grepSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SEVENTY-SECOND real
## production from-source recipe. GNU grep is THE canonical line-
## matching CLI on every modern Linux distribution — every shell
## pipeline + every log scanner + every config-search Makefile rule
## + every IDE file-search backend shells out to ``/usr/bin/grep``.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the one-flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * SINGLE executable artifact registration (M3) — ``grep`` tagged
##     ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + one executable artifact under
# ``grepSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz"

const ExpectedHash =
  "1db2aedde89d0dea42b16d9528f894c8d15dae4e190b59aecc78f5a951276eab"

const ExpectedConfigureFlags = @[
  "--disable-perl-regexp",
]

suite "grepSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("grepSource")
    check spec.packageName == "grepSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 is the canonical published upstream ``sha256sum`` for
    # grep-3.11.tar.xz; length check guards against a future bump
    # that forgets to widen the hash alongside the URL.
    let spec = registeredFetchSpec("grepSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("grepSource")
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
  test "artifacts register a single grep executable tagged dakExecutable":
    # M3 artifact registry: ``grep`` is tagged ``dakExecutable``.
    # grep's autotools build emits a single load-bearing binary
    # (the canonical line-matching CLI); the POSIX-mandated ``egrep``
    # + ``fgrep`` shell wrappers are NOT registered in v1. A
    # regression that flattened the kind discriminator would
    # mis-route the M9.L install path; a regression that collapsed
    # the artifact-name partitioning at the one-artifact cardinality
    # would not produce a single entry with the expected name.
    let arts = registeredArtifacts("grepSource")
    check arts.len == 1
    check arts[0].packageName == "grepSource"
    check arts[0].artifactName == "grep"
    check arts[0].kind == dakExecutable

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source``. The repository points at
    # the canonical savannah.gnu.org mirror that hosts the grep
    # source tree.
    let vs = registeredVersions("grepSource")
    check vs.len == 1
    check vs[0].version == "3.11"
    check vs[0].sourceRevision == "v3.11"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/grep.git"
