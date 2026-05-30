## Verification for the pascal-direct (Mode 3) language convention (M59).
##
## Coverage:
##   * ``recognize`` returns true for the Mode 3 fixture when ``fpc``
##     is on PATH.
##   * ``recognize`` returns false when a ``*.lpi`` is at the workspace
##     root (the future Mode 2 Pascal convention's territory).
##   * ``recognize`` returns false when ``uses:`` lacks a Pascal
##     toolchain token.
##   * ``recognize`` returns false when no executable / library
##     members are declared.
##   * ``emitFragment`` against the pure-Pascal Mode 3 fixture emits
##     per-member ``fpc -O2 -CX`` + ``ar rcs`` for libraries and
##     ``fpc -O2 -o<bin>`` for executables wired by the workspace
##     ``depends_on`` graph:
##       - The library archive lands at ``libpascallib.a`` under the
##         scratch dir.
##       - The executable link action's ``deps`` include the archive
##         action's id.
##       - The executable link action's ``inputs`` include the
##         upstream archive path (cache invalidation).
##       - The executable link argv carries the upstream archive
##         after the ``-k`` linker pass-through.
##   * Forward cross-language: a Pascal binary depends on a C library —
##     the convention emits both directions' actions and threads the
##     C archive onto the ``fpc`` argv via ``-Fl<dir>`` + ``-k<archive>``.
##   * Reverse cross-language: a C++ binary depends on a Pascal library
##     — the convention emits the Pascal library AND the C++ binary's
##     per-source compile + terminal link with the archive on the link
##     line.
##   * cycle detection: a scratch fixture with cross-package cycles
##     rejects with a descriptive ValueError.
##   * undeclared-dep detection: a depends_on references an undeclared
##     package — rejected.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/pascal_direct as pascal_direct_convention

const
  ## ``parentDir`` four times lands at the ``reprobuild/`` repo root.
  ## The fixture lives under the sibling ``reprobuild-examples``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  Mode3Fixture =
    MetacraftRoot / "reprobuild-examples" / "pascal-mode3" /
      "binary-with-library"
  Mode3MixedForwardFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "pascal-uses-cpp-lib"
  Mode3MixedReverseFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "cpp-uses-pascal-lib"

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

proc fpcOnPath(): bool =
  findExe("fpc").len > 0

proc gccOnPath(): bool =
  findExe("gcc").len > 0 or findExe("clang").len > 0

proc gppOnPath(): bool =
  findExe("g++").len > 0 or findExe("clang++").len > 0

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-pascal-direct-test-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "pascal-direct convention recognition":

  test "recognize: positive — Mode 3 fixture (no *.lpi, fpc on PATH)":
    if not fpcOnPath():
      skip()
    elif not dirExists(Mode3Fixture):
      skip()
    else:
      let conv = pascal_direct_convention.pascalDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      check conv.recognize(Mode3Fixture, request)

  test "recognize: negative — *.lpi at project root":
    let dir = makeScratch("with-lpi")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "fpc"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.pas",
      "program Main;\nbegin\nend.\n")
    writeFile(dir / "hello.lpi",
      "<?xml version=\"1.0\"?>\n<CONFIG><ProjectOptions/></CONFIG>\n")
    let conv = pascal_direct_convention.pascalDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — uses lacks Pascal":
    let dir = makeScratch("no-pascal-toolchain")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.pas",
      "program Main;\nbegin\nend.\n")
    let conv = pascal_direct_convention.pascalDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — no Pascal members declared":
    if not fpcOnPath():
      skip()
    else:
      let dir = makeScratch("no-members")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "fpc"
