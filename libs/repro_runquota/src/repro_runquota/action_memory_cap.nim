## The per-task memory cap on Reprobuild's actions: what a build resolves
## once, what each action's launch applies, and how a breach is reported.
##
## WHAT THE CAP IS. RunQuota grants each host lease a memory cap (a factor
## times the command's largest successful peak, a declared size, or the
## memory that was free at the grant when no peak is recorded yet). The
## launcher decides what to do with it: the host file's `[enforcement]
## memoryCap` (`off`, `advisory`, `kill`; off when absent) and the per-run
## variable `RUNQUOTA_MEMORY_CAP` (`off`, `advisory`, `kill` or a size).
## RunQuota's own launch library (`runquota_exec/memory_cap_launch`) holds
## the rules; this module applies them to Reprobuild's actions, which
## Reprobuild launches itself rather than through `runquota run`.
##
## THE PLATFORM MECHANISM IS RUNQUOTA'S, and only the cap's: on Linux a
## capped action's tree gets a cgroup v2 leaf of its own under the resolved
## cgroup root, in a directory where no CPU setting is written
## (`memoryOnlyPlacement`), so its CPU placement is what it was without the
## cap; on Windows a Job Object; on macOS a footprint walk of the tree. All
## three are driven by the fields `applyMemoryCap` sets on the launch.
##
## OFF COSTS NOTHING PER ACTION. The host mode and the variable are resolved
## once per build (`currentReproMemoryCapPolicy`); with the mode off and the
## variable unset the policy is inactive, and an action's launch reads no
## file, touches no cgroup and makes no system call for the cap.
##
## THE VARIABLE IS THE ENGINE'S, NEVER THE ACTION'S. An action may declare a
## `RUNQUOTA_MEMORY_CAP` of its own in its environment; that is the value
## its own RunQuota clients see, and it must not decide how the action
## itself is capped. A daemon-hosted build installs the caller's
## environment for the length of the request, so the engine reads the
## caller's value there too.
##
## A cap-exceeded action FAILS, is never retried by the engine and publishes
## nothing (the engine's failure path); its failure carries the report
## below. A cap reached without a kill, or passed in advisory mode, on an
## action that otherwise succeeded is a warning, not a failure.

import std/[json, options, os, strutils]

import runquota_client
import runquota_core/memory_cap
import runquota_daemon/host_config
import runquota_exec/memory_cap_launch
import runquota_process

# The cap's vocabulary (modes, bases, the grant and the finish block) and
# RunQuota's launch rules, for the engine and the command line, which name
# them through this module.
export memory_cap, memory_cap_launch

type
  ReproMemoryCapPolicy* = object
    ## What a build does about the memory cap of its actions, resolved
    ## once per build from the engine's environment and the host file.
    resolved*: bool
      ## Set by every resolution; false only for a policy nobody resolved
      ## (the zero value, which is inactive).
    active*: bool
      ## Whether any action's launch has anything to consider. False when
      ## the host mode is off and `RUNQUOTA_MEMORY_CAP` is unset: then
      ## nothing below is consulted per action.
    hostMode*: MemoryCapMode
      ## `[enforcement] memoryCap` of the host file (`mcmOff` when absent or
      ## unreadable).
    hostProblem*: string
      ## Why the host file could not be read, or "".
    envValue*: string
      ## `RUNQUOTA_MEMORY_CAP` of the engine's environment ("" when unset).
    nested*: bool
      ## The engine itself runs inside a leased tree
      ## (`RUNQUOTA_PARENT_LEASE` set): its launcher's cap already covers
      ## every action, and a cap of the actions' own would move them out of
      ## it, so none is applied.
    cgroupRoot*: CgroupRoot
      ## Linux: the cgroup root a capped action's leaf is placed under, as
      ## RunQuota's launchers resolve it (`RUNQUOTA_CGROUP_ROOT`, else the
      ## host file's `[enforcement] cgroups`). Resolved only for an active,
      ## non-nested policy.
    error*: string
      ## A `RUNQUOTA_MEMORY_CAP` value that is none of the accepted ones:
      ## every action's launch is refused with it, since a switch that
      ## decides whether a tree may be killed must not be guessed at.

  ActionMemoryCap* = object
    ## The memory cap of one action's launch.
    grant*: GrantMemoryCap
      ## The cap the lease was granted with.
    resolution*: MemoryCapResolution
      ## What the launch applies (`resolveMemoryCap`); `applies` false when
      ## the policy is inactive or nothing applies.
    root*: CgroupRoot
      ## The policy's cgroup root, for the reason a Linux cap is not
      ## enforced.

