## Gate ``e2e_arch_addon_alpm_hook_reports`` (milestone AR6; spec
## ReproOS-Add-On-Mode §4.3.1, §7.7, §7.8; threat model T45-T47, G43;
## falsifier 15).
##
## The Arch counterpart of A10's ``e2e_addon_hook_reports_new_file_on_ledger_path``
## and ``e2e_addon_apt_hook_never_blocks_dpkg``. Generation 0 carries the
## ALPM hook ``/etc/pacman.d/hooks/90-repro-addon.hook``; generation 1
## declares, under ``/etc/repro-fx/``, a file no package owns
## (``new.conf``) and two taken-over backup files of ``makepkg`` fixture
## packages (``up.conf`` of ``repro-fx-up``, ``gone.conf`` of
## ``repro-fx-gone``). Then, each a real pacman transaction that must
## succeed, each report naming the package and the path (pacman's output,
## the hook's event log, the journal), each followed by the next plan:
##
## - *pacnew*: ``repro-fx-up`` is upgraded to a version whose packaged file
##   changed: pacman keeps the add-on's copy and writes ``up.conf.pacnew``;
##   the hook reports the vendor change, and the next plan reports it too
##   (a note that never changes the plan's outcome: the ``.pacnew`` is
##   pacman's normal state after a vendor update under a ``takeOver``);
## - *pacsave*: ``repro-fx-gone`` is removed: pacman moves the add-on's copy
##   to ``gone.conf.pacsave``; the hook reports it (and the ledger path
##   gone), and the next plan reports it;
## - *install*: ``repro-fx-new`` ships ``new.conf``, installed with
##   ``--overwrite`` (pacman refuses an unowned file otherwise): the hook
##   reports the changed object and the package that now owns the path, and
##   the next plan refuses it with ``EAddOnPackageOwned`` naming the package;
## - *a packaged hook of the add-on's name*: ``repro-fx-hookname`` ships
##   ``/usr/share/libalpm/hooks/90-repro-addon.hook``, which the add-on's
##   file silently disables (T46): the hook reports it.
##
## Negative controls (the verify binary replaced by a stand-in, bind mounts
## undone after each, as in A10's gate), each around a pacman transaction
## that must succeed: a *failing* verification (``verify-failed``); a
## *hanging* one that ignores SIGTERM and leaves a grandchild -- the
## transaction finishes within the watchdog's bound (60 s, plus the 5 s
## kill grace) plus 5 s, the hook's log records ``verify-timeout`` and
## nothing of the hung process group is left; and, last, ``/repro/store``
## *deleted*: the hook fails to run the verification (``verify-missing``),
## the transaction still succeeds, and the re-assert unit reports
## ``degraded``.
##
## Falsifying mutations (``REPRO_ADDON_MUTATION``):
## ``alpm-hook-without-timeout`` -- the hang holds pacman past the bound
## (the gate kills it at ``HangDeadlineSec``); ``alpm-hook-ignores-pacnew``
## -- neither the hook nor the plan reports the ``.pacnew`` or the
## ``.pacsave``. Each turns exactly its steps red.
##
## Bases: ``REPRO_ADDON_BASES`` (the recipe's default is
## ``arch-btrfs-amd64,arch-ext4-amd64``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_arch_addon_alpm_hook_reports``).
##
## *Mocking.* The three faults replace the verify binary with a stand-in:
## the property under test is the hook's handling of whatever process it
## starts, and a fault is exactly a binary that fails, hangs or is gone.
## pacman, makepkg, systemd and the hook are real.

import std/[json, os, strutils, tables, times, unittest]

import repro_test_support/reasoned_skip
import repro_addon/[fingerprint, generation0]

import ./arch_fixture_packages
import ./arch_gate_support
import ./arch_update_support

const
  Gate = "e2e_arch_addon_alpm_hook_reports"
  Dir = "/etc/repro-fx"
  NewConf = Dir & "/new.conf"
  UpConf = Dir & "/up.conf"
  GoneConf = Dir & "/gone.conf"
  ShadowHook = "/usr/share/libalpm/hooks/90-repro-addon.hook"
  HookBoundSec = 60 + 5 + 5   ## the watchdog's bound, its grace, plus 5 s
  HangDeadlineSec = 300       ## the gate gives up on pacman here

proc fx(name, pkgver: string; files: seq[ArchFixtureFile]): ArchFixturePackage =
  ArchFixturePackage(name: name, pkgver: pkgver, pkgrel: "1", files: files)

