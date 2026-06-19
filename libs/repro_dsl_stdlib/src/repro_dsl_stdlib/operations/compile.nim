## DSL-port M9.R.2b — Layer-2 ``compile`` dispatch.
##
## Recipes call ``compile(opts: CompileOptions)`` (or the convenience
## overload ``compile(source, target, inputs)``); the dispatcher
## reads the active ``compiler`` variant via
## ``operations/toolchain.currentCompiler()`` and routes to the
## per-compiler ``<x>Compile`` implementation under
## ``packages/<x>.nim``.

import repro_project_dsl

import ./toolchain
import ../types/options
import ../packages/gcc as gcc_module
import ../packages/clang as clang_module

proc compile*(opts: CompileOptions): BuildActionDef =
  ## Dispatch on ``currentCompiler()``.
  case currentCompiler()
  of cfGcc:   gcc_module.gccCompile(opts)
  of cfClang: clang_module.clangCompile(opts)
  of cfMsvc:
    raise newException(ValueError,
      "msvc compile not yet implemented — set compiler variant " &
      "to \"gcc\" or \"clang\"")

proc compile*(source: string;
              target: string;
              inputs: seq[LibraryApi] = @[];
              standard = "";
              defines: seq[string] = @[]): BuildActionDef =
  ## Convenience overload that builds a ``CompileOptions`` literal
  ## from the canonical named-arg shape recipe authors use most.
  compile(CompileOptions(
    source: source,
    target: target,
    inputs: inputs,
    defines: defines,
    standard: standard))
