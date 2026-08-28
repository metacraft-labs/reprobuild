## Smoke test for the from-source ``iproute2Source`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FORTY-NINTH real production
## from-source recipe. iproute2's unique coverage angle vs the prior
## forty-eight is the FOUR-EXECUTABLE single-package shape driven by a
## RAW Makefile paired with a HAND-ROLLED ``./configure`` shell-script
## wrapper (NOT autoconf-generated). The ``configureFlags:`` channel
## carries a single ``--without-libelf`` flag — the smallest production
## configure-flag set in the corpus and a useful pin for the
## per-channel one-flag-only edge case.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + cmake + make channels MUST be empty).
##   * FOUR executable artifact registration (M3) — ``ip`` + ``tc`` +
##     ``ss`` + ``bridge`` all tagged ``dakExecutable``, all in the
##     same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + four executable artifacts under
# ``iproute2Source`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://www.kernel.org/pub/linux/utils/net/iproute2/iproute2-6.12.0.tar.xz"

const ExpectedHash =
  "bbd141ef7b5d0127cc2152843ba61f274dc32814fa3e0f13e7d07a080bef53d9"

const ExpectedConfigureFlags = @[
  "PREFIX=/usr",
  "SBINDIR=/usr/sbin",
  "CBUILD_CFLAGS=$(CPPFLAGS) $(CFLAGS)",
  "HOSTCC=$(CC) $(LDFLAGS)",
]

suite "iproute2Source — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("iproute2Source")
    check spec.packageName == "iproute2Source"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 925,392-byte tarball; length check guards
    # against a future bump that forgets to widen the hash alongside
    # the URL.
    let spec = registeredFetchSpec("iproute2Source")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream kernel.org release
    # tarballs use.
    let spec = registeredFetchSpec("iproute2Source")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("iproute2Source")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("iproute2Source") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("iproute2Source")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("iproute2Source")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("iproute2Source", "makeVars")
    check not buildBlockPassesArgument("iproute2Source", "installMakeVars")
  test "artifacts register four executables with correct kinds":
    # M3 artifact registry: ``ip`` + ``tc`` + ``ss`` + ``bridge`` are
    # all tagged ``dakExecutable``. iproute2 ships only executables
    # at the externally-consumed surface (the internal
    # ``libnetlink.a`` static archive + helper libraries are NOT
    # installed as library artifacts in the distro-packaging sense).
    let arts = registeredArtifacts("iproute2Source")
    check arts.len == 4
    var seenIp = false
    var seenTc = false
    var seenSs = false
    var seenBridge = false
    for art in arts:
      check art.packageName == "iproute2Source"
      check art.kind == dakExecutable
      case art.artifactName
      of "ip":
        seenIp = true
      of "tc":
        seenTc = true
      of "ss":
        seenSs = true
      of "bridge":
        seenBridge = true
      else:
        discard
    check seenIp
    check seenTc
    check seenSs
    check seenBridge

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream kernel.org release tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # canonical mirror on git.kernel.org that hosts the iproute2 source
    # tree.
    let vs = registeredVersions("iproute2Source")
    check vs.len == 1
    check vs[0].version == "6.12.0"
    check vs[0].sourceRevision == "v6.12.0"
    check vs[0].sourceUrl ==
      "https://www.kernel.org/pub/linux/utils/net/iproute2/iproute2-6.12.0.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.kernel.org/pub/scm/network/iproute2/iproute2.git"
