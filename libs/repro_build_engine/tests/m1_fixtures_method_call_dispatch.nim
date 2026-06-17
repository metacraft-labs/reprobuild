## Typed-Outputs M1 test fixture for
## ``t_engine_method_call_on_typed_field_emits_execution_edge``.
##
## Two typed-tool surfaces participate:
##
## * ``buildNimUnittest.build(...)`` — the *build* edge. Declares
##   ``outputs testBinary is NimUnittestBinary, binary`` so the M1
##   wrapper populates ``edge.testBinary.path`` at action emission.
##
## * ``NimUnittestBinary.run(self: NimUnittestBinary; filter)`` — the
##   *execution* edge. A manually-authored typed-tool wrapper
##   (matching the shape ``defineCliInterface`` / a future
##   ``executable`` migration would generate) reads ``self.path`` and
##   passes it as a synthesised ``binary`` input flag so the action
##   cache keys on the binary content.
##
## The consumer package's ``build:`` body calls the build edge once
## and then chains a UFCS ``edge.testBinary.run(filter = "case_x")``
## call. The test asserts the resulting fragment contains both edges.

import repro_project_dsl

type NimUnittestBinary* = object
  ## Typed handle. Carries the bound binary path so UFCS method calls
  ## like ``edge.testBinary.run(...)`` can route the path into the
  ## execution edge's input set.
  path*: string

defineCliInterface buildNimUnittest, "test-buildNimUnittest-method":
  subcmd "build":
    flag source is string,
      role = input,
      required = true
    flag binary is string,
      role = output,
      required = true
    outputs testBinary is NimUnittestBinary, binary

proc run*(self: NimUnittestBinary; filter = "";
         actionId = ""; deps: openArray[string] = [];
         after: openArray[BuildActionDef] = []): BuildActionDef
    {.discardable.} =
  ## Typed-Outputs M1 manual wrapper: emits one execution edge whose
  ## inputs include ``self.path`` (the bound binary) so the action
  ## cache keys on the binary content. The wrapper takes the typed
  ## handle as its first parameter so UFCS dispatch fires when the
  ## consumer writes ``edge.testBinary.run(filter = ...)``.
  ##
  ## Mirrors what a follow-on ``executable`` migration would generate
  ## automatically. The body matches the ``recordToolInvocation`` shape
  ## the package-block wrapper code produces.
  var cliArgs: seq[PublicCliArg] = @[]
  cliArgs.add(inputArg("binary", self.path))
  if filter.len > 0:
    cliArgs.add(cliArg("filter", filter))
  let call = publicCliCall("test-buildNimUnittest-method",
    "test-buildNimUnittest-method", "run",
    "test-buildNimUnittest-method.run", cliArgs)
  let selectedActionId =
    if actionId.len > 0: actionId
    else: defaultToolActionId(call)
  result = recordToolInvocation(selectedActionId, call,
    deps = combineActionDeps(deps, after),
    dependencyPolicy = automaticMonitorPolicy())
  # Named-Targets M1 wiring: surface the implicit name (the binary
  # basename) on the export table so the new edge is selectable by
  # name like every other typed-tool edge.
  let implicitNames = computeImplicitTargetNames(call, @["binary"])
  if implicitNames.len > 0:
    setRegisteredActionTargetNames(result.id, implicitNames)
    registerImplicitTargetExports(result.id,
      "test-buildNimUnittest-method", implicitNames,
      "m1_fixtures_method_call_dispatch.nim", 0)

package tEngineMethodCallTypedFieldPkg:
  uses:
    "nim >=2.2 <3.0"
  build:
    let edge = buildNimUnittest.build(source = "tests/foo.nim",
      binary = "build/test-bin/foo", actionId = "build-foo")
    discard edge.testBinary.run(filter = "case_x",
      actionId = "run-foo-case_x")

export buildNimUnittest
export NimUnittestBinary
export run
export buildTEngineMethodCallTypedFieldPkgPackage
