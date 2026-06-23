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

import std/[os, strutils, tables]

import repro_project_dsl
import ./library
import ./executable

# DSL-port M9.R.2c — re-export the typed ``Library`` / ``Executable``
# records so the 79 from-source recipes that import
# ``repro_dsl_stdlib/types/package_result`` (for the
# ``MesonPackageResult`` / ``CmakePackageResult`` /
# ``AutotoolsPackageResult`` slicing surface) automatically pull the
# typed-value layer into scope. The package macro's M9.R.2c artifact
# slot injection (``var <n>: Library`` / ``var <n>: Executable``)
# references the types by bare ident; this re-export lets it resolve
# in every recipe without a second import line. The 5 outlier recipes
# without this import path get an explicit
# ``import repro_dsl_stdlib/types`` instead.
export library
export executable

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
    ## ``./configure`` invocation; ``compileEdge`` is ``make``.
    ##
    ## ``installEdge`` is the TERMINAL install-stage edge that downstream
    ## stage-copy / mirror actions depend on for ordering. When the
    ## constructor emits the M9.R.15p.2.4 post-install ``.la``-cleanup
    ## edge (the standard distro practice of stripping libtool archives
    ## from staged installs), ``installEdge`` is that cleanup edge so
    ## stage-copy runs after the ``.la`` files are gone. The underlying
    ## ``make install DESTDIR=...`` action — the one that carries the
    ## M9.R.14c.1 parallel-make ``MAKEFLAGS=-jN`` hint and the
    ## ``DESTDIR`` var — is exposed separately as ``installMakeEdge``.
    ## Recipes that need a separate ``make check`` edge wire it through
    ## the low-level ``make.run`` Layer-3 surface.
    buildEdge*: BuildActionDef
    compileEdge*: BuildActionDef
    installEdge*: BuildActionDef
    installMakeEdge*: BuildActionDef
      ## The raw ``make install DESTDIR=...`` action. Distinct from
      ## ``installEdge`` whenever a post-install cleanup edge is the
      ## terminal node; identical to ``installEdge`` otherwise. Carries
      ## the ``MAKEFLAGS=-jN`` parallel-make hint + the ``DESTDIR`` var.
    destdir*: string
      ## DESTDIR-style staging path. Relative to ``buildDir`` for
      ## autotools recipes (``make install DESTDIR=out`` from a
      ## ``cwd = buildDir`` process lands at
      ## ``<recipeRoot>/<buildDir>/out``).
    buildDir*: string
      ## M9.R.14c.5 — the out-of-tree build directory the install
      ## action runs ``make install DESTDIR=...`` from. Stage-copy
      ## emission joins ``buildDir / destdir`` to locate the
      ## DESTDIR staging tree on disk. Empty string means the destdir
      ## value is interpreted relative to the recipe root directly.
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

# Forward declarations — ``emitAutotoolsStageCopy`` /
# ``emitInstallTreeMirror`` are defined below in the stage-copy helpers
# section but are referenced by the meson slicing methods above.
# Forward-declaring (rather than reordering) keeps the related stage-
# copy logic in one block at the bottom of the module where the
# autotools slicing methods consume it too.
proc emitAutotoolsStageCopy(installEdge: BuildActionDef;
                            buildDir, destdir, packageName, kind, name: string)
proc emitInstallTreeMirror*(installEdge: BuildActionDef;
                            buildDir, destdir, packageName: string)
proc emitStageCopyAlias(installEdge: BuildActionDef;
                        buildDir, destdir, packageName, aliasName,
                        sourceName: string)

proc executable*(r: MesonPackageResult; name: string): Executable =
  ## Slice the meson install edge into an executable artifact. The
  ## ``installPrefix`` is the resolved component path (typically
  ## ``"usr/bin"``); recipe authors join it with the package's
  ## destdir to get the on-disk binary location.
  ##
  ## M9.R.14d.7 — emit a stage-copy action that bridges the meson
  ## install tree (`<destdir>/usr/bin/<name>`) onto the canonical
  ## from-source resolver path (`.repro/output/<name>/<name>`).
  ## ``r.destdir`` is the absolute path the meson_package constructor
  ## resolved at provider-compile time (see M9.R.14d.7); we pass it
  ## with an EMPTY ``buildDir`` so ``emitAutotoolsStageCopy`` treats
  ## it as the install-root verbatim rather than prepending another
  ## relative segment.
  emitAutotoolsStageCopy(r.installEdge, "", r.destdir,
    currentOwningPackage(), "executable", name)
  # M9.R.14e.2 — also emit the package's install-tree mirror so the
  # M9.R.14e.1 resolver's search-path probe finds the staged
  # ``.pc`` / ``include`` / ``lib`` tree at a layout-stable location.
  # Idempotent (one mirror per package) — see ``emitInstallTreeMirror``.
  emitInstallTreeMirror(r.installEdge, "", r.destdir,
    currentOwningPackage())
  newExecutable(
    install = r.installEdge,
    executableName = name,
    installPrefix = componentPath(r.components, "runtime"))

proc library*(r: MesonPackageResult; name: string): Library =
  ## Slice the meson install edge into a library artifact.
  ##
  ## M9.R.14d.7 — emit a stage-copy action mirroring the executable
  ## slicing's pattern. Library-kind probing handles the wayland
  ## naming convention where the recipe declares ``library libwayland
  ## Client`` but meson installs ``libwayland-client.so`` — the probe
  ## walks the autotools naming taxonomy and matches the file the
  ## meson build actually emitted.
  emitAutotoolsStageCopy(r.installEdge, "", r.destdir,
    currentOwningPackage(), "library", name)
  # M9.R.14e.2 — install-tree mirror (see executable() above).
  emitInstallTreeMirror(r.installEdge, "", r.destdir,
    currentOwningPackage())
  newLibrary(
    install = r.installEdge,
    installPrefix = componentPath(r.components, "library"))

proc executableAlias*(r: MesonPackageResult; aliasName, sourceName: string):
    Executable =
  ## M9.R.15g.1 — emit a stage-copy that copies the installed binary
  ## ``<destdir>/usr/bin/<sourceName>`` onto the canonical from-source
  ## resolver path ``.repro/output/<aliasName>/<aliasName>`` so a dep
  ## selector that doesn't match any of the package's own binary names
  ## resolves to one of them by alias.
  ##
  ## Motivating case: ``gobject-introspection`` (the upstream package +
  ## the dep selector consumers write) installs binaries ``g-ir-scanner``,
  ## ``g-ir-compiler``, ``g-ir-generate``, ... — none of which canonicalise
  ## to the package name. The M9.R.14d resolver's canonical-prefix tier
  ## therefore can't pick one. ``executableAlias("gobject-introspection",
  ## sourceName = "g-ir-scanner")`` stages ``g-ir-scanner`` at
  ## ``.repro/output/gobject-introspection/gobject-introspection`` so the
  ## resolver's tier-0 exact match fires.
  ##
  ## Same DESTDIR / destdir handling as ``executable()``. The
  ## ``Executable`` record returned points at the alias's stage-copy
  ## output so callers consuming the slice see the same shape as a
  ## regular ``pkg.executable(name)`` call.
  emitStageCopyAlias(r.installEdge, "", r.destdir,
    currentOwningPackage(), aliasName, sourceName)
  # The install-tree mirror is already emitted by the recipe's other
  # executable / library slices; no need to repeat it here. Aliases
  # never participate in the mirror because they're synthetic
  # rename-only artefacts.
  newExecutable(
    install = r.installEdge,
    executableName = aliasName,
    installPrefix = componentPath(r.components, "runtime"))

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
  ## M9.R.14h.8 — emit per-artifact stage-copy + the package's
  ## install-tree mirror so the from-source resolver finds the staged
  ## install layout at the canonical
  ## ``<recipeRoot>/.repro/output/<name>`` and
  ## ``<recipeRoot>/.repro/output/install/usr`` paths.  Matches the
  ## meson_package + autotools_package slicing methods; without this
  ## a cmake-built sibling recipe (json-c, ...) could compile + install
  ## successfully yet leave its install tree invisible to consumers.
  emitAutotoolsStageCopy(r.installEdge, "", r.destdir,
    currentOwningPackage(), "executable", name)
  emitInstallTreeMirror(r.installEdge, "", r.destdir,
    currentOwningPackage())
  newExecutable(
    install = r.installEdge,
    executableName = name,
    installPrefix = componentPath(r.components, "runtime"))

proc library*(r: CmakePackageResult; name: string): Library =
  ## M9.R.14h.8 — see ``executable`` above.  json-c is the motivating
  ## case: ``libjson-c.so`` was installed under
  ## ``build/out/usr/lib64/`` by the cmake_package install action but
  ## never staged into ``.repro/output/libJsonC/`` or mirrored into
  ## ``.repro/output/install/usr/`` because the slicing methods
  ## returned a bare ``Library`` value without emitting either glue
  ## action.
  emitAutotoolsStageCopy(r.installEdge, "", r.destdir,
    currentOwningPackage(), "library", name)
  emitInstallTreeMirror(r.installEdge, "", r.destdir,
    currentOwningPackage())
  newLibrary(
    install = r.installEdge,
    installPrefix = componentPath(r.components, "library"))

proc files*(r: CmakePackageResult; name: string): BuildActionDef =
  discard componentPath(r.components, name)
  r.installEdge

# ---------------------------------------------------------------------------
# Stage-copy emission (M9.R.14c.5)
# ---------------------------------------------------------------------------
#
# The from-source-* tool resolver looks for the recipe's artefacts at
# the canonical ``<recipeRoot>/.repro/output/<name>/<name>`` path
# (per ``fromSourceArtifactCandidate`` in repro_tool_profiles). The
# autotools_package install action writes to a DESTDIR-style tree
# under ``destdir/usr/bin/<name>`` / ``destdir/usr/lib/<lib>.so``,
# so we need a stage-copy action that bridges the two layouts.
#
# The from-source-custom convention already ships an equivalent
# ``emitStageCopyAction`` helper for shell-action recipes (per the
# DslShellAction surface). v1 of the slicing-method stage emission
# duplicates that pattern inline so the autotools_package /
# meson_package / cmake_package slicing surface gains the same
# install-glue without a cross-module refactor.

import std/sets

var stageCopyEmitted {.threadvar.}: HashSet[string]
  ## Per-artifact stage-copy emission guard (executable/library kind).
var installMirrorEmitted {.threadvar.}: HashSet[string]
  ## M9.R.14e.2 — per-package install-tree-mirror emission guard. A
  ## recipe may call ``pkg.executable(...)`` AND ``pkg.library(...)``
  ## multiple times; we want the install-tree mirror emitted exactly
  ## once per package so the action registry doesn't collide.

proc stageCopyEmittedKey(packageName, kind, name: string): string =
  packageName & "." & kind & "." & name

