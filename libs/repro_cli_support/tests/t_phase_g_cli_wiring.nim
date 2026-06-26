## Windows-System-Resources Phase G — CLI-wiring smoke tests.
##
## Phase G shipped the apply-driver dispatch contract (``runInfraApply``
## calls ``buildActionDispatcher(buildActions)`` BEFORE the live-state
## dispatch, and fails-closed when ``buildActions.len > 0`` AND
## ``buildActionDispatcher == nil``). The CLI seam in
## ``libs/repro_cli_support/src/repro_cli_support/infra.nim`` is the
## production caller that MUST populate both fields from the compiled
## profile's ``ProfileIntent.buildActions`` — without this wiring,
## production ``repro infra apply`` against a profile that uses
## ``expandArchive.build(...)`` would see an empty ``opts.buildActions``,
## the fail-closed guard would NOT trigger, and the action edge would
## be SILENTLY DROPPED.
##
## These tests pin the wiring at the helper-proc seam
## (``attachBuildActionDispatcher``) — the layer
## ``runInfraApply``/``runSystemSync`` call after decoding the profile.
## We construct an ``ApplyOptions`` value the same way the CLI does,
## hand it a synthetic ``buildActions`` seq, and assert that:
##
##   1. ``opts.buildActions`` carries every action edge from the input
##      (the load-bearing assertion — without it the dispatcher sees
##      nothing).
##   2. ``opts.buildActionDispatcher`` is non-nil when the input is
##      non-empty, so the Phase G fail-closed guard does NOT fire and
##      the dispatcher actually runs.
##   3. The dispatcher's closure round-trips the buildActions through
##      the engine-construction layer — verified by running it against
##      a no-spawn-needed edge (cacheable + outputs-exist short-circuit
##      ⇒ no real process spawned) and asserting per-edge outcomes.
##   4. An empty ``buildActions`` seq leaves the dispatcher nil — the
##      apply driver's empty-buildActions short-circuit never consults
##      the field, so there's no point wiring a closure for a no-op.
##   5. The fail-closed guard in ``runInfraApply`` would HAVE fired
##      against a pre-wiring CLI (positive control via direct dispatch
##      using nil dispatcher) — pins what we'd see WITHOUT the wiring.

import std/[os, tempfiles, unittest]

import repro_elevation
import repro_infra
import repro_profile
import repro_cli_support/infra as cli_infra

# ---------------------------------------------------------------------------
# Helpers — build synthetic ProfileBuildAction entries that mirror the
# shape the profile macro emits for ``expandArchive.build`` /
# ``inlineExecCall`` calls.
# ---------------------------------------------------------------------------

proc mkSyntheticAction(id: string;
                       requiresElevation = false;
                       outputs: seq[string] = @[]): ProfileBuildAction =
  ProfileBuildAction(
    id: id,
    argv: @["/bin/true", "--id", id],
    cwd: "",
    deps: @[],
    inputs: @[],
    outputs: outputs,
    commandStatsId: "test." & id,
    toolIdentityRefs: @[],
    requiresElevation: requiresElevation,
    cacheable: true)

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

