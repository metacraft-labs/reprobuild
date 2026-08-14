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
## 2 = rejected / ambiguous / usage error (non-retryable).

import std/[os, strutils]

import repro_deploy_agent
import repro_deploy_agent/apply_hook

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
      return 2

  let cfg = AgentConfig(
    target: flags.target,
    sources: flags.sources,
    anchors: anchors,
    stateDir: flags.stateDir,
    fetchTimeoutMs: flags.fetchTimeoutMs,
    secretsKeyPath: flags.secretsKey,
    secretsDir: flags.secretsDir)
  let deps = AgentDeps(
    apply: mkRunInfraApplyHook(flags.stateDir, flags.cacheRoot,
      hostIdentity =
        (if flags.hostIdentity.len > 0: flags.hostIdentity
         else: "reprobuild-deploy-agent")))

  let outcome =
    try:
      runAgentTick(cfg, deps)
    except CatchableError as e:
      stderr.writeLine("repro deploy-agent: tick failed: " & e.msg)
      return 1

  echo "repro deploy-agent"
  echo "  target       : " & outcome.target
  echo "  outcome      : " & $outcome.kind
  if outcome.sequence > 0'u64:
    echo "  sequence     : " & $outcome.sequence
  if outcome.deploymentId.len > 0:
    echo "  deployment   : " & outcome.deploymentId
  echo "  message      : " & outcome.message

  case outcome.kind
  of aoApplied, aoConverged, aoWaiting: return 0
  of aoApplyFailed, aoSourceError: return 1
  # `2` is the "operator must act" class, alongside a rejected or ambiguous
  # manifest. A secrets failure is deliberately NOT `1`: retrying on the timer
  # will not fix a wrong recipient key or a missing --secrets-key, and grouping
  # it with the retryable failures would bury it in a loop that never converges.
  of aoRejected, aoAmbiguous, aoSecretsFailed: return 2
