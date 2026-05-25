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
include "repro_project_dsl/runtime_core"
include "repro_project_dsl/macros_a"
include "repro_project_dsl/runtime_provider"
include "repro_project_dsl/macros_b"