const
  MemoryCapExceededReason* = "memory cap exceeded"
    ## `ActionResult.reason` of an action whose tree its memory cap killed:
    ## what tells it from a command that failed on its own. Its stderr
    ## carries the report (`actionMemoryCapReport`).

proc memoryCapPolicy*(hostMode: MemoryCapMode; envValue: string;
                      nested: bool; cgroupRoot: CgroupRoot;
                      hostProblem = ""): ReproMemoryCapPolicy =
  ## The policy from what `currentReproMemoryCapPolicy` read. Pure.
  result = ReproMemoryCapPolicy(resolved: true, hostMode: hostMode,
    hostProblem: hostProblem, envValue: envValue.strip(), nested: nested,
    cgroupRoot: cgroupRoot)
  result.active = hostMode != mcmOff or result.envValue.len > 0
  if not result.active:
    return
  # The variable's validity does not depend on the grant: checked once.
  result.error = resolveMemoryCap(GrantMemoryCap(known: false), mcmOff,
    result.envValue, nested = false).error

proc currentReproMemoryCapPolicy*(hostConfig = ""): ReproMemoryCapPolicy =
  ## The policy of a build run from this process's environment: the host
  ## file's mode, `RUNQUOTA_MEMORY_CAP`, `RUNQUOTA_PARENT_LEASE`, and, only
  ## when the cap can apply, the cgroup root (as RunQuota's launchers
  ## resolve it, a caller's limited cgroup and the agent session's scope
  ## included). Called once per build. A host file that cannot be read
  ## leaves the cap off, as for every RunQuota launcher: a launch never
  ## fails over a setting it only consults. `hostConfig` names another host
  ## file than the system's (tests); "" is the system's.
  let path = if hostConfig.len > 0: hostConfig else: hostConfigPath
  let envValue = getEnv(MemoryCapEnvVar)
  var problem = ""
  let mode = enforcementMemoryCapMode(problem, path)
  if mode == mcmOff and envValue.strip().len == 0:
    return memoryCapPolicy(mode, "", false,
      CgroupRoot(state: crsOff, reason: "memory cap off"), problem)
  let nested = parentLeaseFromEnvironment().isSome
  var root = CgroupRoot(state: crsOff,
    reason: "inside the tree of a parent lease")
  if not nested:
    when defined(linux):
      var cgroupsProblem = ""
      let switchOn =
        if getEnv(CgroupRootEnvVar).strip().len == 0:
          enforcementCgroupsOn(cgroupsProblem, path)
        else: false
      root = currentCgroupRoot(switchOn)
    else:
      root = CgroupRoot(state: crsUnavailable,
        reason: "cgroups exist only on Linux")
  memoryCapPolicy(mode, envValue, nested, root, problem)

proc encodePolicyArg*(policy: ReproMemoryCapPolicy): string =
  ## The policy as one word for the RunQuota helper's command line: JSON,
  ## so no path or value can break it. The helper is another process and
  ## must apply what the engine resolved -- the cgroup root with the
  ## caller's limited cgroup that holds it, and the reason when there is
  ## none -- rather than read the host file again per action. "" for an
  ## inactive policy: the helper then applies nothing.
  if not policy.active:
    return ""
  $(%*{
    "mode": $policy.hostMode,
    "env": policy.envValue,
    "nested": policy.nested,
    "root": {
      "state": $policy.cgroupRoot.state,
      "path": policy.cgroupRoot.path,
      "reason": policy.cgroupRoot.reason,
      "holder": policy.cgroupRoot.holder,
      "holderLimit": policy.cgroupRoot.holderLimit,
      "holderNote": policy.cgroupRoot.holderNote
    }
  })

