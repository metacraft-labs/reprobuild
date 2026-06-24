## Windows-System-Resources Phase E — CLI seam that wires the build
## engine's ``brokerSpawn`` hook to the privileged-operation broker.
##
## The build engine (``libs/repro_build_engine``) exposes
## ``BuildEngineConfig.brokerSpawn: ElevatedExecSpawner``. When non-nil
## the scheduler's pre-launch decision point delegates every
## ``requiresElevation = true`` edge to the closure instead of forking
## directly; when nil the engine FAILS CLOSED with a
## ``BuildEngineError`` (the spec-mandated fail-closed posture for any
## elevated edge that reaches an apply path without a broker hook
## attached).
##
## This module is the production caller that constructs the closure
## from a ``FixtureContext`` (the broker's per-apply context) and the
## elevation library's ``dispatchOperation`` entry point. The
## ``repro infra apply`` driver is the only seam that should attach
## this closure — the standalone ``repro build`` driver leaves
## ``brokerSpawn = nil`` so an inadvertent elevated edge surfaces with
## the spec-mandated diagnostic instead of silently spawning unprivileged.
##
## Shape:
##
##   1. The engine populates an ``ElevatedExecRequest`` from the edge's
##      argv + cwd + env at the pre-launch decision point.
##   2. ``mkInfraApplyBrokerSpawn`` returns a closure that builds a
##      matching ``pokInlineExecCall`` ``PrivilegedOperation``, wraps it
##      in a ``WireOperation`` (``PlannedOperation``) with an empty
##      baseline digest (``pokInlineExecCall`` is a one-shot spawn —
##      ``dispatchOperation`` short-circuits the observe / drift gate
##      for the kind, so the baseline is unused), and calls
##      ``dispatchOperation``.
##   3. The closure projects ``DispatchResult`` back into an
##      ``ElevatedExecResult``. Success: ``ok = true``, ``exitCode``
##      stays at the engine's default (``0``) because the inline-exec
##      driver only returns a ``DispatchResult`` with ``outcome =
##      doApplied`` when the exit code was in ``iecAcceptExitCodes`` —
##      a non-zero accepted exit code is rare but legitimate
##      (e.g. ``@[0, 3010]`` for the Windows "reboot required"
##      installer signal); the spawned-process exit code is not
##      threaded back through ``DispatchResult`` itself, so the engine
##      sees ``0`` for any accepted outcome. Failure: the
##      ``dispatchOperation`` call raises ``EProtocol`` (the inline-
##      exec driver's failure mode); the closure converts that into
##      ``ok = false`` + a non-zero exit code + the diagnostic, so the
##      engine projects the failure onto ``ActionResult.status =
##      asFailed`` instead of taking the cache-record success branch.
##
## Errors:
##   * Any ``CatchableError`` raised by ``dispatchOperation`` (the
##     ``EProtocol`` from a broker drift / driver failure / spawn-fail
##     / unaccepted-exit-code) is converted to a failure
##     ``ElevatedExecResult`` with the exception message in
##     ``diagnostic``. The build engine then surfaces that as a failed
##     action — this is the spec-mandated diagnostic-surface, NOT a
##     silent swallow (the failure is visible in ``ActionResult.stderr``
##     and the action graph short-circuits to a failed terminal).
##
## See ``libs/repro_build_engine/src/repro_build_engine.nim``
## §``ElevatedExecSpawner`` for the engine-side type and
## ``libs/repro_elevation/src/repro_elevation/dispatch.nim``
## §``dispatchOperation`` for the broker-side dispatch entry.

import repro_build_engine
import repro_elevation

# ---------------------------------------------------------------------------
# Public types + constructor.
# ---------------------------------------------------------------------------

const InfraApplyBrokerFailureExitCode* = 1
  ## The exit code surfaced in ``ElevatedExecResult.exitCode`` when the
  ## broker reported a non-success outcome (drift / driver failure / a
  ## ``dispatchOperation`` exception). Distinct from any exit code the
  ## elevated process itself returned: the engine only sees this value
  ## when the dispatch ITSELF failed (an unaccepted exit code from the
  ## spawned process surfaces as an ``EProtocol`` raised by the inline-
  ## exec driver, which lands here too).

proc elevatedExecRequestToPrivilegedOperation*(
    req: ElevatedExecRequest): PrivilegedOperation =
  ## Build the ``pokInlineExecCall`` ``PrivilegedOperation`` matching
  ## the engine-side ``ElevatedExecRequest``.
  ##
  ## Mapping (see ``repro_build_engine.ElevatedExecRequest`` /
  ## ``repro_elevation.operations.pokInlineExecCall``):
  ##
  ##   * ``actionId``  -> ``PrivilegedOperation.address`` so the audit
  ##                      log + the apply-log record can trace the
  ##                      dispatch back to the build edge.
  ##   * ``argv[0]``   -> ``iecExecutable``.
  ##   * ``argv[1..]`` -> ``iecArguments`` (literal ``@FILE:<path>``
  ##                      tokens preserved — the broker side re-expands
  ##                      them under elevation; the audit-log redaction
  ##                      lives downstream).
  ##   * ``cwd``       -> ``iecWorkingDirectory`` ("" means "broker's
  ##                      cwd at fork time").
  ##   * ``env``       -> ``iecEnvironment``.
  ##
  ## ``iecToolIdentityRefs`` is left empty here — the engine-side
  ## ``ElevatedExecRequest`` does not carry tool refs; the broker's
  ## PATH-prepend hook (when wired) reads the inherited environment
  ## directly. ``iecAcceptExitCodes`` defaults to ``@[0]`` to match the
  ## codec-boundary default — a profile that opts into a wider accept
  ## set will surface that through the broker's own protocol path, not
  ## through this engine-edge seam.
  ##
  ## An empty ``argv`` is not rejected here — the validator inside
  ## ``dispatchOperation`` raises ``EProtocol`` for that case, which
  ## the closure converts to a failure ``ElevatedExecResult``.
  if req.argv.len == 0:
    # An elevated edge with empty argv is a programming error on the
    # engine side; surface it with a structured PrivilegedOperation
    # (empty executable string) so the elevation-side validator
    # produces the canonical diagnostic instead of a confusing
    # `index out of bounds` raised from this proc.
    return PrivilegedOperation(kind: pokInlineExecCall,
      address: req.actionId,
      iecExecutable: "",
      iecArguments: @[],
      iecWorkingDirectory: req.cwd,
      iecEnvironment: req.env,
      iecToolIdentityRefs: @[],
      iecAcceptExitCodes: @[0])
  result = PrivilegedOperation(kind: pokInlineExecCall,
    address: req.actionId,
    iecExecutable: req.argv[0],
    iecArguments: req.argv[1 .. ^1],
    iecWorkingDirectory: req.cwd,
    iecEnvironment: req.env,
    iecToolIdentityRefs: @[],
    iecAcceptExitCodes: @[0])

