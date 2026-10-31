## Gate ``e2e_addon_secrets_follow_generations`` (milestone A7, review
## round 2; spec §10.3, §7.3, §7.5; threat model G18, G36).
##
## Secrets follow the generation that uses them, through a failed apply, a
## reboot, an exclusive unit's credential change, a rotation and a
## rollback, and a rotation cut short by a crash is completed.
##
## On each base (the seam build):
##
## 1. *a failed apply keeps the old generation's secrets.* Generation 1
##    (manifest 1, key K1) runs ``old-web`` loading ``old-web/legacy`` and
##    an exclusive ``x-web`` and a ``restartIfChanged = false`` ``h-web``
##    loading their ``token``s. Manifest 2's profile drops ``old-web`` and
##    adds a unit whose health check fails; its sealed section lacks
##    ``old-web/legacy``. The tick fails (``aoApplyFailed``, rolled back);
##    the latest envelope is unchanged and nothing is left staged; after a
##    reboot the re-assert unit reports ``ok`` and ``old-web`` runs with
##    its legacy secret;
## 2. *credential changes go through the switch's transition rules.*
##    Manifest 3 is generation 1's profile with new token values: the
##    exclusive ``x-web`` is stopped and confirmed exited before its new
##    instance starts (its lifetime log alternates start/stop, and the new
##    instance read the new value); ``h-web`` keeps running with the old
##    value, and the re-assert unit reports it (``drift``, restart pending);
## 3. *rollback after a rotation.* ``rotate-recipient-key``; manifest 4
##    sealed to K2 retires K1; ``repro system rollback`` to manifest 3's
##    generation re-materialises its values (its copy was re-sealed to K2
##    when K1 was retired);
## 4. *a rotation cut short.* Another rotation (K3); manifest 5's tick is
##    paused at ``rotation-after-rename`` (the key is K3, ``recipient.pub``
##    still K2) and killed; ``repro system addon recover`` finishes it:
##    ``recipient.pub`` is K3, ``verify`` reports ``ok``, and the next tick
##    applies manifest 5.
##
## 5. *a retirement cut short after the overwrite.* Another rotation (K4);
##    manifest 6's tick is paused at ``rotation-after-overwrite`` (the old
##    key is all NUL bytes, the next key not yet renamed) and killed;
##    ``recover`` finishes it (``recipient.pub`` is K4, ``verify`` ok) and the
##    next tick applies manifest 6;
## 6. *a failed put restarts what it stopped.* A ``secret put`` for the
##    exclusive ``x-web`` is refused after x-web was stopped (another
##    service's directory is a link); x-web is started again.
##
## *Falsifying mutations*, each red on this gate:
## ``secrets-single-retained-envelope`` (the round-1 design: one retained
## envelope, replaced before the apply) fails step 1 -- after the reboot
## ``old-web`` has no secret; ``credentials-not-planned`` fails step 2 --
## ``x-web`` keeps its old instance and value; ``rotation-not-reconciled``
## fails step 4 -- ``recipient.pub`` stays K2 and ``verify`` reports drift;
## ``retirement-not-resumed`` fails step 5 -- the zeroed key is never
## replaced and every later step fails on it.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``; the seam build, which
## ``scripts/run_addon_gate.sh`` selects for this gate.
##
## *Mocking.* None.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./addon_secrets_support

const Target = "addon-tb"

proc decl(svc, name: string): string =
  "secrets.secretFile {\n  service = \"" & svc & "\"\n  name = \"" & name &
    "\"\n}\n\n"

proc reader(unit, cred, extra: string; fields = ""): string =
  ## A unit that appends "start <pid> <value>" to /var/lib/a7-<unit>.log
  ## when it starts and "stop" when it stops, and keeps running.
  let log = "/var/lib/a7-" & unit & ".log"
  "systemd.systemUnit {\n  name = \"" & unit & ".service\"\n" &
    "  content = \"[Unit]\nDescription=a7 reader\n\n[Service]\n" &
    "ExecStart=/bin/sh -c 'echo start $$$$ $$(cat $$CREDENTIALS_DIRECTORY/" &
    cred & ") >> " & log & "; exec sleep infinity'\n" &
    "ExecStopPost=/bin/sh -c 'echo stop >> " & log & "'\n" & extra &
    "\n[Install]\nWantedBy=multi-user.target\n\"\n" &
    "  credentials = [\"" & cred & "\"]\n" & fields & "}\n\n"

