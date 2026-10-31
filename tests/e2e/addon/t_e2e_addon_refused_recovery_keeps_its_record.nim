## Gate ``e2e_addon_refused_recovery_keeps_its_record`` (milestone A5;
## spec §7.2, §7.3, §7.7; threat model T25).
##
## A replay or a revert can be refused like any switch: its step 2 must
## stop an ``exclusive`` unit, and an instance that will not die (it
## ignores SIGTERM and its unit sets ``SendSIGKILL=no``) is never left
## running beside its successor (§7.3). Such a refusal must not cost the
## recovery its record: the pending marker and the write-ahead plan are
## the only description of a host that may be half-switched. A fresh
## switch refused before its own flip changed nothing and may forget
## itself; a replay or a revert never may, because its own marker is
## fresh -- written at its step 1 -- and says nothing about how far the
## switch it recovers had got.
##
## The fixture is one exclusive unit whose instance ignores SIGTERM while
## ``/run/repro-fixture-stubborn`` names its generation, and a file per
## generation. Cases:
##
## - **revert refused**: B's health check fails (a TCP port nothing
##   listens on), and B's instance will not stop, so the revert's step 2
##   refuses. The apply fails saying the switch could not be rolled back;
##   the marker stays (a revert's); an operator's ``recover`` meets the
##   same instance, refuses again and still keeps it; once the instance is
##   gone ``recover`` finishes the revert: the host is A, ``ok``, no
##   marker, the attempt recorded ``rolled-back``.
## - **boot replay refused**: the switch to B is interrupted after its
##   flip (``step-3``, hard reset), the boot's recovery is held at its
##   start and an instance of the unit is made stubborn under it; released,
##   the replay's step 2 refuses, and so does the revert it falls back to.
##   The unit reports ``degraded`` and the marker stays; once the instance
##   is gone ``recover`` ends in A or B, ``ok``, no marker.
## - **an apply recovers first** (§7.7; the race of an apply with a boot
##   recovery that did not finish): the switch is interrupted again, the
##   boot's recovery is held and then killed (as its start timeout would),
##   and an operator applies A. The marker's owner is a previous boot's,
##   so the apply recovers the interrupted switch first, under the locks
##   it holds, and then applies: it succeeds, the host is A and no marker
##   is left.
##
## Falsifying mutation ``refused-recovery-forgets-marker``: a refusal in a
## replay or a revert is undone like a fresh switch's, removing the marker
## and plan; the first two cases go red (no marker after the refusal).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``; QEMU only (a reset needs a disk);
## the seam build (``scripts/run_addon_gate.sh``).
##
## *Mocking.* None: real images, a real stubborn process, real resets.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  Unit = "repro-fixture-ex.service"
  Stubborn = "/run/repro-fixture-stubborn"
  Script = "/usr/local/libexec/repro-fixture-stubborn"
  GenFile = "/etc/repro-fixture/gen.conf"
  # An instance ignores SIGTERM while the control file names its
  # generation; the `sleep` child dies, the shell stays.
  ScriptBody = "#!/bin/sh\n" &
    "trap 'if grep -qx \"$GEN\" " & Stubborn & " 2>/dev/null; then :; " &
    "else exit 0; fi' TERM\n" &
    "while :; do sleep 1 & wait $!; done\n"

proc unitText(gen: string): string =
  "[Unit]\nDescription=stubborn exclusive fixture\n[Service]\nEnvironment=GEN=" &
    gen & "\nExecStart=" & Script & "\nTimeoutStopSec=3\nSendSIGKILL=no\n\n" &
    "[Install]\nWantedBy=multi-user.target\n"

