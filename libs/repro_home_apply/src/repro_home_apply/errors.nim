## Typed exception hierarchy and structured diagnostic records for the
## M63 `repro home apply` activation pipeline.
##
## Every error must carry enough structured context for the CLI layer
## (M63's extension of `runHomeCommand`) and the gates' diagnostic
## assertions to identify which step failed, which package or file
## was implicated, and what the user can do about it. Silent
## fail-open is forbidden by the milestone contract.

type
  EHomeApply* = object of CatchableError
    ## Root of the apply pipeline exception hierarchy. The pipeline
    ## itself wraps every step in a `try/except` that converts lower-
    ## level diagnostics from the M55/M56/M57/M59/M62 libraries into
    ## one of the typed subclasses below; the gates assert specifically
    ## against those subclasses.
    step*: int
    stepName*: string

  EApplyIntentLoad* = object of EHomeApply
    ## Step 1: could not parse `home.nim` or its predicate modules.
    profilePath*: string

  EApplyConfigurableFinalize* = object of EHomeApply
    ## Step 2: configurable graph could not be resolved.
    configurableKey*: string

  EApplyGenerationIdCompute* = object of EHomeApply
    ## Step 3: the BLAKE3 derivation of the generation id failed —
    ## reserved; an internal invariant violation rather than a user
    ## error.

  EApplyPlanFailed* = object of EHomeApply
    ## Step 4-5: diff computation against the current generation
    ## raised. Distinct from realize/materialize so partial-recovery
    ## tests can tell the planning phase apart.

  EApplyRealizeFailed* = object of EHomeApply
    ## Step 7: a package's realization through Scoop / Nix / tarball
    ## raised. Carries the package id and the underlying adapter's
    ## error message verbatim.
    packageId*: string
    adapter*: string

  EApplyMaterializeFailed* = object of EHomeApply
    ## Step 8: a generated-file write or managed-block rewrite failed.
    absoluteOutputPath*: string

  EApplyLauncherFailed* = object of EHomeApply
    ## Step 9: a launch-plan materialization (Linux symlink, POSIX
    ## script, or Windows launcher copy + sidecar) failed.
    commandName*: string

  EApplyCurrentRotationFailed* = object of EHomeApply
    ## Step 10: rotating the `current` pointer (POSIX symlink) or the
    ## Windows stable bin dir failed. This is intentionally separate
    ## from `EApplyManifestCommit` because rotation is the only
    ## destination-of-no-return; gates pin the boundary.
    targetPath*: string

  EApplyManifestCommit* = object of EHomeApply
    ## Step 11: the activation manifest could not be sealed into the
    ## CAS or the pointer envelope could not be written.

  EApplyKilledByTestHook* = object of EHomeApply
    ## Raised by the `REPRO_TEST_APPLY_KILL_AFTER_STEP` injection
    ## hook used by gate 3. The pipeline does NOT clean up; the
    ## `apply.in-progress` marker stays so the next apply can quarantine
    ## the partial generation directory. The exception inherits from
    ## `EHomeApply` so the CLI layer surfaces it consistently, but
    ## the in-process apply rethrows it after the marker is written
    ## so the `repro home apply` command exits non-zero.
    killStep*: int

  EApplyHostUnsupported* = object of EHomeApply
    ## Raised when `--host <name>` is combined with `--now` on
    ## `enable` / `disable` — remote apply is deferred to M71.
    requestedHost*: string

  EApplyNoApplyOnApply* = object of EHomeApply
    ## Raised when `repro home apply --no-apply` is invoked: apply is
    ## the action; `--no-apply` belongs on intent-mutating commands.

  EResourceMove* = object of EHomeApply
    ## M68 Phase B: `repro home resource move <old> <new>` could not
    ## complete — e.g. there is no active generation to carry the
    ## binding forward from, or the active generation's pointer is
    ## missing. Distinct from `EUnknownResource` / `EResourceConflict`
    ## (which the resource layer raises for the move's own pre-checks).

  EHomePlanCyclicDependency* = object of EHomeApply
    ## M82 home-scope follow-up: the home planner's resource
    ## dependency graph contains a CYCLE — the apply order cannot be
    ## topologically determined. Causes:
    ##
    ##   * explicit `depends_on` edges that form a cycle in the
    ##     user's `home.nim` `resources:` block (e.g. A depends_on B;
    ##     B depends_on A);
    ##   * an explicit edge that closes a cycle with an implicit
    ##     producer -> consumer edge from
    ##     `home_producer_consumer_map.ProducerConsumerMap` (the home
    ##     table is empty today; the diagnostic plumbing is in place
    ##     so the first implicit-edge cycle is named correctly).
    ##
    ## `cyclePath` lists the resource ADDRESSES participating in the
    ## cycle, in traversal order with the first node repeated at the
    ## end (e.g. `@["A", "B", "C", "A"]`) so the operator can see
    ## exactly where the cycle closes. Parallels the system-scope
    ## `EPlanCyclicDependency` in `libs/repro_infra/`.
    cyclePath*: seq[string]

  EStowConflict* = object of EHomeApply
    ## M72 Deliverable 3: the stow materializer found a target that
    ## already exists as something OTHER than the correct symlink /
    ## junction to the stow source — a regular file, or a link to a
    ## DIFFERENT source. The materializer does NOT clobber it; the
    ## apply pipeline reports the conflict as drift and leaves the
    ## target byte-identical. `--reconcile-drift` / `--accept-overwrite`
    ## is required to replace it, per the home-scope drift contract.
    targetPath*: string
    existingKind*: string             ## "regular-file" | "symlink" |
                                      ## "junction"
    desiredSource*: string            ## the stow source the target
                                      ## should point at

