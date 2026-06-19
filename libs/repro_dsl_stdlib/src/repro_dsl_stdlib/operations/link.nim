## DSL-port M9.R.2b — Layer-2 ``link`` dispatch.

import repro_project_dsl

import ./toolchain
import ../types/library
import ../types/options
import ../packages/gcc as gcc_module
import ../packages/clang as clang_module

proc link*(opts: LinkOptions): BuildActionDef =
  ## Dispatch on ``currentCompiler()``.
  case currentCompiler()
  of cfGcc:   gcc_module.gccLink(opts)
  of cfClang: clang_module.clangLink(opts)
  of cfMsvc:
    raise newException(ValueError,
      "msvc link not yet implemented — set compiler variant " &
      "to \"gcc\" or \"clang\"")

proc link*(objects: seq[BuildActionDef];
           target: string;
           kind = lokExecutable;
           deps: seq[Library] = @[];
           soname = ""): BuildActionDef =
  ## Convenience overload — wraps the canonical named-arg form.
  link(LinkOptions(
    objects: objects,
    deps: deps,
    kind: kind,
    target: target,
    soname: soname))
