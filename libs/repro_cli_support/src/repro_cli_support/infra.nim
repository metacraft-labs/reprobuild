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

import std/[os, strutils, times]

import repro_elevation
import repro_infra
import repro_profile
import repro_profile_intent
import repro_profile_compile
import repro_cli_support/home as cli_home
import repro_cli_support/disk as cli_disk
import repro_cli_support/infra_install_root

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

proc compileAndAdaptSystemProfile*(profilePath, stateDir: string):
    tuple[text: string; cached: bool; compileError: string;
          buildActions: seq[ProfileBuildAction]] =
  ## Run the Phase C build-engine edge against `profilePath`, decode
  ## the RBPI artifact, and render the adapted `SystemProfile` back
  ## into the canonical declarative text the M69 lib's APIs consume.
  ##
  ## On success: `result.text` is the canonical text and the caller
  ## passes it down to `runInfraApply(text, opts)`. On compile
  ## failure: `result.text` is empty and `result.compileError`
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
  let opts = ProfileCompileOptions(
    stateDir: stateDir,
    publicCliPath: getAppFilename(),
    repoRoot: getEnv(RepoRootEnvVar),
    workDir: profilePath.parentDir,
    verbose: false,
    forceRebuild: false)
  try:
    let artifact = compileProfileToRbpi(profilePath, opts)
    let intent = decodeRbpi(artifact.rbpiBytes)
    let sp = profileIntentToSystemProfile(intent)
    result.text = renderSystemProfileToText(sp)
    result.buildActions = intent.buildActions
  except ProfileCompileError as err:
    result.compileError = err.msg
  except CatchableError as err:
    result.compileError = err.msg

