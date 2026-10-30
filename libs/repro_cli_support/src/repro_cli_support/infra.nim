## `repro infra plan` / `repro infra apply` and `repro system audit`
## CLI surface (M69).
##
## Thin command layer over the `repro_infra` library. Per
## System-Profile-And-Infra-Apply.md:
##
##   * `repro infra plan` runs FULLY non-elevated / read-only and
##     produces an `RBIP` plan envelope; the plan output names the
##     privileged operations and states the single elevation prompt
##     is coming and why.
##   * `repro infra apply [<plan-id>]` re-checks plan staleness
##     (`EPlanStale`), then applies — through the M81 single broker
##     (one prompt), the already-elevated fast path (zero prompts),
##     or `--no-elevate` (privileged subset skipped).
##   * `repro system audit` reads the RBSL audit log of the current
##     (or a named) generation.
##
## M69 Phase A operates on a hand-authored `system.nim` profile; the
## `repro system add/remove/list/...` profile-editing family is
## deferred to a later phase.

import std/[options, os, strutils, times]

import repro_core/file_lock
import repro_core/host_apply_lock
import repro_elevation
import repro_infra
import repro_profile
import repro_profile_intent
import repro_profile_compile
import repro_profile_compile/binary_cache_build_actions as bc_actions
import repro_binary_cache_client
import repro_dsl_stdlib/packages_schema
import repro_cli_support/home as cli_home
import repro_cli_support/disk as cli_disk
import repro_cli_support/infra_install_root
import repro_cli_support/infra_host_registry
import repro_infra/addon_diagnostics
# Add-on mode owns Linux filesystem and ledger operations. Keep those imports
# out of the portable engine; ordinary system/infra commands still exist here.
when defined(linux):
  import repro_addon/addon_apply as addon_apply
  import repro_addon/cli as addon_cli
import repro_infra/host_base
import repro_infra/addon_diagnostics
from repro_home_intent/host_identity import selectHost, EHostIdentity
from repro_cli_support/self_spawn_image import selfSpawnIoMonitorPath

# ---------------------------------------------------------------------------
# M83 Phase D + F3: compile-then-adapt path for `system.nim` profiles.
#
# Phase F3 removed the legacy-parser auto-fallback. Profile compilation
# failure on the apply path is now a HARD ERROR with a uniform diagnostic
# (formatted via the shared `formatProfileCompileError` helper in
# `repro_cli_support/home`). The hand-rolled `parseSystemProfile` parser
# remains a library proc for the structural editor (`repro system
# add/remove/list/why`), which legitimately needs to read source text +
# edit it byte-for-byte preserving comments and formatting.
# ---------------------------------------------------------------------------

proc compileAndAdaptSystemProfile*(profilePath, stateDir: string;
    target: SystemPlanTarget = defaultSystemPlanTarget();
    declaredInputs: seq[string] = @[]):
    tuple[compiled: bool; text: string; cached: bool; compileError: string;
          adaptError: string; buildActions: seq[ProfileBuildAction];
          projection: Projection] =
  ## Run the Phase C build-engine edge against `profilePath`, decode
  ## the RBPI artifact, and render the adapted `SystemProfile` back
  ## into the canonical declarative text the M69 lib's APIs consume.
  ##
  ## `result.compiled` is the ONLY success signal, and it is set at
  ## exactly one place: after the decode + render completed without
  ## raising. Callers must branch on it.
  ##
  ## It is deliberately NOT inferable from `result.text`. A profile
  ## that compiles CLEANLY and declares no live-state resources — one
  ## whose `resources:` block holds only action edges
  ## (`inlineExecCall(...)`, `expandArchive.build(...)`) — renders to
  ## the EMPTY canonical text, because `renderSystemProfileToText`
  ## emits one block per resource and there are none. That is a
  ## legitimate desired state ("this host declares no live state; its
  ## work is the build-action half"), not a failure, and the apply
  ## path parses "" as zero resources and converges.
  ##
  ## On success: `result.text` is the canonical text and the caller
  ## passes it down to `runInfraApply(text, opts)`. On compile
  ## failure: `result.compiled` is false and `result.compileError`
  ## carries the diagnostic; apply-path callers propagate as a hard
  ## error via `formatProfileCompileError`.
  ##
  ## Windows-System-Resources Phase G + CLI-wiring: `result.buildActions`
  ## carries the profile's action-edge intent items (decoded from the
  ## RBPI envelope's ``ProfileIntent.buildActions`` seq). The apply
  ## path threads these into ``ApplyOptions.buildActions`` so the
  ## injected ``BuildActionDispatcher`` closure dispatches them through
  ## ``runBuild`` + the elevation broker hook. Profiles that declare no
  ## action edges leave this seq empty — the apply driver skips the
  ## dispatcher entirely when empty (see ``dispatchBuildActions``).
  ##
  ## `target` is the host being planned and what its host-registry entry
  ## selects (`infra_host_registry.systemPlanTargetFor`): runtime
  ## predicates are evaluated for it, its system activities select
  ## activity-scoped resources, and an add-on target projects every
  ## selected field through the `add-on-debian` realisation profile
  ## (`result.projection`). The default is the running machine with the
  ## `default` activity, realised in full -- a plan with no registry.
  ##
  ## A profile that compiles but that the system adapter refuses for this
  ## target (a home-scope resource, an undeclared activity, an
  ## `EAddOnOutOfScope` field) sets `result.adaptError` instead of
  ## `result.compileError`: the operator is told the profile cannot be used
  ## as a system profile for this host, not that it failed to compile.
  let opts = ProfileCompileOptions(
    stateDir: stateDir,
    # Guarded like every internal-verb spawn: the compile wraps its actions
    # in `<publicCliPath> internal io monitor` (`self_spawn_image`).
    publicCliPath: selfSpawnIoMonitorPath(),
    # Empty: `compileProfileToRbpi` resolves the sources through
    # `reprobuildRepoRoot()`, which honours `$REPROBUILD_REPO_ROOT` and the
    # installed package's `$REPROBUILD_SOURCE_ROOT` alike.
    repoRoot: "",
    workDir: profilePath.parentDir,
    verbose: false,
    forceRebuild: false,
    declaredInputs: declaredInputs)
  var intent: ProfileIntent
  try:
    let artifact = compileProfileToRbpi(profilePath, opts)
    intent = decodeRbpi(artifact.rbpiBytes)
  except ProfileCompileError as err:
    result.compileError = err.msg
    return
  except CatchableError as err:
    result.compileError = err.msg
    return
  try:
    let adapted = adaptSystemProfile(intent, target)
    result.text = renderSystemProfileToText(adapted.profile)
    result.projection = adapted.projection
  except CatchableError as err:
    result.adaptError = err.msg
    return
  result.buildActions = intent.buildActions
  result.compiled = true

proc resolveSystemProfileText*(profilePath: string;
                               originalText, stateDir,
                               commandName: string;
                               outText: var string;
                               planCommand = "";
                               outBuildActions: ptr seq[ProfileBuildAction] = nil;
                               target: SystemPlanTarget = defaultSystemPlanTarget();
                               declaredInputs: seq[string] = @[];
                               outProjection: ptr Projection = nil):
    bool =
  ## Drive the Phase F3 compile path for a `system.nim`. Sets `outText`
  ## to the canonical text rendered from the adapted profile when the
  ## compile path succeeds.
  ##
  ## Returns `false` (with a uniform actionable error already on
  ## stderr) when the compile failed; the caller exits non-zero. The
  ## `originalText` argument is retained for compatibility (callers
  ## still read the source for non-compile uses like drift previews)
  ## but is no longer consulted on a compile failure.
  ##
  ## Windows-System-Resources Phase G + CLI-wiring: when
  ## ``outBuildActions != nil`` the compiled profile's ``buildActions``
  ## seq is copied into the caller-supplied target so the apply driver
  ## can populate ``ApplyOptions.buildActions``. Callers that do not
  ## drive an apply (e.g. ``repro infra plan``) leave the pointer nil
  ## and the seq is discarded.
  ##
  ## SUCCESS IS `outcome.compiled`, NOT `outcome.text.len > 0`. Keying
  ## on the rendered text failed a profile that compiled cleanly but
  ## rendered no live-state resources — a `resources:` block holding
  ## only action edges renders to "" — and reported it as
  ## "profile compilation failed" with an EMPTY diagnostic, because
  ## there was no error to quote. Two things were wrong at once: a
  ## valid profile was refused, and the refusal named no cause. Both
  ## come from inferring failure from absent output instead of from an
  ## actual error.
  discard originalText  # retained for caller compatibility; see docstring
  let outcome = compileAndAdaptSystemProfile(profilePath, stateDir, target,
    declaredInputs)
  if outcome.compiled:
    outText = outcome.text
    if outBuildActions != nil:
      outBuildActions[] = outcome.buildActions
    if outProjection != nil:
      outProjection[] = outcome.projection
    return true
  if outcome.adaptError.len > 0:
    stderr.writeLine(commandName & ": " & profilePath & " compiled, but " &
      "cannot be used as a system profile\n" &
      "  diagnostic:\n" &
      "    " & outcome.adaptError.strip().replace("\n", "\n    "))
    return false
  # A compile failure with nothing to say is still a compile failure,
  # but the operator must not be handed a diagnostic-shaped blank. Say
  # so explicitly rather than printing an empty `diagnostic:` block.
  let diagnostic =
    if outcome.compileError.strip().len > 0: outcome.compileError
    else: "the profile compile failed without reporting a diagnostic"
  stderr.writeLine(cli_home.formatProfileCompileError(
    commandName, profilePath, diagnostic,
    planCommand = planCommand))
  false

