## DSL-port M9.R.2b — Layer-1 ``nim_executable`` constructor.

{.experimental: "callOperator".}

import repro_project_dsl

import ../types/executable
import ../packages/nim as nim_module

proc nim_executable*(into: string;
                     source: string;
                     defines: seq[string] = @[];
                     mm = "orc";
                     paths: seq[string] = @[]): Executable =
  let action = nim.c(
    source = source,
    output = into,
    defines = defines,
    mm = mm,
    paths = paths)
  newExecutable(install = action, executableName = into,
                installPrefix = "usr/bin")
