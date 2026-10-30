## Under a non-native `--target`, a constructor that does not thread the
## target refuses before it emits anything.
##
## ReproOS-Add-On-Mode A15. Before the guard, `repro build --target=armv7-…`
## of a recipe built with `autotools_package` exited 0 with an x86-64
## `libz.so` mirrored under `install@armv7-…` and a cache identity that said
## armv7. Every constructor except `cargo_package` ignored the CrossTarget
## slot. `requireCrossTargetConsulted` is now the first statement of each of
## them, and of the `compile` / `link` / `nim.c` operations the C and Nim
## constructors reach.
##
## WHAT IS EXERCISED, AND WHAT IS MOCKED. Nothing is mocked. Each case opens
## a real `build:` frame (`beginBuildBlock`, what the lowered `build:` body
## calls), sets the target the way `--target` does (`REPRO_VARIANTS`), calls
## the constructor as a recipe does, and reads the action registry the
## engine would emit from. "Nothing emitted" is the registry being empty
## after the refusal. The end-to-end half (exit status, no `install@<triple>`
## mirror, nothing in the store) is
## `tests/integration/t_target_build_refuses_a_recipe_that_does_not_thread_it`.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/active_context
import repro_dsl_stdlib/toolchain_policy
import repro_dsl_stdlib/operations/compile
import repro_dsl_stdlib/operations/link
import repro_dsl_stdlib/constructors/c_executable
import repro_dsl_stdlib/constructors/nim_executable
import repro_dsl_stdlib/constructors/nim_library
import repro_dsl_stdlib/constructors/cmake_package
import repro_dsl_stdlib/constructors/autotools_package
import repro_dsl_stdlib/constructors/meson_package
import repro_dsl_stdlib/constructors/go_package
import repro_dsl_stdlib/constructors/cabal_package
import repro_dsl_stdlib/constructors/node_package
import repro_dsl_stdlib/constructors/cargo_package

const
  Triple = "armv7-unknown-linux-musleabihf"
  Recipe = "hostOnlyProbe"

proc withTarget(value: string; body: proc()) =
  let saved = getEnv("REPRO_VARIANTS")
  if value.len > 0: putEnv("REPRO_VARIANTS", "targetTriple=" & value)
  else: delEnv("REPRO_VARIANTS")
  try: body()
  finally:
    if saved.len > 0: putEnv("REPRO_VARIANTS", saved)
    else: delEnv("REPRO_VARIANTS")

proc inBuild(body: proc()) =
  ## One `build:` frame for `Recipe`, with an empty action registry.
  resetBuildActionRegistry()
  let state = beginBuildBlock(Recipe)
  try: body()
  finally: endBuildBlock(state)

proc refusal(call: proc()): string =
  ## The refusal's message, or "" when `call` did not raise.
  try:
    call()
  except ValueError as e:
    return e.msg
  ""

proc checkRefused(caller: string; call: proc()) =
  let msg = refusal(call)
  checkpoint(caller & " -> " & msg)
  check msg.len > 0
  check ("recipe '" & Recipe & "'") in msg
  check caller in msg
  check Triple in msg
  check registeredBuildActions().len == 0

suite "--target refuses every constructor that does not thread it":

  test "each refuses before emitting, naming the recipe, itself and the target":
    withTarget(Triple, proc() =
      let cases: seq[(string, proc())] = @[
        ("compile", proc() =
          discard compile("src/a.c", "build/a.o")),
        ("link", proc() =
          discard link(@[], "build/a")),
        ("compile", proc() =
          discard c_executable("hello", @["src/hello.c"])),
        ("nim_executable", proc() =
          discard nim_executable("hello", "src/hello.nim")),
        ("nim_library", proc() =
          discard nim_library("hello", "src/hello.nim")),
        ("cmake_package", proc() =
          discard cmake_package("src")),
        ("autotools_package", proc() =
          discard autotools_package("src")),
        ("meson_package", proc() =
          discard meson_package("src")),
        ("go_package", proc() =
          discard go_package("hello")),
        ("cabal_package", proc() =
          discard cabal_package("exe:hello")),
        ("node_package", proc() =
          discard node_package(entry = "bundle/hello.js")),
      ]
      for i in 0 ..< cases.len:
        let caller = cases[i][0]
        let call = cases[i][1]
        inBuild(proc() = checkRefused(caller, call)))

  test "outside a build: block the refusal is unconditional":
    withTarget(Triple, proc() =
      resetBuildActionRegistry()
      setCurrentOwningPackageOverride(Recipe)
      defer: clearCurrentOwningPackageOverride()
      checkRefused("compile", proc() =
        discard compile("src/a.c", "build/a.o")))

