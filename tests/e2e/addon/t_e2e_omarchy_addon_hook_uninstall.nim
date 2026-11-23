## Gate ``e2e_omarchy_addon_hook_uninstall`` (milestone AR6; spec
## ReproOS-Add-On-Mode §4.3.2, §6.2, §6.4, §7.7, §12.2; threat model T48,
## T49, G45).
##
## AR1's byte-identity sequence (``e2e_arch_addon_bootstrap_uninstall_byte_identity``)
## on the Omarchy VM, whose generation 0 now carries the post-update hook
## ``~omarchy/.config/omarchy/hooks/post-update.d/90-repro-addon``: the
## fingerprint, with the account's hook tree (``omarchy-hooks``), taken twice
## (determinism); bootstrap, a generation that adds a unit and a file, one
## that removes the unit and changes the file, uninstall -- every diff equal
## to what the ledgers account for, and the fingerprint after uninstall
## equal to the one before bootstrap: uninstall leaves the operator's hook
## directory as preflight saw it. After bootstrap the hook is the add-on's
## script for its binary, root-owned 0644, ``post-update.d`` (created when
## it was missing) the account's; the re-assert unit compares the hook with
## the ledger (``ok``, then ``drift`` naming it once the account replaces
## it), and the next plan reports it (a note: no apply repairs it, so it
## must not fail every later apply).
##
## Negative controls (spec §4.3.2: the no-follow writer and the owner
## checks), each followed by the proof that nothing outside the home was
## written or removed:
##
## - *at bootstrap*: (a) the account plants a symbolic link at the hook's
##   path, pointing at a path under ``/etc``; (b) the account replaces
##   ``post-update.d`` with a link to a root-owned directory under ``/etc``.
##   Each time bootstrap is refused, the link's target is not created or
##   written, and the host's fingerprint is the baseline's but for the
##   account's own link;
## - *at uninstall*: (c) ``post-update.d`` replaced with a link to an
##   ``/etc`` directory holding a decoy with the hook's very bytes; (d) the
##   hook replaced with a link to an ``/etc`` decoy with the same bytes.
##   Each time uninstall leaves the link and the decoy, reports the drift
##   and stays incomplete; once the account's change is undone, the next
##   uninstall completes.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=omarchy-hook-writer-follows-links``):
## the hook is written and removed by path, following links, with no owner
## check, and the preflight does not walk its directories: control (a)'s
## bootstrap goes ahead and writes the link's target under ``/etc``. The
## gate goes red at that step and stops there (the mutated bootstrap has
## installed the add-on); every step before it must be green.
##
## Bases: the Omarchy VM (``omarchy-amd64``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_omarchy_addon_hook_uninstall``).
##
## *Mocking.* None: the Omarchy VM Omarchy's installer laid out, real
## systemd, the real static add-on binary; the account's actions are run as
## the account (``runuser``).

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip
import repro_addon/[fingerprint, generation0]

import ./arch_gate_support
import ./arch_update_support

const
  Gate = "e2e_omarchy_addon_hook_uninstall"
  Target = "/etc/repro-gate-hook-target"
  TargetDir = "/etc/repro-gate-hook-dir"
  ControlA = "bootstrap (a): a link at the hook's path is refused; nothing outside the home is written"
  ControlB = "bootstrap (b): post-update.d replaced with a link is refused; nothing outside the home is written"

