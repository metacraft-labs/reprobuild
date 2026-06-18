## Smoke test for the from-source ``coreutilsSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FORTY-THIRD real
## production from-source recipe. coreutils's unique coverage angle vs
## the prior forty-two is being the canonical GNU userland — the most-
## installed package on every Linux desktop, shipping ~100 distinct
## binaries from a single ``./configure`` + ``make`` invocation. v1
## records the SIX most-used binaries as typed artifacts (ls + cp +
## mv + rm + cat + echo); the remaining ~94 are built by the make
## invocation but not registered.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set (includes the
##     comma-separated ``--enable-no-install-program=kill,uptime,arch``
##     value, pinning the per-channel handling of comma-list values) +
##     channel-isolation spot-check (meson + cmake channels MUST be
##     empty).
##   * SIX executable artifact registration (M3) — ls + cp + mv + rm
##     + cat + echo all tagged ``dakExecutable``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + six executable artifacts under
# ``coreutilsSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/coreutils/vendor/coreutils-9.5.tar.xz"

const ExpectedHash =
  "cd328edeac92f6a665de9f323c93b712af1858bc2e0d88f3f7100469470a1b8a"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--enable-no-install-program=kill,uptime,arch",
  "--without-selinux",
]

suite "coreutilsSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("coreutilsSource")
    check spec.packageName == "coreutilsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 6,007,136-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("coreutilsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream ftp.gnu.org release
    # tarballs use.
    let spec = registeredFetchSpec("coreutilsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.I exact-order round-trip on the configure channel — the
    # autotools ``./configure`` script evaluates options left-to-right
    # and a regression that reorders this seq would silently change
    # build behaviour (static on/off, per-binary install skip-list,
    # selinux on/off). The middle flag's comma-separated value
    # (``kill,uptime,arch``) pins the per-channel handling of
    # comma-list values — a regression that split the value on commas
    # would surface here as a flag-count mismatch.
    let flags = registeredBuildFlags("coreutilsSource", "", "configure")
    check flags == ExpectedConfigureFlags
    check flags.len == 3

  test "configureFlags does not leak into the meson channel":
    # Cross-channel isolation — guards against a regression that
    # flattens the registries.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("coreutilsSource", "", "meson") == emptyStrSeq

  test "configureFlags does not leak into the cmake channel":
    # Cross-channel isolation #2 — guards against a regression that
    # merges the autotools + CMake channels.
    let emptyStrSeq: seq[string] = @[]
    check registeredBuildFlags("coreutilsSource", "", "cmake") == emptyStrSeq

  test "artifacts register six executables all tagged dakExecutable":
    # M3 artifact registry: ls + cp + mv + rm + cat + echo are all
    # tagged ``dakExecutable``. coreutils's autotools build emits ~100
    # binaries from one ``./configure`` + ``make`` invocation but v1
    # records only the SIX most-used. A regression that flattened the
    # kind discriminator would mis-route the M9.L install path; a
    # regression that collapsed the artifact-name partitioning at the
    # six-artifact cardinality would not produce six distinct entries
    # with the expected names below.
    let arts = registeredArtifacts("coreutilsSource")
    check arts.len == 6
    var seenLs = false
    var seenCp = false
    var seenMv = false
    var seenRm = false
    var seenCat = false
    var seenEcho = false
    for art in arts:
      check art.packageName == "coreutilsSource"
      check art.kind == dakExecutable
      case art.artifactName
      of "ls":
        seenLs = true
      of "cp":
        seenCp = true
      of "mv":
        seenMv = true
      of "rm":
        seenRm = true
      of "cat":
        seenCat = true
      of "echo":
        seenEcho = true
      else:
        discard
    check seenLs
    check seenCp
    check seenMv
    check seenRm
    check seenCat
    check seenEcho

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream ftp.gnu.org release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical savannah.gnu.org mirror that hosts the coreutils
    # source tree.
    let vs = registeredVersions("coreutilsSource")
    check vs.len == 1
    check vs[0].version == "9.5"
    check vs[0].sourceRevision == "v9.5"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/coreutils/coreutils-9.5.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/coreutils.git"
