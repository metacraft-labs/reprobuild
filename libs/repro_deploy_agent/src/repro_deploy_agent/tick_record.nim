## Windows-Runner-Binary-Cache-Deploy — the deploy agent's TICK RECORD
## fan-out.
##
## One tick, three sinks, three different readers:
##
##   * `tick_status`  — `<safe-target>.last-tick.json`, one record,
##     overwritten. What an ALERT reads: "is it broken right now, and how
##     stale is that answer".
##   * `tick_history` — `<safe-target>.tick-history.jsonl`, append-only and
##     bounded. What a HUMAN reads after the alert fires: when it started,
##     whether it flapped, what the last good tick was.
##   * `tick_event_log` — the Windows Application log, Windows only. Where a
##     Windows ADMIN already looks, and the only one of the three that
##     survives the state dir being wiped or read remotely.
##
## They are written independently and every one of them is best effort. A
## sink that cannot be written must not stop the others, must not change the
## tick's exit code, and must not mask the original error — a state dir that
## turns a diagnosable failure into a different failure is worse than no
## state dir at all. `recordTickStatus`, `recordTickHistory` and
## `reportTickEvent` each own that guarantee; this module only fans out.

import ./agent
import ./tick_event_log
import ./tick_history
import ./tick_status

proc recordTick*(stateDir, target: string; rec: TickStatusRecord) =
  ## Fan `rec` out to every sink. Never raises.
  ##
  ## Order is deliberate: the status file first, because it is what a probe
  ## polls and the cheapest thing to get right; then the history, which is
  ## the sink that must survive on a Linux host too; then the Event Log,
  ## which is the one most likely to be refused (privilege) and the one
  ## whose message names the history file the admin should go and read.
  recordTickStatus(stateDir, target, rec)
  recordTickHistory(stateDir, target, rec)
  reportTickEvent(rec, tickHistoryPath(stateDir, target))

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
    recordTick(cfg.stateDir, cfg.target, tickStatusFor(outcome))
  except CatchableError as e:
    # Unchanged semantics: a raised tick is exit 1, the retryable class.
    result = RecordedTick(exitCode: 1, raised: true, error: e.msg)
    recordTick(cfg.stateDir, cfg.target, tickStatusForRaise(cfg.target, e.msg))