suite "what the guard lets through":

  test "a native build is unchanged":
    withTarget("", proc() =
      inBuild(proc() =
        check refusal(proc() =
          discard compile("src/a.c", "build/a.o")) == ""
        check registeredBuildActions().len == 1))
    withTarget("native", proc() =
      inBuild(proc() =
        check refusal(proc() =
          discard compile("src/a.c", "build/a.o")) == ""))

  test "a recipe that read activeCrossTarget() threads it itself":
    withTarget(Triple, proc() =
      inBuild(proc() =
        check activeCrossTarget().triple == Triple
        let msg = refusal(proc() =
          discard compile("src/a.c", "build/a.o"))
        checkpoint(msg)
        check msg == ""
        check registeredBuildActions().len == 1))

  test "cargo_package is cross-aware and does not lift the guard for others":
    withTarget(Triple, proc() =
      inBuild(proc() =
        setCurrentOwningPackageOverride(Recipe)
        defer: clearCurrentOwningPackageOverride()
        let res = cargo_package()
        check res.compileEdge.id.len > 0
        let emitted = registeredBuildActions().len
        let msg = refusal(proc() = discard cmake_package("src"))
        check "cmake_package" in msg
        check registeredBuildActions().len == emitted))

suite "nested frames, helper reads and host triples":

  test "a read in the package's build: covers an artifact frame nested in it":
    withTarget(Triple, proc() =
      inBuild(proc() =
        discard activeCrossTarget()
        let inner = beginBuildBlock(Recipe, ownerKind = "executable",
          ownerName = "hello")
        try:
          check refusal(proc() =
            discard compile("src/a.c", "build/a.o")) == ""
        finally:
          endBuildBlock(inner)))

  test "a read in another package's enclosing frame does not cover this one":
    withTarget(Triple, proc() =
      inBuild(proc() =
        discard activeCrossTarget()
        let other = beginBuildBlock("someOtherPackage")
        try:
          check "compile" in refusal(proc() =
            discard compile("src/a.c", "build/a.o"))
        finally:
          endBuildBlock(other)))

  test "a helper reading through peekActiveCrossTarget lifts nothing":
    withTarget(Triple, proc() =
      inBuild(proc() =
        proc helper(): string = peekActiveCrossTarget().triple
        check helper() == Triple
        let inner = beginBuildBlock(Recipe, ownerKind = "executable",
          ownerName = "hello")
        try:
          check helper() == Triple
          check "compile" in refusal(proc() =
            discard compile("src/a.c", "build/a.o"))
        finally:
          endBuildBlock(inner)
        check "compile" in refusal(proc() =
          discard compile("src/a.c", "build/a.o"))))

  test "--target naming the build host is native: no refusal":
    when defined(linux) and defined(amd64):
      for host in ["x86_64-unknown-linux-gnu", "x86_64-pc-linux-gnu"]:
        withTarget(host, proc() =
          check not isCrossTriple(host)
          check activeTargetTriple() == ""
          check activeTargetTripleTag() == ""
          inBuild(proc() =
            check refusal(proc() =
              discard compile("src/a.c", "build/a.o")) == ""))
      check isCrossTriple("x86_64-unknown-linux-musl")
    check isCrossTriple(Triple)
    check not isCrossTriple("native")
