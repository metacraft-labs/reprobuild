## DSL-port M9.R.2b — Layer-1 ``nim_library`` constructor.
##
## Wraps ``nim.c(--app:lib ...)`` and returns a typed ``Library``.
##
## The shared library takes the layout every Layer-1 constructor gives one
## (``shared_library_layout``; From-Source-Build-Recipes.md, the ``api:``
## block's ``soname`` and ``sover``): on an ELF target it is written as
## ``lib/lib<soname>.so.<sover>``, carries that string as its SONAME
## (``--passL:-Wl,-soname,<SONAME>``), and ``lib/lib<soname>.so`` is a
## link-time symlink to it (``Library.linkTimeName``). Without ``sover``
## the file and its SONAME are ``lib/lib<soname>.so``; without an ``api:``
## block the base name is ``into``.

{.experimental: "callOperator".}

import repro_project_dsl

import ../types/library
import ../packages/nim as nim_module
import ../active_context
import ../operations/zig_c
import ./shared_library_layout

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

  # One name drives the file, ``-Wl,-soname,`` and the declared output,
  # as for ``c_library``: a consumer's ``DT_NEEDED`` is the SONAME, and the
  # loader opens a file of exactly that name.
  let layout = sharedLibraryLayout(api, into)
  let output = targetKeyedPath(layout.target)
  var action = nim.c(
    source = source,
    output = output,
    defines = defines,
    mm = mm,
    paths = paths,
    cpu = cross.cpu,
    os = cross.os,
    cc = (if zigTarget != nil: "clang" else: ""),
    clangExe = cross.ccExe,
    clangLinkerExe = cross.ccExe,
    passL = (if layout.soname.len > 0: @["-Wl,-soname," & layout.soname]
             else: @[]),
    after = (if zigTarget != nil: @[cross.wrappers] else: @[]),
    appLib = true)
  # This calls the typed `nim.c(..., output = ...)` form, which declares
  # no passthrough of its own; only the `binary =` alias adds it. Name the
  # temp-directory variables here as that alias does, for the reason
  # `NimCompileScratchEnvNames` states: keyed by value, the first build in
  # every new `nix develop` shell would recompile this edge.
  appendRegisteredActionEnvPassthrough(action, NimCompileScratchEnvNames)
  result = newLibrary(install = action, api = api,
                      installPrefix = "usr/lib")
  result.linkTimeName = linkTimeNameAction("nim-library-link-time-name-",
    pkg, layout, action, output)
