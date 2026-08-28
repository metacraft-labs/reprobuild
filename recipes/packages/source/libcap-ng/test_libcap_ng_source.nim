## Smoke test for the from-source ``libcapNgSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the FIFTIETH real production
## from-source recipe. libcap-ng's unique coverage angle vs the prior
## forty-nine is the SINGLE-library autotools-driven shape that
## complements (does NOT replace) the libcap recipe (thirty-fourth) —
## libcap covers the "raw" POSIX 1003.1e capabilities API, libcap-ng
## covers the higher-level wrapper API. The kebab-cased upstream
## SONAME ``cap-ng`` -> ``libCapNg`` PascalCase mapping pins the
## json-c -> libJsonC precedent on a second SONAME.
##
## Coverage (≥8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``configureFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set (including the
##     two consecutive ``--without-python*`` flags that guard against
##     prefix-collapse regressions) + channel-isolation spot-check
##     (meson + cmake + make channels MUST be empty).
##   * SINGLE library artifact registration (M3) — ``libCapNg`` tagged
##     ``dakLibrary``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + configure flags + one library artifact under
# ``libcapNgSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://people.redhat.com/sgrubb/libcap-ng/libcap-ng-0.8.5.tar.gz"

const ExpectedHash =
  "3ba5294d1cbdfa98afaacfbc00b6af9ed2b83e8a21817185dfd844cc8c7ac6ff"

const ExpectedConfigureFlags = @[
  "--disable-static",
  "--without-python",
  "--without-python3",
]

suite "libcapNgSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("libcapNgSource")
    check spec.packageName == "libcapNgSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 460,149-byte tarball; length check guards
    # against a future bump that forgets to widen the hash alongside
    # the URL.
    let spec = registeredFetchSpec("libcapNgSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream people.redhat.com
    # release tarballs use.
    let spec = registeredFetchSpec("libcapNgSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "configureFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``autotools_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("libcapNgSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedConfigureFlags
    check buildBlockConstructors("libcapNgSource") == @["autotools_package"]
  test "configureFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("libcapNgSource")
  test "configureFlags does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("libcapNgSource")
  test "configureFlags does not leak into the make channel":
    # The retired registry kept a separate ``make`` flag channel.
    # Its post-M9.R.6.1 equivalent is the ``makeVars`` /
    # ``installMakeVars`` arguments of the Layer-1 constructors:
    # flags reaching the make step would be passed there. This
    # recipe passes neither, so nothing leaks into that channel.
    check not buildBlockPassesArgument("libcapNgSource", "makeVars")
    check not buildBlockPassesArgument("libcapNgSource", "installMakeVars")
  test "artifacts register a single library with kebab-to-PascalCase SONAME":
    # M3 artifact registry: ``libCapNg`` is the only artifact and must
    # be tagged ``dakLibrary``. libcap-ng's autotools build emits a
    # single shared object (``libcap-ng.so``). The PascalCased
    # ``libCapNg`` identifier pins the json-c -> libJsonC precedent
    # that handles the kebab-to-PascalCase mapping on hyphenated
    # SONAMEs (the upstream SONAME ``cap-ng`` becomes ``libCapNg``).
    # A regression that mis-tagged the artifact kind would mis-route
    # the M9.L install path (``lib/`` vs ``bin/``).
    let arts = registeredArtifacts("libcapNgSource")
    check arts.len == 1
    check arts[0].packageName == "libcapNgSource"
    check arts[0].artifactName == "libCapNg"
    check arts[0].kind == dakLibrary

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream people.redhat.com release tag
    # is recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at the
    # canonical github.com mirror of Steve Grubb's libcap-ng source
    # tree.
    let vs = registeredVersions("libcapNgSource")
    check vs.len == 1
    check vs[0].version == "0.8.5"
    check vs[0].sourceRevision == "v0.8.5"
    check vs[0].sourceUrl ==
      "https://people.redhat.com/sgrubb/libcap-ng/libcap-ng-0.8.5.tar.gz"
    check vs[0].sourceRepository ==
      "https://github.com/stevegrubb/libcap-ng"
