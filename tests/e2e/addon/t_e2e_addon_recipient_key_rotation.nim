## Gate ``e2e_addon_recipient_key_rotation`` (milestone A7; spec §10.3;
## threat model G36, T41, CRED-2).
##
## After ``repro system addon rotate-recipient-key`` and a producer publish
## sealed to the new key, the next tick opens it and deletes the old key;
## an envelope sealed to the old key afterwards is refused with
## ``aoSecretsFailed``.
##
## On each base:
##
## 1. bootstrap; manifest 1 sealed to key K1 (value V1) is applied by the
##    tick; the service loads V1;
## 2. ``rotate-recipient-key`` prints K2's public half; the current key is
##    still K1 and the next key is ``0400`` root; running it again prints
##    the same K2 (a pending rotation is not replaced);
## 3. a tick with nothing new converges and K1 is still the key;
## 4. manifest 2 sealed to K2 (value V2): the tick applies it; afterwards
##    ``recipient.key`` is K2 (its public half equals ``recipient.pub``,
##    which equals the printed K2), the next key is gone, no file under
##    ``/var/lib/repro/agent`` holds K1's scalar, the service was restarted
##    and loads V2, and ``repro system addon verify`` reports ``ok`` (the
##    ledger follows the rotation);
## 5. manifest 3 sealed to the OLD key K1: the tick exits 2 with
##    ``aoSecretsFailed``; the service still loads V2, and the retained
##    envelope is unchanged;
## 6. reboot: the re-assert unit reports ``ok`` and re-materialises V2.
##
## *Negative control*: ``rotation-keeps-old-key`` keeps the retired key
## and opens what is sealed to it; step 5 then applies V3 and the gate goes
## red (``REPRO_ADDON_MUTATION=rotation-keeps-old-key``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./addon_secrets_support

const Target = "addon-tb"

const Profile = "secrets.secretFile {\n  service = \"rot-web\"\n  name = \"value\"\n}\n\n" &
  "systemd.systemUnit {\n  name = \"rot-web.service\"\n" &
  "  content = \"[Unit]\nDescription=rotation probe\n\n[Service]\n" &
  "DynamicUser=yes\nRuntimeDirectory=rot-web\nRuntimeDirectoryMode=0755\n" &
  "ExecStart=/bin/sh -c 'cat $$CREDENTIALS_DIRECTORY/value > /run/rot-web/seen; " &
  "exec sleep infinity'\n\n[Install]\nWantedBy=multi-user.target\n\"\n" &
  "  credentials = [\"value\"]\n}\n"

proc seen(g: Guest; want: string): string =
  g.exec("for i in $(seq 1 30); do [ \"$(cat /run/rot-web/seen 2>/dev/null)\" = '" &
         want & "' ] && break; sleep 1; done; cat /run/rot-web/seen 2>/dev/null").stdout

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
    let (ok, anchors) = g.bootstrapAddonWithAnchors(repro, step)
    if not ok: return fails
    let signer = anchors.deploySignerKeys[0]
    let k1 = g.recipientPubHex()
    let k1Scalar = g.run("cat /var/lib/repro/agent/recipient.key").strip()
    # 1.
    let m1 = g.publishManifest(signer, Target, 1, Profile,
                               @[("rot-web/value", "V1")], k1)
    var r = g.tick(repro, Target, @[m1])
    step("tick 1 applies (sealed to K1)", r.outcomeOf() == "aoApplied",
         r.stdout & r.stderr)
    step("the service loads V1", g.seen("V1") == "V1", g.seen("V1"))
    # 2.
    r = g.exec(repro & " system addon rotate-recipient-key")
    var k2 = ""
    for line in r.stdout.splitLines:
      if line.startsWith("next recipient public key: "):
        k2 = line.split(": ")[1].strip()
    step("rotate-recipient-key prints the next public key",
         r.exitCode == 0 and k2.len == 130 and k2 != k1, r.stdout & r.stderr)
    let nextMode = g.exec("stat -c '%a %U' /var/lib/repro/agent/recipient.key.next").stdout.strip()
    step("the next key is 0400 root", nextMode == "400 root", nextMode)
    step("the current key is still K1", g.recipientPubHex() == k1 and
         g.run("cat /var/lib/repro/agent/recipient.key").strip() == k1Scalar, "")
    let again = g.exec(repro & " system addon rotate-recipient-key").stdout
    step("a pending rotation is not replaced", k2 in again, again)
    # 3.
    r = g.tick(repro, Target, @[m1])
    step("a tick with nothing new converges", r.outcomeOf() == "aoConverged",
         r.stdout)
    step("K1 is still the key after it", g.recipientPubHex() == k1, "")
    # 4.
    let m2 = g.publishManifest(signer, Target, 2, Profile,
                               @[("rot-web/value", "V2")], k2)
    r = g.tick(repro, Target, @[m2])
    step("tick 2 applies (sealed to K2)", r.outcomeOf() == "aoApplied",
         r.stdout & r.stderr)
    step("recipient.pub is K2", g.recipientPubHex() == k2, g.recipientPubHex())
    step("the next key is gone",
         g.exec("test ! -e /var/lib/repro/agent/recipient.key.next").exitCode == 0, "")
    let leftover = g.exec("grep -rlF '" & k1Scalar & "' /var/lib/repro/agent " &
                          "/var/lib/repro/system 2>/dev/null").stdout.strip()
    step("the old key is deleted (no file holds K1's scalar)",
         leftover.len == 0, leftover)
    let keyMode = g.exec("stat -c '%a %U' /var/lib/repro/agent/recipient.key").stdout.strip()
    step("the new key is 0400 root", keyMode == "400 root", keyMode)
    step("the service was restarted and loads V2", g.seen("V2") == "V2",
         g.seen("V2"))
    r = g.exec(repro & " system addon verify")
    step("verify reports ok (the ledger follows the rotation)",
         r.exitCode == 0, r.stdout & r.stderr)
    # 5.
    let retainedBefore = g.run("sha256sum /var/lib/repro/agent/sealed-secrets")
    let m3 = g.publishManifest(signer, Target, 3, Profile,
                               @[("rot-web/value", "V3")], k1)
    r = g.tick(repro, Target, @[m3])
    record["oldKeyTick"] = %(r.stdout & r.stderr)
    step("an envelope sealed to the old key is refused with aoSecretsFailed",
         r.exitCode == 2 and r.outcomeOf() == "aoSecretsFailed",
         r.stdout & r.stderr)
    step("the service still loads V2", g.seen("V2") == "V2", g.seen("V2"))
    step("the retained envelope is unchanged",
         g.run("sha256sum /var/lib/repro/agent/sealed-secrets") == retainedBefore, "")
    # 6.
    discard g.exec("systemctl reboot", timeoutSec = 30)
    discard g.waitPoweredOff(300)
    g.boot()
    let journal = g.waitReasserted()
    let report = g.exec("cat /var/lib/repro/system/addon/reassert-report").stdout
    step("after a reboot the re-assert unit reports ok", "reassert: ok" in report,
         report & journal)
    step("after a reboot the service loads V2", g.seen("V2") == "V2", g.seen("V2"))
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

suite "e2e_addon_recipient_key_rotation":
  test "the next tick opens the new key's envelope and deletes the old key":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_recipient_key_rotation)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_recipient_key_rotation",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_recipient_key_rotation", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
