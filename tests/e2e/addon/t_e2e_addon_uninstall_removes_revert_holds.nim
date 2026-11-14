## Add-on VM gate: uninstall removes a revert's hold (ReproOS Add-On Mode
## spec §6.4 step 2, §4.2; §10.1 "A revert does not refuse on its own floor
## check" and §13 decision 133; reprobuild-pm issue
## ``2026-11-14-floor-a-revert-hold-is-in-no-ledger-so-uninstall-leaves-it``).
##
## On each base:
##
## 1. a floored unit with a ``StateDirectory=`` applies; it is stopped and
##    its directory replaced by a root tree, so the next apply is refused
##    by the floor check and its revert commits holding the unit, with the
##    persistent hold ``/etc/systemd/system/a9r-st.service.d/zz-repro-addon-
##    revert-hold.conf`` written and no switch pending;
## 2. the ledger copy the revert wrote records the hold (class
##    ``revertHold``) and the ``a9r-st.service.d`` directory it made, and
##    the record of the directories it was about to make
##    (``revert-hold-dirs``, written before it made them) is gone;
## 3. ``repro system addon uninstall`` exits 0 and leaves neither the hold
##    nor its directory, and the base's fingerprint is what it was before
##    bootstrap (the fixture's account and the refused tree aside, which
##    the gate made itself);
## 4. an operator's own unit of the same name, written after the uninstall,
##    starts (the issue's measurement: before the fix ``start=1``,
##    ``AssertResult=no``).
##
## The second test does the same with the guest hard-reset while the
## revert is paused at ``revert:step-8``: its ledger is written, it has not
## committed. The boot's recovery replays the revert from the ledger the
## refused switch started from, which names no hold directory, so only the
## record (``revert-hold-dirs``) tells the replay the directory is the
## add-on's. Steps 2 to 4 hold after the replay commits.
##
## Falsifying builds (red here): ``revert-hold-unledgered``, the engine
## before the fix: the ledger records no hold, uninstall leaves it, and
## the operator's unit cannot start; ``revert-hold-dirs-cleared-at-ledger``
## (red on the second test only): the record goes with the revert's
## ledger, the replay leaves the directory unclaimed, and uninstall leaves
## it behind, empty; ``revert-hold-not-synced`` (red on the second test
## only): the hold reaches the disk empty and the held unit starts at the
## boot.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``. The second test pauses a switch and
## resets a QEMU guest, so it needs the seam build, which
## ``scripts/run_addon_gate.sh`` makes for this gate.
##
## *Mocking.* None: the real add-on, the base's own systemd.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const Gate = "e2e_addon_uninstall_removes_revert_holds"
const Head = "addOn {\n  managedEtcPrefixes = []\n}\n\n"
const Pending = "/var/lib/repro/system/addon/pending"
const HoldDir = "/etc/systemd/system/a9r-st.service.d"
const Hold = HoldDir & "/zz-repro-addon-revert-hold.conf"
const RecordPath = "/var/lib/repro/system/addon/revert-hold-dirs"

proc unitResource(name, service, binary: string; description: string): string =
  ## A floored oneshot unit that stays active, enabled.
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=" & description & "\n" &
    "\n[Service]\nType=oneshot\nRemainAfterExit=yes\n" & service &
    "ExecStart=" & binary & " --version\n" &
    "\n[Install]\nWantedBy=multi-user.target\n\"\n  enabled = true\n}\n"

proc startedPastItsAsserts(journal: string): bool =
  ## Whether the unit's journal shows a start that got past its assertions.
  ## A start the hold refused logs "Starting requested but asserts failed"
  ## and "Assertion failed for ...", which ``journalStarted`` would count.
  for l in journal.splitLines():
    if ("Started " in l or "Starting " in l) and "skipped" notin l and
        "asserts failed" notin l:
      return true
  false

