## Gate ``e2e_addon_recovery_never_holds_up_boot`` (milestone A5; spec §7.7,
## threat model T26).
##
## The re-assert unit may take long -- it replays an interrupted switch,
## confirm step included, at boot -- and the base's boot must not wait for
## it. The gate makes a recovery as slow as it likes: the seam build holds
## a recovery at its start while ``test-pause-recovery`` is present (the
## file is written and synced before the switch starts, so it survives the
## reset). From generation A, the switch to B is paused at step-3 and the
## guest hard-reset; at the next boot, while the recovery is held:
##
## - ``multi-user.target`` reaches ``active``, and does so no later than in
##   a reference boot of the same guest plus a fixed margin;
## - SSH answers (the test bed reaches the guest only over SSH);
## - the re-assert unit is still running, held at ``recovery``.
##
## Released, the recovery finishes and reports ``ok``.
##
## Both generations carry a unit that loads a credential
## (``secrets.secretFile``, ``credentials``). Such a unit is wanted by
## multi-user.target and must start before its secret is needed, so it is
## ordered after the add-on's bounded boot secrets unit
## (``repro-addon-secrets.service``); while the recovery is held it must be
## active, having read its secret.
##
## Falsifying mutation ``addon-target-in-boot-order`` (``REPRO_ADDON_MUTATION``):
## ``repro-addon.target`` keeps systemd's default dependencies, so
## multi-user.target is ordered after it, and it after the recovery: the
## gate must go red (multi-user.target never becomes active while the
## recovery is held).
##
## Falsifying mutation ``secrets-after-recovery``: the credential unit is
## ordered after the re-assert unit instead (the ordering A7 first
## shipped), so multi-user.target waits for the held recovery through it:
## red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``; QEMU only; the seam build.
##
## *Mocking.* None.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  MarginSeconds = 30.0
    ## Slack over the reference boot for a single boot's jitter under KVM.
  HoldWaitSeconds = 240

proc unitText(gen: string): string =
  "[Unit]\nDescription=boot-order fixture\n[Service]\nEnvironment=GEN=" & gen &
    "\nExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target\n"

const
  CredService = "repro-fixture-cred"
  CredSeen = "/run/repro-fixture-cred.seen"
  CredValue = "a5-boot-credential"

proc credentialUnit(gen: string): string =
  ## A unit that loads a credential, wanted by multi-user.target like any
  ## service, so whatever it is ordered after is on the base's boot path.
  ## It copies what it read to a file the gate checks (root-only /run).
  "secrets.secretFile {\n  service = \"" & CredService & "\"\n  name = \"token\"\n}\n\n" &
    "systemd.systemUnit {\n  name = \"" & CredService & ".service\"\n" &
    "  content = \"[Unit]\nDescription=credential boot-order fixture\n\n" &
    "[Service]\nEnvironment=GEN=" & gen & "\nExecStart=/bin/sh -c 'cat " &
    "$$CREDENTIALS_DIRECTORY/token > " & CredSeen & "; exec sleep infinity'\n\n" &
    "[Install]\nWantedBy=multi-user.target\n\"\n" &
    "  credentials = [\"token\"]\n}\n\n"

proc profile(gen: string): string =
  credentialUnit(gen) &
  "addOn {\n  managedEtcPrefixes = [\"/etc/repro-fixture/\"]\n}\n\n" &
    "systemd.systemUnit {\n  name = \"repro-fixture-boot.service\"\n  content = \"" &
    unitText(gen) & "\"\n}\n\n" &
    "fs.systemFile {\n  path = \"/etc/repro-fixture/boot.conf\"\n  content = \"" &
    gen & "\n\"\n}\n"

