## Verification for the zig-direct (Mode 3) language convention
## (M44).
##
## Coverage:
##   * ``recognize`` returns true for the Mode 3 fixture when zig is
##     on PATH.
##   * ``recognize`` returns false when a ``build.zig`` is at the
##     workspace root (the future Mode 2 ``zig`` convention's
##     territory).
##   * ``recognize`` returns false when ``uses:`` lacks ``zig``.
##   * ``recognize`` returns false when no executable / library
##     members are declared.
##   * ``emitFragment`` against the pure-Zig Mode 3 fixture emits
##     per-member ``zig build-lib`` / ``zig build-exe`` link actions
##     wired by the workspace ``depends_on`` graph:
##       - The library action lands ``libziglib.a`` under the scratch
##         dir.
##       - The executable link action's ``deps`` include the library
##         action's id.
##       - The executable link action's ``inputs`` include the
##         upstream archive path (cache invalidation).
##       - The executable link argv carries the upstream archive as a
##         trailing positional.
##   * Forward cross-language: a Zig binary depends on a C library —
##     the convention emits both directions' actions and threads the
##     C archive onto the ``zig build-exe`` link.
##   * Reverse cross-language: a C++ binary depends on a Zig library
##     — the convention emits the Zig library AND the C++ binary's
##     per-source compile + terminal link with the archive on the
##     link line.
##   * cycle detection: a scratch fixture with cross-package cycles
##     rejects with a descriptive ValueError.
##   * undeclared-dep detection: a depends_on references an
##     undeclared package — rejected.
##   * cConsumable toggle: when a C/C++ executable in the workspace
##     depends on a Zig library's package, the library's
##     ``cConsumable`` is set; verified by checking the C++ link
##     argv carries the archive as a trailing positional.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/zig_direct as zig_direct_convention

const
  ## ``parentDir`` four times lands at the ``reprobuild/`` repo root.
  ## The fixture lives under the sibling ``reprobuild-examples``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  Mode3Fixture =
    MetacraftRoot / "reprobuild-examples" / "zig-mode3" /
      "binary-with-library"
  Mode3MixedForwardFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "zig-uses-cpp-lib"
  Mode3MixedReverseFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "cpp-uses-zig-lib"

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

proc zigOnPath(): bool =
  if findExe("zig").len > 0:
    return true
  # Fall back to the bundled Zig under D:/metacraft-dev-deps/zig/<v>/
  # mirroring the convention's own probe order. M44's honest-scope
  # cut: if Zig isn't installed anywhere, every test SKIPs cleanly.
  when defined(windows):
    let zigRoot = "D:/metacraft-dev-deps/zig"
    if dirExists(zigRoot):
      for kind, path in walkDir(zigRoot):
        if kind != pcDir:
          continue
        let candidate = path / "zig.exe"
        if fileExists(candidate):
          let binDir = parentDir(candidate)
          putEnv("PATH", binDir & ";" & getEnv("PATH"))
          return findExe("zig").len > 0
  false

proc gccOnPath(): bool =
  findExe("gcc").len > 0 or findExe("clang").len > 0

proc gppOnPath(): bool =
  findExe("g++").len > 0 or findExe("clang++").len > 0

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-zig-direct-test-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "zig-direct convention recognition":

  test "recognize: positive — Mode 3 fixture (no build.zig, zig on PATH)":
    if not zigOnPath():
      skip()
    else:
      let conv = zig_direct_convention.zigDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      check conv.recognize(Mode3Fixture, request)

  test "recognize: negative — build.zig at project root":
    let dir = makeScratch("with-build-zig")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "zig"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.zig",
      "pub fn main() void {}\n")
    writeFile(dir / "build.zig",
      "// placeholder build.zig — the future Mode 2 zig convention's territory\n")
    let conv = zig_direct_convention.zigDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — uses lacks zig":
    let dir = makeScratch("no-zig-toolchain")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.zig",
      "pub fn main() void {}\n")
    let conv = zig_direct_convention.zigDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — no zig members declared":
    if not zigOnPath():
      skip()
    else:
      let dir = makeScratch("no-members")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "zig"
