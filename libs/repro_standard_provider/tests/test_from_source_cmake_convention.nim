## M9.L.1 verification: from-source CMake (Tier 2b) convention.
##
## Pins the wiring between:
##
##   * the M9.H ``registeredFetchSpec`` registry (fetch: block) → fetch
##     BuildAction emitted by the shared
##     ``conventions/fetch_action.emitFetchAction`` helper;
##   * the M9.I ``registeredBuildFlags`` registry on the ``"cmake"``
##     channel (cmakeFlags: block) → cmake-configure BuildAction's argv;
##   * the per-recipe ``executable``/``library`` declarations →
##     per-artifact stage-copy BuildAction one per declared member.
##
## The test runs against the **real production kcoreaddons recipe**
## under ``recipes/packages/source/kcoreaddons/`` (vendored tarball)
## and exercises ``recognize`` + ``emitFragment`` end-to-end.
##
## Tool availability (``cmake`` / ``ninja`` / ``gcc`` on PATH) is
## intentionally NOT a precondition: the convention emits the action
## graph regardless so the wiring assertions run identically on hosts
## that don't have cmake installed. The actual end-to-end build run
## is gated by ``scripts/validate-from-source-cmake-kcoreaddons.ps1``.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_cmake as
  from_source_cmake_convention

# Side-effect import: triggers the kcoreaddons recipe's package macro
# which registers the fetch spec + cmake flags + library artifact under
# the ``kcoreaddonsSource`` key at module init time. The path is
# relative to this test file's location; ``../../..`` lands at the
# reprobuild repo root, and ``recipes/...`` from there.
import "../../../recipes/packages/source/kcoreaddons/repro"

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_from_source_cmake_convention.nim``
  ## lands at the reprobuild repo root.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  KcoreaddonsRecipe =
    ReprobuildRoot / "recipes" / "packages" / "source" / "kcoreaddons"

proc dummyRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

proc inlineArgvOf(action: BuildActionDef): seq[string] =
  for arg in action.call.arguments:
    if arg.name == "argv":
      if arg.encodedValue.len == 0:
        return @[]
      return arg.encodedValue.split("\x1f")
  @[]

proc extractActions(fragment: GraphFragment): seq[BuildActionDef] =
  for node in fragment.nodes:
    if node.kind != gnkAction:
      continue
    result.add(decodeBuildActionPayload(toBytes(node.payload)))

proc findById(actions: seq[BuildActionDef]; id: string): BuildActionDef =
  for a in actions:
    if a.id == id:
      return a
  raise newException(ValueError, "action not found: " & id)