# ---------------------------------------------------------------------------
# Windows-System-Resources Phase G + CLI-wiring: populate the apply
# options with the action-edge intent items + a build-action dispatcher
# closure that drives them through ``runBuild`` with the elevation
# broker hook attached. This is the production seam that connects the
# profile macro's action-edge output (Phase G) to ``runInfraApply``'s
# build-action dispatch step (Phase G's ``dispatchBuildActions``).
#
# Without this wiring, production ``repro infra apply`` against a
# profile that uses ``expandArchive.build(...)`` or bare
# ``inlineExecCall(...)`` inside its ``resources:`` block would see an
# empty ``opts.buildActions``, skip the dispatcher entirely, and
# silently DROP the action edge — the spec's "no silent fallback"
# posture explicitly forbids that.
# ---------------------------------------------------------------------------

proc attachBuildActionDispatcher*(opts: var ApplyOptions;
                                  buildActions: seq[ProfileBuildAction];
                                  stateDir: string) =
  ## Wire the Phase G + Phase E closures into ``opts``:
  ##
  ##   * ``opts.buildActions`` is copied from the compiled profile so
  ##     the apply driver's ``dispatchBuildActions`` step sees the
  ##     declared action edges.
  ##   * ``opts.buildActionDispatcher`` is constructed via
  ##     ``mkBuildActionDispatcher(cacheRoot, ctx)`` so a non-empty
  ##     ``buildActions`` seq actually flows through ``runBuild`` + the
  ##     ``mkInfraApplyBrokerSpawn(ctx)`` broker hook.
  ##
  ## ``stateDir`` is the apply's per-user state directory; the engine's
  ## action-cache + CAS for the action-edge half live under
  ## ``<stateDir>/<ApplyBuildActionsCacheDirName>``. Distinct from the
  ## profile-compile cache (``<stateDir>/profile-cache/``) so a cache
  ## sweep for one half doesn't perturb the other.
  ##
  ## ``FixtureContext.filePrefix = stateDir``: the inline-exec dispatch
  ## doesn't consume the context for ``pokInlineExecCall`` but the
  ## parameter is kept so the same dispatcher interface scales to the
  ## broker-subprocess path (which threads a populated context through
  ## the dispatch loop). Mirroring the test seam's pattern in
  ## ``libs/repro_profile_compile/tests/t_smoke_phase_g_action_edges_integration.nim``.
  opts.buildActions = buildActions
  if buildActions.len == 0:
    # Empty action-edge set: leave the dispatcher nil. The apply
    # driver's ``dispatchBuildActions`` short-circuits on an empty seq
    # and never consults the dispatcher field.
    return
  let cacheRoot = stateDir / ApplyBuildActionsCacheDirName
  let ctx = FixtureContext(filePrefix: stateDir)
  opts.buildActionDispatcher = mkBuildActionDispatcher(cacheRoot, ctx)

# ---------------------------------------------------------------------------
# Shared option parsing.
# ---------------------------------------------------------------------------

type
  InfraCliFlags* = object
    stateDir: string
    profilePath: string
    platformCpu*, platformOs*, platformAbi*, platformLibc*: string
    platformCpuGiven*, platformOsGiven*, platformAbiGiven*,
      platformLibcGiven*: bool
      ## `repro infra cache-keys --platform-*`: the platform of the host
      ## the keys are derived FOR. A flag that was not given keeps this
      ## host's value (`localPlatformTriple`), so a bare `cache-keys`
      ## prints what an apply here would look up; a flag that WAS given
      ## is taken as given, including an empty value, because a musl or
      ## unknown-libc host derives with `--platform-libc=` and nothing
      ## else can clear a host default.
    host: string
    hostGiven: bool
      ## `--host` was passed (even as `--host=`), so an empty value is
      ## refused rather than read as "no flag" (`selectHost`).
    homeProfileDir: string
      ## `--home-profile-dir`: the home profile whose `hosts:` registry says
      ## who manages each host's system (GM10, `infra_host_registry`).
      ## Default: the `home.nim` beside the system profile.
    planId: string
    generationId: string
    keepGenerations, keepDays: int
    keepGenerationsGiven, keepDaysGiven: bool
      ## `--keep-generations N` / `--keep-days D` on `repro infra apply`:
      ## an add-on host's generation retention (ReproOS Add-On Mode §5.2);
      ## refused on any other host, where they mean nothing.
    noElevate: bool
    noPreview: bool
    acceptFeatureDestroy: bool
    acceptPasswdDestroy: bool
    reconcileDrift: bool                  ## also set by `--accept-drift`
    forceUnlock: bool
      ## `--force-unlock`: the operator escape hatch for a wedged apply
      ## lock. Takes `<state-dir>/locks/apply.lock` regardless of who
      ## owns it, so a hung owner can be displaced deliberately instead
      ## of the operator deleting the lock file by hand. The displaced
      ## process is NOT terminated — see `repro_infra/apply_lock.nim`.
    acceptDrift: bool
      ## M82 Phase C: a plan-time flag. When the planner detects
      ## external drift since the previously-applied generation,
      ## passing this flag annotates the drift findings as accepted
      ## (the apply proceeds under M82 Phase A's live-state-refresh
      ## model in either case; the flag's effect is the annotation
      ## that the operator acknowledged the drift). `--reconcile-drift`
      ## is the spelling `repro system rollback` already accepts;
      ## under M82 Phase C the two are aliases at plan time so the
      ## same flag works across `repro infra plan` and rollback.

proc resolveInfraHost(flags: InfraCliFlags; command: string;
                      host: var string): bool =
  ## The host identity of one `repro infra` / `repro system` command, from
  ## the ONE resolver `repro home` uses (`host_identity.selectHost`:
  ## `$REPRO_HOST`, else `--host`, else the lower-cased OS hostname; a
  ## `--host` that `$REPRO_HOST` contradicts, or an empty `--host`, is
  ## refused). The same name keys the host registry (GM10) and is recorded in
  ## the plan and the generation, so the registry line and the `host` line of
  ## a report cannot disagree. False (after a diagnostic naming the command)
  ## when the host cannot be resolved; callers exit 2, as `repro home` does.
  try:
    host = selectHost(flags.host, flags.hostGiven).name
    true
  except EHostIdentity as err:
    stderr.writeLine(command & ": " & err.msg)
    false

proc recordedHostNote(stateDir, host: string): string =
  ## A note for the report when the CURRENT generation recorded a different
  ## host identity than this run resolves, or "" when it did not (or there is
  ## no readable current generation). The recorded identity is provenance,
  ## never a lookup key -- every generation stays listed and stays a rollback
  ## target whatever host it recorded -- so a change of identity (the
  ## pre-unification `localhost` / upper-case `%COMPUTERNAME%`, a renamed
  ## machine) is reported rather than refused (CLI/infra/README.md §Host
  ## identity).
  var current, recorded: string
  try:
    current = readCurrentGenerationId(stateDir)
    if current.len == 0:
      return ""
    recorded = readGenerationEnvelope(
      pointerPath(stateDir, current)).hostIdentity
  except CatchableError:
    # An unreadable current generation is reported by the commands that
    # need it (history, rollback); a note is not the place to fail.
    return ""
  if recorded == host:
    return ""
  "the current generation " & current & " recorded host '" & recorded &
    "'; this run is host '" & host & "' (earlier generations stay listed " &
    "and remain rollback targets)"

proc resolveProfilePath(flags: InfraCliFlags; stateDir: string): string =
  if flags.profilePath.len > 0:
    return flags.profilePath
  systemProfilePath(stateDir)

