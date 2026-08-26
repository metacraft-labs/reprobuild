## Smoke test for the from-source ``kwinSource`` recipe.
##
## Pins the M9.H/I/K trio's behaviour on the TWENTIETH real production
## from-source recipe and the SECOND recipe in the Plasma stack batch.
## kwin's unique coverage angle vs the prior nineteen is that it's the
## FIRST CMake recipe to combine a library + an executable in the same
## ``package`` macro (the meson-side analogues — wayland, mutter,
## gnome-shell — already pinned the mixed-kind partitioning from the
## meson channel). The cross-channel isolation pin below additionally
## checks the meson + configure channels stay empty under the mixed-
## kind shape, so a regression that flattened the artifact-kind
## partitioning AND the per-channel build-flag partitioning at once
## would surface here.
##
## Coverage (12 check assertions across 8 tests):
##
##   * ``fetch:`` block round-trip (M9.H) — URL + sha256 length +
##     algorithm + kind discriminant + extractStrip.
##   * ``cmakeFlags:`` block round-trip (M9.I) — exact-order
##     sequence equality on the production flag set + channel-isolation
##     spot-check (meson + configure channels MUST be empty).
##   * Library + executable artifact registration (M3) — ``libKWin``
##     tagged ``dakLibrary`` and ``kwinWayland`` tagged
##     ``dakExecutable`` within the same package's artifact set.
##   * ``versions:`` block round-trip (M2) — upstream tag + URL +
##     repository for ``repro update-source``.

import std/[envvars, os, strutils, unittest]

import repro_project_dsl

# Side-effect import: triggers the package macro which registers
# fetch spec + cmake flags + library + executable artifacts under
# ``kwinSource`` at module init time.
import ./repro

# Test-support helpers that read the recipe's ``build:`` block off
# the DSL's ``registeredBuildActions`` registry -- the surface the
# per-channel build flags moved to when M9.R.6.1 retired
# ``registeredBuildFlags``.
import ../recipe_build_block

const ExpectedUrl =
  # M9.R.15f.5 drive-by — the recipe long since switched to the
  # upstream download.kde.org URL but this constant was never
  # updated.
  "https://download.kde.org/stable/plasma/6.2.5/kwin-6.2.5.tar.xz"

const ExpectedHash =
  "5cc450a6e41105c8c49929b72550b331237f96aafb294690f4707bdc5f776848"

const RecipeRootEnv = "REPROBUILD_RECIPE_ROOT"

template withRecipeRootEnv(body: untyped) =
  let oldSet = existsEnv(RecipeRootEnv)
  let oldValue = getEnv(RecipeRootEnv)
  putEnv(RecipeRootEnv, currentSourcePath.parentDir.parentDir)
  try:
    body
  finally:
    if oldSet:
      putEnv(RecipeRootEnv, oldValue)
    else:
      delEnv(RecipeRootEnv)

proc argByName(action: BuildActionDef; name: string): PublicCliArg =
  for arg in action.call.arguments:
    if arg.name == name:
      return arg
  raise newException(ValueError, "no argument named '" & name & "'")

proc encodedValues(arg: PublicCliArg): seq[string] =
  if arg.encodedValue.len == 0:
    return @[]
  arg.encodedValue.split("\x1f")

proc envValue(action: BuildActionDef; name: string): string =
  for (key, value) in action.env:
    if key == name:
      return value
  ""

proc findCmakeConfigureAction(): BuildActionDef =
  for action in registeredBuildActions():
    if action.call.packageName == "cmake" and
        action.call.executableName == "cmakeBin" and
        action.call.subcommand == "configure":
      return action
  raise newException(ValueError, "cmake configure action not found")

proc cacheVarValue(action: BuildActionDef; name: string): string =
  let prefix = name & "="
  for entry in action.argByName("cacheVars").encodedValues():
    if entry.startsWith(prefix):
      return entry[prefix.len .. ^1]
  ""

const ExpectedCmakeFlags = @[
  "BUILD_TESTING=OFF",
  "KWIN_BUILD_TABBOX=OFF",
  "KWIN_BUILD_X11=OFF",
  "KWIN_BUILD_KCMS=OFF",
  "KWIN_BUILD_GLOBALSHORTCUTS=OFF",
  "KWIN_BUILD_NOTIFICATIONS=OFF",
  "KWIN_BUILD_SCREENLOCKER=OFF",
  "KWIN_BUILD_RUNNERS=OFF",
  "CMAKE_BUILD_TYPE=Release",
  "CMAKE_C_FLAGS=",
  "CMAKE_CXX_FLAGS=",
  "CMAKE_EXE_LINKER_FLAGS=-Wl,--copy-dt-needed-entries ",
  "CMAKE_SHARED_LINKER_FLAGS=-Wl,--copy-dt-needed-entries ",
]

