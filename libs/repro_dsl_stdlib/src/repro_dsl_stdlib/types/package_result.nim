## DSL-port M9.R.2b — multi-artifact package result records.
##
## ``meson_package(...)`` / ``cmake_package(...)`` /
## ``autotools_package(...)`` run a configure + build + install
## pipeline once and return a multi-artifact result whose
## ``.executable(name)`` / ``.library(name)`` / ``.files(name)`` methods
## slice install components into individual artifact bindings — one
## tool invocation maps to many artifact bindings without re-running
## the upstream build.
##
## v1 component layout: the slicing methods consult a hard-coded
## standard-layout table (``"runtime" -> "usr/bin"``, ``"library" ->
## "usr/lib"``, etc.) populated by each constructor at result
## construction time. Recipes that need a non-standard layout pass a
## populated ``components`` table to the result's ``newXResult``
## convenience constructor (the constructors expose this via their
## ``components`` argument; v1's three production constructors use the
## standard layout).
##
## The slicing methods do NOT re-run the build. They synthesise a thin
## ``Library`` / ``Executable`` / ``BuildActionDef`` value pointing at
## the package's ``installEdge`` plus the matched component's relative
## path.
##
## See [[file:Reprobuild-Standard-Library.md][Reprobuild-Standard-Library]]
## §"Multi-artifact result types" for the cross-tool contract.

import std/tables

import repro_project_dsl
import ./library
import ./executable

type
  PackageResultBase = object of RootObj
    ## Shared fields across ``MesonPackageResult`` /
    ## ``CmakePackageResult`` / ``AutotoolsPackageResult``. v1 uses
    ## composition (rather than inheritance) for the three concrete
    ## result types so they can grow tool-specific fields
    ## independently; the base record documents the shared shape.

  MesonPackageResult* = object
    ## Returned by ``meson_package(...)``. Each of the three edges
    ## stamps one configure/build/install role; the slicing methods
    ## consult ``components`` to map a component name onto an
    ## install-tree relative path.
    buildEdge*: BuildActionDef
      ## The ``meson setup`` edge.
    compileEdge*: BuildActionDef
      ## The ``meson compile`` edge.
    installEdge*: BuildActionDef
      ## The ``meson install`` edge. ``.executable(name)`` and
      ## ``.library(name)`` return values whose ``install`` field
      ## points here.
    destdir*: string
      ## DESTDIR-style staging path (e.g. ``"out"``). Consumers
      ## prepend this to a component's relative path to land at the
      ## absolute file location.
    components*: Table[string, string]
      ## Component name → relative path within ``destdir``. v1 uses
      ## the standard meson install layout (``"runtime"``,
      ## ``"library"``, ``"share"``, ``"man"``, ``"include"``,
      ## ``"pkgconfig"``). Recipes that need a custom layout populate
      ## this directly.

  CmakePackageResult* = object
    ## Returned by ``cmake_package(...)``. Mirrors
    ## ``MesonPackageResult`` field-for-field; the difference is the
    ## installation driver (``cmake --install`` vs ``meson install``).
    buildEdge*: BuildActionDef
    compileEdge*: BuildActionDef
    installEdge*: BuildActionDef
    destdir*: string
    components*: Table[string, string]

  AutotoolsPackageResult* = object
    ## Returned by ``autotools_package(...)``. ``configureEdge`` is the
    ## ``./configure`` invocation; ``compileEdge`` is ``make``;
    ## ``installEdge`` is ``make install DESTDIR=...``. Recipes that
    ## need a separate ``make check`` edge wire it through the
    ## low-level ``make.run`` Layer-3 surface.
    buildEdge*: BuildActionDef
    compileEdge*: BuildActionDef
    installEdge*: BuildActionDef
    destdir*: string
    components*: Table[string, string]

# ---------------------------------------------------------------------------
# Standard component-layout helpers
# ---------------------------------------------------------------------------

proc standardComponents*(): Table[string, string] =
  ## v1 hard-coded layout shared across all three multi-artifact
  ## constructors. Mirrors the FHS-style tree ``meson install
  ## --destdir=<out>`` (and the matching ``cmake --install`` /
  ## ``make install DESTDIR=...``) writes by default.
  result = initTable[string, string]()
  result["runtime"]   = "usr/bin"
  result["library"]   = "usr/lib"
  result["share"]     = "usr/share"
  result["man"]       = "usr/share/man"
  result["include"]   = "usr/include"
  result["pkgconfig"] = "usr/lib/pkgconfig"

# ---------------------------------------------------------------------------
# Slicing methods — MesonPackageResult
# ---------------------------------------------------------------------------

proc componentPath(components: Table[string, string]; name: string): string =
  ## Resolve a component name → relative path. Falls back to the bare
  ## component name when no explicit entry exists (recipes that want
  ## a custom name like ``"man3"`` get an unmangled path back rather
  ## than an empty string).
  if name in components:
    return components[name]
  name

proc executable*(r: MesonPackageResult; name: string): Executable =
  ## Slice the meson install edge into an executable artifact. The
  ## ``installPrefix`` is the resolved component path (typically
  ## ``"usr/bin"``); recipe authors join it with the package's
  ## destdir to get the on-disk binary location.
  newExecutable(
    install = r.installEdge,
    executableName = name,
    installPrefix = componentPath(r.components, "runtime"))

proc library*(r: MesonPackageResult; name: string): Library =
  ## Slice the meson install edge into a library artifact.
  newLibrary(
    install = r.installEdge,
    installPrefix = componentPath(r.components, "library"))

proc files*(r: MesonPackageResult; name: string): BuildActionDef =
  ## Return the install edge for ``name``-shaped files (man pages,
  ## docs, share data). The caller resolves the file paths via
  ## ``destdir`` + ``components[name]`` at consumption time.
  discard componentPath(r.components, name) # placeholder until typed PathRef
  r.installEdge

# ---------------------------------------------------------------------------
# Slicing methods — CmakePackageResult
# ---------------------------------------------------------------------------

proc executable*(r: CmakePackageResult; name: string): Executable =
  newExecutable(
    install = r.installEdge,
    executableName = name,
    installPrefix = componentPath(r.components, "runtime"))

proc library*(r: CmakePackageResult; name: string): Library =
  newLibrary(
    install = r.installEdge,
    installPrefix = componentPath(r.components, "library"))

proc files*(r: CmakePackageResult; name: string): BuildActionDef =
  discard componentPath(r.components, name)
  r.installEdge

# ---------------------------------------------------------------------------
# Slicing methods — AutotoolsPackageResult
# ---------------------------------------------------------------------------

proc executable*(r: AutotoolsPackageResult; name: string): Executable =
  newExecutable(
    install = r.installEdge,
    executableName = name,
    installPrefix = componentPath(r.components, "runtime"))

proc library*(r: AutotoolsPackageResult; name: string): Library =
  newLibrary(
    install = r.installEdge,
    installPrefix = componentPath(r.components, "library"))

proc files*(r: AutotoolsPackageResult; name: string): BuildActionDef =
  discard componentPath(r.components, name)
  r.installEdge