proc profile(gen: string; check = ""; timeout = 0): string =
  "addOn {\n  managedEtcPrefixes = [\"/etc/repro-fixture/\"]\n" &
    (if timeout > 0: "  confirmTimeout = " & $timeout & "\n" else: "") & "}\n\n" &
    "fs.systemFile {\n  path = \"" & GenFile & "\"\n  content = \"" & gen &
    "\n\"\n}\n\n" &
    "systemd.systemUnit {\n  name = \"" & Unit & "\"\n  content = \"" &
    unitText(gen) & "\"\n  exclusive = true\n" &
    (if check.len > 0: "  healthCheck = \"" & check & "\"\n" else: "") & "}\n\n"

proc markerPresent(g: Guest): bool =
  g.exec("test -e " & SeamDir & "/pending").exitCode == 0

proc markerField(g: Guest; field: string): string =
  g.exec("sed -n 's/^" & field & "\\t//p' " & SeamDir &
         "/pending 2>/dev/null").stdout.strip()

proc releaseInstance(g: Guest) =
  ## The operator's remedy: the stubborn instance is made to go.
  discard g.exec("rm -f " & Stubborn & "; systemctl kill --signal=KILL " &
    Unit & " 2>/dev/null; for i in 1 2 3 4 5 6 7 8 9 10; do " &
    "pgrep -f " & Script & " >/dev/null || break; sleep 1; done; " &
    "systemctl reset-failed " & Unit & " 2>/dev/null; true")

proc genNow(g: Guest): tuple[file, unitGen, state: string] =
  (g.exec("cat " & GenFile & " 2>/dev/null").stdout.strip(),
   g.exec("systemctl show -p Environment --value " & Unit).stdout.strip(),
   g.exec("systemctl is-active " & Unit).stdout.strip())

