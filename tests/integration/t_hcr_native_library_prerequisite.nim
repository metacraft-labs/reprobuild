## Evaluate the real producer recipe, not a second copy of its declaration.
## No mocks: the refusal arm offers the real compiler as cc with the declared
## role absent. Actual compilation and symbol validation are graph actions,
## never test-body helper compilation.
## This went red on f1f83dc4: no hcr-agent-lib target or producing edge existed.
import std/[algorithm, os, osproc, strtabs, strutils, tempfiles, unittest]
import repro_core/ambient_execution
import repro_project_dsl
import ../../repro as producer

const Root = currentSourcePath().parentDir.parentDir.parentDir
const LibraryId = "reprobuild.hcr_agent.lib"
const SymbolsId = "reprobuild.hcr_agent.symbols"

when defined(reproProviderMode):
  # The suite builds in provider mode; importing a recipe then registers its
  # interface only. Evaluate its actual build body explicitly in that mode.
  buildReprobuildPackage()

let actions = registeredBuildActions()
let targets = registeredBuildTargets()

proc action(id: string): BuildActionDef =
  for candidate in actions:
    if candidate.id == id: return candidate
  raise newException(ValueError, "missing canonical native producer: " & id)

proc command(edge: BuildActionDef): string =
  for arg in edge.call.arguments:
    if arg.name == "command": return arg.encodedValue
  raise newException(ValueError, "producer is not a shell action")

proc members(name: string): seq[string] =
  for candidate in targets:
    if candidate.name == name: result.add(candidate.actions)

when defined(linux) or defined(macosx):
  suite "canonical native HCR prerequisite":
    test "the Just entrypoint bootstraps the source-matched CLI":
      # Ask Just to resolve its real recipe, including its prerequisite.
      # Actual bootstrap and graph execution are separately qualified with
      # the producer shell's ordinary PATH, which may hold an older engine.
      let entry = uncontrolledExecCmdEx("just --show hcr-agent-lib",
        workingDir = Root)
      checkpoint entry.output
      require entry.exitCode == 0
      check "hcr-agent-lib: bootstrap" in entry.output
      check "./build/bin/repro build --tool-provisioning=path --daemon=off .#hcr-agent-lib" in entry.output

    test "named producer owns the complete source tree and both healthy outputs":
      check LibraryId in members("hcr-agent-lib")
      let edge = action(LibraryId)
      check "libs/repro_hcr_agent/build_lib.sh" in edge.inputs
      check "libs/repro_hcr_agent/c" in edge.inputs
      when defined(macosx):
        const name = "librepro_hcr_agent.dylib"
      else:
        const name = "librepro_hcr_agent.so"
      check edge.outputs.sorted == @[
        "libs/repro_hcr_agent/build/" & name,
        "libs/repro_hcr_agent/build/lib/" & name].sorted
      check LibraryId in members("test")
      check SymbolsId in members("test")
      check LibraryId notin members("apps")
      check LibraryId notin members("release")
      var ownBuildAction = ""
      for candidate in actions:
        if "tests/integration/t_hcr_native_library_prerequisite.nim" in candidate.inputs:
          ownBuildAction = candidate.id
          check candidate.id in members("test")
      check ownBuildAction.len > 0
      let symbols = action(SymbolsId)
      check LibraryId in symbols.deps
      check edge.outputs[0] in symbols.inputs
      check "libs/repro_hcr_agent/check_symbols.sh" in symbols.inputs

    test "the symbol check is the canonical script after the producer":
      let symbols = action(SymbolsId)
      check command(symbols) == "bash libs/repro_hcr_agent/check_symbols.sh"
      check LibraryId in symbols.deps
      check "nm" in symbols.toolIdentityRefs
      check "bash" in symbols.toolIdentityRefs

    test "an absent declared compiler cannot fall back to a real cc":
      let scratch = createTempDir("hcr-compiler-role-", "")
      defer: removeDir(scratch)
      when defined(macosx):
        const compiler = "clang"
      else:
        const compiler = "gcc"
      let realCompiler = uncontrolledFindExe(compiler)
      require realCompiler.len > 0
      createSymlink(realCompiler, scratch / "cc")
      var env = newStringTable(modeCaseSensitive)
      for key, value in envPairs(): env[key] = value
      env["PATH"] = scratch
      let refused = uncontrolledExecCmdEx(command(action(LibraryId)),
        workingDir = Root, env = env)
      checkpoint refused.output
      check refused.exitCode != 0
      check "requires declared " & compiler in refused.output
      check "Compiling" notin refused.output
else:
  suite "native HCR producer platform boundary":
    test "the native prerequisite does not qualify Windows":
      check members("hcr-agent-lib").len == 0