proc multiUserSeconds(g: Guest): float =
  ## Seconds from kernel start to multi-user.target becoming active, -1
  ## while it is not active.
  let st = g.exec("systemctl is-active multi-user.target").stdout.strip()
  if st != "active": return -1
  let us = g.exec("systemctl show -p ActiveEnterTimestampMonotonic --value " &
                  "multi-user.target").stdout.strip()
  try: parseFloat(us) / 1_000_000.0 except ValueError: -1

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
    let put = g.exec("printf %s " & CredValue & " | " & repro &
      " system addon secret put --service " & CredService & " --name token")
    step("secret put " & CredService, put.exitCode == 0, put.stdout & put.stderr)
    var r = g.applyProfile(repro, "a", profile("A"))
    step("generation A applied", r.exitCode == 0, r.stdout & r.stderr)
    # The reference: a clean boot of this guest with the add-on installed.
    discard g.exec("systemctl reboot", timeoutSec = 30)
    discard g.waitPoweredOff(300)
    g.boot()
    discard g.waitReasserted()
    discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                   timeoutSec = 600)
    let reference = g.multiUserSeconds()
    record["referenceMultiUserSeconds"] = %reference
    step("reference: multi-user.target active", reference > 0, $reference)
    # Hold the next recovery, then interrupt a switch.
    discard g.run("touch " & SeamDir & "/test-pause-recovery && sync")
    let paused = g.startSwitchPausedAt(repro, "b", profile("B"), "step-3")
    step("the switch to B paused at step-3", paused.exitCode == 0,
         paused.stdout & paused.stderr)
    if paused.exitCode != 0: return fails
    g.hardResetAfterSettle()
    let t0 = epochTime()
    g.boot()                     # returns once SSH answers
    record["sshSecondsFromQemuStart"] = %(epochTime() - t0)
    step("SSH answers while the recovery is held", true,
         $(epochTime() - t0) & " s after QEMU started")
    var seconds = -1.0
    let deadline = epochTime() + HoldWaitSeconds.float
    while epochTime() < deadline:
      seconds = g.multiUserSeconds()
      if seconds > 0: break
      sleep(2000)
    record["heldMultiUserSeconds"] = %seconds
    let held = g.exec("cat " & SeamDir & "/test-paused-at 2>/dev/null").stdout.strip()
    let reassertState = g.exec("systemctl show -p ActiveState --value " &
                               "repro-addon-reassert.service").stdout.strip()
    step("the recovery is held while the base boots",
         held == "recovery" and reassertState == "activating",
         "paused-at=" & held & " reassert=" & reassertState)
    step("multi-user.target is active while the recovery is held, within " &
         "the reference boot plus " & $MarginSeconds & " s",
         seconds > 0 and seconds <= reference + MarginSeconds,
         "held boot " & $seconds & " s, reference " & $reference & " s; jobs:\n" &
         g.exec("systemctl list-jobs --no-pager").stdout)
    # The unit that loads a credential started in this boot, before the
    # recovery, with its secret: the boot secrets unit materialised it.
    let credState = g.exec("systemctl is-active " & CredService & ".service").stdout.strip()
    let seen = g.exec("cat " & CredSeen & " 2>/dev/null").stdout
    step("the credential unit is active and read its secret while the " &
         "recovery is held", credState == "active" and seen == CredValue,
         "state=" & credState & " seen=" & seen & "; secrets unit: " &
         g.exec("systemctl status --no-pager repro-addon-secrets.service " &
                "2>&1 | tail -5").stdout)
    # Release the recovery; it finishes the switch.
    discard g.run("touch " & SeamDir & "/test-resume")
    let j = g.waitReasserted()
    step("released, the recovery finishes and reports ok",
         "repro-addon reassert: ok" in j, j)
    step("no pending marker is left",
         g.exec("test ! -e /var/lib/repro/system/addon/pending").exitCode == 0, "")
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

suite "e2e_addon_recovery_never_holds_up_boot":
  test "a slow recovery never delays the base's multi-user.target":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_recovery_never_holds_up_boot)")
    elif useIncus():
      skip("a hard reset is of a disk image; QEMU only")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_recovery_never_holds_up_boot",
          "base": b.name, "arch": b.debArch, "backend": "qemu",
          "mutation": mutation(), "testSeams": testSeams(),
          "reprobuild": gitHead(), "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_recovery_never_holds_up_boot", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
