## Verification for the ada-direct (Mode 3) language convention (M58).
##
## Coverage:
##   * ``recognize`` returns true for the Mode 3 fixture when
##     ``gnatmake`` is on PATH.
##   * ``recognize`` returns false when a ``*.gpr`` is at the workspace
##     root (the future Mode 2 Ada convention's territory).
##   * ``recognize`` returns false when ``uses:`` lacks an Ada toolchain
##     token.
##   * ``recognize`` returns false when no executable / library
##     members are declared.
##   * ``emitFragment`` against the pure-Ada Mode 3 fixture emits
##     per-member ``gcc -c -gnatp`` + ``ar rcs`` for libraries and
##     ``gnatmake`` for executables wired by the workspace
##     ``depends_on`` graph:
##       - The library archive lands at ``libadalib.a`` under the
##         scratch dir.
##       - The executable link action's ``deps`` include the archive
##         action's id.
##       - The executable link action's ``inputs`` include the
##         upstream archive path (cache invalidation).
##       - The executable link argv carries the upstream archive
##         after the ``-largs`` separator (gnatmake linker pass-through).
##   * Forward cross-language: an Ada binary depends on a C library —
##     the convention emits both directions' actions and threads the
##     C archive onto the ``gnatmake`` argv after ``-largs``.
##   * Reverse cross-language: a C++ binary depends on an Ada library —
##     the convention emits the Ada library AND the C++ binary's
##     per-source compile + terminal link with the archive on the
##     link line.
##   * cycle detection: a scratch fixture with cross-package cycles
##     rejects with a descriptive ValueError.
##   * undeclared-dep detection: a depends_on references an undeclared
##     package — rejected.
##   * cConsumable toggle: when a C/C++ executable in the workspace
##     depends on an Ada library's package, the library's archive is
##     wired onto the C++ link argv.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/ada_direct as ada_direct_convention

const
  ## ``parentDir`` four times lands at the ``reprobuild/`` repo root.
  ## The fixture lives under the sibling ``reprobuild-examples``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  Mode3Fixture =
    MetacraftRoot / "reprobuild-examples" / "ada-mode3" /
      "binary-with-library"
  Mode3MixedForwardFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "ada-uses-cpp-lib"
  Mode3MixedReverseFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "cpp-uses-ada-lib"

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

proc gnatmakeOnPath(): bool =
  findExe("gnatmake").len > 0

proc gccOnPath(): bool =
  findExe("gcc").len > 0 or findExe("clang").len > 0

proc gppOnPath(): bool =
  findExe("g++").len > 0 or findExe("clang++").len > 0

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-ada-direct-test-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "ada-direct convention recognition":

  test "recognize: positive — Mode 3 fixture (no *.gpr, gnatmake on PATH)":
    if not gnatmakeOnPath():
      skip()
    else:
      let conv = ada_direct_convention.adaDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      check conv.recognize(Mode3Fixture, request)

  test "recognize: negative — *.gpr at project root":
    let dir = makeScratch("with-gpr")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "gnatmake"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.adb",
      "procedure Main is\nbegin\n   null;\nend Main;\n")
    writeFile(dir / "hello.gpr",
      "project Hello is\n   for Source_Dirs use (\"src\");\nend Hello;\n")
    let conv = ada_direct_convention.adaDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — uses lacks Ada":
    let dir = makeScratch("no-ada-toolchain")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.adb",
      "procedure Main is\nbegin\n   null;\nend Main;\n")
    let conv = ada_direct_convention.adaDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — no Ada members declared":
    if not gnatmakeOnPath():
      skip()
    else:
      let dir = makeScratch("no-members")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "gnatmake"
