## Gate ``e2e_arch_addon_takeover_restore_rechecked`` (spec
## ReproOS-Add-On-Mode §4.3.1, §7.2, §7.7; §13 decision 89).
##
## The two paths of a ``takeOver`` removal that only a switch stopped in the
## middle reaches, driven through the seam build's pause before step 6's
## restore (``REPRO_ADDON_TEST_SEAMS=1``):
##
## - **The write-time re-check.** A switch that removes a taken-over backup
##   file decides at plan time which bytes go back (the recorded ones: the
##   package has not changed). While it is paused before the restore the
##   package is upgraded to a version whose packaged file changed, so the
##   database's ``%BACKUP%`` and the ``.pacnew`` now call for the other
##   undo. The resumed switch must not restore on its stale reading: the
##   path keeps the add-on's copy, the ledger keeps the entry, the apply
##   reports the change as drift (exit 1). The next apply decides afresh
##   and installs the ``.pacnew``.
## - **A replay keeps an undo it cannot carry out.** A switch that removes a
##   taken-over file whose ``.pacnew`` holds the packaged version is
##   stopped (``SIGKILL``) before the restore; the ``.pacnew`` is then edited
##   by hand, so no rule allows the restore any more. ``repro system addon
##   recover`` must finish the switch -- its other removal, a plain file of
##   the add-on's (``own.conf``), goes -- without restoring anything at the
##   take-over's path: the add-on's copy and the ledger entry stay, the
##   edited ``.pacnew`` is untouched. Once the ``.pacnew`` holds the packaged version again, an
##   apply restores it.
##
## Each step's restore, or its absence, is observed on the guest: the path's
## SHA-256, the ``.pacnew``, the ledger. ``makepkg`` fixture packages
## (``arch_fixture_packages``) own the files.
##
## Falsifying mutations: ``takeover-skips-write-recheck`` (the restore
## carried out as planned) must turn the re-check step red;
## ``takeover-replay-refuses`` (the replay refuses instead of keeping) must
## turn the replay step red -- the recovery then does not finish the
## switch's other removal. Each is judged by
## ``arch_gate_support.falsifierVerdict``.
##
## Bases: ``REPRO_ADDON_BASES`` (the recipe's default is
## ``arch-btrfs-amd64,arch-ext4-amd64``). The seam build is a test-only
## artefact; no product build carries the pause.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_arch_addon_takeover_restore_rechecked``).
##
## *Mocking.* None: real Arch guests, real makepkg, pacman and systemd, the
## static add-on binary built with its test seams.

import std/[json, os, strutils, tables, times, unittest]

import repro_test_support/reasoned_skip
import repro_addon/[fingerprint, ledger]

import ./arch_fixture_packages
import ./arch_gate_support

const
  Gate = "e2e_arch_addon_takeover_restore_rechecked"
  Dir = "/etc/repro-fx"
  PendingMarker = "/var/lib/repro/system/addon/pending"

proc pathOf(c: string): string = Dir & "/" & c & ".conf"
proc pkgOf(c: string): string = "repro-fx-" & c
proc addOnBytes(c: string): string = "# the add-on's " & c & "\nmanaged = yes\n"
proc packaged(c: string; v: int): string =
  "# " & c & " as packaged, version " & $v & "\nsetting = " & $v & "\n"

const Own = "/etc/repro-fx/own.conf"
  ## A plain file of the add-on's own, removed by the same switch as the
  ## replayed take-over: a replay that keeps the take-over finishes this
  ## removal; one that refuses the whole switch (and reverts) does not.

proc profile(cases: openArray[string]; own = true): string =
  result = "addOn {\n  managedEtcPrefixes = [\"" & Dir & "/\"]\n}\n"
  if own:
    result.add("\nfs.systemFile {\n  path = \"" & Own & "\"\n  content = \"own\n\"\n}\n")
  for c in cases:
    result.add("\nfs.systemFile {\n  path = \"" & pathOf(c) & "\"\n" &
      "  content = \"" & addOnBytes(c) & "\"\n  collision = \"takeOver\"\n}\n")

proc listed(ledgerText, path: string): int =
  for e in parseLedger(ledgerText).entries:
    if e.path == path: inc result

proc killPendingOwner(g: Guest): tuple[ok: bool; detail: string] =
  ## SIGKILL the apply that owns the pending marker -- the paused switch
  ## this gate started -- and only it (the marker names its PID, checked to
  ## be a ``repro infra apply``).
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

