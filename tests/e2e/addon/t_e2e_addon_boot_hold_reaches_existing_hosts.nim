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
##    (``sysinit.target.wants``), with the bytes this build renders, named in
##    the ledger copy with that digest, and adds it to the stored own
##    profile; nothing else of generation 0 changes on disk;
## 3. a second apply changes nothing of it (idempotent);
## 4. two reboots with nothing pending skip the unit by its condition, and
##    the boots take no longer than the baseline (within 25 % plus 2 s: a
##    VM's boots vary by more than a skipped oneshot costs);
## 5. ``repro system addon uninstall`` removes it and its link through the
##    ledger, and the base is as it was before the bootstrap.
##
## A path in the way -- the unit's file there, not the add-on's -- is
## refused before any generation change; ``t_addon_boot_hold_and_gen0_
## upgrade`` covers it with the failure part-way, and step 2's check that
## nothing else of generation 0 changed is this gate's half.
##
## Falsifying build, red here: ``gen0-not-upgraded`` (step 2: the unit never
## arrives). The reboot behaviour with a switch pending is
## ``t_e2e_addon_floor_reapplies_after_restarts``'s (``boot-hold-after-
## sysinit``, ``boot-holds-unrecorded``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and ``REPRO_A9_PREVIOUS_ADDON``.
##
## *Mocking.* None: the real add-on of two engines, the base's own systemd.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const Gate = "e2e_addon_boot_hold_reaches_existing_hosts"
const Head = "addOn {\n  managedEtcPrefixes = []\n}\n\n"
const Unit = "repro-addon-boot-hold.service"
const UnitFile = "/etc/systemd/system/" & Unit
const WantsLink = "/etc/systemd/system/sysinit.target.wants/" & Unit
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
    var baseline = 0.0
    for i in 1 .. 2:
      g.rebootGuest()
      baseline += g.bootSeconds() / 2
    record["bootSecondsBefore"] = %baseline
    # Every generation-0 object's bytes before the upgrade: only the new
    # unit and its link may differ after it.
    const Gen0Sums = "sha256sum /etc/systemd/system/repro-addon* " &
      "/etc/repro/*.conf /etc/repro/anchors/* /etc/apt/apt.conf.d/90repro-addon " &
      "/etc/profile.d/repro-addon.sh 2>/dev/null | grep -v " & Unit & " | sort"
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
    let unitText = g.exec("cat " & UnitFile).stdout
    step("the unit runs before sysinit.target, while a switch is pending",
         "Before=sysinit.target" in unitText and "DefaultDependencies=no" in unitText and
         "ConditionPathExists=/var/lib/repro/system/addon/pending" in unitText, unitText)
    r = g.applyProfile(repro, "u2", profile)
    let unitSha2 = g.run("sha256sum " & UnitFile & " | cut -d' ' -f1").strip()
    step("a second apply leaves it as it is", r.exitCode == 0 and unitSha2 == unitSha and
         g.exec("grep -c 'name = \"" & Unit & "\"' " & OwnProfile).stdout.strip() == "1",
         r.stdout & r.stderr)
    var withUnit = 0.0
    for i in 1 .. 2:
      g.rebootGuest()
      withUnit += g.bootSeconds() / 2
    record["bootSecondsAfter"] = %withUnit
    let cond = g.exec("systemctl show -p ConditionResult -p ActiveState " & Unit).stdout
    record["bootHoldIdle"] = %cond
    step("with nothing pending the boot skips it, and takes no longer than before",
         "ConditionResult=no" in cond and baseline > 0 and withUnit > 0 and
         withUnit <= baseline * 1.25 + 2.0,
         cond & "before=" & $baseline & "s after=" & $withUnit & "s")
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