proc gen1Profile(): string =
  decl("old-web", "legacy") & decl("x-web", "token") & decl("h-web", "token") &
    reader("old-web", "legacy", "") &
    reader("x-web", "token", "", "  exclusive = true\n") &
    reader("h-web", "token", "", "  restartIfChanged = false\n")

proc failingProfile(): string =
  "addOn {\n  managedEtcPrefixes = []\n  confirmTimeout = 10\n}\n\n" &
    decl("x-web", "token") & decl("h-web", "token") &
    reader("x-web", "token", "", "  exclusive = true\n") &
    reader("h-web", "token", "", "  restartIfChanged = false\n") &
    "systemd.systemUnit {\n  name = \"a7-broken.service\"\n" &
    "  content = \"[Service]\nExecStart=/bin/sleep infinity\n\n[Install]\n" &
    "WantedBy=multi-user.target\n\"\n  healthCheck = \"tcp:127.0.0.1:18999\"\n}\n"

proc lastValue(g: Guest; unit: string): string =
  let lines = g.exec("cat /var/lib/a7-" & unit & ".log 2>/dev/null").stdout.strip().splitLines()
  for i in countdown(lines.high, 0):
    if lines[i].startsWith("start "):
      let parts = lines[i].split(' ')
      return (if parts.len >= 3: parts[2] else: "")

proc waitValue(g: Guest; unit, want: string): string =
  for i in 0 ..< 30:
    result = g.lastValue(unit)
    if result == want: return
    sleep(1000)

