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

import std/os
from std/strutils import endsWith, toHex

import ct_test_interface
export ct_test_interface

import repro_project_dsl
export repro_project_dsl
from repro_core/scratch_env import ScratchLocationEnvNames

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

proc nimUnittestExecutablePath*(binary: string;
                                windowsTarget = defined(windows)): string =
  ## The file a test binary declared as ``binary`` really is on disk, and
  ## therefore the path both of its edges must name.
  ##
  ## On Windows ``nim c --out:foo`` writes ``foo.exe``, and the io monitor
  ## starts the child with ``CreateProcessW`` given an explicit application
  ## path, which does NOT append ``.exe`` the way a ``PATH`` search would
  ## (https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw,
  ## ``lpApplicationName``: "The function will not use the search path ...
  ## you must specify the file name extension"). So the compile edge's
  ## declared output, the typed ``testBinary`` handle and every execute
  ## edge's ``binary`` input all go through this one helper: an execute edge
  ## naming the bare path launches a file that does not exist
  ## (``CreateProcessW failed (err=2)``), and because no edge declares that
  ## bare path as an output nothing orders the compile before it either.
  ## Same rule as ``nim.c``'s ``effectiveBinary``
  ## (``repro_dsl_stdlib/packages/nim.nim``).
  ##
  ## Idempotent, so a caller that already spelled ``foo.exe`` (or a handle
  ## built from this helper's result) is unchanged. ``windowsTarget`` is a
  ## parameter only so the Windows rule can be tested on any host; callers
  ## leave it at the default, the host the recipe is evaluated for.
  if windowsTarget and binary.len > 0 and not binary.endsWith(".exe"):
    binary & ".exe"
  else:
    binary

proc defaultNimcacheDir(binary: string): string =
  let outputName = splitFile(binary).name
  if outputName.len > 0:
    result = "build" / "nimcache" / outputName
  else:
    result = "build" / "nimcache" / "nim-unittest"

proc compileDependencyPolicy(cacheDir: string;
                             cacheable: bool;
                             policy: BuildActionDependencyPolicy):
    BuildActionDependencyPolicy =
  if policy.kind != bdpDefault:
    return policy
  if cacheable:
    return automaticMonitorPolicy()
  makeDepfilePolicy(cacheDir / "nim-compile.d")

