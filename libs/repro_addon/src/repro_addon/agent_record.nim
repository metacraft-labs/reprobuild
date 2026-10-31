## What a deploy-agent apply records in the add-on generation it commits
## (ReproOS Add-On Mode §7.4: "the deploy-agent `deploymentId` and sequence,
## when the apply came from the agent"), and the operator's `pause` marker
## that holds the agent after a local rollback (§9.3).
##
## The record is `generations/<id>/addon-agent`, beside the generation's
## ledger, profiles and base identity, written when the generation commits.
## A generation without one was applied by an operator (or by bootstrap).
##
## The pause itself is the deploy agent's own marker; this module finds every
## agent of the host so an operator rollback can pause all of them (see the
## section below).

import std/[os, strutils]

import repro_deploy_agent/agent
import repro_infra

import ./ledger

const
  AgentRecordName* = "addon-agent"
  AgentRecordHeader* = "# repro-addon-agent v1"

type
  AgentRecord* = object
    deploymentId*: string
    sequence*: uint64
    migratedFrom*: string
      ## The agent generation (in the agent's own state directory) this
      ## add-on generation took over, when it is the migration of a host
      ## whose agent applied outside the add-on switch (§9, "Migration").

  AgentRecordError* = object of CatchableError

proc present*(r: AgentRecord): bool =
  r.deploymentId.len > 0 or r.sequence > 0'u64 or r.migratedFrom.len > 0

proc oneLine(v, what: string): string =
  if '\n' in v or '\r' in v or '\t' in v:
    raise newException(AgentRecordError, what & " holds a line break or " &
      "a tab: " & v.escape)
  v

proc render*(r: AgentRecord): string =
  result = AgentRecordHeader & "\n"
  result.add("deployment\t" & oneLine(r.deploymentId, "deploymentId") & "\n")
  result.add("sequence\t" & $r.sequence & "\n")
  if r.migratedFrom.len > 0:
    result.add("migrated-from\t" & oneLine(r.migratedFrom, "migratedFrom") &
      "\n")

proc parseAgentRecord*(text: string): AgentRecord =
  let lines = text.splitLines()
  if lines.len == 0 or lines[0] != AgentRecordHeader:
    raise newException(AgentRecordError, "not a repro-addon agent record")
  for i in 1 ..< lines.len:
    if lines[i].len == 0: continue
    let f = lines[i].split('\t', 1)
    if f.len != 2:
      raise newException(AgentRecordError, "malformed agent record line " &
        $(i + 1))
    case f[0]
    of "deployment": result.deploymentId = f[1]
    of "sequence":
      try: result.sequence = parseBiggestUInt(f[1]).uint64
      except ValueError:
        raise newException(AgentRecordError, "malformed sequence " & f[1])
    of "migrated-from": result.migratedFrom = f[1]
    else: discard              # a later field; this build does not need it

proc agentRecordPath*(stateDir, generationId: string): string =
  generationDir(stateDir, generationId) / AgentRecordName

proc readAgentRecord*(stateDir, generationId: string): AgentRecord =
  ## The generation's agent record; an empty one (``present`` false) when
  ## the generation did not come from the agent or the record is unreadable.
  try: parseAgentRecord(readFile(agentRecordPath(stateDir, generationId)))
  except CatchableError: AgentRecord()

proc anyAgentGeneration*(stateDir: string): bool =
  ## Whether any generation of this add-on state carries an agent record:
  ## the agent has applied through the switch here at least once.
  let root = generationsRoot(stateDir)
  if not dirExists(root): return false
  for kind, p in walkDir(root):
    if kind == pcDir and fileExists(p / AgentRecordName):
      return true
  false

# ---------------------------------------------------------------------------
# Pausing the agents of this host (§9.3).
#
# The marker is the deploy agent's own (`repro_deploy_agent/agent`,
# `<agent state>/deploy-agent/pause`): every tick of that agent reads it and
# reports ``aoPaused``. The operator's `repro system rollback` knows the
# add-on's state directory, not the agents' flags, so every agent that
# applies through the switch registers its state directory with the add-on
# (`<stateDir>/addon/agent-state-dirs`), and a rollback pauses each one
# registered there, together with the two agent states an add-on host has
# by construction (the A8 split's `/var/lib/repro/agent` and the
# single-process agent's `/var/lib/repro/agent/state`) where they exist.
# ---------------------------------------------------------------------------

const
  AgentStatesName* = "agent-state-dirs"
  WellKnownAgentStates* = ["/var/lib/repro/agent",
                           "/var/lib/repro/agent/state"]

proc agentStatesPath*(stateDir: string): string =
  stateDir / "addon" / AgentStatesName

proc registeredAgentStates*(stateDir: string): seq[string] =
  try:
    for l in readFile(agentStatesPath(stateDir)).splitLines():
      let d = l.strip()
      if d.len > 0 and d.isAbsolute and d notin result: result.add(d)
  except IOError, OSError:
    discard

proc registerAgentState*(stateDir, agentStateDir: string) =
  ## Record that an agent with state ``agentStateDir`` applies here (the
  ## agent's apply hook calls this on every apply; idempotent).
  let d = absolutePath(agentStateDir)
  var known = registeredAgentStates(stateDir)
  if d in known: return
  known.add(d)
  let path = agentStatesPath(stateDir)
  createDir(parentDir(path))
  # Durable like every other add-on record (the file and its directory
  # fsynced around the rename): a power cut after the agent's apply must
  # not lose the registration a later rollback pauses it through.
  writeFileAtomic(path, known.join("\n") & "\n", 0o644)

proc agentStatesToPause*(stateDir: string): seq[string] =
  ## Every agent state directory on this host a pause must reach.
  result = registeredAgentStates(stateDir)
  for d in WellKnownAgentStates:
    if dirExists(d) and d notin result: result.add(d)

proc currentOperator*(): string =
  ## Who ran the command: the sudo caller when there is one.
  for v in ["SUDO_USER", "LOGNAME", "USER"]:
    let s = getEnv(v).strip()
    if s.len > 0 and '\n' notin s and '=' notin s: return s
  "uid " & $getCurrentProcessId()

proc pauseAgents*(stateDir, generation: string;
                  operator = currentOperator()): seq[string] =
  ## Pause every agent of this host (an operator rollback, §9.3); returns
  ## the agent state directories paused.
  for d in agentStatesToPause(stateDir):
    writePauseMarker(d, generation, operator)
    result.add(d)

proc resumeAgents*(stateDir: string): seq[string] =
  ## ``repro system addon resume``: the agent states whose pause was lifted.
  for d in agentStatesToPause(stateDir):
    if clearPauseMarker(d): result.add(d)
