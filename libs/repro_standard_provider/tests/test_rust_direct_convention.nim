## Verification for the rust-direct (Mode 3) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/rust-mode3/binary-with-library`` plus a small
## set of scratch-directory negative cases.
##
## Coverage:
##   * ``recognize`` returns true for the Mode 3 fixture (no Cargo.toml,
##     rustc on PATH).
##   * ``recognize`` returns false when a Cargo.toml is present (the
##     Mode 2 Rust convention's territory) — the registration order
##     assertion still belongs in the standard-provider binary's
##     dispatch order test, but the convention's own ``recognize`` is
##     the load-bearing line of defense.
##   * ``recognize`` returns false when the ``uses:`` block lacks
##     ``rust`` / ``rustc``.
##   * ``emitFragment`` against the Mode 3 fixture:
##     - per-crate rustc link actions for both ``mathlib`` (library)
##       and ``calc`` (executable).
##     - the executable's link argv carries the upstream library
##       rlib path via a ``--extern <crate>=<rlib>`` flag (Mode 3 dep
##       wiring).
##     - the executable's link action ``deps`` include the library's
##       action id (sequencing).
##     - the executable's link action ``inputs`` include the rlib
##       output path (cache-hit invalidation).
##   * cycle detection: a scratch fixture with ``depends_on a: b``
##     AND ``depends_on b: a`` rejects emitFragment with a descriptive
##     ValueError.
##   * undeclared-dep detection: a scratch fixture with
##     ``depends_on a: c`` (where ``c`` is not a declared package)
##     rejects with a descriptive ValueError.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/rust_direct as rust_direct_convention

const
  ## ``parentDir`` four times lands at the ``reprobuild/`` repo root.
  ## The fixture lives under the sibling ``reprobuild-examples``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  Mode3Fixture =
    MetacraftRoot / "reprobuild-examples" / "rust-mode3" /
      "binary-with-library"
  Mode3MixedForwardFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "rust-uses-cpp-lib"
  Mode3MixedReverseFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "cpp-uses-rust-lib"

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

proc rustcOnPath(): bool =
  if findExe("rustc").len > 0:
    return true
  # Fall back to the bundled rustup stable toolchain that env.ps1 ships
  # with on Windows (the M9 harness's per-language probe does the same).
  when defined(windows):
    let rustupStableBin = "D:/metacraft-dev-deps/rustup/toolchains/stable-x86_64-pc-windows-msvc/bin"
    let candidate = rustupStableBin / "rustc.exe"
    if fileExists(candidate):
      putEnv("PATH", rustupStableBin & ";" & getEnv("PATH"))
      return findExe("rustc").len > 0
  false

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-rust-direct-test-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "rust-direct convention recognition":

  test "recognize: positive — Mode 3 fixture (no Cargo.toml, rustc available)":
    if not rustcOnPath():
      skip()
    else:
      let conv = rust_direct_convention.rustDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      check conv.recognize(Mode3Fixture, request)

  test "recognize: negative — Cargo.toml at the project root":
    let dir = makeScratch("with-cargo-toml")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "rust"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.rs",
      "fn main() {}\n")
    writeFile(dir / "Cargo.toml", "[package]\nname=\"x\"\nversion=\"0.1.0\"\n")
    let conv = rust_direct_convention.rustDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — uses lacks rust/rustc":
    let dir = makeScratch("no-rust-toolchain")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.rs",
      "fn main() {}\n")
    let conv = rust_direct_convention.rustDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — no rust members declared":
    if not rustcOnPath():
      skip()
    else:
      let dir = makeScratch("no-members")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "rust"