proc profile(exe: string): string =
  "addOn {\n  managedEtcPrefixes = [\"" & Dir & "/\"]\n}\n\n" &
  "fs.systemFile {\n  path = \"" & NewConf & "\"\n  content = \"# the add-on's new.conf\n\"\n}\n\n" &
  "fs.systemFile {\n  path = \"" & UpConf & "\"\n  content = \"# the add-on's up.conf\n\"\n" &
    "  collision = \"takeOver\"\n}\n\n" &
  "fs.systemFile {\n  path = \"" & GoneConf & "\"\n  content = \"# the add-on's gone.conf\n\"\n" &
    "  collision = \"takeOver\"\n}\n"

proc expectedFalsifier(mut: string; b: BaseImage): Falsifier =
  let common = @["preflight is compatible", "bootstrap",
    "generation 0 carries the ALPM hook, as generation 0 renders it",
    "gen1: a file and two taken-over backup files apply",
    "pacnew: pacman -Syu-style upgrade of repro-fx-up succeeds and writes up.conf.pacnew",
    "pacsave: pacman -R repro-fx-gone succeeds and keeps gone.conf.pacsave",
    "install: pacman -U --overwrite of repro-fx-new succeeds",
    "install: the hook names repro-fx-new and new.conf",
    "install: the next plan refuses EAddOnPackageOwned naming repro-fx-new",
    "fails: the transaction succeeds and the log records verify-failed"]
  case mut
  of "alpm-hook-without-timeout":
    Falsifier(
      required: @["hangs: the transaction finishes within the watchdog's bound plus 5 s"],
      mayBeRed: @["hangs: the hook's log records verify-timeout",
                  "hangs: nothing of the hung process group is left",
                  "store deleted: the transaction succeeds, the hook records verify-missing",
                  "store deleted: the re-assert unit reports degraded"],
      mustRunGreen: common)
  of "alpm-hook-ignores-pacnew":
    Falsifier(
      required: @["pacnew: the hook names repro-fx-up and up.conf.pacnew",
                  "pacnew: the next plan reports the .pacnew",
                  "pacnew: the profile still applies, reporting the .pacnew",
                  "pacsave: the hook names repro-fx-gone and gone.conf.pacsave",
                  "pacsave: the next plan reports the .pacsave"],
      mayBeRed: @[],
      mustRunGreen: common & @[
        "hangs: the transaction finishes within the watchdog's bound plus 5 s",
        "store deleted: the transaction succeeds, the hook records verify-missing",
        "store deleted: the re-assert unit reports degraded"])
  else: raise unknownMutation(Gate, mut)

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  proc hookSaid(pacmanOut: string): string =
    pacmanOut & "\n--- event log\n" & g.logLines(AlpmHookLog).join("\n") &
      "\n--- journal\n" & g.journalOf(AlpmHookTag)
  try:
    g = newArchGuest(b)
    g.boot()
    g.prepareArchGuest()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha

    # Fixture packages, built before the baseline.
    g.installMakepkgPrerequisites()
    let upV1 = g.buildArchFixture(fx("repro-fx-up", "1",
      @[fxFile(UpConf, "# up as packaged, v1\n", backup = true)]))
    let upV2 = g.buildArchFixture(fx("repro-fx-up", "2",
      @[fxFile(UpConf, "# up as packaged, v2\n", backup = true)]))
    let goneV1 = g.buildArchFixture(fx("repro-fx-gone", "1",
      @[fxFile(GoneConf, "# gone as packaged\n", backup = true)]))
    let newV1 = g.buildArchFixture(fx("repro-fx-new", "1",
      @[fxFile(NewConf, "# new as packaged\n")]))
    let shadow = g.buildArchFixture(fx("repro-fx-hookname", "1",
      @[fxFile(ShadowHook, "[Trigger]\nOperation = Install\nType = Package\n" &
        "Target = repro-fx-nothing\n\n[Action]\nWhen = PostTransaction\n" &
        "Exec = /usr/bin/true\n")]))
    let noop1 = g.buildArchFixture(fx("repro-fx-noop", "1",
      @[fxFile("/usr/share/repro-fx/noop", "1\n")]))
    let noop2 = g.buildArchFixture(fx("repro-fx-noop", "2",
      @[fxFile("/usr/share/repro-fx/noop", "2\n")]))
    let inst = g.exec("pacman -U --noconfirm " & upV1 & " " & goneV1 & " " &
                      noop1 & " 2>&1", timeoutSec = 900)
    if inst.exitCode != 0:
      raise newException(TestBedError, "installing the fixture packages " &
        "failed: " & inst.stdout & inst.stderr)

    g.settleBaseline(step)
    if not g.bootstrapArch(repro, step).ok: return fails
    let exe = g.gen0ReproExe()
    step("generation 0 carries the ALPM hook, as generation 0 renders it",
         g.sha256InGuest(AlpmHookPathInGuest) == sha256Hex(alpmHook(exe)) and
           AlpmHookPathInGuest in g.ledgerOf(),
         g.run("cat " & AlpmHookPathInGuest & " 2>&1 | head -20"))
    let a1 = g.applyProfile(repro, "gen1", profile(exe))
    step("gen1: a file and two taken-over backup files apply", a1.exitCode == 0,
         a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails

    # pacnew.
    block:
      let r = g.pacmanInstall(upV2)
      step("pacnew: pacman -Syu-style upgrade of repro-fx-up succeeds and writes up.conf.pacnew",
           r.exitCode == 0 and g.exec("test -f " & UpConf & ".pacnew").exitCode == 0,
           r.stdout & r.stderr)
      let said = hookSaid(r.stdout)
      step("pacnew: the hook names repro-fx-up and up.conf.pacnew",
           ("repro-fx-up installed " & UpConf & ".pacnew") in r.stdout and
             (UpConf & ".pacnew") in g.logLines(AlpmHookLog).join("\n") and
             (UpConf & ".pacnew") in g.journalOf(AlpmHookTag), said)
      let p = g.planProfile(repro, "gen1", profile(exe))
      step("pacnew: the next plan reports the .pacnew",
           p.exitCode == 0 and ("repro-fx-up installed " & UpConf & ".pacnew") in p.stdout,
           "exit " & $p.exitCode & "\n" & p.stdout & p.stderr)
      # A .pacnew beside a taken-over file is pacman's normal state after a
      # vendor update (spec §4.3.1): reported, it must not fail the apply.
      let a = g.applyProfile(repro, "gen1", profile(exe))
      step("pacnew: the profile still applies, reporting the .pacnew",
           a.exitCode == 0 and ("repro-fx-up installed " & UpConf & ".pacnew") in a.stdout,
           "exit " & $a.exitCode & "\n" & a.stdout & a.stderr)
    # pacsave.
    block:
      let r = g.pacmanRemove("repro-fx-gone")
      step("pacsave: pacman -R repro-fx-gone succeeds and keeps gone.conf.pacsave",
           r.exitCode == 0 and g.exec("test -f " & GoneConf & ".pacsave").exitCode == 0,
           r.stdout & r.stderr)
      step("pacsave: the hook names repro-fx-gone and gone.conf.pacsave",
           ("repro-fx-gone was removed and pacman kept " & GoneConf & ".pacsave") in r.stdout and
             (GoneConf & ".pacsave") in g.logLines(AlpmHookLog).join("\n"),
           hookSaid(r.stdout))
      let p = g.planProfile(repro, "gen1", profile(exe))
      step("pacsave: the next plan reports the .pacsave",
           ("repro-fx-gone was removed and pacman kept " & GoneConf & ".pacsave") in
             (p.stdout & p.stderr),
           "exit " & $p.exitCode & "\n" & p.stdout & p.stderr)
    # install over a ledger path.
    block:
      let r = g.exec("pacman -U --noconfirm --overwrite " & NewConf & " " &
                     newV1 & " 2>&1", timeoutSec = 900)
      step("install: pacman -U --overwrite of repro-fx-new succeeds", r.exitCode == 0,
           r.stdout & r.stderr)
      step("install: the hook names repro-fx-new and new.conf",
           ("package repro-fx-new now owns ledger path " & NewConf) in r.stdout and
             ("changed: etcFile " & NewConf) in r.stdout and
             NewConf in g.logLines(AlpmHookLog).join("\n") and
             "repro-fx-new" in g.journalOf(AlpmHookTag),
           hookSaid(r.stdout))
      let p = g.planProfile(repro, "gen1", profile(exe))
      let said = p.stdout & p.stderr
      step("install: the next plan refuses EAddOnPackageOwned naming repro-fx-new",
           p.exitCode != 0 and "EAddOnPackageOwned" in said and "repro-fx-new" in said,
           "exit " & $p.exitCode & "\n" & said)
    # a packaged hook of the add-on's name.
    block:
      let r = g.pacmanInstall(shadow)
      step("hookname: pacman -U of repro-fx-hookname succeeds", r.exitCode == 0,
           r.stdout & r.stderr)
      step("hookname: the hook reports the packaged hook it silently disables",
           ("package repro-fx-hookname ships " & ShadowHook) in r.stdout and
             "silently disables" in g.logLines(AlpmHookLog).join("\n"),
           hookSaid(r.stdout))

    # Negative controls: the verify binary replaced by a stand-in.
    discard g.run("mkdir -p /root/fault-empty; " &
      "printf '#!/bin/sh\\nexit 1\\n' > /root/fault-fail; " &
      "printf '#!/bin/sh\\ntrap \"\" TERM\\nsleep 1919 &\\nwhile :; do sleep 1; done\\n' > /root/fault-hang; " &
      "chmod 0755 /root/fault-fail /root/fault-hang")
    var noopNext = noop2
    proc noopTransaction(timeoutSec: int): tuple[code: int; secs: float; output: string] =
      let pkg = noopNext
      noopNext = if noopNext == noop2: noop1 else: noop2
      let t0 = epochTime()
      let r = g.exec("timeout -s KILL " & $timeoutSec & " pacman -U --noconfirm " &
                     pkg & " 2>&1", timeoutSec = timeoutSec + 60)
      (r.exitCode, epochTime() - t0, r.stdout & r.stderr)
    block:
      let before = g.logLines(AlpmHookLog).len
      discard g.run("mount --bind /root/fault-fail " & exe)
      let r = noopTransaction(HangDeadlineSec)
      discard g.exec("umount " & exe)
      let lines = g.logLines(AlpmHookLog)
      step("fails: the transaction succeeds and the log records verify-failed",
           r.code == 0 and lines.len > before and
             "verify-failed" in lines[^1],
           r.output & "\n" & lines.join("\n"))
    block:
      let before = g.logLines(AlpmHookLog).len
      discard g.run("mount --bind /root/fault-hang " & exe)
      let r = noopTransaction(HangDeadlineSec)
      let left = g.exec("pgrep -f 'sleep 1919'").exitCode == 0
      # Whatever the hook left (a mutated hook leaves all of it).
      discard g.exec("pkill -KILL -f fault-hang; pkill -KILL -f 'sleep 1919'; " &
                     "sleep 1; umount " & exe & "; rm -f /var/lib/pacman/db.lck")
      step("hangs: the transaction finishes within the watchdog's bound plus 5 s",
           r.code == 0 and r.secs <= HookBoundSec.float,
           "exit " & $r.code & " after " & $r.secs & " s (bound " &
             $HookBoundSec & " s)\n" & r.output)
      let lines = g.logLines(AlpmHookLog)
      step("hangs: the hook's log records verify-timeout",
           lines.len > before and "verify-timeout" in lines[^1],
           lines.join("\n"))
      step("hangs: nothing of the hung process group is left", not left,
           g.run("ps -ef | grep -E 'fault-hang|sleep 1919' | grep -v grep || true"))
      record["hangSeconds"] = %r.secs
    # Last: the store deleted.
    block:
      let before = g.logLines(AlpmHookLog).len
      let del = g.exec("systemctl stop repro-store.mount; " &
        "rm -rf --one-file-system /repro/store; test ! -e " & exe)
      let r = noopTransaction(HangDeadlineSec)
      let lines = g.logLines(AlpmHookLog)
      step("store deleted: the transaction succeeds, the hook records verify-missing",
           del.exitCode == 0 and r.code == 0 and lines.len > before and
             "verify-missing" in lines[^1],
           del.stdout & del.stderr & "\n" & r.output & "\n" & lines.join("\n"))
      discard g.exec("systemctl restart repro-addon-reassert.service",
                     timeoutSec = 600)
      let rep = g.run("cat /var/lib/repro/system/addon/reassert-report 2>&1; " &
        "journalctl -o cat --no-pager -u repro-addon-reassert.service | tail -5")
      step("store deleted: the re-assert unit reports degraded",
           "degraded" in rep, rep)
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
  test "the ALPM hook reports pacman's changes to ledger paths and never blocks pacman":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
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
