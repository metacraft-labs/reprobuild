## Smoke test for the from-source ``wireplumberSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SIXTY-NINTH real
## production from-source recipe. wireplumber is THE session/policy
## manager for pipewire: implements the Lua-scripted session-policy
## layer that decides device-to-role mappings + per-application audio
## routing on top of pipewire's multimedia graph.
##
## Coverage (>=8 tests with multiple assertions each):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (cmake + configure channels MUST be empty).
##   * MIXED artifact registration (M3) — one executable
##     (``dakExecutable``) + one library (``dakLibrary``) attributed
##     to ``wireplumberSource`` with kind discriminators preserved
##     per-artifact.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + one executable + one library artifact
# under ``wireplumberSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://gitlab.freedesktop.org/pipewire/wireplumber/-/archive/0.5.14/wireplumber-0.5.14.tar.gz"

# Tarball-bytes sha256 — distinct from the nixpkgs SRI hash which
# covers the NAR-form EXTRACTED directory rather than the tarball
# bytes (gzip mtime + tar block padding differ between the two).
const ExpectedHash =
  "e91f04cd8cec75d72b8a2aaa7e90b1ba0a5e2094b7a882fc3a29a484a48a87e9"

const ExpectedMesonOptions = @[
  "doc=disabled",
  "introspection=disabled",
  "system-lua=false",
  "systemd=enabled",
  "tests=false",
]

suite "wireplumberSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("wireplumberSource")
    check spec.packageName == "wireplumberSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # Length + algorithm check guards against a future bump that
    # forgets to widen the hash alongside the URL. The pinned value
    # is the upstream gitlab.freedesktop.org tarball-bytes sha256.
    let spec = registeredFetchSpec("wireplumberSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gitlab archive
    # tarballs use.
    let spec = registeredFetchSpec("wireplumberSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "declares the build and runtime closure":
    check registeredBuildDeps("wireplumberSource") == @[
      "pipewire >=1.0",
      "glib2 >=2.68",
      "systemd >=240",
    ]
    check registeredRuntimeDeps("wireplumberSource") == @[
      "pipewire >=1.0",
      "glib2 >=2.68",
      "systemd >=240",
    ]
    let native = registeredNativeBuildDeps("wireplumberSource")
    check "meson >=0.59" in native
    check "ninja >=1.10" in native
    check "gcc >=11" in native
    check "pkg-config" in native

  test "mesonOptions registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``meson_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("wireplumberSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedMesonOptions
    check buildBlockConstructors("wireplumberSource") == @["meson_package"]
  test "mesonOptions does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("wireplumberSource")
  test "mesonOptions does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("wireplumberSource")
  test "artifacts register one executable + one library mixed-kind":
    # M3 artifact registry: ``wireplumber`` is tagged
    # ``dakExecutable`` while ``libWireplumber`` is tagged
    # ``dakLibrary``. The MIXED meson shape where a single
    # ``meson setup`` + ``ninja`` emits BOTH kinds — a regression
    # that flattened the kind discriminator at the meson convention
    # layer would mis-route the M9.L install path (``lib/`` vs
    # ``bin/``) for one of the two.
    let arts = registeredArtifacts("wireplumberSource")
    check arts.len == 2
    var seenDaemon = false
    var seenLib = false
    for art in arts:
      check art.packageName == "wireplumberSource"
      case art.artifactName
      of "wireplumber":
        seenDaemon = true
        check art.kind == dakExecutable
      of "libWireplumber":
        seenLib = true
        check art.kind == dakLibrary
      else:
        discard
    check seenDaemon
    check seenLib

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream gitlab.freedesktop.org
    # release tag is recorded for ``repro update-source``. The
    # repository points at the canonical gitlab project that hosts
    # the wireplumber source tree.
    let vs = registeredVersions("wireplumberSource")
    check vs.len == 1
    check vs[0].version == "0.5.14"
    check vs[0].sourceRevision == "0.5.14"
    check vs[0].sourceUrl ==
      "https://gitlab.freedesktop.org/pipewire/wireplumber/-/archive/0.5.14/wireplumber-0.5.14.tar.gz"
    check vs[0].sourceRepository ==
      "https://gitlab.freedesktop.org/pipewire/wireplumber"