proc sanitizeStageCopyName(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc m9r14fStripDepConstraint*(value: string): string =
  ## DSL-port M9.R.14f.2 — strip a version-constraint suffix off a raw
  ## dep constraint string so ``"wayland >=1.22"`` → ``"wayland"``.
  ## Mirrors the equivalent helpers in meson_package.nim and
  ## repro_tool_profiles.nim. Exported for unit-test introspection.
  for i, ch in value:
    if ch == ' ' or ch == '>' or ch == '<' or ch == '=' or
        ch == '~' or ch == '^':
      return value[0 ..< i]
  return value

proc m9r14fAppendDepMirrorDir(dst: var seq[string]; recipeRoot, depRaw: string) =
  let dep = m9r14fStripDepConstraint(depRaw)
  if dep.len == 0: return
  let libDir = recipeRoot / dep / ".repro" / "output" / "install" /
    "usr" / "lib"
  let lib64Dir = recipeRoot / dep / ".repro" / "output" / "install" /
    "usr" / "lib64"
  let posixLib = libDir.replace("\\", "/")
  let posixLib64 = lib64Dir.replace("\\", "/")
  if posixLib notin dst:
    dst.add(posixLib)
  if posixLib64 notin dst:
    dst.add(posixLib64)

proc m9r14fCollectDepMirrorLibDirs*(projectRoot, packageName: string):
    seq[string] =
  ## DSL-port M9.R.14f.2 — enumerate the install-mirror ``lib/`` dirs
  ## of every declared dep of ``packageName``. Each path joined as
  ## ``<recipeRoot>/<depName>/.repro/output/install/usr/lib``. The
  ## returned strings are POSIX-style with forward slashes so the
  ## emitted shell script does not need additional escaping. Order is
  ## (nativeBuildDeps, then buildDeps) in source-declaration order —
  ## deterministic across runs.
  let recipeRoot = parentDir(projectRoot)
  if recipeRoot.len == 0:
    return
  for raw in registeredNativeBuildDeps(packageName):
    m9r14fAppendDepMirrorDir(result, recipeRoot, raw)
  for raw in registeredBuildDeps(packageName):
    m9r14fAppendDepMirrorDir(result, recipeRoot, raw)

# ---------------------------------------------------------------------------
# M9.R.15i.1 — Qt6 component CMake-config dir threading.
# ---------------------------------------------------------------------------

proc m9r15iScanQt6CmakeDirs*(qt6DepRecipeDir: string;
                              dst: var seq[(string, string)]) =
  ## DSL-port M9.R.15i.1 — scan a qt6-* dep's install-mirror cmake/
  ## tree for ``Qt6*Config.cmake`` files and emit ``(Component, dir)``
  ## pairs. ``dir`` is the absolute path to the directory holding the
  ## config file (what CMake expects as ``<Component>_DIR``).
  ##
  ## Exported for unit-test introspection.
  let cmakeRoot = qt6DepRecipeDir / ".repro" / "output" / "install" /
    "usr" / "lib" / "cmake"
  if not dirExists(cmakeRoot):
    return
  # Sort kinds + names so the output is deterministic across host file-
  # system enumeration order.
  var entries: seq[string] = @[]
  for kindPc, walked in walkDir(cmakeRoot):
    if kindPc != pcDir and kindPc != pcLinkToDir:
      continue
    var subdir = walked
    when defined(windows):
      if subdir.startsWith("\\\\?\\"):
        subdir = subdir[4 .. ^1]
    entries.add(subdir)
  # std/algorithm sort would pull a transitive import; the entries
  # collected from a single walkDir round are already deterministic
  # for a fixed filesystem state, but the M9.R.15i.1 unit test pins
  # a sorted contract so a future filesystem-order shift cannot
  # silently flip the emitted ``-D`` order. Manual insertion-sort
  # keeps the import surface narrow.
  for i in 1 ..< entries.len:
    let cur = entries[i]
    var j = i
    while j > 0 and entries[j - 1] > cur:
      entries[j] = entries[j - 1]
      dec j
    entries[j] = cur
  for subdir in entries:
    let component = lastPathPart(subdir)
    if not component.startsWith("Qt6"):
      continue
    let configFile = subdir / (component & "Config.cmake")
    if not fileExists(configFile):
      continue
    dst.add((component, subdir.replace("\\", "/")))

proc m9r15iCollectQt6ComponentDirs*(projectRoot, packageName: string):
    seq[(string, string)] =
  ## DSL-port M9.R.15i.1 — enumerate every ``Qt6*Config.cmake`` found
  ## in the install-mirror cmake/ trees of every declared ``qt6-*``
  ## dep of ``packageName``. Returns ``(Component, dir)`` pairs; the
  ## emitter wraps each as ``-DComponent_DIR=dir``.
  ##
  ## Qt6's CMake-config-package structure expects every dependent
  ## ``find_package(Qt6 ... LinguistTools REQUIRED)`` to resolve all
  ## requested components from a SINGLE install prefix. Because we
  ## build qt6-base + qt6-tools + future qt6-* as siblings each with
  ## its own ``.repro/output/install/`` prefix, KF6 / Plasma recipes'
  ## probes fail until each component's ``Qt6<X>_DIR`` is pre-pointed
  ## at the right sibling.
  ##
  ## Order: deterministic across runs. Each qt6-* dep is walked in
  ## (nativeBuildDeps, then buildDeps) declaration order; within a
  ## dep, component names are sorted.
  let recipeRoot = parentDir(projectRoot)
  if recipeRoot.len == 0:
    return
  proc visitDep(raw: string; sink: var seq[(string, string)]) =
    let dep = m9r14fStripDepConstraint(raw)
    if not dep.startsWith("qt6-"):
      return
    let depRecipeDir = recipeRoot / dep
    m9r15iScanQt6CmakeDirs(depRecipeDir, sink)
  for raw in registeredNativeBuildDeps(packageName):
    visitDep(raw, result)
  for raw in registeredBuildDeps(packageName):
    visitDep(raw, result)

# ---------------------------------------------------------------------------
# M9.R.15i.5 — Generic CMake-config dir threading for sibling install
# prefixes (KF6 modules + ECM + any future cmake-config-package dep).
# ---------------------------------------------------------------------------

proc m9r15iScanCmakeConfigDirs*(depRecipeDir: string;
                                 dst: var seq[(string, string)]) =
  ## DSL-port M9.R.15i.5 — scan a dep's install-mirror cmake/ tree for
  ## ``<Component>Config.cmake`` (and lowercase
  ## ``<component>-config.cmake``) files and emit ``(Component, dir)``
  ## pairs. Unlike ``m9r15iScanQt6CmakeDirs`` this helper does NOT
  ## filter on ``Component.startsWith("Qt6")`` — it surfaces every
  ## CMake-config package found in the dep's prefix.
  let cmakeRoot = depRecipeDir / ".repro" / "output" / "install" /
    "usr" / "lib" / "cmake"
  if not dirExists(cmakeRoot):
    return
  var entries: seq[string] = @[]
  for kindPc, walked in walkDir(cmakeRoot):
    if kindPc != pcDir and kindPc != pcLinkToDir:
      continue
    var subdir = walked
    when defined(windows):
      if subdir.startsWith("\\\\?\\"):
        subdir = subdir[4 .. ^1]
    entries.add(subdir)
  for i in 1 ..< entries.len:
    let cur = entries[i]
    var j = i
    while j > 0 and entries[j - 1] > cur:
      entries[j] = entries[j - 1]
      dec j
    entries[j] = cur
  for subdir in entries:
    let component = lastPathPart(subdir)
    # Try the camelCase ``<Component>Config.cmake`` form first
    # (canonical for KF6 / Qt6 / most modern CMake-config packages).
    let configPascal = subdir / (component & "Config.cmake")
    if fileExists(configPascal):
      dst.add((component, subdir.replace("\\", "/")))
      continue
    # Fall back to lowercase ``<component>-config.cmake`` form
    # (autotools-style packages that ship one).
    let configKebab = subdir / (component.toLowerAscii & "-config.cmake")
    if fileExists(configKebab):
      dst.add((component, subdir.replace("\\", "/")))

proc m9r15iCollectAllCmakeConfigDirs*(projectRoot, packageName: string):
    seq[(string, string)] =
  ## DSL-port M9.R.15i.5 — enumerate every CMake-config package
  ## available in EVERY declared dep's install-mirror cmake/ tree.
  ## Unlike ``m9r15iCollectQt6ComponentDirs`` this covers KF6 modules
  ## (kconfig, ki18n, kglobalaccel, ...), ECM-style cmake-only deps,
  ## and any future cmake-config-package dep — not just qt6-*.
  ##
  ## Without this fix, a KF6 module that declares ``kglobalaccel`` as
  ## a buildDep cannot resolve ``find_package(KF6GlobalAccel REQUIRED)``
  ## because the sibling install prefix isn't on CMAKE_PREFIX_PATH at
  ## configure time. The fix is to scan every dep's lib/cmake/ subdir
  ## and emit ``-D<Component>_DIR=...`` for each Config.cmake found.
  ##
  ## Order: deterministic across runs. Each dep is walked in
  ## (nativeBuildDeps, then buildDeps) declaration order; within a
  ## dep, component names are sorted alphabetically.
  let recipeRoot = parentDir(projectRoot)
  if recipeRoot.len == 0:
    return
  proc visitDep(raw: string; sink: var seq[(string, string)]) =
    let dep = m9r14fStripDepConstraint(raw)
    if dep.len == 0:
      return
    let depRecipeDir = recipeRoot / dep
    m9r15iScanCmakeConfigDirs(depRecipeDir, sink)
  for raw in registeredNativeBuildDeps(packageName):
    visitDep(raw, result)
  for raw in registeredBuildDeps(packageName):
    visitDep(raw, result)

proc m9r15iEmitQt6ComponentCacheVars*(componentDirs: seq[(string, string)]):
    seq[string] =
  ## DSL-port M9.R.15i.1 — emit ``Component_DIR=dir`` cache-var entries
  ## suitable for ``cmake.configure(cacheVars = ...)``. The configure
  ## CLI lowering prefixes each with ``-D``.
  ##
  ## Also used by M9.R.15i.5's generic config-dir emitter.
  for (component, dir) in componentDirs:
    result.add(component & "_DIR=" & dir)

# ---------------------------------------------------------------------------
# M9.R.15q.3.1 — Virtual KF6 umbrella config dispatcher.
# ---------------------------------------------------------------------------
#
# Per KDE upstream's KF6 packaging convention, a recipe that wants to
# pull in multiple KF6 modules writes:
#
#     find_package(KF6 REQUIRED COMPONENTS Config CoreAddons I18n WindowSystem)
#
# CMake looks for a top-level ``KF6Config.cmake`` (the umbrella
# dispatcher) on ``CMAKE_PREFIX_PATH`` (or via ``-DKF6_DIR=...``) which
# then routes each requested ``<X>`` to its sibling-installed
# ``KF6<X>Config.cmake``.
#
# Reprobuild's M9.R.15i.5 auto-threads per-module ``-DKF6<X>_DIR=...``
# cache vars but does NOT generate the umbrella ``KF6_DIR`` pointing at
# a synthesised dispatcher. Without the dispatcher the umbrella
# ``find_package(KF6 ... COMPONENTS ...)`` fails before the per-module
# threading has a chance to satisfy each component.
#
# M9.R.15q.3.1 closes the gap by:
#
#   1. Detecting whenever ``m9r15iCollectAllCmakeConfigDirs`` surfaces
#      one or more ``KF6<X>`` components (i.e. the sibling deps already
#      install KF6 module configs).
#   2. Writing a synthetic ``KF6Config.cmake`` at
#      ``<projectRoot>/.repro/build/cmake/KF6/KF6Config.cmake`` that
#      dispatches to each requested component using the per-component
#      ``KF6<X>_DIR`` cache vars the caller already threaded.
#   3. Returning the synthetic directory so the caller can emit
#      ``-DKF6_DIR=<dir>`` alongside the per-module entries.

proc m9r15q31KF6UmbrellaDir*(projectRoot: string): string =
  ## DSL-port M9.R.15q.3.1 — canonical path of the synthesized KF6
  ## umbrella config directory under ``projectRoot``.
  ##
  ## Exported so the cmake_package constructor can pass
  ## ``-DKF6_DIR=<this>`` and so unit tests can introspect the
  ## generated layout without re-deriving the path.
  ##
  ## Returns POSIX-style forward slashes so the path is safe to embed
  ## directly inside the cmake ``-D...`` cache var (cmake accepts
  ## forward slashes on every host; backslashes need escaping).
  if projectRoot.len == 0:
    return ""
  let raw = projectRoot / ".repro" / "build" / "cmake" / "KF6"
  raw.replace("\\", "/")

proc m9r15q31KF6Components*(componentDirs: seq[(string, string)]):
    seq[string] =
  ## DSL-port M9.R.15q.3.1 — filter a generic
  ## ``m9r15iCollectAllCmakeConfigDirs`` result to the KF6 component
  ## names alone (``KF6Config``, ``KF6CoreAddons``, ...). The umbrella
  ## dispatcher iterates these names so a request like
  ## ``COMPONENTS Config CoreAddons`` resolves against the synthesized
  ## umbrella even when the actual cmake find_package call only names
  ## a subset.
  ##
  ## Order: matches input order (which the upstream collector already
  ## sorts deterministically).
  for (comp, _) in componentDirs:
    if not comp.startsWith("KF6"):
      continue
    if comp == "KF6":
      # Never emit ``KF6`` itself (would re-enter the umbrella).
      continue
    if comp in result:
      continue
    result.add(comp)

proc m9r15q31SynthesizeKF6UmbrellaConfig*(projectRoot: string;
                                          kf6Components: seq[string]):
    string =
  ## DSL-port M9.R.15q.3.1 — synthesize a virtual ``KF6Config.cmake``
  ## umbrella dispatcher at ``<projectRoot>/.repro/build/cmake/KF6/``
  ## and return the path of the directory it lives in (suitable for
  ## ``-DKF6_DIR=<this>``).
  ##
  ## The synthesized umbrella:
  ##   * sets ``KF6_FOUND TRUE``.
  ##   * iterates ``KF6_FIND_COMPONENTS`` (the list cmake builds from
  ##     the upstream ``COMPONENTS`` clause).
  ##   * for each component, dispatches via
  ##     ``find_package(KF6<comp> CONFIG REQUIRED)`` — the
  ##     M9.R.15i.5-threaded per-module ``-DKF6<X>_DIR=...`` cache vars
  ##     supply the hint cmake needs to locate each sibling config.
  ##   * if a requested component is unknown (not in the threaded set),
  ##     defers to cmake's default search so existing behaviour is
  ##     preserved as long as ``CMAKE_PREFIX_PATH`` carries the prefix.
  ##
  ## Idempotent: the file content depends only on ``kf6Components``;
  ## two invocations with the same input produce byte-identical output.
  ## Inert in unit-test mode when ``projectRoot`` is empty (returns "").
  if projectRoot.len == 0:
    return ""
  if kf6Components.len == 0:
    return ""
  let umbrellaDir = m9r15q31KF6UmbrellaDir(projectRoot)
  createDir(umbrellaDir)
  let umbrellaFile = umbrellaDir / "KF6Config.cmake"
  var script = ""
  script.add("# Generated by reprobuild M9.R.15q.3.1 — virtual KF6\n")
  script.add("# umbrella dispatcher. Routes each requested KF6 component\n")
  script.add("# to its sibling-threaded ``KF6<X>_DIR`` cache var.\n")
  script.add("set(KF6_FOUND TRUE)\n")
  script.add("set(KF6_VERSION \"6.0.0\")\n")
  script.add("set(KF6_VERSION_STRING \"${KF6_VERSION}\")\n")
  script.add("set(_kf6_known_components\n")
  for comp in kf6Components:
    # ``comp`` is the full ``KF6<X>`` component name; the umbrella
    # exposes ``<X>`` to the caller.
    let stripped = comp[3 .. ^1]
    if stripped.len == 0:
      continue
    script.add("  \"" & stripped & "\"\n")
  script.add(")\n")
  script.add("foreach(_kf6_comp ${KF6_FIND_COMPONENTS})\n")
  script.add("  set(_kf6_target \"KF6${_kf6_comp}\")\n")
  script.add("  find_package(${_kf6_target} CONFIG QUIET)\n")
  script.add("  if(${_kf6_target}_FOUND)\n")
  script.add("    set(KF6_${_kf6_comp}_FOUND TRUE)\n")
  script.add("  else()\n")
  script.add("    set(KF6_${_kf6_comp}_FOUND FALSE)\n")
  script.add("    if(KF6_FIND_REQUIRED_${_kf6_comp})\n")
  script.add("      message(FATAL_ERROR \"KF6 umbrella: required component ${_kf6_comp} not found (looked for ${_kf6_target})\")\n")
  script.add("    endif()\n")
  script.add("  endif()\n")
  script.add("endforeach()\n")
  writeFile(umbrellaFile, script)
  umbrellaDir.replace("\\", "/")

# ---------------------------------------------------------------------------
# M9.R.15o.1 — Auto-thread Qt6Gui transitive find_dependency targets
# (libxkbcommon + mesa) for every qt6-* consumer.
# ---------------------------------------------------------------------------

const m9r15oQt6GuiTransitiveDeps* = [
  ## DSL-port M9.R.15o.1 — recipes Qt6Gui's CMake config calls
  ## ``find_dependency(...)`` for that are NOT shipped by any qt6-* dep
  ## itself. Without these on CMAKE_PREFIX_PATH + threaded as tool refs,
  ## every Qt6Gui consumer (KF6 modules / Plasma / KWin / ...) fails
  ## ``find_package(Qt6Gui REQUIRED)``.
  ##
  ## Diagnosed M9.R.15n.3 (kcrash) → M9.R.15n.5 (kded): every Qt6Gui
  ## consumer needed an identical per-recipe ``libxkbcommon`` + ``mesa``
  ## buildDeps annotation. M9.R.15o.1 moves that to the constructor.
  ##
  ## ``libxkbcommon`` supplies ``XKB`` (Qt6 GUI text-input dependency);
  ## ``mesa`` supplies ``GLESv2`` + ``EGL`` + ``gbm`` (Qt6 GUI OpenGL
  ## backend). Both are pinned at the same constraint floors the M9.R.15n
  ## hand-patched recipes used (``libxkbcommon >=1.5``, ``mesa >=23.3``).
  "libxkbcommon",
  "mesa",
]

proc m9r15oCollectQt6TransitiveCmakeDeps*(projectRoot, packageName: string):
    seq[string] =
  ## DSL-port M9.R.15o.1 — when any ``qt6-*`` dep is present in
  ## ``packageName``'s nativeBuildDeps + buildDeps AND the corresponding
  ## sibling install-mirror directory exists, return the recipe-dep
  ## names from ``m9r15oQt6GuiTransitiveDeps`` whose install-mirror
  ## ``usr/`` tree is on disk. The caller virtually injects them as
  ## additional tool-identity refs (so the from-source search-path
  ## channels reach the action env) and re-runs the generic CMake-config
  ## dir scan against them.
  ##
  ## ``projectRoot`` is the active recipe's project-root directory;
  ## ``parentDir(projectRoot)`` is the sibling-recipe directory
  ## (``recipes/packages/source/``) — matches the convention in
  ## ``m9r14fCollectDepMirrorLibDirs`` + ``m9r15iCollectQt6ComponentDirs``.
  ##
  ## Inert in unit-test mode when ``projectRoot`` is empty, and inert
  ## when no qt6-* dep is declared. Order: matches the declaration order
  ## in ``m9r15oQt6GuiTransitiveDeps``; idempotent across runs.
  if projectRoot.len == 0:
    return
  var hasQt6 = false
  for raw in registeredNativeBuildDeps(packageName):
    if m9r14fStripDepConstraint(raw).startsWith("qt6-"):
      hasQt6 = true
      break
  if not hasQt6:
    for raw in registeredBuildDeps(packageName):
      if m9r14fStripDepConstraint(raw).startsWith("qt6-"):
        hasQt6 = true
        break
  if not hasQt6:
    return
  # Don't double-inject a dep the recipe already declared by hand —
  # the M9.R.15n hand-patched recipes (kcrash / kglobalaccel / kded)
  # still carry the explicit annotations; injecting again would
  # duplicate the entry on every search-path channel + dep-ref list.
  var declared: seq[string] = @[]
  for raw in registeredNativeBuildDeps(packageName):
    declared.add(m9r14fStripDepConstraint(raw))
  for raw in registeredBuildDeps(packageName):
    declared.add(m9r14fStripDepConstraint(raw))
  let siblingsRoot = parentDir(projectRoot)
  if siblingsRoot.len == 0:
    return
  for dep in m9r15oQt6GuiTransitiveDeps:
    if dep in declared:
      continue
    # Only inject when the sibling install-mirror exists on disk so
    # the helper is inert in unit-test fixtures + host-orchestration
    # mode that builds the action graph without populating mirrors.
    let mirrorUsr = siblingsRoot / dep / ".repro" / "output" /
      "install" / "usr"
    if not dirExists(mirrorUsr):
      continue
    result.add(dep)

proc m9r15oCollectQt6TransitiveCmakeConfigDirs*(projectRoot, packageName: string):
    seq[(string, string)] =
  ## DSL-port M9.R.15o.1 — for every virtually-injected transitive
  ## Qt6Gui dep returned by ``m9r15oCollectQt6TransitiveCmakeDeps``,
  ## scan its install-mirror ``cmake/`` tree (same shape
  ## ``m9r15iScanCmakeConfigDirs`` walks) and return the ``(Component,
  ## dir)`` pairs so the cmake_package constructor can thread
  ## ``-D<Component>_DIR=...`` cache vars without the recipe author
  ## listing the dep manually.
  ##
  ## ``mesa`` ships no CMake config files (it's pkg-config / raw
  ## ``find_library`` consumed) so the scan returns 0 entries for it —
  ## the value of the injection is the search-path channel side (which
  ## is what reaches Qt6Gui's ``find_dependency(GLESv2)`` probe).
  ## ``libxkbcommon`` similarly is pkg-config consumed. Returning an
  ## empty seq is the expected shape today; the helper exists so
  ## future cmake-config-bearing transitive deps slot in without a
  ## constructor edit.
  let extraDeps = m9r15oCollectQt6TransitiveCmakeDeps(projectRoot, packageName)
  if extraDeps.len == 0:
    return
  let siblingsRoot = parentDir(projectRoot)
  if siblingsRoot.len == 0:
    return
  for dep in extraDeps:
    m9r15iScanCmakeConfigDirs(siblingsRoot / dep, result)

proc m9r14fEmitRpathPatchScript*(escapedDstUsr: string;
                                 depMirrorLibDirs: seq[string]): string =
  ## DSL-port M9.R.14f.2 — emit a POSIX shell snippet that walks every
  ## ELF under ``<mirror>/lib`` + ``<mirror>/lib64`` + ``<mirror>/bin``
  ## and runs ``patchelf --set-rpath`` on each. RPATH layout:
  ## ``$ORIGIN:$ORIGIN/../lib:$ORIGIN/../lib64:<dep1>:<dep2>:...``.
  ##
  ## The ``$ORIGIN`` family covers same-directory + sibling-directory
  ## SONAME chains (``libwayland-server.so`` next to
  ## ``libwayland-client.so``; ``wayland-scanner`` in ``bin/`` reaching
  ## ``../lib/libwayland-client.so``). Absolute dep paths cover
  ## transitive runtime deps (libexpat for wayland-scanner; libffi for
  ## libwayland-server; etc.).
  ##
  ## Idempotent: ``patchelf`` overwrites the existing RPATH every time,
  ## so re-running the install-mirror produces the same final RPATH.
  ##
  ## Graceful skip: when ``patchelf`` is not on PATH (host orchestration
  ## that builds the action graph but doesn't run it), the loop short-
  ## circuits without failing. Inside the Linux smoke environment
  ## (where patchelf IS provisioned via the bootstrap-linux-smoke.sh
  ## nix-shell deps), the loop runs over every ELF.
  var script = ""
  script.add("if command -v patchelf >/dev/null 2>&1; then ")
  # Build the RPATH string. Single-quote ``$ORIGIN`` so the shell does
  # not expand it — ``$ORIGIN`` must reach patchelf verbatim so the
  # dynamic linker interprets it at load time. Use a here-doc-free
  # construction so the snippet stays compatible with /bin/sh.
  #
  # M9.R.15q.5.1 — existence-check each dep mirror lib dir before
  # appending it to RPATH. Recipes routinely declare nix-stub deps
  # (libltdl, hwdata, libxdmcp, ...) whose ``<recipeRoot>/<depName>/
  # .repro/output/install/usr/lib`` path NEVER exists on disk — those
  # are resolved via ``/nix/store/...`` at engine fork time. Without
  # the existence-check, every such dep contributed a dangling RPATH
  # entry; ``patchelf`` happily bakes it into the ELF and the dynamic
  # loader silently skips it at run time, masking the resolution gap
  # until something later trips a missing-SONAME error.
  #
  # In ADDITION to the existence-check, fold every directory present
  # in ``$LD_LIBRARY_PATH`` into the rpath. The engine's
  # ``applyResolvedAuxPaths`` populates ``LD_LIBRARY_PATH`` from each
  # tool-identity-ref's ``libraryPathList`` (nix-store lib dirs for
  # nix-stub deps; sibling install-mirror lib dirs for from-source
  # deps). This is the load-bearing channel that carries the nix-store
  # paths the install-mirror script has no other way to discover.
  script.add("rpath=$(printf '%s' '$ORIGIN'")
  script.add("; printf ':%s' '$ORIGIN/../lib'")
  script.add("; printf ':%s' '$ORIGIN/../lib64'")
  script.add("); ")
  # Append every existing sibling-recipe install-mirror lib dir. The
  # ``[ -d ... ]`` guard skips nix-stub deps whose mirror path doesn't
  # exist (M9.R.15q.5.1).
  for libDir in depMirrorLibDirs:
    let escapedLibDir = libDir.replace("\"", "\\\"")
    script.add("if [ -d \"" & escapedLibDir & "\" ]; then ")
    script.add("rpath=\"$rpath:" & escapedLibDir & "\"; ")
    script.add("fi; ")
  # Append every directory present in ``$LD_LIBRARY_PATH``. Splits on
  # ``:`` via IFS; existence-check via ``[ -d ... ]`` so empty
  # segments + stale entries don't pollute the embedded RPATH.
  script.add("if [ -n \"$LD_LIBRARY_PATH\" ]; then ")
  script.add("OLD_IFS=$IFS; IFS=':'; ")
  script.add("for ldp in $LD_LIBRARY_PATH; do ")
  script.add("if [ -n \"$ldp\" ] && [ -d \"$ldp\" ]; then ")
  script.add("rpath=\"$rpath:$ldp\"; ")
  script.add("fi; ")
  script.add("done; ")
  script.add("IFS=$OLD_IFS; ")
  script.add("fi; ")
  # DSL-port M9.R.15h.14.4 — preserve the toolchain libstdc++ / libgcc_s
  # path. Without a from-source gcc recipe, the C++ compiler is the
  # nix-shell-provisioned gcc-wrapper which links against libstdc++.so.6
  # at e.g. ``/nix/store/<gcc-lib>-gcc-N.M.0-lib/lib/libstdc++.so.6``.
  # The plain $ORIGIN + dep-mirror rpath chain doesn't reach this path,
  # so executables that need C++ runtime (qtpaths, lupdate, lrelease,
  # KF6 binaries) hit ``error while loading shared libraries:
  # libstdc++.so.6: cannot open shared object file`` at run time even
  # when launched from inside the originating nix-shell.
  #
  # Append the gcc-wrapper's resolved libstdc++ dirname to the rpath
  # so the dynamic loader finds it without LD_LIBRARY_PATH. We resolve
  # the path at install-mirror time via ``gcc -print-file-name=...``,
  # which echoes the absolute path of the named library file even when
  # the compiler isn't on PATH. The directory of that path is what we
  # want on rpath.
  script.add(
    "stdcxx_dir=$(gcc -print-file-name=libstdc++.so.6 2>/dev/null); ")
  script.add("if [ -n \"$stdcxx_dir\" ] && [ \"$stdcxx_dir\" != " &
    "\"libstdc++.so.6\" ]; then ")
  script.add("rpath=\"$rpath:$(dirname \"$stdcxx_dir\")\"; ")
  script.add("fi; ")
  # DSL-port M9.R.26.5 — discover the recipe's OWN internal versioned
  # subdirs under lib/ + lib64/ (e.g. mutter-15/, qt6/plugins/, etc.)
  # and append each as an absolute path to the rpath. Without this,
  # files under lib64/mutter-15/*.so are patched with a base rpath
  # whose $ORIGIN/.. resolves to lib64/ (good) but whose $ORIGIN/../..
  # is the usr/ root, and the cross-subdir SONAME chain (libmutter-cogl
  # in mutter-15/ linking against libmutter-mtk in the same subdir,
  # plus libmutter-15.so in lib64/ linking against everything in
  # mutter-15/) breaks because the parent lib's $ORIGIN doesn't reach
  # the versioned subdir.
  #
  # Solution: enumerate every versioned subdir at install-mirror time
  # and add it to the per-recipe rpath. The enumeration is dynamic
  # (POSIX glob) so any recipe that ships internal-implementation .so
  # files in lib64/<pkg-version>/ subdirs gets the right rpath without
  # having to hand-thread per-recipe overrides.
  for libDirName in ["lib", "lib64"]:
    let libDirAbs = escapedDstUsr & "/" & libDirName
    script.add("if [ -d \"" & libDirAbs & "\" ]; then ")
    script.add("for subd in \"" & libDirAbs & "\"/*/; do ")
    script.add("if [ -d \"$subd\" ]; then ")
    # Only include the subdir if it contains .so* files (skip pkg-config /
    # cmake / locale / static-only subdirs).
    script.add("if find \"$subd\" -maxdepth 1 -name '*.so*' -print -quit 2>/dev/null | grep -q .; then ")
    # Strip trailing slash for a clean rpath entry.
    script.add("rpath=\"$rpath:${subd%/}\"; ")
    script.add("fi; ")
    script.add("fi; ")
    script.add("done; ")
    script.add("fi; ")
  # Walk lib/ + lib64/ for .so* files (the SONAME-versioned chain).
  # Walk bin/ for executables.
  script.add("for d in \"" & escapedDstUsr & "/lib\" \"" & escapedDstUsr &
    "/lib64\" \"" & escapedDstUsr & "/bin\"; do ")
  script.add("if [ -d \"$d\" ]; then ")
  script.add("find \"$d\" -maxdepth 2 -type f \\( ")
  script.add("-name '*.so' -o -name '*.so.*' -o -perm -u+x ")
  script.add("\\) 2>/dev/null | while IFS= read -r f; do ")
  # ``patchelf --set-rpath`` is no-op for non-ELF files (it errors with
  # ``not an ELF executable``); guard with file-magic check via ``head``
  # before patching so non-ELF executables (shell scripts, etc.) don't
  # pollute the log with errors. ``\\177ELF`` is the 4-byte magic.
  script.add("magic=$(head -c 4 \"$f\" 2>/dev/null | od -An -c | head -1 | tr -d ' '); ")
  script.add("case \"$magic\" in 177ELF*) ")
  script.add("patchelf --set-rpath \"$rpath\" \"$f\" 2>/dev/null || true; ")
  script.add(";; esac; ")
  script.add("done; ")
  script.add("fi; done; ")
  script.add("fi; ")
  script

proc emitInstallTreeMirror*(installEdge: BuildActionDef;
                            buildDir, destdir, packageName: string) =
  ## DSL-port M9.R.14e.2 — mirror the recipe's DESTDIR install tree
  ## (``<recipeRoot>/<buildDir>/<destdir>/usr/``) to the canonical
  ## stable location at ``<recipeRoot>/.repro/output/install/usr/`` so
  ## consumer recipes have a layout-stable on-disk install tree to
  ## point ``PKG_CONFIG_PATH`` / ``CMAKE_PREFIX_PATH`` / ``CPATH`` /
  ## ``LIBRARY_PATH`` at — independent of which ``buildDir`` /
  ## ``destdir`` parameters the upstream recipe configured.
  ##
  ## Why: M9.R.14e.1's resolver already probes ``build/out/usr/``
  ## directly, but two recipes may configure different ``buildDir``
  ## values (e.g. ``meson_package(buildDir = "build")`` vs
  ## ``cmake_package(buildDir = "_build")``). The mirror at
  ## ``.repro/output/install/usr/`` is the single canonical location the
  ## resolver enumerates first, so the threaded env vars stay stable
  ## across constructor variants and across upstream layout drift.
  ##
  ## The action runs ``cp -a`` to preserve symlinks (load-bearing for
  ## ``.so`` SONAME chains: ``libwayland-client.so.0.25.0`` is the real
  ## file; ``libwayland-client.so.0`` and ``libwayland-client.so`` are
  ## symlinks the linker / loader resolve at run time).
  ##
  ## Idempotent: gated by ``installMirrorEmitted`` so a recipe that
  ## calls ``pkg.executable(...)`` AND ``pkg.library(...)`` emits the
  ## mirror once. Inert in unit-test mode (empty ``projectRoot``).
  let projectRoot = activeProviderProjectRoot()
  if projectRoot.len == 0:
    return
  if installMirrorEmitted.len == 0:
    installMirrorEmitted = initHashSet[string]()
  if packageName in installMirrorEmitted:
    return
  installMirrorEmitted.incl(packageName)
  let effectiveDestRoot =
    if buildDir.len > 0: buildDir & "/" & destdir
    else: destdir
  let srcUsr = effectiveDestRoot & "/usr"
  let escapedSrcUsr = srcUsr.replace("\\", "/").replace("\"", "\\\"")
  let dstUsrRoot = projectRoot / ".repro" / "output" / "install"
  let dstUsr = dstUsrRoot / "usr"
  createDir(dstUsrRoot)
  let escapedDstUsrRoot = dstUsrRoot.replace("\\", "/").replace("\"", "\\\"")
  let escapedDstUsr = dstUsr.replace("\\", "/").replace("\"", "\\\"")
  # Output stamp: a touch file so the engine has a concrete artefact to
  # key the action on without enumerating every nested file (recipes
  # routinely install hundreds of headers).
  let stampPath = dstUsrRoot / ".m9r14e_2_install_mirror.stamp"
  let escapedStamp = stampPath.replace("\\", "/").replace("\"", "\\\"")
  var script = "set -e; "
  # Remove the previous mirror to avoid stale artefacts. ``rm -rf`` is
  # safe here because ``dstUsr`` is a deterministic per-recipe path that
  # we own; no user data lives under ``.repro/output/install/usr``.
  script.add("rm -rf \"" & escapedDstUsr & "\"; ")
  script.add("mkdir -p \"" & escapedDstUsrRoot & "\"; ")
  # ``cp -a`` preserves symlinks, modes, timestamps. The ``--`` guards
  # against a future ``destdir`` whose value starts with ``-`` from
  # being interpreted as a flag.
  script.add("if [ -d \"" & escapedSrcUsr & "\" ]; then ")
  script.add("cp -a -- \"" & escapedSrcUsr & "\" \"" & escapedDstUsrRoot & "/\"; ")
  script.add("fi; ")
  # M9.R.15e.11 — some autotools projects (Linux-PAM, glibc) hardcode
  # libdir=/lib64 in their configure.ac regardless of --prefix, so the
  # .so files install to ``<destdir>/lib64/`` (no ``/usr/`` segment).
  # Merge ``<destdir>/lib`` and ``<destdir>/lib64`` into the mirrored
  # ``usr/lib`` and ``usr/lib64`` so consumers' resolver search paths
  # (anchored at ``<recipeDir>/.repro/output/install/usr``) find them.
  for bareSubdir in ["lib", "lib64", "etc", "sbin"]:
    let srcBare = effectiveDestRoot & "/" & bareSubdir
    let escapedSrcBare = srcBare.replace("\\", "/").replace("\"", "\\\"")
    let usrTarget = "usr/" & bareSubdir
    if bareSubdir in ["etc", "sbin"]:
      # ``etc`` + ``sbin`` are not nested under ``usr/`` in the FHS;
      # mirror them at the dstUsrRoot directly so the canonical install
      # tree carries them at ``<install>/etc`` / ``<install>/sbin``.
      script.add("if [ -d \"" & escapedSrcBare & "\" ]; then ")
      script.add("cp -a -- \"" & escapedSrcBare & "\" \"" & escapedDstUsrRoot & "/\"; ")
      script.add("fi; ")
    else:
      # ``lib`` + ``lib64`` are FOLDED into ``usr/lib`` + ``usr/lib64``.
      let dstBare = dstUsr / bareSubdir
      let escapedDstBare = dstBare.replace("\\", "/").replace("\"", "\\\"")
      script.add("if [ -d \"" & escapedSrcBare & "\" ]; then ")
      script.add("mkdir -p \"" & escapedDstBare & "\"; ")
      script.add("cp -a -- \"" & escapedSrcBare & "\"/. \"" & escapedDstBare & "/\"; ")
      script.add("fi; ")
  # M9.R.14e.8 — rewrite the .pc files' ``prefix=`` line to point at the
  # absolute path of the mirrored ``usr/`` tree so consumers that consult
  # ``pkg-config --variable=...`` or ``pkg-config --cflags`` see real
  # on-disk paths instead of the upstream-baked ``/usr``. Without this,
  # meson's ``Program /usr/bin/wayland-scanner found: NO`` trip
  # surfaces every time a downstream recipe asks pkg-config where the
  # producer's binaries / headers live.
  #
  # The rewrite uses ``sed -i`` against every ``.pc`` file under
  # ``lib/pkgconfig``, ``lib64/pkgconfig``, ``share/pkgconfig``. The
  # pattern matches an exact ``prefix=/usr`` line at the top of the pc
  # file (the standard autotools/meson layout). pc files that ship a
  # non-``/usr`` prefix (e.g. ``prefix=/opt/foo``) get one extra sed
  # invocation looking for ``prefix=`` at line start with any value —
  # the second pass is idempotent and inert when the first already
  # matched.
  script.add("for pcdir in \"" & escapedDstUsr & "/lib/pkgconfig\" \"" &
    escapedDstUsr & "/lib64/pkgconfig\" \"" & escapedDstUsr &
    "/share/pkgconfig\"; do ")
  script.add("if [ -d \"$pcdir\" ]; then ")
  script.add("for pc in \"$pcdir\"/*.pc; do ")
  script.add("if [ -f \"$pc\" ]; then ")
  # M9.R.14f.8 — rewrite ALL of prefix / exec_prefix / libdir /
  # includedir / datadir / sharedstatedir lines that point at an
  # absolute ``/usr...`` path baked in at build time. Some
  # autotools-generated pc files (e.g. freetype's freetype2.pc)
  # expand ``${prefix}/include`` to ``/usr/include`` at install
  # time, so the M9.R.14e.8 prefix-only rewrite leaves consumers
  # pointed at the host's /usr/include (or a non-existent dir
  # under the install mirror) instead of the mirror's own include
  # tree. Rewrite each of the standard variable lines that begins
  # with ``/usr`` to start with the mirror's ``<dstUsr>`` instead.
  script.add("sed -i ")
  script.add("'1,/^prefix=/{ s|^prefix=.*$|prefix=" & escapedDstUsr & "|; } ")
  script.add("; s|^exec_prefix=/usr|exec_prefix=" & escapedDstUsr & "| ")
  script.add("; s|^libdir=/usr/lib64|libdir=" & escapedDstUsr & "/lib64| ")
  script.add("; s|^libdir=/usr/lib|libdir=" & escapedDstUsr & "/lib| ")
  script.add("; s|^includedir=/usr/include|includedir=" & escapedDstUsr & "/include| ")
  script.add("; s|^datadir=/usr/share|datadir=" & escapedDstUsr & "/share| ")
  script.add("; s|^datarootdir=/usr/share|datarootdir=" & escapedDstUsr & "/share| ")
  script.add("; s|^sharedstatedir=/usr/com|sharedstatedir=" & escapedDstUsr & "/com|' ")
  script.add("\"$pc\"; ")
  script.add("fi; ")
  script.add("done; fi; done; ")
  # M9.R.14f.2 — patch RPATH on every ELF under the mirror's lib/lib64/bin
  # dirs so the resulting binaries can find their transitive deps without
  # relying on LD_LIBRARY_PATH at runtime.
  let depMirrorLibDirs = m9r14fCollectDepMirrorLibDirs(projectRoot, packageName)
  script.add(m9r14fEmitRpathPatchScript(escapedDstUsr, depMirrorLibDirs))
  script.add("touch \"" & escapedStamp & "\"")
  let argv = @["sh", "-c", script]
  let stageId = "install-mirror-" & sanitizeStageCopyName(packageName)
  # M9.R.15q.5.1 — thread every declared dep onto the install-mirror's
  # tool-identity-ref list so the engine populates ``LD_LIBRARY_PATH``
  # (and the rest of the auxiliary search-path channels) from each
  # dep's ``libraryPathList`` at fork time. The RPATH patch script
  # (``m9r14fEmitRpathPatchScript``) consumes ``$LD_LIBRARY_PATH`` and
  # folds every existing dir into the embedded RPATH so nix-stub-resolved
  # deps (libltdl, hwdata, libxdmcp, ...) reach the patched ELF without
  # the install-mirror having to enumerate ``/nix/store`` paths itself.
  var mirrorToolRefs = @["sh"]
  for raw in registeredNativeBuildDeps(packageName):
    let dep = m9r14fStripDepConstraint(raw)
    if dep.len > 0 and dep notin mirrorToolRefs:
      mirrorToolRefs.add(dep)
  for raw in registeredBuildDeps(packageName):
    let dep = m9r14fStripDepConstraint(raw)
    if dep.len > 0 and dep notin mirrorToolRefs:
      mirrorToolRefs.add(dep)
  discard buildAction(
    id = stageId,
    call = inlineExecCall(argv),
    deps = @[installEdge.id],
    inputs = installEdge.outputs,
    outputs = @[stampPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "autotools_package.install_mirror",
    toolIdentityRefs = mirrorToolRefs)

proc m9r14dPascalToKebab*(value: string): string =
  ## DSL-port M9.R.14d.7c — convert ``libwaylandClient`` → ``libwayland-client``.
  ## meson packages name their shared libraries in kebab-case
  ## (``libwayland-client.so``) while recipes commonly declare them
  ## in PascalCase (``library libwaylandClient:``). The probe order
  ## consumes both forms.
  result = ""
  for i, ch in value:
    if ch in {'A' .. 'Z'} and i > 0 and value[i - 1] notin {'-', '_'}:
      result.add('-')
      result.add(chr(ord(ch) - ord('A') + ord('a')))
    elif ch in {'A' .. 'Z'}:
      result.add(chr(ord(ch) - ord('A') + ord('a')))
    else:
      result.add(ch)

proc m9r14fPascalToSnake*(value: string): string =
  ## DSL-port M9.R.14f.9 — convert ``libdrmAmdgpu`` → ``libdrm_amdgpu``.
  ## libdrm / mesa-style libraries use snake_case for the SONAME suffix
  ## (``libdrm_amdgpu.so`` / ``libdrm_nouveau.so``) while recipes
  ## commonly declare them in PascalCase. Mirrors
  ## ``m9r14dPascalToKebab`` but inserts ``_`` instead of ``-``.
  result = ""
  for i, ch in value:
    if ch in {'A' .. 'Z'} and i > 0 and value[i - 1] notin {'-', '_'}:
      result.add('_')
      result.add(chr(ord(ch) - ord('A') + ord('a')))
    elif ch in {'A' .. 'Z'}:
      result.add(chr(ord(ch) - ord('A') + ord('a')))
    else:
      result.add(ch)

proc m9r14dPascalToKebabWithDigits*(value: string): string =
  ## DSL-port M9.R.14d.7d — extension of `m9r14dPascalToKebab` that
  ## also inserts ``-`` at letter-↔-digit transitions. Pixman names its
  ## SONAME ``libpixman-1.so`` while the recipe declares ``libpixman1``
  ## (the trailing digit is the SOVERSION). Used as a fallback probe so
  ## the existing kebab form (e.g. ``libwayland-client``) keeps its
  ## priority.
  result = ""
  for i, ch in value:
    if i > 0:
      let prev = value[i - 1]
      let prevAlpha = prev in {'a' .. 'z', 'A' .. 'Z'}
      let prevDigit = prev in {'0' .. '9'}
      let curUpper = ch in {'A' .. 'Z'}
      let curDigit = ch in {'0' .. '9'}
      if (curUpper and prevAlpha and prev notin {'-', '_'}) or
         (curDigit and prevAlpha) or
         (curUpper and prevDigit):
        result.add('-')
    if ch in {'A' .. 'Z'}:
      result.add(chr(ord(ch) - ord('A') + ord('a')))
    else:
      result.add(ch)

proc emitAutotoolsStageCopy(installEdge: BuildActionDef;
                            buildDir, destdir, packageName, kind, name: string) =
  ## Emit a single stage-copy action that copies the installed
  ## artefact at ``destdir/usr/{bin,lib}/<name>`` into the canonical
  ## ``<projectRoot>/.repro/output/<name>/<name>`` location so the
  ## from-source resolver can find it. Idempotent — guarded by the
  ## ``autotoolsStageCopyEmitted`` flag so a recipe that calls
  ## ``pkg.executable("autoconf")`` multiple times only emits the
  ## stage-copy once.
  let projectRoot = activeProviderProjectRoot()
  if projectRoot.len == 0:
    # Unit-test mode: no provider project root means no on-disk path
    # to stage into. Defer to the legacy "thin handle only" behaviour.
    return
  let flagKey = stageCopyEmittedKey(packageName, kind, name)
  if stageCopyEmitted.len == 0:
    stageCopyEmitted = initHashSet[string]()
  if flagKey in stageCopyEmitted:
    return
  stageCopyEmitted.incl(flagKey)
  let outputDir = projectRoot / ".repro" / "output" / name
  createDir(outputDir)
  let outputPath = outputDir / name
  let escapedOut = outputPath.replace("\\", "/").replace("\"", "\\\"")
  let escapedOutDir = outputDir.replace("\\", "/").replace("\"", "\\\"")
  let effectiveDestRoot =
    if buildDir.len > 0: buildDir & "/" & destdir
    else: destdir
  let installPrefix = effectiveDestRoot & "/usr/" & (if kind == "library": "lib" else: "bin")
  let escapedSrcDir = installPrefix.replace("\\", "/").replace("\"", "\\\"")
  let escapedName = name.replace("\"", "\\\"")
  # Probe order: <prefix>/<name>, <prefix>/<name>.exe (cross-build
  # safety), <prefix>/lib<name>.so (library shape).
  var script = "set -e; mkdir -p \"" & escapedOutDir & "\"; "
  if kind == "library":
    # Library: probe several common autotools / meson naming patterns.
    # The DSL allows the recipe author to declare ``library libExpat:``
    # while the actual file is ``libexpat.so`` (autotools lowercases +
    # prefixes ``lib``); meson uses kebab-case so ``library
    # libwaylandClient:`` maps to ``libwayland-client.so``. The probe
    # order:
    #   1. lib<name>.so          (exact-case)
    #   2. lib<lowerName>.so     (autotools convention — case-folded)
    #   3. <kebabName>.so        (meson kebab-case, with `lib` prefix
    #                             collapsed when the recipe already wrote
    #                             it — `libwaylandClient` → `libwayland-client`)
    #   4. <name>.so             (no lib- prefix, exact-case)
    #   5. <lowerName>.so        (no lib- prefix, case-folded)
    #   6. lib<name>.a / lib<lowerName>.a (static archive fallbacks)
    let escapedLowerName = name.toLowerAscii.replace("\"", "\\\"")
    let kebabName = m9r14dPascalToKebab(name).replace("\"", "\\\"")
    let kebabDigitsName =
      m9r14dPascalToKebabWithDigits(name).replace("\"", "\\\"")
    # M9.R.14f.9 — snake_case probe for libdrm / mesa-style naming
    # where ``libdrmAmdgpu`` maps to ``libdrm_amdgpu.so``.
    let snakeName = m9r14fPascalToSnake(name).replace("\"", "\\\"")
    # M9.R.14g.7 — strip a leading ``lib`` prefix from the DSL name so
    # recipes that already wrote ``library libGModule:`` (the DSL
    # convention) probe the same file shapes recipes using bare
    # ``library glib2:`` shapes do. Without this strip, the lib<name>
    # probe becomes ``liblibGModule.so`` (double-lib) and misses the
    # upstream ``libgmodule-2.0.so``.
    proc stripLibPrefix(value: string): string =
      if value.len > 3 and value[0 .. 2].toLowerAscii == "lib":
        value[3 ..< value.len]
      else:
        value
    let strippedName = stripLibPrefix(name).replace("\"", "\\\"")
    let strippedLowerName = strippedName.toLowerAscii
    let strippedKebab = m9r14dPascalToKebab(stripLibPrefix(name)).replace("\"", "\\\"")
    let strippedKebabDigits = m9r14dPascalToKebabWithDigits(stripLibPrefix(name)).replace("\"", "\\\"")
    let strippedSnake = m9r14fPascalToSnake(stripLibPrefix(name)).replace("\"", "\\\"")
    script.add("for candidate in ")
    script.add("\"" & escapedSrcDir & "/lib" & escapedName & ".so\" ")
    script.add("\"" & escapedSrcDir & "/lib" & escapedLowerName & ".so\" ")
    script.add("\"" & escapedSrcDir & "/" & kebabName & ".so\" ")
    script.add("\"" & escapedSrcDir & "/" & kebabDigitsName & ".so\" ")
    script.add("\"" & escapedSrcDir & "/" & snakeName & ".so\" ")
    script.add("\"" & escapedSrcDir & "/" & escapedName & ".so\" ")
    script.add("\"" & escapedSrcDir & "/" & escapedLowerName & ".so\" ")
    # M9.R.14g.7 — stripped-prefix variants for ``library libFoo:`` shapes.
    if strippedName != name:
      script.add("\"" & escapedSrcDir & "/lib" & strippedName & ".so\" ")
      script.add("\"" & escapedSrcDir & "/lib" & strippedLowerName & ".so\" ")
      # M9.R.14h.8 — kebab + snake variants on the stripped form so
      # ``libJsonC`` -> ``lib<json-c>.so`` and ``libGdkPixbuf`` ->
      # ``lib<gdk_pixbuf>.so`` resolve as plain ``.so`` shapes (the
      # version-suffix glob below handles the ``-N.M.so`` variants).
      if strippedKebab.len > 0 and strippedKebab != strippedLowerName:
        script.add("\"" & escapedSrcDir & "/lib" & strippedKebab & ".so\" ")
      # M9.R.15e.2 — kebab-with-digits stripped variant so PascalCase
      # names with trailing digits resolve to the upstream SONAME shape.
      # ``libGtk4`` -> stripped ``Gtk4`` -> kebabDigits ``gtk-4`` ->
      # probe ``libgtk-4.so`` (matches gtk4's upstream layout).
      if strippedKebabDigits.len > 0 and
          strippedKebabDigits != strippedLowerName and
          strippedKebabDigits != strippedKebab:
        script.add("\"" & escapedSrcDir & "/lib" & strippedKebabDigits & ".so\" ")
      if strippedSnake.len > 0 and strippedSnake != strippedLowerName and
          strippedSnake != strippedKebab:
        script.add("\"" & escapedSrcDir & "/lib" & strippedSnake & ".so\" ")
    script.add("\"" & escapedSrcDir & "/lib" & escapedName & ".a\" ")
    script.add("\"" & escapedSrcDir & "/lib" & escapedLowerName & ".a\" ")
    script.add("\"" & escapedSrcDir & "/" & kebabName & ".a\" ")
    script.add("\"" & escapedSrcDir & "/" & kebabDigitsName & ".a\"; ")
    script.add("do if [ -f \"$candidate\" ]; then cp -fL \"$candidate\" \"" & escapedOut & "\"; exit 0; fi; done; ")
    # M9.R.14g.3 — version-suffix glob fallback for libraries that meson
    # builds with `soversion = '0.19'` and similar (wlroots, gtk-3,
    # libfoo-2.0, ...). The literal probe above only matches
    # `lib<name>.so` shapes; this glob covers `lib<name>-<version>.so`
    # where the version is baked into the SONAME stem rather than as a
    # `.so.<X>` suffix. We sort `LC_ALL=C` and take the FIRST match to
    # stay deterministic; multiple matches in the same directory would
    # be a packaging anomaly we'd surface in the upstream recipe.
    script.add("first=$(ls -1 \"" & escapedSrcDir & "/lib" & escapedName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); ")
    script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & escapedSrcDir & "/lib" & escapedLowerName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
    script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & escapedSrcDir & "/" & kebabName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
    # M9.R.15q.11.5 — dot-versioned SONAME fallback. The DASH-version
    # globs above match ``lib<name>-2.0.so`` (meson soversion +
    # libfoo-2.0 family) but the canonical Linux SONAME convention is
    # ``lib<name>.so.<X>[.Y[.Z]]`` (e.g. libKGlobalAccelD.so.6.2.5,
    # libwayland-client.so.0.25.0). Many KDE/Plasma upstreams install
    # ONLY the dot-versioned ``lib<name>.so.<X>`` symlink + the real
    # ``lib<name>.so.<X>.<Y>.<Z>`` file WITHOUT a bare ``lib<name>.so``
    # — so the literal probe AND the dash-version glob both miss it.
    # Prefer the shortest (typically the major-version symlink, e.g.
    # ``libKGlobalAccelD.so.6``) for the staged copy. We use ``-V`` for
    # version-sort so ``so.10`` doesn't sort before ``so.2``.
    script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & escapedSrcDir & "/lib" & escapedName & ".so.\"* 2>/dev/null | LC_ALL=C sort -V | head -n1); fi; ")
    script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & escapedSrcDir & "/lib" & escapedLowerName & ".so.\"* 2>/dev/null | LC_ALL=C sort -V | head -n1); fi; ")
    # M9.R.15q.11.6 — dot-versioned strippedName variant. The recipe
    # spells the artifact ``libKGlobalAccelD`` (with the ``lib`` prefix)
    # which combined with the literal ``lib`` prefix in
    # ``escapedSrcDir/lib<escapedName>.so.*`` produces
    # ``liblibKGlobalAccelD.so.*`` -- the DOUBLE-lib-prefix isn't what
    # upstream installs.  The strippedName drops one of the two libs
    # so the glob becomes ``libKGlobalAccelD.so.*`` and matches the
    # real install.
    if strippedName != name:
      script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & escapedSrcDir & "/lib" & strippedName & ".so.\"* 2>/dev/null | LC_ALL=C sort -V | head -n1); fi; ")
      script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & escapedSrcDir & "/lib" & strippedLowerName & ".so.\"* 2>/dev/null | LC_ALL=C sort -V | head -n1); fi; ")
    # M9.R.14g.7 — stripped-prefix glob variants (libgmodule-2.0.so etc.)
    if strippedName != name:
      script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & escapedSrcDir & "/lib" & strippedName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
      script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & escapedSrcDir & "/lib" & strippedLowerName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
    # M9.R.14g.8 — letters-only glob. ``libGlib2`` -> ``glib`` (strip
    # ``lib`` + drop trailing digits) -> glob ``libglib-*.so`` matches
    # upstream ``libglib-2.0.so`` where the soversion ``2.0`` contains a
    # ``.`` that simple kebab-digit conversion can't represent.
    proc lettersOnlyLower(value: string): string =
      for ch in value:
        if ch in {'a' .. 'z'}:
          result.add(ch)
        elif ch in {'A' .. 'Z'}:
          result.add(chr(ord(ch) - ord('A') + ord('a')))
    let lettersOnly = lettersOnlyLower(stripLibPrefix(name))
    if lettersOnly.len > 0 and lettersOnly != strippedLowerName:
      script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & escapedSrcDir & "/lib" & lettersOnly & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
    # M9.R.14h.7 — snake-case version-suffix glob for libraries like
    # ``libgdk_pixbuf-2.0.so`` whose upstream SONAME uses an underscore
    # between the project segments while the DSL writes the artifact as
    # ``libgdkPixbuf``.  Without this probe the version-suffix walk
    # only tries ``libgdkPixbuf-*.so`` / ``libgdkpixbuf-*.so`` and
    # misses ``libgdk_pixbuf-2.0.so`` outright.
    if strippedSnake.len > 0 and strippedSnake != strippedLowerName:
      script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & escapedSrcDir & "/lib" & strippedSnake & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
    # M9.R.14h.8 — kebab stripped version-suffix glob for libraries like
    # ``libjson-c.so`` where the recipe writes ``libJsonC`` -> stripped
    # ``JsonC`` -> kebab ``json-c`` -> glob ``libjson-c-*.so``.
    if strippedKebab.len > 0 and strippedKebab != strippedLowerName and
        strippedKebab != strippedSnake:
      script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & escapedSrcDir & "/lib" & strippedKebab & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
    # M9.R.15e.2 — kebab-with-digits stripped version-suffix glob for
    # PascalCase names whose digit suffix is the SOVERSION separator.
    # ``libGtk4`` -> stripped ``Gtk4`` -> kebabDigits ``gtk-4`` ->
    # glob ``libgtk-4-*.so`` (gtk-4 ships ``libgtk-4.so`` AND
    # ``libgtk-4.so.<X>`` — the plain-name probe handles the former; the
    # glob handles version-suffix variants like ``libgtk-4-extras.so``).
    if strippedKebabDigits.len > 0 and
        strippedKebabDigits != strippedLowerName and
        strippedKebabDigits != strippedKebab and
        strippedKebabDigits != strippedSnake:
      script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & escapedSrcDir & "/lib" & strippedKebabDigits & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
    script.add("if [ -n \"$first\" ]; then cp -fL \"$first\" \"" & escapedOut & "\"; exit 0; fi; ")
    # M9.R.14g.7 — many recipes write ``library libGModule:`` but the
    # upstream library lives under ``lib/x86_64-linux-gnu/`` or
    # ``lib64/`` instead of ``lib/``. Probe both common multi-arch
    # subdirs as a last-resort fallback so x86_64 cmake recipes
    # publishing under ``lib64/`` (e.g. json-c, gobject-introspection)
    # don't fail stage-copy.
    let lib64Dir = escapedSrcDir.replace("/usr/lib", "/usr/lib64")
    if lib64Dir != escapedSrcDir:
      script.add("for candidate in ")
      script.add("\"" & lib64Dir & "/lib" & escapedName & ".so\" ")
      script.add("\"" & lib64Dir & "/lib" & escapedLowerName & ".so\" ")
      # M9.R.14h.8 — kebab+snake stripped variants on lib64 too.
      if strippedKebab.len > 0 and strippedKebab != strippedLowerName:
        script.add("\"" & lib64Dir & "/lib" & strippedKebab & ".so\" ")
      # M9.R.15e.2 — kebab-with-digits stripped variant on lib64 (gtk4).
      if strippedKebabDigits.len > 0 and
          strippedKebabDigits != strippedLowerName and
          strippedKebabDigits != strippedKebab:
        script.add("\"" & lib64Dir & "/lib" & strippedKebabDigits & ".so\" ")
      if strippedSnake.len > 0 and strippedSnake != strippedLowerName and
          strippedSnake != strippedKebab:
        script.add("\"" & lib64Dir & "/lib" & strippedSnake & ".so\" ")
      if strippedName != name:
        script.add("\"" & lib64Dir & "/lib" & strippedName & ".so\" ")
        script.add("\"" & lib64Dir & "/lib" & strippedLowerName & ".so\"; ")
      else:
        script.add("\"" & lib64Dir & "/lib" & escapedLowerName & ".so\"; ")
      script.add("do if [ -f \"$candidate\" ]; then cp -fL \"$candidate\" \"" & escapedOut & "\"; exit 0; fi; done; ")
      script.add("first=$(ls -1 \"" & lib64Dir & "/lib" & escapedName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); ")
      script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & lib64Dir & "/lib" & escapedLowerName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
      if strippedName != name:
        script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & lib64Dir & "/lib" & strippedName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
        script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & lib64Dir & "/lib" & strippedLowerName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
      # M9.R.14h.8 — kebab + snake stripped version-suffix globs on lib64.
      if strippedKebab.len > 0 and strippedKebab != strippedLowerName:
        script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & lib64Dir & "/lib" & strippedKebab & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
      # M9.R.15e.2 — kebab-with-digits stripped version-suffix glob on lib64.
      if strippedKebabDigits.len > 0 and
          strippedKebabDigits != strippedLowerName and
          strippedKebabDigits != strippedKebab and
          strippedKebabDigits != strippedSnake:
        script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & lib64Dir & "/lib" & strippedKebabDigits & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
      if strippedSnake.len > 0 and strippedSnake != strippedLowerName and
          strippedSnake != strippedKebab:
        script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & lib64Dir & "/lib" & strippedSnake & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
      script.add("if [ -n \"$first\" ]; then cp -fL \"$first\" \"" & escapedOut & "\"; exit 0; fi; ")
    # M9.R.15e.9 — some autotools projects (Linux-PAM, glibc, util-linux's
    # libuuid path) hardcode ``libdir=/lib64`` in their configure.ac
    # regardless of ``--prefix``, so the .so files install to
    # ``<destdir>/lib64/`` (no ``/usr/`` segment).  Walk both bare
    # ``<destdir>/lib`` and ``<destdir>/lib64`` as a last-resort probe
    # AFTER the ``usr/lib`` + ``usr/lib64`` checks have failed.
    #
    # We re-use the install root above ``/usr`` by stripping ``/usr/lib``
    # off escapedSrcDir; this gives the destdir root which we then walk
    # for ``/lib`` + ``/lib64`` directly.
    var destdirRoot = ""
    if escapedSrcDir.endsWith("/usr/lib"):
      destdirRoot = escapedSrcDir[0 ..< (escapedSrcDir.len - "/usr/lib".len)]
    if destdirRoot.len > 0:
      for bareDir in ["/lib64", "/lib"]:
        let dirPath = destdirRoot & bareDir
        # Plain candidates.
        script.add("for candidate in ")
        script.add("\"" & dirPath & "/lib" & escapedName & ".so\" ")
        script.add("\"" & dirPath & "/lib" & escapedLowerName & ".so\" ")
        if strippedKebab.len > 0 and strippedKebab != strippedLowerName:
          script.add("\"" & dirPath & "/lib" & strippedKebab & ".so\" ")
        if strippedKebabDigits.len > 0 and
            strippedKebabDigits != strippedLowerName and
            strippedKebabDigits != strippedKebab:
          script.add("\"" & dirPath & "/lib" & strippedKebabDigits & ".so\" ")
        if strippedSnake.len > 0 and strippedSnake != strippedLowerName and
            strippedSnake != strippedKebab:
          script.add("\"" & dirPath & "/lib" & strippedSnake & ".so\" ")
        if strippedName != name:
          script.add("\"" & dirPath & "/lib" & strippedName & ".so\" ")
          script.add("\"" & dirPath & "/lib" & strippedLowerName & ".so\"; ")
        else:
          script.add("\"" & dirPath & "/lib" & escapedLowerName & ".so\"; ")
        script.add("do if [ -f \"$candidate\" ]; then cp -fL \"$candidate\" \"" & escapedOut & "\"; exit 0; fi; done; ")
        # Version-suffix glob.
        script.add("first=$(ls -1 \"" & dirPath & "/lib" & escapedName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); ")
        script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & dirPath & "/lib" & escapedLowerName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
        if strippedName != name:
          script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & dirPath & "/lib" & strippedName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
          script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & dirPath & "/lib" & strippedLowerName & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
        if strippedKebab.len > 0 and strippedKebab != strippedLowerName:
          script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & dirPath & "/lib" & strippedKebab & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
        if strippedKebabDigits.len > 0 and
            strippedKebabDigits != strippedLowerName and
            strippedKebabDigits != strippedKebab and
            strippedKebabDigits != strippedSnake:
          script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & dirPath & "/lib" & strippedKebabDigits & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
        if strippedSnake.len > 0 and strippedSnake != strippedLowerName and
            strippedSnake != strippedKebab:
          script.add("if [ -z \"$first\" ]; then first=$(ls -1 \"" & dirPath & "/lib" & strippedSnake & "\"-*.so 2>/dev/null | LC_ALL=C sort | head -n1); fi; ")
        script.add("if [ -n \"$first\" ]; then cp -fL \"$first\" \"" & escapedOut & "\"; exit 0; fi; ")
    script.add("echo \"autotools_package stage-copy: no library candidate for " & escapedName & " under " & escapedSrcDir & "\" >&2; exit 1")
  else:
    # Executable: probe bare name; also try .exe for cross-builds and
    # kebab-case (meson convention — recipe declares
    # ``executable waylandScanner`` while meson installs
    # ``wayland-scanner``).
    let kebabName = m9r14dPascalToKebab(name).replace("\"", "\\\"")
    # M9.R.14f.11 — recipes sometimes append a disambiguating suffix
    # like ``Bin`` / ``CLI`` / ``Cmd`` / ``Tool`` to the DSL artifact
    # identifier so the slot doesn't collide with the recipe's library
    # of the same upstream name (e.g. libinput recipe has
    # ``library libinput`` + ``executable libinputBin`` but upstream
    # installs the CLI as bare ``libinput``). Probe the suffix-
    # stripped form as a fallback.
    var strippedName = name
    # M9.R.15q.12.4 — also strip ``Init`` so ``systemdInit`` (the
    # systemd recipe's renamed slot for the bare-``systemd`` upstream
    # init binary) probes for ``systemd`` under the candidate dirs.
    # The recipe renames the slot to avoid colliding with the
    # ``systemd`` package-name prefix (per the sddm / sddmGreeter
    # disambiguation convention).
    # M9.R.15q.12.5 — also strip ``Daemon`` so ``pipewireDaemon``
    # probes for the bare ``pipewire`` binary name (same renaming
    # convention as systemdInit).
    for suffix in ["Bin", "CLI", "Cmd", "Tool", "Exe", "Init", "Daemon"]:
      if strippedName.endsWith(suffix) and strippedName.len > suffix.len:
        strippedName = strippedName[0 ..< (strippedName.len - suffix.len)]
        break
    let strippedEscaped = strippedName.replace("\"", "\\\"")
    let strippedKebab =
      m9r14dPascalToKebab(strippedName).replace("\"", "\\\"")
    # M9.R.15m.6 — system daemons (udevd, sshd, kmodd, etc.) install
    # to ``usr/sbin`` rather than ``usr/bin``. Build the candidate dir
    # list as ``usr/bin`` first (canonical), then fall back to
    # ``usr/sbin`` so recipes don't need to special-case the install
    # path. The destdir-relative install root is ``effectiveDestRoot``;
    # we already used ``installPrefix = effectiveDestRoot & "/usr/bin"``
    # above, so derive ``sbinSrcDir`` parallel to it here.
    let sbinSrcDir = (effectiveDestRoot & "/usr/sbin").replace("\\", "/").replace("\"", "\\\"")
    # M9.R.15q.11.4 — KDE Plasma daemons (kglobalacceld, kactivitymanagerd,
    # etc.) install under ``$libdir/libexec/`` per Qt6's INSTALL_LIBEXECDIR
    # convention; some upstreams use ``$prefix/libexec/`` directly. Probe
    # both shapes after the canonical $bindir + $sbindir.
    let libexecSrcDir = (effectiveDestRoot & "/usr/libexec").replace("\\", "/").replace("\"", "\\\"")
    let libLibexecSrcDir = (effectiveDestRoot & "/usr/lib/libexec").replace("\\", "/").replace("\"", "\\\"")
    # M9.R.15q.12.4 — systemd's daemons (``systemd``, ``systemd-logind``,
    # ``systemd-journald``, ``systemd-udevd``) install under
    # ``$libdir/systemd/`` (the systemd-private libexec convention).
    # Without this entry, the autotools_package executable stage-copy
    # for systemdInit/systemdLogind fails with "no executable candidate"
    # even though the binary IS in the install tree. Probe this AFTER
    # the canonical $bindir + $sbindir + $libexec dirs so non-systemd
    # recipes that happen to ship a same-named file under $libdir/X/
    # don't get mis-routed.
    let libSystemdSrcDir = (effectiveDestRoot & "/usr/lib/systemd").replace("\\", "/").replace("\"", "\\\"")
    # M9.R.27.2 — polkit installs its daemon + helper binaries under
    # ``$libdir/polkit-1/`` (the polkit-private libexec convention).
    # Without this entry, the autotools_package executable stage-copy
    # for polkitd / polkit-agent-helper-1 fails with "no executable
    # candidate" even though the binaries ARE in the install tree at
    # /usr/lib/polkit-1/polkitd + /usr/lib/polkit-1/polkit-agent-helper-1.
    # Probe this AFTER the canonical $bindir + $sbindir + $libexec dirs.
    let libPolkit1SrcDir = (effectiveDestRoot & "/usr/lib/polkit-1").replace("\\", "/").replace("\"", "\\\"")
    let candidateDirs = @[escapedSrcDir, sbinSrcDir, libexecSrcDir, libLibexecSrcDir, libSystemdSrcDir, libPolkit1SrcDir]
    # M9.R.15q.7.9 — also probe snake_case form. The kebab probe
    # covers ``kwinWayland`` → ``kwin-wayland`` but kwin upstream
    # installs ``kwin_wayland`` (snake_case underscore). The library
    # case at line ~1361 already probes m9r14fPascalToSnake; mirror
    # that here for executables.
    let snakeName = m9r14fPascalToSnake(name).replace("\"", "\\\"")
    let strippedSnake = m9r14fPascalToSnake(strippedName).replace("\"", "\\\"")
    var first = true
    for dir in candidateDirs:
      let leader = (if first: "if" else: "elif")
      script.add(leader & " [ -f \"" & dir & "/" & escapedName & "\" ]; then ")
      script.add("cp -fL \"" & dir & "/" & escapedName & "\" \"" & escapedOut & "\"; chmod +x \"" & escapedOut & "\"; ")
      script.add("elif [ -f \"" & dir & "/" & kebabName & "\" ]; then ")
      script.add("cp -fL \"" & dir & "/" & kebabName & "\" \"" & escapedOut & "\"; chmod +x \"" & escapedOut & "\"; ")
      if snakeName != kebabName and snakeName != name:
        script.add("elif [ -f \"" & dir & "/" & snakeName & "\" ]; then ")
        script.add("cp -fL \"" & dir & "/" & snakeName & "\" \"" & escapedOut & "\"; chmod +x \"" & escapedOut & "\"; ")
      if strippedName != name:
        script.add("elif [ -f \"" & dir & "/" & strippedEscaped & "\" ]; then ")
        script.add("cp -fL \"" & dir & "/" & strippedEscaped & "\" \"" & escapedOut & "\"; chmod +x \"" & escapedOut & "\"; ")
        script.add("elif [ -f \"" & dir & "/" & strippedKebab & "\" ]; then ")
        script.add("cp -fL \"" & dir & "/" & strippedKebab & "\" \"" & escapedOut & "\"; chmod +x \"" & escapedOut & "\"; ")
        if strippedSnake != strippedKebab and strippedSnake != strippedName:
          script.add("elif [ -f \"" & dir & "/" & strippedSnake & "\" ]; then ")
          script.add("cp -fL \"" & dir & "/" & strippedSnake & "\" \"" & escapedOut & "\"; chmod +x \"" & escapedOut & "\"; ")
      script.add("elif [ -f \"" & dir & "/" & escapedName & ".exe\" ]; then ")
      script.add("cp -fL \"" & dir & "/" & escapedName & ".exe\" \"" & escapedOut & ".exe\"; ")
      first = false
    script.add("else echo \"autotools_package stage-copy: no executable candidate for " & escapedName & " under " & escapedSrcDir & " or " & sbinSrcDir & " or " & libexecSrcDir & " or " & libLibexecSrcDir & " or " & libSystemdSrcDir & " or " & libPolkit1SrcDir & "\" >&2; exit 1; fi")
  let argv = @["sh", "-c", script]
  let stageId = "autotools-stage-" & kind & "-" & sanitizeStageCopyName(packageName) &
    "-" & sanitizeStageCopyName(name)
  discard buildAction(
    id = stageId,
    call = inlineExecCall(argv),
    deps = @[installEdge.id],
    inputs = installEdge.outputs,
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "autotools_package.stage." & kind,
    toolIdentityRefs = @["sh"])

