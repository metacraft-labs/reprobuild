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
##   * ``recognize`` returns TRUE when any ``.go`` file ships
##     ``import "C"`` (M36: cgo lifted; routes through ``go build``).
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
##
## M36 cross-language coverage:
##   * Forward direction (Go binary → C library, cgo path): the
##     ``mixed/go-uses-cpp-lib`` fixture produces a per-source ``gcc -c``
##     compile + ``ar rcs libmathlib.a`` archive action, plus a
##     ``go-direct-build-calc`` cgo ``go build`` action. The action's
##     argv carries ``-ldflags=-extldflags "-L<dir> -lmathlib"`` and its
##     deps/inputs include the upstream archive.
##   * Reverse direction (C++ binary → Go c-archive): the
##     ``mixed/cpp-uses-go-lib`` fixture produces a
##     ``go-direct-c-archive-goaddlib`` ``go build -buildmode=c-archive``
##     action emitting ``libgoaddlib.a`` AND ``libgoaddlib.h``, plus a
##     per-source ``g++ -c`` compile + ``g++ -o cppapp.exe`` link with
##     the Go archive threaded as a trailing positional + Go runtime
##     libs.
##   * Pure-Go regression: the M31 ``go-mode3/binary-with-library``
##     fixture continues to emit ``go-direct-compile-*`` +
##     ``go-direct-link-*`` actions (the M31 fast path), NOT
##     ``go-direct-build-*`` (which would mean we'd lost the
##     ``go tool compile`` regression).
##   * Cycle detection extends to cross-language: a workspace with
##     ``depends_on goApp: cLib`` AND ``depends_on cLib: goApp`` is
##     rejected.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/go_direct as go_direct_convention
import repro_test_support

const
  ## ``parentDir`` four times lands at the ``reprobuild/`` repo root.
  ## The fixture lives under the sibling ``reprobuild-examples``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  Mode3Fixture =
    MetacraftRoot / "reprobuild-examples" / "go-mode3" /
      "binary-with-library"
  Mode3MixedForwardFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "go-uses-cpp-lib"
  Mode3MixedReverseFixture =
    MetacraftRoot / "reprobuild-examples" / "mixed" / "cpp-uses-go-lib"

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

# Go is not part of the Windows dev-env (the host PATH the test
# harness inherits does not include go.exe). Gate to platforms
# where the convention can actually exercise go list -export.
when isNixSupported:
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

  test "recognize: positive — import \"C\" anywhere (M36: cgo lifted)":
    # M36 lifts the M31 cgo-rejection. A workspace with ``import "C"``
    # now routes through the go-direct convention; the per-member
    # ``go build`` path (instead of ``go tool compile / go tool link``)
    # handles cgo's preprocessor + linker integration.
    if not goOnPath():
      skip()
    else:
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
      check conv.recognize(dir, request)
      removeDir(dir)

when isNixSupported:
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

when isNixSupported:
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

when isNixSupported:
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

# ---------------------------------------------------------------------------
# M36 cross-language Go ↔ C/C++ verification.
#
# Forward direction (Go binary → C library, cgo): the go-direct
# convention emits per-source ``gcc -c`` + ``ar rcs lib<name>.a`` for
# the C library plus a Go ``go build`` action that threads
# ``-ldflags=-extldflags "-L<dir> -l<libname>"`` onto its argv.
#
# Reverse direction (C++ binary → Go c-archive): the convention emits
# the Go library with ``go build -buildmode=c-archive`` (derived from
# the ``cConsumable`` flag the dep graph sets) landing at
# ``lib<name>.a``, plus per-source ``g++ -c`` + terminal ``g++ -o``
# for the C++ binary with the Go archive threaded as a trailing
# positional + the platform-specific Go runtime libs.
# ---------------------------------------------------------------------------

