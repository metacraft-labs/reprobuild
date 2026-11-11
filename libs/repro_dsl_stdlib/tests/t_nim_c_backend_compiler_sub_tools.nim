## Every `nim c` edge declares the C compiler its backend runs, whichever
## argument form produced it, and only that compiler.
##
## `nim c` emits C and then runs a bare `gcc` (`clang` on macOS) through
## `/bin/sh -c`. An edge that does not declare that compiler is not given its
## directory on `PATH`, so outside a developer shell it fails with
## `gcc: command not found`.
##
## The compiler is a property of the TOOL, not of one call site, so it is
## declared once as the typed `nim` tool's `subTools`. The `binary =`
## shorthand and the typed wrapper's own `output =` form record their edges
## through the same generated wrapper, and both must carry it. The `output =`
## form is the one a consumer reaches when it writes `nim.c(source = ...,
## output = ...)`; it had no compiler declaration at all.
##
## The OTHER platform's compiler must not be a sub-tool. Sub-tools come
## before an edge's own references on its `PATH`, so a recipe that declares
## both compilers -- reprobuild's own declares `gcc` everywhere and `clang`
## on macOS -- would have the non-default one's directory shadow the
## compiler the edge names. On macOS that directory is `/usr/bin`, which
## also holds Apple's `clang`. The PATH cases compose the edge's `PATH` the
## way the engine lowers it, from profiles shaped like that host.

import std/[os, strutils, unittest]

import repro_cli_support
import repro_project_dsl
import repro_tool_profiles
# Imported under an alias: the `package nim:` block in that module emits a
# const named `nim`, which a plain import would shadow with the module name.
import repro_dsl_stdlib/packages/nim as nim_module

const nimTool = nim_module.nim

const
  backendCompiler = when defined(macosx): "clang" else: "gcc"
  otherCompiler = when defined(macosx): "gcc" else: "clang"
  nimDir = "/fixture/nim/bin"
  backendDir = "/fixture/" & backendCompiler & "-wrapper/bin"
  # Where the non-default compiler resolves: on macOS, Apple's shim
  # directory, which also holds a `clang` that is not the declared one.
  otherDir = "/fixture/host-usr/bin"

proc registeredEdge(id: string): BuildActionDef =
  for act in registeredBuildActions():
    if act.id == id:
      return act
  raise newException(KeyError, "no registered action " & id)

proc profile(name, path: string): PathOnlyToolProfile =
  result = PathOnlyToolProfile(packageSelector: name, executableName: name,
    resolvedExecutablePath: path)
  refreshProfileIdentity(result)

proc edgePathDirs(edge: BuildActionDef): seq[string] =
  ## The edge's `PATH` as the engine composes it when lowering: the tool's
  ## own directory, then its sub-tools, then the edge's references.
  let profiles = [
    profile("nim", nimDir / "nim"),
    profile(backendCompiler, backendDir / backendCompiler),
    profile(otherCompiler, otherDir / otherCompiler)]
  let entry = actionPathEnvEntry(profiles, edge.call.packageName,
    edge.call.executableName, edge.subToolRefs & edge.toolIdentityRefs)
  check entry.startsWith("PATH=")
  entry["PATH=".len .. ^1].split(PathSep)

suite "nim.c declares its backend C compiler":

  test "the output = form carries the platform's backend compiler":
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "main.nim",
      output = "build" / "bin" / "sub_tools_output_form",
      mm = "arc")
    let edge = registeredEdge(act.id)
    check edge.subToolRefs == @[backendCompiler]

  test "the binary = form carries the same sub-tool":
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "main.nim",
      binary = "build" / "bin" / "sub_tools_binary_form")
    let edge = registeredEdge(act.id)
    check edge.subToolRefs == @[backendCompiler]
    check backendCompiler in edge.toolIdentityRefs

  test "the output = edge's PATH reaches the declared backend compiler":
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "main.nim",
      output = "build" / "bin" / "sub_tools_output_path",
      mm = "arc")
    let dirs = edgePathDirs(registeredEdge(act.id))
    check nimDir in dirs
    check backendDir in dirs
    check otherDir notin dirs

  test "a declared non-default compiler does not shadow the backend":
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "main.nim",
      binary = "build" / "bin" / "sub_tools_binary_path")
    let dirs = edgePathDirs(registeredEdge(act.id))
    check backendDir in dirs
    check otherDir notin dirs