""")
      let conv = rust_direct_convention.rustDirectConvention()
      let request = dummyRequest(dir)
      check not conv.recognize(dir, request)
      removeDir(dir)

suite "rust-direct convention emit (Mode 3 fixture)":

  test "emitFragment: produces per-crate link actions with --extern wiring":
    if not rustcOnPath():
      skip()
    else:
      let conv = rust_direct_convention.rustDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)

      var linkActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("rust-direct-link-"):
          linkActions.add(action)

      check linkActions.len == 2  # mathlib + calc

      var mathlibAction: BuildActionDef
      var calcAction: BuildActionDef
      var sawMathlib = false
      var sawCalc = false
      for action in linkActions:
        if action.id == "rust-direct-link-mathlib":
          mathlibAction = action
          sawMathlib = true
        elif action.id == "rust-direct-link-calc":
          calcAction = action
          sawCalc = true
      check sawMathlib
      check sawCalc

      # The mathlib action's outputs include lib<name>.rlib under the
      # scratch dir.
      var mathlibRlib = ""
      for outPath in mathlibAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libmathlib.rlib"):
          mathlibRlib = outPath
      check mathlibRlib.len > 0

      # The calc link action's deps include the mathlib action id.
      var sawMathlibDep = false
      for dep in calcAction.deps:
        if dep == mathlibAction.id:
          sawMathlibDep = true
      check sawMathlibDep

      # The calc link action's inputs include the upstream rlib (cache
      # invalidation).
      var sawMathlibInput = false
      for inp in calcAction.inputs:
        if inp == mathlibRlib:
          sawMathlibInput = true
      check sawMathlibInput

      # The calc link argv carries ``--extern mathlib=<rlib>``.
      let calcArgv = inlineArgvOf(calcAction)
      var sawExtern = false
      for i, token in calcArgv:
        if token == "--extern" and i + 1 < calcArgv.len:
          let next = calcArgv[i + 1]
          if next.startsWith("mathlib=") and
              next.toLowerAscii.replace('\\', '/').endsWith("libmathlib.rlib"):
            sawExtern = true
      check sawExtern

      # The mathlib argv compiles with --crate-type rlib (NOT staticlib —
      # see the M30 honest-scope cut about Rust-to-Rust linking).
      let mathlibArgv = inlineArgvOf(mathlibAction)
      var sawRlibCrateType = false
      for i, token in mathlibArgv:
        if token == "--crate-type" and i + 1 < mathlibArgv.len and
            mathlibArgv[i + 1] == "rlib":
          sawRlibCrateType = true
      check sawRlibCrateType

suite "rust-direct convention dep validation":

  test "depends_on cycle is rejected before any compile fires":
    if not rustcOnPath():
      skip()
    else:
      let dir = makeScratch("cycle")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "rust"
  library alpha

package betaPkg:
  uses:
    "rust"
  library beta

depends_on alphaPkg: betaPkg
depends_on betaPkg: alphaPkg
""")
      createDir(dir / "alpha" / "src")
      writeFile(dir / "alpha" / "src" / "lib.rs",
        "pub fn alpha() -> i32 { 1 }\n")
      createDir(dir / "beta" / "src")
      writeFile(dir / "beta" / "src" / "lib.rs",
        "pub fn beta() -> i32 { 2 }\n")
      let conv = rust_direct_convention.rustDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

  test "depends_on references undeclared package — rejected":
    if not rustcOnPath():
      skip()
    else:
      let dir = makeScratch("undeclared")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package onlyPkg:
  uses:
    "rust"
  executable hello:
    discard

depends_on onlyPkg: nonexistentPkg
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.rs",
        "fn main() {}\n")
      let conv = rust_direct_convention.rustDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

# ---------------------------------------------------------------------------
# Layout A vs Layout B recognition. Pins the convention's behaviour
# for single-package fixtures whose layout matches the spec's
# Layout A (workspace root has ``src/main.rs`` / ``src/lib.rs``).
# ---------------------------------------------------------------------------

suite "rust-direct convention layout recognition":

  test "layout A: single-member workspace with src/main.rs at root":
    if not rustcOnPath():
      skip()
    else:
      let dir = makeScratch("layout-a-bin")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package soloPkg:
  uses:
    "rust"
  executable solo:
    discard
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.rs",
        "fn main() { println!(\"layout A\"); }\n")
      let conv = rust_direct_convention.rustDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

  test "layout B: multi-package workspace with <member>/src/{main,lib}.rs":
    if not rustcOnPath():
      skip()
    else:
      let dir = makeScratch("layout-b-recognise")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package libPkg:
  uses:
    "rust"
  library mylib

package binPkg:
  uses:
    "rust"
  executable mybin:
    discard
