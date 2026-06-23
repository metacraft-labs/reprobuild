## Standard-Configurations — the built-in ``buildType`` axis the Layer-2
## build operations (``compile`` / ``link``) consume.
##
## ``buildType`` is assumed to exist in every project: a recipe does NOT
## have to declare it for ``compile``/``link`` to pick optimization and
## debug-info defaults. ``currentBuildType()`` resolves it the same way
## ``operations/toolchain.currentCompiler()`` resolves the ``compiler``
## variant — thread-local override (tests) → solver-resolved ``buildType``
## variant → ``REPRO_VARIANTS`` env (so ``repro build --release`` works even
## for a recipe that never declared the variant) → the ``debug`` default.
##
## The default is ``debug``: like ``cargo build``, building your own project
## from the command line is a debug build. Systems that are *configured*
## rather than iterated on (e.g. a ReproOS image) set their own default by
## declaring ``buildType`` with a different default in their ``config:``
## block, and any build can override per-invocation with ``--release`` /
## ``--variant buildType=<value>``. Projects may also widen the value set
## (``pgo``, ``coverage``, …) by declaring the variant with extra enum
## values; ``parseBuildType`` maps the four standard names and falls back to
## ``debug`` for unknown values (the recipe that introduced them reads
## ``.value`` directly).

import std/[os, strutils, tables]

import repro_project_dsl
import ../configurables/variants

type
  BuildType* = enum
    ## The four standard build configurations (Standard-Configurations.md).
    btDebug          ## -O0 + debug info; assertions on. The default.
    btRelease        ## optimized, no debug info.
    btRelWithDebInfo ## optimized + debug info.
    btMinSizeRel     ## size-optimized.

const VariantName* = "buildType"

var
  buildTypeOverride {.threadvar.}: string
    ## Thread-local override for test fixtures that drive the operations
    ## without running the variant solver. Empty means "no override".

proc setBuildTypeOverride*(name: string) =
  ## Test-fixture helper. Pass ``""`` to clear the override.
  buildTypeOverride = name

proc parseBuildType*(name: string): BuildType =
  ## Map a ``buildType`` string onto the enum. Unknown / project-specific
  ## values fall back to ``btDebug`` — the operations are forgiving so a
  ## recipe that introduces an extra value (e.g. ``pgo``) without teaching
  ## the standard operations about it still gets a sane compile, while the
  ## recipe itself reads ``buildType.value`` to drive its custom edges.
  case name.toLowerAscii()
  of "debug": btDebug
  of "release": btRelease
  of "relwithdebinfo", "release-with-debug-info": btRelWithDebInfo
  of "minsizerel", "min-size-release": btMinSizeRel
  else: btDebug

proc buildTypeFromEnv(): string =
  ## Parse ``buildType=<value>`` out of ``REPRO_VARIANTS`` (the env var the
  ## ``--variant`` / ``--release`` CLI flags write). Returns "" when absent.
  for assignment in getEnv("REPRO_VARIANTS").split(','):
    let kv = assignment.split('=', 1)
    if kv.len == 2 and kv[0].strip() == VariantName:
      return kv[1].strip()
  ""

proc currentBuildType*(): BuildType =
  ## Resolve the active build type. Lookup order:
  ##   1. Thread-local override (test fixtures).
  ##   2. Solver-resolved ``buildType`` variant.
  ##   3. ``REPRO_VARIANTS`` env (recipe never declared the variant).
  ##   4. ``btDebug`` default.
  if buildTypeOverride.len > 0:
    return parseBuildType(buildTypeOverride)
  if hasSolverSolution():
    let sol = lastSolverSolution()
    if VariantName in sol.variants:
      return parseBuildType(sol.variants[VariantName])
  let fromEnv = buildTypeFromEnv()
  if fromEnv.len > 0:
    return parseBuildType(fromEnv)
  btDebug

type
  BuildTypeCompileFlags* = object
    ## gcc/clang compile flags derived from a build type.
    optimization*: string  ## ``-O`` level, e.g. "0", "2", "s".
    debugInfo*: bool       ## emit debug info (``-g``).

proc compileFlagsFor*(bt: BuildType): BuildTypeCompileFlags =
  ## The standard optimization / debug-info defaults per build type, mapped
  ## to the gcc/clang model (``-O<level>`` + ``-g``). Cf. Spack's
  ## ``build_type`` → ``CMAKE_BUILD_TYPE`` mapping.
  case bt
  of btDebug:          BuildTypeCompileFlags(optimization: "0", debugInfo: true)
  of btRelease:        BuildTypeCompileFlags(optimization: "2", debugInfo: false)
  of btRelWithDebInfo: BuildTypeCompileFlags(optimization: "2", debugInfo: true)
  of btMinSizeRel:     BuildTypeCompileFlags(optimization: "s", debugInfo: false)

proc currentCompileFlags*(): BuildTypeCompileFlags =
  ## Convenience: ``compileFlagsFor(currentBuildType())``.
  compileFlagsFor(currentBuildType())