# ---------------------------------------------------------------------------
# Warning / informational diagnostic records
# ---------------------------------------------------------------------------

type
  DiagnosticSeverity* = enum
    dsInfo = "info"
    dsWarning = "warning"

  StowDiagnosticCode* = enum
    ## Spec-named diagnostic codes for the M63 Phase B stow surface.
    sdIStowFellBack = "IStowFellBack"
    sdIStowLooseFile = "IStowLooseFile"
    sdWStowOverridesShadowed = "WStowOverridesShadowed"
    sdWStowAmbiguousSuppression = "WStowAmbiguousSuppression"

  StowDiagnostic* = object
    ## A single structured diagnostic emitted by the planner/materializer.
    severity*: DiagnosticSeverity
    code*: StowDiagnosticCode
    path*: string                       ## the `$HOME/<rel-path>` involved
    package*: string                    ## "" when not package-related
    relatedPackages*: seq[string]       ## for `WStowAmbiguousSuppression`
    deadConfigKeys*: seq[string]        ## for `WStowOverridesShadowed`
    fallbackFrom*: string               ## "symlink" | "junction" — for IStowFellBack
    fallbackTo*: string                 ## "junction" | "copy"   — for IStowFellBack
    message*: string                    ## human-readable rendering

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc raiseIntentLoad*(profilePath, msg: string) {.noreturn.} =
  var e = newException(EApplyIntentLoad,
    "repro home apply: step 1 (load intent) failed for " & profilePath &
    ": " & msg)
  e.step = 1
  e.stepName = "load_intent"
  e.profilePath = profilePath
  raise e

proc raiseConfigurableFinalize*(key, msg: string) {.noreturn.} =
  var e = newException(EApplyConfigurableFinalize,
    "repro home apply: step 2 (finalize configurables) failed for " &
    key & ": " & msg)
  e.step = 2
  e.stepName = "finalize_configurables"
  e.configurableKey = key
  raise e

proc raisePlanFailed*(msg: string) {.noreturn.} =
  var e = newException(EApplyPlanFailed,
    "repro home apply: step 5 (plan) failed: " & msg)
  e.step = 5
  e.stepName = "plan"
  raise e

proc raiseRealizeFailed*(packageId, adapter, msg: string) {.noreturn.} =
  var e = newException(EApplyRealizeFailed,
    "repro home apply: step 7 (realize) failed for package " & packageId &
    " via adapter '" & adapter & "': " & msg)
  e.step = 7
  e.stepName = "realize"
  e.packageId = packageId
  e.adapter = adapter
  raise e

