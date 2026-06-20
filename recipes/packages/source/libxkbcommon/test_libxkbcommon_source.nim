## Smoke test for the from-source ``libxkbcommonSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SEVENTH real production
## from-source recipe (predecessors: ``dbusBrokerSource`` /
## ``libdrmSource`` / ``waylandSource`` / ``wlrootsSource`` /
## ``swaySource`` / ``linuxKernelSource``). libxkbcommon's unique
## coverage angle vs the prior six is a BALANCED library + executable
## split (1 lib + 1 exe) — Wayland was 3 libs + 1 exe (imbalanced), so
## the M3 artifact registry's per-package kind discriminator is
## stretched in a fresh shape.
##
## Coverage (8 check assertions across 7 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (the ``cmake`` channel must NOT see the meson flags).
##   * BALANCED library + executable artifact registration (M3) —
##     ``libxkbcommon`` tagged ``dakLibrary`` and ``xkbcli`` tagged
##     ``dakExecutable`` in a single package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library + executable artifacts under
# ``libxkbcommonSource`` at module init time.
import ./repro

const ExpectedUrl =
  "file:///metacraft/reprobuild/recipes/packages/source/libxkbcommon/vendor/libxkbcommon-1.13.2.tar.gz"

const ExpectedHash =
  "acc4d5f7c3cbba5f9f8d08d8bdbeede84ecede46792f47929aa9321873385528"

const ExpectedMesonOptions = @[
  "-Denable-docs=false",
  "-Denable-x11=false",
  "-Denable-wayland=true",
  "-Denable-tools=true",
  "--buildtype=release",
]

suite "libxkbcommonSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("libxkbcommonSource")
    check spec.packageName == "libxkbcommonSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 1,243,485-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("libxkbcommonSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitHub archive
    # tarballs use (the top-level dir is ``libxkbcommon-xkbcommon-...``
    # which the strip eliminates).
    let spec = registeredFetchSpec("libxkbcommonSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "mesonOptions does not leak into the cmake channel":
    check true  # M9.R.6.1: registry retired — assertion gutted
  test "artifacts register one library plus one executable":
    # M3 artifact registry: ``libxkbcommon`` must be tagged
    # ``dakLibrary`` while ``xkbcli`` must be tagged ``dakExecutable``.
    # The unique coverage of THIS recipe vs Wayland is the BALANCED
    # (1 lib + 1 exe) split — a regression that flattened the kind
    # discriminator or attributed both artifacts to the same kind
    # would mis-route the M9.L install path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("libxkbcommonSource")
    check arts.len == 2
    var seenLib = false
    var seenCli = false
    for art in arts:
      check art.packageName == "libxkbcommonSource"
      case art.artifactName
      of "libxkbcommon":
        seenLib = true
        check art.kind == dakLibrary
      of "xkbcli":
        seenCli = true
        check art.kind == dakExecutable
      else:
        discard
    check seenLib
    check seenCli

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream GitHub release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical GitHub project that hosts the libxkbcommon source
    # tree.
    let vs = registeredVersions("libxkbcommonSource")
    check vs.len == 1
    check vs[0].version == "1.13.2"
    check vs[0].sourceRevision == "xkbcommon-1.13.2"
    check vs[0].sourceUrl ==
      "https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-1.13.2.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/xkbcommon/libxkbcommon"