suite "from-source-cmake convention M9.L.1 — kcoreaddons":

  test "convention name is 'from-source-cmake'":
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    check conv.name == "from-source-cmake"

  test "recognize: positive — kcoreaddons source recipe":
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    # Sanity: the production recipe must exist at the expected path —
    # a regression that moves the recipe should fail loudly here, not
    # silently turn the assertion into a no-op.
    check fileExists(KcoreaddonsRecipe / "repro.nim")
    # Sanity: the recipe import must have populated the M9.H fetch
    # registry. If this fails, the relative-path import didn't reach
    # the side-effect macro and recognise will return false for the
    # wrong reason.
    let spec = registeredFetchSpec("kcoreaddonsSource")
    check spec.url.len > 0
    # No in-tree CMakeLists.txt at projectRoot — otherwise the existing
    # M38 ``c-cpp-cmake`` convention claims it and the from-source
    # variant intentionally yields.
    check not fileExists(extendedPath(KcoreaddonsRecipe / "CMakeLists.txt"))
    let request = dummyRequest(KcoreaddonsRecipe)
    check conv.recognize(KcoreaddonsRecipe, request)

  test "recognize: negative — projectRoot carries in-tree CMakeLists.txt":
    # If ``CMakeLists.txt`` is present at the root, the existing M38
    # ``c-cpp-cmake`` convention claims the project; the from-source
    # variant intentionally yields.
    let scratch = getTempDir() /
      "test_from_source_cmake_convention_intree_cmakelists"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "CMakeLists.txt",
      "cmake_minimum_required(VERSION 3.16)\n" &
      "project(intree C)\n" &
      "add_executable(intree main.c)\n")
    writeFile(scratch / "repro.nim",
      "import repro_project_dsl\n" &
      "package fromSourceCmakeIntreePkg:\n" &
      "  fetch:\n" &
      "    url: \"https://example.com/foo.tar.gz\"\n" &
      "    sha256: \"abc\" & repeat(\"0\", 61)\n" &
      "  uses:\n" &
      "    \"cmake >=3.16\"\n" &
      "  executable foo:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no fetch: block registered":
    # A recipe with ``uses: cmake`` but no fetch spec must NOT be
    # claimed by the from-source variant (no source to fetch).
    let scratch = getTempDir() /
      "test_from_source_cmake_convention_no_fetch"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "repro.nim",
      "import repro_project_dsl\n" &
      "package fromSourceCmakeNoFetchPkg:\n" &
      "  uses:\n" &
      "    \"cmake >=3.16\"\n" &
      "  executable foo:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    # The fetch registry is per-thread; the test recipe is NOT
    # imported (no module-level macro run) so the registry slot stays
    # empty. The recognize gate must reject.
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: produces fetch + configure + build + install + stage-copy chain":
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(KcoreaddonsRecipe)
    require conv.recognize(KcoreaddonsRecipe, request)
    let fragment = conv.emitFragment(KcoreaddonsRecipe, request)
    let actions = extractActions(fragment)

    # The pipeline emits at least 5 actions: fetch + configure + build
    # + install + 1 stage-copy (one per declared library).
    check actions.len >= 5

    var sawFetch = false
    var sawConfigure = false
    var sawBuild = false
    var sawInstall = false
    var sawStageLib = false
    for a in actions:
      if a.id == "ccpp-fetch-kcoreaddonsSource":
        sawFetch = true
      elif a.id == "from-source-cmake-configure":
        sawConfigure = true
      elif a.id == "from-source-cmake-build":
        sawBuild = true
      elif a.id == "from-source-cmake-install":
        sawInstall = true
      elif a.id == "from-source-cmake-stage-libKF6CoreAddons":
        sawStageLib = true
    check sawFetch
    check sawConfigure
    check sawBuild
    check sawInstall
    check sawStageLib

  test "emitFragment: configure argv carries cmake -S/-B/-G Ninja + buildtype + cmakeFlags":
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(KcoreaddonsRecipe)
    let fragment = conv.emitFragment(KcoreaddonsRecipe, request)
    let actions = extractActions(fragment)
    let configure = findById(actions, "from-source-cmake-configure")
    let argvJoined = inlineArgvOf(configure).join(" ")

    # Anchor flags
    check argvJoined.contains("cmake")
    check argvJoined.contains("-S")
    check argvJoined.contains("-B")
    check argvJoined.contains("-G Ninja")
    check argvJoined.contains("-DCMAKE_BUILD_TYPE=Release")

    # M9.I-registered cmakeFlags from the kcoreaddons recipe — every
    # production flag must round-trip into the configure argv. Order is
    # not asserted here (the in-tree c_cpp_cmake tests already pin
    # declaration-order preservation against the same registry); the
    # presence check is sufficient at this layer.
    check argvJoined.contains("-DBUILD_TESTING=OFF")
    check argvJoined.contains("-DBUILD_QCH=OFF")
    check argvJoined.contains("-DBUILD_PYTHON_BINDINGS=OFF")

  test "emitFragment: build depends on configure; install depends on build":
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(KcoreaddonsRecipe)
    let fragment = conv.emitFragment(KcoreaddonsRecipe, request)
    let actions = extractActions(fragment)
    let build = findById(actions, "from-source-cmake-build")
    let install = findById(actions, "from-source-cmake-install")
    check build.deps == @["from-source-cmake-configure"]
    check install.deps == @["from-source-cmake-build"]

  test "emitFragment: stage-copy actions depend on install":
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(KcoreaddonsRecipe)
    let fragment = conv.emitFragment(KcoreaddonsRecipe, request)
    let actions = extractActions(fragment)
    let stageLib = findById(actions,
      "from-source-cmake-stage-libKF6CoreAddons")
    check stageLib.deps == @["from-source-cmake-install"]

  test "emitFragment: stage-copy output paths land under .repro/output/<member>/":
    # The canonical per-artifact output schema — engine output
    # collection keys off this path shape.
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(KcoreaddonsRecipe)
    let fragment = conv.emitFragment(KcoreaddonsRecipe, request)
    let actions = extractActions(fragment)
    let stageLib = findById(actions,
      "from-source-cmake-stage-libKF6CoreAddons")
    check stageLib.outputs.len == 1
    let unified = stageLib.outputs[0].replace('\\', '/')
    check unified.contains(".repro/output/libKF6CoreAddons/")

  test "emitFragment: configure depends on fetch action":
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(KcoreaddonsRecipe)
    let fragment = conv.emitFragment(KcoreaddonsRecipe, request)
    let actions = extractActions(fragment)
    let configure = findById(actions, "from-source-cmake-configure")
    var sawFetchDep = false
    for dep in configure.deps:
      if dep == "ccpp-fetch-kcoreaddonsSource":
        sawFetchDep = true
    check sawFetchDep

  test "emitFragment: fetch action's argv carries the recipe's URL + sha256":
    # M9.H/M9.K round-trip: the fetch action's argv must embed the
    # vendored URL and the 64-hex sha256 from the kcoreaddons recipe.
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(KcoreaddonsRecipe)
    let fragment = conv.emitFragment(KcoreaddonsRecipe, request)
    let actions = extractActions(fragment)
    let fetch = findById(actions, "ccpp-fetch-kcoreaddonsSource")
    let argvJoined = inlineArgvOf(fetch).join(" ")
    check argvJoined.contains("kcoreaddons-6.10.0.tar.xz")
    check argvJoined.contains(
      "89bf28747915e987cab21c77397b0971caffa1258b6f575543d73d4188184a72")

  test "emitFragment: build action's argv invokes cmake --build":
    # The convention's build step must call ``cmake --build <buildDir>``
    # so the configure-time generator (Ninja) is honoured without
    # baking ninja knowledge into the convention.
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(KcoreaddonsRecipe)
    let fragment = conv.emitFragment(KcoreaddonsRecipe, request)
    let actions = extractActions(fragment)
    let build = findById(actions, "from-source-cmake-build")
    let argvJoined = inlineArgvOf(build).join(" ")
    check argvJoined.contains("cmake")
    check argvJoined.contains("--build")

  test "emitFragment: install action's argv invokes cmake --install --prefix <staging>":
    # The install step must call ``cmake --install <buildDir> --prefix
    # <stagingDir>`` so the engine collects artifacts from a known
    # location regardless of the recipe's configure-time prefix.
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(KcoreaddonsRecipe)
    let fragment = conv.emitFragment(KcoreaddonsRecipe, request)
    let actions = extractActions(fragment)
    let install = findById(actions, "from-source-cmake-install")
    let argvJoined = inlineArgvOf(install).join(" ")
    check argvJoined.contains("cmake")
    check argvJoined.contains("--install")
    check argvJoined.contains("--prefix")
    let unified = argvJoined.replace('\\', '/')
    check unified.contains("from-source-cmake/staging")
