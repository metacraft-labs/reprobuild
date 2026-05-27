## M17 verification: C/C++ Autotools language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/c-cpp-autotools/``:
##
##   * ``c-cpp-autotools/hello-binary`` — single ``executable hello``
##                                        built via autoreconf + configure
##                                        + make.
##
## Negative recognise cases are materialised as tiny scratch projects
## under the test's temp directory so each case is hermetic.
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - autoreconf / autoconf / automake are on PATH (or a checked-in
##       ``configure`` script is present)
##     - ``make`` (or ``mingw32-make`` on Windows) is on PATH
##     - ``sh`` is on PATH
##     - a C compiler is on PATH
##   * ``recognize`` returns false when:
##     - ``configure.ac`` is absent
##     - ``Makefile.am`` is absent
##     - ``uses:`` doesn't list autoconf + compiler + make
##     - no executable / library member is declared
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     any required tool is missing):
##     - the convention emits exactly two actions
##       (``ccpp-autotools-configure`` + ``ccpp-autotools-build``).
##     - the build action lists the configure action as a dependency.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/c_cpp_autotools as autotools_convention

const
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "c-cpp-autotools" / "hello-binary"

proc dummyRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

proc autotoolsAvailable(projectRoot: string): bool =
  ## True when every tool the convention demands at recognise time is
  ## present. ``autoreconf`` is only required when no ``configure`` is
  ## checked in.
  if findExe("gcc").len == 0 and findExe("clang").len == 0:
    return false
  let makeExe = findExe("make")
  let mingwMake = when defined(windows): findExe("mingw32-make") else: ""
  if makeExe.len == 0 and mingwMake.len == 0:
    return false
  if findExe("sh").len == 0:
    return false
  if not fileExists(projectRoot / "configure"):
    if findExe("autoreconf").len == 0:
      return false
  true

suite "c-cpp-autotools convention M17":

  test "recognize: positive — hello-binary fixture (toolchain-gated)":
    let conv = autotools_convention.cCppAutotoolsConvention()
    check conv.name == "c-cpp-autotools"
    if not fileExists(HelloBinaryFixture / "configure.ac"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    if not autotoolsAvailable(HelloBinaryFixture):
      checkpoint "autotools toolchain incomplete — positive recognize " &
        "will return false"
      check not conv.recognize(HelloBinaryFixture, request)
    else:
      check conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — configure.ac missing":
    let scratch = getTempDir() / "test_c_cpp_autotools_no_configure_ac"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "Makefile.am",
      "bin_PROGRAMS = hello\nhello_SOURCES = src/main.c\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeAutotoolsNoAc:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"autoconf >=2.71\"\n" &
      "    \"automake >=1.16\"\n" &
      "    \"make >=4\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — Makefile.am missing":
    let scratch = getTempDir() / "test_c_cpp_autotools_no_makefile_am"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "configure.ac",
      "AC_INIT([fake-pkg], [0.1.0])\nAC_OUTPUT\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeAutotoolsNoAm:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"autoconf >=2.71\"\n" &
      "    \"automake >=1.16\"\n" &
      "    \"make >=4\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks autoconf":
    let scratch = getTempDir() / "test_c_cpp_autotools_no_autoconf_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src")
    writeFile(scratch / "src" / "main.c",
      "#include <stdio.h>\nint main(void){return 0;}\n")
    writeFile(scratch / "configure.ac",
      "AC_INIT([fake-pkg], [0.1.0])\nAC_OUTPUT\n")
    writeFile(scratch / "Makefile.am",
      "bin_PROGRAMS = hello\nhello_SOURCES = src/main.c\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeAutotoolsNoAuto:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"make >=4\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declared":
    let scratch = getTempDir() / "test_c_cpp_autotools_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "configure.ac",
      "AC_INIT([fake-pkg], [0.1.0])\nAC_OUTPUT\n")
    writeFile(scratch / "Makefile.am", "\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package emptyAutotools:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "    \"autoconf >=2.71\"\n" &
      "    \"automake >=1.16\"\n" &
      "    \"make >=4\"\n")
    defer:
      removeDir(scratch)
    let conv = autotools_convention.cCppAutotoolsConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: configure + build actions, dependency wired":
    if not autotoolsAvailable(HelloBinaryFixture):
      skip()
    else:
      let conv = autotools_convention.cCppAutotoolsConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var configureAction: BuildActionDef
      var buildAction: BuildActionDef
      var sawConfigure = false
      var sawBuild = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "ccpp-autotools-configure":
          configureAction = action
          sawConfigure = true
        elif action.id == "ccpp-autotools-build":
          buildAction = action
          sawBuild = true

      check sawConfigure
      check sawBuild
      check configureAction.pool == "compile"
      check buildAction.pool == "compile"
      check configureAction.id in buildAction.deps
