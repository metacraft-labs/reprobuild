## Gate ``e2e_addon_boot_replay_confirms_floored_unit`` (milestone A9, §13
## decision 144 and its amendment, decision 155; spec §7.7, *A boot replay
## confirms a floored unit*).
##
## Decision 144 orders every floored unit ``After=`` the boot re-assertion,
## so that a pending revert's holds are back in place before anything can
## start. At boot, an interrupted switch is replayed *inside* the
## re-assertion, and the replay's step 8 confirms its health checks there.
## A floored unit's start waits for the re-assertion, so while the
## re-assertion was a oneshot the confirm polled a unit that could not
## start until the confirm returned: the replay always failed at
## ``confirmTimeout`` and was reverted, and ``multi-user.target`` waited
## that long too (issue
## ``2026-11-15-floor-a-boot-replay-cannot-confirm-a-health-checked-floored-unit-so-it-always-reverts``).
##
## The case: generation A has a floored control unit; generation B adds a
## floored oneshot (``RemainAfterExit=yes``) with ``healthCheck = "active"``
## and ``confirmTimeout = 20``. The switch from A to B is paused at
## ``step-5`` (the drivers' writes done) and the guest is hard-reset. After
## the boot:
##
## - the floored unit is still ordered after the re-assertion (the premise:
##   decision 144's ordering is in effect, nothing waived it);
## - the re-assertion reports that it replayed the switch to completion,
##   ``ok``, and no pending marker is left;
## - ``current`` is B's generation (not a re-applied A), and the floored
##   unit with the health check is active;
## - the re-assertion signalled readiness before it confirmed, and the
##   floored unit started after that signal and before the confirm ended
##   (the order decision 144 asks for, and the one that lets the confirm
##   see the unit).
##
## Falsifying build: ``REPRO_ADDON_MUTATION=boot-confirm-before-ready``
## (the re-assertion signals readiness only when it exits, as a oneshot's
## completion did): the replay is reverted after ``confirmTimeout`` -- red.
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
    let journal = g.waitReasserted()
    discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                   timeoutSec = 600)
    record["reassertJournal"] = %journal
    let after = g.exec("systemctl show -p After " & Checked).stdout
    step("the replayed unit is loaded with that ordering",
         "repro-addon-reassert.service" in after, after)
    step("the re-assertion replayed the switch to completion",
         "replayed the switch to completion" in journal and
         "did not complete and was reverted" notin journal, journal)
    step("the re-assertion reported ok",
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
    # The order: the re-assertion's start job completed (it signalled
    # readiness) before the floored unit started, and the floored unit
    # started before the re-assertion's process exited (the confirm ran
    # after it).
    let ready = g.monotonicUsec("repro-addon-reassert.service",
                                "ActiveEnterTimestamp")
    let exited = g.monotonicUsec("repro-addon-reassert.service",
                                 "ExecMainExitTimestamp")
    let started = g.monotonicUsec(Checked, "ExecMainStartTimestamp")
    record["monotonicUsec"] = %*{"reassertReady": ready,
      "reassertExited": exited, "flooredStarted": started}
    step("the floored unit started after the re-assertion was ready and " &
         "before it exited", ready > 0 and started >= ready and
         exited > started, "ready " & $ready & ", floored started " &
         $started & ", re-assertion exited " & $exited)
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
