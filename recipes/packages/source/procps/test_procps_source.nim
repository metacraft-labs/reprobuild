## Smoke test for the from-source ``procpsSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FORTY-EIGHTH real
## production from-source recipe. procps-ng's unique coverage angle vs
## the prior forty-seven is the SIX-ARTIFACT (mixed-kind) single-package
## shape with FIVE executables + ONE library all driven through the
## autotools ``configureFlags:`` channel, sourced from the GitLab
## archive endpoint (``/-/archive/<tag>/<name>-<tag>.tar.gz``) — the
## FIRST recipe in the corpus to consume the GitLab archive shape.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * SIX artifact registration (M3) — five executables tagged
##     ``dakExecutable`` + one library tagged ``dakLibrary``, all in
##     the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + five executable + one library
# artifacts under ``procpsSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://gitlab.com/procps-ng/procps/-/archive/v4.0.5/procps-v4.0.5.tar.gz"

const ExpectedHash =
  "2c6d7ed9f2acde1d4dd4602c6172fe56eff86953fe8639bd633dbd22cc18f5db"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--disable-nls",
  "--with-systemd=no",
  "LIBS=-ltinfow",
  "NCURSES_CFLAGS=-I/opt/repro/reprobuild/recipes/packages/source/ncurses/.repro/output/install/usr/include",
  "NCURSES_LIBS=-lncursesw",
]

suite "procpsSource — from-source recipe smoke test":

  test "build dependencies cover autoreconf and top's terminal UI":
    check registeredNativeBuildDeps("procpsSource") == @[
      "autoconf", "automake", "libtool", "m4", "make", "gcc >=11",
      "pkg-config",
    ]
    check registeredBuildDeps("procpsSource") == @["ncurses >=6.0"]

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("procpsSource")
    check spec.packageName == "procpsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2,392,641-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("procpsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream GitLab archive
    # tarballs use (the leading directory in the .tar.gz is
    # ``procps-v4.0.5/`` so extractStrip=1 lands the source tree at
    # the build cwd root).
    let spec = registeredFetchSpec("procpsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("procpsSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("procpsSource") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("procpsSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("procpsSource")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("procpsSource", "makeVars")
    check not buildBlockPassesArgument("procpsSource", "installMakeVars")
  test "artifacts register five executables + one library with correct kinds":
    # M3 artifact registry: ``ps`` + ``top`` + ``free`` + ``kill`` +
    # ``uptime`` are tagged ``dakExecutable`` while ``libProc2`` is
    # tagged ``dakLibrary``. A regression that flattened the kind
    # discriminator would mis-route the M9.L install path (``lib/``
    # vs ``bin/``); a regression that collapsed the artifact-name
    # partitioning would not produce six distinct entries with the
    # expected names below.
    let arts = registeredArtifacts("procpsSource")
    check arts.len == 6
    var seenPs = false
    var seenTop = false
    var seenFree = false
    var seenKill = false
    var seenUptime = false
    var seenLibProc = false
    for art in arts:
      check art.packageName == "procpsSource"
      case art.artifactName
      of "ps":
        seenPs = true
        check art.kind == dakExecutable
      of "top":
        seenTop = true
        check art.kind == dakExecutable
      of "free":
        seenFree = true
        check art.kind == dakExecutable
      of "kill":
        seenKill = true
        check art.kind == dakExecutable
      of "uptime":
        seenUptime = true
        check art.kind == dakExecutable
      of "libProc2":
        seenLibProc = true
        check art.kind == dakLibrary
      else:
        discard
    check seenPs
    check seenTop
    check seenFree
    check seenKill
    check seenUptime
    check seenLibProc

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream gitlab.com archive URL is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical procps-ng GitLab project that hosts the source tree.
    let vs = registeredVersions("procpsSource")
    check vs.len == 1
    check vs[0].version == "4.0.5"
    check vs[0].sourceRevision == "v4.0.5"
    check vs[0].sourceUrl ==
      "https://gitlab.com/procps-ng/procps/-/archive/v4.0.5/procps-v4.0.5.tar.gz"
    check vs[0].sourceRepository ==
      "https://gitlab.com/procps-ng/procps"