proc emitStageCopyAlias(installEdge: BuildActionDef;
                        buildDir, destdir, packageName, aliasName,
                        sourceName: string) =
  ## M9.R.15g.1 — emit a stage-copy that copies the installed binary
  ## ``<destdir>/usr/bin/<sourceName>`` into the canonical from-source
  ## resolver path ``.repro/output/<aliasName>/<aliasName>`` so a dep
  ## selector that doesn't match any of the package's own binary names
  ## resolves to one of them by alias.
  ##
  ## Mirrors ``emitAutotoolsStageCopy`` for the executable kind but
  ## uses ``sourceName`` for the probe source and ``aliasName`` for the
  ## destination so the same upstream binary can be staged under
  ## multiple names. Idempotent — keyed by ``(packageName, "executable",
  ## aliasName)`` so repeated declarations only emit one action.
  let projectRoot = activeProviderProjectRoot()
  if projectRoot.len == 0:
    return
  let flagKey = stageCopyEmittedKey(packageName, "executable", aliasName)
  if stageCopyEmitted.len == 0:
    stageCopyEmitted = initHashSet[string]()
  if flagKey in stageCopyEmitted:
    return
  stageCopyEmitted.incl(flagKey)
  let outputDir = projectRoot / ".repro" / "output" / aliasName
  createDir(outputDir)
  let outputPath = outputDir / aliasName
  let escapedOut = outputPath.replace("\\", "/").replace("\"", "\\\"")
  let escapedOutDir = outputDir.replace("\\", "/").replace("\"", "\\\"")
  let effectiveDestRoot =
    if buildDir.len > 0: buildDir & "/" & destdir
    else: destdir
  let escapedSrc = sourceName.replace("\"", "\\\"")
  # M9.R.28.4 — probe usr/bin THEN usr/sbin THEN usr/libexec THEN
  # usr/lib/libexec for the alias source. Filesystem-utility recipes
  # (dosfstools, e2fsprogs, util-linux) install most binaries under
  # /usr/sbin/, not /usr/bin/, so the historical bin-only probe missed
  # them and forced recipes to over-specify install paths.
  let bin = (effectiveDestRoot & "/usr/bin").replace("\\", "/").replace("\"", "\\\"")
  let sbin = (effectiveDestRoot & "/usr/sbin").replace("\\", "/").replace("\"", "\\\"")
  let libexec = (effectiveDestRoot & "/usr/libexec").replace("\\", "/").replace("\"", "\\\"")
  let libLibexec = (effectiveDestRoot & "/usr/lib/libexec").replace("\\", "/").replace("\"", "\\\"")
  let candidateDirs = [bin, sbin, libexec, libLibexec]
  var script = "set -e; mkdir -p \"" & escapedOutDir & "\"; "
  var firstClause = true
  for dir in candidateDirs:
    let leader = (if firstClause: "if" else: "elif")
    script.add(leader & " [ -f \"" & dir & "/" & escapedSrc & "\" ]; then ")
    script.add("cp -fL \"" & dir & "/" & escapedSrc & "\" \"" & escapedOut & "\"; chmod +x \"" & escapedOut & "\"; ")
    script.add("elif [ -f \"" & dir & "/" & escapedSrc & ".exe\" ]; then ")
    script.add("cp -fL \"" & dir & "/" & escapedSrc & ".exe\" \"" & escapedOut & ".exe\"; ")
    firstClause = false
  script.add("else echo \"executableAlias stage-copy: no source binary " & escapedSrc & " under " & bin & " or " & sbin & " or " & libexec & " or " & libLibexec & "\" >&2; exit 1; fi")
  let argv = @["sh", "-c", script]
  let stageId = "autotools-stage-alias-" & sanitizeStageCopyName(packageName) &
    "-" & sanitizeStageCopyName(aliasName)
  discard buildAction(
    id = stageId,
    call = inlineExecCall(argv),
    deps = @[installEdge.id],
    inputs = installEdge.outputs,
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "autotools_package.stage.executable_alias",
    toolIdentityRefs = @["sh"])