proc decodePolicyArg*(text: string; policy: var ReproMemoryCapPolicy;
                      problem: var string): bool =
  ## `encodePolicyArg` read back. "" is the inactive policy. False, with
  ## `problem`, for a word that is not one -- including a root or holder
  ## path that is not a cgroup path RunQuota would accept
  ## (`explicitRootProblem`) -- and `policy` is then inactive.
  policy = ReproMemoryCapPolicy(resolved: true)
  problem = ""
  if text.len == 0:
    return true
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError as err:
    problem = "not JSON: " & err.msg
    return false
  if node.kind != JObject or node{"root"}.isNil or
      node{"root"}.kind != JObject:
    problem = "not a memory-cap policy object"
    return false
  var mode = mcmOff
  case node{"mode"}.getStr()
  of $mcmOff: mode = mcmOff
  of $mcmAdvisory: mode = mcmAdvisory
  of $mcmKill: mode = mcmKill
  else:
    problem = "unknown mode `" & node{"mode"}.getStr() & "`"
    return false
  let r = node["root"]
  var root = CgroupRoot(reason: r{"reason"}.getStr(),
    path: r{"path"}.getStr(), holder: r{"holder"}.getStr(),
    holderLimit: r{"holderLimit"}.getStr(),
    holderNote: r{"holderNote"}.getStr())
  var known = false
  for state in CgroupRootState:
    if r{"state"}.getStr() == $state:
      root.state = state
      known = true
  if not known:
    problem = "unknown cgroup root state `" & r{"state"}.getStr() & "`"
    return false
  if root.usable:
    let rootProblem = explicitRootProblem(root.path)
    if rootProblem.len > 0:
      problem = "cgroup root: " & rootProblem
      return false
  if root.holder.len > 0:
    let holderProblem = explicitRootProblem(root.holder)
    if holderProblem.len > 0:
      problem = "holder cgroup: " & holderProblem
      return false
    # Defence in depth: a holder's root is always its `runquota` child
    # (`HolderRootName`); a root elsewhere would have the helper prepare one
    # cgroup and place trees in another.
    if root.path != root.holder & "/" & HolderRootName:
      problem = "cgroup root " & root.path & " is not " & root.holder & "/" &
        HolderRootName & ", the root inside its holder"
      return false
  policy = memoryCapPolicy(mode, node{"env"}.getStr(),
    node{"nested"}.getBool(), root)
  true

proc resolveActionMemoryCap*(policy: ReproMemoryCapPolicy;
                             grant: GrantMemoryCap): ActionMemoryCap =
  ## The cap one action's launch applies, from the build's policy and the
  ## lease's grant. Nothing for an inactive policy.
  if not policy.active:
    return
  result.grant = grant
  result.root = policy.cgroupRoot
  result.resolution = resolveMemoryCap(grant, policy.hostMode,
    policy.envValue, policy.nested)

proc applies*(cap: ActionMemoryCap): bool =
  cap.resolution.error.len == 0 and cap.resolution.applies

proc applyActionMemoryCap*(spec: var CommandSpec; cap: ActionMemoryCap) =
  ## Put the cap on the launch: the fields every OS's mechanism reads, and
  ## on Linux the memory-only placement under the policy's root. A launch
  ## with nothing to apply is left exactly as it was.
  if not cap.applies:
    return
  spec.applyMemoryCap(cap.resolution)
  when defined(linux):
    if cap.root.usable:
      spec.cgroup = memoryOnlyPlacement(cap.root)

proc actionMemoryCapNote*(cap: ActionMemoryCap; launch: LaunchResult): string =
  ## "memory cap not enforced: <why>" when the cap applies and the platform
  ## did not put it in place; "" otherwise. On Linux without a cgroup root
  ## the root's own reason is added, since "no cgroup root" alone does not
  ## say how to get one.
  result = cap.resolution.memoryCapNotEnforced(launch)
  when defined(linux):
    if result.len > 0 and not cap.root.usable and cap.root.reason.len > 0:
      result.add(" (" & cap.root.reason & ")")

proc finishBlock*(cap: ActionMemoryCap;
                  completion: ProcessCompletion): FinishMemoryCap =
  ## The finish's memory-cap block, or none for a launch that applied none.
  if not cap.applies:
    return FinishMemoryCap(present: false)
  completion.finishMemoryCap(cap.resolution)

proc actionMemoryCapReport*(action, commandStatsId: string;
                            grant: GrantMemoryCap;
                            finishBlock: FinishMemoryCap;
                            killed: bool): string =
  ## RunQuota's breach report (`memoryCapReport`), said of an action:
  ##
  ## ```text
  ## action <name> exceeded its memory cap (command id <id>):
  ##   cap 2.0 GiB = 2 × the largest successful peak, 1.0 GiB; peak 2.0 GiB; killed
  ##   If this growth is expected:
  ##     for one run:     RUNQUOTA_MEMORY_CAP=off   (or RUNQUOTA_MEMORY_CAP=<size>)
  ##     from now on:     runquota expect-growth <id> --to <size>
  ##   Otherwise it is a memory regression: report it to the project that owns
  ##   this action.
  ## ```
  ##
  ## The body is RunQuota's own text, so the figures, the derivation of the
  ## cap and both ways to declare growth are said the same way by every
  ## launcher. Only the first line (who passed the cap) and the owner named
  ## at the end change. A cap taken from the free budget keeps its "not a
  ## regression" body and still ends with whom to tell if it recurs, since
  ## the report always ends with that suggestion. "" when there was no
  ## breach.
  let text = memoryCapReport(action, commandStatsId, grant, finishBlock,
    killed)
  if text.len == 0:
    return ""
  var lines = text.strip(leading = false).splitLines()
  let subject = ": " & action & " (command id " & commandStatsId & ")"
  let idText = " (command id " & commandStatsId & "):"
  const prefix = "runquota: "
  var headline = ""
  if lines[0].startsWith(prefix) and lines[0].endsWith(subject):
    headline = lines[0][prefix.len ..< lines[0].len - subject.len]
  let first =
    case headline
    of "memory cap exceeded":
      "action " & action & " exceeded its memory cap" & idText
    of "memory cap reached":
      "action " & action & " reached its memory cap" & idText
    of "stopped at the memory free when it started":
      "action " & action & " was stopped at the memory free when it " &
        "started" & idText
    of "":
      # A form this module does not know (a newer RunQuota): its own first
      # line, said of the action, rather than nothing.
      "action " & action & idText & " " & lines[0]
    else:
      "action " & action & " " & headline & idText
  lines[0] = first
  let budget = finishBlock.present and finishBlock.basis == mcbBudget or
    not finishBlock.present and grant.basis == mcbBudget
  if lines[^1].strip() == "this command.":
    lines[^1] = "  this action."
  elif budget:
    lines.add("  If it fails this way again with more memory free, report " &
      "it to the project")
    lines.add("  that owns this action.")
  lines.join("\n") & "\n"

