## Add-on VM gate: a host an earlier engine bootstrapped gets the boot-hold
## unit at its next apply (ReproOS Add-On Mode spec §6.2, §10.1, §13
## decision 159; A9 review round 15).
##
## On each base:
##
## 1. the add-on is bootstrapped by the PREVIOUS engine -- a static add-on
##    artefact built from a commit before the boot-hold unit
##    (``REPRO_A9_PREVIOUS_ADDON``: a directory laid out as
##    ``build_addon_static.sh`` writes one, ``<debian-arch>/repro`` with its
##    ``repro.sha256`` and the sandbox launcher) -- and has no
##    ``repro-addon-boot-hold.service``; the previous engine applies the
##    gate's profile, and the boot time with nothing pending is measured over
##    two boots (``UserspaceTimestampMonotonic`` to
##    ``FinishTimestampMonotonic``, after ``is-system-running --wait``);
## 2. one apply by this engine installs the unit, enabled
##    (``sysinit.target.requires``), with the bytes this build renders, named in
##    the ledger copy with that digest, and adds it to the stored own
##    profile; nothing else of generation 0 changes on disk;
## 3. a second apply changes nothing of it (idempotent);
## 4. five reboots with nothing pending skip the unit by its condition, and
##    their mean takes no longer than the baseline's five (within 25 % plus
##    2 s: a VM's boots vary by more than a skipped oneshot costs); each
##    boot's time, the unit's own timestamps and the host's load average
##    are recorded (A9 review round 16, finding 8);
## 4a. the same apply points the re-assert unit at this engine, realised in
##    the store, the unit and the prefix named in the ledger (§13 decision
##    164); a floored service only its socket starts is refused, its
##    revert pending over holds it cannot write (the service's and the
##    socket's drop-in directories full); after a reboot the
##    re-assertion commits the revert, and across a second reboot the
##    socket stays down and does not listen;
## 4b. after the re-point, a switch whose health check fails reverts, and
##    ``repro system rollback`` to the previous engine's generation
##    succeeds; both leave the re-assert and boot-confirm units on this
##    engine and its prefix in the ledger (A9 review round 17, finding 1);
## 5. ``repro system addon uninstall`` removes it and its link through the
##    ledger, and the base is as it was before the bootstrap.
##
## A path in the way -- the unit's file there, not the add-on's -- is
## refused before any generation change; ``t_addon_boot_hold_and_gen0_
## upgrade`` covers it with the failure part-way, and step 2's check that
## nothing else of generation 0 changed is this gate's half.
##
## Falsifying builds, red here: ``gen0-not-upgraded`` (step 2: the unit never
## arrives), ``reassert-not-repointed`` (step 4a: the re-assert unit keeps
## the bootstrap engine, which holds the service but not its socket, so the
## socket listens after the second reboot), ``repoint-backwards`` (step 4b:
## the revert and the rollback point the units back at the previous
## engine). The reboot behaviour with a switch pending is
## ``t_e2e_addon_floor_reapplies_after_restarts``'s (``boot-hold-after-
## sysinit``, ``boot-holds-unrecorded``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and ``REPRO_A9_PREVIOUS_ADDON``.
##
## *Mocking.* None: the real add-on of two engines, the base's own systemd.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

proc currentGeneration(g: Guest): string =
  ## ``current`` is a link to the generation's directory (``state_dir``).
  g.exec("basename \"$(readlink /var/lib/repro/system/current)\"").
    stdout.strip()

const Gate = "e2e_addon_boot_hold_reaches_existing_hosts"
const Head = "addOn {\n  managedEtcPrefixes = []\n}\n\n"
const Unit = "repro-addon-boot-hold.service"
const UnitFile = "/etc/systemd/system/" & Unit
const WantsLink = "/etc/systemd/system/sysinit.target.requires/" & Unit
  ## ``RequiredBy=sysinit.target`` (§13 decision 172).
const OwnProfile = "/var/lib/repro/system/addon/own.profile"

