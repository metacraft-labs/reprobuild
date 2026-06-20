## ct_test_nim_unittest — Nim unittest adapter for the codetracer
## test framework.
##
## Exports:
##
## * ``NimUnittestBinary`` — the typed handle for a built Nim
##   ``unittest`` test binary. Carries the binary path so UFCS dispatch
##   procs like ``handle.run(...)`` can route the path into
##   execution-edge input sets.
##
## * ``buildNimUnittest.build(...)`` — a reprobuild typed-tool that
##   compiles a Nim unittest test binary. Spec-Implementation M4 reshaped
##   this surface: instead of relying on the temporary engine-side shim
##   that translated ``ct_test_nim_unittest.buildNimUnittest`` into a
##   ``nim c`` action by hand (the ``lowerGraphAction`` block at
##   ``libs/repro_cli_support/src/repro_cli_support.nim`` ~line 1295),
##   the wrapper now records a ``PublicCliCall`` against the ``nim``
##   profile directly (``executableName = "nim"`` / ``subcommand = "c"``)
##   so the engine's normal typed-tool wrapper machinery resolves the
##   action through the ``nim`` profile and produces the exact same
##   ``nim c <flags> <source>`` argv the shim was synthesising. The
##   ``--out:`` / ``-d:`` / ``--import:`` / ``--threads:on`` /
##   ``--hints:off`` / ``--warnings:off`` aliases mirror the long-standing
##   ``nim.c`` typed-tool wrapper at
##   ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/nim.nim``.
##
##   The wrapper returns a per-call ``BuildEdge`` subtype carrying
##   ``action: BuildActionDef`` and ``testBinary: NimUnittestBinary`` so
##   the call-site contract (``edge.action`` accumulation into a
##   ``collect("test", ...)`` aggregator; ``edge.testBinary.run(...)``
##   for UFCS dispatch) is preserved byte-for-byte against the
##   pre-M4 shim shape.
##
## * ``run(self: NimUnittestBinary; ...)``,
##   ``runTest(self: NimUnittestBinary; ...)``,
##   ``list(self: NimUnittestBinary; ...)`` — UFCS dispatch procs that
##   emit execution edges. The boilerplate shape matches what a
##   follow-on auto-generation milestone will eventually emit from a
##   CLI-only ``executable NimUnittestBinary`` declaration; today the
##   procs are hand-authored.
##
## Standalone usage (no reprobuild edge emission) still works for the
## bare type — a user can construct ``NimUnittestBinary(path: "...")``
## directly and invoke the binary by any conventional means.
##
## See ``ct_test_runner_adapter`` (the sibling library landed in M4)
## for the ``TestRunner`` cross-cutting interface implementation that
## handles RUN/LIST/ENUMERATE at engine execution time.

import ct_test_interface
export ct_test_interface

import repro_project_dsl
export repro_project_dsl

const NimUnittestToolId* = "ct_test_nim_unittest.buildNimUnittest"
  ## Stable identity string preserved from the pre-M4 shim shape so the
  ## ``repro why`` / explainer surfaces keep matching ``provider:`` lines
  ## back to this adapter. The reach of the literal narrowed in M4 — it
  ## is now used only for adapter identification and for the
  ## implicit-target-export rows; the recorded ``PublicCliCall`` uses
  ## ``executableName = "nim"`` so the engine's normal typed-tool
  ## resolution path drives the compile.

type
  NimUnittestBinary* = object
    ## Typed handle for a Nim ``unittest`` test binary. Carries the
    ## binary path so UFCS method calls like ``handle.run(...)`` can
    ## route the path into execution-edge input sets.
    path*: string

  BuildNimUnittest* = object
    ## Namespace value for ``buildNimUnittest.build(...)``. The empty
    ## object exists so the call shape ``buildNimUnittest.build(...)``
    ## remains a valid Nim expression — Nim's UFCS dispatches
    ## ``buildNimUnittest.build(arg)`` as ``build(buildNimUnittest, arg)``.

  BuildNimUnittestBuildEdge* = object
    ## Per-call ``BuildEdge`` subtype returned by
    ## ``buildNimUnittest.build``. Carries the embedded
    ## ``action: BuildActionDef`` so call sites that accumulate edges
    ## into a ``seq[BuildActionDef]`` keep compiling unchanged, and
    ## the typed ``testBinary: NimUnittestBinary`` field so UFCS calls
    ## like ``edge.testBinary.run(...)`` continue to work.
    action*: BuildActionDef
    testBinary*: NimUnittestBinary