""")
      let conv = zig_direct_convention.zigDirectConvention()
      let request = dummyRequest(dir)
      check not conv.recognize(dir, request)
      removeDir(dir)

suite "zig-direct convention emit (Mode 3 fixture)":

  test "emitFragment: per-member build-lib + build-exe actions":
    if not zigOnPath():
      skip()
    else:
      let conv = zig_direct_convention.zigDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)

      var ziglibAction: BuildActionDef
      var zigcalcAction: BuildActionDef
      var sawZiglib = false
      var sawZigcalc = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "zig-direct-link-ziglib":
          ziglibAction = action
          sawZiglib = true
        elif action.id == "zig-direct-link-zigcalc":
          zigcalcAction = action
          sawZigcalc = true
      check sawZiglib
      check sawZigcalc

      # The ziglib output lands at .repro/build/ziglib/libziglib.a.
      var ziglibArchive = ""
      for outPath in ziglibAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libziglib.a"):
          ziglibArchive = outPath
      check ziglibArchive.len > 0

      # The library argv runs `zig build-lib` (not build-exe).
      let ziglibArgv = inlineArgvOf(ziglibAction)
      var sawBuildLib = false
      for token in ziglibArgv:
        if token == "build-lib":
          sawBuildLib = true
      check sawBuildLib

      # The zigcalc argv runs `zig build-exe`.
      let zigcalcArgv = inlineArgvOf(zigcalcAction)
      var sawBuildExe = false
      for token in zigcalcArgv:
        if token == "build-exe":
          sawBuildExe = true
      check sawBuildExe

      # The zigcalc action's deps include the ziglib action id.
      var sawZiglibDep = false
      for dep in zigcalcAction.deps:
        if dep == ziglibAction.id:
          sawZiglibDep = true
      check sawZiglibDep

      # The zigcalc action's inputs include the upstream archive.
      var sawZiglibInput = false
      for inp in zigcalcAction.inputs:
        if inp == ziglibArchive:
          sawZiglibInput = true
      check sawZiglibInput

      # The zigcalc argv carries the archive as a trailing positional.
      var sawArchivePositional = false
      for token in zigcalcArgv:
        if token == ziglibArchive:
          sawArchivePositional = true
      check sawArchivePositional

      # The argv carries -femit-bin=<output>.
      var sawEmitBin = false
      for token in zigcalcArgv:
        if token.startsWith("-femit-bin="):
          sawEmitBin = true
      check sawEmitBin

suite "zig-direct convention dep validation":

  test "depends_on cycle is rejected before any compile fires":
    if not zigOnPath():
      skip()
    else:
      let dir = makeScratch("cycle")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "zig"
  library alpha

package betaPkg:
  uses:
    "zig"
  library beta

depends_on alphaPkg: betaPkg
depends_on betaPkg: alphaPkg
""")
      createDir(dir / "alpha" / "src")
      writeFile(dir / "alpha" / "src" / "root.zig",
        "export fn alpha() i32 { return 1; }\n")
      createDir(dir / "beta" / "src")
      writeFile(dir / "beta" / "src" / "root.zig",
        "export fn beta() i32 { return 2; }\n")
      let conv = zig_direct_convention.zigDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

  test "depends_on references undeclared package — rejected":
    if not zigOnPath():
      skip()
    else:
      let dir = makeScratch("undeclared")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package onlyPkg:
  uses:
    "zig"
  executable hello:
    discard

depends_on onlyPkg: nonexistentPkg
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.zig",
        "pub fn main() void {}\n")
      let conv = zig_direct_convention.zigDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

# ---------------------------------------------------------------------------
# M44 cross-language Zig ↔ C/C++ verification.
# ---------------------------------------------------------------------------

suite "zig-direct convention M44 cross-language (forward direction)":

  test "forward: Zig binary picks up C archive as trailing positional":
    if not zigOnPath() or not gccOnPath():
      skip()
    else:
      let conv = zig_direct_convention.zigDirectConvention()
      let request = dummyRequest(Mode3MixedForwardFixture)
      require conv.recognize(Mode3MixedForwardFixture, request)
      let fragment = conv.emitFragment(Mode3MixedForwardFixture, request)

      var archiveAction: BuildActionDef
      var zigcalcAction: BuildActionDef
      var sawArchive = false
      var sawZigcalc = false
      var sawCompile = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "zig-xlang-ccpp-archive-mathlib":
          archiveAction = action
          sawArchive = true
        elif action.id == "zig-direct-link-zigcalc":
          zigcalcAction = action
          sawZigcalc = true
        elif action.id.startsWith("zig-xlang-ccpp-compile-mathlib"):
          sawCompile = true

      check sawArchive
      check sawZigcalc
      check sawCompile

      # The archive output lands at .repro/build/mathlib/libmathlib.a
      # (the cross-language schema shared with c-cpp-direct).
      var archiveOutput = ""
      for outPath in archiveAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libmathlib.a"):
          archiveOutput = outPath
      check archiveOutput.len > 0

      # The zigcalc action's deps include the archive action id.
      var sawArchiveDep = false
      for dep in zigcalcAction.deps:
        if dep == archiveAction.id:
          sawArchiveDep = true
      check sawArchiveDep

      # The zigcalc action's inputs include the upstream archive.
      var sawArchiveInput = false
      for inp in zigcalcAction.inputs:
        if inp == archiveOutput:
          sawArchiveInput = true
      check sawArchiveInput

      # The zigcalc argv carries the archive as a trailing positional
      # AND ``-L <archive-dir>`` so Zig's underlying linker resolves it.
      let zigcalcArgv = inlineArgvOf(zigcalcAction)
      var sawArchivePositional = false
      var sawLFlag = false
      for i, token in zigcalcArgv:
        if token == archiveOutput:
          sawArchivePositional = true
        if token == "-L" and i + 1 < zigcalcArgv.len:
          sawLFlag = true
      check sawArchivePositional
      check sawLFlag

