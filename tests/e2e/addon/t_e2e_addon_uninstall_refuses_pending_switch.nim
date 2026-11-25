## Gate ``e2e_addon_uninstall_refuses_pending_switch`` (spec
## ReproOS-Add-On-Mode §6.4 step 0, §7.7; §13 decision 122; milestone A11,
## assigned by the operator 2026-11-25).
##
## On each Debian and Ubuntu guest: bootstrap with the deploy agent
## configured (a day-long poll interval, so its timer waits), apply a
## generation with a plain ``fs.systemFile`` fixture (no ``network``
## object), then start the switch to a second generation with the seam
## build paused just after it wrote its pending marker (``step-1``). The
## gate SIGKILLs exactly that apply process -- the PID the marker records as
## its owner, checked against ``/proc/<pid>/cmdline`` first -- and does NOT
## reboot or hard-reset the guest: a boot runs ``repro-addon-reassert``,
## which would recover the marker before the uninstall ran. The marker
## stays and its owner is dead.
##
## ``repro system addon uninstall`` must then refuse with
## ``EAddOnSwitchPending`` naming the marker -- not ``ELockTimeout``: the
## killed owner's lock went with it -- and change nothing: the fingerprint
## is identical, the marker is still there, and the deploy agent's fetch
## timer is still active (§6.4 orders step 0 before step 1, "stop the
## add-on's units"). After ``repro system addon recover`` the uninstall
## completes.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=uninstall-skips-pending-check``):
## uninstall proceeds over the pending marker, so the refusal steps are red.
##
## Seam build (the switch's pause). Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: the seam is a pause compiled only into the test build
## (``repro_addon/seams``); everything else is the real add-on.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_uninstall_refuses_pending_switch"
  PendingMarker = "/var/lib/repro/system/addon/pending"
  AgentTimer = "repro-agent-fetch.timer"
  FixturePath = "/etc/repro/a11-pending"

proc profile(n: string): string =
  canonicalFile(FixturePath, "generation " & n & "\n")

proc killPendingOwner(g: Guest): tuple[ok: bool; detail: string] =
  ## SIGKILL the apply process that owns the pending marker: the one this
  ## gate started (``startSwitchPausedAt``). Its PID is read from the
  ## marker it wrote, and refused unless that process is the paused
  ## ``repro infra apply``; then it is the only process signalled.
  let pid = g.run("sed -n 's/^owner-pid\\t//p' " & PendingMarker).strip()
  if pid.len == 0 or not pid.allCharsInSet({'0'..'9'}) or pid == "0":
    return (false, "the marker names no owner pid: '" & pid & "'")
  let cmd = g.run("tr '\\0' ' ' < /proc/" & pid & "/cmdline 2>/dev/null; true")
  if "infra apply" notin cmd:
    return (false, "pid " & pid & " is not the paused apply: " & cmd)
  discard g.run("kill -KILL " & pid)
  let deadline = epochTime() + 60
  while epochTime() < deadline:
    if g.exec("test -e /proc/" & pid).exitCode != 0:
      return (true, "killed pid " & pid & " (" & cmd.strip() & ")")
    sleep(250)
  (false, "pid " & pid & " is still there after SIGKILL")

proc waitFetchIdle(g: Guest; timeoutSec = 600) =
  ## Until no fetch cycle runs (the timer's first one, at its start).
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    let s = g.exec("systemctl show -p ActiveState --value " &
                   "repro-agent-fetch.service repro-agent-apply.service").stdout
    if "activating" notin s and "deactivating" notin s and
        "\nactive" notin "\n" & s:
      return
    sleep(1000)

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let a1 = g.applyProfile(repro, "gen1", profile("1"))
  step("apply generation 1 (an fs.systemFile)", a1.exitCode == 0,
       a1.stdout & a1.stderr)
  if a1.exitCode != 0: return
  # The agent: its timer armed, its first cycle settled, a day before the
  # next (--poll-interval 86400).
  discard g.exec("systemctl start " & AgentTimer)
  g.waitFetchIdle()
  step("the deploy agent's fetch timer is active",
       g.exec("systemctl is-active " & AgentTimer).stdout.strip() == "active",
       g.exec("systemctl status --no-pager " & AgentTimer & " 2>&1").stdout)

  let paused = g.startSwitchPausedAt(repro, "gen2", profile("2"), "step-1")
  step("the switch to generation 2 stops after its pending marker",
       paused.exitCode == 0, paused.stdout & paused.stderr)
  if paused.exitCode != 0: return
  let killed = g.killPendingOwner()
  step("the apply that owns the marker is killed (SIGKILL, no reboot)",
       killed.ok, killed.detail)
  if not killed.ok: return

  g.waitFetchIdle()
  let fBefore = g.takeFingerprint(repro)
  let un = g.exec(repro & " system addon uninstall", timeoutSec = 600)
  let said = un.stdout & un.stderr
  record["uninstallOverMarker"] = %said
  step("uninstall refuses with EAddOnSwitchPending, naming the marker",
       un.exitCode != 0 and "EAddOnSwitchPending" in said and
         PendingMarker in said,
       "exit " & $un.exitCode & "\n" & said)
  step("the refusal is not ELockTimeout (the owner's lock went with it)",
       "ELockTimeout" notin said, said)
  let timer = g.exec("systemctl is-active " & AgentTimer)
  record["agentTimerAtRefusal"] = %timer.stdout.strip()
  step("the refusal came before the units were stopped (the deploy " &
       "agent's fetch timer is still active)",
       timer.stdout.strip() == "active", timer.stdout & timer.stderr)
  let same = identityReport(fBefore, g.takeFingerprint(repro))
  step("the refused uninstall changed nothing (fingerprint identical)",
       same.ok, same.text)
  step("the pending marker is still there",
       g.exec("test -f " & PendingMarker).exitCode == 0, "")

  let rec = g.exec(repro & " system addon recover", timeoutSec = 900)
  step("recover finishes or reverts the switch", rec.exitCode == 0,
       rec.stdout & rec.stderr)
  let un2 = g.exec(repro & " system addon uninstall", timeoutSec = 1800)
  step("uninstall completes after recover", un2.exitCode == 0,
       un2.stdout & un2.stderr)
  step("no pending marker and no add-on state are left",
       g.exec("test -e " & PendingMarker).exitCode != 0 and
         g.exec("test -e /var/lib/repro/system/addon-ledger").exitCode != 0,
       g.exec("ls -la /var/lib/repro/system 2>&1").stdout)

suite Gate:
  test "uninstall refuses while a switch's pending marker exists":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    elif useIncus():
      skip("the switch's pause seam is driven over QEMU guests only")
    else:
      check gateMain(Gate, body,
                     extraFlags = " --poll-interval 86400").len == 0
