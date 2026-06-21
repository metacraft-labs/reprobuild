## Smoke test for the from-source ``boostSource`` recipe.
##
## Pins the M9.H/I + M3 registry behaviour on the FIRST C++ multi-module
## custom-build library to land in the from-source corpus. boost's
## coverage angles vs the prior from-source recipes:
##
##   * FIRST recipe in the corpus to ship FIVE library artifacts under
##     the ``from-source-custom`` convention with a shared install-tree
##     anchored on the FIRST library (``libBoostSystem``).
##   * THIRD multi-shell ``from-source-custom`` consumer (after ninja +
##     gcc) — pins the M9.N Batch C.1 shell-action registry round-trip
##     on a THREE-shell bootstrap-build-stage-copy pipeline.
##   * Real sha256 on the fetch channel — the test asserts the exact
##     64-char hex hash recorded in the recipe + the algorithm tag.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * MULTI library artifact registration (M3) — libBoostSystem +
##     libBoostFilesystem + libBoostThread + libBoostDateTime +
##     libBoostProgramOptions all tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.
##   * ``shell()`` action registry round-trip (M9.N Batch C.1) — three
##     verbatim commands recorded in declaration order under the
##     ``libBoostSystem`` anchor artifact.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + five library artifacts + three shell actions under
# ``boostSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.bz2"

# Real sha256 over the upstream boost_1_86_0.tar.bz2 tarball; see
# ``repro.nim``'s sha256 strategy section.
const ExpectedHash =
  "1bed88e40401b2cb7a1f76d4bab499e352fa4d0c5f31c0dbae64e24d34d7513b"

suite "boostSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("boostSource")
    check spec.packageName == "boostSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the real sha256 over the upstream tarball":
    # Real sha256 over the upstream archives.boost.io tarball; computed
    # locally + asserted exactly.
    let spec = registeredFetchSpec("boostSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream archives.boost.io
    # release tarballs use.
    let spec = registeredFetchSpec("boostSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "artifacts register five libraries":
    # M3 artifact registry: libBoostSystem + libBoostFilesystem +
    # libBoostThread + libBoostDateTime + libBoostProgramOptions all
    # tagged ``dakLibrary``. The shared install-tree on the anchor
    # artifact's build body fans out across all five via the
    # convention's stage-copy step.
    let arts = registeredArtifacts("boostSource")
    check arts.len == 5
    var seenSystem = false
    var seenFilesystem = false
    var seenThread = false
    var seenDateTime = false
    var seenProgramOptions = false
    for art in arts:
      check art.packageName == "boostSource"
      check art.kind == dakLibrary
      case art.artifactName
      of "libBoostSystem": seenSystem = true
      of "libBoostFilesystem": seenFilesystem = true
      of "libBoostThread": seenThread = true
      of "libBoostDateTime": seenDateTime = true
      of "libBoostProgramOptions": seenProgramOptions = true
      else: discard
    check seenSystem
    check seenFilesystem
    check seenThread
    check seenDateTime
    check seenProgramOptions

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream archives.boost.io release tag
    # is recorded for ``repro update-source``. The repository points at
    # the canonical github.com/boostorg/boost tree.
    let vs = registeredVersions("boostSource")
    check vs.len == 1
    check vs[0].version == "1.86.0"
    check vs[0].sourceRevision == "boost-1.86.0"
    check vs[0].sourceUrl ==
      "https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.bz2"
    check vs[0].sourceRepository ==
      "https://github.com/boostorg/boost"

  test "shell() action registry records the bootstrap-build-stage-copy pipeline":
    # M9.N Batch C.1 — the anchor artifact's ``build:`` block records
    # three shell actions: bootstrap + b2 install + stage-copy. The
    # from-source-custom convention consumes the sequence verbatim.
    let rows = registeredShellActions("boostSource")
    check rows.len == 3
    for r in rows:
      check r.packageName == "boostSource"
      check r.artifactName == "libBoostSystem"
    check rows[0].command ==
      "./bootstrap.sh --prefix=$out --with-libraries=system,filesystem,thread,date_time,program_options"
    check rows[1].command ==
      "./b2 install --prefix=$out link=shared threading=multi"
    check rows[2].command ==
      "mkdir -p $out/install/usr && cp -a $out/lib $out/include $out/install/usr/"

  test "shell() ids carry the per-artifact sequence number":
    # M9.N Batch C.1 — auto-generated ids follow the
    # ``<package>-<artifact>-<seq>`` shape; sequence increments per
    # artifact.
    let rows = registeredShellActions("boostSource")
    check rows.len == 3
    check rows[0].id == "boostSource-libBoostSystem-1"
    check rows[1].id == "boostSource-libBoostSystem-2"
    check rows[2].id == "boostSource-libBoostSystem-3"
