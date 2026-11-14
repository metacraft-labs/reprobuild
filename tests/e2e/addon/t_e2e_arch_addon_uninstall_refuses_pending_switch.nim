## Gate ``e2e_arch_addon_uninstall_refuses_pending_switch`` (spec
## ReproOS-Add-On-Mode §6.4 step 0, §7.7, §8.4; §13 decision 122).
##
## On each Arch guest: settle the base (``settleBaseline``) and take the
## baseline fingerprint, bootstrap with the deploy agent configured, apply a generation with a plain
## ``etcFile`` fixture (no ``network`` object), then start the switch to a
## second generation with the seam build paused just after it wrote its
## pending marker (``step-1``). The gate kills exactly that apply process
## with ``SIGKILL`` -- the PID the marker records as its owner, checked
## against ``/proc/<pid>/cmdline`` first -- and does not reboot, so the
## re-assert unit does not run: the marker stays and its owner is dead.
##
## *The agent.* Bootstrap configures the deploy agent (``--target``, one
## ``--manifest`` at ``AgentManifest``, an address in TEST-NET-1 that no
## route reaches, RFC 5737, and a day-long poll interval), so the add-on
## has a fetch timer whose first cycle fails and which then waits.
## §6.4 orders step 0 before step 1 ("stop the add-on's units"): the gate
## observes it as the fetch timer still ``active`` after the refusal. An
## uninstall that stopped the units before refusing would leave it
## inactive (and the fingerprint different).
##
## ``repro system addon uninstall`` must then refuse with
## ``EAddOnSwitchPending`` naming the marker -- not ``ELockTimeout``: the
## killed owner's ``flock`` on the host apply lock went with it -- and change
## nothing (fingerprint identical, the marker still there). After ``repro
## system addon recover`` the uninstall completes, and the fingerprint is
## the one taken before bootstrap (AR1's byte identity).
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=uninstall-skips-pending-check``,
## with ``REPRO_ADDON_TEST_SEAMS=1``): uninstall proceeds over the pending
## marker, so the refusal step is red. Record red, then green.
##
## A falsifier run (``REPRO_ADDON_MUTATION``) passes only when every base
## shows the mutation's own red steps and nothing else (``expectedFalsifier``,
## judged by ``arch_gate_support.falsifierVerdict``): only the listed steps
## may be red, the steps that run before and around the mutated code
## (bootstrap, the generation applies, uninstall, ...) must be present and
## green, and an exception or infrastructure failure always fails it. A base
## outside the mutation must stay green. The base's own verdict stays
## ``red`` in its record; the judgement is the record's ``falsifier``.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and ``REPRO_ADDON_TEST_SEAMS=1``
## (``just e2e_arch_addon_uninstall_refuses_pending_switch``).
##
## *Mocking.* None: the seam is a pause compiled only into the test build
## (``repro_addon/seams``); everything else is the real add-on.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./agent_e2e_support
import ./arch_gate_support

const
  PendingMarker = "/var/lib/repro/system/addon/pending"
  AgentManifest = "http://192.0.2.1/manifest.json"
    ## RFC 5737 TEST-NET-1: an address literal (the fetch unit's egress
    ## allow-list takes it as is) that nothing answers.
  AgentFlags = " --target ar1-pending-switch --manifest " & AgentManifest &
    " --poll-interval 86400"
  AgentTimer = "repro-agent-fetch.timer"

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

proc uninstallOverMarkerRanToItsEnd(record: JsonNode): bool =
  ## Under the mutation the uninstall over the marker must have proceeded
  ## and succeeded (exit 0): a refusal for another reason, or a failure,
  ## is not the skipped check.
  record{"uninstallOverMarkerExit"}.getInt(-1) == 0

