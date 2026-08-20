## Windows-Runner-Binary-Cache-Deploy — the deploy agent's DURABLE TICK RECORD.
##
## WHY THIS MODULE EXISTS, in one incident.
##
## win-ci-bare-001, 2026-08-19/20: every ten-minute tick failed for THIRTEEN
## HOURS while the box looked healthy. `nim` was absent from the SYSTEM PATH,
## so `requireNimOnPath` raised inside the profile compile and no manifest
## could be applied. Everything the agent had to say about that went to
## stdout/stderr — and the converge loop is deployed as a Task Scheduler task
## (see the `windowsScheduledTask` resource), which DISCARDS both. The only
## observable symptoms were `LastTaskResult 0x1` and a `current.txt` that
## quietly stopped advancing. The error text survived by pure chance, in the
## build engine's per-action log, which is not the agent's log at all; a
## failure in fetch, verification or secrets would have left nothing.
##
## The state dir was no help either, because everything the agent persists —
## `<target>.seq`, `current.txt`, the generation tree — advances only on
## SUCCESS. On failure the state dir is byte-identical to the previous tick,
## so "converged two minutes ago" and "last succeeded thirteen hours ago" are
## indistinguishable from the outside.
##
## Worse, a WARM PROFILE CACHE masks this whole class: while desired state is
## unchanged the compiler is never invoked and every tick reports success. The
## box breaks precisely when new desired state arrives.
##
## So: every tick — success, failure, and the raise that never produced an
## outcome at all — leaves ONE machine-readable record at
##
##     <stateDir>/deploy-agent/<safe-target>.last-tick.json
##
## next to the `<safe-target>.seq` file it mirrors, carrying the timestamp,
## the outcome kind, the process exit code, the target, the sequence /
## deployment id where known, the human message, and the exception text when
## the tick raised. A monitoring probe reads exactly one file and can answer
## both "did the last tick converge?" and "how old is that answer?".
##
## Two properties are load-bearing and both are pinned by
## `t_repro_deploy_agent_records_tick_status`:
##
##   * ATOMIC. The record is staged at `<path>.tmp` and renamed into place.
##     A probe polling on its own schedule must never read a torn file, and a
##     crash mid-write must leave the PREVIOUS record intact rather than
##     destroying the only evidence of the last failure.
##   * BEST EFFORT. Writing the record must never change the tick's exit code
##     nor mask the original error — a status file that turns a diagnosable
##     failure into a different failure is worse than no status file.

import std/[json, os, times]

import ./agent

const
  TickStatusSchemaId* = "reprobuild.deploy-agent.tick-status.v1"
    ## Envelope identity, per the repo's `reprobuild.<domain>.<thing>.v<N>`
    ## convention (cf. `reprobuild.daemon.stats-observation.v1`). A reader
    ## that does not recognise it must refuse to interpret the fields.
  TickStatusSchemaVersion* = 1

  TickRaisedOutcome* = "tickRaised"
    ## The `outcome` value used when the tick raised BEFORE producing an
    ## `AgentOutcome`. Deliberately not one of the `AgentOutcomeKind` names:
    ## an operator must be able to tell "the agent decided this" from "the
    ## agent fell over", and a probe must not have to guess.

  TickStatusFileSuffix* = ".last-tick.json"

type
  TickStatusRecord* = object
    ## One tick's outcome, as persisted. Field names are camelCase to match
    ## every other JSON state file in the repo.
    timestamp*: string           ## ISO-8601 UTC, `yyyy-MM-ddTHH:mm:ssZ`
    timestampUnix*: int64        ## same instant, for staleness arithmetic
    outcome*: string             ## an `AgentOutcomeKind` name, or `tickRaised`
    exitCode*: int               ## the code the process is about to return
    target*: string
    sequence*: uint64            ## selected/applied sequence, 0 when none
    deploymentId*: string
    message*: string             ## the human-readable outcome message
    errorCode*: string           ## the machine-readable outcome error code
    error*: string               ## exception text; empty unless the tick raised

  RecordedTick* = object
    ## What `runAgentTickRecorded` observed. `raised` distinguishes "the tick
    ## produced this outcome" from "the tick threw and `outcome` is unset" —
    ## callers must not read `outcome` when `raised` is true.
    outcome*: AgentOutcome
    exitCode*: int
    raised*: bool
    error*: string

proc tickStatusPath*(stateDir, target: string): string =
  ## Sibling of `sequenceStatePath` — same directory, same per-target
  ## filesystem-safe stem, so two targets sharing a state dir cannot
  ## clobber each other's record.
  stateDir / "deploy-agent" / (safeTargetName(target) & TickStatusFileSuffix)

proc tickStatusPath*(cfg: AgentConfig): string =
  tickStatusPath(cfg.stateDir, cfg.target)

proc deployAgentExitCode*(kind: AgentOutcomeKind): int =
  ## The tick's process exit code. THE mapping — `repro deploy-agent` returns
  ## this and the status record reports the same number, so an operator
  ## reading `LastTaskResult` and an operator reading the record can never be
  ## told two different stories.
  ##
  ## 0 = applied OR already-converged OR waiting (nothing to do yet);
  ## 1 = apply failed / source error (retryable — the timer retries);
  ## 2 = rejected / ambiguous (non-retryable).
  case kind
  of aoApplied, aoConverged, aoWaiting: 0
  of aoApplyFailed, aoSourceError: 1
  # `2` is the "operator must act" class, alongside a rejected or ambiguous
  # manifest. A secrets failure is deliberately NOT `1`: retrying on the timer
  # will not fix a wrong recipient key or a missing --secrets-key, and grouping
  # it with the retryable failures would bury it in a loop that never converges.
  of aoRejected, aoAmbiguous, aoSecretsFailed: 2

