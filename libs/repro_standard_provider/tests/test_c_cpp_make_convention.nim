## M17 verification: C/C++ Make language convention.
##
## Tests against the in-tree fixtures under
## ``reprobuild-examples/c-cpp-make/``:
##
##   * ``c-cpp-make/binary``         — single ``executable hello`` built
##                                     from ``src/main.c`` via a hand-
##                                     written Makefile.
##   * ``c-cpp-make/library-static`` — single ``library greet`` built
##                                     to ``libgreet.a``.
##
## Negative recognise cases are materialised as tiny scratch projects
## under the test's temp directory so each case is hermetic.
##
## Coverage:
##   * ``recognize`` returns true for:
##     - the ``c-cpp-make/binary`` fixture (with gcc on PATH).
##     - the ``c-cpp-make/library-static`` fixture (with gcc on PATH).
##   * ``recognize`` returns false when:
##     - no root-level Makefile exists.
##     - ``CMakeLists.txt`` is present at the root (CMake's territory).
##     - ``configure.ac`` is present at the root (Autotools' territory).
##     - ``uses:`` doesn't list a compiler + ``make``.
##     - no executable / library member is declared.
##   * ``emitFragment`` against the ``binary`` fixture (skipped when gcc
##     isn't on PATH):
##     - at least one ``ccpp-make-compile-*`` action and one
##       ``ccpp-make-link-*`` action exist.
##     - the link action declares an executable output under the
##       convention's scratch dir.
##   * ``emitFragment`` against the ``library-static`` fixture (skipped
##     when gcc isn't on PATH):
##     - the convention emits a ``ccpp-make-archive-*`` action with a
##       ``lib<name>.a`` output.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/c_cpp_make as c_cpp_make_convention

const
  ## ``parentDir`` four times from
  ## ``libs/repro_standard_provider/tests/test_c_cpp_make_convention.nim``
  ## lands at the ``reprobuild/`` repo root. The fixture lives in the
  ## sibling ``reprobuild-examples`` checkout under ``D:/metacraft/``,
  ## so take one more parent.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  BinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "c-cpp-make" / "binary"
  LibraryStaticFixture =
    MetacraftRoot / "reprobuild-examples" / "c-cpp-make" / "library-static"

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

proc gccOnPath(): bool =
  ## True when either ``gcc`` or ``clang`` resolves. The convention's
  ## ``recognize`` short-circuits to ``false`` when neither resolves, so
  ## the emit-fragment tests skip cleanly in environments without a C
  ## compiler.
  findExe("gcc").len > 0 or findExe("clang").len > 0

