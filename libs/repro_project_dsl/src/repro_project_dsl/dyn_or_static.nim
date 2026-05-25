## Pragma macro that toggles a public DSL+runtime proc between three
## compilation roles:
##
## * **Legacy monolithic** (neither ``reproProviderRuntimeDll`` nor
##   ``reproProviderDynamic`` defined): the proc body stays untouched
##   and is compiled into the importing module exactly as before.
##
## * **Shared DSL runtime DLL build** (``reproProviderRuntimeDll``
##   defined): the proc body stays, and the proc is annotated
##   ``{.exportc, dynlib.}`` so its symbol is exported from
##   ``librepro_project_dsl_runtime.{dll,so,dylib}`` under a
##   deterministic, overload-disambiguated C name.
##
## * **Static stub in dynamic mode** (``reproProviderDynamic`` defined,
##   ``reproProviderRuntimeDll`` NOT defined — the per-project provider
##   compile with ``REPRO_PROVIDER_DYNAMIC=1`` on the engine side): the
##   body is replaced with ``discard`` and the proc is annotated
##   ``{.importc, dynlib: "repro_project_dsl_runtime".}`` so the link
##   step resolves it against the shared DSL runtime DLL produced
##   above.
##
## Overloaded procs (``providerDirectoryInput*``, ``exportTarget*``,
## ``cliArg*``, …) need distinct C symbol names. The macro maintains a
## per-name compile-time counter so the N-th occurrence of
## ``{.dynOrStatic.} proc foo*(…)`` is exported / imported under the
## C name ``reproDsl_foo_<N>``. Because both the DLL build and the
## dynamic-stub compile process the same include files in the same
## order, the counter values match across builds and the names line
## up.
##
## Procs called by macros at compile time (``stableHashHex``,
## ``parsePackageDef``, …) are file-local (no ``*``) and are not
## annotated with this pragma. They stay statically compiled and are
## visible to the macro VM in both modes via the existing umbrella
## ``include``s.
##
## See ``reprobuild-specs/Provider-Compile-Tiering.md`` for the
## broader design.

import std/[macros, tables]

# Path passed to Nim's ``{.dynlib.}`` consumer. Nim's loader passes
# this string verbatim to ``dlopen``/``LoadLibrary``, so we must
# expand the ``lib`` prefix + platform extension ourselves to match
# the artifact produced by ``scripts/build_apps.sh``
# (``build/lib/librepro_project_dsl_runtime.{dll,so,dylib}``).
#
# When the engine has a known absolute DLL location (set via
# ``--define:reproProviderDynamicLibPath=<abs>`` from
# ``providerCompileCommand`` in ``repro_interface_artifacts``), prefer
# the absolute path so the provider binary is self-locating even when
# launched from a deep CMake ``TryCompile`` scratch dir whose Windows
# DLL search order would not otherwise find the DLL. Falling back to
# the bare basename keeps the legacy ``LD_LIBRARY_PATH`` / ``PATH``
# discovery path open for hand-launched providers.
const reproProviderDynamicLib* {.strdefine: "reproProviderDynamicLibPath".} =
  when defined(windows):    "librepro_project_dsl_runtime.dll"
  elif defined(macosx):     "librepro_project_dsl_runtime.dylib"
  else:                     "librepro_project_dsl_runtime.so"

var dynOrStaticCounters* {.compileTime.}: Table[string, int]
  ## Per-proc-name counter used to disambiguate overloaded procs in
  ## the generated C symbol names. Each call to the ``dynOrStatic``
  ## macro increments the counter for that proc's bare name.

proc dynOrStaticCName*(name: string; index: int): string {.compileTime.} =
  ## C-symbol name minted for the ``index``-th occurrence of a proc
  ## named ``name`` annotated with ``{.dynOrStatic.}``. Exported so
  ## the macro itself and the DLL entry point can derive the same
  ## name when needed.
  "reproDsl_" & name & "_" & $index

macro dynOrStatic*(body: untyped): untyped =
  ## Attach to a public proc declaration whose body should live in
  ## the shared DSL runtime DLL when the per-project provider is
  ## compiled with ``-d:reproProviderDynamic``, and inline otherwise.
  ## See the module-level doc comment for the three modes.
  expectKind(body, RoutineNodes)
  let nameNode = body[0]
  var bareName: string
  case nameNode.kind
  of nnkPostfix:
    bareName = $nameNode[1]
  of nnkIdent, nnkSym:
    bareName = $nameNode
  else:
    bareName = nameNode.repr
  let prevCount =
    if dynOrStaticCounters.hasKey(bareName): dynOrStaticCounters[bareName]
    else: 0
  dynOrStaticCounters[bareName] = prevCount + 1
  let cname = dynOrStaticCName(bareName, prevCount)
  result = body
  when defined(reproProviderRuntimeDll):
    # Building the shared DLL: keep the body, export the symbol under
    # the deterministic overload-disambiguated C name.
    result.addPragma(newColonExpr(ident"exportc", newStrLitNode(cname)))
    result.addPragma(ident"dynlib")
  elif defined(reproProviderDynamic):
    # Static stub in dynamic mode: drop the body, link to the DLL.
    result[6] = newNimNode(nnkDiscardStmt).add(newEmptyNode())
    result.addPragma(newColonExpr(ident"importc", newStrLitNode(cname)))
    result.addPragma(newColonExpr(
      ident"dynlib", newStrLitNode(reproProviderDynamicLib)))
  else:
    discard
