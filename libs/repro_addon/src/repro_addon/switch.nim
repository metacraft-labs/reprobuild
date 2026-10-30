## The host-side steps of the add-on switch (ReproOS Add-On Mode §7.2)
## that act on systemd and the kernel: stopping, starting, restarting and
## reloading units (steps 2 and 7), confirming an exclusive unit has
## exited, running the fragment tools (step 6), and the generation
## retention policy that follows a commit (§5.2).
##
## Everything here goes through the host's own tools by absolute path
## (``host_exec``) and never through a shell.
##
## **Exclusive units** (§7.3). ``systemctl stop`` returns when the unit's
## job is done, but a unit whose process ignores SIGTERM and declares
## ``SendSIGKILL=no`` ends in ``failed`` with the process still alive in
## its cgroup. "Confirmed exited" therefore means the unit's control
## group has no process left, read from
## ``/sys/fs/cgroup/<ControlGroup>/cgroup.procs``, not merely
## ``ActiveState=inactive``. A unit that cannot be confirmed makes the
## apply refuse with ``EAddOnExclusiveOverlap`` before step 3, so nothing
## was switched and the successor is never started.
##
## **Sysctl** (§7.2 step 6, threat model G35). A ``net.*`` key is per
## network namespace, so a ``sysctl -w`` from inside the apply unit's
## ``PrivateNetwork=yes`` would set a throwaway namespace's copy and read
## it back as success. The fragments are applied by restarting the host's
## own ``systemd-sysctl.service`` (PID 1 runs it in the host namespaces)
## and the effective values are observed by a transient unit the host's
## systemd runs for us (``systemd-run --wait --pipe``).

import std/[algorithm, os, strutils, times]

import repro_infra/addon_diagnostics
import repro_local_store/store

import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./store_root
import ./transitions

type
  SwitchError* = object of CatchableError

const
  SystemdSysctlCandidates* = ["/usr/lib/systemd/systemd-sysctl",
                              "/lib/systemd/systemd-sysctl"]
  SysctlService* = "systemd-sysctl.service"
  CgroupRoot* = "/sys/fs/cgroup"
  ExclusiveStopGraceSeconds* = 5
    ## After `systemctl stop` returns, how long the control group may
    ## still drain before the unit counts as not confirmed.

# ---------------------------------------------------------------------------
# Units.
# ---------------------------------------------------------------------------

proc unitProperty*(unit, property: string): string =
  ## One ``systemctl show -p`` value, "" when unknown.
  let r = runSystemctl(["show", "-p", property, "--value", "--", unit])
  if r.exitCode != 0: "" else: r.output.strip()

proc unitIsActive*(unit: string): bool =
  unitProperty(unit, "ActiveState") == "active"

proc cgroupProcs*(unit: string): seq[string] =
  ## The PIDs in the unit's control group, from cgroup v2's
  ## ``cgroup.procs``; empty when the group is gone or empty.
  let cg = unitProperty(unit, "ControlGroup")
  if cg.len == 0: return @[]
  let path = CgroupRoot / cg.strip(chars = {'/'}) / "cgroup.procs"
  if not fileExists(path): return @[]
  try:
    for line in readFile(path).splitLines():
      if line.strip().len > 0: result.add(line.strip())
  except IOError, OSError:
    discard

proc systemctlVerb(verb, unit: string) =
  let r = if unit.len > 0: runSystemctl([verb, "--", unit])
          else: runSystemctl([verb])
  if r.exitCode != 0:
    raise newException(SwitchError, "systemctl " & verb & " " & unit & ": " &
      r.output.strip())

proc stopUnit*(unit: string) = systemctlVerb("stop", unit)
proc startUnit*(unit: string) = systemctlVerb("start", unit)
proc restartUnit*(unit: string) = systemctlVerb("restart", unit)
proc reloadUnit*(unit: string) = systemctlVerb("reload", unit)
proc disableUnit*(unit: string) = systemctlVerb("disable", unit)

proc daemonReload*() = systemctlVerb("daemon-reload", "")

proc stopExclusive*(unit: string; graceSeconds = ExclusiveStopGraceSeconds) =
  ## Stop ``unit`` and confirm its control group is empty; refuse with
  ## ``EAddOnExclusiveOverlap`` otherwise (the successor must not start
  ## while the old instance lives).
  try:
    stopUnit(unit)
  except SwitchError as e:
    # `stop` failing (a timeout with SendSIGKILL=no, a job cancelled) is
    # not yet a refusal: what matters is whether anything is still alive.
    discard e
  let deadline = epochTime() + graceSeconds.float
  while true:
    let procs = cgroupProcs(unit)
    if procs.len == 0:
      return
    if epochTime() >= deadline:
      raise newAddOnExclusiveOverlap(unit, "its control group still holds " &
        "process(es) " & procs.join(", ") & " after `systemctl stop` " &
        "(ActiveState=" & unitProperty(unit, "ActiveState") & ", SubState=" &
        unitProperty(unit, "SubState") & ")")
    sleep(200)