proc build*(tool: BuildNimUnittest;
            source: string;
            binary: string;
            defines: seq[string] = @[];
            paths: seq[string] = @[];
            imports: seq[string] = @[];
            mm = "";
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
            nimcache = "";
            cacheable = true;
            dependencyPolicy = defaultDependencyPolicy();
            actionCachePolicy = defaultActionCachePolicy();
            commandStatsId = "";
            extraEnv: openArray[(string, string)] = [];
            typedTestBinary = true):
    BuildNimUnittestBuildEdge {.discardable.} =
  ## M4 rewrite of the pre-M4 ``defineCliInterface buildNimUnittest`` /
  ## engine-shim pair. Records a ``PublicCliCall`` against the ``nim``
  ## profile (``executableName = "nim"``, ``subcommand = "c"``) so the
  ## engine's normal ``lowerGraphAction`` path resolves the action
  ## through the standard ``nim`` profile and ``argvForCall`` produces
  ## the exact same argv shape the shim was building by hand:
  ##
  ##   ``<nim-binary> c [--threads:on] [--hints:off] [--warnings:off] \``
  ##   ``  [-d:<def>...] [--path:<dir>...] [--import:<m>...] [--mm:<mgr>] \``
  ##   ``  --out:<binary> <source>``
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
  # Every Nim edge drops the installation's `nimblepath` entries (Nimble's
  # `$home/.nimble` and `/opt/nimble`): a package reaches the compile only
  # as a `--path:` (Nimble-Package-Catalog NPC-AREQ22).
  cliArgs.add(cliArg(name = "noNimblePath", value = true,
    alias = "--noNimblePath"))

  # ``defines`` / ``paths`` / ``imports`` are repeated concat-form flags
  # matching the ``nim.c`` typed-tool surface (``-d:foo``, ``--path:dir``,
  # ``--import:bar``). ``paths`` maps to the ``nim`` profile's ``--path:``
  # flag (``libs/repro_dsl_stdlib/.../packages/nim.nim`` subcmd ``c``): a
  # test whose module search path is supplied by the repo's ``Justfile``
  # (``--path:src``) rather than a ``config.nims`` needs an explicit
  # ``--path:`` so ``nim c`` resolves the package's importable modules.
  if defines.len > 0:
    cliArgs.add(cliArgSeq(name = "defines", value = defines,
      alias = "-d:", format = cafConcat, repeated = true))
  if paths.len > 0:
    cliArgs.add(cliArgSeq(name = "paths", value = paths,
      alias = "--path:", format = cafConcat, repeated = true))
  if imports.len > 0:
    cliArgs.add(cliArgSeq(name = "imports", value = imports,
      alias = "--import:", format = cafConcat, repeated = true))

  # ``mm`` maps to the ``nim`` profile's single-valued concat-form
  # ``--mm:`` flag (``libs/repro_dsl_stdlib/.../packages/nim.nim`` subcmd
  # ``c`` — same flag the ``nim.c`` typed-tool exposes). A repo whose
  # ``Justfile`` pins a memory manager for its test matrix point
  # (e.g. nim-libvterm's default ``--mm:orc``) rather than relying on
  # Nim's per-file default needs to thread it through here so the
  # engine-driven compile matches the repo's own ``nim c`` invocation.
  if mm.len > 0:
    cliArgs.add(cliArg(name = "mm", value = mm,
      alias = "--mm:", format = cafConcat))

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

  let cacheDir = if nimcache.len > 0: nimcache else: defaultNimcacheDir(binary)
  cliArgs.add(cliArg(name = "nimcache", value = cacheDir,
    alias = "--nimcache:", format = cafConcat))

  # ``binary`` is the output path. Nim's ``nim c`` flag is ``--out:`` in
  # concat form; tagging the arg with ``role = output`` makes the
  # engine register the path as a declared output and supplies the
  # implicit target name (mirrors ``nim.c``'s ``flag output``).
  #
  # On Windows `nim c --out:foo` writes `foo.exe`, so the declared output
  # names the file nim really writes, as `nim.c` does
  # (repro_dsl_stdlib/packages/nim.nim, `effectiveBinary`): `--out:foo.exe`
  # produces exactly `foo.exe`. Declaring `foo` left the edge's one output
  # absent, which the engine fails for a cacheable action
  # (Build-Engine-And-Scheduler.md §"A declared output is an obligation").
  # The typed `testBinary` handle below carries this same path, so the
  # execute edges launch the file this edge produces. Only the nimcache
  # directory keeps keying on `binary`'s stem.
  let outputBinary = nimUnittestExecutablePath(binary)
  cliArgs.add(outputArg(name = "output", value = outputBinary,
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
    # Some self-hosted test graph compiles are deliberately non-cacheable
    # because the io-mon preload shim can perturb host C compilers. In that
    # case the caller may keep the compile fully executed while avoiding
    # monitor wrapping; no cache entry is published for the incomplete evidence.
    dependencyPolicy = compileDependencyPolicy(
      cacheDir, cacheable, dependencyPolicy),
    actionCachePolicy = actionCachePolicy,
    extraEnv = extraEnv)

  # The nimcache is nim's private derived state. Every file in it is written
  # by this edge, from inputs in its key, and nothing else reads it, so it is
  # declared as a directory the engine removes before the edge runs. Without
  # that declaration the monitor records each generated ``.c`` and ``.o`` as an
  # output the edge does not own, and a certificate's untracked-input rule
  # judges the edge's own read-back of those files as an untracked read.
  # ``removeBeforeRun`` is the declaration the certificate exempts (Test-
  # Certificates.md, "What is not an untracked read": a file under an output
  # the engine removes before such an action runs); the flag is the ``nimcache``
  # argument of the call, so the directory named here is the one nim writes.
  appendRegisteredActionRemoveBeforeRun(result.action.id, call, ["nimcache"])

  # Match the standard nim.c wrapper: Nim invokes its native C backend by
  # bare name. A package-level uses declaration alone is scoped away unless
  # the selected compile action references it. Keep the backend in the normal
  # tool-identity resolver so both its PATH and identity reach this edge;
  # undeclared selectors remain inert. No ambient compiler is substituted.
  let backendCompiler =
    when defined(macosx): "clang"
    else: "gcc"
  appendRegisteredActionToolIdentityRefs(result.action.id, [backendCompiler])

  # The same temp-directory passthrough the ``nim`` tool declares on its
  # ``c`` subcommand (``envPassthrough`` in the ``cli:`` block of
  # ``repro_dsl_stdlib/packages/nim``, which states the reason and the cost).
  # This edge is a ``nim c`` compile but is recorded here, through
  # ``recordToolInvocation``, not through the typed ``nim.c`` wrapper, so the
  # tool's declaration does not reach it and it names the list itself. Not
  # applied to the execute edges below: what a test does with its temp
  # directory is the test's business.
  appendRegisteredActionEnvPassthrough(result.action, ScratchLocationEnvNames)

  # Typed-Outputs M1 binding: populate ``edge.testBinary`` with a
  # ``NimUnittestBinary`` whose ``path`` is the resolved binary path so
  # UFCS dispatch (``edge.testBinary.run(...)``) reaches the run/list
  # procs below.
  #
  # ``typedTestBinary = false`` leaves the TYPED OUTPUT off the graph (the
  # handle is still returned). Test-Binary-Grouping M2 registers every
  # grouped source's own compile as a FALLBACK edge, built only when its
  # group fails to compile; a consumer that enumerates the graph's test
  # binaries by this type must not see those as a second copy of the group's
  # cases. (``repro test --shard`` was such a consumer; it now partitions the
  # selection's test commands instead, so nothing in this repository reads
  # the type today.)
  #
  # The handle carries the DECLARED OUTPUT (`<binary>.exe` on Windows), not
  # the spelling the caller passed: `run` / `runTest` / `list` turn
  # `self.path` into the program the execute edge launches and into the
  # input that orders this compile before it. Handing them the bare path
  # made a Windows execute edge launch a file no edge produces.
  result.testBinary = NimUnittestBinary(path: outputBinary)
  if typedTestBinary:
    appendRegisteredActionTypedOutput(
      result.action.id, "testBinary",
      @["NimUnittestBinary"], outputBinary)

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
          pool = "";
          poolUnits = 1'u32;
          cacheable = true;
          actionCachePolicy = defaultActionCachePolicy();
          registerImplicitName = true;
          extraEnv: openArray[(string, string)] = [];
          dependencyPolicy = automaticMonitorPolicy()):
    BuildActionDef {.discardable.} =
  ## Emit one execution edge that runs the test binary. The bound
  ## ``self.path`` flows in as a synthesised ``binary`` input flag so
  ## the action cache keys on the binary content. It is spelled through
  ## ``nimUnittestExecutablePath`` (``.exe`` on Windows), so a handle a
  ## caller built from the bare ``binary =`` path still launches the file
  ## the compile edge declares.
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
  ##
  ## ``dependencyPolicy`` selects how the engine gathers this edge's runtime
  ## inputs. The default, ``automaticMonitorPolicy()``, is the baseline for
  ## opaque tools: the engine wraps the command in ``repro internal io
  ## monitor``, which injects an ``LD_PRELOAD`` interposer to observe reads.
  ##
  ## A test that performs ``LD_PRELOAD`` interposition ITSELF cannot be
  ## observed that way — two interposers on the same libc entry points
  ## re-enter each other. Such a test passes ``makeDepfilePolicy(...)`` naming
  ## a depfile that describes its inputs, which resolves to a kind outside the
  ## engine's ``MonitorPolicyKinds``, so no wrap and no shim injection happen.
  ## A recorder-backed test can likewise require a subject free of the
  ## monitor's modified code and mutable mapped shards. Such a test must use
  ## ``cacheable = false`` when a generated depfile does not observe its
  ## complete runtime input closure.
  ## Where no step in the graph already emits such a file,
  ## ``fs.unmonitorableActionDepfile`` generates one as a graph output; read
  ## its docstring before reaching for it.
  ##
  ## This is NOT a way to skip dependency tracking. Declaring inputs
  ## statically and calling the action complete is a soundness hole that was
  ## removed from this codebase and must not return; see the note on
  ## ``dgDeclaredOnly`` in repro_core/dependency_gathering.nim.
  ##
  ## ``extraEnv`` declares environment variables ON THE EXECUTE EDGE.
  ##
  ## A test binary that reads an environment variable to decide whether to
  ## run an expensive layer has, until it is declared here, a behaviour the
  ## action cache cannot see. The variable still REACHES the binary — the
  ## launcher layers the action's environment over the inherited one, so an
  ## undeclared name is simply inherited — but it contributes nothing to the
  ## weak fingerprint, so a later build may replay a result computed under a
  ## different setting of it and report success. Declaring the variable fixes
  ## both halves: the declared value REPLACES whatever the caller exported,
  ## and ``keyedOnActionEnvironment`` mixes the (name, value) pair into the
  ## key, so the two settings are two different cache entries.
  ##
  ## The value must be a constant of the RECIPE. Reading the host with
  ## ``getEnv`` at graph-construction time does NOT work: the provider graph
  ## snapshot and the lowered-graph cache are both reused across invocations
  ## that differ only in the ambient environment, so the first build's value
  ## would be baked in. Give each setting its own edge instead.
  ##
  ## ``pool`` / ``poolUnits`` forward the execute edge into a named
  ## engine build pool (``recordToolInvocation`` → ``BuildAction.pool``;
  ## the engine's ``poolRunning`` capacity tracker sequences edges that
  ## share a pool). This is the reprobuild-native way to constrain the
  ## concurrency of resource-contending test binaries — e.g. pty /
  ## real-subprocess integration tests whose child fork+exec timing
  ## degrades under saturated CPU when the whole corpus runs in
  ## parallel. Assigning such tests a capacity-1 pool (declared once
  ## with ``buildPool("<name>", 1)`` in the project ``build:`` block)
  ## serialises them WITHOUT touching any test assertion — nothing is
  ## skipped or weakened, only scheduled. Defaults (``pool = ""``,
  ## ``poolUnits = 1``) preserve the prior unconstrained behaviour for
  ## every existing call site.
  var cliArgs: seq[PublicCliArg] = @[]
  cliArgs.add(inputArg("binary", nimUnittestExecutablePath(self.path)))
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
    pool = pool,
    poolUnits = poolUnits,
    cacheable = cacheable,
    dependencyPolicy = dependencyPolicy,
    actionCachePolicy = actionCachePolicy,
    extraEnv = extraEnv)
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
  cliArgs.add(inputArg("binary", nimUnittestExecutablePath(self.path)))
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
  cliArgs.add(inputArg("binary", nimUnittestExecutablePath(self.path)))
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

