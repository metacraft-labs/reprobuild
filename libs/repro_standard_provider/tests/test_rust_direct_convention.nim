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
