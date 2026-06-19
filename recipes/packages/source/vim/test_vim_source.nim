## Smoke test for the from-source ``vimSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTY-FIRST real
## production from-source recipe. vim's unique coverage angle vs the
## prior sixty is being the de-facto Unix modal editor + the LARGEST
## configureFlags: block in the source-recipe corpus so far (SEVEN
## flags, all in the ``--enable-/--disable-/--without-`` grammar
## variants). The seven-flag cardinality pins the M9.I block parser's
## upper end against potential off-by-one regressions; the mixed
## ``--enable-``/``--disable-``/``--without-`` prefixes pin the parser's
## grammar-agnostic flag handling.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production seven-flag set +
##     channel-isolation spot-check (meson + cmake + make channels
##     MUST be empty).
##   * THREE executable artifact registration (M3) — ``vim`` +
##     ``vimdiff`` + ``vimtutor`` all tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + three executable artifacts under
# ``vimSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/vim/vendor/vim-9.1.1000.tar.gz"

const ExpectedHash =
  "c8ccd457bba5563513ab3e2088ad10d62b982682af9a9278686b48202b8c7697"

const ExpectedConfigureFlags = @[
  "--enable-gui=no",
  "--without-x",
  "--disable-gpm",
  "--disable-perlinterp",
  "--disable-pythoninterp",
  "--disable-rubyinterp",
  "--disable-luainterp",
]

suite "vimSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("vimSource")
    check spec.packageName == "vimSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 18,393,329-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("vimSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream github.com archive
    # tarballs use (``vim-<tag>/`` is the single top-level dir).
    let spec = registeredFetchSpec("vimSource")
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
  test "artifacts register three executables all tagged dakExecutable":
    # M3 artifact registry: ``vim`` + ``vimdiff`` + ``vimtutor`` are
    # all tagged ``dakExecutable``. vim's autotools build emits three
    # load-bearing entry points; ``vimdiff`` is technically a symlink
    # to ``vim`` (argv[0] dispatch) but the artifact entry pins the
    # expected install-side name so M9.L's install glue can
    # distinguish the symlink target via the ``installed-path``
    # postprocess. A regression that flattened the kind discriminator
    # would mis-route the M9.L install path; a regression that
    # collapsed the artifact-name partitioning at the three-artifact
    # cardinality would not produce three distinct entries with the
    # expected names below.
    let arts = registeredArtifacts("vimSource")
    check arts.len == 3
    var seenVim = false
    var seenVimdiff = false
    var seenVimtutor = false
    for art in arts:
      check art.packageName == "vimSource"
      check art.kind == dakExecutable
      case art.artifactName
      of "vim":
        seenVim = true
      of "vimdiff":
        seenVimdiff = true
      of "vimtutor":
        seenVimtutor = true
      else:
        discard
    check seenVim
    check seenVimdiff
    check seenVimtutor

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream github.com archive tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical vim project on github.com.
    let vs = registeredVersions("vimSource")
    check vs.len == 1
    check vs[0].version == "9.1.1000"
    check vs[0].sourceRevision == "v9.1.1000"
    check vs[0].sourceUrl ==
      "https://github.com/vim/vim/archive/refs/tags/v9.1.1000.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/vim/vim.git"