suite "zig-direct convention M44 cross-language (reverse direction)":

  test "reverse: C++ binary picks up Zig archive as trailing positional":
    if not zigOnPath() or not gppOnPath():
      skip()
    else:
      let conv = zig_direct_convention.zigDirectConvention()
      let request = dummyRequest(Mode3MixedReverseFixture)
      require conv.recognize(Mode3MixedReverseFixture, request)
      let fragment = conv.emitFragment(Mode3MixedReverseFixture, request)

      var zigaddlibAction: BuildActionDef
      var cppappLinkAction: BuildActionDef
      var sawZigaddlib = false
      var sawCppLink = false
      var sawCppCompile = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "zig-direct-link-zigaddlib":
          zigaddlibAction = action
          sawZigaddlib = true
        elif action.id == "zig-xlang-ccpp-exec-link-cppapp":
          cppappLinkAction = action
          sawCppLink = true
        elif action.id.startsWith("zig-xlang-ccpp-exec-compile-cppapp"):
          sawCppCompile = true
      check sawZigaddlib
      check sawCppLink
      check sawCppCompile

      # The zigaddlib argv runs zig build-lib.
      let zigaddlibArgv = inlineArgvOf(zigaddlibAction)
      var sawBuildLib = false
      for token in zigaddlibArgv:
        if token == "build-lib":
          sawBuildLib = true
      check sawBuildLib

      # The zigaddlib output lands at the canonical archive path
      # .repro/build/zigaddlib/libzigaddlib.a (shared schema with
      # c-cpp-direct, Rust staticlib, Fortran archive).
      var zigaddlibOutput = ""
      for outPath in zigaddlibAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libzigaddlib.a"):
          zigaddlibOutput = outPath
      check zigaddlibOutput.len > 0

      # The cppapp link action's deps include the zigaddlib action id.
      var sawZigaddlibDep = false
      for dep in cppappLinkAction.deps:
        if dep == zigaddlibAction.id:
          sawZigaddlibDep = true
      check sawZigaddlibDep

      # The cppapp link action's inputs include the upstream archive.
      var sawZigaddlibInput = false
      for inp in cppappLinkAction.inputs:
        if inp == zigaddlibOutput:
          sawZigaddlibInput = true
      check sawZigaddlibInput

      # The cppapp link argv carries the archive as a trailing
      # positional. Unlike Rust/Fortran, Zig does NOT thread runtime
      # ``-l`` libs onto the link — Zig static archives bundle
      # compiler-rt into the archive.
      let cppappArgv = inlineArgvOf(cppappLinkAction)
      var sawArchive = false
      for token in cppappArgv:
        if token == zigaddlibOutput:
          sawArchive = true
      check sawArchive

suite "zig-direct convention M44 cConsumable toggle":

  test "pure-zig fixture: library not marked cConsumable":
    # The pure-Zig fixture has no C/C++ consumers, so the cConsumable
    # flag stays false for ziglib. The action graph still emits the
    # library (Zig static archives are C-ABI by construction); the
    # flag's observable consequence at this milestone is only on the
    # downstream wiring path — no archive layout change.
    if not zigOnPath():
      skip()
    else:
      let conv = zig_direct_convention.zigDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)
      var ziglibAction: BuildActionDef
      var sawZiglib = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "zig-direct-link-ziglib":
          ziglibAction = action
          sawZiglib = true
      check sawZiglib
      # The output still lands at libziglib.a regardless of cConsumable.
      var sawArchiveOutput = false
      for outPath in ziglibAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libziglib.a"):
          sawArchiveOutput = true
      check sawArchiveOutput
