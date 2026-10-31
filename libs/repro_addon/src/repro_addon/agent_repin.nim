## ``repro system addon agent-repin`` (spec §9.1, "Re-pinning the origins"):
## resolve the deploy agent's origins again and move the fetch unit's
## egress allow-list and its private hosts file to the addresses they have
## now.
##
## Bootstrap resolves every origin -- each manifest source, each binary
## cache -- once, and generation 0 pins the addresses: the fetch unit has no
## DNS (its ``IPAddressAllow=`` takes addresses, and its ``/etc/hosts`` is
## the add-on's ``/etc/repro/agent-hosts``). When an origin moves, the agent
## can no longer reach it, by design, and only an operator on the host may
## move the pins: a manifest may not (the two objects are the agent's
## confinement, which no profile supersedes, §9 "Generation-0 objects a
## profile supersedes").
##
## Without ``--apply`` the verb prints the plan -- the old and new
## allow-list and hosts lines -- and its digest, and writes nothing.
## ``--apply <digest>`` re-resolves, refuses when the result is not the plan
## that digest names (the names resolved differently in between), and runs
## one add-on switch with generation 0's own objects re-rendered: ledgered,
## retained, reachable by ``repro system rollback`` like every other switch.
## Nothing else in generation 0 changes.

import std/[algorithm, os, strutils]

import repro_binary_cache_client/caches_config

import ./addon_apply
import ./agent_split
import ./fingerprint
import ./generation0
import ./preflight

type
  RepinPlan* = object
    ownText*: string          ## the own profile with the re-pinned objects
    changed*: bool
    diff*: seq[string]        ## "-" / "+" lines of the two objects
    digest*: string           ## what ``--apply`` must name

  RepinError* = object of CatchableError

const UnitBlockHead = "systemd.systemUnit {\n  name = \""

proc blockBounds(own, head: string): tuple[a, b: int] =
  ## The ``[a, b)`` span of the canonical block that starts with ``head``
  ## (``renderOwnProfile``'s layout: a block ends at the first "\n}\n").
  let a = own.find(head)
  if a < 0: return (-1, -1)
  let e = own.find("\n}\n", a)
  if e < 0:
    raise newException(RepinError, "the own profile's block at byte " & $a &
      " is not terminated")
  (a, e + 3)

proc unitContentOf(own, unit: string): string =
  let (a, b) = blockBounds(own, UnitBlockHead & unit & "\"\n")
  if a < 0: return ""
  let block0 = own[a ..< b]
  let k = block0.find("  content = \"")
  let e = block0.rfind("\"\n  enabled = ")
  if k < 0 or e < 0: return ""
  block0[k + "  content = \"".len ..< e]

proc lineDiff(what, old, new: string): seq[string] =
  let o = old.splitLines()
  let n = new.splitLines()
  for l in o:
    if l.len > 0 and l notin n: result.add(what & ": - " & l)
  for l in n:
    if l.len > 0 and l notin o: result.add(what & ": + " & l)

proc hostsLines(text: string): string =
  ## The address lines of a hosts file.
  for l in text.splitLines():
    if l.strip().len > 0 and not l.strip().startsWith("#"):
      result.add(l & "\n")

proc execStartExe(unitContent: string): string =
  for l in unitContent.splitLines():
    if l.startsWith("ExecStart="):
      return l["ExecStart=".len .. ^1].splitWhitespace()[0]
  ""