""")
      let conv = pascal_direct_convention.pascalDirectConvention()
      let request = dummyRequest(dir)
      check not conv.recognize(dir, request)
      removeDir(dir)

  test "recognize: positive — accepts ``pascal`` token in uses":
    if not fpcOnPath():
      skip()
    else:
      let dir = makeScratch("pascal-token")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "pascal"
  executable hello:
    discard
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.pas",
        "program Main;\nbegin\nend.\n")
      let conv = pascal_direct_convention.pascalDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

  test "recognize: positive — accepts ``freepascal`` token in uses":
    if not fpcOnPath():
      skip()
    else:
      let dir = makeScratch("freepascal-token")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "freepascal"
  executable hello:
    discard
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.pas",
        "program Main;\nbegin\nend.\n")
      let conv = pascal_direct_convention.pascalDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

  test "recognize: positive — accepts .pp source extension":
    if not fpcOnPath():
      skip()
    else:
      let dir = makeScratch("pp-extension")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "fpc"
  executable hello:
    discard
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.pp",
        "program Main;\nbegin\nend.\n")
      let conv = pascal_direct_convention.pascalDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

suite "pascal-direct convention emit (Mode 3 fixture)":

  test "emitFragment: per-member fpc compile + ar rcs + fpc link":
    if not fpcOnPath():
      skip()
    elif not dirExists(Mode3Fixture):
      skip()
    else:
      let conv = pascal_direct_convention.pascalDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)

      var pascallibArchiveAction: BuildActionDef
      var pascalcalcLinkAction: BuildActionDef
      var sawPascallibArchive = false
      var sawPascallibCompile = false
      var sawPascalcalc = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "pascal-direct-archive-pascallib":
          pascallibArchiveAction = action
          sawPascallibArchive = true
        elif action.id == "pascal-direct-link-pascalcalc":
          pascalcalcLinkAction = action
          sawPascalcalc = true
        elif action.id.startsWith("pascal-direct-compile-pascallib"):
          sawPascallibCompile = true
      check sawPascallibArchive
      check sawPascallibCompile
      check sawPascalcalc

      # The pascallib output lands at .repro/build/pascallib/libpascallib.a.
      var pascallibArchive = ""
      for outPath in pascallibArchiveAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libpascallib.a"):
          pascallibArchive = outPath
      check pascallibArchive.len > 0

      # The archive argv invokes ``ar rcs``.
      let archiveArgv = inlineArgvOf(pascallibArchiveAction)
      var sawArAction = false
      var sawRcsFlag = false
      for token in archiveArgv:
        if token.endsWith("ar") or token.endsWith("ar.exe"):
          sawArAction = true
        elif token == "rcs":
          sawRcsFlag = true
      check sawArAction
      check sawRcsFlag

      # The pascalcalc argv carries fpc + -O2 + -o<bin>.
      let pascalcalcArgv = inlineArgvOf(pascalcalcLinkAction)
      var sawFpc = false
      var sawOptFlag = false
      var sawOFlag = false
      for token in pascalcalcArgv:
        if token.toLowerAscii.endsWith("fpc") or
            token.toLowerAscii.endsWith("fpc.exe"):
          sawFpc = true
        elif token == "-O2":
          sawOptFlag = true
        elif token.startsWith("-o") and token.len > 2:
          sawOFlag = true
      check sawFpc
      check sawOptFlag
      check sawOFlag

      # The pascalcalc action's deps include the pascallib archive
      # action id.
      var sawPascallibDep = false
      for dep in pascalcalcLinkAction.deps:
        if dep == pascallibArchiveAction.id:
          sawPascallibDep = true
      check sawPascallibDep

      # The pascalcalc action's inputs include the upstream archive.
      var sawPascallibInput = false
      for inp in pascalcalcLinkAction.inputs:
        if inp == pascallibArchive:
          sawPascallibInput = true
      check sawPascallibInput

      # The pascalcalc argv carries the archive via ``-k<archive>``
      # (fpc linker pass-through).
      var sawKFlag = false
      for token in pascalcalcArgv:
        if token == "-k" & pascallibArchive:
          sawKFlag = true
      check sawKFlag

suite "pascal-direct convention dep validation":

  test "depends_on cycle is rejected before any compile fires":
    if not fpcOnPath():
      skip()
    else:
      let dir = makeScratch("cycle")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "fpc"
  library alpha

package betaPkg:
  uses:
    "fpc"
  library beta

depends_on alphaPkg: betaPkg
depends_on betaPkg: alphaPkg
""")
      createDir(dir / "alpha" / "src")
      writeFile(dir / "alpha" / "src" / "lib.pas",
        "unit Lib;\ninterface\nimplementation\nend.\n")
      createDir(dir / "beta" / "src")
      writeFile(dir / "beta" / "src" / "lib.pas",
        "unit Lib;\ninterface\nimplementation\nend.\n")
      let conv = pascal_direct_convention.pascalDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

  test "depends_on references undeclared package — rejected":
    if not fpcOnPath():
      skip()
    else:
      let dir = makeScratch("undeclared")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package onlyPkg:
  uses:
    "fpc"
  executable hello:
    discard

depends_on onlyPkg: nonexistentPkg
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.pas",
        "program Main;\nbegin\nend.\n")
      let conv = pascal_direct_convention.pascalDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

# ---------------------------------------------------------------------------
# M59 cross-language Pascal ↔ C/C++ verification.
# ---------------------------------------------------------------------------