# ---------------------------------------------------------------------------
# Slicing methods — AutotoolsPackageResult
# ---------------------------------------------------------------------------

proc executable*(r: AutotoolsPackageResult; name: string): Executable =
  # M9.R.14c.5 — emit a stage-copy action that bridges the autotools
  # DESTDIR install tree (``<buildDir>/<destdir>/usr/bin/<name>``)
  # onto the canonical from-source resolver path
  # (``.repro/output/<name>/<name>``) so consumers of the recipe can
  # resolve the artefact at the location the resolver looks for it.
  emitAutotoolsStageCopy(r.installEdge, r.buildDir, r.destdir,
    currentOwningPackage(), "executable", name)
  # M9.R.14e.2 — install-tree mirror at the canonical layout-stable
  # location ``.repro/output/install/usr/`` (see ``emitInstallTreeMirror``).
  emitInstallTreeMirror(r.installEdge, r.buildDir, r.destdir,
    currentOwningPackage())
  newExecutable(
    install = r.installEdge,
    executableName = name,
    installPrefix = componentPath(r.components, "runtime"))

proc executableAlias*(r: AutotoolsPackageResult; aliasName, sourceName: string):
    Executable =
  ## M9.R.28.4 — autotools-side mirror of ``MesonPackageResult.executableAlias``.
  ## Some autotools projects install binaries whose on-disk names
  ## include characters the PascalToKebab transformer cannot represent
  ## (e.g. ``mkfs.fat``, ``fsck.fat`` — period between the verb and
  ## the filesystem name) so the stock probe shape misses them.
  ## ``executableAlias`` stages the binary at
  ## ``<destdir>/usr/{bin,sbin}/<sourceName>`` under the canonical
  ## ``.repro/output/<aliasName>/<aliasName>`` resolver path, letting
  ## the recipe author bridge the DSL-side name to the upstream
  ## on-disk basename verbatim.
  emitStageCopyAlias(r.installEdge, r.buildDir, r.destdir,
    currentOwningPackage(), aliasName, sourceName)
  emitInstallTreeMirror(r.installEdge, r.buildDir, r.destdir,
    currentOwningPackage())
  newExecutable(
    install = r.installEdge,
    executableName = aliasName,
    installPrefix = componentPath(r.components, "runtime"))

proc library*(r: AutotoolsPackageResult; name: string): Library =
  emitAutotoolsStageCopy(r.installEdge, r.buildDir, r.destdir,
    currentOwningPackage(), "library", name)
  emitInstallTreeMirror(r.installEdge, r.buildDir, r.destdir,
    currentOwningPackage())
  newLibrary(
    install = r.installEdge,
    installPrefix = componentPath(r.components, "library"))

proc files*(r: AutotoolsPackageResult; name: string): BuildActionDef =
  discard componentPath(r.components, name)
  r.installEdge
