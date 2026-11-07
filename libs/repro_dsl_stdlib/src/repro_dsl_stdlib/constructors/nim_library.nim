## DSL-port M9.R.2b — Layer-1 ``nim_library`` constructor.
##
## Wraps ``nim.c(--app:lib ...)`` and returns a typed ``Library``.

{.experimental: "callOperator".}

import repro_project_dsl

import ../types/library
import ../packages/nim as nim_module
import ../active_context
import ../operations/zig_c

proc activePackageName(): string {.inline.} =
  let st = tryCurrentBuildState()
  if st == nil: "" else: st.packageName

proc nim_library*(into: string;
                  source: string;
                  defines: seq[string] = @[];
                  mm = "orc";
                  paths: seq[string] = @[]): Library =
  ## Build a Nim library from one entry-point source file via
  ## ``nim c --app:lib``.
  # A zig target is threaded here: Nim's --cpu/--os and clang pointed at
  # the zig `cc` wrapper. Any other non-native target still refuses.
  let zigTarget = activeZigCrossTarget()
  var cross: ZigNimCross
  if zigTarget != nil:
    cross = zigNimCross(zigTarget, "nim_library")
  else:
    requireCrossTargetConsulted("nim_library")
  let pkg = activePackageName()
  let api = registeredLibraryApi(pkg, into)

  let target =
    if api.soname.len > 0: "lib" & api.soname & ".so"
    else: "lib" & into & ".so"
  let action = nim.c(
    source = source,
    output = targetKeyedPath(target),
    defines = defines,
    mm = mm,
    paths = paths,
    cpu = cross.cpu,
    os = cross.os,
    cc = (if zigTarget != nil: "clang" else: ""),
    clangExe = cross.ccExe,
    clangLinkerExe = cross.ccExe,
    after = (if zigTarget != nil: @[cross.wrappers] else: @[]),
    appLib = true)
  newLibrary(install = action, api = api,
             installPrefix = "usr/lib")
