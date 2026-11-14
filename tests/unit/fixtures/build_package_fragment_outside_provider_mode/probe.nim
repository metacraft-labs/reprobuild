## Probe for
## tests/unit/t_build_package_fragment_outside_provider_mode_names_the_define.nim.
##
## Calls the two provider-mode-only entry points of `repro_project_dsl` in
## the shapes real callers use: `buildPackageFragment` with three positional
## arguments plus the named `includeDefault = false` (as
## `conventions/from_source_custom.nim` and its siblings do), and with three
## positional arguments (as `repro_cmake_trycompile_provider.nim` does); and
## `buildPackageDevEnv` with three positional arguments (as the
## `libs/repro_project_dsl/tests` dev-env tests do). It imports exactly what
## `from_source_custom.nim` imports for that call.
##
## The test compiles it with and without `-d:reproProviderMode`; it is never
## run. Each call is on its own line, and the test locates those lines by the
## `CALL:` markers, so keep one marker per call.

import repro_provider_runtime
import repro_project_dsl

proc registerAll() =
  discard

proc namedIncludeDefault(pkg: PackageDef;
                         request: ProviderGraphRequest): GraphFragment =
  result = buildPackageFragment(pkg, request, registerAll, # CALL: named
    includeDefault = false)

proc positionalThreeArguments(pkg: PackageDef;
                              request: ProviderGraphRequest): GraphFragment =
  buildPackageFragment(pkg, request, registerAll) # CALL: positional

proc devEnv(pkg: PackageDef; request: ProviderGraphRequest): DevEnvResult =
  buildPackageDevEnv(pkg, request, registerAll) # CALL: dev-env

when isMainModule:
  let pkg = PackageDef(packageName: "probe")
  let request = ProviderGraphRequest(arguments: ".")
  discard namedIncludeDefault(pkg, request)
  discard positionalThreeArguments(pkg, request)
  discard devEnv(pkg, request)
