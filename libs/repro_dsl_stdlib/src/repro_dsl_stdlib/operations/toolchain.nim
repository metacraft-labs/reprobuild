## DSL-port M9.R.2b — Layer-2 toolchain dispatch helper.
##
## The mid-level operation overloads (``compile``, ``link``,
## ``archive``, ``strip`` under ``operations/``) call ``currentCompiler()``
## to pick the per-compiler implementation. The dispatcher reads the
## solver-resolved ``compiler`` variant; when no variant resolution is
## available (test fixtures that haven't run the solver) it falls back
## to a thread-local override (``setCompilerOverride``) and finally to
## ``cfGcc``.
##
## The variant-read path mirrors ``active_context.nim``'s
## ``resolveToolchain`` and ``resolveCrossTarget`` — same accessor
## (``hasSolverSolution`` / ``lastSolverSolution`` / ``sol.variants``)
## per [[file:Reprobuild-Standard-Library.md][Reprobuild-Standard-Library]]
## §"Toolchain dispatch".

import std/[strutils, tables]

import repro_project_dsl
import ../configurables/variants

type
  CompilerFamily* = enum
    ## The three compiler families v1 dispatches across. ``cfMsvc`` is
    ## declared but not yet implemented — recipes that resolve the
    ## ``compiler`` variant to ``"msvc"`` raise from the per-operation
    ## dispatcher (``operations/compile.nim`` etc.) until a real msvc
    ## implementation lands.
    cfGcc
    cfClang
    cfMsvc

var
  compilerOverride {.threadvar.}: string
    ## Thread-local override for test fixtures that need to drive the
    ## dispatcher without running the variant solver. Empty means
    ## "no override; read the solver solution".

proc setCompilerOverride*(name: string) =
  ## Test-fixture helper. Pass ``""`` to clear the override and fall
  ## back to the solver-resolved value (or the ``cfGcc`` default).
  compilerOverride = name

proc parseCompilerFamily*(name: string): CompilerFamily =
  ## Map a ``compiler.value`` string onto the enum. Unknown values
  ## fall back to ``cfGcc`` — the dispatcher is forgiving so a recipe
  ## with a typo doesn't crash at graph-emission time; the per-tool
  ## wrappers downstream will surface the missing-binary error.
  case name.toLowerAscii()
  of "gcc": cfGcc
  of "clang": cfClang
  of "msvc", "cl": cfMsvc
  else: cfGcc

proc currentCompiler*(): CompilerFamily =
  ## Resolve the active compiler family. Lookup order:
  ##
  ##   1. Thread-local override (test fixtures use this).
  ##   2. Solver-resolved ``compiler`` variant.
  ##   3. Default ``cfGcc``.
  if compilerOverride.len > 0:
    return parseCompilerFamily(compilerOverride)
  if hasSolverSolution():
    let sol = lastSolverSolution()
    if "compiler" in sol.variants:
      return parseCompilerFamily(sol.variants["compiler"])
  cfGcc