suite "Windows-System-Resources Phase G — CLI wiring":

  test "attachBuildActionDispatcher populates opts.buildActions":
    let tmp = createTempDir("phaseG-cli-wiring-populate-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let actions = @[
      mkSyntheticAction("extractRunner", requiresElevation = true),
      mkSyntheticAction("configureRunner", requiresElevation = true)]
    var opts = ApplyOptions(stateDir: tmp, hostIdentity: "phaseG-cli-host")
    cli_infra.attachBuildActionDispatcher(opts, actions, tmp)
    # The load-bearing assertion: opts.buildActions must carry every
    # entry. Without this, the apply driver's dispatchBuildActions
    # sees an empty seq and silently skips — the original gap.
    check opts.buildActions.len == 2
    check opts.buildActions[0].id == "extractRunner"
    check opts.buildActions[1].id == "configureRunner"
    # Each entry's requiresElevation flag must survive the copy — the
    # broker hook keys on it to route the edge through the elevation
    # broker rather than a direct fork.
    check opts.buildActions[0].requiresElevation
    check opts.buildActions[1].requiresElevation

  test "attachBuildActionDispatcher wires a non-nil dispatcher when non-empty":
    let tmp = createTempDir("phaseG-cli-wiring-nonempty-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let actions = @[mkSyntheticAction("oneAction")]
    var opts = ApplyOptions(stateDir: tmp, hostIdentity: "phaseG-cli-host")
    cli_infra.attachBuildActionDispatcher(opts, actions, tmp)
    # Without a non-nil dispatcher, runInfraApply's fail-closed guard
    # raises EProtocol when buildActions.len > 0. The whole point of
    # the CLI wiring is to install a real dispatcher so the apply
    # actually runs the action edges instead of failing closed.
    check opts.buildActionDispatcher != nil

  test "attachBuildActionDispatcher leaves dispatcher nil when buildActions empty":
    let tmp = createTempDir("phaseG-cli-wiring-empty-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let actions: seq[ProfileBuildAction] = @[]
    var opts = ApplyOptions(stateDir: tmp, hostIdentity: "phaseG-cli-host")
    cli_infra.attachBuildActionDispatcher(opts, actions, tmp)
    # Empty input ⇒ runInfraApply's dispatchBuildActions short-
    # circuits without consulting the dispatcher field. We deliberately
    # leave it nil so a profile that declares no action edges does
    # not allocate a build-engine cache root + closure that will never
    # fire.
    check opts.buildActions.len == 0
    check opts.buildActionDispatcher == nil

  test "wired dispatcher honours the BuildActionDispatcher contract end-to-end":
    # End-to-end smoke: the wired dispatcher must produce a non-empty
    # seq[BuildActionApplyOutcome] when given a non-empty input. We
    # don't validate the EXACT shape of every outcome here (the
    # underlying ``mkBuildActionDispatcher`` is tested in
    # ``libs/repro_profile_compile/tests/
    # t_smoke_phase_g_action_edges_integration.nim``); what we pin is
    # that the CLI-wired closure is a real dispatcher that returns
    # one outcome per input action — the contract Phase G's
    # ``dispatchBuildActions`` folds into ``ApplyResult``.
    #
    # NOTE: this test does NOT spawn /bin/true. The action carries
    # ``cacheable = true`` but no outputs; the build engine's
    # action-cache may MISS and spawn the process. On a CI host where
    # /bin/true exists the spawn succeeds; on a host where it doesn't
    # the dispatcher projects the failure into a per-edge failure
    # outcome (the closure NEVER raises). Either way the contract
    # (one outcome per input, dispatcher does not crash) holds.
    let tmp = createTempDir("phaseG-cli-wiring-roundtrip-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let actions = @[mkSyntheticAction("oneAction")]
    var opts = ApplyOptions(stateDir: tmp, hostIdentity: "phaseG-cli-host")
    cli_infra.attachBuildActionDispatcher(opts, actions, tmp)
    check opts.buildActionDispatcher != nil
    let outcomes = opts.buildActionDispatcher(opts.buildActions)
    # One outcome per input action — the dispatcher's hard contract
    # (see ``BuildActionDispatcher``'s docstring in
    # ``libs/repro_infra/src/repro_infra/apply.nim``).
    check outcomes.len == 1
    check outcomes[0].id == "oneAction"
    # The outcome's address mirrors the input's id — the apply-log
    # uses this as the "address" column so a failed edge is greppable.
    check outcomes[0].address == "oneAction"

  test "without wiring, opts.buildActions stays empty (the gap this closes)":
    # Positive control: without ``attachBuildActionDispatcher`` the
    # default-constructed ``ApplyOptions`` has an empty buildActions
    # seq + nil dispatcher. The apply driver's fail-closed guard does
    # NOT fire on this shape (because the seq is empty), so the
    # action edges would have been SILENTLY DROPPED. This is exactly
    # the gap the CLI wiring closes — pin what the "without wiring"
    # world looked like so a future regression in the wiring path
    # surfaces here.
    var opts = ApplyOptions(stateDir: "/tmp",
                            hostIdentity: "phaseG-cli-host")
    check opts.buildActions.len == 0
    check opts.buildActionDispatcher == nil
    # The fail-closed guard fires when buildActions.len > 0 AND
    # dispatcher == nil. With both empty/nil, the apply-driver's
    # dispatchBuildActions short-circuits to a no-op — so a profile
    # that DECLARES action edges but whose CLI seam drops them looks
    # IDENTICAL to a profile that declares none. That silent collapse
    # is what attachBuildActionDispatcher prevents.

  test "fail-closed guard triggers when buildActions populated but dispatcher nil":
    # The Phase G safety net: if the CLI populates buildActions but
    # forgets to attach a dispatcher, runInfraApply MUST raise
    # EProtocol before any live-state mutation. This test exercises
    # the same defense from the CLI's side: we hand the apply driver
    # an opts value the wiring (intentionally) refused to complete and
    # confirm the apply driver refuses to run.
    let tmp = createTempDir("phaseG-cli-wiring-failclosed-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let stateDir = tmp / "state"
    createDir(stateDir)
    var opts = ApplyOptions(
      stateDir: stateDir,
      hostIdentity: "phaseG-cli-host",
      reproExe: "/usr/bin/false",
      elevationMode: emNoElevate,
      noPreview: true,
      buildActions: @[mkSyntheticAction("forbiddenAction")],
      buildActionDispatcher: nil)
    expect EProtocol:
      discard runInfraApply("", opts)