proc platformMechanism(): string =
  when defined(linux):
    "in a cgroup leaf of its own (no CPU setting; uncapped actions stay in " &
      "the build's cgroup)"
  elif defined(windows): "in its own Job Object"
  elif defined(macosx): "by a footprint walk of its tree"
  else: "by no mechanism on this platform"

proc effectiveMode(policy: ReproMemoryCapPolicy): string =
  ## The mode actions run in, and where it came from.
  let value = policy.envValue
  case value
  of "":
    $policy.hostMode & " (host file)"
  of "advisory", "kill":
    value & " (" & MemoryCapEnvVar & "=" & value & ")"
  else:
    let mode = if policy.hostMode == mcmOff: mcmKill else: policy.hostMode
    $mode & " at " & value & " (" & MemoryCapEnvVar & "=" & value & ")"

proc memoryCapStateText*(policy: ReproMemoryCapPolicy;
                         notEnforced = ""; applied = true;
                         bypassed = false): string =
  ## The memory cap of Reprobuild's actions in one phrase, for the build
  ## header and the run report: off, lifted, or its mode, and whether it is
  ## enforced, with why not. `notEnforced` is the first "memory cap not
  ## enforced" note an action's launch gave in this build, if any;
  ## `applied` whether any action ran with its cap in place. Until one has,
  ## the cap "will be" enforced: nothing has shown yet that it is.
  ## `bypassed`: the build ran actions without RunQuota leases (`--no-runquota`
  ## or an unreachable daemon), and a launch with no grant has no cap.
  if bypassed:
    return "does not apply: this build ran its actions without RunQuota " &
      "leases, and a launch with no grant has no cap"
  if not policy.active:
    return "off (the host file's [enforcement] memoryCap is off or " &
      "absent, and " & MemoryCapEnvVar & " is unset)"
  if policy.error.len > 0:
    return "refused: " & policy.error
  if policy.nested:
    return "not applied: this build runs inside a parent lease's tree, " &
      "whose launcher applies the cap"
  if policy.envValue == "off":
    if policy.hostMode == mcmOff:
      # Nothing to lift: the host file leaves the cap off.
      return "off"
    return "lifted for this run by " & MemoryCapEnvVar & "=off; each " &
      "action measured " & platformMechanism()
  let mode = policy.effectiveMode()
  if notEnforced.len > 0:
    return mode & ", " & notEnforced
  when defined(linux):
    if not policy.cgroupRoot.usable:
      return mode & ", memory cap not enforced: no cgroup root (" &
        policy.cgroupRoot.reason & ")"
    return mode & (if applied: ", enforced" else: ", will be enforced") &
      ": each capped action " & platformMechanism() & " under " &
      policy.cgroupRoot.path / MemoryCappedDirName
  else:
    mode & (if applied: ", enforced" else: ", will be enforced") &
      ": each capped action " & platformMechanism()

proc memoryCapEnforced*(policy: ReproMemoryCapPolicy;
                        notEnforced = ""): bool =
  ## Whether a cap applies to the actions and nothing said it was not put
  ## in place.
  if not policy.active or policy.error.len > 0 or policy.nested or
      notEnforced.len > 0:
    return false
  if policy.envValue == "off" and policy.hostMode == mcmOff:
    return false
  when defined(linux):
    policy.cgroupRoot.usable
  else:
    true
