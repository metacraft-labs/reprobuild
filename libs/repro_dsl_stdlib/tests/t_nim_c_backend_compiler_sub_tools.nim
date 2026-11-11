## Every `nim c` edge declares the C compiler its backend runs, whichever
## argument form produced it.
##
## `nim c` emits C and then runs a bare `gcc` (or `clang`, or whatever
## `--cc:` selects) through `/bin/sh -c`. An edge that does not declare that
## compiler is not given its directory on `PATH`, so outside a developer
## shell it fails with `gcc: command not found`.
##
## The compiler is a property of the TOOL, not of one call site, so it is
## declared once as the typed `nim` tool's `subTools`. The `binary =`
## shorthand and the typed wrapper's own `output =` form record their edges
## through the same generated wrapper, and both must carry it. The `output =`
## form is the one a consumer reaches when it writes `nim.c(source = ...,
## output = ...)`; it had no compiler declaration at all.

import std/[os, unittest]

import repro_project_dsl
# Imported under an alias: the `package nim:` block in that module emits a
# const named `nim`, which a plain import would shadow with the module name.
import repro_dsl_stdlib/packages/nim as nim_module

const nimTool = nim_module.nim

proc registeredEdge(id: string): BuildActionDef =
  for act in registeredBuildActions():
    if act.id == id:
      return act
  raise newException(KeyError, "no registered action " & id)

suite "nim.c declares its backend C compiler":

  test "the output = form carries gcc and clang as sub-tools":
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "main.nim",
      output = "build" / "bin" / "sub_tools_output_form",
      mm = "arc")
    let edge = registeredEdge(act.id)
    check "gcc" in edge.subToolRefs
    check "clang" in edge.subToolRefs

  test "the binary = form carries the same sub-tools":
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "main.nim",
      binary = "build" / "bin" / "sub_tools_binary_form")
    let edge = registeredEdge(act.id)
    check "gcc" in edge.subToolRefs
    check "clang" in edge.subToolRefs