""")
      let conv = ada_direct_convention.adaDirectConvention()
      let request = dummyRequest(dir)
      check not conv.recognize(dir, request)
      removeDir(dir)

  test "recognize: positive — accepts ``ada`` token in uses":
    if not gnatmakeOnPath():
      skip()
    else:
      let dir = makeScratch("ada-token")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "ada"
  executable hello:
    discard
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.adb",
        "procedure Main is\nbegin\n   null;\nend Main;\n")
      let conv = ada_direct_convention.adaDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

  test "recognize: positive — accepts ``gnat`` token in uses":
    if not gnatmakeOnPath():
      skip()
    else:
      let dir = makeScratch("gnat-token")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "gnat"
  executable hello:
    discard
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.adb",
        "procedure Main is\nbegin\n   null;\nend Main;\n")
      let conv = ada_direct_convention.adaDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

suite "ada-direct convention emit (Mode 3 fixture)":

  test "emitFragment: per-member gcc -c + ar rcs + gnatmake link":
    if not gnatmakeOnPath():
      skip()
    else:
      let conv = ada_direct_convention.adaDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)

      var adalibArchiveAction: BuildActionDef
      var adacalcLinkAction: BuildActionDef
      var sawAdalibArchive = false
      var sawAdalibCompile = false
      var sawAdacalc = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "ada-direct-archive-adalib":
          adalibArchiveAction = action
          sawAdalibArchive = true
        elif action.id == "ada-direct-link-adacalc":
          adacalcLinkAction = action
          sawAdacalc = true
        elif action.id.startsWith("ada-direct-compile-adalib"):
          sawAdalibCompile = true
      check sawAdalibArchive
      check sawAdalibCompile
      check sawAdacalc

      # The adalib output lands at .repro/build/adalib/libadalib.a.
      var adalibArchive = ""
      for outPath in adalibArchiveAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libadalib.a"):
          adalibArchive = outPath
      check adalibArchive.len > 0

      # The archive argv invokes ``ar rcs``.
      let archiveArgv = inlineArgvOf(adalibArchiveAction)
      var sawArAction = false
      var sawRcsFlag = false
      for token in archiveArgv:
        if token.endsWith("ar") or token.endsWith("ar.exe"):
          sawArAction = true
        elif token == "rcs":
          sawRcsFlag = true
      check sawArAction
      check sawRcsFlag

      # The adacalc argv carries gnatmake + -O2 + -o + the entry source.
      let adacalcArgv = inlineArgvOf(adacalcLinkAction)
      var sawGnatmake = false
      var sawOptFlag = false
      var sawOFlag = false
      for token in adacalcArgv:
        if token.toLowerAscii.endsWith("gnatmake") or
            token.toLowerAscii.endsWith("gnatmake.exe"):
          sawGnatmake = true
        elif token == "-O2":
          sawOptFlag = true
        elif token == "-o":
          sawOFlag = true
      check sawGnatmake
      check sawOptFlag
      check sawOFlag

      # The adacalc action's deps include the adalib archive action id.
      var sawAdalibDep = false
      for dep in adacalcLinkAction.deps:
        if dep == adalibArchiveAction.id:
          sawAdalibDep = true
      check sawAdalibDep

      # The adacalc action's inputs include the upstream archive.
      var sawAdalibInput = false
      for inp in adacalcLinkAction.inputs:
        if inp == adalibArchive:
          sawAdalibInput = true
      check sawAdalibInput

      # The adacalc argv carries the archive after -largs (gnatmake
      # linker pass-through).
      var sawLargsSeparator = false
      var archiveAfterLargs = false
      var seenLargs = false
      for token in adacalcArgv:
        if token == "-largs":
          sawLargsSeparator = true
          seenLargs = true
          continue
        if seenLargs and token == adalibArchive:
          archiveAfterLargs = true
      check sawLargsSeparator
      check archiveAfterLargs

suite "ada-direct convention dep validation":

  test "depends_on cycle is rejected before any compile fires":
    if not gnatmakeOnPath():
      skip()
    else:
      let dir = makeScratch("cycle")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "gnatmake"
  library alpha

package betaPkg:
  uses:
    "gnatmake"
  library beta

depends_on alphaPkg: betaPkg
depends_on betaPkg: alphaPkg
""")
      createDir(dir / "alpha" / "src")
      writeFile(dir / "alpha" / "src" / "lib.adb",
        "package body Lib is\nend Lib;\n")
      writeFile(dir / "alpha" / "src" / "lib.ads",
        "package Lib is\nend Lib;\n")
      createDir(dir / "beta" / "src")
      writeFile(dir / "beta" / "src" / "lib.adb",
        "package body Lib is\nend Lib;\n")
      writeFile(dir / "beta" / "src" / "lib.ads",
        "package Lib is\nend Lib;\n")
      let conv = ada_direct_convention.adaDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

  test "depends_on references undeclared package — rejected":
    if not gnatmakeOnPath():
      skip()
    else:
      let dir = makeScratch("undeclared")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package onlyPkg:
  uses:
    "gnatmake"
  executable hello:
    discard

depends_on onlyPkg: nonexistentPkg
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.adb",
        "procedure Main is\nbegin\n   null;\nend Main;\n")
      let conv = ada_direct_convention.adaDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

# ---------------------------------------------------------------------------
# M58 cross-language Ada ↔ C/C++ verification.
# ---------------------------------------------------------------------------