proc perTestIdPart(value: string): string =
  ## ``value`` with every character outside ``[A-Za-z0-9._-]`` replaced by
  ## ``_``, so a path can name an action and a file.
  for ch in value:
    result.add(if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}: ch
      else: '_')

proc perTestCompileEdge(binary: string): BuildActionDef =
  ## The recorded action that compiles ``binary``, for
  ## ``runPerTest(perTestBinaries = true)``: a ``nim c`` that declares it
  ## as an output (``buildNimUnittest.build``). Raises ``ValueError`` when
  ## there is none, or more than one.
  var found = 0
  for action in registeredBuildActions():
    if binary in action.outputs:
      inc found
      result = action
  if found != 1:
    raise newException(ValueError, "runPerTest(perTestBinaries = true): " &
      (if found == 0: "no recorded action" else: $found & " actions") &
      " declare " & binary & " as an output. Each test's binary is " &
      "compiled like the listed one, so record its compile " &
      "(buildNimUnittest.build) once, before runPerTest")
  if result.call.executableName != "nim" or result.call.subcommand != "c":
    raise newException(ValueError, "runPerTest(perTestBinaries = true): " &
      binary & " is produced by " & result.id & ", which is not a nim " &
      "compile (nim c); one binary per test needs nim-entrypoints' " &
      "-d:entrypointsTest=<name>")