proc expectedFalsifier(mut: string; b: BaseImage): Falsifier =
  let common = @["baseline: udevadm settle and systemctl daemon-reload",
    "preflight is compatible", "bootstrap",
    "gen1: both backup files are taken over"]
  case mut
  of "takeover-skips-write-recheck":
    Falsifier(
      required: @["recheck: the resumed switch leaves the path as drift instead of restoring stale bytes"],
      mayBeRed: @["recheck: the next apply decides afresh and installs the .pacnew"],
      mustRunGreen: common & @["recheck: the switch removing it stops before the restore",
        "recheck: meanwhile an upgrade changes the packaged file (.pacnew, new %BACKUP%)",
        "replay: an upgrade leaves the packaged version in .pacnew",
        "replay: the switch removing it stops before the restore",
        "replay: the switch is killed (SIGKILL) before the restore",
        "replay: recover keeps the take-over (copy and ledger entry stay) and finishes the switch's other removal",
        "replay: with the .pacnew put right, an apply installs it", "uninstall"])
  of "takeover-replay-refuses":
    Falsifier(
      required: @["replay: recover keeps the take-over (copy and ledger entry stay) and finishes the switch's other removal"],
      mayBeRed: @["replay: with the .pacnew put right, an apply installs it", "uninstall"],
      mustRunGreen: common & @["recheck: the switch removing it stops before the restore",
        "recheck: meanwhile an upgrade changes the packaged file (.pacnew, new %BACKUP%)",
        "recheck: the resumed switch leaves the path as drift instead of restoring stale bytes",
        "recheck: the next apply decides afresh and installs the .pacnew",
        "replay: an upgrade leaves the packaged version in .pacnew",
        "replay: the switch removing it stops before the restore",
        "replay: the switch is killed (SIGKILL) before the restore"])
  else: raise unknownMutation(Gate, mut)

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
    g.installMakepkgPrerequisites()
    var files = initTable[string, string]()
    for (c, v, ver) in [("recheck", 1, "1"), ("recheck", 2, "2"),
                        ("replay", 1, "1"), ("replay", 2, "2")]:
      files[c & "-" & ver] = g.buildArchFixture(ArchFixturePackage(
        name: pkgOf(c), pkgver: ver, pkgrel: "1",
        files: @[fxFile(pathOf(c), packaged(c, v), backup = true)]))
    let inst = g.exec("pacman -U --noconfirm " & files["recheck-1"] & " " &
                      files["replay-1"] & " 2>&1", timeoutSec = 900)
    if inst.exitCode != 0:
      raise newException(TestBedError, "installing the fixtures failed: " &
        inst.stdout & inst.stderr)
    g.settleBaseline(step)
    if not g.bootstrapArch(repro, step).ok: return fails
    let a1 = g.applyProfile(repro, "gen1", profile(["recheck", "replay"]))
    step("gen1: both backup files are taken over", a1.exitCode == 0 and
         g.sha256InGuest(pathOf("recheck")) == sha256Hex(addOnBytes("recheck")) and
         g.sha256InGuest(pathOf("replay")) == sha256Hex(addOnBytes("replay")),
         a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails

    # --- The write-time re-check.
    let paused = g.startSwitchPausedAt(repro, "gen2", profile(["replay"]), "step-6")
    step("recheck: the switch removing it stops before the restore",
         paused.exitCode == 0, paused.stdout & paused.stderr)
    if paused.exitCode != 0: return fails
    let up = g.pacmanInstall(files["recheck-2"])
    step("recheck: meanwhile an upgrade changes the packaged file (.pacnew, new %BACKUP%)",
         up.exitCode == 0 and
           g.sha256InGuest(pathOf("recheck") & ".pacnew") == sha256Hex(packaged("recheck", 2)),
         up.stdout & up.stderr)
    let res = g.resumeSwitch()
    let saidRes = res.stdout & res.stderr
    record["recheckResumed"] = %saidRes
    step("recheck: the resumed switch leaves the path as drift instead of restoring stale bytes",
         res.exitCode == 1 and "changed after the plan" in saidRes and
           g.sha256InGuest(pathOf("recheck")) == sha256Hex(addOnBytes("recheck")) and
           g.sha256InGuest(pathOf("recheck") & ".pacnew") == sha256Hex(packaged("recheck", 2)) and
           listed(g.ledgerOf(), pathOf("recheck")) == 1,
         "exit " & $res.exitCode & "\n" & saidRes)
    block:
      let a = g.applyProfile(repro, "gen2b", profile(["replay"]))
      let qkk = g.pacmanQkkClean(pkgOf("recheck"))
      step("recheck: the next apply decides afresh and installs the .pacnew",
           a.exitCode == 0 and
             g.sha256InGuest(pathOf("recheck")) == sha256Hex(packaged("recheck", 2)) and
             g.sha256InGuest(pathOf("recheck") & ".pacnew") == "absent" and
             listed(g.ledgerOf(), pathOf("recheck")) == 0 and qkk.ok,
           "exit " & $a.exitCode & "\n" & a.stdout & a.stderr & "\n" & qkk.output)

    # --- A replay keeps an undo it cannot carry out.
    block:
      let up2 = g.pacmanInstall(files["replay-2"])
      step("replay: an upgrade leaves the packaged version in .pacnew",
           up2.exitCode == 0 and
             g.sha256InGuest(pathOf("replay") & ".pacnew") == sha256Hex(packaged("replay", 2)),
           up2.stdout & up2.stderr)
    let paused2 = g.startSwitchPausedAt(repro, "gen3", profile([], own = false), "step-6")
    step("replay: the switch removing it stops before the restore",
         paused2.exitCode == 0, paused2.stdout & paused2.stderr)
    if paused2.exitCode != 0: return fails
    let killed = g.killPendingOwner()
    step("replay: the switch is killed (SIGKILL) before the restore", killed.ok,
         killed.detail)
    if not killed.ok: return fails
    discard g.run("printf '# edited by hand\\n' >> " & pathOf("replay") & ".pacnew")
    let editedSha = g.sha256InGuest(pathOf("replay") & ".pacnew")
    let rec = g.exec(repro & " system addon recover", timeoutSec = 900)
    let saidRec = rec.stdout & rec.stderr
    record["replayRecover"] = %saidRec
    record["replayRecoverExit"] = %rec.exitCode
    step("replay: recover keeps the take-over (copy and ledger entry stay) and finishes the switch's other removal",
         g.exec("test -e " & PendingMarker).exitCode != 0 and
           g.sha256InGuest(Own) == "absent" and listed(g.ledgerOf(), Own) == 0 and
           g.sha256InGuest(pathOf("replay")) == sha256Hex(addOnBytes("replay")) and
           g.sha256InGuest(pathOf("replay") & ".pacnew") == editedSha and
           listed(g.ledgerOf(), pathOf("replay")) == 1,
         "exit " & $rec.exitCode & "\n" & saidRec & "\nmarker: " &
           g.exec("ls -la " & PendingMarker & " 2>&1").stdout)
    discard g.run("bsdtar -xOf " & files["replay-2"].quoteShell & " " &
      pathOf("replay")[1 .. ^1] & " > " & pathOf("replay") & ".pacnew")
    block:
      let a = g.applyProfile(repro, "gen3b", profile([], own = false))
      let qkk = g.pacmanQkkClean(pkgOf("replay"))
      step("replay: with the .pacnew put right, an apply installs it",
           a.exitCode == 0 and
             g.sha256InGuest(pathOf("replay")) == sha256Hex(packaged("replay", 2)) and
             g.sha256InGuest(pathOf("replay") & ".pacnew") == "absent" and
             listed(g.ledgerOf(), pathOf("replay")) == 0 and qkk.ok,
           "exit " & $a.exitCode & "\n" & a.stdout & a.stderr & "\n" & qkk.output)
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

suite Gate:
  test "a take-over's restore is decided again before it is carried out, and a replay keeps what it cannot restore":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    elif not testSeams():
      echo "FAIL ", Gate, " needs the seam build (REPRO_ADDON_TEST_SEAMS=1)"
      check false
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        if isOmarchyBase(b):
          failures.add(b.name & ": " & Gate & " runs on the plain Arch guests")
          continue
        let record = archGateRecord(Gate)
        record["base"] = %b.name
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        let judged = judgeRun(Gate, record, f, expectedFalsifier, b)
        echo "record: ", writeRecord(Gate, record)
        failures.add(judged)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