suite "pascal-direct convention M59 cross-language (forward direction)":

  test "forward: Pascal binary picks up C archive via -k linker pass-through":
    if not fpcOnPath() or not gccOnPath():
      skip()
    elif not dirExists(Mode3MixedForwardFixture):
      skip()
    else:
      let conv = pascal_direct_convention.pascalDirectConvention()
      let request = dummyRequest(Mode3MixedForwardFixture)
      require conv.recognize(Mode3MixedForwardFixture, request)
      let fragment = conv.emitFragment(Mode3MixedForwardFixture, request)

      var archiveAction: BuildActionDef
      var pascalcalcAction: BuildActionDef
      var sawArchive = false
      var sawPascalcalc = false
      var sawCompile = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "pascal-xlang-ccpp-archive-mathlib":
          archiveAction = action
          sawArchive = true
        elif action.id == "pascal-direct-link-pascalcalc":
          pascalcalcAction = action
          sawPascalcalc = true
        elif action.id.startsWith("pascal-xlang-ccpp-compile-mathlib"):
          sawCompile = true

      check sawArchive
      check sawPascalcalc
      check sawCompile

      # The archive output lands at .repro/build/mathlib/libmathlib.a.
      var archiveOutput = ""
      for outPath in archiveAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libmathlib.a"):
          archiveOutput = outPath
      check archiveOutput.len > 0

      # The pascalcalc action's deps include the archive action id.
      var sawArchiveDep = false
      for dep in pascalcalcAction.deps:
        if dep == archiveAction.id:
          sawArchiveDep = true
      check sawArchiveDep

      # The pascalcalc action's inputs include the upstream archive.
      var sawArchiveInput = false
      for inp in pascalcalcAction.inputs:
        if inp == archiveOutput:
          sawArchiveInput = true
      check sawArchiveInput

      # The pascalcalc argv carries the archive via ``-k<archive>``
      # (fpc linker pass-through).
      let pascalcalcArgv = inlineArgvOf(pascalcalcAction)
      var sawKFlag = false
      for token in pascalcalcArgv:
        if token == "-k" & archiveOutput:
          sawKFlag = true
      check sawKFlag

suite "pascal-direct convention M59 cross-language (reverse direction)":

  test "reverse: C++ binary picks up Pascal archive as trailing positional":
    if not fpcOnPath() or not gppOnPath():
      skip()
    elif not dirExists(Mode3MixedReverseFixture):
      skip()
    else:
      let conv = pascal_direct_convention.pascalDirectConvention()
      let request = dummyRequest(Mode3MixedReverseFixture)
      require conv.recognize(Mode3MixedReverseFixture, request)
      let fragment = conv.emitFragment(Mode3MixedReverseFixture, request)

      var pascaladdlibArchiveAction: BuildActionDef
      var cppappLinkAction: BuildActionDef
      var sawPascaladdlibArchive = false
      var sawCppLink = false
      var sawCppCompile = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "pascal-direct-archive-pascaladdlib":
          pascaladdlibArchiveAction = action
          sawPascaladdlibArchive = true
        elif action.id == "pascal-xlang-ccpp-exec-link-cppapp":
          cppappLinkAction = action
          sawCppLink = true
        elif action.id.startsWith("pascal-xlang-ccpp-exec-compile-cppapp"):
          sawCppCompile = true
      check sawPascaladdlibArchive
      check sawCppLink
      check sawCppCompile

      # The pascaladdlib output lands at the canonical archive path
      # .repro/build/pascaladdlib/libpascaladdlib.a (shared schema
      # with c-cpp-direct, Rust staticlib, Fortran archive, Zig
      # archive, D archive, Ada archive).
      var pascaladdlibOutput = ""
      for outPath in pascaladdlibArchiveAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libpascaladdlib.a"):
          pascaladdlibOutput = outPath
      check pascaladdlibOutput.len > 0

      # The cppapp link action's deps include the pascaladdlib archive
      # action id.
      var sawPascaladdlibDep = false
      for dep in cppappLinkAction.deps:
        if dep == pascaladdlibArchiveAction.id:
          sawPascaladdlibDep = true
      check sawPascaladdlibDep

      # The cppapp link action's inputs include the upstream archive.
      var sawPascaladdlibInput = false
      for inp in cppappLinkAction.inputs:
        if inp == pascaladdlibOutput:
          sawPascaladdlibInput = true
      check sawPascaladdlibInput

      # The cppapp link argv carries the archive as a trailing
      # positional. The M59 honest-scope cut limits the reverse
      # fixture to ``public name '...'; cdecl;`` no-RTL-bootstrap entry
      # points so the gcc driver resolves all references against the
      # Pascal archive itself without external runtime libs.
      let cppappArgv = inlineArgvOf(cppappLinkAction)
      var sawArchive = false
      for token in cppappArgv:
        if token == pascaladdlibOutput:
          sawArchive = true
      check sawArchive