proc repinOwnProfile*(own: string; fresh: AgentUnitsInputs;
                      currentHosts: string): RepinPlan =
  ## Re-render the fetch unit and the agent's hosts file in ``own`` (the
  ## stored own profile) for ``fresh`` origins. Pure: the caller resolved
  ## the names and read the current hosts file (``currentHosts``).
  let oldUnit = unitContentOf(own, AgentFetchUnit)
  if oldUnit.len == 0:
    raise newException(RepinError, "generation 0 carries no deploy agent " &
      "(no " & AgentFetchUnit & " in the own profile); nothing to re-pin")
  let reproExe = execStartExe(oldUnit)
  if reproExe.len == 0:
    raise newException(RepinError, AgentFetchUnit & " names no ExecStart")
  let newUnit = agentFetchUnit(reproExe, fresh)
  # Without its comment lines: a '#' cannot be carried inline in the
  # canonical text, and the hosts file is carried inline from now on.
  let newHosts = hostsLines(renderAgentHosts(fresh))
  assertInlineSafe("unit " & AgentFetchUnit, newUnit)
  assertInlineSafe(AgentHostsPath, newHosts)
  result.ownText = own
  # The unit's content, in place.
  let (ua, ub) = blockBounds(own, UnitBlockHead & AgentFetchUnit & "\"\n")
  let oldBlock = own[ua ..< ub]
  let newBlock = oldBlock.replace("  content = \"" & oldUnit & "\"",
                                  "  content = \"" & newUnit & "\"")
  result.ownText = own[0 ..< ua] & newBlock & own[ub .. ^1]
  # The hosts file: carried inline from now on (generation 0's copy is a
  # body in its files prefix, which re-pinning does not rewrite).
  let hostsBlock = "fs.systemFile {\n  path = \"" & AgentHostsPath &
    "\"\n  content = \"" & newHosts & "\"\n}\n"
  let (ha, hb) = blockBounds(result.ownText, "fs.systemFile {\n  path = \"" &
                             AgentHostsPath & "\"\n")
  if ha >= 0:
    result.ownText = result.ownText[0 ..< ha] & hostsBlock &
                     result.ownText[hb .. ^1]
  elif fresh.hosts.len > 0:
    result.ownText.add("\n" & hostsBlock)
  result.diff = lineDiff(AgentFetchUnit, oldUnit, newUnit) &
                lineDiff(AgentHostsPath, hostsLines(currentHosts), newHosts)
  result.changed = result.diff.len > 0
  result.digest = sha256Hex(result.ownText)

proc freshAgentInputs*(): AgentUnitsInputs =
  ## The origins resolved now: every manifest source in ``agent.conf`` and
  ## every cache ``caches.conf`` names.
  let conf = loadAgentConf()
  result = resolveAgentInputs(conf.target, conf.sources, "",
                              conf.profileCompiler)
  if fileExists(CachesConfPath):
    for c in parseCachesFile(CachesConfPath):
      let extra = resolveAgentInputs(conf.target, @[c.url], "", "")
      for a in extra.allowedAddresses:
        if a notin result.allowedAddresses: result.allowedAddresses.add(a)
      for h in extra.hosts:
        if h notin result.hosts: result.hosts.add(h)
  result.allowedAddresses.sort()
  result.hosts.sort()

proc runAgentRepinCli*(args: seq[string]): int =
  ## ``repro system addon agent-repin [--apply <digest>]``.
  var applyDigest = ""
  var i = 0
  while i < args.len:
    if args[i] == "--apply" and i + 1 < args.len:
      applyDigest = args[i + 1]
      i += 2
    else:
      stderr.write("usage: repro system addon agent-repin [--apply <digest>]\n")
      return 2
  if not fileExists(AgentConfPath):
    stderr.write("repro system addon agent-repin: no deploy agent is " &
      "configured (" & AgentConfPath & " is missing)\n")
    return 1
  let own = readFile(ownProfilePath(DefaultStateDir))
  let hostsNow = if fileExists(AgentHostsPath): readFile(AgentHostsPath)
                 else: ""
  let plan = repinOwnProfile(own, freshAgentInputs(), hostsNow)
  if not plan.changed:
    stdout.write("the deploy agent's origins resolve to the pinned " &
      "addresses; nothing to re-pin\n")
    return 0
  for l in plan.diff: stdout.write(l & "\n")
  if applyDigest.len == 0:
    stdout.write("plan " & plan.digest & "; nothing was written. Apply " &
      "it with: repro system addon agent-repin --apply " & plan.digest & "\n")
    return 0
  if applyDigest != plan.digest:
    stderr.write("repro system addon agent-repin: the origins resolve to " &
      "something other than plan " & applyDigest & " now (plan " &
      plan.digest & "); review it and apply that one\n")
    return 1
  let userText = if fileExists(userProfilePath(DefaultStateDir)):
                   readFile(userProfilePath(DefaultStateDir)) else: ""
  let r = runAddonApply(AddonApplyOptions(stateDir: DefaultStateDir,
    hostIdentity: readHostname(), userProfileText: userText,
    ownProfileText: plan.ownText))
  stdout.write("re-pinned the deploy agent's origins: add-on generation " &
    r.generationId & "\n")
  0
