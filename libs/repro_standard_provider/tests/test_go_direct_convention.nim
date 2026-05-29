## Verification for the go-direct (Mode 3) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/go-mode3/binary-with-library`` plus a small
## set of scratch-directory negative cases.
##
## Coverage:
##   * ``recognize`` returns true for the Mode 3 fixture (no go.mod,
##     go on PATH).
##   * ``recognize`` returns false when a go.mod is present (the
##     Mode 2 ``go`` convention's territory).
##   * ``recognize`` returns false when the ``uses:`` block lacks ``go``.
##   * ``recognize`` returns false when a go.work is present.
##   * ``recognize`` returns false when any ``.go`` file ships
##     ``import "C"`` (cgo trigger; cgo is deferred to M36).
##   * ``emitFragment`` against the Mode 3 fixture:
##     - per-member compile actions for both ``mathlib`` (library) and
##       ``calc`` (executable);
##     - calc's link action carries the upstream library archive via
##       importcfg.link;
##     - calc's compile / link ``deps`` include mathlib's compile
##       action id (sequencing);
##     - calc's link ``inputs`` include the mathlib archive path
##       (cache-hit invalidation).
##   * cycle detection: a scratch fixture with ``depends_on a: b``
##     AND ``depends_on b: a`` rejects emitFragment with ValueError.
##   * undeclared-dep detection: a scratch fixture with
##     ``depends_on a: c`` (where ``c`` is not a declared package)
##     rejects with ValueError.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/go_direct as go_direct_convention

const
  ## ``parentDir`` four times lands at the ``reprobuild/`` repo root.
  ## The fixture lives under the sibling ``reprobuild-examples``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  Mode3Fixture =
    MetacraftRoot / "reprobuild-examples" / "go-mode3" /
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

proc goOnPath(): bool =
  if findExe("go").len > 0:
    return true
  # Fall back to the bundled Go toolchain that env.ps1 ships with on
  # Windows (the M9 harness's per-language probe does the same).
  when defined(windows):
    let goRoot = "D:/metacraft-dev-deps/go"
    if dirExists(goRoot):
      for kind, entry in walkDir(goRoot):
        if kind != pcDir:
          continue
        let candidate = entry / "go" / "bin" / "go.exe"
        if fileExists(candidate):
          let binDir = parentDir(candidate)
          putEnv("PATH", binDir & ";" & getEnv("PATH"))
          if findExe("go").len > 0:
            return true
  false

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-go-direct-test-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "go-direct convention recognition":

  test "recognize: positive — Mode 3 fixture (no go.mod, go available)":
    if not goOnPath():
      skip()
    else:
      let conv = go_direct_convention.goDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      check conv.recognize(Mode3Fixture, request)

  test "recognize: negative — go.mod at the project root":
    let dir = makeScratch("with-go-mod")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "go"
  executable hello:
    discard
""")
    createDir(dir / "hello")
    writeFile(dir / "hello" / "main.go",
      "package main\nfunc main() {}\n")
    writeFile(dir / "go.mod", "module example.com/x\ngo 1.21\n")
    let conv = go_direct_convention.goDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — uses lacks go":
    let dir = makeScratch("no-go-toolchain")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "hello")
    writeFile(dir / "hello" / "main.go",
      "package main\nfunc main() {}\n")
    let conv = go_direct_convention.goDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — go.work present (workspaces deferred)":
    let dir = makeScratch("with-go-work")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "go"
  executable hello:
    discard
""")
    createDir(dir / "hello")
    writeFile(dir / "hello" / "main.go",
      "package main\nfunc main() {}\n")
    writeFile(dir / "go.work", "go 1.21\nuse ./hello\n")
    let conv = go_direct_convention.goDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — import \"C\" anywhere (cgo deferred to M36)":
    let dir = makeScratch("with-cgo")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "go"
  executable hello:
    discard
""")
    createDir(dir / "hello")
    writeFile(dir / "hello" / "main.go", """
package main

// #include <stdio.h>
import "C"

