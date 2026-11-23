## DSL-port M9.R.2b — Layer-1 ``nim_executable`` constructor.

{.experimental: "callOperator".}

import repro_project_dsl

import ../types/executable
import ../packages/nim as nim_module
import ../active_context
import ../operations/zig_c

proc nim_executable*(into: string;
                     source: string;
                     defines: seq[string] = @[];
                     mm = "orc";
                     paths: seq[string] = @[]): Executable =
  # A zig target is threaded here: Nim's --cpu/--os and clang pointed at
  # the zig `cc` wrapper. Any other non-native target still refuses.
  let zigTarget = activeZigCrossTarget()
  var cross: ZigNimCross
  if zigTarget != nil:
    cross = zigNimCross(zigTarget, "nim_executable")
  else:
    requireCrossTargetConsulted("nim_executable")
  let action = nim.c(
    source = source,
    output = targetKeyedPath(into),
    defines = defines,
    mm = mm,
    paths = paths,
    cpu = cross.cpu,
    os = cross.os,
    cc = (if zigTarget != nil: "clang" else: ""),
    clangExe = cross.ccExe,
    clangLinkerExe = cross.ccExe,
    after = (if zigTarget != nil: @[cross.wrappers] else: @[]))
  newExecutable(install = action, executableName = into,
                installPrefix = "usr/bin")
