## `repro deploy-agent` CLI surface —
## Windows-Runner-Binary-Cache-Deploy M5.
##
## Thin command layer over ``repro_deploy_agent``. One invocation runs a
## SINGLE agent tick (poll → verify → monotonic apply); a systemd/service
## timer re-invokes it on an interval, mirroring the Linux
## ``mcl-deploy-agent`` oneshot + timer shape (see nixos-modules
## ``modules/deployment/pull-agent.nix``). The tick:
##
##   * polls every ``--manifest <PATH|URL>`` source,
##   * verifies each against the ``--allowed-signers <FILE>`` set (one
##     130-char hex ECDSA-P256 pubkey per line — the cache's trust-anchor
##     format),
##   * applies the highest valid sequence for ``--target`` via the M4
##     ``runInfraApply`` path (build-action outputs substituted from the
##     binary cache when ``REPRO_BINARY_CACHE_URL`` is set).
##
## Exit codes: 0 = applied OR already-converged OR waiting (nothing to do
## yet); 1 = apply failed / source error (retryable — the timer retries);
## 2 = rejected / ambiguous / usage error (non-retryable). The outcome →
## code mapping itself is ``deployAgentExitCode`` in
## ``repro_deploy_agent/tick_status``, shared with the status record so the
## number an operator reads from ``LastTaskResult`` and the number in the
## record are the same number by construction.
##
## Every tick also leaves a durable, machine-readable record of its outcome
## at ``<stateDir>/deploy-agent/<safe-target>.last-tick.json`` — on FAILURE
## and success alike. Under Task Scheduler (how the ``windowsScheduledTask``
## resource deploys this loop) stdout and stderr are discarded, so the echoes
## below are not observability; that file is. See ``tick_status.nim`` for the
## incident that made it necessary.

import std/[os, strutils]

import repro_deploy_agent
import repro_deploy_agent/apply_hook
import repro_profile
import ./infra

type
  DeployAgentFlags = object
    target: string
    sources: seq[string]
    allowedSigners: string
    stateDir: string
    cacheRoot: string
    fetchTimeoutMs: int
    hostIdentity: string
    secretsKey: string
    secretsDir: string

proc parseFlags(args: openArray[string]): DeployAgentFlags =
  result.fetchTimeoutMs = 30_000
  result.hostIdentity = ""
  var i = 0
  proc need(i: var int; name: string; args: openArray[string]): string =
    inc i
    if i >= args.len:
      raise newException(ValueError, name & " requires a value")
    args[i]
  while i < args.len:
    let a = args[i]
    case a
    of "--target": result.target = need(i, a, args)
    of "--manifest": result.sources.add(need(i, a, args))
    of "--allowed-signers": result.allowedSigners = need(i, a, args)
    of "--state-dir": result.stateDir = need(i, a, args)
    of "--cache-root": result.cacheRoot = need(i, a, args)
    of "--host": result.hostIdentity = need(i, a, args)
    of "--secrets-key": result.secretsKey = need(i, a, args)
    of "--secrets-dir": result.secretsDir = need(i, a, args)
    of "--fetch-timeout-ms":
      result.fetchTimeoutMs = parseInt(need(i, a, args))
    else:
      if a.startsWith("--target="): result.target = a["--target=".len .. ^1]
      elif a.startsWith("--manifest="):
        result.sources.add(a["--manifest=".len .. ^1])
      elif a.startsWith("--allowed-signers="):
        result.allowedSigners = a["--allowed-signers=".len .. ^1]
      elif a.startsWith("--state-dir="):
        result.stateDir = a["--state-dir=".len .. ^1]
      elif a.startsWith("--cache-root="):
        result.cacheRoot = a["--cache-root=".len .. ^1]
      elif a.startsWith("--host="):
        result.hostIdentity = a["--host=".len .. ^1]
      elif a.startsWith("--secrets-key="):
        result.secretsKey = a["--secrets-key=".len .. ^1]
      elif a.startsWith("--secrets-dir="):
        result.secretsDir = a["--secrets-dir=".len .. ^1]
      elif a.startsWith("--fetch-timeout-ms="):
        result.fetchTimeoutMs = parseInt(a["--fetch-timeout-ms=".len .. ^1])
      else:
        raise newException(ValueError, "unknown flag: " & a)
    inc i

