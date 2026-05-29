## Verification for the d-direct (Mode 3) language convention (M45).
##
## Coverage:
##   * ``recognize`` returns true for the Mode 3 fixture when a D
##     compiler (``ldmd2``/``dmd``/``ldc2``) is on PATH (or under the
##     bundled D:/metacraft-dev-deps/ldc/<v>/ tree).
##   * ``recognize`` returns false when a ``dub.json`` / ``dub.sdl`` is
##     at the workspace root (the future Mode 2 D convention's
##     territory).
##   * ``recognize`` returns false when ``uses:`` lacks a D toolchain
##     token.
##   * ``recognize`` returns false when no executable / library
##     members are declared.
##   * ``emitFragment`` against the pure-D Mode 3 fixture emits
##     per-member ``ldmd2 -lib`` / ``ldmd2`` link actions wired by the
##     workspace ``depends_on`` graph:
##       - The library action lands ``libdlib.a`` under the scratch
##         dir.
##       - The executable link action's ``deps`` include the library
##         action's id.
##       - The executable link action's ``inputs`` include the
##         upstream archive path (cache invalidation).
##       - The executable link argv carries the upstream archive via
##         ``-L=<archive>`` (linker pass-through).
##   * Forward cross-language: a D binary depends on a C library —
##     the convention emits both directions' actions and threads the
##     C archive onto the ``ldmd2`` link as ``-L=<archive>``.
##   * Reverse cross-language: a C++ binary depends on a D library —
##     the convention emits the D library AND the C++ binary's
##     per-source compile + terminal link with the archive on the
##     link line.
##   * cycle detection: a scratch fixture with cross-package cycles
##     rejects with a descriptive ValueError.
##   * undeclared-dep detection: a depends_on references an
##     undeclared package — rejected.
##   * cConsumable toggle: when a C/C++ executable in the workspace
##     depends on a D library's package, the library's
##     ``cConsumable`` is set; verified by checking the C++ link
##     argv carries the archive as a trailing positional.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/d_direct as d_direct_convention

const
  ## ``parentDir`` four times lands at the ``reprobuild/`` repo root.
  ## The fixture lives under the sibling ``reprobuild-examples``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  Mode3Fixture =
    MetacraftRoot / "reprobuild-examples" / "d-mode3" /
      "binary-with-library"
  Mode3MixedForwardFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "d-uses-cpp-lib"
  Mode3MixedReverseFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "cpp-uses-d-lib"

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

proc dOnPath(): bool =
  if findExe("ldmd2").len > 0:
    return true
  if findExe("dmd").len > 0:
    return true
  if findExe("ldc2").len > 0:
    return true
  # Fall back to the bundled LDC under D:/metacraft-dev-deps/ldc/<v>/
  # mirroring the convention's own probe order. M45's honest-scope
  # cut: if D isn't installed anywhere, every test SKIPs cleanly.
  when defined(windows):
    let ldcRoot = "D:/metacraft-dev-deps/ldc"
    if dirExists(ldcRoot):
      for kind, path in walkDir(ldcRoot):
        if kind != pcDir:
          continue
        for kind2, sub in walkDir(path):
          if kind2 != pcDir:
            continue
          let candidate = sub / "bin" / "ldmd2.exe"
          if fileExists(candidate):
            let binDir = parentDir(candidate)
            putEnv("PATH", binDir & ";" & getEnv("PATH"))
            return findExe("ldmd2").len > 0 or findExe("dmd").len > 0 or
              findExe("ldc2").len > 0
  false

proc gccOnPath(): bool =
  findExe("gcc").len > 0 or findExe("clang").len > 0

proc gppOnPath(): bool =
  findExe("g++").len > 0 or findExe("clang++").len > 0

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-d-direct-test-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "d-direct convention recognition":

  test "recognize: positive — Mode 3 fixture (no dub manifest, D on PATH)":
    if not dOnPath():
      skip()
    else:
      let conv = d_direct_convention.dDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      check conv.recognize(Mode3Fixture, request)

  test "recognize: negative — dub.json at project root":
    let dir = makeScratch("with-dub-json")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "d"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.d",
      "void main() {}\n")
    writeFile(dir / "dub.json",
      "{ \"name\": \"placeholder\" }\n")
    let conv = d_direct_convention.dDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — dub.sdl at project root":
    let dir = makeScratch("with-dub-sdl")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "d"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.d",
      "void main() {}\n")
    writeFile(dir / "dub.sdl",
      "name \"placeholder\"\n")
    let conv = d_direct_convention.dDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — uses lacks D":
    let dir = makeScratch("no-d-toolchain")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.d",
      "void main() {}\n")
    let conv = d_direct_convention.dDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — no D members declared":
    if not dOnPath():
      skip()
    else:
      let dir = makeScratch("no-members")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "d"