proc parseRetentionBound(flag, value: string): int =
  ## A retention bound: a non-negative integer (0 keeps only what is
  ## always kept).
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, flag & " expects a non-negative integer, got " & value)
  if result < 0:
    raise newException(ValueError, flag & " expects a non-negative integer, got " & value)

proc parseInfraFlags(args: openArray[string]):
    tuple[flags: InfraCliFlags; positional: seq[string]] =
  var i = 0
  while i < args.len:
    let a = args[i]
    template valueOf(): string =
      if i + 1 >= args.len:
        raise newException(ValueError, a & " requires a value")
      else:
        inc i
        args[i]
    if a == "--state-dir": result.flags.stateDir = valueOf()
    elif a.startsWith("--state-dir="):
      result.flags.stateDir = a["--state-dir=".len .. ^1]
    elif a == "--profile": result.flags.profilePath = valueOf()
    elif a.startsWith("--profile="):
      result.flags.profilePath = a["--profile=".len .. ^1]
    elif a == "--platform-cpu":
      result.flags.platformCpu = valueOf(); result.flags.platformCpuGiven = true
    elif a.startsWith("--platform-cpu="):
      result.flags.platformCpu = a["--platform-cpu=".len .. ^1]
      result.flags.platformCpuGiven = true
    elif a == "--platform-os":
      result.flags.platformOs = valueOf(); result.flags.platformOsGiven = true
    elif a.startsWith("--platform-os="):
      result.flags.platformOs = a["--platform-os=".len .. ^1]
      result.flags.platformOsGiven = true
    elif a == "--platform-abi":
      result.flags.platformAbi = valueOf(); result.flags.platformAbiGiven = true
    elif a.startsWith("--platform-abi="):
      result.flags.platformAbi = a["--platform-abi=".len .. ^1]
      result.flags.platformAbiGiven = true
    elif a == "--platform-libc":
      result.flags.platformLibc = valueOf(); result.flags.platformLibcGiven = true
    elif a.startsWith("--platform-libc="):
      result.flags.platformLibc = a["--platform-libc=".len .. ^1]
      result.flags.platformLibcGiven = true
    elif a == "--home-profile-dir": result.flags.homeProfileDir = valueOf()
    elif a.startsWith("--home-profile-dir="):
      result.flags.homeProfileDir = a["--home-profile-dir=".len .. ^1]
    elif a == "--host":
      result.flags.host = valueOf()
      result.flags.hostGiven = true
    elif a.startsWith("--host="):
      result.flags.host = a["--host=".len .. ^1]
      result.flags.hostGiven = true
    elif a == "--plan": result.flags.planId = valueOf()
    elif a.startsWith("--plan="):
      result.flags.planId = a["--plan=".len .. ^1]
    elif a == "--keep-generations" or a.startsWith("--keep-generations="):
      let v = if a.startsWith("--keep-generations="): a["--keep-generations=".len .. ^1]
              else: valueOf()
      result.flags.keepGenerations = parseRetentionBound(a, v)
      result.flags.keepGenerationsGiven = true
    elif a == "--keep-days" or a.startsWith("--keep-days="):
      let v = if a.startsWith("--keep-days="): a["--keep-days=".len .. ^1]
              else: valueOf()
      result.flags.keepDays = parseRetentionBound(a, v)
      result.flags.keepDaysGiven = true
    elif a == "--generation": result.flags.generationId = valueOf()
    elif a.startsWith("--generation="):
      result.flags.generationId = a["--generation=".len .. ^1]
    elif a == "--no-elevate": result.flags.noElevate = true
    elif a == "--elevate": result.flags.noElevate = false
    elif a == "--no-preview": result.flags.noPreview = true
    elif a == "--accept-feature-destroy":
      result.flags.acceptFeatureDestroy = true
    elif a == "--accept-passwd-destroy":
      result.flags.acceptPasswdDestroy = true
    elif a == "--force-unlock":
      result.flags.forceUnlock = true
    elif a == "--reconcile-drift":
      # M82 Phase C: at plan time `--reconcile-drift` is an alias for
      # `--accept-drift` — the planner records "operator acknowledged
      # external drift" on every finding. The flag retains its original
      # semantics for `repro system rollback` (where rollback ALWAYS
      # confirms drift), so we set BOTH bits so the rollback path keeps
      # working unchanged.
      result.flags.reconcileDrift = true
      result.flags.acceptDrift = true
    elif a == "--accept-drift":
      # The canonical M82 Phase C spelling. The reconcileDrift bit is
      # set in lockstep because the rollback path still consumes the
      # historical name.
      result.flags.acceptDrift = true
      result.flags.reconcileDrift = true
    elif a.startsWith("--"):
      raise newException(ValueError, "unknown flag: " & a)
    else:
      result.positional.add(a)
    inc i

# ---------------------------------------------------------------------------
# GM10: the host registry gate.
# ---------------------------------------------------------------------------

proc gateHostSystemManagement(flags: InfraCliFlags; host, profilePath,
                              stateDir, command: string;
                              verdict: var HostRegistryVerdict;
                              target: var SystemPlanTarget): bool =
  ## Read the host registry (`infra_host_registry`) and refuse a host whose
  ## system is managed elsewhere, or whose registry mode disagrees with the
  ## base it runs (`checkHostSystemMode`, `EAddOnModeMismatch`; an add-on
  ## host on a base without a realisation profile is
  ## `EAddOnUnsupportedBase`). On success `target` is the system-scope
  ## target the registry selects (`systemPlanTargetFor`). Runs BEFORE the system profile is
  ## compiled and before any plan, lock or generation is written, so a
  ## refused host leaves the state directory as it was. Returns false (after
  ## printing why) when the command must stop. `host` is the command's
  ## resolved identity (`resolveInfraHost`), the name the plan and the
  ## generation record too.
  try:
    let registry = resolveHostRegistryPath(flags.homeProfileDir, profilePath)
    verdict = readHostRegistry(registry, host, stateDir)
  except EHostRegistry as e:
    stderr.writeLine(command & ": " & e.msg)
    stderr.writeLine("  Who manages this host's system is unknown, so " &
      "nothing was planned or changed.")
    return false
  let refusal = managedElsewhereRefusal(verdict, command)
  if refusal.len > 0:
    stderr.writeLine(refusal)
    return false
  let base = observeHostBase()
  try:
    checkHostSystemMode(verdict, base)
    target = systemPlanTargetFor(verdict, base)
  except EAddOn as e:
    stderr.writeLine(command & ": refusing host " & host & ": " & e.msg)
    stderr.writeLine("  host registry : " &
      (if verdict.registryPath.len > 0: verdict.registryPath else: "none"))
    stderr.writeLine("  observed base : " & describeHostBase(base))
    return false
  true

# ---------------------------------------------------------------------------
# repro infra plan
# ---------------------------------------------------------------------------