const buildNimUnittest* = BuildNimUnittest()
  ## The namespace value. Reprobuild project files write
  ## ``buildNimUnittest.build(source = ..., binary = ..., defines = ...)``
  ## to record a build edge; that call expands via Nim UFCS to the
  ## ``build(tool, ...)`` proc declared below.

proc build*(tool: BuildNimUnittest;
            source: string;
            binary: string;
            defines: seq[string] = @[];
            imports: seq[string] = @[];
            extraPassC: seq[string] = @[];
            extraPassL: seq[string] = @[];
            threadsOn = true;
            hintsOff = true;
            warningsOff = true;
            actionId = "";
            deps: openArray[string] = [];
            after: openArray[BuildActionDef] = [];
            extraInputs: openArray[string] = [];
            extraOutputs: openArray[string] = [];
            depfile = "";
            cacheable = true;
            actionCachePolicy = defaultActionCachePolicy();
            commandStatsId = ""): BuildNimUnittestBuildEdge {.discardable.} =
  ## M4 rewrite of the pre-M4 ``defineCliInterface buildNimUnittest`` /
  ## engine-shim pair. Records a ``PublicCliCall`` against the ``nim``
  ## profile (``executableName = "nim"``, ``subcommand = "c"``) so the
  ## engine's normal ``lowerGraphAction`` path resolves the action
  ## through the standard ``nim`` profile and ``argvForCall`` produces
  ## the exact same argv shape the shim was building by hand:
  ##
  ##   ``<nim-binary> c [--threads:on] [--hints:off] [--warnings:off] \``
  ##   ``  [-d:<def>...] [--import:<m>...] --out:<binary> <source>``
  ##
  ## ``threadsOn`` / ``hintsOff`` / ``warningsOff`` default to ``true``
  ## because the pre-M4 callers in ``repro_tests.nim`` and the spec
  ## fixtures always pass them — keeping them on by default matches the
  ## existing build behaviour without forcing every call site to spell
  ## them out.
  discard tool

  var cliArgs: seq[PublicCliArg] = @[]

  # ``--threads:on`` / ``--hints:off`` / ``--warnings:off`` are encoded
  # as their `nim` profile counterparts so ``argvForCall`` emits them
  # exactly as the shim used to: a bare alias string, no separate value.
  if threadsOn:
    cliArgs.add(cliArg(name = "threadsOn", value = true,
      alias = "--threads:on"))
  if hintsOff:
    cliArgs.add(cliArg(name = "hintsOff", value = true,
      alias = "--hints:off"))
  if warningsOff:
    cliArgs.add(cliArg(name = "warningsOff", value = true,
      alias = "--warnings:off"))

  # ``defines`` and ``imports`` are repeated concat-form flags matching
  # the ``nim.c`` typed-tool surface (``-d:foo``, ``--import:bar``).
  if defines.len > 0:
    cliArgs.add(cliArgSeq(name = "defines", value = defines,
      alias = "-d:", format = cafConcat, repeated = true))
  if imports.len > 0:
    cliArgs.add(cliArgSeq(name = "imports", value = imports,
      alias = "--import:", format = cafConcat, repeated = true))

  # Bootstrap-And-Self-Build B4: ``extraPassC`` / ``extraPassL`` are
  # repeated concat-form flags that emit one ``--passC:<value>`` /
  # ``--passL:<value>`` per entry. These cover the macOS-arm64 HCR
  # workaround (``--passC:-fpatchable-function-entry=16,0`` +
  # ``--passL:-Wl,-segprot,__HCR,rwx,rwx``) that previously lived in
  # ``scripts/run_tests.sh`` as a direct ``nim c`` re-compile loop —
  # the typed-tool's ``defines:`` slot only carries ``-d:`` defines,
  # not arbitrary passC/passL. Surface matches the ``nim.c`` typed-
  # tool's ``passC`` / ``passL`` flags in
  # ``repro_dsl_stdlib/packages/nim.nim``.
  if extraPassC.len > 0:
    cliArgs.add(cliArgSeq(name = "extraPassC", value = extraPassC,
      alias = "--passC:", format = cafConcat, repeated = true))
  if extraPassL.len > 0:
    cliArgs.add(cliArgSeq(name = "extraPassL", value = extraPassL,
      alias = "--passL:", format = cafConcat, repeated = true))

  # ``binary`` is the output path. Nim's ``nim c`` flag is ``--out:`` in
  # concat form; tagging the arg with ``role = output`` makes the
  # engine register the path as a declared output and supplies the
  # implicit target name (mirrors ``nim.c``'s ``flag output``).
  cliArgs.add(outputArg(name = "output", value = binary,
    alias = "--out:", format = cafConcat))

  # ``source`` is the positional input to ``nim c``. ``role = input``
  # marks it for engine-side declared-input tracking just like
  # ``nim.c``'s ``pos source`` does.
  cliArgs.add(inputArg(name = "source", value = source,
    kind = cpkPositional, position = 0))

  let call = publicCliCall(
    packageName = "nim",
    executableName = "nim",
    subcommand = "c",
    providerEntrypointId = NimUnittestToolId & ".build",
    arguments = cliArgs)

  let selectedActionId =
    if actionId.len > 0: actionId
    else: defaultToolActionId(call)

  result.action = recordToolInvocation(
    selectedActionId, call,
    deps = combineActionDeps(deps, after),
    extraInputs = extraInputs,
    extraOutputs = extraOutputs,
    depfile = depfile,
    cacheable = cacheable,
    commandStatsId = commandStatsId,
    # Dependency-correctness: a test binary's compile reads far more than its
    # top-level ``source`` — every transitively imported Nim module
    # (``repro_test_support``, the libs under test, the stdlib) is pulled in
    # via ``--path``. ``declaredOnly`` tracked ONLY ``source``, so editing a
    # depended-on lib never invalidated the binary (its fingerprint was
    # unchanged) and ``repro build`` reported it up-to-date with a stale
    # binary — which then fed a stale test execute edge. ``automaticMonitor``
    # records every file the compile actually reads, so any input change
    # invalidates the binary and, transitively, its execute edge. Matches the
    # ``nim.c`` app/helper edges, which already declare ``automaticMonitor``.
    dependencyPolicy = automaticMonitorPolicy(),
    actionCachePolicy = actionCachePolicy)

  # Typed-Outputs M1 binding: populate ``edge.testBinary`` with a
  # ``NimUnittestBinary`` whose ``path`` is the resolved binary path so
  # UFCS dispatch (``edge.testBinary.run(...)``) reaches the run/list
  # procs below.
  result.testBinary = NimUnittestBinary(path: binary)
  appendRegisteredActionTypedOutput(
    result.action.id, "testBinary",
    @["NimUnittestBinary"], binary)

  # Named-Targets M1: compute the implicit target name from the output
  # path basename and stamp it onto the edge so ``repro why`` / the
  # explainer surface see the same name as the per-package
  # target-export table.
  let implicitNames = computeImplicitTargetNames(call, @["output"])
  if implicitNames.len > 0:
    setRegisteredActionTargetNames(result.action.id, implicitNames)
    registerImplicitTargetExports(result.action.id,
      NimUnittestToolId, implicitNames,
      "ct_test_nim_unittest.nim", 0)

