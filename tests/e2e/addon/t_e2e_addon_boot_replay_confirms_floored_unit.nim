## Gate ``e2e_addon_boot_replay_confirms_floored_unit`` (milestone A9, §13
## decisions 144 and 157; spec §7.7).
##
## Decision 144 orders every floored unit ``After=`` the boot re-assertion,
## so a switch replayed inside it could not confirm a floored unit's health:
## the unit could not start until the replay returned, the replay always
## failed at ``confirmTimeout`` and was reverted, and ``multi-user.target``
## waited that long too. Decision 157: such a switch is left to
## ``repro-addon-boot-confirm.service``, ordered after the re-assertion,
## which replays it once the floored units can start.
##
## The case (the A9 round-15 reviewer's section H, on the real floor, built
## on the claimant's WIP gate): generation A has a floored control unit;
## generation B adds a floored oneshot (``RemainAfterExit=yes``) with
## ``healthCheck = "active"`` and ``confirmTimeout = 20``. A plain reboot
## first measures the boot. Then the switch from A to B is paused at
## ``step-5`` and the guest is hard-reset. After the boot:
##
## - the floored unit is ordered after the re-assertion (the premise);
## - the re-assertion left the switch to the boot-confirm unit, and the
##   boot-confirm unit replayed it to completion; no pending marker is
##   left; ``current`` is B's generation and both floored units are active;
## - the health-checked unit started after the re-assertion exited and
##   before the boot-confirm unit's confirm ended;
## - the boot took no longer than the plain one (within 25 % plus 2 s): the
##   boot-confirm unit is not on ``multi-user.target``'s path.
##
## Falsifying build: ``REPRO_ADDON_MUTATION=boot-confirm-in-reassert`` (the
## re-assertion replays and confirms the switch itself): it is reverted
## after ``confirmTimeout`` -- red.
##
## Needs the seam build: ``REPRO_ADDON_TEST_SEAMS=1`` (set by
## ``scripts/run_addon_gate.sh``). Opt-in: ``REPRO_ADDON_VM_GATES=1``;
## QEMU only (a reset needs a disk).
##
## *Mocking.* None: real images, a real reset, the real switch, recovery
## and systemd.