suite "c-cpp-make convention M17":

  test "recognize: positive — binary fixture (declaration-only)":
    # M9.N: recognise claims a recipe based on DECLARATION (Makefile at
    # projectRoot + uses: gcc/clang + executable/library member +
    # per-source resolution), NOT host PATH availability. Tool identity
    # is resolved AFTER recognise by the engine.
    let conv = c_cpp_make_convention.cCppMakeConvention()
    check conv.name == "c-cpp-make"
    if not fileExists(BinaryFixture / "Makefile"):
      checkpoint "fixture missing — looked at " & BinaryFixture
      fail()
    let request = dummyRequest(BinaryFixture)
    check conv.recognize(BinaryFixture, request)

  test "recognize: positive — library-static fixture (declaration-only)":
    let conv = c_cpp_make_convention.cCppMakeConvention()
    if not fileExists(LibraryStaticFixture / "Makefile"):
      checkpoint "fixture missing — looked at " & LibraryStaticFixture
      fail()
    let request = dummyRequest(LibraryStaticFixture)
    check conv.recognize(LibraryStaticFixture, request)

  test "recognize: returns true even without C compiler on PATH (M9.N)":
    # M9.N architectural correction: explicit assertion that the
    # host-PATH gate has been dropped from recognise — the convention
    # claims the recipe regardless of whether gcc/clang resolve.
    let conv = c_cpp_make_convention.cCppMakeConvention()
    if not fileExists(BinaryFixture / "Makefile"):
      checkpoint "fixture missing — looked at " & BinaryFixture
      fail()
    let request = dummyRequest(BinaryFixture)
    checkpoint "C compiler on PATH: " & $gccOnPath()
    check conv.recognize(BinaryFixture, request)

  test "recognize: negative — Makefile missing":
    let scratch = getTempDir() / "test_c_cpp_make_convention_no_makefile"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){puts(\"x\");return 0;}\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeCcMake:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"make >=4\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = c_cpp_make_convention.cCppMakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — CMakeLists.txt at root":
    let scratch = getTempDir() / "test_c_cpp_make_convention_cmake"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "Makefile",
      "all: hello\nhello: src/main.o\n\t$(CC) -o $@ $^\n" &
      "src/main.o: src/main.c\n\t$(CC) -c -o $@ $<\n")
    writeFile(scratch / "CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeCmakeCm:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"make >=4\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = c_cpp_make_convention.cCppMakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — configure.ac at root (Autotools' territory)":
    let scratch = getTempDir() / "test_c_cpp_make_convention_autotools"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "Makefile",
      "all: hello\nhello: src/main.o\n\t$(CC) -o $@ $^\n" &
      "src/main.o: src/main.c\n\t$(CC) -c -o $@ $<\n")
    writeFile(scratch / "configure.ac",
      "AC_INIT([fake-autotools], [0.1.0])\nAC_OUTPUT\n")
    writeFile(scratch / "Makefile.am", "bin_PROGRAMS = hello\nhello_SOURCES = src/main.c\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeAutotools:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"make >=4\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = c_cpp_make_convention.cCppMakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks make":
    let scratch = getTempDir() / "test_c_cpp_make_convention_no_make_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "Makefile",
      "all: hello\nhello: src/main.o\n\t$(CC) -o $@ $^\n" &
      "src/main.o: src/main.c\n\t$(CC) -c -o $@ $<\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeNoMake:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = c_cpp_make_convention.cCppMakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declared":
    let scratch = getTempDir() / "test_c_cpp_make_convention_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "Makefile",
      "all: hello\nhello: src/main.o\n\t$(CC) -o $@ $^\n" &
      "src/main.o: src/main.c\n\t$(CC) -c -o $@ $<\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package emptyMake:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"make >=4\"\n")
    defer:
      removeDir(scratch)
    let conv = c_cpp_make_convention.cCppMakeConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: binary fixture produces compile + link actions":
    if not gccOnPath():
      skip()
    else:
      let conv = c_cpp_make_convention.cCppMakeConvention()
      let request = dummyRequest(BinaryFixture)
      require conv.recognize(BinaryFixture, request)
      let fragment = conv.emitFragment(BinaryFixture, request)

      var compileActions: seq[BuildActionDef] = @[]
      var linkActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("ccpp-make-compile-"):
          compileActions.add(action)
        elif action.id.startsWith("ccpp-make-link-"):
          linkActions.add(action)

      check compileActions.len >= 1
      check linkActions.len == 1

      # The compile action's argv carries ``-c`` and a depfile flag.
      let compileArgv = inlineArgvOf(compileActions[0])
      var sawDashC = false
      var sawMD = false
      for token in compileArgv:
        if token == "-c":
          sawDashC = true
        elif token == "-MD":
          sawMD = true
      check sawDashC
      check sawMD
      check compileActions[0].pool == "compile"

      # The link action declares an executable output under the scratch
      # dir.
      var sawBinary = false
      for outPath in linkActions[0].outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if ".repro/build/" in lower and
           (lower.endsWith("/hello") or lower.endsWith("/hello.exe")):
          sawBinary = true
      check sawBinary

  test "emitFragment: library-static fixture produces archive action":
    if not gccOnPath():
      skip()
    else:
      let conv = c_cpp_make_convention.cCppMakeConvention()
      let request = dummyRequest(LibraryStaticFixture)
      require conv.recognize(LibraryStaticFixture, request)
      let fragment = conv.emitFragment(LibraryStaticFixture, request)

      var archiveActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("ccpp-make-archive-"):
          archiveActions.add(action)
      check archiveActions.len == 1

      # The archive action declares a ``lib<name>.a`` output under the
      # scratch dir.
      var sawArchive = false
      for outPath in archiveActions[0].outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if ".repro/build/" in lower and lower.endsWith("/libgreet.a"):
          sawArchive = true
      check sawArchive

      # The argv's first token is ``ar`` (or its absolute path) and the
      # second is ``rcs``.
      let argv = inlineArgvOf(archiveActions[0])
      check argv.len >= 2
      let arg0Base = extractFilename(argv[0]).toLowerAscii
      # `arDriver()` resolves the host's ar; accept plain `ar` plus
      # toolchain-prefixed variants (`llvm-ar`, `gcc-ar`,
      # `aarch64-linux-gnu-ar`, …) and the `.exe` suffix on Windows.
      check arg0Base == "ar" or arg0Base == "ar.exe" or
            arg0Base.endsWith("-ar") or arg0Base.endsWith("-ar.exe")
      check argv[1] == "rcs"

  test "M9.K: makeFlags appear in link action argv":
    # DSL-port M9.K: when the M9.I registry holds makeFlags for the
    # DSL package, ``emitFragment`` must inject them into the link
    # action's argv. The c-cpp-make convention does NOT invoke ``make``
    # itself — see the module docstring's "makeFlags" note — so the
    # pragmatic mapping is to append the registered tokens to the
    # ``gcc -o ...`` link command.
    if not gccOnPath():
      skip()
    else:
      # Read the fixture's recipe to pull the DSL package name so the
      # M9.K lookup key matches.
      let recipePath = BinaryFixture / "reprobuild.nim"
      let recipeSrc = if fileExists(recipePath): readFile(recipePath) else: ""
      var pkgName = ""
      for rawLine in recipeSrc.splitLines():
        let stripped = rawLine.strip()
        if stripped.startsWith("package"):
          let rest = stripped[len("package") .. ^1].strip()
          for ch in rest:
            if ch in {' ', '\t', ':', ','}: break
            pkgName.add(ch)
          if pkgName.len > 0:
            break
      check pkgName.len > 0
      resetDslPortBuildFlagState()
      registerBuildFlag(pkgName, "", "make", "-lm")
      registerBuildFlag(pkgName, "", "make", "-static")
      defer:
        resetDslPortBuildFlagState()
      let conv = c_cpp_make_convention.cCppMakeConvention()
      let request = dummyRequest(BinaryFixture)
      let fragment = conv.emitFragment(BinaryFixture, request)
      var sawLm = false
      var sawStatic = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if not action.id.startsWith("ccpp-make-link-"):
          continue
        let argvJoined = inlineArgvOf(action).join(" ")
        if argvJoined.contains("-lm"):
          sawLm = true
        if argvJoined.contains("-static"):
          sawStatic = true
      check sawLm
      check sawStatic

  test "emitFragment: build actions carry toolIdentityRefs (M9.N Batch B)":
    # M9.N Batch B: every emitted compile / link / archive action
    # stamps the catalog tool refs the engine resolves at fork time.
    let conv = c_cpp_make_convention.cCppMakeConvention()
    let request = dummyRequest(BinaryFixture)
    require conv.recognize(BinaryFixture, request)
    let fragment = conv.emitFragment(BinaryFixture, request)
    var sawCompileRefs = false
    var sawLinkRefs = false
    for node in fragment.nodes:
      if node.kind != gnkAction:
        continue
      let action = decodeBuildActionPayload(toBytes(node.payload))
      if action.id.startsWith("ccpp-make-compile-"):
        check "gcc" in action.toolIdentityRefs
        sawCompileRefs = true
      elif action.id.startsWith("ccpp-make-link-"):
        check "gcc" in action.toolIdentityRefs
        sawLinkRefs = true
    check sawCompileRefs
    check sawLinkRefs
    # The library fixture's archive action references ``ar``.
    let libFragment = conv.emitFragment(LibraryStaticFixture,
      dummyRequest(LibraryStaticFixture))
    var sawArchiveRefs = false
    for node in libFragment.nodes:
      if node.kind != gnkAction:
        continue
      let action = decodeBuildActionPayload(toBytes(node.payload))
      if action.id.startsWith("ccpp-make-archive-"):
        check "ar" in action.toolIdentityRefs
        sawArchiveRefs = true
    check sawArchiveRefs
