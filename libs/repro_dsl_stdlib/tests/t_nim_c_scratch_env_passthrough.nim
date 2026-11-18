## Every Nim compile edge the standard library records names the four
## temp-directory variables as environment PASSTHROUGH, and nothing else.
##
## `nix develop` exports a fresh `/tmp/nix-shell.XXXXXX` as `TMPDIR`, `TMP`,
## `TEMP` and `TEMPDIR` in every shell. The compile reads them, io-mon records
## the reads, and the engine keyed an observed read by VALUE, so the first
## build in every new shell missed every Nim compile edge on an unchanged
## tree (reprobuild-pm issue
## `2026-10-18-compile-edges-record-the-shells-temp-so-every-new-nix-develop-shell-misses`).
## Passthrough keys them by name only. The end-to-end property -- a warm build
## from a "new shell" hits -- is
## `tests/integration/t_nim_compile_key_ignores_the_shells_temp_dir.nim`;
## this file pins the declaration on the edges themselves, for the
## `binary =` shorthand, the `nim_executable` / `nim_library` constructors
## (which call the typed `output =` form and add the names themselves), and
## the `ct_test_nim_unittest` compile, pins that the typed `output =` form
## alone declares none, and pins that the list is the one the
## provider and profile compiles use, so the classes cannot drift apart.
##
## No mocks: the real typed wrappers and the real registry.

import std/unittest

import repro_project_dsl
import repro_interface_artifacts
from repro_core/scratch_env import ScratchLocationEnvNames
import ct_test_nim_unittest
import repro_dsl_stdlib/constructors/nim_executable
import repro_dsl_stdlib/constructors/nim_library
# Imported under an alias: the `package nim:` block in that module emits a
# const named `nim`, which a plain import would shadow with the module name.
import repro_dsl_stdlib/packages/nim as nim_module

const nimTool = nim_module.nim

proc registeredEdge(id: string): BuildActionDef =
  ## The LAST registration under `id`: the one the graph is built from.
  let actions = registeredBuildActions()
  for i in countdown(actions.high, 0):
    if actions[i].id == id:
      return actions[i]
  raise newException(KeyError, "no registered action " & id)

suite "Nim compile edges pass the temp-directory variables through by name":

  setup:
    resetBuildActionRegistry()
    resetTargetExportRegistry()

  test "the list is the one the provider and profile compiles use":
    check @NimCompileScratchEnvNames == @["TMPDIR", "TMP", "TEMP", "TEMPDIR"]
    check @NimCompileScratchEnvNames == @ScratchLocationEnvNames
    for name in ScratchLocationEnvNames:
      check name in ProviderCompileEnvironmentPassthrough

  test "nim.c's registered edge and its returned handle carry the four names":
    let act = nimTool.c(source = "src/main.nim", binary = "build/bin/tmpprobe")
    let edge = registeredEdge(act.id)
    check edge.envPassthrough == @["TMPDIR", "TMP", "TEMP", "TEMPDIR"]
    check act.envPassthrough == edge.envPassthrough
    # Passthrough, not a declared value: the compile still runs with the
    # caller's temp directory.
    for (name, _) in edge.env:
      check name notin ScratchLocationEnvNames
    # And the payload the graph stores carries them.
    check decodeBuildActionPayload(encodeBuildActionPayload(
        edge)).envPassthrough ==
      edge.envPassthrough

  test "only the temp-directory names, whatever else the call sets":
    # `NIX_BUILD_TOP` is per-shell too but the compile does not read it, and
    # nothing else a compile reads (`HOME`, `NIM_*`, `PATH`) may be waived.
    let act = nimTool.c(source = "src/main.nim", binary = "build/bin/other",
      extraEnv = @[("NIM_FLAGS", "x")], runInSourceDir = true)
    let edge = registeredEdge(act.id)
    check edge.envPassthrough == @NimCompileScratchEnvNames
    check ("NIM_FLAGS", "x") in edge.env

  test "a repeated identical call: the last registration carries them":
    let first = nimTool.c(source = "src/main.nim", binary = "build/bin/twice")
    let second = nimTool.c(source = "src/main.nim", binary = "build/bin/twice")
    check first.id == second.id
    check registeredEdge(second.id).envPassthrough ==
      @NimCompileScratchEnvNames

  test "nim_executable and nim_library compile edges carry them":
    # Both call the typed `output =` form, not the alias, so each names the
    # four itself; without that their compile would key them by value.
    let state = beginBuildBlock("scratchprobe")
    try:
      let exe = nim_executable("hello", "src/hello.nim")
      check registeredEdge(exe.install.id).envPassthrough ==
        @NimCompileScratchEnvNames
      check exe.install.envPassthrough == @NimCompileScratchEnvNames
      let lib = nim_library("hello", "src/hello.nim")
      check registeredEdge(lib.install.id).envPassthrough ==
        @NimCompileScratchEnvNames
      check lib.install.envPassthrough == @NimCompileScratchEnvNames
    finally:
      endBuildBlock(state)

  test "the typed output= form alone declares no passthrough":
    # There is no tool-level passthrough declaration: a recipe calling the
    # typed form directly keeps keying these reads by value. Pinned so that
    # changing it is a visible decision rather than a side effect.
    let act = nimTool.c(source = "src/main.nim", output = "build/bin/typed")
    check registeredEdge(act.id).envPassthrough.len == 0

  test "the ct_test_nim_unittest compile carries them; its execute edge does not":
    let built = buildNimUnittest.build(
      source = "tests/t_probe.nim", binary = "build/test-bin/t_probe")
    let edge = registeredEdge(built.action.id)
    check edge.call.executableName == "nim"
    check edge.envPassthrough == @ScratchLocationEnvNames
    check built.action.envPassthrough == edge.envPassthrough
    # What a test does with its temp directory is the test's business.
    # The compile already claimed the binary's implicit target name.
    let run = built.testBinary.run(registerImplicitName = false)
    check registeredEdge(run.id).envPassthrough.len == 0
