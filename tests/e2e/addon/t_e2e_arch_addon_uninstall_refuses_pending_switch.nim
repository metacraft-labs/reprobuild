## Gate ``e2e_arch_addon_uninstall_refuses_pending_switch`` (spec
## ReproOS-Add-On-Mode §6.4 step 0, §7.7, §8.4; §13 decision 122).
##
## On each Arch guest: bootstrap, apply a generation with a plain
## ``etcFile`` fixture (no ``network`` object), then start the switch to a
## second generation with the seam build paused just after it wrote its
## pending marker (``step-1``). The gate kills exactly that apply process
## with ``SIGKILL`` -- the PID the marker records as its owner, checked
## against ``/proc/<pid>/cmdline`` first -- and does not reboot, so the
## re-assert unit does not run: the marker stays and its owner is dead.
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
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and ``REPRO_ADDON_TEST_SEAMS=1``
## (``just e2e_arch_addon_uninstall_refuses_pending_switch``).
##
## *Mocking.* None: the seam is a pause compiled only into the test build
## (``repro_addon/seams``); everything else is the real add-on.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support

const PendingMarker = "/var/lib/repro/system/addon/pending"

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
    let f0 = g.fingerprintArch(repro)
    if not g.bootstrapArch(repro, step).ok: return fails
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

    let fBefore = g.fingerprintArch(repro)
    let un = g.exec(repro & " system addon uninstall", timeoutSec = 600)
    let said = un.stdout & un.stderr
    record["uninstallOverMarker"] = %said
    step("uninstall refuses with EAddOnSwitchPending, naming the marker",
         un.exitCode != 0 and "EAddOnSwitchPending" in said and
           PendingMarker in said,
         "exit " & $un.exitCode & "\n" & said)
    step("the refusal is not ELockTimeout (the owner's lock went with it)",
         "ELockTimeout" notin said, said)
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
        echo "record: ", writeRecord(
          "e2e_arch_addon_uninstall_refuses_pending_switch", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
