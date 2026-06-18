## Smoke test for the from-source ``gccSource`` recipe.
##
## Pins the M9.H/I + M3 registry behaviour on the M9.N Batch E
## compiler-chain slice. gcc's unique coverage angles vs the prior 81
## from-source recipes:
##
##   * FIRST recipe in the corpus to declare MIXED-KIND artifacts
##     under the ``from-source-custom`` convention (three
##     ``executable`` + two ``library`` sharing a single
##     ``mkdir-configure-build-install`` install-tree). Pins the
##     per-artifact stage-copy fan-out at the (3 exec, 2 lib) mixed
##     cardinality from a multi-shell custom pipeline.
##   * SECOND multi-shell ``from-source-custom`` consumer with a
##     FOUR-shell ``build:`` block (vs cmake's three-shell
##     bootstrap-build-install pipeline) — pins the M9.N Batch C.1
##     shell-action registry round-trip on the gcc out-of-tree
##     pattern (``mkdir`` + out-of-tree ``configure`` + ``make`` +
##     ``make install``).
##   * Real sha256 on the fetch channel — the test asserts the exact
##     64-char hex hash recorded in the recipe + the algorithm tag.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * No-flags state on ALL FOUR build channels (M9.I) — configure +
##     meson + cmake + make all empty (gcc's from-source-custom
##     pipeline records the configure invocation as a shell action,
##     not as a flag-block entry).
##   * MIXED-KIND artifact registration (M3) — gcc + g++ + cpp
##     tagged ``dakExecutable``, libgcc_s + libstdc++ tagged
##     ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.
##   * ``shell()`` action registry round-trip (M9.N Batch C.1) — four
##     verbatim commands recorded in declaration order under the
##     ``gcc`` artifact.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + three executable + two library artifacts + four shell
# actions under ``gccSource`` at module init time.
import ./repro

const ExpectedUrl =
  "https://ftp.gnu.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz"

# Real sha256 over the upstream gcc-14.2.0.tar.xz tarball; see
# ``repro.nim``'s sha256 strategy section.
const ExpectedHash =
  "a7b39bc69cbf9e25826c5a60ab26477001f7c08d85cec04bc0e29cabed6f3cc9"

suite "gccSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("gccSource")
    check spec.packageName == "gccSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is the real sha256 over the upstream tarball":
    # Real sha256 over the upstream ftp.gnu.org tarball; computed
    # locally + asserted exactly.
    let spec = registeredFetchSpec("gccSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("gccSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "no flags registered on the configure channel":
    # M9.I cross-channel registry empty-state — gcc's from-source-
    # custom pipeline records the configure invocation as a shell
    # action, not as a flag-block entry.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("gccSource", "", "configure") == emptyStrSeq

  test "no flags registered on the meson channel":
    # M9.I cross-channel registry empty-state #2.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("gccSource", "", "meson") == emptyStrSeq

  test "no flags registered on the cmake channel":
    # M9.I cross-channel registry empty-state #3.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("gccSource", "", "cmake") == emptyStrSeq

  test "no flags registered on the make channel":
    # M9.I cross-channel registry empty-state #4 — the make channel
    # is empty because the from-source-custom pipeline records the
    # ``make`` invocation as a shell action, not as a flag-block
    # entry.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("gccSource", "", "make") == emptyStrSeq

  test "artifacts register three executables + two libraries mixed-kind":
    # M3 artifact registry: gcc + g++ + cpp tagged
    # ``dakExecutable``; libgcc_s + libstdc++ tagged ``dakLibrary``.
    # A regression that flattened the kind discriminator at the
    # (3, 2) mixed cardinality would surface here (mis-routing the
    # M9.L install path: ``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("gccSource")
    check arts.len == 5
    var seenGcc = false
    var seenGxx = false
    var seenCpp = false
    var seenLibgccS = false
    var seenLibstdcxx = false
    for art in arts:
      check art.packageName == "gccSource"
      case art.artifactName
      of "gcc":
        seenGcc = true
        check art.kind == dakExecutable
      of "g++":
        seenGxx = true
        check art.kind == dakExecutable
      of "cpp":
        seenCpp = true
        check art.kind == dakExecutable
      of "libgcc_s":
        seenLibgccS = true
        check art.kind == dakLibrary
      of "libstdc++":
        seenLibstdcxx = true
        check art.kind == dakLibrary
      else:
        discard
    check seenGcc
    check seenGxx
    check seenCpp
    check seenLibgccS
    check seenLibstdcxx

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source``. The repository points at
    # the canonical gcc.gnu.org git tree.
    let vs = registeredVersions("gccSource")
    check vs.len == 1
    check vs[0].version == "14.2.0"
    check vs[0].sourceRevision == "releases/gcc-14.2.0"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://gcc.gnu.org/git/gcc.git"

  test "shell() action registry records the gcc mkdir-configure-build-install pipeline":
    # M9.N Batch C.1 — the recipe's ``build:`` block records four
    # shell actions: ``mkdir -p $extracted/build`` + out-of-tree
    # configure + build + install. The from-source-custom convention
    # consumes the sequence verbatim.
    let rows = registeredShellActions("gccSource")
    check rows.len == 4
    for r in rows:
      check r.packageName == "gccSource"
      check r.artifactName == "gcc"
    check rows[0].command == "mkdir -p $extracted/build"
    check rows[1].command ==
      "cd $extracted/build && ../configure --prefix=$out --enable-languages=c,c++ --disable-multilib --disable-bootstrap --disable-nls --without-headers"
    check rows[2].command == "cd $extracted/build && make"
    check rows[3].command == "cd $extracted/build && make install"

  test "shell() ids carry the per-artifact sequence number":
    # M9.N Batch C.1 — auto-generated ids follow the
    # ``<package>-<artifact>-<seq>`` shape; sequence increments per
    # artifact.
    let rows = registeredShellActions("gccSource")
    check rows.len == 4
    check rows[0].id == "gccSource-gcc-1"
    check rows[1].id == "gccSource-gcc-2"
    check rows[2].id == "gccSource-gcc-3"
    check rows[3].id == "gccSource-gcc-4"
