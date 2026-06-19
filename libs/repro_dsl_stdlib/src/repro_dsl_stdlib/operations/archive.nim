## DSL-port M9.R.2b — Layer-2 ``archive`` dispatch.

import repro_project_dsl

import ./toolchain
import ../types/options
import ../packages/gcc as gcc_module
import ../packages/clang as clang_module

proc archive*(opts: ArchiveOptions): BuildActionDef =
  case currentCompiler()
  of cfGcc:   gcc_module.gccArchive(opts)
  of cfClang: clang_module.clangArchive(opts)
  of cfMsvc:
    raise newException(ValueError,
      "msvc archive not yet implemented — set compiler variant " &
      "to \"gcc\" or \"clang\"")

proc archive*(objects: seq[BuildActionDef];
              target: string;
              modifiers = "rcs"): BuildActionDef =
  archive(ArchiveOptions(
    objects: objects,
    target: target,
    modifiers: modifiers))