proc installPrevious(g: Guest; dir = "/root/addon-prev"): tuple[repro, sha: string] =
  ## The previous engine's artefact, verified in the guest against its
  ## published digest before it runs, as ``installArtefact`` does.
  let root = getEnv("REPRO_A9_PREVIOUS_ADDON")
  if root.len == 0:
    raise newException(TestBedError, "REPRO_A9_PREVIOUS_ADDON must name the " &
      "previous engine's add-on artefact directory")
  let a = root / g.base.debArch
  let sha = readFile(a / "repro.sha256").splitWhitespace()[0]
  discard g.run("mkdir -p " & dir)
  g.copyTo(a / "repro", dir & "/repro")
  g.copyTo(a / "reprobuild-sandbox-launcher", dir & "/reprobuild-sandbox-launcher")
  discard g.run("cd " & dir & " && echo '" & sha & "  repro' | sha256sum -c - && " &
                "chmod 0755 repro reprobuild-sandbox-launcher && " &
                "ln -sf repro repro-addon-fingerprint")
  (dir & "/repro", sha)

proc bootSeconds(g: Guest): float =
  ## Userspace boot time of the boot just finished, in seconds.
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

const Boots = 5
  ## Boots per side of the boot-time comparison (A9 review round 16,
  ## finding 8).

proc bootSeries(g: Guest; label: string; record: JsonNode): seq[float] =
  ## ``Boots`` reboots, each one's userspace time, with the boot-hold unit's
  ## own timestamps (``systemd-analyze blame`` and ``critical-chain``) and
  ## the load average of the host the VM runs on, recorded per boot.
  let arr = newJArray()
  for i in 1 .. Boots:
    g.rebootGuest()
    let t = g.bootSeconds()
    result.add(t)
    let own = g.exec("systemd-analyze blame --no-pager 2>/dev/null | grep -E " &
      "'repro-addon-(boot-hold|reassert)' ; systemd-analyze critical-chain " &
      "--no-pager " & Unit & " 2>/dev/null | tail -4; systemctl show -p " &
      "ConditionResult -p ConditionTimestampMonotonic -p ActiveEnterTimestampMonotonic " &
      Unit & "; true").stdout
    arr.add(%*{"boot": i, "userspaceSeconds": t, "unit": own,
               "hostLoad": readFile("/proc/loadavg").strip()})
  record[label] = arr

