## DSL-port M9.R.2b — Layer-2 ``strip`` dispatch.

import repro_project_dsl

import ./toolchain
import ../types/options
import ../packages/gcc as gcc_module
import ../packages/clang as clang_module

proc strip*(opts: StripOptions): BuildActionDef =
  case currentCompiler()
  of cfGcc:   gcc_module.gccStrip(opts)
  of cfClang: clang_module.clangStrip(opts)
  of cfMsvc:
    raise newException(ValueError,
      "msvc strip not yet implemented — set compiler variant " &
      "to \"gcc\" or \"clang\"")

proc strip*(input: BuildActionDef;
            target = "";
            keepSymbols: seq[string] = @[]): BuildActionDef =
  strip(StripOptions(
    input: input,
    target: target,
    keepSymbols: keepSymbols))