proc waitHeldRecovery(g: Guest; timeoutSec = 240): bool =
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    if g.exec("cat " & SeamDir & "/test-paused-at 2>/dev/null").stdout.strip() ==
        "recovery":
      return true
    sleep(1000)
  false

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
    writeFile(g.runDir / "stubborn.sh", ScriptBody)
    discard g.run("mkdir -p /usr/local/libexec")
    g.copyTo(g.runDir / "stubborn.sh", Script)
    discard g.run("chmod 0755 " & Script)
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    var r = g.applyProfile(repro, "a", profile("A"))
    step("generation A applied", r.exitCode == 0, r.stdout & r.stderr)

    # --- Case 1: the revert of a failed switch is refused.
    let before = g.rolledBackRecords()
    discard g.run("echo B > " & Stubborn)
    r = g.applyProfile(repro, "bf", profile("B", "tcp:127.0.0.1:1", 5))
    step("revert-refused: the failed switch says it could not be rolled back",
         r.exitCode != 0 and "could not be rolled back" in (r.stdout & r.stderr),
         r.stdout & r.stderr)
    step("revert-refused: the pending marker is kept, a revert's",
         g.markerPresent() and g.markerField("purpose") == "revert",
         g.exec("cat " & SeamDir & "/pending 2>&1").stdout)
    var rec = g.exec(repro & " system addon recover", timeoutSec = 1200)
    step("revert-refused: a recovery meeting the same instance keeps the marker",
         rec.exitCode != 0 and g.markerPresent() and
         "neither finished nor reverted" in rec.stdout,
         rec.stdout & rec.stderr)
    g.releaseInstance()
    rec = g.exec(repro & " system addon recover", timeoutSec = 1200)
    step("revert-refused: with the instance gone, recover finishes the revert",
         rec.exitCode == 0 and "reassert: ok" in rec.stdout,
         rec.stdout & rec.stderr)
    var cur = g.genNow()
    step("revert-refused: the host is A, its unit active",
         cur.file == "A" and cur.unitGen == "GEN=A" and cur.state == "active",
         $cur)
    step("revert-refused: no marker is left", not g.markerPresent(), "")
    step("revert-refused: the attempt is recorded rolled-back",
         g.rolledBackRecords() > before,
         $before & " -> " & $g.rolledBackRecords())

    # --- Case 2: the boot's replay is refused.
    discard g.run("touch " & SeamDir & "/test-pause-recovery && sync")
    let paused = g.startSwitchPausedAt(repro, "b", profile("B"), "step-3")
    step("boot-replay-refused: the switch to B paused after its flip",
         paused.exitCode == 0, paused.stdout & paused.stderr)
    if paused.exitCode == 0:
      g.hardResetAfterSettle()
      g.boot()
      step("boot-replay-refused: the boot's recovery is held",
           g.waitHeldRecovery(), "")
      discard g.run("printf 'A\\nB\\n' > " & Stubborn & "; systemctl is-active " &
        Unit & " >/dev/null || systemctl start " & Unit & "; true")
      step("boot-replay-refused: a stubborn instance runs under the recovery",
           g.exec("systemctl is-active " & Unit).stdout.strip() == "active", "")
      discard g.run("touch " & SeamDir & "/test-resume")
      let j = g.waitReasserted()
      step("boot-replay-refused: the unit reports degraded",
           "repro-addon reassert: degraded" in j, j)
      step("boot-replay-refused: the pending marker is kept",
           g.markerPresent(),
           g.exec("cat " & SeamDir & "/pending 2>&1").stdout & "\n" & j)
      g.releaseInstance()
      rec = g.exec(repro & " system addon recover", timeoutSec = 1200)
      step("boot-replay-refused: with the instance gone, recover finishes",
           rec.exitCode == 0 and "reassert: ok" in rec.stdout,
           rec.stdout & rec.stderr)
      cur = g.genNow()
      step("boot-replay-refused: the host is one generation, its unit active",
           cur.file in ["A", "B"] and cur.unitGen == "GEN=" & cur.file and
           cur.state == "active", $cur)
      step("boot-replay-refused: no marker is left", not g.markerPresent(), "")

    # --- Case 3: an apply after a boot recovery that did not finish.
    if g.genNow().file != "A":
      r = g.applyProfile(repro, "a", profile("A"))
      step("apply-recovers-first: back to A", r.exitCode == 0, r.stdout & r.stderr)
    discard g.run("touch " & SeamDir & "/test-pause-recovery && sync")
    let p3 = g.startSwitchPausedAt(repro, "b", profile("B"), "step-3")
    step("apply-recovers-first: the switch to B paused after its flip",
         p3.exitCode == 0, p3.stdout & p3.stderr)
    if p3.exitCode == 0:
      g.hardResetAfterSettle()
      g.boot()
      step("apply-recovers-first: the boot's recovery is held",
           g.waitHeldRecovery(), "")
      # Killed where it waits, as its start timeout would kill it.
      discard g.run("systemctl kill --signal=KILL repro-addon-reassert.service; " &
        "for i in 1 2 3 4 5 6 7 8 9 10; do systemctl is-active -q " &
        "repro-addon-reassert.service || break; sleep 1; done; rm -f " &
        SeamDir & "/test-paused-at " & SeamDir & "/test-pause-at; sync")
      step("apply-recovers-first: the marker is still there", g.markerPresent(), "")
      r = g.applyProfile(repro, "a", profile("A"))
      step("apply-recovers-first: the apply recovered the switch first and applied",
           r.exitCode == 0, r.stdout & r.stderr)
      cur = g.genNow()
      step("apply-recovers-first: the host is A, its unit active",
           cur.file == "A" and cur.unitGen == "GEN=A" and cur.state == "active",
           $cur)
      step("apply-recovers-first: no marker is left", not g.markerPresent(), "")
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
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

suite "e2e_addon_refused_recovery_keeps_its_record":
  test "a refused replay or revert keeps the recovery's record":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_refused_recovery_keeps_its_record)")
    elif useIncus():
      skip("a hard reset is of a disk image; QEMU only")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_refused_recovery_keeps_its_record",
          "base": b.name, "arch": b.debArch, "backend": "qemu",
          "mutation": mutation(), "testSeams": testSeams(),
          "reprobuild": gitHead(), "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_refused_recovery_keeps_its_record", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
