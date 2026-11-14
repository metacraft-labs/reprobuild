## The standard library's parallel tools are SIZED.
##
## An action that starts a parallel tool must not be left at the one-slot
## default: it asks RunQuota for a width range and names the flag through which
## the tool takes the grant (reprobuild-pm `spec/Build-Engine-And-Scheduler.md`,
## "Integration tiers" -> "Sized T0 actions"). The typed constructors for cargo,
## Nim compiles, make, ninja, cmake --build and meson compile record that on the
## action they register, and the payload that carries the action to the engine
## preserves it.
##
## The assertions read the REGISTERED ACTION (what the engine will run), not the
## wrapper's parameters. Two controls keep the table honest in the other
## direction: a call that starts one process (`cargo vendor`-like fetch edges,
## `nim js`, `cmake configure`) stays the one-slot default, and an older payload
## decodes unsized.

{.experimental: "callOperator".}

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packages/cargo as cargo_module
import repro_dsl_stdlib/packages/nim as nim_module
import repro_dsl_stdlib/packages/make as make_module
import repro_dsl_stdlib/packages/ninja as ninja_module
import repro_dsl_stdlib/packages/cmake as cmake_module
import repro_dsl_stdlib/packages/meson as meson_module

proc only(): BuildActionDef =
  let recorded = registeredBuildActions()
  check recorded.len == 1
  recorded[^1]

proc checkSized(action: BuildActionDef; flag: string) =
  check action.widthFlag == flag
  # One slot is the floor: a sized edge can always run, narrowly.
  check action.cpuMinMilli == 1000'u32
  # A range, not a single value: RunQuota grants the widest free width.
  check action.cpuPreferredMilli > action.cpuMinMilli

proc checkUnsized(action: BuildActionDef) =
  check action.widthFlag.len == 0
  check action.cpuMinMilli == 0'u32
  check action.cpuPreferredMilli == 0'u32

suite "parallel tools are sized":

  test "cargo build, install and test take -j":
    resetBuildActionRegistry()
    discard cargo.build(actionId = "b")
    discard cargo.install(actionId = "i", path = ".")
    discard cargo.test(actionId = "t", noRun = true)
    let recorded = registeredBuildActions()
    check recorded.len == 3
    for action in recorded:
      checkSized(action, "-j")

  test "the cargo test binary edge takes --test-threads":
    resetBuildActionRegistry()
    let binary = CargoTestBinary(path: "target/debug/deps/x-1")
    discard binary.run(actionId = "r")
    let action = only()
    check action.widthFlag == "--test-threads"
    checkSized(action, "--test-threads")

  test "nim c takes --parallelBuild:":
    resetBuildActionRegistry()
    discard nim.c(source = "src/a.nim", binary = "build/a")
    let action = only()
    check action.widthFlag == "--parallelBuild:"
    checkSized(action, "--parallelBuild:")

  test "make and ninja take -j":
    resetBuildActionRegistry()
    discard make(workDir = "b", vars = @[], targets = @["all"], actionId = "m")
    discard ninja(workDir = "b", targets = @["all"], actionId = "n")
    let recorded = registeredBuildActions()
    check recorded.len == 2
    for action in recorded:
      checkSized(action, "-j")

  test "cmake --build takes -j, or --parallel when the recipe spelled that":
    resetBuildActionRegistry()
    discard cmake.build(buildDir = "b", actionId = "j")
    discard cmake.build(buildDir = "b", parallel = 4, actionId = "p")
    let recorded = registeredBuildActions()
    check recorded.len == 2
    checkSized(recorded[0], "-j")
    checkSized(recorded[1], "--parallel")

  test "meson compile takes -j":
    resetBuildActionRegistry()
    discard meson.compile(actionId = "c")
    let action = only()
    check action.widthFlag == "-j"
    checkSized(action, "-j")

  test "calls that start one process stay the one-slot default":
    resetBuildActionRegistry()
    discard nim.js(source = "src/a.nim", output = "build/a.js",
      actionId = "js")
    discard cmake.configure(srcDir = "s", buildDir = "b",
      actionId = "cfg")
    let recorded = registeredBuildActions()
    check recorded.len == 2
    for action in recorded:
      checkUnsized(action)

suite "the width travels in the action payload":

  test "a sized action decodes with its range and flag":
    resetBuildActionRegistry()
    discard nim.c(source = "src/a.nim", binary = "build/a")
    let decoded = decodeBuildActionPayload(
      encodeBuildActionPayload(only()))
    check decoded.widthFlag == "--parallelBuild:"
    checkSized(decoded, "--parallelBuild:")

  test "a payload from before the width existed decodes unsized":
    resetBuildActionRegistry()
    discard nim.c(source = "src/a.nim", binary = "build/a")
    let older = encodeBuildActionPayloadAtVersion(only(), 32'u16)
    check buildActionPayloadVersion(older) == 32'u16
    checkUnsized(decodeBuildActionPayload(older))