proc resolveSystemProfileText*(profilePath: string;
                               originalText, stateDir,
                               commandName: string;
                               outText: var string;
                               planCommand = "";
                               outBuildActions: ptr seq[ProfileBuildAction] = nil):
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
  discard originalText  # retained for caller compatibility; see docstring
  let outcome = compileAndAdaptSystemProfile(profilePath, stateDir)
  if outcome.text.len > 0:
    outText = outcome.text
    if outBuildActions != nil:
      outBuildActions[] = outcome.buildActions
    return true
  stderr.writeLine(cli_home.formatProfileCompileError(
    commandName, profilePath, outcome.compileError,
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
  InfraCliFlags = object
    stateDir: string
    profilePath: string
    host: string
    planId: string
    generationId: string
    noElevate: bool
    noPreview: bool
    acceptFeatureDestroy: bool
    acceptPasswdDestroy: bool
    reconcileDrift: bool                  ## also set by `--accept-drift`
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

proc hostIdentity(explicit: string): string =
  if explicit.len > 0:
    return explicit
  let h = getEnv("COMPUTERNAME")
  if h.len > 0: h else: "localhost"

proc resolveProfilePath(flags: InfraCliFlags; stateDir: string): string =
  if flags.profilePath.len > 0:
    return flags.profilePath
  systemProfilePath(stateDir)

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
    elif a == "--host": result.flags.host = valueOf()
    elif a.startsWith("--host="):
      result.flags.host = a["--host=".len .. ^1]
    elif a == "--plan": result.flags.planId = valueOf()
    elif a.startsWith("--plan="):
      result.flags.planId = a["--plan=".len .. ^1]
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
  let originalText = readFile(profilePath)
  # M83 Phase F3: compile-then-adapt is the ONLY path; a compile
  # failure exits non-zero with a uniform actionable error.
  var profileText: string
  if not resolveSystemProfileText(profilePath, originalText, stateDir,
      "repro infra plan", profileText,
      planCommand = "repro infra plan"):
    return 1
  let host = hostIdentity(flags.host)
  ensureSystemStateDir(stateDir)
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
  ## The `repro` binary the broker re-execs. Use the current
  ## executable's own path.
  getAppFilename()

proc runInfraApply(args: openArray[string]): int =
  let (flags, positional) = parseInfraFlags(args)
  let stateDir = (if flags.stateDir.len > 0: flags.stateDir
                  else: resolveSystemStateDir())
  setStateDirOverride(stateDir)
  let profilePath = resolveProfilePath(flags, stateDir)
  if not fileExists(profilePath):
    stderr.writeLine("repro infra apply: no system profile at " &
      profilePath)
    return 1
  let originalText = readFile(profilePath)
  # M83 Phase F3: compile-then-adapt is the ONLY path; a compile
  # failure exits non-zero with a uniform actionable error.
  var profileText: string
  var profileBuildActions: seq[ProfileBuildAction]
  if not resolveSystemProfileText(profilePath, originalText, stateDir,
      "repro infra apply", profileText,
      planCommand = "repro infra plan",
      outBuildActions = addr profileBuildActions):
    return 1
  let host = hostIdentity(flags.host)

  var planId = flags.planId
  if planId.len == 0 and positional.len > 0:
    planId = positional[0]
  if planId.len == 0 and not flags.noPreview:
    stderr.writeLine("repro infra apply: no plan id given; either run " &
      "`repro infra plan` first and pass --plan <id>, or pass " &
      "--no-preview to compute and apply a fresh plan without preview.")
    return 2

  if not acquireApplyLock(stateDir):
    stderr.writeLine("repro infra apply: another system apply is in " &
      "progress (lock held at " & applyLockPath(stateDir) & ").")
    return 1
  defer: releaseApplyLock(stateDir)

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
  for rec in auditResult.records:
    let ts = $fromUnix(rec.timestamp).utc()
    echo "  [" & ts & "] " & rec.outcome & "  " & rec.operationKind &
      "  " & rec.resourceAddress
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
  let originalText = readFile(profilePath)
  # M83 Phase F3: compile-then-adapt is the ONLY path; a compile
  # failure exits non-zero with a uniform actionable error.
  var profileText: string
  var profileBuildActions: seq[ProfileBuildAction]
  if not resolveSystemProfileText(profilePath, originalText, stateDir,
      "repro system sync", profileText,
      planCommand = "repro infra plan",
      outBuildActions = addr profileBuildActions):
    return 1
  let host = hostIdentity(flags.host)
  if not acquireApplyLock(stateDir):
    stderr.writeLine("repro system sync: another system apply is in " &
      "progress (lock held at " & applyLockPath(stateDir) & ").")
    return 1
  defer: releaseApplyLock(stateDir)
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
  var applyResult: ApplyResult
  try:
    applyResult = runInfraApply(profileText, opts)
  except EInfra as e:
    stderr.writeLine("repro system sync: " & e.msg)
    return 1
  echo "repro system sync"
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
      " no-op=" & $rec.envelope.noOpCount
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
  if not acquireApplyLock(stateDir):
    stderr.writeLine("repro system rollback: another system apply is in " &
      "progress (lock held at " & applyLockPath(stateDir) & ").")
    return 1
  defer: releaseApplyLock(stateDir)
  var opts: SystemRollbackOptions
  opts.stateDir = stateDir
  opts.hostIdentity = hostIdentity(flags.host)
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
       irfDiskoLoadFailed: return 1
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

proc runInfraCommand*(args: seq[string]): int =
  ## `repro infra <subcommand>`.
  if args.len == 0:
    stderr.writeLine("usage: repro infra {plan | apply | install-root} ...")
    return 2
  let sub = args[0]
  let rest = if args.len > 1: args[1 .. ^1] else: @[]
  try:
    case sub
    of "plan": return runInfraPlan(rest)
    of "apply": return runInfraApply(rest)
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
      "sync | history | rollback | audit} ...")
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
    of "rollback": return runSystemRollbackCmd(rest)
    of "audit": return runSystemAudit(rest)
    else:
      stderr.writeLine("repro system: unknown subcommand: " & sub)
      return 2
  except ValueError as e:
    stderr.writeLine("repro system " & sub & ": " & e.msg)
    return 2
  except CatchableError as e:
    stderr.writeLine("repro system " & sub & ": error: " & e.msg)
    return 1