""")
      createDir(dir / "mylib" / "src")
      writeFile(dir / "mylib" / "src" / "lib.rs",
        "pub fn helper() -> i32 { 42 }\n")
      createDir(dir / "mybin" / "src")
      writeFile(dir / "mybin" / "src" / "main.rs",
        "fn main() {}\n")
      let conv = rust_direct_convention.rustDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

# ---------------------------------------------------------------------------
# M34 cross-language Rust ↔ C/C++ verification.
#
# Forward direction (Rust binary → C library): the rust-direct
# convention emits per-source ``gcc -c`` + ``ar rcs lib<name>.a`` for
# the C library plus a Rust ``rustc`` link that threads
# ``-L native=<dir>`` ``-l static=<libname>`` flags onto its argv.
#
# Reverse direction (C++ binary → Rust library): the convention emits
# the Rust library with ``--crate-type=staticlib`` (derived from the
# ``cConsumable`` flag the dep graph sets) landing at ``lib<name>.a``,
# plus per-source ``g++ -c`` + terminal ``g++ -o`` for the C++ binary
# with the Rust archive threaded as a trailing positional.
# ---------------------------------------------------------------------------

suite "rust-direct convention M34 cross-language (forward direction)":

  test "forward: Rust binary picks up C archive via -L native + -l static":
    if not rustcOnPath():
      skip()
    else:
      let conv = rust_direct_convention.rustDirectConvention()
      let request = dummyRequest(Mode3MixedForwardFixture)
      require conv.recognize(Mode3MixedForwardFixture, request)
      let fragment = conv.emitFragment(Mode3MixedForwardFixture, request)

      var archiveAction: BuildActionDef
      var calcAction: BuildActionDef
      var sawArchive = false
      var sawCalc = false
      var sawCompile = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "rust-xlang-ccpp-archive-mathlib":
          archiveAction = action
          sawArchive = true
        elif action.id == "rust-direct-link-calc":
          calcAction = action
          sawCalc = true
        elif action.id.startsWith("rust-xlang-ccpp-compile-mathlib"):
          sawCompile = true

      # The convention emits at least: 1 per-source compile + 1 archive +
      # 1 Rust link. The C/C++ helpers carry the rust-xlang-ccpp- prefix
      # to discriminate from the Nim convention's nim-xlang-ccpp-.
      check sawArchive
      check sawCalc
      check sawCompile

      # The archive output lands at .repro/build/mathlib/libmathlib.a
      # (the cross-language schema shared with c-cpp-direct).
      var archiveOutput = ""
      for outPath in archiveAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libmathlib.a"):
          archiveOutput = outPath
      check archiveOutput.len > 0

      # The calc action's deps include the archive action id.
      var sawArchiveDep = false
      for dep in calcAction.deps:
        if dep == archiveAction.id:
          sawArchiveDep = true
      check sawArchiveDep

      # The calc action's inputs include the upstream archive (cache
      # invalidation).
      var sawArchiveInput = false
      for inp in calcAction.inputs:
        if inp == archiveOutput:
          sawArchiveInput = true
      check sawArchiveInput

      # The calc argv carries the canonical Rust → C archive flags:
      #   -L native=<dir>
      #   -l static=mathlib
      let calcArgv = inlineArgvOf(calcAction)
      var sawLNative = false
      var sawLStatic = false
      for i, token in calcArgv:
        if token == "-L" and i + 1 < calcArgv.len and
            calcArgv[i + 1].startsWith("native="):
          sawLNative = true
        if token == "-l" and i + 1 < calcArgv.len and
            calcArgv[i + 1] == "static=mathlib":
          sawLStatic = true
      check sawLNative
      check sawLStatic

suite "rust-direct convention M34 cross-language (reverse direction)":

  test "reverse: Rust library emits --crate-type=staticlib when consumed by C++":
    if not rustcOnPath():
      skip()
    else:
      let conv = rust_direct_convention.rustDirectConvention()
      let request = dummyRequest(Mode3MixedReverseFixture)
      require conv.recognize(Mode3MixedReverseFixture, request)
      let fragment = conv.emitFragment(Mode3MixedReverseFixture, request)

      var addlibAction: BuildActionDef
      var cppappLinkAction: BuildActionDef
      var sawAddlib = false
      var sawCppLink = false
      var sawCppCompile = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "rust-direct-link-addlib":
          addlibAction = action
          sawAddlib = true
        elif action.id == "rust-xlang-ccpp-exec-link-cppapp":
          cppappLinkAction = action
          sawCppLink = true
        elif action.id.startsWith("rust-xlang-ccpp-exec-compile-cppapp"):
          sawCppCompile = true
      check sawAddlib
      check sawCppLink
      check sawCppCompile

      # The addlib argv carries --crate-type staticlib (NOT rlib).
      let addlibArgv = inlineArgvOf(addlibAction)
      var sawStaticlib = false
      var sawRlib = false
      for i, token in addlibArgv:
        if token == "--crate-type" and i + 1 < addlibArgv.len:
          if addlibArgv[i + 1] == "staticlib":
            sawStaticlib = true
          elif addlibArgv[i + 1] == "rlib":
            sawRlib = true
      check sawStaticlib
      check not sawRlib

      # The addlib argv carries -C panic=abort (load-bearing for no_std
      # staticlib FFI archives on this host's MSVC-rustc + MinGW-gcc
      # combo — without the flag, rustc errors with "unwinding panics
      # are not supported without std").
      var sawPanicAbort = false
      for i, token in addlibArgv:
        if token == "-C" and i + 1 < addlibArgv.len and
            addlibArgv[i + 1] == "panic=abort":
          sawPanicAbort = true
      check sawPanicAbort

      # The addlib output lands at the canonical archive path
      # .repro/build/addlib/libaddlib.a (shared schema with c-cpp-direct
      # and Nim).
      var addlibOutput = ""
      for outPath in addlibAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libaddlib.a"):
          addlibOutput = outPath
      check addlibOutput.len > 0

      # The cppapp link action's deps include the addlib action id.
      var sawAddlibDep = false
      for dep in cppappLinkAction.deps:
        if dep == addlibAction.id:
          sawAddlibDep = true
      check sawAddlibDep

      # The cppapp link action's inputs include the upstream archive.
      var sawAddlibInput = false
      for inp in cppappLinkAction.inputs:
        if inp == addlibOutput:
          sawAddlibInput = true
      check sawAddlibInput

      # The cppapp link argv carries the archive as a trailing positional
      # AND the platform-specific Rust runtime libs.
      let cppappArgv = inlineArgvOf(cppappLinkAction)
      var sawArchive = false
      for token in cppappArgv:
        if token == addlibOutput:
          sawArchive = true
      check sawArchive
      when defined(windows):
        # Windows MinGW: -lws2_32 -luserenv -ladvapi32 -lbcrypt -lntdll
        var sawWs232 = false
        var sawBcrypt = false
        for token in cppappArgv:
          if token == "-lws2_32": sawWs232 = true
          if token == "-lbcrypt": sawBcrypt = true
        check sawWs232
        check sawBcrypt
      else:
        # POSIX: -lpthread -ldl -lm
        var sawPthread = false
        var sawDl = false
        var sawM = false
        for token in cppappArgv:
          if token == "-lpthread": sawPthread = true
          if token == "-ldl": sawDl = true
          if token == "-lm": sawM = true
        check sawPthread
        check sawDl
        check sawM

suite "rust-direct convention M34 cConsumable preserves M30 rlib emit":

  test "M30 fixture (pure Rust workspace) still produces rlib, not staticlib":
    # The mode3-pilot fixture has only Rust packages — no C/C++ consumers,
    # so cConsumable=false for mathlib and the convention must still emit
    # --crate-type=rlib. M30 behaviour preserved.
    if not rustcOnPath():
      skip()
    else:
      let conv = rust_direct_convention.rustDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)
      var mathlibAction: BuildActionDef
      var sawMathlib = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "rust-direct-link-mathlib":
          mathlibAction = action
          sawMathlib = true
      check sawMathlib
      let mathlibArgv = inlineArgvOf(mathlibAction)
      var sawRlib = false
      var sawStaticlib = false
      for i, token in mathlibArgv:
        if token == "--crate-type" and i + 1 < mathlibArgv.len:
          if mathlibArgv[i + 1] == "rlib": sawRlib = true
          elif mathlibArgv[i + 1] == "staticlib": sawStaticlib = true
      check sawRlib
      check not sawStaticlib
      # The pure-Rust mathlib output lands at libmathlib.rlib (NOT .a).
      var sawRlibOutput = false
      for outPath in mathlibAction.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libmathlib.rlib"):
          sawRlibOutput = true
      check sawRlibOutput

suite "rust-direct convention M34 cross-language cycle + undeclared":

  test "forward cycle: Rust binary depends_on C lib AND C lib depends_on Rust app — rejected":
    if not rustcOnPath():
      skip()
    else:
      let dir = makeScratch("xlang-cycle")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package cLibPkg:
  uses:
    "gcc >=11"
  library clib

package rustAppPkg:
  uses:
    "rust"
  executable rustapp:
    discard

depends_on rustAppPkg: cLibPkg
depends_on cLibPkg: rustAppPkg
""")
      createDir(dir / "clib" / "src")
      writeFile(dir / "clib" / "src" / "add.c",
        "int add(int a, int b) { return a + b; }\n")
      createDir(dir / "rustapp" / "src")
      writeFile(dir / "rustapp" / "src" / "main.rs",
        "fn main() {}\n")
      let conv = rust_direct_convention.rustDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

  test "reverse cycle: C++ binary depends_on Rust lib AND Rust lib depends_on C++ app — rejected":
    if not rustcOnPath():
      skip()
    else:
      let dir = makeScratch("xlang-reverse-cycle")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package rustLibPkg:
  uses:
    "rust"
  library rustlib

package cppAppPkg:
  uses:
    "gcc >=11"
  executable cppapp:
    discard

depends_on cppAppPkg: rustLibPkg
depends_on rustLibPkg: cppAppPkg
""")
      createDir(dir / "rustlib" / "src")
      writeFile(dir / "rustlib" / "src" / "lib.rs",
        "pub fn x() -> i32 { 1 }\n")
      createDir(dir / "cppapp" / "src")
      writeFile(dir / "cppapp" / "src" / "main.cpp",
        "int main() { return 0; }\n")
      let conv = rust_direct_convention.rustDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)