func main() { C.puts(C.CString("hi")) }
""")
    let conv = go_direct_convention.goDirectConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

suite "go-direct convention emit (Mode 3 fixture)":

  test "emitFragment: produces per-member compile + link with importcfg wiring":
    if not goOnPath():
      skip()
    else:
      let conv = go_direct_convention.goDirectConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)

      var compileActions: seq[BuildActionDef] = @[]
      var linkActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("go-direct-compile-"):
          compileActions.add(action)
        elif action.id.startsWith("go-direct-link-"):
          linkActions.add(action)

      check compileActions.len == 2  # mathlib + calc
      check linkActions.len == 1     # calc only

      var mathlibCompile: BuildActionDef
      var calcCompile: BuildActionDef
      var sawMathlib = false
      var sawCalc = false
      for action in compileActions:
        if action.id == "go-direct-compile-mathlib":
          mathlibCompile = action
          sawMathlib = true
        elif action.id == "go-direct-compile-calc":
          calcCompile = action
          sawCalc = true
      check sawMathlib
      check sawCalc

      # The mathlib compile output is <root>/.repro/build/mathlib/mathlib.a
      var mathlibArchive = ""
      for outPath in mathlibCompile.outputs:
        let lower = outPath.toLowerAscii.replace('\\', '/')
        if lower.endsWith("/mathlib.a"):
          mathlibArchive = outPath
      check mathlibArchive.len > 0

      # The mathlib compile argv uses ``-p mathlib`` (the library
      # package name).
      let mathlibArgv = inlineArgvOf(mathlibCompile)
      var sawPMathlib = false
      for i, token in mathlibArgv:
        if token == "-p" and i + 1 < mathlibArgv.len and
            mathlibArgv[i + 1] == "mathlib":
          sawPMathlib = true
      check sawPMathlib

      # The calc compile argv uses ``-p main`` (executable members
      # always compile under the magic package name).
      let calcArgv = inlineArgvOf(calcCompile)
      var sawPMain = false
      for i, token in calcArgv:
        if token == "-p" and i + 1 < calcArgv.len and
            calcArgv[i + 1] == "main":
          sawPMain = true
      check sawPMain

      # The calc compile argv carries ``-I <mathlib archive dir>`` so
      # the bare ``mathlib`` import resolves at compile time.
      var sawIMathlibDir = false
      for i, token in calcArgv:
        if token == "-I" and i + 1 < calcArgv.len:
          let candidate = calcArgv[i + 1].toLowerAscii.replace('\\', '/')
          if candidate.endsWith("/.repro/build/mathlib"):
            sawIMathlibDir = true
      check sawIMathlibDir

      # The calc compile deps include the mathlib compile action id
      # (sequencing).
      var sawMathlibCompileDep = false
      for dep in calcCompile.deps:
        if dep == mathlibCompile.id:
          sawMathlibCompileDep = true
      check sawMathlibCompileDep

      let calcLink = linkActions[0]
      check calcLink.id == "go-direct-link-calc"

      # The link argv carries ``-L <mathlib archive dir>``.
      let calcLinkArgv = inlineArgvOf(calcLink)
      var sawLMathlibDir = false
      for i, token in calcLinkArgv:
        if token == "-L" and i + 1 < calcLinkArgv.len:
          let candidate = calcLinkArgv[i + 1].toLowerAscii.replace('\\', '/')
          if candidate.endsWith("/.repro/build/mathlib"):
            sawLMathlibDir = true
      check sawLMathlibDir

      # The link action's deps include the mathlib compile action id
      # (sequencing).
      var sawMathlibLinkDep = false
      for dep in calcLink.deps:
        if dep == mathlibCompile.id:
          sawMathlibLinkDep = true
      check sawMathlibLinkDep

      # The link action's inputs include the upstream archive path
      # (cache invalidation).
      var sawMathlibArchiveInput = false
      for inp in calcLink.inputs:
        if inp == mathlibArchive:
          sawMathlibArchiveInput = true
      check sawMathlibArchiveInput

suite "go-direct convention dep validation":

  test "depends_on cycle is rejected before any compile fires":
    if not goOnPath():
      skip()
    else:
      let dir = makeScratch("cycle")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package alphaPkg:
  uses:
    "go"
  library alpha

package betaPkg:
  uses:
    "go"
  library beta

depends_on alphaPkg: betaPkg
depends_on betaPkg: alphaPkg
""")
      createDir(dir / "alpha")
      writeFile(dir / "alpha" / "alpha.go",
        "package alpha\nfunc Alpha() int { return 1 }\n")
      createDir(dir / "beta")
      writeFile(dir / "beta" / "beta.go",
        "package beta\nfunc Beta() int { return 2 }\n")
      let conv = go_direct_convention.goDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

  test "depends_on references undeclared package — rejected":
    if not goOnPath():
      skip()
    else:
      let dir = makeScratch("undeclared")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package onlyPkg:
  uses:
    "go"
  executable hello:
    discard

depends_on onlyPkg: nonexistentPkg
""")
      createDir(dir / "hello")
      writeFile(dir / "hello" / "main.go",
        "package main\nfunc main() {}\n")
      let conv = go_direct_convention.goDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)

# ---------------------------------------------------------------------------
# Layout recognition. Pins the convention's behaviour for single-package
# fixtures using either Layout B (<member>/*.go) or Layout A
# (<root>/src/*.go).
# ---------------------------------------------------------------------------

suite "go-direct convention layout recognition":

  test "layout B: multi-package workspace with per-<member>/*.go":
    if not goOnPath():
      skip()
    else:
      let dir = makeScratch("layout-b-recognise")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package libPkg:
  uses:
    "go"
  library mylib

package binPkg:
  uses:
    "go"
  executable mybin:
    discard
""")
      createDir(dir / "mylib")
      writeFile(dir / "mylib" / "lib.go",
        "package mylib\nfunc Helper() int { return 42 }\n")
      createDir(dir / "mybin")
      writeFile(dir / "mybin" / "main.go",
        "package main\nfunc main() {}\n")
      let conv = go_direct_convention.goDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

  test "layout A: single-member workspace with src/*.go at root":
    if not goOnPath():
      skip()
    else:
      let dir = makeScratch("layout-a-bin")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package soloPkg:
  uses:
    "go"
  executable solo:
    discard
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "main.go",
        "package main\nfunc main() {}\n")
      let conv = go_direct_convention.goDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)