proc runInfraPlan(args: openArray[string]): int =
  let (flags, _) = parseInfraFlags(args)
  let stateDir = (if flags.stateDir.len > 0: flags.stateDir
                  else: resolveSystemStateDir())
  setStateDirOverride(stateDir)
  let profilePath = resolveProfilePath(flags, stateDir)
  if not fileExists(profilePath):
    stderr.writeLine("repro infra plan: no system profile at " & profilePath)
    return 1
  var host: string
  if not resolveInfraHost(flags, "repro infra plan", host):
    return 2
  var registry: HostRegistryVerdict
  var target: SystemPlanTarget
  if not gateHostSystemManagement(flags, host, profilePath, stateDir,
      "repro infra plan", registry, target):
    return 1
  let originalText = readFile(profilePath)
  # M83 Phase F3: compile-then-adapt is the ONLY path; a compile
  # failure exits non-zero with a uniform actionable error.
  var profileText: string
  var projection: Projection
  if not resolveSystemProfileText(profilePath, originalText, stateDir,
      "repro infra plan", profileText,
      planCommand = "repro infra plan", target = target,
      outProjection = addr projection):
    return 1
  ensureSystemStateDir(stateDir)
  when defined(linux):
    # ReproOS add-on mode: the add-on's plan is the collision pass over the
    # operator's profile (spec §7.1); it writes nothing and prints the
    # ledger diff and the collision report, then the plain plan follows.
    if addon_apply.isAddonHost(stateDir):
      try:
        let r = addon_apply.runAddonApply(addon_apply.AddonApplyOptions(
          stateDir: stateDir, hostIdentity: host, userProfileText: profileText,
          reconcileDrift: flags.reconcileDrift, planOnly: true))
        echo "repro infra plan (add-on)"
        stdout.write(addon_cli.renderAddonSections(r))
      except CatchableError as e:
        stderr.writeLine("repro infra plan: " & e.msg)
        return 2
  # M82 Phase C: pass the state dir so the planner can read the
  # previously-applied generation's recorded `postWriteDigest` per
  # resource and surface external drift. The `--accept-drift` /
  # `--reconcile-drift` flag annotates findings as operator-accepted.
  let planResult = producePlan(profileText, host,
    opts = PlannerOptions(stateDir: stateDir,
                          acceptDrift: flags.acceptDrift))
  let env = planResult.envelope
  writePlanFile(planPath(stateDir, env.planId), env)

  echo "repro infra plan"
  echo "  profile : " & profilePath
  echo "  host    : " & host
  echo "  registry: " & describeRegistry(registry)
  echo "  system  : " & describeSystemTarget(target)
  for e in ignoredEntries(projection):
    echo "  ignored : " & describeEntry(e)
  let hostNote = recordedHostNote(stateDir, host)
  if hostNote.len > 0:
    echo "  note    : " & hostNote
  echo "  plan-id : " & env.planId
  var changeCount = 0
  for op in env.operations:
    let marker = if op.action == "no-op": "  " else: "* "
    echo "  " & marker & op.summary & "  [" & op.action & "]"
    if op.action != "no-op":
      inc changeCount
  if changeCount == 0:
    echo "  (no changes — apply would be a no-op)"
  else:
    echo "  " & $changeCount & " operation(s) would change the system."
  # M82 Phase C: surface plan-time external drift, if any.
  let driftText = renderDriftFindings(planResult.driftFindings)
  if driftText.len > 0:
    echo ""
    echo driftText
  # Name the privileged operations and state the single prompt is
  # coming and why (the M81 partition notice).
  let partition = planPartition(profileText, env)
  let notice = partition.renderPlanPrivilegeNotice(
    alreadyElevated = isProcessElevated())
  if notice.len > 0:
    echo ""
    echo notice
  echo ""
  echo "  apply with: repro infra apply --plan " & env.planId
  return 0

# ---------------------------------------------------------------------------
# repro infra apply
# ---------------------------------------------------------------------------

proc reproExePath(): string =
  ## The `repro` binary the broker re-execs: the running engine, by the path
  ## that re-enters it (`publicCliImagePath`; under the portable Linux
  ## launcher `getAppFilename()` names the glibc loader instead).
  ##
  ## The broker runs as `<this> --privileged-broker …`, a mode only `repro`
  ## implements, so the path goes through the same self-spawn guard as the
  ## internal verbs (Distribution-And-Packaging.md §5.2): for the CLI it is
  ## exactly `publicCliImagePath()`, and an embedded caller that has not
  ## declared itself `repro` gets "", which `launchAndDriveBroker` refuses
  ## instead of launching the caller's own image as the broker.
  selfSpawnIoMonitorPath()

var cliHostLock: HostApplyLock
  ## The host lock `takeInfraApplyLock` took for this command.

proc releaseInfraApplyLock(stateDir: string) =
  ## The two locks `takeInfraApplyLock` took, in reverse order.
  releaseApplyLock(stateDir)
  cliHostLock.release()

proc takeInfraApplyLock(stateDir, command: string;
                        flags: InfraCliFlags): bool =
  ## Acquire the per-host apply lock for a mutating `repro infra` /
  ## `repro system` command, and TELL THE OPERATOR what happened.
  ##
  ## A refusal names the holder, how long it has held the lock and when
  ## it last made progress, so "another apply is in progress" is
  ## actionable rather than a dead end. A reclaim that displaced a
  ## still-running process says so loudly: the lock moved, the process
  ## did not, and the operator must confirm it is gone.
  ##
  ## The host-wide apply lock comes FIRST, then the state directory's: one
  ## order everywhere (`repro_core/host_apply_lock`), so no two commands
  ## can each hold one and wait for the other.
  try:
    cliHostLock = acquireHostApplyLock(command & " (state " & stateDir & ")",
      privileged = isProcessElevated())
  except ELockTimeout as e:
    stderr.writeLine(command & ": " & e.msg)
    return false
  var policy = defaultApplyLockPolicy()
  policy.forceUnlock = flags.forceUnlock
  let acq = tryAcquireApplyLock(stateDir, policy)
  if not acq.acquired:
    cliHostLock.release()
    stderr.writeLine(command & ": another system apply is in progress (" &
      describeApplyLockHolder(stateDir, acq) & ").")
    stderr.writeLine("  The owner is alive and not provably stalled, so " &
      "the lock stays with it. If you are certain it is hung, stop it " &
      "and re-run with --force-unlock.")
    return false
  if acq.reclaim in ReclaimedFromLiveOwner:
    stderr.writeLine(command & ": reclaimed the apply lock from pid " &
      $acq.previousOwner & " (" & $acq.reclaim & "; held for " &
      $acq.heldForSeconds & "s, last progress " &
      $acq.sinceHeartbeatSeconds & "s ago).")
    stderr.writeLine("  That process was NOT terminated. Verify it is " &
      "gone before trusting this apply — two concurrent applies would " &
      "both mutate system state.")
  elif acq.reclaim == alrDeadOwner:
    stderr.writeLine(command & ": reclaimed a stale apply lock left by " &
      "dead pid " & $acq.previousOwner & ".")
  elif acq.reclaim == alrMalformed:
    stderr.writeLine(command & ": reclaimed an unreadable apply lock.")
  true

proc canonicalPlatformCpu*(token: string): string =
  ## The cache's spelling of a CPU family: `armhf`, `armv7l` and `armv7h`
  ## all mean `armv7`, `amd64` means `x86_64`, `arm64` means `aarch64`
  ## (`packages_schema.parsePlatformCpuToken`). A token no host derives —
  ## `unknown`, `any`, a typo — is refused by name: a key derived from it
  ## would be one that no apply ever looks up, so the entry published under
  ## it would be unreachable and the mistake invisible.
  let parsed = parsePlatformCpuToken(token)
  if not parsed.ok or parsed.cpu == pcAny:
    raise newException(ValueError,
      "--platform-cpu '" & token & "' names no CPU family the binary cache " &
      "keys by (x86_64, aarch64, armv7, x86); an entry published under it " &
      "could never be substituted")
  $parsed.cpu

proc cacheKeysPlatform*(flags: InfraCliFlags; stateDir: string):
    PlatformTriple =
  ## The platform `repro infra cache-keys` derives for: each `--platform-*`
  ## flag that was GIVEN (an empty value included), and this host's value
  ## for the rest.
  result = bc_actions.localPlatformTriple(stateDir)
  if flags.platformCpuGiven:
    result.cpu = canonicalPlatformCpu(flags.platformCpu)
  if flags.platformOsGiven:
    if flags.platformOs.len == 0 or flags.platformOs == "unknown":
      raise newException(ValueError,
        "--platform-os must name an OS a host derives (linux, darwin, " &
        "windows); got '" & flags.platformOs & "'")
    result.os = flags.platformOs
  if flags.platformAbiGiven: result.abi = flags.platformAbi
  if flags.platformLibcGiven: result.libcVariant = flags.platformLibc

proc renderCacheKeys*(actions: seq[ProfileBuildAction];
                      platform: PlatformTriple): string =
  ## The `repro infra cache-keys` report: one block per build-action edge
  ## with the entry key an apply on `platform` looks up and the identity
  ## flags that publish under it. Edges whose outputs are not all under
  ## their `cwd` are listed as not substitutable, which is what the apply
  ## concludes about them too (`outputRelPaths`).
  for action in actions:
    let idy = bc_actions.buildActionCacheIdentity(action, platform)
    result.add(action.id & "\n")
    if not bc_actions.isSubstitutable(action):
      result.add("  not substitutable: an output is not under cwd\n")
      continue
    result.add("  entry-key: " & deriveCacheEntryKeyHex(idy) & "\n")
    result.add("  publish:   repro cache publish " &
      deriveCacheEntryKeyHex(idy) & " <prefix> " &
      bc_actions.publishIdentityFlags(idy).join(" ") & "\n")
    if action.substituteOnly or action.expectedOutputDigest.len > 0:
      result.add("  expectedOutputDigest: " &
        (if action.expectedOutputDigest.len > 0: action.expectedOutputDigest
         else: "(none; `repro cache publish` prints `output-digest blake3:…`" &
               " to pin)") & "\n")

