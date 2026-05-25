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
include "repro_project_dsl/macros_a"
include "repro_project_dsl/runtime_provider"
include "repro_project_dsl/macros_b"