import std/[json, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  Gate = "e2e_addon_boot_replay_confirms_floored_unit"
  Account = "a9br"
  Control = "a9brc.service"
  Checked = "a9brf.service"
  ConfirmTimeout = 20
  BootConfirm = "repro-addon-boot-confirm.service"

proc floored(name, binary, description: string; extra = ""): string =
  ## A floored oneshot that stays active: no ``hardening`` of its own, so
  ## the add-on's default puts it under the floor (spec §10.1).
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=" & description & "\n\n[Service]\nType=oneshot\n" &
    "RemainAfterExit=yes\nUser=" & Account & "\nExecStart=" & binary &
    " --version\n\n[Install]\nWantedBy=multi-user.target\n\"\n" &
    "  enabled = true\n" & extra & "}\n\n"

proc profileA(binary: string): string =
  "addOn {\n  managedEtcPrefixes = []\n  confirmTimeout = " &
    $ConfirmTimeout & "\n}\n\n" &
    floored(Control, binary, "A9 boot replay control")

proc profileB(binary: string): string =
  profileA(binary) &
    floored(Checked, binary, "A9 boot replay checked",
            "  healthCheck = \"active\"\n")

proc currentGeneration(g: Guest): string =
  ## ``current`` is a link to the generation's directory (``state_dir``).
  g.exec("basename \"$(readlink /var/lib/repro/system/current)\"").
    stdout.strip()

proc monotonicUsec(g: Guest; unit, prop: string): int64 =
  ## A unit timestamp property, as microseconds of CLOCK_MONOTONIC (0 when
  ## unset): ``<prop>Monotonic`` (systemd.exec(5), org.freedesktop.systemd1(5)).
  let v = g.exec("systemctl show -p " & prop & "Monotonic --value " & unit).
    stdout.strip()
  try: parseBiggestInt(v) except ValueError: 0'i64

proc userspaceSeconds(g: Guest): float =
  ## This boot's userspace time, once the boot is finished.
  discard g.exec("systemctl is-system-running --wait; true", timeoutSec = 600)
  let sh = g.exec("systemctl show -p UserspaceTimestampMonotonic " &
                  "-p FinishTimestampMonotonic").stdout
  var u, f = 0'i64
  for l in sh.splitLines():
    let kv = l.split('=', 1)
    if kv.len != 2: continue
    try:
      if kv[0] == "UserspaceTimestampMonotonic": u = parseBiggestInt(kv[1])
      elif kv[0] == "FinishTimestampMonotonic": f = parseBiggestInt(kv[1])
    except ValueError: discard
  if u == 0 or f <= u: return -1.0
  float(f - u) / 1e6

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    discard g.run("useradd -r -M -s /usr/sbin/nologin " & Account)
    let binary = g.run("ls -d /repro/store/prefixes/repro-addon/*/bin/repro " &
                       "| head -1").strip()
    var r = g.applyProfile(repro, "a", profileA(binary))
    step("generation A applies", r.exitCode == 0, r.stdout & r.stderr)
    let genA = g.currentGeneration()
    # The boot to compare with: A, nothing pending.
    g.rebootGuest()
    discard g.waitReasserted()
    let plainBoot = g.userspaceSeconds()
    record["plainBootSeconds"] = %plainBoot
    # The switch to B, stopped after the drivers' writes, then a reset: the
    # boot's re-assertion replays it.
    g.holdWriteback()
    let paused = g.startSwitchPausedAt(repro, "b", profileB(binary), "step-5")
    step("the switch to B paused at step-5", paused.exitCode == 0,
         paused.stdout & paused.stderr)
    if paused.exitCode != 0: return fails
    # The premise, read from the unit file the paused switch wrote (a
    # reverted host no longer has it): the health-checked unit is floored,
    # so ordered after the re-assertion (decision 144).
    let unitFile = g.exec("cat /etc/systemd/system/" & Checked).stdout
    step("premise: the health-checked unit is floored, ordered after the " &
         "re-assertion (decision 144)",
         "After=repro-addon-reassert.service" in unitFile, unitFile)
    g.hardResetAfterSettle()
    g.boot()
    let reassertJournal = g.waitReasserted()
    discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                   timeoutSec = 600)
    let resetBoot = g.userspaceSeconds()
    record["resetBootSeconds"] = %resetBoot
    discard g.exec("for i in $(seq 1 300); do s=$(systemctl show -p ActiveState --value " &
      BootConfirm & "); [ $s = active ] || [ $s = failed ] && break; sleep 2; done",
      timeoutSec = 900)
    let journal = g.exec("journalctl -b -o cat --no-pager -u " & BootConfirm).stdout
    record["reassertJournal"] = %reassertJournal
    record["bootConfirmJournal"] = %journal
    step("the re-assertion left the switch to the boot-confirm unit (§13 decision 157)",
         BootConfirm in reassertJournal and "deferred" in reassertJournal,
         reassertJournal)
    let after = g.exec("systemctl show -p After " & Checked).stdout
    step("the replayed unit is loaded with that ordering",
         "repro-addon-reassert.service" in after, after)
    step("the boot-confirm unit replayed the switch to completion",
         "replayed the switch to completion" in journal and
         "did not complete and was reverted" notin journal, journal)
    step("and reported ok",
         "repro-addon reassert: ok" in journal, journal)
    step("no pending marker is left",
         g.exec("test ! -e " & SeamDir & "/pending").exitCode == 0, "")
    let genNow = g.currentGeneration()
    record["generations"] = %*{"a": genA, "afterBoot": genNow}
    step("current is the replayed generation, not a re-applied A",
         genNow.len > 0 and genNow != genA and
         ("generation " & genNow & " is current") in journal,
         "A " & genA & ", now " & genNow & "\n" & journal)
    let state = g.exec("systemctl is-active " & Checked & " " & Control).
      stdout.splitWhitespace()
    step("both floored units are active", state == @["active", "active"],
         $state)
    # The order: the health-checked unit started after the re-assertion
    # exited, and before the boot-confirm unit's process exited (its
    # confirm saw it start).
    let reassertExited = g.monotonicUsec("repro-addon-reassert.service",
                                         "ExecMainExitTimestamp")
    let confirmExited = g.monotonicUsec(BootConfirm, "ExecMainExitTimestamp")
    let started = g.monotonicUsec(Checked, "ExecMainStartTimestamp")
    record["monotonicUsec"] = %*{"reassertExited": reassertExited,
      "bootConfirmExited": confirmExited, "flooredStarted": started}
    step("the floored unit started after the re-assertion exited and before " &
         "the boot-confirm unit's confirm ended",
         reassertExited > 0 and started >= reassertExited and confirmExited > started,
         "re-assertion exited " & $reassertExited & ", floored started " &
         $started & ", boot-confirm exited " & $confirmExited)
    step("the boot took no longer than the plain one (the boot-confirm unit is " &
         "not on multi-user.target's path)",
         plainBoot > 0 and resetBoot > 0 and resetBoot <= plainBoot * 1.25 + 2.0,
         "plain " & $plainBoot & " s, after the reset " & $resetBoot & " s")
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

suite Gate:
  test "a boot replay confirms a health-checked floored unit":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    elif useIncus():
      skip("a hard reset is of a disk image; QEMU only")
    elif not testSeams():
      skip("needs the seam build: set REPRO_ADDON_TEST_SEAMS=1")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": "qemu", "mutation": mutation(),
          "testSeams": testSeams(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
