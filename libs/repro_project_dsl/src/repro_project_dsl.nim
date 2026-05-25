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

when defined(reproProviderDynamic):
  # Tier 1 dynamic mode (opt-in via ``REPRO_PROVIDER_DYNAMIC=1`` on the
  # engine side; see ``providerCompileCommand`` in
  # ``repro_interface_artifacts``). The runtime portion of the DSL is
  # available as ``librepro_project_dsl_runtime.{dll,so,dylib}`` next
  # to ``repro.exe``.
  #
  # Status: the foundation is in place (DLL builds, link flags emit,
  # umbrella branches), but the runtime include files are still pulled
  # in here unchanged. The configure-time speedup only materialises
  # once a follow-on change replaces the runtime includes below with
  # ``{.dynlib, importc.}`` forward declarations generated from the
  # same proc surface. The macros call a small set of runtime procs
  # from their compile-time bodies — at least
  # ``defaultDependencyPolicy``, ``declaredOnlyDependencyPolicy``,
  # ``automaticMonitorPolicy``, ``makeDepfilePolicy``,
  # ``stableHashHex``, ``callIdentity``, ``defaultToolActionId``,
  # ``actionIdPart``, ``parseExpr``-emitting helpers — and those
  # specific bodies must stay static so the Nim VM can still execute
  # them when expanding ``package`` / ``defineCliInterface``.
  include "repro_project_dsl/runtime_core"
  include "repro_project_dsl/macros_a"
  include "repro_project_dsl/runtime_provider"
  include "repro_project_dsl/macros_b"
else:
  include "repro_project_dsl/runtime_core"
  include "repro_project_dsl/macros_a"
  include "repro_project_dsl/runtime_provider"
  include "repro_project_dsl/macros_b"