proc runPerTest*(self: NimUnittestBinary;
                 actionId = "";
                 fragment = "";
                 producer = "";
                 perTestBinaries = false;
                 deps: openArray[string] = [];
                 after: openArray[BuildActionDef] = []): BuildActionDef
    {.discardable.} =
  ## The per-test form of ``run``: the build graph lists the binary's tests
  ## through its ``tests`` entry and runs, caches and reports each of them
  ## as an action of its own.
  ##
  ## The binary must answer nim-entrypoints' ``tests`` entry
  ## (https://github.com/metacraft-labs/nim-entrypoints). Either build it
  ## with nim-entrypoints: ``import entrypoints/tests``, ``testCase`` (or a
  ## ``tests:`` block), and a ``main:``, built with ``main`` (not
  ## ``-d:entrypoint=tests``), so that listing runs no test: in a tests-only
  ## build the ``tests:`` blocks run when the process starts, listing
  ## included. Or write its tests with ``ct_test_unittest_parallel``'s
  ## ``suite`` / ``test``, which answers the entry itself (in a program
  ## that also uses nim-entrypoints, put them in a ``tests:`` block).
  ##
  ## Two edges are recorded:
  ##
  ## * a LISTING edge, ``<actionId>.list``. It runs ``repro-tests-fragment``,
  ##   which asks ``<binary> --entrypoint=list`` whether the binary has the
  ##   ``tests`` entry, runs ``<binary> --entrypoint=tests --list`` and
  ##   writes, to
  ##   ``fragment``, a dynamic graph fragment with one ``create-action``
  ##   record per listed test: argv ``[<binary>, "--entrypoint=tests",
  ##   "--run-exact=<name>"]``, the binary as its input, the monitor as its
  ##   dependency policy, cacheable, and ``<binary>::<name>`` as its
  ##   ``commandStatsId``. The created action's id is
  ##   ``<actionId>.test.<name>`` (see ``ct_test_nim_unittest/tests_fragment``
  ##   for how a name is spelled in an id). The edge is monitored and keyed
  ##   on the binary, so an unchanged binary replays its fragment from the
  ##   cache.
  ## * a COLLECTOR edge, ``actionId``, which is returned. Its
  ##   ``dynamicDepsFile`` is the fragment, so the engine creates the
  ##   per-test actions when the collector is about to run, and the
  ##   fragment makes the collector depend on each of them. Put it where
  ##   ``run``'s edge would go (``collect("test", ...)``): building it runs
  ##   every test, each a cache entry of its own, and a failing test fails
  ##   its own action and blocks the collector.
  ##
  ## A test run is keyed as a declared execute edge is: its argv (which
  ## names the test), its input's content (the binary) and what the monitor
  ## saw it read. Every test of one binary shares that binary, so a change
  ## to any of them reruns all of them.
  ##
  ## The listing edge fails, and nothing runs, when the binary has entries
  ## but no ``tests`` entry, lists no tests, or lists a name twice (two tests
  ## with one name cannot be run one at a time). A binary with no entries at
  ## all (``--entrypoint=list`` exits 0 without an ``entrypoints/1``
  ## document: a plain ``std/unittest`` binary, say) is not listed: the
  ## fragment creates one run of the whole binary,
  ## ``<actionId>.whole-binary``, because its answer to ``--entrypoint=tests
  ## --list`` cannot be trusted to mean the entry (see
  ## ``ct_test_nim_unittest/tests_fragment``). One binary per test refuses
  ## such a binary.
  ##
  ## ONE BINARY PER TEST (``perTestBinaries = true``, an opt-in). The
  ## listing still comes from this binary, but every test is then compiled
  ## into a binary of its own and run from it: the fragment also creates a
  ## compile per test, ``<actionId>.compile.<name>``, which is this
  ## binary's compile (the recorded ``buildNimUnittest.build`` edge that
  ## declares it, as the engine lowers it) with nim-entrypoints'
  ## ``-d:entrypointsTest=<name>``, its own output
  ## (``<dir>/<stem>.per-test/<name>/<file>``) and its own nimcache. That
  ## define compiles the one ``testCase`` and expands every other to
  ## nothing, so the binary of a test whose code did not change comes out
  ## byte-identical, and its run, which checks its inputs by content when
  ## their metadata moved (the ``hybrid`` input-check policy), is a cache
  ## hit: changing one test reruns only that test. It costs a compile per
  ## test, and it covers ``testCase`` tests only: the listing edge fails,
  ## naming every listed test of a ``tests:`` block, before any compile is
  ## created.
  ## A test still reruns when an edit moves its lines, since its line
  ## numbers are in its binary. Record the compile before calling this.
  ##
  ## ``actionId`` defaults to ``tests-per-entry.<binary>`` (the binary's
  ## path with ``/`` and other punctuation spelled ``_``); ``fragment`` to
  ## ``build/tests-per-entry/<actionId>.rbdyn``. ``producer`` names the
  ## program the listing edge and the collector run, in place of the
  ## ``repro-tests-fragment`` installed beside ``repro``; it must take that
  ## program's arguments and write the same fragment.
  let binary = nimUnittestExecutablePath(self.path)
  let collectorId =
    if actionId.len > 0: actionId
    else: "tests-per-entry." & perTestIdPart(binary)
  let listingId = collectorId & ".list"
  let fragmentPath =
    if fragment.len > 0: fragment
    else: "build" / "tests-per-entry" / (perTestIdPart(collectorId) & ".rbdyn")

  var listArgs: seq[PublicCliArg] = @[]
  listArgs.add(inputArg("binary", binary))
  listArgs.add(outputArg(name = "fragment", value = fragmentPath))
  listArgs.add(cliArg("collector", collectorId))
  if producer.len > 0:
    listArgs.add(inputArg("producer", producer))
  if perTestBinaries:
    # The compile edge rides along as its payload (hex, so the call's
    # string slot carries any byte), and the engine lowers it exactly as it
    # lowers the edge itself; the listing edge is keyed on it too, so a
    # change to the compile's flags rekeys the listing.
    listArgs.add(cliArg("compileEdge",
      toHex(actionPayload(perTestCompileEdge(binary)))))
  let listCall = publicCliCall(NimUnittestToolId, NimUnittestToolId,
    "listTests", NimUnittestToolId & ".listTests", listArgs)
  let listing = recordToolInvocation(listingId, listCall,
    deps = combineActionDeps(deps, after),
    dependencyPolicy = automaticMonitorPolicy())

  var collectArgs: seq[PublicCliArg] = @[]
  collectArgs.add(inputArg("fragment", fragmentPath))
  if producer.len > 0:
    collectArgs.add(inputArg("producer", producer))
  let collectCall = publicCliCall(NimUnittestToolId, NimUnittestToolId,
    "collectTests", NimUnittestToolId & ".collectTests", collectArgs)
  result = buildAction(collectorId, collectCall,
    # The listing edge already waits for ``deps`` and ``after``.
    deps = [listing.id],
    inputs = [fragmentPath],
    dynamicDepsFile = fragmentPath,
    dependencyPolicy = automaticMonitorPolicy())
