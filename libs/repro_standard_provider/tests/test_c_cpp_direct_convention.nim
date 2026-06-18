## Verification for the c-cpp-direct (Mode 3) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/c-cpp-mode3/binary-with-library`` plus a small
## set of scratch-directory negative cases.
##
## Coverage:
##   * ``recognize`` returns true for the Mode 3 fixture (no Makefile,
##     C compiler on PATH).
##   * ``recognize`` returns false when a Makefile is present (the Make
##     convention's territory) — the registration order assertion still
##     belongs in the standard-provider binary's dispatch order test,
##     but the convention's own ``recognize`` is the load-bearing
##     line of defense.
##   * ``recognize`` returns false when CMakeLists.txt / configure.ac
##     is present.
##   * ``emitFragment`` against the Mode 3 fixture:
##     - per-source compile actions for both ``mathlib`` (library) and
##       ``calc`` (executable).
##     - per-package archive (``ar rcs libmathlib.a``) and link
##       (``gcc -o calc[.exe]``) actions.
##     - the link action's argv carries the upstream library archive
##       path as a trailing positional (Mode 3 dep wiring).
##     - the link action's ``deps`` include the archive action id
##       (sequencing).
##     - the link action's ``inputs`` include the archive output path
##       (cache-hit invalidation).
##     - the compile action carries ``-I <upstream-include-dir>`` so
##       the executable's ``#include "mathlib/add.h"`` resolves.
##   * cycle detection: a scratch fixture with ``depends_on a: b`` AND
##     ``depends_on b: a`` rejects emitFragment with a descriptive
##     ValueError.
##   * undeclared-dep detection: a scratch fixture with
##     ``depends_on a: c`` (where ``c`` is not a declared package)
##     rejects with a descriptive ValueError.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/c_cpp_direct as c_cpp_direct_convention

const
  ## ``parentDir`` four times lands at the ``reprobuild/`` repo root.
  ## The fixture lives under the sibling ``reprobuild-examples``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  Mode3Fixture =
    MetacraftRoot / "reprobuild-examples" / "c-cpp-mode3" /
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

proc gccOnPath(): bool =
  findExe("gcc").len > 0 or findExe("clang").len > 0

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-c-cpp-direct-test-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "c-cpp-direct convention recognition":

  test "recognize: positive — Mode 3 fixture (declaration-only)":
    # M9.N: recognise claims a recipe based on DECLARATION (no
    # conflicting in-tree manifest + uses: gcc/clang + per-member source
    # resolution), NOT host PATH availability. Tool identity is resolved
    # AFTER recognise by the engine.
    let conv = c_cpp_direct_convention.cCppDirectConvention()
    let request = dummyRequest(Mode3Fixture)
    check conv.recognize(Mode3Fixture, request)

  test "recognize: returns true even without C compiler on PATH (M9.N)":
    # M9.N architectural correction: explicit assertion that the
    # host-PATH gate has been dropped from recognise — the convention
    # claims the recipe regardless of whether gcc/clang resolve.
    let conv = c_cpp_direct_convention.cCppDirectConvention()
    let request = dummyRequest(Mode3Fixture)
    checkpoint "C compiler on PATH: " & $gccOnPath()
    check conv.recognize(Mode3Fixture, request)

  test "recognize: negative — Makefile at the project root":
    let dir = makeScratch("with-makefile")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "gcc >=11"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "hello.c",
      "#include <stdio.h>\nint main(void) { return 0; }\n")
    writeFile(dir / "Makefile", "hello: src/hello.c\n\tgcc -o $@ $<\n")
    let conv = c_cpp_direct_convention.cCppDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — CMakeLists.txt at the project root":
    let dir = makeScratch("with-cmake")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "gcc >=11"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "hello.c",
      "int main(void) { return 0; }\n")
    writeFile(dir / "CMakeLists.txt",
      "cmake_minimum_required(VERSION 3.10)\nadd_executable(hello src/hello.c)\n")
    let conv = c_cpp_direct_convention.cCppDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — uses lacks a compiler":
    let dir = makeScratch("no-compiler")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "hello.c",
      "int main(void) { return 0; }\n")
    let conv = c_cpp_direct_convention.cCppDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