proc runInfraCacheKeys(args: openArray[string]): int =
  ## `repro infra cache-keys [--profile P] [--state-dir D] [--platform-cpu C]
  ## [--platform-os O] [--platform-abi A] [--platform-libc L]`.
  ##
  ## Compiles the profile exactly as `plan` and `apply` do and prints, for
  ## every build-action edge, the binary-cache entry key an apply of that
  ## profile derives on the given platform (default: this host), with the
  ## `repro cache publish` flags that publish an output prefix under it.
  ## This is how a build host publishes an edge's outputs AHEAD of a host
  ## that cannot build them (Binary-Caches.md §"Publishing for a host that
  ## cannot build"): the key is a function of the edge and the consuming
  ## platform only, so it can be derived anywhere the profile compiles.
  ## Nothing is applied, planned or written outside the profile-compile
  ## cache under the state directory.
  let (flags, _) = parseInfraFlags(args)
  let stateDir = (if flags.stateDir.len > 0: flags.stateDir
                  else: resolveSystemStateDir())
  setStateDirOverride(stateDir)
  let profilePath = resolveProfilePath(flags, stateDir)
  if not fileExists(profilePath):
    stderr.writeLine("repro infra cache-keys: no system profile at " &
      profilePath)
    return 1
  var profileText: string
  var actions: seq[ProfileBuildAction]
  if not resolveSystemProfileText(profilePath, readFile(profilePath),
      stateDir, "repro infra cache-keys", profileText,
      planCommand = "repro infra cache-keys",
      outBuildActions = addr actions):
    return 1
  let platform = cacheKeysPlatform(flags, stateDir)
  echo "repro infra cache-keys"
  echo "  profile : " & profilePath
  echo "  platform: cpu=" & platform.cpu & " os=" & platform.os &
    " abi=" & platform.abi & " libc=" & platform.libcVariant
  if actions.len == 0:
    echo "  (the profile declares no build-action edges)"
    return 0
  stdout.write(renderCacheKeys(actions, platform))
  return 0

proc runInfraApply(args: openArray[string]): int =
  let (flags, positional) = parseInfraFlags(args)
  let stateDir = (if flags.stateDir.len > 0: flags.stateDir
                  else: resolveSystemStateDir())
  setStateDirOverride(stateDir)
  if flags.keepGenerationsGiven or flags.keepDaysGiven:
    var addOnHost = false
    when defined(linux):
      addOnHost = addon_apply.isAddonHost(stateDir)
    if not addOnHost:
      stderr.writeLine("repro infra apply: --keep-generations and " &
        "--keep-days set an add-on host's generation retention; this host " &
        "is not an add-on host")
      return 2
  let profilePath = resolveProfilePath(flags, stateDir)
  if not fileExists(profilePath):
    stderr.writeLine("repro infra apply: no system profile at " &
      profilePath)
    return 1
  var host: string
  if not resolveInfraHost(flags, "repro infra apply", host):
    return 2
  var registry: HostRegistryVerdict
  var target: SystemPlanTarget
  if not gateHostSystemManagement(flags, host, profilePath, stateDir,
      "repro infra apply", registry, target):
    return 1
  let originalText = readFile(profilePath)
  # M83 Phase F3: compile-then-adapt is the ONLY path; a compile
  # failure exits non-zero with a uniform actionable error.
  var profileText: string
  var profileBuildActions: seq[ProfileBuildAction]
  if not resolveSystemProfileText(profilePath, originalText, stateDir,
      "repro infra apply", profileText,
      planCommand = "repro infra plan",
      outBuildActions = addr profileBuildActions, target = target):
    return 1

  var planId = flags.planId
  if planId.len == 0 and positional.len > 0:
    planId = positional[0]
  if planId.len == 0 and not flags.noPreview:
    stderr.writeLine("repro infra apply: no plan id given; either run " &
      "`repro infra plan` first and pass --plan <id>, or pass " &
      "--no-preview to compute and apply a fresh plan without preview.")
    return 2

  if not takeInfraApplyLock(stateDir, "repro infra apply", flags):
    return 1
  defer: releaseInfraApplyLock(stateDir)

  when defined(linux):
    # ReproOS add-on mode: on a host the add-on was bootstrapped on, every
    # generation is the add-on's own objects plus this profile, and the
    # ownership ledger decides what may be removed. A plain infra apply here
    # would bypass the ledger, so the apply goes through the add-on layer.
    if addon_apply.isAddonHost(stateDir):
      if profileBuildActions.len > 0:
        stderr.writeLine("repro infra apply: this is an add-on host, and " &
          "add-on generations do not carry build actions yet; the profile " &
          "declares " & $profileBuildActions.len)
        return 2
      # The generation retention policy (§5.2): only what was given
      # overrides the default; nothing given keeps the default.
      var retention = none(addon_apply.RetentionPolicy)
      if flags.keepGenerationsGiven or flags.keepDaysGiven:
        var p = addon_apply.DefaultRetention
        if flags.keepGenerationsGiven: p.keepGenerations = flags.keepGenerations
        if flags.keepDaysGiven: p.keepDays = flags.keepDays
        retention = some(p)
      try:
        # `--plan` on an add-on host pins the add-on plan id the plan
        # printed ("add-on plan-id"); the apply refuses with EPlanStale
        # when what it observes now gives another (spec §7.1).
        let r = addon_apply.runAddonApply(addon_apply.AddonApplyOptions(
          stateDir: stateDir, hostIdentity: host, userProfileText: profileText,
          reconcileDrift: flags.reconcileDrift, planId: planId,
          retention: retention))
        stdout.write(addon_cli.renderAddonSections(r))
        echo "repro infra apply (add-on): generation " & r.generationId &
          " (previous " & r.previousGenerationId & "), applied " &
          $r.infra.appliedCount & ", removed " & $r.removed.len &
          ", restored " & $r.restored.len
        if r.drift.len > 0:
          stderr.writeLine("repro infra apply: " & $r.drift.len &
            " object(s) left in place as actionable drift")
          return 1
        return 0
      except EPlanStale as e:
        stderr.writeLine("repro infra apply: " & e.msg)
        for a in e.drifted:
          stderr.writeLine("  drifted: " & a)
        return 3
      except EAddOn as e:
        stderr.writeLine("repro infra apply: " & e.msg)
        return 2
      except addon_apply.AddonCollisionError as e:
        stderr.writeLine("repro infra apply: " & e.msg)
        return 2
      except addon_apply.AddonDriftError as e:
        stderr.writeLine("repro infra apply: " & e.msg)
        return 2
      except CatchableError as e:
        stderr.writeLine("repro infra apply: " & e.msg)
        return 1

  var opts: ApplyOptions
  opts.stateDir = stateDir
  opts.hostIdentity = host
  opts.reproExe = reproExePath()
  opts.planId = planId
  opts.elevationMode = if flags.noElevate: emNoElevate else: emBroker
  opts.forceBroker = getEnv(ForceBrokerEnvVar).len > 0
  opts.noPreview = flags.noPreview
  opts.acceptPasswdDestroy = flags.acceptPasswdDestroy
  # Windows-System-Resources Phase G + CLI-wiring: attach the action-
  # edge dispatcher closure + the profile's ``buildActions`` seq. The
  # apply driver's ``dispatchBuildActions`` step dispatches each entry
  # through ``runBuild`` + the elevation broker hook
  # (``mkInfraApplyBrokerSpawn``). A profile with no action edges
  # leaves ``buildActions`` empty and the dispatcher is never consulted.
  attachBuildActionDispatcher(opts, profileBuildActions, stateDir)

  # Read BEFORE the apply commits a generation: afterwards the current
  # generation is this run's own.
  let hostNote = recordedHostNote(stateDir, host)
  var applyResult: ApplyResult
  try:
    applyResult = runInfraApply(profileText, opts)
  except EPlanStale as e:
    stderr.writeLine("repro infra apply: " & e.msg)
    for a in e.drifted:
      stderr.writeLine("  drifted: " & a)
    return 3
  except EPasswdDestroy as e:
    stderr.writeLine("repro infra apply: " & e.msg)
    return 1
  except EInfra as e:
    stderr.writeLine("repro infra apply: " & e.msg)
    return 1

  echo "repro infra apply"
  echo "  plan-id      : " & applyResult.planId
  echo "  host         : " & host
  echo "  registry     : " & describeRegistry(registry)
  echo "  system       : " & describeSystemTarget(target)
  if hostNote.len > 0:
    echo "  note         : " & hostNote
  echo "  generation   : " & applyResult.generationId
  echo "  applied      : " & $applyResult.appliedCount
  echo "  no-op        : " & $applyResult.noOpCount
  if applyResult.skippedCount > 0:
    echo "  skipped      : " & $applyResult.skippedCount &
      " (privileged; not elevated)"
  if applyResult.driftCount > 0:
    echo "  drift        : " & $applyResult.driftCount &
      " (fail-closed; re-plan)"
  if applyResult.errorCount > 0:
    echo "  errors       : " & $applyResult.errorCount
  echo "  broker used  : " & $applyResult.usedBroker &
    " (launches: " & $applyResult.brokerLaunchCount & ")"
  echo "  audit log    : " & applyResult.auditLogPath
  if applyResult.restartNeeded:
    echo "  NOTE: a reboot is required to finish one or more changes; " &
      "Reprobuild does not auto-reboot."
  for d in applyResult.diagnostics:
    echo "  - " & d
  if applyResult.driftCount > 0 or applyResult.errorCount > 0:
    return 1
  if applyResult.skippedCount > 0:
    # Partial success — the non-privileged subset applied, the
    # privileged ones were skipped.
    return 4
  return 0