proc run*(self: NimUnittestBinary; filter = "";
          actionId = ""; deps: openArray[string] = [];
          after: openArray[BuildActionDef] = [];
          requiredBinaries: openArray[string] = [];
          extraInputs: openArray[string] = [];
          cacheable = true;
          actionCachePolicy = defaultActionCachePolicy();
          registerImplicitName = true):
    BuildActionDef {.discardable.} =
  ## Emit one execution edge that runs the test binary. The bound
  ## ``self.path`` flows in as a synthesised ``binary`` input flag so
  ## the action cache keys on the binary content.
  ##
  ## ``requiredBinaries`` (Bootstrap-And-Self-Build B3): paths of
  ## additional executable artifacts the test subprocess depends on at
  ## runtime — e.g. ``./build/bin/repro`` for e2e tests that spawn the
  ## reprobuild CLI. Each entry is recorded as a typed input to the
  ## execute edge so the engine (a) builds the binary before the
  ## execute edge runs and (b) re-runs the execute edge when the
  ## binary's content changes. ``extraInputs`` is the generic escape
  ## hatch for any other file dependency.
  ##
  ## ``registerImplicitName`` (B3): when ``false`` the implicit-target-
  ## name registration is skipped. The two-edge shape introduced by B3
  ## emits BOTH a build edge and an execute edge per ``TestSpec``;
  ## both edges would otherwise compute the SAME implicit name (the
  ## binary basename) and the package's target-export table rejects
  ## the second registration with a ``duplicate implicit target name``
  ## diagnostic. Callers in reprobuild's ``build:`` block pass
  ## ``false`` and rely on the explicit ``actionId`` for the execute
  ## edge's selector. The default stays ``true`` so existing single-
  ## edge call sites (the Typed-Outputs M1 fixtures, ad-hoc one-off
  ## ``run`` calls) keep their implicit-name behaviour.
  var cliArgs: seq[PublicCliArg] = @[]
  cliArgs.add(inputArg("binary", self.path))
  if filter.len > 0:
    cliArgs.add(cliArg("filter", filter))
  let call = publicCliCall(NimUnittestToolId, NimUnittestToolId,
    "run", NimUnittestToolId & ".run", cliArgs)
  let selectedActionId =
    if actionId.len > 0: actionId
    else: defaultToolActionId(call)
  var allExtraInputs: seq[string] = @[]
  for path in requiredBinaries:
    if path.len > 0:
      allExtraInputs.add(path)
  for path in extraInputs:
    if path.len > 0:
      allExtraInputs.add(path)
  result = recordToolInvocation(selectedActionId, call,
    deps = combineActionDeps(deps, after),
    extraInputs = allExtraInputs,
    cacheable = cacheable,
    dependencyPolicy = automaticMonitorPolicy(),
    actionCachePolicy = actionCachePolicy)
  if registerImplicitName:
    let implicitNames = computeImplicitTargetNames(call, @["binary"])
    if implicitNames.len > 0:
      setRegisteredActionTargetNames(result.id, implicitNames)
      registerImplicitTargetExports(result.id,
        NimUnittestToolId, implicitNames,
        "ct_test_nim_unittest.nim", 0)

