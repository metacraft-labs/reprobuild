## ``python_unittest`` — Python ``unittest``-style test adapter for the
## reprobuild typed-tool DSL.
##
## Bootstrap-And-Self-Build B4: this wrapper closes the last special-
## case in ``scripts/run_tests.sh`` (the Python loop at line ~190) by
## letting Python test files participate in the engine's graph as
## ordinary execute edges. Each ``pythonUnittest.run(source = ...)``
## call records a ``PublicCliCall`` against the ``python3`` profile so
## the engine's normal tool-resolution path drives the execution. The
## evidence shape matches ``buildNimUnittest.run``: exit code 0 = pass,
## non-zero = fail.
##
## Standalone usage (``python_unittest.run(...)`` outside a reprobuild
## ``build:`` block) still works for fixtures + ad-hoc scripts — the
## bare type is a value type with no required environment.
##
## Known limitation (carried from the B3 outcome): the path-mode tool
## resolver doesn't yet ship a profile for either
## ``ct_test_nim_unittest.buildNimUnittest`` or this wrapper, so
## execute-edge materialisation through the engine SKIPs with a
## classifier in the B4 integration tests. The structural arms PASS
## independently and assert the source-level migration intent.

import repro_project_dsl
export repro_project_dsl

const PythonUnittestToolId* = "python_unittest.run"
  ## Stable identity string used for diagnostic surfaces and for the
  ## implicit-target-export rows. Mirrors the
  ## ``ct_test_nim_unittest.NimUnittestToolId`` convention.

type
  PythonUnittest* = object
    ## Namespace value for ``pythonUnittest.run(...)``. The empty object
    ## exists so the call shape ``pythonUnittest.run(source = ...)``
    ## remains a valid Nim expression — Nim's UFCS dispatches the call
    ## as ``run(pythonUnittest, source = ...)``.

const pythonUnittest* = PythonUnittest()
  ## The namespace value. Project files write
  ## ``pythonUnittest.run(source = "tests/.../test_*.py", actionId = ...)``
  ## to record a Python test execute edge.

proc run*(tool: PythonUnittest;
          source: string;
          actionId = "";
          deps: openArray[string] = [];
          after: openArray[BuildActionDef] = [];
          extraInputs: openArray[string] = [];
          cacheable = true;
          actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef {.discardable.} =
  ## Emit one execute edge that runs the given Python test file via
  ## ``python3 <source>``. The source path flows in as a typed input so
  ## the engine action-cache keys on the file's content; touching the
  ## test re-runs the execute edge.
  ##
  ## Evidence: the subprocess exit code (0 = pass, non-zero = fail) per
  ## the standard Tier-1 protocol. Per-test JSON output (e.g.
  ## ``unittest --json``) is a follow-on; today the wrapper relies on
  ## exit code + captured stdout/stderr in the build report.
  discard tool

  var cliArgs: seq[PublicCliArg] = @[]
  cliArgs.add(inputArg(name = "source", value = source,
    kind = cpkPositional, position = 0))

  let call = publicCliCall(
    packageName = "python3",
    executableName = "python3",
    subcommand = "",
    providerEntrypointId = PythonUnittestToolId,
    arguments = cliArgs)

  let selectedActionId =
    if actionId.len > 0: actionId
    else: defaultToolActionId(call)

  var allExtraInputs: seq[string] = @[]
  for path in extraInputs:
    if path.len > 0:
      allExtraInputs.add(path)

  result = recordToolInvocation(selectedActionId, call,
    deps = combineActionDeps(deps, after),
    extraInputs = allExtraInputs,
    cacheable = cacheable,
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    actionCachePolicy = actionCachePolicy)
