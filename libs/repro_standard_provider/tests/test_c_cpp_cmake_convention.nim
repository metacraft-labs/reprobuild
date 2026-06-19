## M38 verification: C/C++ CMake (Tier 2b) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/c-cpp-cmake/hello-binary/`` plus scratch
## projects materialised in the test's temp directory.
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - cmake is on PATH
##     - a C compiler is on PATH
##     - ninja OR a platform make is on PATH
##   * ``recognize`` returns false when:
##     - ``CMakeLists.txt`` is absent
##     - ``configure.ac`` is present at the root (Autotools' territory)
##     - ``uses:`` doesn't list cmake + a C compiler
##     - no executable / library member is declared
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     toolchain is missing):
##     - the convention emits a ``ccpp-cmake-configure`` action.
##     - the convention emits a ``ccpp-cmake-build-hello`` action that
##       depends on the configure action and declares an executable
##       output under ``.repro/build/cmake/``.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/c_cpp_cmake as cmake_convention

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_c_cpp_cmake_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to the
  ## sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "c-cpp-cmake" / "hello-binary"

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

proc cmakeToolchainReady(): bool =
  ## True when cmake + a C compiler + a single-config builder
  ## (ninja or platform make) are on PATH.
  if findExe("cmake").len == 0:
    return false
  if findExe("gcc").len == 0 and findExe("clang").len == 0:
    return false
  if findExe("ninja").len > 0:
    return true
  when defined(windows):
    if findExe("mingw32-make").len > 0:
      return true
    if findExe("make").len > 0:
      return true
    false
  else:
    findExe("make").len > 0