# ---------------------------------------------------------------------------
# repro system audit
# ---------------------------------------------------------------------------

proc runSystemAudit(args: openArray[string]): int =
  let (flags, positional) = parseInfraFlags(args)
  let stateDir = (if flags.stateDir.len > 0: flags.stateDir
                  else: resolveSystemStateDir())
  setStateDirOverride(stateDir)
  var generationId =
    if positional.len > 0: positional[0]
    else: readCurrentGenerationId(stateDir)
  if generationId.len == 0:
    stderr.writeLine("repro system audit: no current system generation " &
      "(run `repro infra apply` first).")
    return 1
  let logPath = applyLogPath(stateDir, generationId)
  let auditResult = readAuditLog(logPath)
  echo "repro system audit"
  echo "  generation : " & generationId
  echo "  log        : " & logPath
  echo "  records    : " & $auditResult.records.len
  # Break the count down by population. An apply converges live-state
  # resources AND build-action edges; the summary counters pool them,
  # so the audit view states each half explicitly rather than leaving
  # a reader to guess which resources a number refers to.
  var liveStateRecords = 0
  var buildActionRecords = 0
  for rec in auditResult.records:
    if rec.isBuildActionRecord(): inc buildActionRecords
    else: inc liveStateRecords
  echo "    live-state   : " & $liveStateRecords
  echo "    build-action : " & $buildActionRecords
  for rec in auditResult.records:
    let ts = $fromUnix(rec.timestamp).utc()
    echo "  [" & ts & "] " & rec.outcome & "  " & rec.recordClass &
      "  " & rec.operationKind & "  " & rec.resourceAddress
    if rec.fingerprintHex.len > 0:
      echo "      fingerprint " & rec.fingerprintHex
    if rec.diagnostic.len > 0:
      echo "      " & rec.diagnostic
    if rec.restartNeeded:
      echo "      (reboot required)"
  if auditResult.truncatedTail:
    echo "  WARNING: the log ends with a truncated record (an apply " &
      "was interrupted); the records above are intact."
  return 0

# ===========================================================================
# repro system add / remove / list / why / sync / history / rollback
# (M69 Phase B — the system-scope analogue of the M60-M64 home commands).
#
# `add` / `remove` edit `system.nim` through the formatting-preserving
# structural editor (`repro_infra/intent.nim`); `list` / `why` query
# the parsed profile; `sync` drives the Phase-A `repro infra apply`
# path; `history` enumerates the RBSG generation envelopes; `rollback`
# re-applies a prior generation.
# ===========================================================================

proc systemProfilePathOrCreate(flags: InfraCliFlags;
                               stateDir: string): string =
  ## The `system.nim` path. `repro system add` may target a file that
  ## does not exist yet — the editor creates it on first add.
  if flags.profilePath.len > 0: flags.profilePath
  else: systemProfilePath(stateDir)

proc buildResourceFromArgs(kindTag: string;
                           fieldArgs: openArray[string]): SystemResource =
  ## Build a `SystemResource` from `repro system add <kind> key=value
  ## ...` positional arguments. Reuses the Phase-A `parseSystemProfile`
  ## parser by rendering the arguments into a single stanza and
  ## parsing it — so `add` and a hand-authored stanza go through the
  ## SAME validation, and a list field (`workloads=[a,b]`) parses
  ## identically.
  var stanza = kindTag & " {\n"
  for fa in fieldArgs:
    let eq = fa.find('=')
    if eq <= 0:
      raise newException(ValueError,
        "expected key=value, got '" & fa & "'")
    let key = fa[0 ..< eq].strip()
    let raw = fa[eq + 1 .. ^1]
    # A list literal or a bool/identifier passes through verbatim; a
    # bare string is quoted so the parser unquotes it back.
    let rendered =
      if raw.startsWith("["): raw
      elif raw.toLowerAscii() in ["true", "false"]: raw
      elif key in ["kind", "startType", "state"]: raw
      else: "\"" & raw & "\""
    stanza.add("  " & key & " = " & rendered & "\n")
  stanza.add("}\n")
  let parsed = parseSystemProfile(stanza)
  if parsed.resources.len != 1:
    raise newException(ValueError,
      "internal: add stanza did not parse to exactly one resource")
  parsed.resources[0]

proc runSystemAdd(args: openArray[string]): int =
  let (flags, positional) = parseInfraFlags(args)
  let stateDir = (if flags.stateDir.len > 0: flags.stateDir
                  else: resolveSystemStateDir())
  setStateDirOverride(stateDir)
  if positional.len == 0:
    stderr.writeLine("usage: repro system add <kind> key=value ...")
    return 2
  let kindTag = positional[0]
  let fieldArgs = if positional.len > 1: positional[1 .. ^1] else: @[]
  let resource = buildResourceFromArgs(kindTag, fieldArgs)
  let profilePath = systemProfilePathOrCreate(flags, stateDir)
  # Create an empty profile file on first add so the editor has a
  # document to splice into.
  if not fileExists(profilePath):
    let parent = parentDir(profilePath)
    if parent.len > 0: createDir(parent)
    writeFile(profilePath, "")
  var doc = loadSystemIntent(profilePath)
  addResource(doc, resource)
  writeSystemIntent(doc)
  echo "repro system add"
  echo "  profile  : " & profilePath
  echo "  added    : " & $resource.kind & "  " & resource.address
  echo "  apply with: repro system sync"
  return 0

proc runSystemRemove(args: openArray[string]): int =
  let (flags, positional) = parseInfraFlags(args)
  let stateDir = (if flags.stateDir.len > 0: flags.stateDir
                  else: resolveSystemStateDir())
  setStateDirOverride(stateDir)
  if positional.len == 0:
    stderr.writeLine("usage: repro system remove <address>")
    return 2
  let address = positional[0]
  let profilePath = systemProfilePathOrCreate(flags, stateDir)
  if not fileExists(profilePath):
    stderr.writeLine("repro system remove: no system profile at " &
      profilePath)
    return 1
  var doc = loadSystemIntent(profilePath)
  if not removeResource(doc, address):
    stderr.writeLine("repro system remove: no resource with address '" &
      address & "' in " & profilePath)
    return 1
  writeSystemIntent(doc)
  echo "repro system remove"
  echo "  profile  : " & profilePath
  echo "  removed  : " & address
  echo "  apply with: repro system sync"
  return 0

proc runSystemList(args: openArray[string]): int =
  let (flags, _) = parseInfraFlags(args)
  let stateDir = (if flags.stateDir.len > 0: flags.stateDir
                  else: resolveSystemStateDir())
  setStateDirOverride(stateDir)
  let profilePath = systemProfilePathOrCreate(flags, stateDir)
  if not fileExists(profilePath):
    echo "repro system list"
    echo "  (no system profile at " & profilePath & ")"
    return 0
  let profile = parseSystemProfile(readFile(profilePath))
  echo "repro system list"
  echo "  profile   : " & profilePath
  echo "  resources : " & $profile.resources.len
  for r in profile.resources:
    echo "  - " & $r.kind & "  " & r.address
  return 0

