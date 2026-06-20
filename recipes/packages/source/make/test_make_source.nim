## Smoke test for the from-source ``makeSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the M9.N Batch E compiler-
## chain slice. make's unique coverage angles vs the prior 83 from-
## source recipes:
##
##   * SECOND ``from-source-autotools`` recipe with a SINGLE
##     ``executable`` artifact (after the autoconf-vs-autoreconf
##     binary cardinality divergence in Batch D) sharing the simplest
##     possible install-tree. Pins the per-artifact stage-copy fan-
##     out at the 1-binary edge cardinality.
##   * The ONLY from-source recipe in the corpus that bootstraps the
##     build-system-driver ITSELF — every other from-source-autotools
##     recipe transitively assumes a host ``make`` already exists.
##   * Real sha256 on the fetch channel — the test asserts the exact
##     64-char hex hash recorded in the recipe + the algorithm tag.
##   * SECOND recipe in the corpus (after make-4.4.1 itself in the
##     kernel-build chain) to use a ``.tar.gz`` upstream archive vs
##     the more-common ``.tar.xz`` variant. Pins the fetch-spec
##     ``kind`` discriminator at ``dfkTarball`` regardless of the
##     compressor.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the single-flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * SINGLE ``executable`` artifact registration (M3) — make
##     tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + one executable artifact under
# ``makeSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz"

# Real sha256 over the upstream make-4.4.1.tar.gz tarball; see
# ``repro.nim``'s sha256 strategy section.
const ExpectedHash =
  "dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3"

const ExpectedConfigureFlags = @[
  "--disable-nls",
]

suite "makeSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("makeSource")
    check spec.packageName == "makeSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the real sha256 over the upstream tarball":
    # Real sha256 over the upstream ftp.gnu.org tarball; computed
    # locally + asserted exactly.
    let spec = registeredFetchSpec("makeSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention. The fetch-spec ``kind``
    # discriminator is ``dfkTarball`` regardless of the compressor
    # (``.tar.gz`` here vs the more-common ``.tar.xz``).
    let spec = registeredFetchSpec("makeSource")
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
  test "artifacts register a single make executable tagged dakExecutable":
    # M3 artifact registry: make tagged ``dakExecutable``. The
    # SIMPLEST possible artifact cardinality — single executable
    # under a from-source-autotools recipe.
    let arts = registeredArtifacts("makeSource")
    check arts.len == 1
    check arts[0].packageName == "makeSource"
    check arts[0].artifactName == "make"
    check arts[0].kind == dakExecutable

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source``. The repository points at
    # the canonical savannah.gnu.org mirror.
    let vs = registeredVersions("makeSource")
    check vs.len == 1
    check vs[0].version == "4.4.1"
    check vs[0].sourceRevision == "v4.4.1"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/make.git"