proc neverOverlaps(log: string): bool =
  ## Every start after the first follows a stop.
  var running = false
  for l in log.strip().splitLines():
    if l.startsWith("start "):
      if running: return false
      running = true
    elif l == "stop":
      running = false
  true

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
    # 1. Generation 1, then a failing apply with a narrower envelope.
    let m1 = g.publishManifest(signer, Target, 1, gen1Profile(),
      @[("old-web/legacy", "L1"), ("x-web/token", "X1"), ("h-web/token", "H1")], k1)
    var r = g.tick(repro, Target, @[m1])
    step("tick 1 applies generation 1", r.outcomeOf() == "aoApplied",
         r.stdout & r.stderr)
    step("old-web, x-web and h-web read their secrets",
         g.waitValue("old-web", "L1") == "L1" and g.waitValue("x-web", "X1") == "X1" and
         g.waitValue("h-web", "H1") == "H1", "")
    let gen1 = g.run("readlink /var/lib/repro/system/current").strip()
    let latestBefore = g.run("sha256sum /var/lib/repro/agent/sealed-secrets")
    let m2 = g.publishManifest(signer, Target, 2, failingProfile(),
      @[("x-web/token", "X2"), ("h-web/token", "H2")], k1)
    r = g.tick(repro, Target, @[m2])
    # A reverted apply is aoRolledBack since milestone A8 (the deployment is
    # quarantined; spec §9.2), not the retryable aoApplyFailed.
    step("tick 2 fails and is rolled back", r.outcomeOf() == "aoRolledBack" and
         "rolled back" in r.stdout, r.stdout & r.stderr)
    step("the latest envelope is unchanged and nothing is staged",
         g.run("sha256sum /var/lib/repro/agent/sealed-secrets") == latestBefore and
         g.exec("test ! -e /var/lib/repro/agent/sealed-secrets.staged").exitCode == 0,
         "")
    discard g.exec("systemctl reboot", timeoutSec = 30)
    discard g.waitPoweredOff(300)
    g.boot()
    let report1 = (discard g.waitReasserted();
                   g.exec("cat /var/lib/repro/system/addon/reassert-report").stdout)
    step("after a reboot the re-assert unit is not degraded",
         "reassert: degraded" notin report1, report1)
    step("after a reboot old-web runs with its secret",
         g.exec("systemctl is-active old-web.service").stdout.strip() == "active" and
         g.waitValue("old-web", "L1") == "L1",
         g.exec("journalctl -b -u old-web.service --no-pager | tail -5").stdout)
    # 2. New token values for generation 1's profile.
    discard g.exec("echo --- >> /var/lib/a7-x-web.log")
    let m3 = g.publishManifest(signer, Target, 3, gen1Profile(),
      @[("old-web/legacy", "L1"), ("x-web/token", "X3"), ("h-web/token", "H3")], k1)
    r = g.tick(repro, Target, @[m3])
    step("tick 3 applies new credential values", r.outcomeOf() == "aoApplied",
         r.stdout & r.stderr)
    let xlog = g.exec("cat /var/lib/a7-x-web.log").stdout
    step("the exclusive x-web was stopped before its new instance started, " &
         "and reads the new value", g.waitValue("x-web", "X3") == "X3" and
         neverOverlaps(xlog.split("---")[^1]), xlog)
    step("h-web (restartIfChanged = false) still runs with the old value",
         g.lastValue("h-web") == "H1", g.lastValue("h-web"))
    r = g.exec(repro & " system addon reassert")
    step("the re-assert reports h-web's pending restart",
         "h-web.service runs with credentials older" in r.stdout, r.stdout)
    let gen3 = g.run("readlink /var/lib/repro/system/current").strip()
    # 3. A rotation, then a rollback to a generation sealed to the old key.
    r = g.exec(repro & " system addon rotate-recipient-key")
    var k2 = ""
    for line in r.stdout.splitLines:
      if line.startsWith("next recipient public key: "): k2 = line.split(": ")[1].strip()
    let m4 = g.publishManifest(signer, Target, 4, gen1Profile(),
      @[("old-web/legacy", "L4"), ("x-web/token", "X4"), ("h-web/token", "H4")], k2)
    r = g.tick(repro, Target, @[m4])
    step("tick 4 (sealed to K2) applies and retires K1",
         r.outcomeOf() == "aoApplied" and g.recipientPubHex() == k2,
         r.stdout & r.stderr)
    r = g.exec(repro & " system rollback " & extractFilename(gen3), timeoutSec = 1200)
    step("rollback to generation 3 (sealed to K1, re-sealed to K2) succeeds",
         r.exitCode == 0, r.stdout & r.stderr)
    step("after the rollback x-web reads generation 3's value",
         g.waitValue("x-web", "X3") == "X3", g.lastValue("x-web"))
    discard gen1
    # 4. A rotation cut short after its rename.
    r = g.exec(repro & " system addon rotate-recipient-key")
    var k3 = ""
    for line in r.stdout.splitLines:
      if line.startsWith("next recipient public key: "): k3 = line.split(": ")[1].strip()
    let m5 = g.publishManifest(signer, Target, 5, gen1Profile(),
      @[("old-web/legacy", "L5"), ("x-web/token", "X5"), ("h-web/token", "H5")], k3)
    discard g.run("rm -f " & SeamDir & "/test-paused-at; printf " &
      "'rotation-after-rename\\n' > " & SeamDir & "/test-pause-at")
    discard g.run("setsid nohup sh -c '" & repro & " system addon agent-tick " &
      "--target " & Target & " --source " & m5 & " > /root/addon/tick5.log " &
      "2>&1' > /dev/null 2>&1 < /dev/null &")
    var paused = false
    for i in 0 ..< 600:
      if g.exec("cat " & SeamDir & "/test-paused-at 2>/dev/null").stdout.strip() ==
          "rotation-after-rename":
        paused = true
        break
      sleep(500)
    step("tick 5 paused after the rotation's rename", paused,
         g.exec("cat /root/addon/tick5.log").stdout)
    discard g.exec("pkill -9 -f '[a]ddon agent-tick'; sleep 1; rm -f " &
                   SeamDir & "/test-paused-at")
    step("the crash left recipient.pub behind the key",
         g.recipientPubHex() != k3, g.recipientPubHex())
    r = g.exec(repro & " system addon recover", timeoutSec = 1200)
    step("recover finishes the rotation: recipient.pub is K3",
         g.recipientPubHex() == k3, r.stdout & r.stderr)
    r = g.exec(repro & " system addon verify")
    step("verify reports ok after the completed rotation", r.exitCode == 0,
         r.stdout & r.stderr)
    r = g.tick(repro, Target, @[m5])
    step("the next tick applies manifest 5",
         r.outcomeOf() in ["aoApplied", "aoConverged"] and
         g.waitValue("x-web", "X5") == "X5", r.stdout & r.stderr)
    # 5. A retirement cut between the old key's overwrite and the rename.
    r = g.exec(repro & " system addon rotate-recipient-key")
    var k4 = ""
    for line in r.stdout.splitLines:
      if line.startsWith("next recipient public key: "): k4 = line.split(": ")[1].strip()
    let m6 = g.publishManifest(signer, Target, 6, gen1Profile(),
      @[("old-web/legacy", "L6"), ("x-web/token", "X6"), ("h-web/token", "H6")], k4)
    discard g.run("rm -f " & SeamDir & "/test-paused-at; printf " &
      "'rotation-after-overwrite\\n' > " & SeamDir & "/test-pause-at")
    discard g.run("setsid nohup sh -c '" & repro & " system addon agent-tick " &
      "--target " & Target & " --source " & m6 & " > /root/addon/tick6.log " &
      "2>&1' > /dev/null 2>&1 < /dev/null &")
    paused = false
    for i in 0 ..< 600:
      if g.exec("cat " & SeamDir & "/test-paused-at 2>/dev/null").stdout.strip() ==
          "rotation-after-overwrite":
        paused = true
        break
      sleep(500)
    step("tick 6 paused after overwriting the old key", paused,
         g.exec("cat /root/addon/tick6.log").stdout)
    discard g.exec("pkill -9 -f '[a]ddon agent-tick'; sleep 1; rm -f " &
                   SeamDir & "/test-paused-at")
    step("the crash left the key all NUL bytes, the next key in place",
         g.exec("test -e /var/lib/repro/agent/recipient.key.next && " &
           "[ -z \"$(tr -d '\\000' < /var/lib/repro/agent/recipient.key)\" ]").exitCode == 0,
         g.exec("ls -l /var/lib/repro/agent").stdout)
    r = g.exec(repro & " system addon recover", timeoutSec = 1200)
    step("recover finishes the retirement: recipient.pub is K4",
         g.recipientPubHex() == k4 and
         g.exec("test ! -e /var/lib/repro/agent/recipient.key.next").exitCode == 0,
         r.stdout & r.stderr)
    r = g.exec(repro & " system addon verify")
    step("verify reports ok after the finished retirement", r.exitCode == 0,
         r.stdout & r.stderr)
    r = g.tick(repro, Target, @[m6])
    step("the next tick applies manifest 6",
         r.outcomeOf() in ["aoApplied", "aoConverged"] and
         g.waitValue("x-web", "X6") == "X6", r.stdout & r.stderr)
    # 6. A secret put that fails after stopping an exclusive consumer starts
    # it again: h-web's directory is replaced by a link, so the put's
    # materialisation is refused after x-web (whose token changes) stopped.
    discard g.exec("echo --- >> /var/lib/a7-x-web.log")
    discard g.run("mv /run/repro/secrets/h-web /run/repro/a7-h-web-aside && " &
                  "ln -s /tmp /run/repro/secrets/h-web")
    r = g.exec("printf X7 | " & repro & " system addon secret put " &
               "--service x-web --name token")
    let after = g.exec("cat /var/lib/a7-x-web.log").stdout.split("---")[^1]
    step("the failed put refused, and x-web was stopped and started again",
         r.exitCode != 0 and "stop" in after and "start " in after and
         g.exec("systemctl is-active x-web.service").stdout.strip() == "active",
         r.stdout & r.stderr & " / log: " & after)
    discard g.run("rm /run/repro/secrets/h-web && " &
                  "mv /run/repro/a7-h-web-aside /run/repro/secrets/h-web")
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

suite "e2e_addon_secrets_follow_generations":
  test "secrets follow their generation through failure, reboot, rotation and rollback":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_secrets_follow_generations)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_secrets_follow_generations",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_secrets_follow_generations", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