proc runSystemWhy(args: openArray[string]): int =
  let (flags, positional) = parseInfraFlags(args)
  let stateDir = (if flags.stateDir.len > 0: flags.stateDir
                  else: resolveSystemStateDir())
  setStateDirOverride(stateDir)
  if positional.len == 0:
    stderr.writeLine("usage: repro system why <address>")
    return 2
  let address = positional[0]
  let profilePath = systemProfilePathOrCreate(flags, stateDir)
  if not fileExists(profilePath):
    stderr.writeLine("repro system why: no system profile at " &
      profilePath)
    return 1
  let profile = parseSystemProfile(readFile(profilePath))
  for r in profile.resources:
    if r.address == address:
      echo "repro system why " & address
      echo "  declared in : " & profilePath
      echo "  kind        : " & $r.kind
      echo "  target      : " & realWorldIdentity(r)
      echo "  destructive rollback: " & $isDestructiveRollback(r)
      let op = toPrivilegedOperation(r)
      echo "  privileged  : " & $requiresElevation(op.kind) &
        " (a system-scope resource — applied through the elevation broker)"
      return 0
  stderr.writeLine("repro system why: no resource with address '" &
    address & "' in " & profilePath)
  return 1

proc runSystemSync(args: openArray[string]): int =
  ## `repro system sync` — apply the current `system.nim`. Drives the
  ## Phase-A `repro infra apply` path with a fresh plan (no preview),
  ## the system-scope analogue of `repro home apply`.
  let (flags, _) = parseInfraFlags(args)
  let stateDir = (if flags.stateDir.len > 0: flags.stateDir
                  else: resolveSystemStateDir())
  setStateDirOverride(stateDir)
  let profilePath = systemProfilePathOrCreate(flags, stateDir)
  if not fileExists(profilePath):
    stderr.writeLine("repro system sync: no system profile at " &
      profilePath)
    return 1
  var host: string
  if not resolveInfraHost(flags, "repro system sync", host):
    return 2
  var registry: HostRegistryVerdict
  var target: SystemPlanTarget
  if not gateHostSystemManagement(flags, host, profilePath, stateDir,
      "repro system sync", registry, target):
    return 1
  let originalText = readFile(profilePath)
  # M83 Phase F3: compile-then-adapt is the ONLY path; a compile
  # failure exits non-zero with a uniform actionable error.
  var profileText: string
  var profileBuildActions: seq[ProfileBuildAction]
  if not resolveSystemProfileText(profilePath, originalText, stateDir,
      "repro system sync", profileText,
      planCommand = "repro infra plan",
      outBuildActions = addr profileBuildActions, target = target):
    return 1
  if not takeInfraApplyLock(stateDir, "repro system sync", flags):
    return 1
  defer: releaseInfraApplyLock(stateDir)
  # M82 Phase C: surface plan-time drift BEFORE the apply runs. `sync`
  # has `--no-preview` baked in, so we synthesize the same drift output
  # the explicit `infra plan` flow prints; the apply itself then
  # proceeds (drift is REPORTED, not blocking).
  let driftPreview = producePlan(profileText, host,
    opts = PlannerOptions(stateDir: stateDir,
                          acceptDrift: flags.acceptDrift))
  let driftText = renderDriftFindings(driftPreview.driftFindings)
  if driftText.len > 0:
    echo driftText
    echo ""
  var opts: ApplyOptions
  opts.stateDir = stateDir
  opts.hostIdentity = host
  opts.reproExe = reproExePath()
  opts.planId = ""
  opts.elevationMode = if flags.noElevate: emNoElevate else: emBroker
  opts.forceBroker = getEnv(ForceBrokerEnvVar).len > 0
  opts.noPreview = true
  opts.acceptPasswdDestroy = flags.acceptPasswdDestroy
  # Windows-System-Resources Phase G + CLI-wiring: same action-edge
  # attachment as ``repro infra apply``. ``repro system sync`` is the
  # other CLI surface that drives ``runInfraApply``; both seams must
  # populate ``opts.buildActions`` so a profile that mixes live-state
  # and action-edge resources dispatches both halves correctly.
  attachBuildActionDispatcher(opts, profileBuildActions, stateDir)
  let hostNote = recordedHostNote(stateDir, host)
  var applyResult: ApplyResult
  try:
    applyResult = runInfraApply(profileText, opts)
  except EInfra as e:
    stderr.writeLine("repro system sync: " & e.msg)
    return 1
  echo "repro system sync"
  echo "  host         : " & host
  echo "  registry     : " & describeRegistry(registry)
  echo "  system       : " & describeSystemTarget(target)
  if hostNote.len > 0:
    echo "  note         : " & hostNote
  echo "  generation   : " & applyResult.generationId
  echo "  applied      : " & $applyResult.appliedCount
  echo "  no-op        : " & $applyResult.noOpCount
  if applyResult.skippedCount > 0:
    echo "  skipped      : " & $applyResult.skippedCount &
      " (privileged; not elevated)"
  if applyResult.driftCount > 0:
    echo "  drift        : " & $applyResult.driftCount &
      " (fail-closed; re-plan)"
  if applyResult.errorCount > 0:
    echo "  errors       : " & $applyResult.errorCount
  echo "  broker used  : " & $applyResult.usedBroker &
    " (launches: " & $applyResult.brokerLaunchCount & ")"
  echo "  audit log    : " & applyResult.auditLogPath
  if applyResult.restartNeeded:
    echo "  NOTE: a reboot is required to finish one or more changes; " &
      "Reprobuild does not auto-reboot."
  for d in applyResult.diagnostics:
    echo "  - " & d
  if applyResult.driftCount > 0 or applyResult.errorCount > 0:
    return 1
  if applyResult.skippedCount > 0:
    return 4
  return 0

proc runSystemHistory(args: openArray[string]): int =
  ## `repro system history` — list the system-scope generations, the
  ## M62 `repro home history` analogue at system scope.
  let (flags, _) = parseInfraFlags(args)
  let stateDir = (if flags.stateDir.len > 0: flags.stateDir
                  else: resolveSystemStateDir())
  setStateDirOverride(stateDir)
  let generations = enumerateSystemGenerations(stateDir)
  echo "repro system history"
  echo "  state-dir   : " & stateDir
  echo "  generations : " & $generations.len
  for rec in generations:
    let ts = $fromUnix(rec.envelope.activationTimestamp).utc()
    let marker = if rec.isActive: "* " else: "  "
    echo "  " & marker & rec.generationId & "  [" & ts & "]  " &
      "applied=" & $rec.envelope.appliedCount &
      " no-op=" & $rec.envelope.noOpCount &
      " host=" & rec.envelope.hostIdentity
  if generations.len == 0:
    echo "  (no system generations — run `repro system sync` first)"
  return 0

proc runSystemRollbackCmd(args: openArray[string]): int =
  ## `repro system rollback [<generation-id>]` — the M64 home-rollback
  ## analogue at system scope. Re-applies a prior generation's
  ## `system.nim` and actively reverts resources the active generation
  ## added that the target does not declare.
  let (flags, positional) = parseInfraFlags(args)
  let stateDir = (if flags.stateDir.len > 0: flags.stateDir
                  else: resolveSystemStateDir())
  setStateDirOverride(stateDir)
  var targetId = flags.generationId
  if targetId.len == 0 and positional.len > 0:
    targetId = positional[0]
  # A rollback re-applies a generation's system profile, so a host whose
  # system the registry says is managed elsewhere is refused exactly as
  # `repro infra apply` refuses it (GM10). The registry is resolved against
  # the system profile path even when that file does not exist: the rollback
  # reads the generation's copy, but the configuration it belongs to is the
  # directory `--profile` (or the state dir's default) names.
  var host: string
  if not resolveInfraHost(flags, "repro system rollback", host):
    return 2
  var registry: HostRegistryVerdict
  # The rollback re-applies a recorded generation, so it needs the gate's
  # refusals (managed elsewhere, mode mismatch) but not its selection.
  var unusedTarget: SystemPlanTarget
  if not gateHostSystemManagement(flags, host,
      systemProfilePathOrCreate(flags, stateDir), stateDir,
      "repro system rollback", registry, unusedTarget):
    return 1
  let hostNote = recordedHostNote(stateDir, host)
  if not takeInfraApplyLock(stateDir, "repro system rollback", flags):
    return 1
  defer: releaseInfraApplyLock(stateDir)
  var opts: SystemRollbackOptions
  opts.stateDir = stateDir
  opts.hostIdentity = host
  opts.reproExe = reproExePath()
  opts.targetGenerationId = targetId
  opts.acceptFeatureDestroy = flags.acceptFeatureDestroy
  opts.acceptPasswdDestroy = flags.acceptPasswdDestroy
  opts.reconcileDrift = flags.reconcileDrift
  opts.forceBroker = getEnv(ForceBrokerEnvVar).len > 0
  var outcome: SystemRollbackOutcome
  try:
    outcome = runSystemRollback(opts)
  except EFeatureDestroy as e:
    stderr.writeLine("repro system rollback: " & e.msg)
    return 1
  except EPasswdDestroy as e:
    stderr.writeLine("repro system rollback: " & e.msg)
    return 1
  except EPlanStale as e:
    # System-scope rollback always confirms drift: a drifted resource
    # blocks the rollback unless `--reconcile-drift` is passed.
    stderr.writeLine("repro system rollback: " & $e.drifted.len &
      " resource(s) drifted since the target generation was applied; " &
      "system-scope rollback requires explicit confirmation — re-run " &
      "with --reconcile-drift to overwrite the drift.")
    for a in e.drifted:
      stderr.writeLine("  drifted: " & a)
    return 3
  except EInfra as e:
    stderr.writeLine("repro system rollback: " & e.msg)
    return 1
  echo "repro system rollback"
  echo "  host            : " & host
  if hostNote.len > 0:
    echo "  note            : " & hostNote
  echo "  from generation : " & outcome.fromGenerationId
  echo "  to generation   : " & outcome.toGenerationId
  echo "  new generation  : " & outcome.apply.generationId
  echo "  applied         : " & $outcome.appliedCount
  echo "  no-op           : " & $outcome.noOpCount
  if outcome.driftedAddresses.len > 0:
    echo "  reconciled drift: " & $outcome.driftedAddresses.len &
      " resource(s) (--reconcile-drift)"
  echo "  broker used     : " & $outcome.apply.usedBroker &
    " (launches: " & $outcome.apply.brokerLaunchCount & ")"
  if outcome.apply.errorCount > 0:
    echo "  errors          : " & $outcome.apply.errorCount
    return 1
  return 0

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------