suite "c-cpp-cmake convention M38":

  test "recognize: positive — hello-binary fixture (declaration-only)":
    # M9.N: recognise claims a recipe based on DECLARATION
    # (CMakeLists.txt at projectRoot + uses: cmake +
    # executable/library member), NOT host PATH availability. Tool
    # identity is resolved AFTER recognise by the engine.
    let conv = cmake_convention.cCppCMakeConvention()
    check conv.name == "c-cpp-cmake"
    if not fileExists(HelloBinaryFixture / "CMakeLists.txt"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    check conv.recognize(HelloBinaryFixture, request)

  test "recognize: returns true even without cmake on PATH (M9.N)":
    # M9.N architectural correction: explicit assertion that the
    # host-PATH gate has been dropped from recognise — the convention
    # claims the recipe regardless of whether cmake/ninja/gcc resolve.
    let conv = cmake_convention.cCppCMakeConvention()
    if not fileExists(HelloBinaryFixture / "CMakeLists.txt"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    let cmakeOnPath = findExe("cmake").len > 0
    let ninjaOnPath = findExe("ninja").len > 0
    checkpoint "cmake on PATH: " & $cmakeOnPath &
      ", ninja on PATH: " & $ninjaOnPath
    check conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — CMakeLists.txt missing":
    let scratch = getTempDir() / "test_c_cpp_cmake_convention_no_cmakelists"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){puts(\"x\");return 0;}\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeCcCmakeNoCMakeLists:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"cmake >=3.20\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = cmake_convention.cCppCMakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — configure.ac at root (Autotools' territory)":
    let scratch = getTempDir() / "test_c_cpp_cmake_convention_autotools_present"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "CMakeLists.txt",
      "cmake_minimum_required(VERSION 3.20)\n" &
      "project(hello LANGUAGES C)\n" &
      "add_executable(hello src/main.c)\n")
    writeFile(scratch / "configure.ac",
      "AC_INIT([fake-autotools], [0.1.0])\nAC_OUTPUT\n")
    writeFile(scratch / "Makefile.am",
      "bin_PROGRAMS = hello\nhello_SOURCES = src/main.c\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeAutotoolsCmake:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"cmake >=3.20\"\n" &
      "    \"autoconf >=2.71\"\n" &
      "    \"automake >=1.16\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = cmake_convention.cCppCMakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks cmake":
    let scratch = getTempDir() / "test_c_cpp_cmake_convention_no_cmake_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "CMakeLists.txt",
      "cmake_minimum_required(VERSION 3.20)\n" &
      "project(hello LANGUAGES C)\n" &
      "add_executable(hello src/main.c)\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeCmakeNoCMakeInUses:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = cmake_convention.cCppCMakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declared":
    let scratch = getTempDir() / "test_c_cpp_cmake_convention_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "CMakeLists.txt",
      "cmake_minimum_required(VERSION 3.20)\n" &
      "project(hello LANGUAGES C)\n" &
      "add_executable(hello src/main.c)\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeCmakeNoMember:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"cmake >=3.20\"\n")
    defer:
      removeDir(scratch)
    let conv = cmake_convention.cCppCMakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: hello-binary fixture produces configure + build actions":
    if not cmakeToolchainReady():
      skip()
    else:
      let conv = cmake_convention.cCppCMakeConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var configureActions: seq[BuildActionDef] = @[]
      var buildActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "ccpp-cmake-configure":
          configureActions.add(action)
        elif action.id.startsWith("ccpp-cmake-build-"):
          buildActions.add(action)

      check configureActions.len == 1
      check buildActions.len >= 1

      # The configure action's argv mentions ``-S`` and ``-B`` plus
      # the ``-G`` generator flag. When ``sh`` is on PATH the
      # convention wraps the cmake invocation in ``sh -c <script>``;
      # otherwise it issues cmake directly. Search both shapes.
      let configureArgv = inlineArgvOf(configureActions[0])
      let argvJoined = configureArgv.join(" ")
      check argvJoined.contains(" -S ") or argvJoined.contains("\"-S\"") or
            argvJoined.contains("-S \"")
      check argvJoined.contains(" -B ") or argvJoined.contains("\"-B\"") or
            argvJoined.contains("-B \"")
      check argvJoined.contains(" -G ") or argvJoined.contains("\"-G\"") or
            argvJoined.contains("-G \"")
      check configureActions[0].pool == "compile"

      # The build action for ``hello`` depends on the configure action
      # and declares the predicted executable output path.
      var helloBuild: BuildActionDef
      var foundHello = false
      for a in buildActions:
        if a.id == "ccpp-cmake-build-hello":
          helloBuild = a
          foundHello = true
          break
      check foundHello
      check helloBuild.deps == @["ccpp-cmake-configure"]
      var sawBinary = false
      for outPath in helloBuild.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if ".repro/build/cmake/" in lower and
            (lower.endsWith("/hello") or lower.endsWith("/hello.exe")):
          sawBinary = true
      check sawBinary

      # cmake --build argv: cmake, "--build", "<scratch>", "--target", "hello"
      let buildArgv = inlineArgvOf(helloBuild)
      var sawBuildFlag = false
      var sawTargetFlag = false
      var sawHello = false
      for token in buildArgv:
        if token == "--build": sawBuildFlag = true
        elif token == "--target": sawTargetFlag = true
        elif token == "hello": sawHello = true
      check sawBuildFlag
      check sawTargetFlag
      check sawHello

  test "M9.K: cmakeFlags injection retired (M9.R.6.1)":
    # M9.R.6.1 (2026-06-19): the ``registeredBuildFlags`` runtime
    # registry + the ``cmakeFlags:`` parser arm were retired. Recipes
    # route per-tool options through their explicit ``build:`` body
    # calling ``cmake_package(...)`` directly. This assertion documents
    # the retirement at compile time.
    check not compiles((proc (): seq[string] =
      result = registeredBuildFlags("m9kCmakePkg", "", "cmake"))())

  test "emitFragment: build actions carry toolIdentityRefs (M9.N Batch B)":
    # M9.N Batch B: every action carries the list of catalog tool refs
    # the engine resolves at fork time. The configure action lists the
    # build-system + compiler + sh; the build action lists the build-
    # system + compiler. The assertion runs regardless of whether the
    # host has cmake / ninja / gcc installed because the convention's
    # new ``toolIdentityRefs`` are pure compile-time tags.
    let conv = cmake_convention.cCppCMakeConvention()
    let request = dummyRequest(HelloBinaryFixture)
    require conv.recognize(HelloBinaryFixture, request)
    let fragment = conv.emitFragment(HelloBinaryFixture, request)
    var sawConfigureRefs = false
    var sawBuildRefs = false
    for node in fragment.nodes:
      if node.kind != gnkAction:
        continue
      let action = decodeBuildActionPayload(toBytes(node.payload))
      if action.id == "ccpp-cmake-configure":
        check "cmake" in action.toolIdentityRefs
        check "ninja" in action.toolIdentityRefs
        check "gcc" in action.toolIdentityRefs
        check "sh" in action.toolIdentityRefs
        sawConfigureRefs = true
      elif action.id.startsWith("ccpp-cmake-build-"):
        check "cmake" in action.toolIdentityRefs
        check "ninja" in action.toolIdentityRefs
        check "gcc" in action.toolIdentityRefs
        sawBuildRefs = true
    check sawConfigureRefs
    check sawBuildRefs