suite "c-cpp-direct convention emit (Mode 3 fixture)":

  test "emitFragment: produces per-source compile + archive + link actions with dep wiring":
    if not gccOnPath():
      skip()
    else:
      let conv = c_cpp_direct_convention.cCppDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)

      var compileActions: seq[BuildActionDef] = @[]
      var archiveActions: seq[BuildActionDef] = @[]
      var linkActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("ccpp-direct-compile-"):
          compileActions.add(action)
        elif action.id.startsWith("ccpp-direct-archive-"):
          archiveActions.add(action)
        elif action.id.startsWith("ccpp-direct-link-"):
          linkActions.add(action)

      check compileActions.len >= 2  # at least add.c + calc.c
      check archiveActions.len == 1  # mathlib
      check linkActions.len == 1     # calc

      # The archive output path is the static library under the
      # convention's scratch dir.
      var archiveOutput = ""
      for outPath in archiveActions[0].outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/libmathlib.a"):
          archiveOutput = outPath
      check archiveOutput.len > 0

      # The link action's deps include the archive action's id and
      # the link action's argv ends with the archive output as a
      # positional. The link action's inputs include the archive
      # output (cache-hit invalidation).
      let linkArgv = inlineArgvOf(linkActions[0])
      var sawArchivePositional = false
      for token in linkArgv:
        if token == archiveOutput:
          sawArchivePositional = true
      check sawArchivePositional

      var sawArchiveDep = false
      for dep in linkActions[0].deps:
        if dep == archiveActions[0].id:
          sawArchiveDep = true
      check sawArchiveDep

      var sawArchiveInput = false
      for inp in linkActions[0].inputs:
        if inp == archiveOutput:
          sawArchiveInput = true
      check sawArchiveInput

      # The calc compile action must carry ``-I <mathlib-include-dir>``
      # so its ``#include "mathlib/add.h"`` resolves.
      var calcCompile: BuildActionDef
      var sawCalcCompile = false
      for action in compileActions:
        if "calc" in action.id:
          calcCompile = action
          sawCalcCompile = true
          break
      check sawCalcCompile
      let calcCompileArgv = inlineArgvOf(calcCompile)
      var sawMathlibIDash = false
      for i, token in calcCompileArgv:
        if token == "-I" and i + 1 < calcCompileArgv.len:
          let next = calcCompileArgv[i + 1].replace('\\', '/')
          if next.endsWith("mathlib/include"):
            sawMathlibIDash = true
      check sawMathlibIDash

suite "c-cpp-direct convention dep validation":

  test "depends_on cycle is rejected before any compile fires":
    if not gccOnPath():
      skip()
    else:
      let dir = makeScratch("cycle")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "gcc >=11"
  library alpha

package betaPkg:
  uses:
    "gcc >=11"
  library beta

