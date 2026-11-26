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
##
## ``linkKind static`` builds a static archive instead, with
## ``nim c --app:staticlib``: ``lib/lib<soname>.a``, the path ``c_library``
## writes one to. An archive has no SONAME, so there is no ``-Wl,-soname,``
## and no link-time symlink. Unlike a shared Nim library, an archive does
## not start the Nim runtime from a loader constructor: its consumer calls
## ``NimMain()`` before calling into it. Under a zig target ``static`` is
## refused: nim archives a clang build with ``llvm-ar`` from ``PATH``, a
## tool the ``cross_zig`` wrappers do not provide, so the edge would depend
## on whatever the host has. ``linkKind both`` builds the shared library
## only, exactly as ``c_library`` does, so the two constructors agree on it.

{.experimental: "callOperator".}

import std/os

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
  ## ``nim c --app:lib``, or ``--app:staticlib`` for ``linkKind static``.
  # A zig target is threaded here: Nim's --cpu/--os and clang pointed at
  # the zig `cc` wrapper. Any other non-native target still refuses.
  let zigTarget = activeZigCrossTarget()
  let pkg = activePackageName()
  let api = registeredLibraryApi(pkg, into)
  let isStatic = api.linkKind == llkStatic
  # Refuse before ``zigNimCross``, which registers the target's wrapper
  # edge: a refused library leaves nothing behind.
  if isStatic and zigTarget != nil:
    raise newException(ValueError,
      "nim_library(into = \"" & into & "\"): `linkKind static` is not " &
      "supported under the zig target " & zigTarget.triple & ": nim archives " &
      "a clang build with `llvm-ar` from PATH, which the target's toolchain " &
      "does not provide. Build it natively, or declare `linkKind shared`.")
  var cross: ZigNimCross
  if zigTarget != nil:
    cross = zigNimCross(zigTarget, "nim_library")
  else:
    requireCrossTargetConsulted("nim_library")

  if isStatic:
    # A static archive: no SONAME and no link-time symlink, written where
    # ``c_library`` writes one (``lib/lib<soname>.a``).
    let baseName = if api.soname.len > 0: api.soname else: into
    let archive = targetKeyedPath("lib" / ("lib" & baseName & ".a"))
    let action = nim.c(
      source = source,
      output = archive,
      defines = defines,
      mm = mm,
      paths = paths,
      appStaticLib = true)
    result = newLibrary(install = action, api = api,
                        installPrefix = "usr/lib")
    # A consumer's link searches where this edge writes the archive.
    result.linkDir = archive.parentDir
    return

  # One name drives the file, ``-Wl,-soname,`` and the declared output,
  # as for ``c_library``: a consumer's ``DT_NEEDED`` is the SONAME, and the
  # loader opens a file of exactly that name.
  let layout = sharedLibraryLayout(api, into)
  let output = targetKeyedPath(layout.target)
  let action = nim.c(
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
  result = newLibrary(install = action, api = api,
                      installPrefix = "usr/lib")
  # A consumer's link searches where this edge writes the library, as for
  # ``c_library``.
  result.linkDir = output.parentDir
  result.linkTimeName = linkTimeNameAction("nim-library-link-time-name-",
    pkg, layout, action, output)