proc toJsonNode*(rec: TickStatusRecord): JsonNode =
  %*{
    "schemaId": TickStatusSchemaId,
    "schemaVersion": TickStatusSchemaVersion,
    "timestamp": rec.timestamp,
    "timestampUnix": rec.timestampUnix,
    "outcome": rec.outcome,
    "exitCode": rec.exitCode,
    "target": rec.target,
    "sequence": int64(rec.sequence),
    "deploymentId": rec.deploymentId,
    "message": rec.message,
    "errorCode": rec.errorCode,
    "error": rec.error
  }

proc renderTickStatus*(rec: TickStatusRecord): string =
  pretty(rec.toJsonNode()) & "\n"

proc stampNow(rec: var TickStatusRecord) =
  let t = getTime()
  rec.timestampUnix = t.toUnix()
  # UTC, and formatted rather than `$`-ed, so the string is stable and
  # machine-readable regardless of the box's locale or timezone.
  rec.timestamp = t.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc tickStatusFor*(outcome: AgentOutcome): TickStatusRecord =
  ## The record for a tick that produced an outcome — of ANY kind. The
  ## non-zero kinds (`aoApplyFailed`, `aoSourceError`, `aoRejected`,
  ## `aoAmbiguous`, `aoSecretsFailed`) are exactly the ones the incident
  ## needed and are not special-cased here.
  result = TickStatusRecord(
    outcome: $outcome.kind,
    exitCode: deployAgentExitCode(outcome.kind),
    target: outcome.target,
    sequence: outcome.sequence,
    deploymentId: outcome.deploymentId,
    message: outcome.message,
    errorCode: outcome.errorCode,
    error: "")
  stampNow(result)

proc tickStatusForRaise*(target, error: string): TickStatusRecord =
  ## The record for a tick that RAISED before producing an outcome. This is
  ## the path that used to leave nothing but a discarded stderr line, so the
  ## exception text is the whole point of it.
  result = TickStatusRecord(
    outcome: TickRaisedOutcome,
    exitCode: 1,
    target: target,
    sequence: 0'u64,
    deploymentId: "",
    message: "tick failed before producing an outcome",
    errorCode: "tick_raised",
    error: error)
  stampNow(result)

proc writeTickStatus*(path: string; rec: TickStatusRecord) =
  ## Write `rec` to `path` ATOMICALLY. Raises on failure — `recordTickStatus`
  ## is the best-effort wrapper callers on the tick path use.
  ##
  ## Staged at `<path>.tmp` in the SAME directory (a cross-directory rename is
  ## not atomic) and renamed over the previous record. The rename is a single
  ## `MoveFileExW(MOVEFILE_REPLACE_EXISTING)` on Windows and `rename(2)` on
  ## POSIX, both of which replace atomically — so, deliberately, NO
  ## remove-then-move: the repo's other atomic writers unlink the destination
  ## first, which opens a window in which neither file exists. That window is
  ## precisely what this record must not have.
  let dir = parentDir(path)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)
  let tmp = path & ".tmp"
  writeFile(tmp, renderTickStatus(rec))
  moveFile(tmp, path)

proc recordTickStatus*(stateDir, target: string; rec: TickStatusRecord) =
  ## BEST EFFORT. Never raises, never changes the caller's exit code.
  ##
  ## A full disk, a read-only state dir or a lost drive must not convert a
  ## diagnosable tick failure into a different, less informative one. The
  ## write failure is announced on stderr — which is discarded under Task
  ## Scheduler, exactly as this file exists to work around, so it is a
  ## courtesy for the interactive case and nothing more.
  try:
    writeTickStatus(tickStatusPath(stateDir, target), rec)
  except CatchableError as e:
    try:
      stderr.writeLine("repro deploy-agent: could not write the tick status " &
        "record at " & tickStatusPath(stateDir, target) & ": " & e.msg)
    except CatchableError:
      discard

proc runAgentTickRecorded*(cfg: AgentConfig; deps: AgentDeps): RecordedTick =
  ## One tick that ALWAYS leaves a durable record — the entry point the CLI
  ## uses. `runAgentTick` itself stays pure with respect to observability so
  ## the hermetic gates that assert on its return value keep working.
  ##
  ## The exit code is resolved here (from `deployAgentExitCode`) rather than
  ## by the caller so the number in the record and the number the process
  ## returns cannot drift apart.
  try:
    let outcome = runAgentTick(cfg, deps)
    result = RecordedTick(outcome: outcome,
      exitCode: deployAgentExitCode(outcome.kind), raised: false, error: "")
    recordTickStatus(cfg.stateDir, cfg.target, tickStatusFor(outcome))
  except CatchableError as e:
    # Unchanged semantics: a raised tick is exit 1, the retryable class.
    result = RecordedTick(exitCode: 1, raised: true, error: e.msg)
    recordTickStatus(cfg.stateDir, cfg.target,
      tickStatusForRaise(cfg.target, e.msg))