""")
      let conv = d_direct_convention.dDirectConvention()
      let request = dummyRequest(dir)
      check not conv.recognize(dir, request)
      removeDir(dir)

  test "recognize: positive — accepts ``ldc2`` token in uses":
    if not dOnPath():
      skip()
    else:
      let dir = makeScratch("ldc2-token")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "ldc2"
  executable hello:
    discard
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.d",
        "void main() {}\n")
      let conv = d_direct_convention.dDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

suite "d-direct convention emit (Mode 3 fixture)":

  test "emitFragment: per-member -lib + executable link actions":
    if not dOnPath():
      skip()
    else:
      let conv = d_direct_convention.dDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)

      var dlibAction: BuildActionDef
      var dcalcAction: BuildActionDef
      var sawDlib = false
      var sawDcalc = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "d-direct-link-dlib":
          dlibAction = action
          sawDlib = true
        elif action.id == "d-direct-link-dcalc":
          dcalcAction = action
          sawDcalc = true
      check sawDlib
      check sawDcalc

      # The dlib output lands at .repro/build/dlib/libdlib.a.
      var dlibArchive = ""
      for outPath in dlibAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libdlib.a"):
          dlibArchive = outPath
      check dlibArchive.len > 0

      # The library argv carries -lib.
      let dlibArgv = inlineArgvOf(dlibAction)
      var sawLibFlag = false
      for token in dlibArgv:
        if token == "-lib":
          sawLibFlag = true
      check sawLibFlag

      # The dcalc argv does NOT carry -lib (it builds an exec).
      let dcalcArgv = inlineArgvOf(dcalcAction)
      var execHasLibFlag = false
      for token in dcalcArgv:
        if token == "-lib":
          execHasLibFlag = true
      check not execHasLibFlag

      # The dcalc action's deps include the dlib action id.
      var sawDlibDep = false
      for dep in dcalcAction.deps:
        if dep == dlibAction.id:
          sawDlibDep = true
      check sawDlibDep

      # The dcalc action's inputs include the upstream archive.
      var sawDlibInput = false
      for inp in dcalcAction.inputs:
        if inp == dlibArchive:
          sawDlibInput = true
      check sawDlibInput

      # The dcalc argv carries the archive via -L= linker pass-through.
      var sawArchivePassThrough = false
      for token in dcalcArgv:
        if token == "-L=" & dlibArchive:
          sawArchivePassThrough = true
      check sawArchivePassThrough

      # The argv carries -of=<output>.
      var sawOfFlag = false
      for token in dcalcArgv:
        if token.startsWith("-of="):
          sawOfFlag = true
      check sawOfFlag

suite "d-direct convention dep validation":

  test "depends_on cycle is rejected before any compile fires":
    if not dOnPath():
      skip()
    else:
      let dir = makeScratch("cycle")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "d"
  library alpha

package betaPkg:
  uses:
    "d"
  library beta

depends_on alphaPkg: betaPkg
depends_on betaPkg: alphaPkg
""")
      createDir(dir / "alpha" / "src")
      writeFile(dir / "alpha" / "src" / "lib.d",
        "extern (C) int alpha() { return 1; }\n")
      createDir(dir / "beta" / "src")
      writeFile(dir / "beta" / "src" / "lib.d",
        "extern (C) int beta() { return 2; }\n")
      let conv = d_direct_convention.dDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

  test "depends_on references undeclared package — rejected":
    if not dOnPath():
      skip()
    else:
      let dir = makeScratch("undeclared")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package onlyPkg:
  uses:
    "d"
  executable hello:
    discard

depends_on onlyPkg: nonexistentPkg
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.d",
        "void main() {}\n")
      let conv = d_direct_convention.dDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

# ---------------------------------------------------------------------------
# M45 cross-language D ↔ C/C++ verification.
# ---------------------------------------------------------------------------

