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

# ---------------------------------------------------------------------------
# Shared option parsing.
# ---------------------------------------------------------------------------

type
  InfraCliFlags = object
    stateDir: string
    profilePath: string
    host: string
    planId: string
    noElevate: bool
    noPreview: bool
    acceptFeatureDestroy: bool

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
    elif a == "--no-elevate": result.flags.noElevate = true
    elif a == "--elevate": result.flags.noElevate = false
    elif a == "--no-preview": result.flags.noPreview = true
    elif a == "--accept-feature-destroy":
      result.flags.acceptFeatureDestroy = true
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
  let profileText = readFile(profilePath)
  let host = hostIdentity(flags.host)
  let planResult = producePlan(profileText, host)
  let env = planResult.envelope
  ensureSystemStateDir(stateDir)
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
  let profileText = readFile(profilePath)
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

  var applyResult: ApplyResult
  try:
    applyResult = runInfraApply(profileText, opts)
  except EPlanStale as e:
    stderr.writeLine("repro infra apply: " & e.msg)
    for a in e.drifted:
      stderr.writeLine("  drifted: " & a)
    return 3
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

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------

proc runInfraCommand*(args: seq[string]): int =
  ## `repro infra <subcommand>`.
  if args.len == 0:
    stderr.writeLine("usage: repro infra {plan | apply} ...")
    return 2
  let sub = args[0]
  let rest = if args.len > 1: args[1 .. ^1] else: @[]
  try:
    case sub
    of "plan": return runInfraPlan(rest)
    of "apply": return runInfraApply(rest)
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
  ## `repro system <subcommand>`. M69 Phase A: only `audit` is wired;
  ## the `add/remove/list/why/sync/history/rollback` profile-editing
  ## family is deferred to a later phase.
  if args.len == 0:
    stderr.writeLine("usage: repro system {audit} ...")
    return 2
  let sub = args[0]
  let rest = if args.len > 1: args[1 .. ^1] else: @[]
  try:
    case sub
    of "audit": return runSystemAudit(rest)
    of "add", "remove", "list", "why", "sync", "history", "rollback":
      stderr.writeLine("repro system " & sub & ": the system-profile " &
        "editing command family is deferred to a later M69 phase; " &
        "Phase A applies a hand-authored system.nim via " &
        "`repro infra plan` / `repro infra apply`.")
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
