## Smoke test for the from-source ``libdrmSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the SECOND real production
## from-source recipe (the first was ``dbusBrokerSource``). Where the
## dbus-broker test exercised executable artifacts, this one exercises
## the M3 ``library`` artifact family — both kinds plug into the same
## artifact registry but the kind discriminator differs (dakLibrary vs
## dakExecutable), so a regression that flattened the kind discriminator
## would surface differently here than in the dbus-broker smoke test.
##
## Coverage:
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (the ``cmake`` channel must NOT see the meson flags).
##   * ``library`` artifact registration (M3) — three libraries, all
##     tagged ``dakLibrary``, all attributed to ``libdrmSource``.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library artifacts under
# ``libdrmSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://dri.freedesktop.org/libdrm/libdrm-2.4.133.tar.xz"

const ExpectedHash =
  "fc68f9d0ba2ea63c9432a299e14fea09fad7a8a66e8039fcd7802ca59f77b4f5"

const ExpectedMesonOptions = @[
  "intel=disabled",
  "radeon=disabled",
  "amdgpu=enabled",
  "nouveau=enabled",
  "vmwgfx=disabled",
  "freedreno=disabled",
  "vc4=disabled",
  "etnaviv=disabled",
  "tegra=disabled",
  "valgrind=disabled",
  "man-pages=disabled",
]

suite "libdrmSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("libdrmSource")
    check spec.packageName == "libdrmSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 436,912-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("libdrmSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream uses for
    # freedesktop.org tag tarballs.
    let spec = registeredFetchSpec("libdrmSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``meson_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("libdrmSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedMesonOptions
    check buildBlockConstructors("libdrmSource") == @["meson_package"]
  test "mesonOptions does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("libdrmSource")
  test "library artifacts register all three shared objects":
    # M3 artifact registry: ``libdrm``, ``libdrmAmdgpu``, and
    # ``libdrmNouveau`` must all be present so the convention layer's
    # install/output collection knows which shared objects to harvest.
    # Critically, the kind discriminator must be ``dakLibrary`` (not
    # ``dakExecutable``) — that distinction drives the M9.L install
    # path (``lib/`` rather than ``bin/``) and the per-artifact
    # downstream linkage propagation.
    let arts = registeredArtifacts("libdrmSource")
    check arts.len == 3
    var seenCore = false
    var seenAmdgpu = false
    var seenNouveau = false
    for art in arts:
      check art.packageName == "libdrmSource"
      check art.kind == dakLibrary
      case art.artifactName
      of "libdrm":
        seenCore = true
      of "libdrmAmdgpu":
        seenAmdgpu = true
      of "libdrmNouveau":
        seenNouveau = true
      else:
        discard
    check seenCore
    check seenAmdgpu
    check seenNouveau

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream freedesktop.org tag is
    # recorded for ``repro update-source`` even though the live fetch
    # points at the vendored copy. The repository points at the
    # gitlab mirror that hosts the Mesa ``drm`` source tree.
    let vs = registeredVersions("libdrmSource")
    check vs.len == 1
    check vs[0].version == "2.4.133"
    check vs[0].sourceRevision == "libdrm-2.4.133"
    check vs[0].sourceUrl ==
      "https://dri.freedesktop.org/libdrm/libdrm-2.4.133.tar.xz"
    check vs[0].sourceRepository == "https://gitlab.freedesktop.org/mesa/drm"