proc expectedFalsifier(mut: string; b: BaseImage): Falsifier =
  case mut
  of "omarchy-hook-writer-follows-links":
    Falsifier(required: @[ControlA],
      mustRunGreen: @["baseline: udevadm settle and systemctl daemon-reload",
                      "fingerprint is deterministic",
                      "the fingerprint has omarchy-hooks records (the real hook tree)"])
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
    let account = accountFor(b)
    let home = g.run("getent passwd " & account & " | cut -d: -f6").strip()
    let hooks = home & "/.config/omarchy/hooks"
    let dir = hooks & "/post-update.d"
    let hook = omarchyHookPath(home)
    proc asAccount(cmd: string): ExecOut =
      g.exec("runuser -u " & account & " -- sh -c " & quoteShell(cmd))
    let dirExisted = g.exec("test -d " & dir & " -a ! -L " & dir).exitCode == 0
    record["postUpdateDirBefore"] = %dirExisted
    record["hookTreeBefore"] = %g.run("ls -la " & hooks & " " & dir & " 2>&1")

    g.settleBaseline(step)
    let f0 = g.fingerprintArch(repro, account)
    sleep(20_000)
    let f0b = g.fingerprintArch(repro, account)
    let det = identityReport(f0, f0b)
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails
    step("the fingerprint has omarchy-hooks records (the real hook tree)",
         hooksRecorded(f0), g.run("ls -la " & hooks & " 2>&1"))
    let flags = g.firstProfileFlag(b)
    let anchors = g.installAnchors()

    proc refusedBootstrap(): tuple[refused: bool; said: string] =
      let pre = g.preflightArch(repro, anchors.flags & flags)
      let boot = g.exec(repro & " system addon bootstrap --plan " &
        planDigestOf(pre.stdout) & anchors.flags & flags, timeoutSec = 1800)
      (boot.exitCode != 0 and g.exec("test -e /var/lib/repro/system/addon/" &
         "addon-ledger").exitCode != 0,
       "preflight exit " & $pre.exitCode & "\n" & pre.stdout & pre.stderr &
         "\nbootstrap exit " & $boot.exitCode & "\n" & boot.stdout & boot.stderr)

    # (a) A link at the hook's path.
    block:
      if not dirExisted: discard asAccount("mkdir " & dir)
      discard asAccount("ln -s " & Target & " " & hook)
      let r = refusedBootstrap()
      let wrote = g.exec("test -e " & Target & " -o -L " & Target).exitCode == 0
      let fa = g.fingerprintArch(repro, account)
      var allowed = @["omarchy-hooks:" & hook]
      if not dirExisted: allowed.add("omarchy-hooks:" & dir)
      let same = identityReport(f0, fa, allowed)
      step(ControlA, r.refused and not wrote and same.ok and
             symlinkTargetIs(g, hook, Target),
           r.said & "\n" & Target & (if wrote: " was written" else: " absent") &
             "\n" & same.text)
      if wrote:
        # The mutated bootstrap went ahead: nothing after this measures
        # anything.
        return fails
      discard g.exec("rm -f " & hook)
      if not dirExisted: discard g.exec("rmdir " & dir)
    # (b) post-update.d replaced with a link to a root directory under /etc.
    block:
      discard g.exec("mkdir -m 0755 " & TargetDir)
      if dirExisted: discard asAccount("mv " & dir & " " & dir & ".gate-aside")
      discard asAccount("ln -s " & TargetDir & " " & dir)
      let r = refusedBootstrap()
      let wrote = g.run("ls -A " & TargetDir).strip().len > 0
      step(ControlB, r.refused and not wrote,
           r.said & "\n" & TargetDir & ": " & g.run("ls -la " & TargetDir))
      discard g.exec("rm -f " & dir)
      if dirExisted: discard asAccount("mv " & dir & ".gate-aside " & dir)
      discard g.exec("rmdir " & TargetDir)
    let fc = g.fingerprintArch(repro, account)
    let back = identityReport(f0, fc)
    step("after the bootstrap controls the host is the baseline again",
         back.ok, back.text)

    # The real bootstrap.
    if not g.bootstrapArch(repro, step, flags).ok: return fails
    let exe = g.gen0ReproExe()
    let l0 = g.ledgerOf()
    let f1 = g.fingerprintArch(repro, account)
    let d0 = deltaReport(f0, f1, "", l0)
    step("bootstrap diff == generation 0 ledger (the hook included)",
         d0.ok and ("omarchy-hooks\t" & hook) in f1, d0.text)
    let st = g.run("stat -c '%u:%g %a %F' " & hook).strip()
    step("the hook is the add-on's script for its binary, root-owned 0644",
         st == "0:0 644 regular file" and
           g.sha256InGuest(hook) == sha256Hex(omarchyHookScript(exe)) and
           ("omarchyHook\t" & hook) in l0,
         st & "\n" & g.run("head -12 " & hook))
    let dst = g.run("stat -c '%U %a %F' " & dir).strip()
    step("post-update.d is the account's (created by bootstrap when missing)",
         dst == account & " 755 directory" and
           (dirExisted or ("omarchyHook\t" & dir) in l0),
         dst)
    let ra = g.exec("systemctl restart repro-addon-reassert.service; " &
      "cat /var/lib/repro/system/addon/reassert-report", timeoutSec = 600)
    step("the re-assert unit compares the hook with the ledger: ok",
         ra.stdout.contains(": ok"), ra.stdout & ra.stderr)

    let a1 = g.applyProfile(repro, "gen1", gen1Profile(exe, account))
    step("apply generation 1", a1.exitCode == 0, a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails
    let l1 = g.ledgerOf()
    let f2 = g.fingerprintArch(repro, account)
    let d1 = deltaReport(f1, f2, l0, l1)
    step("generation 1 diff == ledger delta", d1.ok, d1.text)
    let a2 = g.applyProfile(repro, "gen2", gen2Profile(account))
    step("apply generation 2", a2.exitCode == 0, a2.stdout & a2.stderr)
    if a2.exitCode != 0: return fails
    let l2 = g.ledgerOf()
    let f3 = g.fingerprintArch(repro, account)
    let d2 = deltaReport(f2, f3, l1, l2)
    step("generation 2 diff == ledger delta", d2.ok, d2.text)

    # The account replaces the hook: drift, at boot and in the next plan.
    let original = g.run("base64 -w0 " & hook).strip()
    discard asAccount("rm -f " & hook & " && echo 'echo mine' > " & hook)
    let rd = g.exec("systemctl restart repro-addon-reassert.service; " &
      "cat /var/lib/repro/system/addon/reassert-report", timeoutSec = 600)
    step("a hook the account replaced: the re-assert unit reports drift naming it",
         rd.stdout.contains("drift") and hook in rd.stdout, rd.stdout & rd.stderr)
    let pd = g.planProfile(repro, "gen2", gen2Profile(account))
    step("a hook the account replaced: the next plan reports it",
         ("the Omarchy post-update hook " & hook) in pd.stdout,
         "exit " & $pd.exitCode & "\n" & pd.stdout & pd.stderr)
    discard g.exec("rm -f " & hook & " && printf '%s' " & original &
      " | base64 -d > " & hook & " && chown 0:0 " & hook & " && chmod 0644 " & hook)
    step("put back, the hook is the ledger's again",
         g.exec(repro & " system addon verify").exitCode == 0,
         g.exec(repro & " system addon verify").stdout)

    # (c) post-update.d replaced with a link at uninstall.
    let fBeforeUninstall = g.fingerprintArch(repro, account)
    block:
      discard g.exec("mkdir -m 0755 " & TargetDir & " && printf '%s' " &
        original & " | base64 -d > " & TargetDir & "/90-repro-addon")
      discard asAccount("mv " & dir & " " & dir & ".gate-aside && ln -s " &
        TargetDir & " " & dir)
      let un = g.exec(repro & " system addon uninstall", timeoutSec = 1800)
      let said = un.stdout & un.stderr
      step("uninstall (c): post-update.d replaced with a link: nothing removed through it, drift, incomplete",
           un.exitCode != 0 and g.exec("test -f " & TargetDir &
             "/90-repro-addon").exitCode == 0 and
             g.exec("test -L " & dir).exitCode == 0 and "symbolic link" in said and
             g.exec("test -d /var/lib/repro/system/addon").exitCode == 0,
           "exit " & $un.exitCode & "\n" & said)
      discard g.exec("rm -f " & dir)
      discard asAccount("mv " & dir & ".gate-aside " & dir)
      discard g.exec("rm -rf " & TargetDir)
    # (d) The hook replaced with a link to a decoy with its bytes.
    block:
      discard g.exec("printf '%s' " & original & " | base64 -d > " & Target)
      discard asAccount("rm -f " & hook & " && ln -s " & Target & " " & hook)
      let un = g.exec(repro & " system addon uninstall", timeoutSec = 1800)
      let said = un.stdout & un.stderr
      step("uninstall (d): the hook replaced with a link: the link and its target left, drift, incomplete",
           un.exitCode != 0 and g.exec("test -f " & Target).exitCode == 0 and
             symlinkTargetIs(g, hook, Target) and "symbolic link" in said,
           "exit " & $un.exitCode & "\n" & said)
      discard g.exec("rm -f " & hook & " " & Target)
    let un = g.exec(repro & " system addon uninstall", timeoutSec = 1800)
    step("uninstall completes once the account's changes are undone",
         un.exitCode == 0, un.stdout & un.stderr)
    let f4 = g.fingerprintArch(repro, account)
    let ident = identityReport(f0, f4)
    step("base fingerprint after uninstall == before bootstrap (the hook directory as preflight saw it)",
         ident.ok, ident.text)
    for (n, t) in [("f0", f0), ("f1", f1), ("f2", f2), ("f3", f3),
                   ("fBeforeUninstall", fBeforeUninstall), ("f4", f4),
                   ("l0", l0), ("l1", l1), ("l2", l2)]:
      writeFile(g.runDir / (n & ".txt"), t)
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
  test "the Omarchy post-update hook is written and removed without following links":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        if not isOmarchyBase(b):
          failures.add(b.name & ": " & Gate & " runs on the Omarchy VM")
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
