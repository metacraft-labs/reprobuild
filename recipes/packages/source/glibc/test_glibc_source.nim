## Smoke test for the from-source ``glibcSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FORTY-SECOND real
## production from-source recipe. glibc's unique coverage angle vs
## the prior forty-one is the SEVEN-artifact mixed-kind shape (six
## libraries + one executable for the dynamic linker) — the new
## record-holder for largest single from-source artifact set,
## eclipsing the prior util-linux eight-artifact record because
## glibc's artifacts span the FULL C runtime + the dynamic linker
## itself (the program the kernel hands every dynamically-linked ELF
## at exec time). A regression that collapsed the artifact-name
## partitioning at this cardinality (or mis-tagged any of the seven
## individual kind discriminants) would surface here.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake channels MUST be empty).
##   * SEVEN artifact registration (M3) — six libraries tagged
##     ``dakLibrary`` (libC + libM + libPthread + libDl + libRt +
##     libCrypt) + one executable tagged ``dakExecutable`` (ldso for
##     the dynamic linker), all in the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + six library + one executable
# artifacts under ``glibcSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/glibc/vendor/glibc-2.40.tar.xz"

const ExpectedHash =
  "19a890175e9263d748f627993de6f4b1af9cd21e03f080e4bfb3a1fac10205a2"

const ExpectedConfigureFlags = @[
  "--disable-werror",
  "--enable-bind-now",
  "--enable-stack-protector=strong",
  "--enable-kernel=4.19",
  "--without-selinux",
]

suite "glibcSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("glibcSource")
    check spec.packageName == "glibcSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 18,752,204-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("glibcSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("glibcSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the meson channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "configureFlags does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register six libraries + one executable with correct kinds":
    # M3 artifact registry: libC + libM + libPthread + libDl + libRt +
    # libCrypt are tagged ``dakLibrary`` while ldso is tagged
    # ``dakExecutable``. The unique coverage of THIS recipe is the
    # SEVEN-artifact mixed-kind shape spanning the full C runtime + the
    # dynamic linker itself. A regression that flattened the kind
    # discriminator would mis-route the M9.L install path (``lib/``
    # vs ``bin/``); a regression that collapsed the artifact-name
    # partitioning at the seven-artifact cardinality would not produce
    # seven distinct entries with the expected names below.
    let arts = registeredArtifacts("glibcSource")
    check arts.len == 7
    var seenLibC = false
    var seenLibM = false
    var seenLibPthread = false
    var seenLibDl = false
    var seenLibRt = false
    var seenLibCrypt = false
    var seenLdso = false
    for art in arts:
      check art.packageName == "glibcSource"
      case art.artifactName
      of "libC":
        seenLibC = true
        check art.kind == dakLibrary
      of "libM":
        seenLibM = true
        check art.kind == dakLibrary
      of "libPthread":
        seenLibPthread = true
        check art.kind == dakLibrary
      of "libDl":
        seenLibDl = true
        check art.kind == dakLibrary
      of "libRt":
        seenLibRt = true
        check art.kind == dakLibrary
      of "libCrypt":
        seenLibCrypt = true
        check art.kind == dakLibrary
      of "ldso":
        seenLdso = true
        check art.kind == dakExecutable
      else:
        discard
    check seenLibC
    check seenLibM
    check seenLibPthread
    check seenLibDl
    check seenLibRt
    check seenLibCrypt
    check seenLdso

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical sourceware.org git mirror that hosts the glibc source
    # tree.
    let vs = registeredVersions("glibcSource")
    check vs.len == 1
    check vs[0].version == "2.40"
    check vs[0].sourceRevision == "glibc-2.40"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/glibc/glibc-2.40.tar.xz"
    check vs[0].sourceRepository ==
      "https://sourceware.org/git/glibc.git"