proc raiseMaterializeFailed*(absoluteOutputPath, msg: string) {.noreturn.} =
  var e = newException(EApplyMaterializeFailed,
    "repro home apply: step 8 (materialize) failed for " &
    absoluteOutputPath & ": " & msg)
  e.step = 8
  e.stepName = "materialize"
  e.absoluteOutputPath = absoluteOutputPath
  raise e

proc raiseLauncherFailed*(commandName, msg: string) {.noreturn.} =
  var e = newException(EApplyLauncherFailed,
    "repro home apply: step 9 (launcher) failed for command '" &
    commandName & "': " & msg)
  e.step = 9
  e.stepName = "launchers"
  e.commandName = commandName
  raise e

proc raiseCurrentRotationFailed*(targetPath, msg: string) {.noreturn.} =
  var e = newException(EApplyCurrentRotationFailed,
    "repro home apply: step 10 (rotate current) failed for target " &
    targetPath & ": " & msg)
  e.step = 10
  e.stepName = "rotate_current"
  e.targetPath = targetPath
  raise e

proc raiseManifestCommit*(msg: string) {.noreturn.} =
  var e = newException(EApplyManifestCommit,
    "repro home apply: step 11 (commit manifest) failed: " & msg)
  e.step = 11
  e.stepName = "commit_manifest"
  raise e

proc raiseKilledByTestHook*(stepNumber: int) {.noreturn.} =
  var e = newException(EApplyKilledByTestHook,
    "repro home apply: aborted after step " & $stepNumber &
    " by REPRO_TEST_APPLY_KILL_AFTER_STEP test hook")
  e.step = stepNumber
  e.stepName = "test_kill_hook"
  e.killStep = stepNumber
  raise e

proc raiseHostUnsupported*(host: string) {.noreturn.} =
  var e = newException(EApplyHostUnsupported,
    "repro home: --host '" & host & "' combined with --now requests " &
    "remote apply, which is deferred to M71. Run the command on '" &
    host & "' directly, or omit --host to apply locally.")
  e.requestedHost = host
  raise e

proc raiseNoApplyOnApply*() {.noreturn.} =
  var e = newException(EApplyNoApplyOnApply,
    "repro home apply: --no-apply is meaningless on this subcommand " &
    "(apply IS the action). --no-apply belongs on intent-mutating " &
    "commands (add, remove, enable, disable).")
  raise e

proc raiseResourceMove*(msg: string) {.noreturn.} =
  var e = newException(EResourceMove, msg)
  e.step = 0
  e.stepName = "resource_move"
  raise e

proc raiseHomePlanCyclicDependency*(cyclePath: seq[string]) {.noreturn.} =
  ## Raise the M82 home-scope "the dependency graph has a cycle" error.
  ## `cyclePath` is the cycle's nodes (resource addresses) in traversal
  ## order with the first node repeated at the end so the diagnostic
  ## shows the closing edge. Parallels the system-scope
  ## `raisePlanCyclicDependency` in `libs/repro_infra/`.
  var arrow = ""
  for i, node in cyclePath:
    if i > 0: arrow.add(" -> ")
    arrow.add(node)
  var e = newException(EHomePlanCyclicDependency,
    "repro home apply: resource dependency graph has a cycle: " & arrow &
    " (refusing to plan — edit `depends_on` so the graph is acyclic).")
  e.step = 4
  e.stepName = "plan"
  e.cyclePath = cyclePath
  raise e

proc raiseStowConflict*(targetPath, existingKind, desiredSource: string)
    {.noreturn.} =
  ## M72 Deliverable 3: a stow target pre-exists as something other
  ## than the correct link. The materializer leaves the target
  ## byte-identical; the apply must surface this as drift.
  var e = newException(EStowConflict,
    "repro home apply: step 8 (stow materialization) refused to " &
    "clobber pre-existing target '" & targetPath & "' (existing kind: " &
    existingKind & "). It is NOT the correct stow link for source '" &
    desiredSource & "'. The target was left byte-identical. Pass " &
    "--reconcile-drift / --accept-overwrite to replace it (the prior " &
    "content is recorded so rollback can restore it).")
  e.step = 8
  e.stepName = "stow_materialization"
  e.targetPath = targetPath
  e.existingKind = existingKind
  e.desiredSource = desiredSource
  raise e