when isNixSupported:
  suite "go-direct convention M36 cross-language (forward direction)":

    test "forward: Go binary uses cgo and picks up C archive via -ldflags":
      if not goOnPath():
        skip()
      else:
        let conv = go_direct_convention.goDirectConvention()
        let request = dummyRequest(Mode3MixedForwardFixture)
        require conv.recognize(Mode3MixedForwardFixture, request)
        let fragment = conv.emitFragment(Mode3MixedForwardFixture, request)

        var archiveAction: BuildActionDef
        var calcBuildAction: BuildActionDef
        var sawArchive = false
        var sawCalcBuild = false
        var sawCcompile = false
        for node in fragment.nodes:
          if node.kind != gnkAction:
            continue
          let action = decodeBuildActionPayload(toBytes(node.payload))
          if action.id == "go-xlang-ccpp-archive-mathlib":
            archiveAction = action
            sawArchive = true
          elif action.id == "go-direct-build-calc":
            calcBuildAction = action
            sawCalcBuild = true
          elif action.id.startsWith("go-xlang-ccpp-compile-mathlib"):
            sawCcompile = true

        # The convention emits at least: 1 per-source compile + 1 archive +
        # 1 Go cgo build. The C/C++ helpers carry the go-xlang-ccpp- prefix
        # to discriminate from the rust-direct convention's
        # rust-xlang-ccpp- and the Nim convention's nim-xlang-ccpp-.
        check sawArchive
        check sawCalcBuild
        check sawCcompile

        # The archive output lands at .repro/build/mathlib/libmathlib.a
        # (the cross-language schema shared with c-cpp-direct).
        var archiveOutput = ""
        for outPath in archiveAction.outputs:
          let lower = outPath.toLowerAscii.replace('\\', '/')
          if lower.endsWith("/libmathlib.a"):
            archiveOutput = outPath
        check archiveOutput.len > 0

        # The calc build action's deps include the archive action id.
        var sawArchiveDep = false
        for dep in calcBuildAction.deps:
          if dep == archiveAction.id:
            sawArchiveDep = true
        check sawArchiveDep

        # The calc build action's inputs include the upstream archive
        # (cache invalidation).
        var sawArchiveInput = false
        for inp in calcBuildAction.inputs:
          if inp == archiveOutput:
            sawArchiveInput = true
        check sawArchiveInput

        # The calc build argv carries the canonical cgo → C archive
        # ldflags: ``-ldflags=-extldflags "-L<dir> -lmathlib"`` (the
        # exact form Go's linker expects when forwarding to gcc's ld).
        let calcArgv = inlineArgvOf(calcBuildAction)
        var sawLdflags = false
        var sawLmathlib = false
        for token in calcArgv:
          if token.startsWith("-ldflags=-extldflags"):
            sawLdflags = true
            if "-lmathlib" in token:
              sawLmathlib = true
        check sawLdflags
        check sawLmathlib

when isNixSupported:
  suite "go-direct convention M36 cross-language (reverse direction)":

    test "reverse: Go library emits -buildmode=c-archive when consumed by C++":
      if not goOnPath():
        skip()
      else:
        let conv = go_direct_convention.goDirectConvention()
        let request = dummyRequest(Mode3MixedReverseFixture)
        require conv.recognize(Mode3MixedReverseFixture, request)
        let fragment = conv.emitFragment(Mode3MixedReverseFixture, request)

        var goaddlibAction: BuildActionDef
        var cppappLinkAction: BuildActionDef
        var sawGoaddlib = false
        var sawCppLink = false
        var sawCppCompile = false
        for node in fragment.nodes:
          if node.kind != gnkAction:
            continue
          let action = decodeBuildActionPayload(toBytes(node.payload))
          if action.id == "go-direct-c-archive-goaddlib":
            goaddlibAction = action
            sawGoaddlib = true
          elif action.id == "go-xlang-ccpp-exec-link-cppapp":
            cppappLinkAction = action
            sawCppLink = true
          elif action.id.startsWith("go-xlang-ccpp-exec-compile-cppapp"):
            sawCppCompile = true
        check sawGoaddlib
        check sawCppLink
        check sawCppCompile

        # The goaddlib argv carries -buildmode=c-archive (NOT the M31
        # ``go tool compile`` path).
        let goaddlibArgv = inlineArgvOf(goaddlibAction)
        var sawCArchiveFlag = false
        for token in goaddlibArgv:
          if token == "-buildmode=c-archive":
            sawCArchiveFlag = true
        check sawCArchiveFlag

        # The goaddlib output lands at the canonical archive path
        # .repro/build/goaddlib/libgoaddlib.a (shared schema with
        # c-cpp-direct + Nim + Rust). Go's c-archive build mode also
        # auto-emits a sibling libgoaddlib.h header in the same dir.
        var goaddlibArchiveOut = ""
        var sawHeaderOut = false
        for outPath in goaddlibAction.outputs:
          let lower = outPath.toLowerAscii.replace('\\', '/')
          if lower.endsWith("/libgoaddlib.a"):
            goaddlibArchiveOut = outPath
          elif lower.endsWith("/libgoaddlib.h"):
            sawHeaderOut = true
        check goaddlibArchiveOut.len > 0
        check sawHeaderOut

        # The cppapp link action's deps include the goaddlib action id.
        var sawGoaddlibDep = false
        for dep in cppappLinkAction.deps:
          if dep == goaddlibAction.id:
            sawGoaddlibDep = true
        check sawGoaddlibDep

        # The cppapp link action's inputs include the upstream archive.
        var sawGoaddlibInput = false
        for inp in cppappLinkAction.inputs:
          if inp == goaddlibArchiveOut:
            sawGoaddlibInput = true
        check sawGoaddlibInput

        # The cppapp link argv carries the archive as a trailing
        # positional AND the platform-specific Go runtime libs.
        let cppappArgv = inlineArgvOf(cppappLinkAction)
        var sawArchive = false
        for token in cppappArgv:
          if token == goaddlibArchiveOut:
            sawArchive = true
        check sawArchive
        when defined(windows):
          # Windows MinGW: -lws2_32 -lwinmm -lbcrypt -lntdll -luserenv
          # -ladvapi32
          var sawWs232 = false
          var sawBcrypt = false
          var sawNtdll = false
          for token in cppappArgv:
            if token == "-lws2_32": sawWs232 = true
            if token == "-lbcrypt": sawBcrypt = true
            if token == "-lntdll": sawNtdll = true
          check sawWs232
          check sawBcrypt
          check sawNtdll
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