suite "ada-direct convention M58 cross-language (forward direction)":

  test "forward: Ada binary picks up C archive after -largs":
    if not gnatmakeOnPath() or not gccOnPath():
      skip()
    elif not dirExists(Mode3MixedForwardFixture):
      skip()
    else:
      let conv = ada_direct_convention.adaDirectConvention()
      let request = dummyRequest(Mode3MixedForwardFixture)
      require conv.recognize(Mode3MixedForwardFixture, request)
      let fragment = conv.emitFragment(Mode3MixedForwardFixture, request)

      var archiveAction: BuildActionDef
      var adacalcAction: BuildActionDef
      var sawArchive = false
      var sawAdacalc = false
      var sawCompile = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "ada-xlang-ccpp-archive-mathlib":
          archiveAction = action
          sawArchive = true
        elif action.id == "ada-direct-link-adacalc":
          adacalcAction = action
          sawAdacalc = true
        elif action.id.startsWith("ada-xlang-ccpp-compile-mathlib"):
          sawCompile = true

      check sawArchive
      check sawAdacalc
      check sawCompile

      # The archive output lands at .repro/build/mathlib/libmathlib.a.
      var archiveOutput = ""
      for outPath in archiveAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libmathlib.a"):
          archiveOutput = outPath
      check archiveOutput.len > 0

      # The adacalc action's deps include the archive action id.
      var sawArchiveDep = false
      for dep in adacalcAction.deps:
        if dep == archiveAction.id:
          sawArchiveDep = true
      check sawArchiveDep

      # The adacalc action's inputs include the upstream archive.
      var sawArchiveInput = false
      for inp in adacalcAction.inputs:
        if inp == archiveOutput:
          sawArchiveInput = true
      check sawArchiveInput

      # The adacalc argv carries the archive after -largs.
      let adacalcArgv = inlineArgvOf(adacalcAction)
      var sawLargs = false
      var archiveAfterLargs = false
      for token in adacalcArgv:
        if token == "-largs":
          sawLargs = true
          continue
        if sawLargs and token == archiveOutput:
          archiveAfterLargs = true
      check sawLargs
      check archiveAfterLargs

suite "ada-direct convention M58 cross-language (reverse direction)":

  test "reverse: C++ binary picks up Ada archive as trailing positional":
    if not gnatmakeOnPath() or not gppOnPath():
      skip()
    elif not dirExists(Mode3MixedReverseFixture):
      skip()
    else:
      let conv = ada_direct_convention.adaDirectConvention()
      let request = dummyRequest(Mode3MixedReverseFixture)
      require conv.recognize(Mode3MixedReverseFixture, request)
      let fragment = conv.emitFragment(Mode3MixedReverseFixture, request)

      var adaaddlibArchiveAction: BuildActionDef
      var cppappLinkAction: BuildActionDef
      var sawAdaaddlibArchive = false
      var sawCppLink = false
      var sawCppCompile = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "ada-direct-archive-adaaddlib":
          adaaddlibArchiveAction = action
          sawAdaaddlibArchive = true
        elif action.id == "ada-xlang-ccpp-exec-link-cppapp":
          cppappLinkAction = action
          sawCppLink = true
        elif action.id.startsWith("ada-xlang-ccpp-exec-compile-cppapp"):
          sawCppCompile = true
      check sawAdaaddlibArchive
      check sawCppLink
      check sawCppCompile

      # The adaaddlib output lands at the canonical archive path
      # .repro/build/adaaddlib/libadaaddlib.a (shared schema with
      # c-cpp-direct, Rust staticlib, Fortran archive, Zig archive,
      # D archive).
      var adaaddlibOutput = ""
      for outPath in adaaddlibArchiveAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libadaaddlib.a"):
          adaaddlibOutput = outPath
      check adaaddlibOutput.len > 0

      # The cppapp link action's deps include the adaaddlib archive
      # action id.
      var sawAdaaddlibDep = false
      for dep in cppappLinkAction.deps:
        if dep == adaaddlibArchiveAction.id:
          sawAdaaddlibDep = true
      check sawAdaaddlibDep

      # The cppapp link action's inputs include the upstream archive.
      var sawAdaaddlibInput = false
      for inp in cppappLinkAction.inputs:
        if inp == adaaddlibOutput:
          sawAdaaddlibInput = true
      check sawAdaaddlibInput

      # The cppapp link argv carries the archive as a trailing
      # positional. The M58 honest-scope cut limits the reverse fixture
      # to ``pragma Export (C, ...)`` no-elaboration entry points so the
      # gcc driver resolves all references against the Ada archive
      # itself without external runtime libs.
      let cppappArgv = inlineArgvOf(cppappLinkAction)
      var sawArchive = false
      for token in cppappArgv:
        if token == adaaddlibOutput:
          sawArchive = true
      check sawArchive

suite "ada-direct convention M58 cConsumable toggle":

  test "pure-Ada fixture: library archive emitted at canonical path":
    if not gnatmakeOnPath():
      skip()
    else:
      let conv = ada_direct_convention.adaDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)
      var adalibAction: BuildActionDef
      var sawAdalib = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "ada-direct-archive-adalib":
          adalibAction = action
          sawAdalib = true
      check sawAdalib
      # The output lands at libadalib.a regardless of cConsumable.
      var sawArchiveOutput = false
      for outPath in adalibAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libadalib.a"):
          sawArchiveOutput = true
      check sawArchiveOutput