suite "kwinSource — from-source recipe smoke test":

  test "fetch spec carries the vendored URL verbatim":
    # M9.H registry round-trip — URL is recorded exactly as declared.
    let spec = registeredFetchSpec("kwinSource")
    check spec.packageName == "kwinSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    # sha256 over the vendored 8,563,352-byte tarball; length check
    # guards against a future bump that forgets to widen the hash
    # alongside the URL.
    let spec = registeredFetchSpec("kwinSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    # Tarball vs git-archive discriminant + the canonical
    # ``--strip-components=1`` convention upstream download.kde.org
    # release tarballs use.
    let spec = registeredFetchSpec("kwinSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "cmakeFlags registers the exact production flag sequence":
    # M9.R.6.1 retired the ``registeredBuildFlags`` runtime registry this
    # assertion used to read. The property outlived the registry: the flags
    # moved into this recipe's explicit ``build:`` block, where they are
    # handed to the Layer-1 ``cmake_package(...)`` constructor. The DSL's M4
    # emitter records that block verbatim and ``registeredBuildActions``
    # exposes it -- see ``recipes/packages/source/recipe_build_block.nim``.
    let declared = declaredBuildOptions("kwinSource")
    check declared.found
    # Several elements are resolver-derived include and link flags built
    # at build-block eval time, so only the literal elements are pinned.
    check declared.values == ExpectedCmakeFlags
    check buildBlockConstructors("kwinSource") == @["cmake_package"]
  test "M9.R.81 threads dependency roots into configure env and include flags":
    withRecipeRootEnv:
      resetBuildActionRegistry()
      buildKwinSourcePackage()

      let configure = findCmakeConfigureAction()
      let waylandRoot = dependencyInstallMirrorRoot("wayland", "kwinSource")
      let qt6BaseRoot = dependencyInstallMirrorRoot("qt6-base", "kwinSource")
      let qt6DeclRoot = dependencyInstallMirrorRoot(
        "qt6-declarative", "kwinSource")

      check configure.envValue("DEP_WAYLAND_ROOT") == waylandRoot
      check configure.envValue("DEP_QT6_BASE_ROOT") == qt6BaseRoot
      check configure.envValue("DEP_QT6_DECLARATIVE_ROOT") == qt6DeclRoot

      let cFlags = configure.cacheVarValue("CMAKE_C_FLAGS")
      let cxxFlags = configure.cacheVarValue("CMAKE_CXX_FLAGS")
      check cFlags.contains("-isystem " & waylandRoot & "/usr/include")
      check cFlags.contains("-isystem " & qt6BaseRoot & "/usr/include")
      check cFlags.contains("-isystem " & qt6DeclRoot & "/usr/include")
      check cxxFlags == cFlags
      check not cFlags.contains("/opt/repro/reprobuild/recipes/packages/source")

  test "cmakeFlags does not leak into the meson channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the meson channel would
    # surface as a ``meson_package(...)`` call here.
    check "meson_package" notin buildBlockConstructors("kwinSource")
  test "cmakeFlags does not leak into the configure channel":
    # Channel isolation: a recipe drives exactly ONE upstream build
    # system, so its ``build:`` block calls exactly one Layer-1
    # constructor. Options leaking into the configure channel would
    # surface as a ``autotools_package(...)`` call here.
    check "autotools_package" notin buildBlockConstructors("kwinSource")
  test "artifacts register an executable + a library with correct kinds":
    # M3 artifact registry: ``kwinWayland`` is tagged ``dakExecutable``
    # while ``libKWin`` is tagged ``dakLibrary``. This is the FIRST
    # CMake recipe to combine a library + an executable in the same
    # package macro. A regression that flattened the kind
    # discriminator would mis-route the M9.L install path
    # (``lib/`` vs ``bin/``); a regression that mis-mapped the
    # PascalCase brand-casing on the library name (``libKWin``)
    # would not match the assertion below.
    let arts = registeredArtifacts("kwinSource")
    check arts.len == 2
    var seenBin = false
    var seenLib = false
    for art in arts:
      check art.packageName == "kwinSource"
      case art.artifactName
      of "kwinWayland":
        seenBin = true
        check art.kind == dakExecutable
      of "libKWin":
        seenLib = true
        check art.kind == dakLibrary
      else:
        discard
    check seenBin
    check seenLib

  test "versions block records the upstream tag + URL + repository":
    # M2 versions registry: the upstream download.kde.org release tag
    # is recorded for ``repro update-source`` even though the live
    # fetch points at the vendored copy. The repository points at the
    # canonical KDE invent.kde.org project that hosts the kwin source
    # tree.
    let vs = registeredVersions("kwinSource")
    check vs.len == 1
    check vs[0].version == "6.2.5"
    check vs[0].sourceRevision == "v6.2.5"
    check vs[0].sourceUrl ==
      "https://download.kde.org/stable/plasma/6.2.5/kwin-6.2.5.tar.xz"
    check vs[0].sourceRepository ==
      "https://invent.kde.org/plasma/kwin"