proc dispatchResultToElevatedExecResult*(
    dr: DispatchResult): ElevatedExecResult =
  ## Project the broker's ``DispatchResult`` back into the engine's
  ## ``ElevatedExecResult`` shape.
  ##
  ## ``doApplied`` / ``doNoOp`` => success (the inline-exec driver only
  ## sets ``doApplied`` after the spawned process exited inside the
  ## accept set). The spawned process's verbatim exit code is not
  ## threaded through the dispatch frame, so the projected
  ## ``exitCode`` stays at ``0`` for an accepted outcome — matching
  ## the legacy direct-fork shape where an in-accept-set exit code
  ## maps to ``asSucceeded`` regardless of the numeric value.
  ##
  ## ``doDrift`` / ``doError`` => failure (``exitCode =
  ## InfraApplyBrokerFailureExitCode``, ``diagnostic`` carries the
  ## broker's ``detail``).
  case dr.outcome
  of doApplied, doNoOp:
    result = ElevatedExecResult(ok: true, exitCode: 0,
      stdout: "", stderr: "", diagnostic: dr.detail)
  of doDrift, doError:
    result = ElevatedExecResult(ok: false,
      exitCode: InfraApplyBrokerFailureExitCode,
      stdout: "", stderr: dr.detail, diagnostic: dr.detail)

proc mkInfraApplyBrokerSpawn*(ctx: FixtureContext): ElevatedExecSpawner =
  ## Build the closure ``repro infra apply`` attaches to
  ## ``BuildEngineConfig.brokerSpawn``. Each invocation translates an
  ## engine-side ``ElevatedExecRequest`` into a ``pokInlineExecCall``
  ## ``PrivilegedOperation``, dispatches it through
  ## ``repro_elevation.dispatchOperation`` (the already-elevated fast
  ## path: same dispatch the broker subprocess uses, no broker fork),
  ## and projects the ``DispatchResult`` back.
  ##
  ## ``ctx`` is the apply's ``FixtureContext`` — only the fixture
  ## drivers actually read it (``filePrefix`` for ``pokFixtureFile``);
  ## ``pokInlineExecCall`` does not read it but the parameter is kept
  ## so the same closure interface scales to the broker subprocess
  ## path (which threads a populated context through the dispatch
  ## loop).
  ##
  ## A ``CatchableError`` raised by ``dispatchOperation`` (the
  ## ``EProtocol`` an inline-exec failure produces) is caught here and
  ## projected onto a failure ``ElevatedExecResult`` so the engine
  ## sees a structured failure value rather than an exception
  ## bubbling out of the closure boundary. The build engine's wrapper
  ## already catches exceptions raised by ``brokerSpawn`` (see
  ## ``runBuild``'s ``except CatchableError`` around the call site),
  ## so swallowing here is purely a presentation choice: the engine
  ## records the failure through ``ActionResult.stderr`` either way,
  ## but a structured result keeps the diagnostic uniform with a
  ## broker-reported drift / error.
  let capturedCtx = ctx
  result = proc(req: ElevatedExecRequest):
      ElevatedExecResult {.gcsafe, closure.} =
    # ``dispatchOperation`` ends up calling ``runInlineExecCall`` for
    # the ``pokInlineExecCall`` branch, which goes through the
    # ``ArgFileReader`` indirect-call seam (typed reader injection).
    # The chain is flagged non-GC-safe by inference even though every
    # closure target in production reads from the local filesystem
    # under a synchronous primitive — there is no concurrent GC heap
    # access. The engine's ``ElevatedExecSpawner`` type pins
    # ``{.gcsafe.}`` so the broker hook is callable from worker
    # threads; we honour that with a ``cast(gcsafe)`` block here. The
    # scope of the cast is the whole body so any future helper added
    # below inherits the same constraint.
    {.cast(gcsafe).}:
      let op = elevatedExecRequestToPrivilegedOperation(req)
      let planned = PlannedOperation(operation: op, baselineDigestHex: "")
      var dr: DispatchResult
      try:
        dr = dispatchOperation(capturedCtx, planned)
      except CatchableError as err:
        return ElevatedExecResult(ok: false,
          exitCode: InfraApplyBrokerFailureExitCode,
          stdout: "",
          stderr: err.msg,
          diagnostic: "broker dispatch failed: " & err.msg)
      result = dispatchResultToElevatedExecResult(dr)