proc runPreStop*(ts: seq[Transition]; disable: openArray[string]):
    seq[string] =
  ## Step 2: the transition list's stops, exclusive ones first and
  ## confirmed, then ``disable`` for the units this generation removes
  ## (their files are about to go, so their [Install] links go with them
  ## while systemd can still read the unit). Returns the units stopped,
  ## for the pending marker.
  when mutated("exclusive-as-plain-restart"):
    # The falsifying mutation: an exclusive unit gets no special step.
    # Its old instance is stopped AFTER the successor starts (`runStart`
    # below) -- "start new, then stop old", the plain order of a
    # rolling restart -- so the two lifetimes overlap, which the gate's
    # lifetime log catches. Nothing is confirmed exited either.
    for t in preStopEntries(ts):
      if t.exclusive: continue
      stopUnit(t.unit)
      result.add(t.unit)
  else:
    for t in preStopEntries(ts):
      if t.exclusive:
        stopExclusive(t.unit)
      else:
        stopUnit(t.unit)
      result.add(t.unit)
  for u in disable:
    try: disableUnit(u)
    except SwitchError: discard   # already disabled, or static

proc runStart*(ts: seq[Transition]) =
  ## Step 7: start, restart or reload in the order given. A
  ## ``stop-start`` unit was stopped in step 2 and is started here.
  for t in startEntries(ts):
    case t.verb
    of tvStart: startUnit(t.unit)
    of tvStopStart:
      when mutated("exclusive-as-plain-restart"):
        restartUnit(t.unit)     # never stopped in step 2: a plain restart
      else:
        startUnit(t.unit)
    of tvRestart: restartUnit(t.unit)
    of tvReload: reloadUnit(t.unit)
    else: discard
  when mutated("exclusive-as-plain-restart"):
    # The deferred stops of the exclusive units this generation removes:
    # after their successors started.
    for t in preStopEntries(ts):
      if t.exclusive and t.verb == tvStop:
        stopUnit(t.unit)

# ---------------------------------------------------------------------------
# Sysctl (step 6).
# ---------------------------------------------------------------------------

proc observeSysctlInHostNamespaces*(key: string): string =
  ## The host's effective value of ``key``, read by a transient unit in
  ## the host's namespaces (``host_exec.readHostSysctl``).
  readHostSysctl(key)

proc applySysctlFragments*(changedFragments: openArray[string]) =
  ## Apply the changed sysctl fragments, each by the host's own
  ## ``systemd-sysctl <fragment>`` run as a transient unit in the host's
  ## namespaces (spec §7.2 step 6). Only the changed fragments: restarting
  ## the whole ``systemd-sysctl.service`` would re-apply the distribution's
  ## fragments too and move keys the generation does not own (measured on
  ## Debian 13: ``net.ipv4.conf.all.accept_redirects``), which the
  ## fingerprint-equals-ledger check rightly refuses.
  let exe = resolveHostTool(SystemdSysctlCandidates)
  if exe.len == 0:
    raise newException(SwitchError, "systemd-sysctl not found at " &
      SystemdSysctlCandidates.join(" or "))
  for f in changedFragments:
    if not fileExists(f): continue       # removed: its key was restored
    when mutated("sysctl-in-apply-namespace"):
      # The falsifying mutation: run systemd-sysctl from THIS process --
      # inside the apply unit's PrivateNetwork=yes that is a throwaway
      # namespace, so the host's net.* values do not change.
      discard runHostTool([exe, f])
    else:
      let r = runInHostNamespaces([exe, f])
      if r.exitCode != 0:
        raise newException(SwitchError, "systemd-sysctl " & f & ": " &
          r.output.strip())

proc restoreSysctlValue*(key, value: string) =
  ## Put a key back to the value the ledger recorded before the add-on
  ## set it (a removed sysctl resource), from the host's namespaces.
  if value.len == 0: return
  let r = runInHostNamespaces(["/bin/sh", "-c",
    "printf '%s' \"$1\" > \"$2\"", "repro-addon", value, sysctlKeyPath(key)])
  if r.exitCode != 0:
    raise newException(SwitchError, "restoring sysctl " & key & " = " &
      value & ": " & r.output.strip())

# ---------------------------------------------------------------------------
# Retention (§5.2).
# ---------------------------------------------------------------------------

type
  RetentionPolicy* = object
    keepGenerations*: int   ## keep the newest N retained generations
    keepDays*: int          ## and every generation newer than this
    ## Whichever retains more. The current and the previous generation
    ## are kept whatever the policy says.

const DefaultRetention* = RetentionPolicy(keepGenerations: 5, keepDays: 30)

proc pruneGenerationRoots*(current, previous: string;
                           policy = DefaultRetention;
                           now = getTime().toUnix()): seq[string] =
  ## Drop the ``profile`` store roots of add-on generations outside the
  ## policy, so ``repro store gc`` can collect what only they held. Never
  ## the current or the previous generation (spec §5.2: collecting what
  ## they hold would turn the next reboot into an outage). Returns the
  ## generation ids whose roots were dropped.
  if not dirExists(StoreRoot): return
  enterWritableStoreView()
  var s = openStore(StoreRoot)
  defer: s.close()
  var rows: seq[RootRow]
  for r in s.listRoots():
    if r.rootId.startsWith(RootIdPrefix) and r.kind == $rkProfile:
      rows.add(r)
  # Newest first by registration time.
  rows.sort(proc(a, b: RootRow): int = cmp(b.createdAtUnix, a.createdAtUnix))
  var kept = 0
  for r in rows:
    let id = r.rootId[RootIdPrefix.len .. ^1]
    let young = now - r.createdAtUnix < int64(max(policy.keepDays, 0)) * 86400
    if id == current or id == previous or kept < max(policy.keepGenerations, 0) or
        young:
      inc kept
      continue
    s.deleteRoot(r.rootId)
    result.add(id)
