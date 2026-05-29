## M39 verification: C/C++ Meson (Tier 2b) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/c-cpp-meson/hello-binary/`` plus scratch
## projects materialised in the test's temp directory.
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - meson is on PATH
##     - ninja is on PATH
##     - a C compiler is on PATH
##   * ``recognize`` returns false when:
##     - ``meson.build`` is absent
##     - ``CMakeLists.txt`` is present at the root (CMake's territory —
##       defensive bidirectional rejection)
##     - ``configure.ac`` is present at the root (Autotools' territory)
##     - ``uses:`` doesn't list meson + a C compiler
##     - no executable / library member is declared
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     toolchain is missing):
##     - the convention emits a ``ccpp-meson-configure`` action.
##     - the convention emits a ``ccpp-meson-build-hello`` action that
##       depends on the configure action and declares an executable
##       output under ``.repro/build/meson/``.
##     - the configure action's argv carries ``meson setup`` (plus the
##       scratch dir and project root), and the build action's argv
##       carries ``meson compile -C <scratch> hello``.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/c_cpp_meson as meson_convention

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_c_cpp_meson_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to the
  ## sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "c-cpp-meson" / "hello-binary"

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

proc mesonToolchainReady(): bool =
  ## True when meson + ninja + a C compiler are all on PATH.
  if findExe("meson").len == 0:
    return false
  if findExe("ninja").len == 0:
    return false
  if findExe("gcc").len == 0 and findExe("clang").len == 0:
    return false
  true

suite "c-cpp-meson convention M39":

  test "recognize: positive — hello-binary fixture (toolchain-gated)":
    let conv = meson_convention.cCppMesonConvention()
    check conv.name == "c-cpp-meson"
    if not fileExists(HelloBinaryFixture / "meson.build"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    if mesonToolchainReady():
      check conv.recognize(HelloBinaryFixture, request)
    else:
      checkpoint "meson toolchain unavailable — recognize must be false"
      check not conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — meson.build missing":
    let scratch = getTempDir() / "test_c_cpp_meson_convention_no_meson_build"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){puts(\"x\");return 0;}\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeMesonNoMesonBuild:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"meson >=1.3\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = meson_convention.cCppMesonConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — CMakeLists.txt at root (CMake's territory)":
    let scratch = getTempDir() / "test_c_cpp_meson_convention_cmake_present"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "meson.build",
      "project('hello', 'c')\n" &
      "executable('hello', 'src/main.c')\n")
    writeFile(scratch / "CMakeLists.txt",
      "cmake_minimum_required(VERSION 3.20)\n" &
      "project(hello LANGUAGES C)\n" &
      "add_executable(hello src/main.c)\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeCmakeMeson:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"meson >=1.3\"\n" &
      "    \"cmake >=3.20\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = meson_convention.cCppMesonConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — configure.ac at root (Autotools' territory)":
    let scratch = getTempDir() / "test_c_cpp_meson_convention_autotools_present"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "meson.build",
      "project('hello', 'c')\n" &
      "executable('hello', 'src/main.c')\n")
    writeFile(scratch / "configure.ac",
      "AC_INIT([fake-autotools], [0.1.0])\nAC_OUTPUT\n")
    writeFile(scratch / "Makefile.am",
      "bin_PROGRAMS = hello\nhello_SOURCES = src/main.c\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeAutotoolsMeson:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"meson >=1.3\"\n" &
      "    \"autoconf >=2.71\"\n" &
      "    \"automake >=1.16\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = meson_convention.cCppMesonConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks meson":
    let scratch = getTempDir() / "test_c_cpp_meson_convention_no_meson_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "meson.build",
      "project('hello', 'c')\n" &
      "executable('hello', 'src/main.c')\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeMesonNoMesonInUses:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = meson_convention.cCppMesonConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declared":
    let scratch = getTempDir() / "test_c_cpp_meson_convention_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "meson.build",
      "project('hello', 'c')\n" &
      "executable('hello', 'src/main.c')\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeMesonNoMember:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"meson >=1.3\"\n")
    defer:
      removeDir(scratch)
    let conv = meson_convention.cCppMesonConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: hello-binary fixture produces configure + build actions":
    if not mesonToolchainReady():
      skip()
    else:
      let conv = meson_convention.cCppMesonConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var configureActions: seq[BuildActionDef] = @[]
      var buildActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "ccpp-meson-configure":
          configureActions.add(action)
        elif action.id.startsWith("ccpp-meson-build-"):
          buildActions.add(action)

      check configureActions.len == 1
      check buildActions.len >= 1

      # The configure action's argv carries ``meson setup`` (when the
      # convention wraps it in ``sh -c``, the script body holds the
      # tokens; when not, the bare argv does). Check both shapes.
      let configureArgv = inlineArgvOf(configureActions[0])
      let argvJoined = configureArgv.join(" ")
      check argvJoined.contains("meson")
      check argvJoined.contains("setup")
      check argvJoined.contains("--buildtype=release")
      check argvJoined.contains("--backend=ninja")
      check configureActions[0].pool == "compile"

      # The build action for ``hello`` depends on the configure action
      # and declares the predicted executable output path under
      # ``.repro/build/meson/``.
      var helloBuild: BuildActionDef
      var foundHello = false
      for a in buildActions:
        if a.id == "ccpp-meson-build-hello":
          helloBuild = a
          foundHello = true
          break
      check foundHello
      check helloBuild.deps == @["ccpp-meson-configure"]
      var sawBinary = false
      for outPath in helloBuild.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if ".repro/build/meson/" in lower and
            (lower.endsWith("/hello") or lower.endsWith("/hello.exe")):
          sawBinary = true
      check sawBinary

      # meson compile argv: meson, "compile", "-C", "<scratch>", "hello"
      let buildArgv = inlineArgvOf(helloBuild)
      var sawCompileVerb = false
      var sawCFlag = false
      var sawHello = false
      for token in buildArgv:
        if token == "compile": sawCompileVerb = true
        elif token == "-C": sawCFlag = true
        elif token == "hello": sawHello = true
      check sawCompileVerb
      check sawCFlag
      check sawHello

  test "emitFragment: configure action's argv pins CC for compiler discovery":
    # M39: the convention pins ``CC=<ccExe>`` via the sh wrapper so
    # meson's compiler auto-detection (which probes ``cc`` first) lands
    # on the convention's resolved compiler — not a stray ``cc.exe`` on
    # PATH from an unrelated dev-deps install. This guard catches a
    # regression where the convention drops the ``CC=...`` pin.
    if not mesonToolchainReady():
      skip()
    elif findExe("sh").len == 0:
      # The CC pin only applies on the sh-wrapped path; the no-sh
      # fallback intentionally skips it.
      skip()
    else:
      let conv = meson_convention.cCppMesonConvention()
      let request = dummyRequest(HelloBinaryFixture)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)
      var sawCcPin = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id != "ccpp-meson-configure":
          continue
        let configureArgv = inlineArgvOf(action)
        for token in configureArgv:
          if token.contains("export CC="):
            sawCcPin = true
      check sawCcPin