proc runTest*(self: NimUnittestBinary; testName: string;
              actionId = ""; deps: openArray[string] = [];
              after: openArray[BuildActionDef] = []): BuildActionDef
    {.discardable.} =
  ## Emit an execution edge that runs exactly one named test inside
  ## the binary. The ``testName`` is expected in the
  ## ``<suite>::<test>`` form per the codetracer parallel test
  ## framework spec.
  var cliArgs: seq[PublicCliArg] = @[]
  cliArgs.add(inputArg("binary", self.path))
  cliArgs.add(cliArg("run", testName))
  let call = publicCliCall(NimUnittestToolId, NimUnittestToolId,
    "runTest", NimUnittestToolId & ".runTest", cliArgs)
  let selectedActionId =
    if actionId.len > 0: actionId
    else: defaultToolActionId(call)
  result = recordToolInvocation(selectedActionId, call,
    deps = combineActionDeps(deps, after),
    dependencyPolicy = automaticMonitorPolicy())
  let implicitNames = computeImplicitTargetNames(call, @["binary"])
  if implicitNames.len > 0:
    setRegisteredActionTargetNames(result.id, implicitNames)
    registerImplicitTargetExports(result.id,
      NimUnittestToolId, implicitNames,
      "ct_test_nim_unittest.nim", 0)

proc list*(self: NimUnittestBinary;
           actionId = ""; deps: openArray[string] = [];
           after: openArray[BuildActionDef] = []): BuildActionDef
    {.discardable.} =
  ## Emit an enumeration edge that lists the binary's test cases.
  ## Reprobuild's action cache memoises this until the binary
  ## content changes.
  var cliArgs: seq[PublicCliArg] = @[]
  cliArgs.add(inputArg("binary", self.path))
  cliArgs.add(cliArg("list-json", true))
  let call = publicCliCall(NimUnittestToolId, NimUnittestToolId,
    "list", NimUnittestToolId & ".list", cliArgs)
  let selectedActionId =
    if actionId.len > 0: actionId
    else: defaultToolActionId(call)
  result = recordToolInvocation(selectedActionId, call,
    deps = combineActionDeps(deps, after),
    dependencyPolicy = automaticMonitorPolicy())
  let implicitNames = computeImplicitTargetNames(call, @["binary"])
  if implicitNames.len > 0:
    setRegisteredActionTargetNames(result.id, implicitNames)
    registerImplicitTargetExports(result.id,
      NimUnittestToolId, implicitNames,
      "ct_test_nim_unittest.nim", 0)