depends_on alphaPkg: betaPkg
depends_on betaPkg: alphaPkg
""")
      createDir(dir / "alpha" / "src")
      writeFile(dir / "alpha" / "src" / "alpha.c", "int alpha(void) { return 1; }\n")
      createDir(dir / "beta" / "src")
      writeFile(dir / "beta" / "src" / "beta.c", "int beta(void) { return 2; }\n")
      let conv = c_cpp_direct_convention.cCppDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

  test "depends_on references undeclared package — rejected":
    if not gccOnPath():
      skip()
    else:
      let dir = makeScratch("undeclared")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package onlyPkg:
  uses:
    "gcc >=11"
  executable hello:
    discard

depends_on onlyPkg: nonexistentPkg
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "hello.c",
        "int main(void) { return 0; }\n")
      let conv = c_cpp_direct_convention.cCppDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

# ---------------------------------------------------------------------------
# Cross-language filter suite.
#
# Pins the convention's behaviour when a project file declares both
# ``uses: gcc`` and other-toolchain packages: this convention only
# emits actions for the C/C++ packages, and (defensively) does NOT
# claim the project's Nim members as its own. In the live dispatch the
# Nim convention's earlier registration claims a mixed workspace; this
# filter is the guarantee that c_cpp_direct stays a no-op-for-Nim if a
# test-time isolated registry invokes it on the same fixture.
# ---------------------------------------------------------------------------

suite "c-cpp-direct convention cross-language filtering":

  test "emitFragment: ignores members from Nim-toolchain packages":
    if not gccOnPath():
      skip()
    else:
      let dir = makeScratch("xlang-filter")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlib:
  uses:
    "gcc >=11"
  library mathlib

package nimapp:
  uses:
    "nim >=2.2 <3.0"
  executable nimapp:
    discard
""")
      createDir(dir / "mathlib" / "src")
      writeFile(dir / "mathlib" / "src" / "add.c", "int add(int a, int b) { return a + b; }\n")
      createDir(dir / "mathlib" / "include" / "mathlib")
      writeFile(dir / "mathlib" / "include" / "mathlib" / "add.h",
        "int add(int a, int b);\n")
      # nim member dir intentionally has no C source. The convention's
      # filter must drop it before resolveTarget runs.
      createDir(dir / "src")
      writeFile(dir / "src" / "nimapp.nim",
        "echo \"unused\"\n")
      let conv = c_cpp_direct_convention.cCppDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      # Must succeed (NOT raise about nimapp's missing C sources).
      let fragment = conv.emitFragment(dir, request)
      var sawArchive = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("ccpp-direct-archive-mathlib"):
          sawArchive = true
        check not action.id.contains("nimapp")
      check sawArchive
      removeDir(dir)

  test "recognize: M34 defers to rust-direct on mixed Rust+C/C++ workspaces":
    # When the workspace ``uses:`` block names ``rust`` / ``rustc`` and
    # no Cargo.toml is present, c-cpp-direct must decline so the later-
    # registered ``rust-direct`` convention can claim the workspace and
    # emit both directions of the cross-language matrix from one
    # fragment. Mirror of how the Nim convention claims mixed Nim+C/C++
    # workspaces (the Nim convention's recognize fires first).
    if not gccOnPath():
      skip()
    else:
      let dir = makeScratch("xlang-defer-rust")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlib:
  uses:
    "gcc >=11"
  library mathlib

package calc:
  uses:
    "rust"
  executable calc:
    discard

depends_on calc: mathlib
""")
      createDir(dir / "mathlib" / "src")
      writeFile(dir / "mathlib" / "src" / "add.c",
        "int add(int a, int b) { return a + b; }\n")
      createDir(dir / "calc" / "src")
      writeFile(dir / "calc" / "src" / "main.rs",
        "fn main() {}\n")
      let conv = c_cpp_direct_convention.cCppDirectConvention()
      let request = dummyRequest(dir)
      check not conv.recognize(dir, request)
      removeDir(dir)

  test "recognize: M34 does NOT defer when Cargo.toml is present (Mode 2 territory)":
    # When a Cargo.toml IS present, Mode 2 ``rust`` claims the
    # workspace ahead of both Mode 3 conventions, so c-cpp-direct's
    # defer-to-rust-direct check intentionally only fires when no
    # Cargo.toml is present. (The pure-C/C++ probe still doesn't match
    # this workspace at the convention level because of the Rust-only
    # member layout, but the defer logic itself must not trigger.)
    if not gccOnPath():
      skip()
    else:
      let dir = makeScratch("xlang-defer-with-cargo")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlib:
  uses:
    "gcc >=11"
  library mathlib

package calc:
  uses:
    "rust"
  executable calc:
    discard
""")
      createDir(dir / "mathlib" / "src")
      writeFile(dir / "mathlib" / "src" / "add.c",
        "int add(int a, int b) { return a + b; }\n")
      # The presence of Cargo.toml is what would normally route to
      # Mode 2 rust; here we just check that c-cpp-direct's defer logic
      # does NOT fire (it should recognize as positive because the
      # rust-direct defer check requires NO Cargo.toml).
      writeFile(dir / "Cargo.toml",
        "[package]\nname = \"calc\"\nversion = \"0.1.0\"\n")
      createDir(dir / "calc" / "src")
      writeFile(dir / "calc" / "src" / "main.rs",
        "fn main() {}\n")
      let conv = c_cpp_direct_convention.cCppDirectConvention()
      let request = dummyRequest(dir)
      # c-cpp-direct DOES recognize (Cargo.toml suppresses the defer);
      # in practice the Mode 2 rust convention recognizes first and
      # wins dispatch, but c-cpp-direct's recognize must return true so
      # the standard-provider's dispatch order resolution works.
      check conv.recognize(dir, request)
      removeDir(dir)
