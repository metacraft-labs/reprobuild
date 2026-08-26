## Smoke test for the from-source ``gnomeShellSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the EIGHTEENTH real production
## from-source recipe and the CLOSING recipe in the GNOME stack batch.
## gnome-shell's unique coverage angle vs the prior seventeen is that
## it's the FIRST recipe to combine BOTH a multi-word-kebab package
## name (``gnome-shell`` -> ``gnomeShellSource``) AND a mixed-kind
## artifact set (library + executable in the same ``package`` macro):
## the M3 registry's name-mangling + per-package artifact partitioning
## are exercised at the same time. A regression that fumbled the
## multi-word kebab-to-camel translation OR collapsed the kind
## discriminator would surface here.
##
## Coverage (12 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``mesonOptions:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (cmake + configure channels MUST be empty).
##   * Library + executable artifact registration (M3) — ``libGnomeShell``
##     tagged ``dakLibrary`` and ``gnomeShell`` tagged ``dakExecutable``
##     within the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[unittest, strutils]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + meson options + library + executable artifacts under
# ``gnomeShellSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  "https://download.gnome.org/sources/gnome-shell/47/gnome-shell-47.10.tar.xz"

const ExpectedHash =
  "5174d25bb05d35f3612498efc33a1de533fc4e0f39e3eb377fd09591c94a10e6"

const ExpectedMesonOptions = @[
  "gtk_doc=false",
  "tests=false",
  "man=false",
  "camera_monitor=false",
  "networkmanager=false",
  "portal_helper=false",
  "systemd=false",
  "extensions_app=false",
  "extensions_tool=false",
]

suite "gnomeShellSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("gnomeShellSource")
    check spec.packageName == "gnomeShellSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 2,144,616-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("gnomeShellSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream gnome.org release
    # tarballs use.
    let spec = registeredFetchSpec("gnomeShellSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "mesonOptions registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``meson_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("gnomeShellSource")
    check declared.found
    # Every element is a string literal, so this is the WHOLE
    # sequence the recipe declares, in declared order.
    check declared.complete
    check declared.values == ExpectedMesonOptions
    check buildBlockConstructors("gnomeShellSource") == @["meson_package"]
  test "mesonOptions does not leak into the cmake channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the cmake channel would
    # surface as a ``cmake_package(...)`` call here.
    check "cmake_package" notin buildBlockConstructors("gnomeShellSource")
  test "mesonOptions does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("gnomeShellSource")
  test "artifacts register an executable + a library with correct kinds":
    # M3 artifact registry: ``gnomeShell`` is tagged ``dakExecutable``
    # while ``libGnomeShell`` is tagged ``dakLibrary``. The unique
    # coverage of THIS recipe is that it combines BOTH the multi-
    # word-kebab package-name mangling (``gnome-shell`` ->
    # ``gnomeShellSource``) AND a mixed-kind artifact set in the same
    # package. A regression that flattened the kind discriminator
    # would mis-route the M9.L install path (``lib/`` vs ``bin/``);
    # a regression that fumbled the kebab-to-camel translation would
    # produce ``gnome_shell`` / ``gnomeshell`` / ``GnomeShell``
    # variants none of which match the assertions below.
    let arts = registeredArtifacts("gnomeShellSource")
    check arts.len == 2
    var seenBin = false
    var seenLib = false
    for art in arts:
      check art.packageName == "gnomeShellSource"
      case art.artifactName
      of "gnomeShell":
        seenBin = true
        check art.kind == dakExecutable
      of "libGnomeShell":
        seenLib = true
        check art.kind == dakLibrary
      else:
        discard
    check seenBin
    check seenLib

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.gnome.org release
    # tag is recorded for ``repro update-source`` even though the
    # live fetch points at the vendored copy. The repository points
    # at the canonical GNOME gitlab project that hosts the
    # gnome-shell source tree.
    let vs = registeredVersions("gnomeShellSource")
    check vs.len == 1
    check vs[0].version == "47.10"
    check vs[0].sourceRevision == "47.10"
    check vs[0].sourceUrl ==
      "https://download.gnome.org/sources/gnome-shell/47/gnome-shell-47.10.tar.xz"
    check vs[0].sourceRepository ==
      "https://gitlab.gnome.org/GNOME/gnome-shell"
