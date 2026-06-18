## Smoke test for the from-source ``cmakeSource`` recipe.
##
## Pins the M9.H/I + M3 registry behaviour on the M9.N Batch D
## build-tool slice. cmake's unique coverage angles vs the prior 76
## from-source recipes:
##
##   * FIRST recipe in the corpus to declare THREE ``executable``
##     artifacts sharing a single ``./bootstrap && make && make
##     install`` install-tree (cmake + ctest + cpack). Pins the
##     ``from-source-custom`` convention's per-artifact stage-copy
##     fan-out from a multi-binary install-tree.
##   * SECOND ``from-source-custom`` consumer with a multi-shell
##     ``build:`` block (vs ``mesonSource``'s four-shell install body)
##     — pins the M9.N Batch C.1 shell-action registry round-trip on a
##     bootstrap-build-install pipeline.
##   * Real sha256 on the fetch channel — the test asserts the exact
##     64-char hex hash recorded in the recipe + the algorithm tag.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * No-flags state on ALL FOUR build channels (M9.I) — configure +
##     meson + cmake + make all empty.
##   * THREE ``executable`` artifact registration (M3) — cmake +
##     ctest + cpack all tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.
##   * ``shell()`` action registry round-trip (M9.N Batch C.1) — three
##     verbatim commands recorded in declaration order under the
##     ``cmake`` artifact.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + three executable artifacts + three shell actions
# under ``cmakeSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://github.com/Kitware/CMake/releases/download/v3.31.2/cmake-3.31.2.tar.gz"

# Real sha256 over the upstream cmake-3.31.2.tar.gz tarball; see
# ``repro.nim``'s sha256 strategy section.
const ExpectedHash =
  "42abb3f48f37dbd739cdfeb19d3712db0c5935ed5c2aef6c340f9ae9114238a2"

suite "cmakeSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("cmakeSource")
    check spec.packageName == "cmakeSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the real sha256 over the upstream tarball":
    # Real sha256 over the upstream GitHub release tarball; computed
    # locally + asserted exactly.
    let spec = registeredFetchSpec("cmakeSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub release
    # tarballs use.
    let spec = registeredFetchSpec("cmakeSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "no flags registered on the configure channel":
    # M9.I cross-channel registry empty-state — cmake's upstream
    # bootstrap path takes no ``./configure`` flags (the recipe drives
    # ``./bootstrap`` + ``make`` + ``make install`` directly via the
    # from-source-custom shell-action pipeline).
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("cmakeSource", "", "configure") == emptyStrSeq

  test "no flags registered on the meson channel":
    # M9.I cross-channel registry empty-state #2.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("cmakeSource", "", "meson") == emptyStrSeq

  test "no flags registered on the cmake channel":
    # M9.I cross-channel registry empty-state #3 — cmake channel is
    # empty (we are not bootstrapping cmake via cmake, that would be
    # the chicken-and-egg).
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("cmakeSource", "", "cmake") == emptyStrSeq

  test "no flags registered on the make channel":
    # M9.I cross-channel registry empty-state #4 — the make channel
    # is empty because the from-source-custom pipeline records the
    # ``make`` invocation as a shell action, not as a flag-block
    # entry.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("cmakeSource", "", "make") == emptyStrSeq

  test "artifacts register three executables all tagged dakExecutable":
    # M3 artifact registry: cmake + ctest + cpack are all tagged
    # ``dakExecutable``. cmake's bootstrap-build-install pipeline
    # emits all three binaries from a single ``make install`` step;
    # a regression that mis-tagged any of the three would mis-route
    # the from-source-custom stage-copy step (which probes
    # ``$out/bin/<member>`` per executable artifact).
    let arts = registeredArtifacts("cmakeSource")
    check arts.len == 3
    var seenCmake = false
    var seenCtest = false
    var seenCpack = false
    for art in arts:
      check art.packageName == "cmakeSource"
      check art.kind == dakExecutable
      case art.artifactName
      of "cmake":
        seenCmake = true
      of "ctest":
        seenCtest = true
      of "cpack":
        seenCpack = true
      else:
        discard
    check seenCmake
    check seenCtest
    check seenCpack

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is
    # recorded for ``repro update-source``. The repository points at
    # the canonical github.com project that hosts the cmake source
    # tree.
    let vs = registeredVersions("cmakeSource")
    check vs.len == 1
    check vs[0].version == "3.31.2"
    check vs[0].sourceRevision == "v3.31.2"
    check vs[0].sourceUrl ==
      "https://github.com/Kitware/CMake/releases/download/v3.31.2/cmake-3.31.2.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/Kitware/CMake"

  test "shell() action registry records the cmake bootstrap pipeline":
    # M9.N Batch C.1 — the recipe's ``build:`` block records three
    # shell actions: ``./bootstrap --prefix=$out -- -DCMAKE_USE_OPENSSL=OFF``
    # followed by ``make`` followed by ``make install``. The from-
    # source-custom convention consumes the sequence verbatim;
    # ``$out`` is resolved to the per-package output dir at emit
    # time.
    let rows = registeredShellActions("cmakeSource")
    check rows.len == 3
    for r in rows:
      check r.packageName == "cmakeSource"
      check r.artifactName == "cmake"
    check rows[0].command == "./bootstrap --prefix=$out -- -DCMAKE_USE_OPENSSL=OFF"
    check rows[1].command == "make"
    check rows[2].command == "make install"

  test "shell() ids carry the per-artifact sequence number":
    # M9.N Batch C.1 — auto-generated ids follow the
    # ``<package>-<artifact>-<seq>`` shape; sequence increments per
    # artifact.
    let rows = registeredShellActions("cmakeSource")
    check rows.len == 3
    check rows[0].id == "cmakeSource-cmake-1"
    check rows[1].id == "cmakeSource-cmake-2"
    check rows[2].id == "cmakeSource-cmake-3"