proc runDeployAgentCommand*(args: seq[string]): int =
  ## ``repro deploy-agent`` entrypoint (one tick).
  var flags: DeployAgentFlags
  try:
    flags = parseFlags(args)
  except ValueError as e:
    stderr.writeLine("repro deploy-agent: " & e.msg)
    return 2

  if flags.target.len == 0:
    stderr.writeLine("repro deploy-agent: --target is required")
    return 2
  if flags.sources.len == 0:
    stderr.writeLine("repro deploy-agent: at least one --manifest is required")
    return 2
  if flags.allowedSigners.len == 0:
    stderr.writeLine("repro deploy-agent: --allowed-signers is required")
    return 2
  if flags.stateDir.len == 0:
    flags.stateDir = getCurrentDir() / ".repro-deploy-agent"
  if flags.cacheRoot.len == 0:
    flags.cacheRoot = flags.stateDir / "cache"
  # `--secrets-dir` defaults, but `--secrets-key` deliberately does NOT: a box
  # that is meant to receive secrets and was started without its key must fail
  # loudly on the first sealed manifest (`secrets_not_configured`), not fall
  # back to some conventional path and then report a decrypt error that reads
  # like key corruption.
  if flags.secretsKey.len > 0 and flags.secretsDir.len == 0:
    flags.secretsDir = flags.stateDir / "secrets"
  if flags.secretsKey.len == 0 and flags.secretsDir.len > 0:
    stderr.writeLine("repro deploy-agent: --secrets-dir given without " &
      "--secrets-key; the directory alone cannot open a sealed section")
    return 2

  let anchors =
    try:
      loadAllowedSigners(flags.allowedSigners)
    except CatchableError as e:
      stderr.writeLine("repro deploy-agent: could not load allowed-signers " &
        "file " & flags.allowedSigners & ": " & e.msg)
      # Recorded, not just printed: an unreadable trust-anchor file wedges the
      # loop exactly as hard as a failing apply, and this is the first point
      # at which both the state dir and the target are known. Exit code
      # unchanged (2 — the operator must act).
      var rec = tickStatusForRaise(flags.target,
        "could not load allowed-signers file " & flags.allowedSigners &
          ": " & e.msg)
      rec.exitCode = 2
      rec.errorCode = "allowed_signers_unreadable"
      recordTickStatus(flags.stateDir, flags.target, rec)
      return 2

  let cfg = AgentConfig(
    target: flags.target,
    sources: flags.sources,
    anchors: anchors,
    stateDir: flags.stateDir,
    fetchTimeoutMs: flags.fetchTimeoutMs,
    secretsKeyPath: flags.secretsKey,
    secretsDir: flags.secretsDir)
  # Compile the manifest's profile through the SAME Phase-F3 path
  # `repro infra apply` uses. Without this the agent hands raw `system.nim`
  # source to a parser that expects canonical resource text, and every real
  # profile dies on `import repro_profile` at line 1.
  #
  # It is wired here, rather than imported inside `apply_hook`, because
  # `resolveSystemProfileText` lives next door in `./infra` and
  # `repro_cli_support` already depends on `repro_deploy_agent` — importing
  # upward from the hook would close a cycle.
  #
  # The compiler needs a FILE, so the text is staged under the state dir. It is
  # written on every tick and deliberately not cached on content: the compile
  # step downstream keys its own cache on the profile's sources, so a repeat
  # tick with an unchanged profile still short-circuits there.
  let capturedStateDir = flags.stateDir
  let resolver: ProfileResolver = proc(profileText: string; outText: var string;
                                       outBuildActions: var seq[ProfileBuildAction]):
                                    bool {.gcsafe.} =
    {.cast(gcsafe).}:
      let scratch = capturedStateDir / "deploy-agent"
      createDir(scratch)
      # Must be `.nim` and a valid Nim module name — the compiler rejects a
      # hyphenated stem outright.
      let profilePath = scratch / "manifest_profile.nim"
      writeFile(profilePath, profileText)
      result = resolveSystemProfileText(profilePath, profileText,
        capturedStateDir, "repro deploy-agent", outText,
        planCommand = "repro infra plan",
        outBuildActions = addr outBuildActions)

  let deps = AgentDeps(
    apply: mkRunInfraApplyHook(flags.stateDir, flags.cacheRoot,
      hostIdentity =
        (if flags.hostIdentity.len > 0: flags.hostIdentity
         else: "reprobuild-deploy-agent"),
      profileResolver = resolver))

  # `runAgentTickRecorded`, not `runAgentTick`: it runs the same tick, resolves
  # the same exit code, and additionally leaves the durable record — including
  # on the path where the tick RAISED and this command used to return 1 having
  # written nothing anywhere. Writing the record is best-effort inside, so it
  # can neither change the code returned here nor mask the error below.
  let tick = runAgentTickRecorded(cfg, deps)
  if tick.raised:
    stderr.writeLine("repro deploy-agent: tick failed: " & tick.error)
    return tick.exitCode

  let outcome = tick.outcome
  echo "repro deploy-agent"
  echo "  target       : " & outcome.target
  echo "  outcome      : " & $outcome.kind
  if outcome.sequence > 0'u64:
    echo "  sequence     : " & $outcome.sequence
  if outcome.deploymentId.len > 0:
    echo "  deployment   : " & outcome.deploymentId
  echo "  message      : " & outcome.message
  echo "  status file  : " & tickStatusPath(cfg)

  # 0 for aoApplied/aoConverged/aoWaiting, 1 for aoApplyFailed/aoSourceError,
  # 2 for aoRejected/aoAmbiguous/aoSecretsFailed — see `deployAgentExitCode`,
  # which carries the rationale for each class (in particular why a secrets
  # failure is deliberately NOT the retryable 1).
  return tick.exitCode