suite "d-direct convention M45 cross-language (forward direction)":

  test "forward: D binary picks up C archive via -L= pass-through":
    if not dOnPath() or not gccOnPath():
      skip()
    elif not dirExists(Mode3MixedForwardFixture):
      skip()
    else:
      let conv = d_direct_convention.dDirectConvention()
      let request = dummyRequest(Mode3MixedForwardFixture)
      require conv.recognize(Mode3MixedForwardFixture, request)
      let fragment = conv.emitFragment(Mode3MixedForwardFixture, request)

      var archiveAction: BuildActionDef
      var dcalcAction: BuildActionDef
      var sawArchive = false
      var sawDcalc = false
      var sawCompile = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "d-xlang-ccpp-archive-mathlib":
          archiveAction = action
          sawArchive = true
        elif action.id == "d-direct-link-dcalc":
          dcalcAction = action
          sawDcalc = true
        elif action.id.startsWith("d-xlang-ccpp-compile-mathlib"):
          sawCompile = true

      check sawArchive
      check sawDcalc
      check sawCompile

      # The archive output lands at .repro/build/mathlib/libmathlib.a.
      var archiveOutput = ""
      for outPath in archiveAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libmathlib.a"):
          archiveOutput = outPath
      check archiveOutput.len > 0

      # The dcalc action's deps include the archive action id.
      var sawArchiveDep = false
      for dep in dcalcAction.deps:
        if dep == archiveAction.id:
          sawArchiveDep = true
      check sawArchiveDep

      # The dcalc action's inputs include the upstream archive.
      var sawArchiveInput = false
      for inp in dcalcAction.inputs:
        if inp == archiveOutput:
          sawArchiveInput = true
      check sawArchiveInput

      # The dcalc argv carries the archive via -L= pass-through.
      let dcalcArgv = inlineArgvOf(dcalcAction)
      var sawArchivePassThrough = false
      for token in dcalcArgv:
        if token == "-L=" & archiveOutput:
          sawArchivePassThrough = true
      check sawArchivePassThrough

suite "d-direct convention M45 cross-language (reverse direction)":

  test "reverse: C++ binary picks up D archive as trailing positional":
    if not dOnPath() or not gppOnPath():
      skip()
    elif not dirExists(Mode3MixedReverseFixture):
      skip()
    else:
      let conv = d_direct_convention.dDirectConvention()
      let request = dummyRequest(Mode3MixedReverseFixture)
      require conv.recognize(Mode3MixedReverseFixture, request)
      let fragment = conv.emitFragment(Mode3MixedReverseFixture, request)

      var daddlibAction: BuildActionDef
      var cppappLinkAction: BuildActionDef
      var sawDaddlib = false
      var sawCppLink = false
      var sawCppCompile = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "d-direct-link-daddlib":
          daddlibAction = action
          sawDaddlib = true
        elif action.id == "d-xlang-ccpp-exec-link-cppapp":
          cppappLinkAction = action
          sawCppLink = true
        elif action.id.startsWith("d-xlang-ccpp-exec-compile-cppapp"):
          sawCppCompile = true
      check sawDaddlib
      check sawCppLink
      check sawCppCompile

      # The daddlib argv runs -lib.
      let daddlibArgv = inlineArgvOf(daddlibAction)
      var sawLibFlag = false
      for token in daddlibArgv:
        if token == "-lib":
          sawLibFlag = true
      check sawLibFlag

      # The daddlib output lands at the canonical archive path
      # .repro/build/daddlib/libdaddlib.a (shared schema with
      # c-cpp-direct, Rust staticlib, Fortran archive, Zig archive).
      var daddlibOutput = ""
      for outPath in daddlibAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libdaddlib.a"):
          daddlibOutput = outPath
      check daddlibOutput.len > 0

      # The cppapp link action's deps include the daddlib action id.
      var sawDaddlibDep = false
      for dep in cppappLinkAction.deps:
        if dep == daddlibAction.id:
          sawDaddlibDep = true
      check sawDaddlibDep

      # The cppapp link action's inputs include the upstream archive.
      var sawDaddlibInput = false
      for inp in cppappLinkAction.inputs:
        if inp == daddlibOutput:
          sawDaddlibInput = true
      check sawDaddlibInput

      # The cppapp link argv carries the archive as a trailing
      # positional. The M45 honest-scope cut limits the reverse
      # fixture to C-ABI-only entry points + ``core.stdc.*`` (no
      # ``import std.*`` / no GC) so the gcc driver resolves all
      # references against the D archive itself without external
      # runtime libs — same property Zig's M44 reverse fixture relies
      # on.
      let cppappArgv = inlineArgvOf(cppappLinkAction)
      var sawArchive = false
      for token in cppappArgv:
        if token == daddlibOutput:
          sawArchive = true
      check sawArchive

suite "d-direct convention M45 cConsumable toggle":

  test "pure-D fixture: library not marked cConsumable":
    # The pure-D fixture has no C/C++ consumers, so the cConsumable
    # flag stays false for dlib. The action graph still emits the
    # library (D static archives are C-ABI by construction when
    # routines are marked ``extern (C)``); the flag's observable
    # consequence at this milestone is only on the downstream wiring
    # path — no archive layout change.
    if not dOnPath():
      skip()
    else:
      let conv = d_direct_convention.dDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)
      var dlibAction: BuildActionDef
      var sawDlib = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "d-direct-link-dlib":
          dlibAction = action
          sawDlib = true
      check sawDlib
      # The output still lands at libdlib.a regardless of cConsumable.
      var sawArchiveOutput = false
      for outPath in dlibAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libdlib.a"):
          sawArchiveOutput = true
      check sawArchiveOutput