proc expectedFalsifier(mut: string; b: BaseImage): Falsifier =
  ## Each falsifier's expected red (``falsifierVerdict``): the uninstall
  ## over the marker proceeds (it neither refuses nor keeps the agent
  ## running), and what follows from that may be red; everything up to the
  ## uninstall must have run green.
  case mut
  of "uninstall-skips-pending-check":
    Falsifier(
      required: @[
        "uninstall refuses with EAddOnSwitchPending, naming the marker",
        "the refusal came before the units were stopped (the agent's fetch " &
          "timer is still active)"],
      mayBeRed: @["the refused uninstall changed nothing",
        "the pending marker is still there",
        "recover finishes or reverts the switch",
        "uninstall completes after recover",
        "base fingerprint after uninstall == before bootstrap"],
      mustRunGreen: @["baseline: udevadm settle and systemctl daemon-reload",
        "preflight is compatible", "bootstrap",
        "the deploy agent's fetch timer is active after bootstrap",
        "apply generation 1 (an etcFile)",
        "the switch to generation 2 stops after its pending marker",
        "the apply that owns the marker is killed (SIGKILL)",
        "the refusal is not ELockTimeout (the owner's lock went with it)"],
      recordChecks: @[(name: "the uninstall over the marker ran to its end (exit 0)",
                       check: uninstallOverMarkerRanToItsEnd)])
  else: raise unknownMutation("e2e_arch_addon_uninstall_refuses_pending_switch", mut)

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newArchGuest(b)
    g.boot()
    g.prepareArchGuest()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    g.settleBaseline(step)
    let f0 = g.fingerprintArch(repro)
    if not g.bootstrapArch(repro, step, AgentFlags, withCache = false).ok: return fails
    step("the deploy agent's fetch timer is active after bootstrap",
         g.exec("systemctl is-active " & AgentTimer).exitCode == 0,
         g.exec("systemctl status --no-pager " & AgentTimer & " 2>&1").stdout)
    let a1 = g.applyProfile(repro, "gen1", addOnStanza() &
                            fixtureFile("fixture = 1\n"))
    step("apply generation 1 (an etcFile)", a1.exitCode == 0,
         a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails

    let paused = g.startSwitchPausedAt(repro, "gen2", addOnStanza() &
                                       fixtureFile("fixture = 2\n"), "step-1")
    step("the switch to generation 2 stops after its pending marker",
         paused.exitCode == 0, paused.stdout & paused.stderr)
    if paused.exitCode != 0: return fails
    let killed = g.killPendingOwner()
    step("the apply that owns the marker is killed (SIGKILL)", killed.ok,
         killed.detail)
    if not killed.ok: return fails

    # The fetch cycle the timer started at activation has failed and
    # settled; with a day-long interval nothing runs again during the gate.
    g.waitAgentIdle(600)
    let fBefore = g.fingerprintArch(repro)
    let un = g.exec(repro & " system addon uninstall", timeoutSec = 600)
    let said = un.stdout & un.stderr
    record["uninstallOverMarker"] = %said
    record["uninstallOverMarkerExit"] = %un.exitCode
    step("uninstall refuses with EAddOnSwitchPending, naming the marker",
         un.exitCode != 0 and "EAddOnSwitchPending" in said and
           PendingMarker in said,
         "exit " & $un.exitCode & "\n" & said)
    step("the refusal is not ELockTimeout (the owner's lock went with it)",
         "ELockTimeout" notin said, said)
    let timer = g.exec("systemctl is-active " & AgentTimer)
    record["agentTimerAtRefusal"] = %timer.stdout.strip()
    step("the refusal came before the units were stopped (the agent's " &
         "fetch timer is still active)", timer.exitCode == 0 and
           timer.stdout.strip() == "active", timer.stdout & timer.stderr)
    let same = identityReport(fBefore, g.fingerprintArch(repro))
    step("the refused uninstall changed nothing", same.ok, same.text)
    step("the pending marker is still there",
         g.exec("test -f " & PendingMarker).exitCode == 0, "")

    let rec = g.exec(repro & " system addon recover", timeoutSec = 900)
    step("recover finishes or reverts the switch", rec.exitCode == 0,
         rec.stdout & rec.stderr)
    let un2 = g.exec(repro & " system addon uninstall", timeoutSec = 900)
    step("uninstall completes after recover", un2.exitCode == 0,
         un2.stdout & un2.stderr)
    let ident = identityReport(f0, g.fingerprintArch(repro))
    step("base fingerprint after uninstall == before bootstrap", ident.ok,
         ident.text)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite "e2e_arch_addon_uninstall_refuses_pending_switch":
  test "uninstall refuses over a dead switch's marker, then completes after recover":
    if not gatesEnabled() or not testSeams():
      skip("add-on VM gate with the seam build: set REPRO_ADDON_VM_GATES=1 " &
           "and REPRO_ADDON_TEST_SEAMS=1 (just " &
           "e2e_arch_addon_uninstall_refuses_pending_switch)")
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        let record = archGateRecord("e2e_arch_addon_uninstall_refuses_pending_switch")
        record["base"] = %b.name
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        let judged = judgeRun("e2e_arch_addon_uninstall_refuses_pending_switch", record, f, expectedFalsifier, b)
        echo "record: ", writeRecord(
          "e2e_arch_addon_uninstall_refuses_pending_switch", record)
        failures.add(judged)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
