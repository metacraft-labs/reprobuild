## Smoke test for the from-source ``lessSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTIETH real production
## from-source recipe. less's unique coverage angle vs the prior
## fifty-nine is being THE canonical Unix pager + a SINGLE-flag
## ``configureFlags:`` block — the smallest configure-channel
## cardinality in the corpus so far, pinning the M9.I block parser's
## one-flag path against potential off-by-one regressions.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the single-flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * SINGLE executable artifact registration (M3) — ``less`` tagged
##     ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + one executable artifact under
# ``lessSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/less/vendor/less-668.tar.gz"

const ExpectedHash =
  "2819f55564d86d542abbecafd82ff61e819a3eec967faa36cd3e68f1596a44b8"

const ExpectedConfigureFlags = @[
  "--with-regex=posix",
]

suite "lessSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("lessSource")
    check spec.packageName == "lessSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 649,770-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("lessSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream release tarballs
    # use.
    let spec = registeredFetchSpec("lessSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the configure channel — the
    # SINGLE-flag cardinality is the smallest in the source-recipe
    # corpus so far and a regression that off-by-ones the M9.I block
    # parser at the one-flag boundary would surface here as either an
    # empty seq or a seq with the flag inadvertently dropped /
    # duplicated.
    let flags = registeredBuildFlags("lessSource", "", "configure")
    check flags == ExpectedConfigureFlags
    check flags.len == 1

  test "configureFlags does not leak into the meson channel":
    # Cross-channel isolation — guards against a regression that
    # flattens the registries.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("lessSource", "", "meson") == emptyStrSeq

  test "configureFlags does not leak into the cmake channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the autotools + CMake channels.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("lessSource", "", "cmake") == emptyStrSeq

  test "configureFlags does not leak into the make channel":
    # Cross-channel isolation #3 — guards against a regression that
    # merges autotools ``configure`` flags onto the raw-Makefile
    # ``make`` channel.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("lessSource", "", "make") == emptyStrSeq

  test "artifacts register a single less executable tagged dakExecutable":
    # M3 artifact registry: ``less`` is tagged ``dakExecutable``.
    # less's autotools build emits a single load-bearing binary (the
    # pager); auxiliary ``lessecho`` + ``lesskey`` helpers are NOT
    # registered in v1. A regression that flattened the kind
    # discriminator would mis-route the M9.L install path; a
    # regression that collapsed the artifact-name partitioning at the
    # one-artifact cardinality would not produce a single entry with
    # the expected name.
    let arts = registeredArtifacts("lessSource")
    check arts.len == 1
    check arts[0].packageName == "lessSource"
    check arts[0].artifactName == "less"
    check arts[0].kind == dakExecutable

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream greenwoodsoftware.com release
    # tag is recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at the
    # github.com mirror where the upstream maintainer publishes the
    # less source tree (greenwoodsoftware.com only hosts tarballs).
    let vs = registeredVersions("lessSource")
    check vs.len == 1
    check vs[0].version == "668"
    check vs[0].sourceRevision == "v668"
    check vs[0].sourceUrl ==
      "https://www.greenwoodsoftware.com/less/less-668.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/gwsw/less.git"