proc runInfraInstallRootCli(args: seq[string]): int =
  ## ``repro infra install-root --target /mnt --device /dev/vda``.
  ##
  ## M9.R.41: install-time root-mirror.  Distinct from ``repro infra
  ## apply``: it does NOT reconcile a system profile in place — it
  ## materialises a content-addressed REPLICA of the live root onto a
  ## freshly-formatted target, then generates the target-side fstab +
  ## installs GRUB.  Used by the M9.R.18 reproos-installer's Phase 5
  ## driver to close the install -> boot loop.
  let loader: DiskoLoader = proc(path: string): DiskPlanOutcome =
    loadDiskoFromSource(path)
  let outcome = runInstallRoot(args, loader)
  if outcome.failure:
    stderr.writeLine("repro infra install-root: " & outcome.failureMsg)
    case outcome.failureKind
    of irfBadFlag: return 2
    of irfMissingTarget, irfMissingSource: return 2
    of irfRsyncFailed, irfGrubInstallFailed,
       irfFstabWriteFailed, irfGrubCfgWriteFailed,
       irfDiskoLoadFailed, irfBootArtifactMissing: return 1
  echo "repro infra install-root"
  echo "  rsync exit       : " & $outcome.rsyncExitCode
  echo "  mount entries    : " & $outcome.mountPlan.len
  for (dev, mp) in outcome.mountPlan:
    let shown = if mp.len == 0: "/" else: mp
    echo "    " & dev & "  ->  " & shown
  if outcome.fstabPath.len > 0:
    echo "  fstab            : " & outcome.fstabPath
  if outcome.grubCfgPath.len > 0:
    echo "  grub.cfg         : " & outcome.grubCfgPath
  echo "  grub-install exit: " & $outcome.grubInstallExit
  return 0

const InfraSubcommandUsage = [
  ("plan", "repro infra plan [--profile FILE] [--state-dir DIR] " &
    "[--home-profile-dir DIR] [--host NAME] [--accept-drift | " &
    "--reconcile-drift]\n  Compile the system profile and show what an " &
    "apply would change; writes nothing but the plan."),
  ("apply", "repro infra apply [--profile FILE] [--state-dir DIR] " &
    "[--home-profile-dir DIR] [--host NAME] --plan ID [--no-elevate | " &
    "--elevate] [--no-preview] [--accept-feature-destroy] " &
    "[--accept-passwd-destroy] [--force-unlock] [--reconcile-drift] " &
    "[--keep-generations N] [--keep-days D]\n  " &
    "Apply the plan `repro infra plan` printed, as a new system generation. " &
    "On an add-on host --plan takes the add-on plan id, and " &
    "--keep-generations/--keep-days set the generation retention."),
  ("cache-keys", "repro infra cache-keys [--profile FILE] [--state-dir DIR] " &
    "[--host NAME] [--platform-cpu CPU] [--platform-os OS] " &
    "[--platform-abi ABI] [--platform-libc LIBC]\n  Print, for every " &
    "build-action edge of the profile, the binary-cache entry key an apply " &
    "derives on the given platform (default: this host) and the `repro " &
    "cache publish` flags that publish under it. Nothing is applied."),
  ("install-root", "repro infra install-root ...\n  Install a built root " &
    "image onto a target disk (see the ReproOS installer documentation)."),
]
  ## What `repro infra <sub> --help` prints. The flag lists are the ones
  ## `parseInfraFlags` accepts; a flag not listed here is one it refuses.

proc runInfraCommand*(args: seq[string]): int =
  ## `repro infra <subcommand>`.
  if args.len == 0:
    stderr.writeLine("usage: repro infra {plan | apply | cache-keys | " &
      "install-root} ...")
    return 2
  let sub = args[0]
  let rest = if args.len > 1: args[1 .. ^1] else: @[]
  # `--help` / `-h` answers for every subcommand before its flags are parsed,
  # so it is never reported as an unknown flag.
  if "--help" in rest or "-h" in rest:
    for (name, usage) in InfraSubcommandUsage:
      if name == sub:
        echo "usage: " & usage
        return 0
    stderr.writeLine("repro infra: unknown subcommand: " & sub)
    return 2
  try:
    case sub
    of "plan": return runInfraPlan(rest)
    of "apply": return runInfraApply(rest)
    of "cache-keys": return runInfraCacheKeys(rest)
    of "install-root": return runInfraInstallRootCli(rest)
    else:
      stderr.writeLine("repro infra: unknown subcommand: " & sub)
      return 2
  except ValueError as e:
    stderr.writeLine("repro infra " & sub & ": " & e.msg)
    return 2
  except CatchableError as e:
    stderr.writeLine("repro infra " & sub & ": error: " & e.msg)
    return 1

proc runSystemCommand*(args: seq[string]): int =
  ## `repro system <subcommand>`. M69 Phase B wires the full
  ## `add/remove/list/why/sync/history/rollback` profile-editing
  ## family (the system-scope analogue of the M60-M64 `repro home`
  ## commands), alongside the Phase-A `audit` reader.
  if args.len == 0:
    stderr.writeLine("usage: repro system {add | remove | list | why | " &
      "sync | history | rollback | audit | addon} ...")
    return 2
  let sub = args[0]
  let rest = if args.len > 1: args[1 .. ^1] else: @[]
  try:
    case sub
    of "add": return runSystemAdd(rest)
    of "remove": return runSystemRemove(rest)
    of "list": return runSystemList(rest)
    of "why": return runSystemWhy(rest)
    of "sync": return runSystemSync(rest)
    of "history": return runSystemHistory(rest)
    of "rollback":
      # An add-on host rolls back through the add-on switch (ReproOS
      # Add-On Mode §7.5): its generations are the add-on's own objects
      # plus the operator's profile, not a whole-system profile. Add-on
      # mode manages Linux hosts only (its §1), so on any other target the
      # ordinary system rollback is the only one, as in `infra plan/apply`.
      when defined(linux):
        if addon_apply.isAddonHost(resolveSystemStateDir()):
          return addon_cli.runAddonRollbackCli(rest)
      return runSystemRollbackCmd(rest)
    of "audit": return runSystemAudit(rest)
    of "addon":
      when defined(linux):
        return addon_cli.runAddonCli(rest)
      else:
        stderr.writeLine("repro system addon: supported only on Linux")
        return 2
    of "adopt":
      when defined(linux):
        # System-scope adoption exists for add-on hosts (spec §11.2 step 3);
        # a full system profile has no unowned objects to claim.
        if not addon_apply.isAddonHost(resolveSystemStateDir()):
          stderr.writeLine("repro system adopt: only an add-on host has " &
            "objects to adopt; this host carries no ownership ledger")
          return 2
        return addon_cli.runAddonAdoptCli(rest)
      else:
        stderr.writeLine("repro system adopt: supported only on Linux")
        return 2
    else:
      stderr.writeLine("repro system: unknown subcommand: " & sub)
      return 2
  except ValueError as e:
    stderr.writeLine("repro system " & sub & ": " & e.msg)
    return 2
  except CatchableError as e:
    stderr.writeLine("repro system " & sub & ": error: " & e.msg)
    return 1
