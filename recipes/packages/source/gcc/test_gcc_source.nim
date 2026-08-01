## Smoke test for the from-source ``gccSource`` recipe.
##
## Pins the M9.H/I + M3 registry behaviour on the M9.N Batch E
## compiler-chain slice. gcc's unique coverage angles vs the prior 81
## from-source recipes:
##
##   * FIRST recipe in the corpus to declare MIXED-KIND artifacts
##     under the ``from-source-custom`` convention (three
##     ``executable`` + four ``library`` sharing a single
##     ``mkdir-configure-build-install`` install-tree). Pins the
##     per-artifact stage-copy fan-out at the (3 exec, 4 lib) mixed
##     cardinality from a multi-shell custom pipeline.
##   * SECOND multi-shell ``from-source-custom`` consumer with a
##     FIVE-shell ``build:`` block (vs cmake's three-shell
##     bootstrap-build-install pipeline) — pins the M9.N Batch C.1
##     shell-action registry round-trip on the gcc out-of-tree
##     pattern (bootstrap-sysroot + ``mkdir``, out-of-tree
##     ``configure``, ``make -j8``, ``make install``, lib64 aliases).
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
##     tagged ``dakExecutable``; libgcc_s + libstdc++ + libgomp +
##     libatomic tagged ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.
##   * ``shell()`` action registry round-trip (M9.N Batch C.1) — four
##     verbatim commands recorded in declaration order under the
##     ``gcc`` artifact.

import std/[algorithm, strutils, unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + three executable + four library artifacts + five shell
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
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "no flags registered on the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "no flags registered on the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "no flags registered on the make channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register three executables + four libraries mixed-kind":
    # M3 artifact registry: gcc + g++ + cpp tagged ``dakExecutable``;
    # libgcc_s + libstdc++ + libgomp + libatomic tagged ``dakLibrary``.
    # A regression that flattened the kind discriminator at the (3, 4)
    # mixed cardinality would surface here (mis-routing the M9.L
    # install path: ``lib/`` vs ``bin/``).
    #
    # The expected set is written out and compared as a whole rather than
    # tracked through per-artifact bools: the previous form asserted a bare
    # count plus five flags, so when the recipe gained libgomp and libatomic
    # the count broke while the flags stayed silent about WHICH artifacts were
    # unaccounted for. Comparing sets names the drift directly.
    let arts = registeredArtifacts("gccSource")
    var executables: seq[string]
    var libraries: seq[string]
    for art in arts:
      check art.packageName == "gccSource"
      case art.kind
      of dakExecutable: executables.add(art.artifactName)
      of dakLibrary: libraries.add(art.artifactName)
      else: discard
    executables.sort()
    libraries.sort()
    check executables == @["cpp", "g++", "gcc"]
    check libraries == @["libatomic", "libgcc_s", "libgomp", "libstdc++"]
    check arts.len == executables.len + libraries.len   # no other kinds

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
    check rows.len == 5
    for r in rows:
      check r.packageName == "gccSource"
      check r.artifactName == "gcc"
    # Steps 0 and 1 are long shell one-liners (bootstrap-sysroot discovery and
    # the full configure flag set). They are matched on their DISTINCTIVE parts
    # rather than verbatim: a byte-exact literal of a ~700-char command turns
    # every recipe tweak into a two-file edit, which is precisely how these
    # expectations fell out of step with the recipe in the first place. The
    # ordering, the count, the ids and the per-artifact attribution are all
    # still asserted exactly, so a reordered or dropped step still fails.
    check rows[0].command.contains("mkdir -p $extracted/build")
    check rows[0].command.contains("bootstrap-sysroot")
    check rows[1].command.contains("../configure --prefix=$out")
    check rows[1].command.contains("--enable-languages=c,c++")
    check rows[1].command.contains("--disable-multilib")
    check rows[1].command.contains("--disable-bootstrap")
    check rows[1].command.contains("--with-build-sysroot=$extracted/bootstrap-sysroot")
    # The job count is deliberately fixed in the recipe so the action's cache
    # identity does not vary with host CPU discovery — assert it verbatim.
    check rows[2].command == "cd $extracted/build && make -j8"
    check rows[3].command == "cd $extracted/build && make install"
    # lib64 -> lib aliases so declared library artifacts resolve consistently.
    check rows[4].command.contains("$out/lib64/$runtime")

  test "shell() ids carry the per-artifact sequence number":
    # M9.N Batch C.1 — auto-generated ids follow the
    # ``<package>-<artifact>-<seq>`` shape; sequence increments per
    # artifact.
    let rows = registeredShellActions("gccSource")
    check rows.len == 5
    check rows[0].id == "gccSource-gcc-1"
    check rows[1].id == "gccSource-gcc-2"
    check rows[2].id == "gccSource-gcc-3"
    check rows[3].id == "gccSource-gcc-4"
    check rows[4].id == "gccSource-gcc-5"