proc mean(xs: seq[float]): float =
  for x in xs: result += x / xs.len.float

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail[max(0, detail.len - 3000) .. ^1])
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (prev, prevSha) = g.installPrevious()
    let (repro, sha) = g.installArtefact()
    record["previousArtefactSha256"] = %prevSha
    record["artefactSha256"] = %sha
    discard g.run("useradd -r -M -s /usr/sbin/nologin a9e")
    # The base after a clean reboot, so the fingerprint below compares like
    # with like (a first boot runs units a later one does not).
    g.rebootGuest()
    let f0 = g.takeFingerprint(repro)
    if not g.bootstrapAddon(prev, step): return fails
    step("the previous engine's generation 0 has no boot-hold unit",
         g.exec("test -e " & UnitFile).exitCode != 0 and
         g.exec("grep -c 'name = \"" & Unit & "\"' " & OwnProfile & "; true").stdout.strip() == "0",
         g.exec("ls -la /etc/systemd/system | grep repro-addon").stdout)
    let binary = g.run("ls -d /repro/store/prefixes/repro-addon/*/bin/repro | head -1").strip()
    let prevExe = binary   # the previous engine, as bootstrap placed it
    let profile = Head & "systemd.systemUnit {\n  name = \"a9b-control.service\"\n" &
      "  content = \"[Unit]\nDescription=A9 round 15\n\n[Service]\nType=oneshot\n" &
      "RemainAfterExit=yes\nUser=a9e\nExecStart=" & binary & " --version\n\n" &
      "[Install]\nWantedBy=multi-user.target\n\"\n  enabled = true\n}\n"
    # The same profile applied by the previous engine first, so the boots
    # compared differ by the boot-hold unit alone (a floored unit wanted by
    # multi-user.target waits for the re-assertion either way, decision
    # 144). Two boots each: a loaded host's boots vary.
    var r = g.applyProfile(prev, "u0", profile)
    step("the previous engine applies the profile", r.exitCode == 0, r.stdout & r.stderr)
    let genPrev = g.currentGeneration()
    let before5 = g.bootSeries("bootsBefore", record)
    let baseline = mean(before5)
    record["bootSecondsBefore"] = %baseline
    # Every generation-0 object's bytes before the upgrade: only the new
    # unit and its link, and the re-assert unit (§13 decision 164), may
    # differ after it.
    const Gen0Sums = "sha256sum /etc/systemd/system/repro-addon* " &
      "/etc/repro/*.conf /etc/repro/anchors/* /etc/apt/apt.conf.d/90repro-addon " &
      "/etc/profile.d/repro-addon.sh 2>/dev/null | grep -v -e " & Unit &
      " -e repro-addon-reassert.service -e repro-addon-boot-confirm.service | sort"
    let before = g.exec(Gen0Sums).stdout
    r = g.applyProfile(repro, "u1", profile)
    let unitSha = g.run("sha256sum " & UnitFile & " 2>/dev/null | cut -d' ' -f1").strip()
    let ledger = g.ledgerOf()
    var ledgered = false
    for l in ledger.splitLines():
      if UnitFile in l and unitSha.len == 64 and unitSha in l: ledgered = true
    record["unitSha256"] = %unitSha
    step("this engine's first apply installs the unit, enabled, ledgered with its digest",
         r.exitCode == 0 and unitSha.len == 64 and ledgered and
         g.exec("test -L " & WantsLink).exitCode == 0 and
         g.exec("grep -c 'name = \"" & Unit & "\"' " & OwnProfile).stdout.strip() == "1",
         r.stdout & r.stderr & "\n" & ledger)
    let after = g.exec(Gen0Sums).stdout
    step("and changes nothing else of generation 0", after == before,
         "before:\n" & before & "after:\n" & after)
    # §13 decision 164: the re-assert unit now runs this engine, from the
    # store, and the ledger names the new unit and the engine's prefix.
    const Reassert = "/etc/systemd/system/repro-addon-reassert.service"
    let engineSha = g.run("sha256sum " & repro & " | cut -d' ' -f1").strip()
    let reassertText = g.exec("cat " & Reassert).stdout
    let reassertSha = g.run("sha256sum " & Reassert & " | cut -d' ' -f1").strip()
    let ledger1 = g.ledgerOf()
    var engineExe = ""
    for l in reassertText.splitLines():
      if l.startsWith("ExecStart=/bin/sh -c 'if [ -x "):
        engineExe = l["ExecStart=/bin/sh -c 'if [ -x ".len .. ^1].split(' ')[0]
    record["reassertExe"] = %engineExe
    step("and points the re-assert unit at this engine, in the store, ledgered " &
         "(§13 decision 164)",
         engineExe.len > 0 and engineExe != prevExe and
         g.exec("test -x " & engineExe & " && cmp -s " & engineExe & " " & repro).exitCode == 0 and
         (reassertSha in ledger1) and (parentDir(parentDir(engineExe)) in ledger1),
         reassertText & "\nengine " & engineSha & "\n" & ledger1)
    let unitText = g.exec("cat " & UnitFile).stdout
    step("the unit runs before sysinit.target, while a switch is pending",
         "Before=sysinit.target" in unitText and "DefaultDependencies=no" in unitText and
         "ConditionPathExists=/var/lib/repro/system/addon/pending" in unitText, unitText)
    r = g.applyProfile(repro, "u2", profile)
    let unitSha2 = g.run("sha256sum " & UnitFile & " | cut -d' ' -f1").strip()
    step("a second apply leaves it as it is", r.exitCode == 0 and unitSha2 == unitSha and
         g.run("sha256sum " & Reassert & " | cut -d' ' -f1").strip() == reassertSha and
         g.exec("grep -c 'name = \"" & Unit & "\"' " & OwnProfile).stdout.strip() == "1",
         r.stdout & r.stderr)
    let after5 = g.bootSeries("bootsAfter", record)
    let withUnit = mean(after5)
    record["bootSecondsAfter"] = %withUnit
    let cond = g.exec("systemctl show -p ConditionResult -p ActiveState " & Unit).stdout
    record["bootHoldIdle"] = %cond
    step("with nothing pending the boot skips it, and takes no longer than before",
         "ConditionResult=no" in cond and baseline > 0 and withUnit > 0 and
         withUnit <= baseline * 1.25 + 2.0,
         cond & "before=" & $baseline & "s after=" & $withUnit & "s")
    # §13 decision 164, the re-pointed re-assert unit at a reboot: a held
    # service's socket stays down. A
    # floored service only its socket starts is refused (a root tree), and
    # its revert cannot write the service's hold (a full tmpfs over the
    # drop-in directory), so it is pending at the reboot. The tmpfs is gone
    # after it: the re-assertion replays the revert and commits it. With
    # this engine the socket is held persistently too, so at a second
    # reboot it stays down; with the bootstrap engine only the service is.
    let srp = Head & "systemd.systemUnit {\n  name = \"a9b-sr.service\"\n" &
      "  content = \"[Unit]\nDescription=A9 round 16\n\n[Service]\nType=oneshot\n" &
      "RemainAfterExit=yes\nUser=a9e\nStateDirectory=a9b-sr\nExecStart=" & binary &
      " --version\n\"\n  enabled = false\n}\n" &
      "systemd.systemUnit {\n  name = \"a9b-sr.socket\"\n  content = \"[Socket]\n" &
      "ListenStream=/run/a9b-sr\nService=a9b-sr.service\n\n[Install]\n" &
      "WantedBy=sockets.target\n\"\n  enabled = true\n}\n"
    r = g.applyProfile(repro, "s1", srp)
    step("a floored service only its socket starts applies", r.exitCode == 0,
         r.stdout & r.stderr)
    # Both drop-in directories full, so before the reboot neither the
    # service nor its socket has a persistent hold: what holds them after
    # it is the re-assertion's replay alone, on the engine it runs.
    discard g.run("rm -rf /var/lib/a9b-sr; mkdir /var/lib/a9b-sr; touch /var/lib/a9b-sr/theirs; " &
      "for u in service socket; do d=/etc/systemd/system/a9b-sr.$u.d; mkdir -p $d; " &
      "mount -t tmpfs -o size=4k a9full $d; " &
      "dd if=/dev/zero of=$d/.fill bs=4096 count=4 2>/dev/null; done; true")
    r = g.applyProfile(repro, "s2", srp.replace("A9 round 16", "A9 round 16 s2"))
    step("its next apply is refused and the revert, unable to write the hold, is pending",
         r.exitCode != 0 and g.exec("test -e /var/lib/repro/system/addon/pending").exitCode == 0,
         r.stdout & r.stderr)
    g.rebootGuest()
    discard g.waitReasserted()
    let first = g.exec("test -e /var/lib/repro/system/addon/pending && echo pending; " &
      "ls /etc/systemd/system/a9b-sr.socket.d/ 2>&1; systemctl is-active a9b-sr.socket; true").stdout
    record["repointedFirstBoot"] = %first
    g.rebootGuest()
    discard g.waitReasserted()
    let second = g.exec("systemctl show -p ActiveState -p AssertResult a9b-sr.socket; " &
      "ss -xlH | grep -c ' /run/a9b-sr '; journalctl -b -o cat --no-pager " &
      "-u repro-addon-reassert.service | tail -5; true").stdout
    record["repointedSecondBoot"] = %second
    step("after the revert committed at a reboot, the held service's socket stays " &
         "down across the next reboot (§13 decisions 155 and 164: the re-assert unit runs this engine)",
         "pending" notin first and "ActiveState=active" notin second and
         second.splitLines().len > 2 and second.splitLines()[2].strip() == "0",
         first & "\n" & second)
    discard g.run("rm -rf /var/lib/a9b-sr")
    r = g.applyProfile(repro, "s3", profile)
    step("and the next apply without it passes", r.exitCode == 0, r.stdout & r.stderr)
    # A9 review round 17, finding 1 (§13 decision 164 as amended): a revert
    # and a rollback after the re-point. The target generation of each
    # names the previous engine; the units on disk run this one. Both must
    # succeed, and the units keep this engine (never pointed back).
    proc engineUnits(): string =
      g.exec("grep -h -o '/repro/store/prefixes/repro-addon/[^ ]*/bin/repro' " &
        "/etc/systemd/system/repro-addon-reassert.service " &
        "/etc/systemd/system/repro-addon-boot-confirm.service | sort -u").stdout.strip()
    let failing = Head.replace("managedEtcPrefixes = []",
        "managedEtcPrefixes = []\n  confirmTimeout = 5") &
      "systemd.systemUnit {\n  name = \"a9b-fail.service\"\n" &
      "  content = \"[Unit]\nDescription=A9 round 17\n\n[Service]\nType=oneshot\n" &
      "RemainAfterExit=yes\nUser=a9e\nExecStart=" & binary & " --version\n\n" &
      "[Install]\nWantedBy=multi-user.target\n\"\n  enabled = true\n" &
      "  healthCheck = \"tcp:127.0.0.1:1\"\n}\n"
    let genS3 = g.currentGeneration()
    r = g.applyProfile(repro, "f1", failing)
    let afterRevert = engineUnits()
    record["engineAfterRevert"] = %afterRevert
    step("a switch whose check fails reverts, and the units keep this engine " &
         "(A9 review round 17, finding 1)",
         r.exitCode != 0 and "was rolled back to " & genS3 in (r.stdout & r.stderr) and
         g.exec("test -e /var/lib/repro/system/addon/pending").exitCode != 0 and
         afterRevert == engineExe,
         r.stdout & r.stderr & "\nunits run: " & afterRevert)
    r = g.exec(repro & " system rollback " & genPrev, timeoutSec = 1200)
    let afterRollback = engineUnits()
    record["engineAfterRollback"] = %afterRollback
    step("a rollback to the previous engine's generation succeeds, and the units " &
         "keep this engine, ledgered",
         r.exitCode == 0 and afterRollback == engineExe and
         g.run("sha256sum " & Reassert & " | cut -d' ' -f1").strip() in g.ledgerOf() and
         parentDir(parentDir(engineExe)) in g.ledgerOf(),
         r.stdout & r.stderr & "\nunits run: " & afterRollback)
    r = g.applyProfile(repro, "s4", profile)
    step("and the next apply passes", r.exitCode == 0, r.stdout & r.stderr)
    # The drop-in directory the gate made for the tmpfs is the gate's.
    discard g.run("rmdir /etc/systemd/system/a9b-sr.service.d " &
                  "/etc/systemd/system/a9b-sr.socket.d 2>/dev/null; true")
    let un = g.exec(repro & " system addon uninstall", timeoutSec = 1800)
    step("uninstall removes the unit and its link through the ledger",
         un.exitCode == 0 and g.exec("test -e " & UnitFile).exitCode != 0 and
         g.exec("test -L " & WantsLink).exitCode != 0,
         un.stdout & un.stderr)
    let id = identityReport(f0, g.takeFingerprint(repro))
    step("the base is as it was before the bootstrap", id.ok, id.text)
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
  test "a host an earlier engine bootstrapped gets the boot-hold unit at its next apply":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "previous": getEnv("REPRO_A9_PREVIOUS_ADDON"), "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