when isNixSupported:
  suite "go-direct convention M36 pure-Go regression":

    test "M31 fixture (pure Go workspace) still uses go tool compile / link":
      # The go-mode3/binary-with-library fixture has no cgo and no C
      # deps — so no member is usesCgo / cConsumable. The convention
      # must STILL emit the M31 fast-path ``go-direct-compile-*`` +
      # ``go-direct-link-*`` actions (NOT ``go-direct-build-*``). This
      # is the load-bearing regression check for M31 behaviour.
      if not goOnPath():
        skip()
      else:
        let conv = go_direct_convention.goDirectConvention()
        let request = dummyRequest(Mode3Fixture)
        require conv.recognize(Mode3Fixture, request)
        let fragment = conv.emitFragment(Mode3Fixture, request)
        var sawCompile = false
        var sawLink = false
        var sawCgoBuild = false
        var sawCArchive = false
        for node in fragment.nodes:
          if node.kind != gnkAction:
            continue
          let action = decodeBuildActionPayload(toBytes(node.payload))
          if action.id.startsWith("go-direct-compile-"):
            sawCompile = true
          elif action.id.startsWith("go-direct-link-"):
            sawLink = true
          elif action.id.startsWith("go-direct-build-"):
            sawCgoBuild = true
          elif action.id.startsWith("go-direct-c-archive-"):
            sawCArchive = true
        check sawCompile
        check sawLink
        check not sawCgoBuild
        check not sawCArchive

when isNixSupported:
  suite "go-direct convention M36 cross-language cycle + undeclared":

    test "forward cycle: Go binary depends_on C lib AND C lib depends_on Go app — rejected":
      if not goOnPath():
        skip()
      else:
        let dir = makeScratch("xlang-cycle")
        writeFile(dir / "repro.nim", """
import repro_project_dsl
import repro_test_support

package cLibPkg:
  uses:
    "gcc >=11"
  library clib

package goAppPkg:
  uses:
    "go"
  executable goapp:
    discard

depends_on goAppPkg: cLibPkg
depends_on cLibPkg: goAppPkg
""")
      createDir(dir / "clib" / "src")
      writeFile(dir / "clib" / "src" / "add.c",
        "int add(int a, int b) { return a + b; }\n")
      createDir(dir / "goapp")
      writeFile(dir / "goapp" / "main.go",
        "package main\n\n// #include <stdio.h>\nimport \"C\"\n" &
        "func main() { C.puts(C.CString(\"hi\")) }\n")
      let conv = go_direct_convention.goDirectConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      expect ValueError:
        discard conv.emitFragment(dir, request)
      removeDir(dir)