proc runBase(b: BaseImage; record: JsonNode; resetAt = ""): seq[string] =
  ## ``resetAt``: a seam point of the refused switch's revert at which the
  ## guest is hard-reset, or "" for a revert that runs to its commit.
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail[max(0, detail.len - 3000) .. ^1])
  proc tail(s: string; n = 3000): string = s[max(0, s.len - n) .. ^1]
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    # The unit's account, made before the base fingerprint: the gate's, not
    # the add-on's.
    discard g.run("useradd -r -M -s /usr/sbin/nologin a9e")
    if resetAt.len > 0:
      # The base after a clean reboot, as the guest will be after the
      # reset: a first boot runs units (``ldconfig.service`` and the like,
      # ``ConditionNeedsUpdate=``) that a later boot does not.
      g.rebootGuest()
    let f0 = g.takeFingerprint(repro)
    if not g.bootstrapAddon(repro, step): return fails
    let binary = g.run("ls -d /repro/store/prefixes/repro-addon/*/bin/repro " &
                       "| head -1").strip()
    let st = proc (d: string): string =
      Head & unitResource("a9r-control.service", "", binary, d) &
        unitResource("a9r-st.service", "User=a9e\nStateDirectory=a9r-st\n", binary, d)
    var r = g.applyProfile(repro, "u1", st("u1"))
    step("a floored unit with a StateDirectory applies", r.exitCode == 0,
         tail(r.stdout & r.stderr))
    # A root tree in its place, made after its last run ended: the next
    # apply's check refuses it, and so does its revert's, which holds it.
    discard g.run("systemctl stop a9r-st.service; rm -rf /var/lib/a9r-st; " &
                  "mkdir /var/lib/a9r-st; touch /var/lib/a9r-st/theirs")
    if resetAt.len == 0:
      r = g.applyProfile(repro, "u2", st("u2"))
      let out2 = r.stdout & r.stderr
      let pending = g.exec("test -e " & Pending & " && cat " & Pending & "; true").stdout
      step("the refused apply's revert commits holding the unit, nothing pending",
           r.exitCode != 0 and "keeps a9r-st.service on hold" in out2 and
           "could not be rolled back" notin out2 and pending.strip().len == 0,
           tail(out2) & "\npending=" & pending)
    else:
      # "Not synced" means "not on the disk" at the reset
      # (``holdWriteback``), so a hold written without a sync comes back
      # empty every time, not when the kernel happens to be slow.
      g.holdWriteback()
      let paused = g.startSwitchPausedAt(repro, "u2", st("u2"), resetAt)
      step("the refused apply's revert paused at " & resetAt,
           paused.exitCode == 0, tail(paused.stdout & paused.stderr))
      if paused.exitCode != 0: return fails
      let log = g.exec("cat /root/addon/bg-apply.log").stdout
      let ledgerBefore = g.ledgerOf()
      var dirBefore = false
      for l in ledgerBefore.splitLines():
        let f = l.split('\t')
        if f.len > 1 and f[0] == "dir" and f[1] == HoldDir: dirBefore = true
      step("the paused revert has written the hold, its ledger and the record",
           "keeps a9r-st.service on hold" in log and
           g.exec("test -f " & Hold).exitCode == 0 and dirBefore and
           g.exec("grep -qx " & HoldDir & " " & RecordPath).exitCode == 0,
           tail(log) & "\n" & ledgerBefore & "\nrecord:\n" &
           g.exec("cat " & RecordPath & " 2>&1").stdout)
      g.hardResetAfterSettle()
      g.boot()
      let journal = g.waitReasserted()
      record["reassert"] = %journal
      let pending = g.exec("test -e " & Pending & " && cat " & Pending & "; true").stdout
      # The hold was on the disk, whole, so the held unit did not start at
      # the boot, before the recovery ran either.
      let unitJournal = g.exec("journalctl -b -o cat --no-pager -u a9r-st.service").stdout
      let state = g.exec("systemctl show -p ActiveState -p AssertResult a9r-st.service").stdout
      step("the boot's recovery replays the revert to its commit, nothing pending",
           pending.strip().len == 0 and "ActiveState=active" notin state,
           tail(journal) & "\npending=" & pending & "\n" & state)
      step("the held unit did not start at the boot",
           not startedPastItsAsserts(unitJournal) and
           "Assertion failed for a9r-st.service" in unitJournal,
           unitJournal & "\n" & state)
    step("the revert's hold is written under /etc",
         g.exec("test -f " & Hold).exitCode == 0,
         g.exec("ls -la " & HoldDir & " 2>&1").stdout)
    let ledger = g.ledgerOf()
    record["ledgerAfterRevert"] = %ledger
    var holdLine, dirLine = false
    for l in ledger.splitLines():
      let f = l.split('\t')
      if f.len > 1 and f[0] == "revertHold" and f[1] == Hold: holdLine = true
      if f.len > 1 and f[0] == "dir" and f[1] == HoldDir: dirLine = true
    step("the revert's ledger records the hold and the directory it made",
         holdLine and dirLine, ledger)
    # The directories the revert recorded before creating them are in its
    # committed ledger now, and the record is gone.
    step("the revert's record of the directories it made is cleared at its commit",
         g.exec("test -e " & RecordPath).exitCode != 0,
         g.exec("cat " & RecordPath & " 2>&1").stdout)
    let un = g.exec(repro & " system addon uninstall", timeoutSec = 1200)
    let left = g.exec("ls -la " & HoldDir & " 2>&1; ls /etc/systemd/system/a9r-st.service 2>&1").stdout
    step("uninstall exits 0 and leaves neither the hold nor its directory",
         un.exitCode == 0 and g.exec("test -e " & HoldDir).exitCode != 0,
         tail(un.stdout & un.stderr) & "\n" & left)
    # The refused tree is the gate's own; then nothing of the add-on's is
    # left that the base did not have.
    discard g.run("rm -rf /var/lib/a9r-st; systemctl reset-failed 'a9r-*' 2>/dev/null; true")
    let id = identityReport(f0, g.takeFingerprint(repro))
    step("the base is as it was before bootstrap", id.ok, id.text)
    let own = g.exec("printf '[Unit]\\nDescription=the operator own unit\\n" &
      "[Service]\\nType=oneshot\\nRemainAfterExit=yes\\nExecStart=/bin/true\\n' " &
      "> /etc/systemd/system/a9r-st.service; systemctl daemon-reload; " &
      "systemctl start a9r-st.service; echo start=$?; " &
      "systemctl show -p AssertResult -p DropInPaths -p ActiveState a9r-st.service")
    record["operatorUnit"] = %own.stdout
    step("an operator's own unit of that name starts after the uninstall",
         "start=0" in own.stdout and "ActiveState=active" in own.stdout and
         g.exec("systemctl show -p DropInPaths --value a9r-st.service").stdout.strip().len == 0,
         own.stdout & own.stderr)
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

proc runGate(resetAt: string) =
  var failures: seq[string]
  for b in selectedBases():
    let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
      "backend": (if useIncus(): "incus" else: "qemu"),
      "mutation": mutation(), "reprobuild": gitHead(),
      "resetAt": resetAt, "started": $now().utc}
    let f = runBase(b, record, resetAt)
    record["verdict"] = %(if f.len == 0: "green" else: "red")
    record["finished"] = %($now().utc)
    echo "record: ", writeRecord(Gate, record)
    failures.add(f)
  for f in failures: echo "FAIL ", f
  check failures.len == 0

suite Gate:
  test "uninstall removes a revert's hold, and an operator's unit of that name starts":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      runGate("")

  test "the same after a reset between the revert's ledger and its commit":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      runGate("revert:step-8")
