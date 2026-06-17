## Reprobuild project DSL umbrella module.
##
## Every generated and hand-authored ``reprobuild.nim`` consumes this
## module via ``import repro_project_dsl``. Internally the DSL is split
## into composable include files so that the heavy runtime portion can
## eventually be factored out into a shared library
## (see ``reprobuild-specs/Provider-Compile-Tiering.md``):
##
## * ``repro_project_dsl/types``            — object/enum/tuple defs
## * ``repro_project_dsl/runtime_core``     — registry globals + the
##                                            169 ordinary procs
## * ``repro_project_dsl/macros_a``         — compile-time helpers used
##                                            by ``defineCliInterface`` /
##                                            ``package``, plus the
##                                            ``defineCliInterface``
##                                            macro
## * ``repro_project_dsl/runtime_provider`` — provider-mode-only runtime
##                                            procs (gated on
##                                            ``reproProviderMode``)
## * ``repro_project_dsl/macros_b``         — remaining compile-time
##                                            helpers and the
##                                            ``package`` macro
##
## The umbrella file keeps the public import surface byte-identical for
## callers across legacy/monolithic and shared-DLL provider modes; only
## the include files change role between modes.

import std/[algorithm, json, macros, os, strutils, tables]

# DSL-port M9.A: ``nimcrypto/sha2`` powers the content-addressed sha256
# hashing path for ``consumeConfigFile`` / ``consumeManagedBlock``. We
# import-alias it under ``ncSha2`` so the M9.A wrappers below can
# instantiate ``ncSha2.sha256`` without colliding with any top-level
# ``sha256`` identifier callers may want to re-introduce. The shim
# modules at ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/`` use
# the same library + identical digest interface, so the cache-key
# composition stays byte-comparable across the M9.A DSL surface and the
# pre-existing shim emitters (Generated-Configuration-Files.md
# §"Cache-key composition").
import nimcrypto/sha2 as ncSha2

proc extendedPath(path: string): string =
  when defined(windows):
    if path.len == 0 or path.startsWith("\\\\"):
      path
    else:
      "\\\\?\\" & absolutePath(path).replace('/', '\\')
  else:
    path

when defined(reproProviderMode):
  import repro_provider_runtime
  export repro_provider_runtime

include "repro_project_dsl/types"

# Project-DSL-Composition M5: per-section typed-object prelude.
# Defines ``Package[name]`` / ``PackageBuild[name]`` and the section-
# accessor templates the new cross-project reference machinery emits
# binding accessors against.
include "repro_project_dsl/prelude_typed_objects"

# The ``dynOrStatic`` pragma macro toggles each public runtime proc
# between three roles:
#   * legacy monolithic build (default): body stays, no decoration;
#   * shared DSL runtime DLL build (``-d:reproProviderRuntimeDll``):
#     body stays, proc is annotated ``{.exportc, dynlib.}`` so its
#     symbol is exported from ``librepro_project_dsl_runtime.{dll,
#     so,dylib}``;
#   * static stub in dynamic mode (``-d:reproProviderDynamic``,
#     selected via ``REPRO_PROVIDER_DYNAMIC=1`` — see
#     ``providerCompileCommand`` in ``repro_interface_artifacts``):
#     body is dropped, proc is annotated
#     ``{.importc, dynlib: "repro_project_dsl_runtime".}`` so the
#     per-project provider binary links against the shared DLL
#     instead of compiling ~5000 lines of DSL+runtime code inline.
#
# Procs called from macro bodies at compile time (``stableHashHex``,
# ``parsePackageDef``, ``dependencyPolicyCode``, …) are file-local
# (no ``*``) and are not annotated with ``{.dynOrStatic.}``; they
# stay statically compiled so the Nim VM can still execute them when
# expanding ``package`` / ``defineCliInterface``.
import "repro_project_dsl/dyn_or_static"
export dyn_or_static
include "repro_project_dsl/runtime_core"
# DSL-port M2 — sidecar runtime for the v8-style ``config:`` scalar
# surface and the new ``versions:`` registry. Lives in its own module so
# the M2 reader/writer API is consumable directly by host code and by
# tests without dragging the macro side along. The ``package`` macro
# emits ``recordConfigDefault[T](...)`` and ``registerVersion(...)``
# calls into the lowered body, both of which resolve through this
# module's public procs.
include "repro_project_dsl/dsl_port_runtime"
include "repro_project_dsl/macros_a"
include "repro_project_dsl/runtime_provider"
# Project-DSL-Composition M5: cross-project edge references —
# compile-time uses-registry, cycle detection, top-level `let`/`var`
# binding collection inside the producer's `build:` block, plus the
# storage / accessor-template / instrumentation emitters used by the
# `package` macro.
include "repro_project_dsl/cross_project"
include "repro_project_dsl/macros_b"
