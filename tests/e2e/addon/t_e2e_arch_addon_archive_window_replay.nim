## Gate ``e2e_arch_addon_archive_window_replay`` (milestone AR6; spec
## ReproOS-Add-On-Mode §7.8, §7.9; §13 decision 91; threat model T45, G43).
##
## The rolling base's counterpart of the Debian point-upgrade and week-of-
## upgrades gates. On each Arch guest (``arch-btrfs-amd64``,
## ``arch-ext4-amd64``):
##
## 1. the guest is moved back to the first date of the pinned 14-date window
##    (``arch_window``) and rebooted into it;
## 2. the add-on is bootstrapped -- its generation 0 carries the ALPM hook
##    (``/etc/pacman.d/hooks/90-repro-addon.hook``, the bytes generation 0
##    renders for the add-on's binary) -- and a generation with two fixture
##    services (store packages, spec §8.3) and a file is applied;
## 3. ``pacman -Syu`` steps through every later date of the window, each from
##    that date of the archive alone (``requirePinnedPacman``). After each:
##    the transaction succeeded; when it changed anything, the ALPM hook ran
##    and reported nothing (pacman's output says ``ok``, its event log stays
##    empty); both services are active in the invocation they had (the plan
##    predicted no restart); and ``repro infra plan`` of the same profile is
##    accepted, its ``base:`` line naming the systemd now installed and the
##    supported matrix, with the change since the generation listed once
##    systemd moved;
## 4. the record names the systemd major bump and the glibc upgrade the
##    window crossed, which must be the pinned ones (a vacuity guard: a
##    window that crossed neither would prove nothing);
## 5. the same profile is applied again after the last date: accepted, no
##    service restarted, ``verify`` ok.
##
## Bases: ``REPRO_ADDON_BASES`` (the recipe's default is
## ``arch-btrfs-amd64,arch-ext4-amd64``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_arch_addon_archive_window_replay``).
##
## *Mocking.* None: real Arch guests, real pacman against the archive's dated
## snapshots through the test bed's caching mirror (``snapshot_mirror``),
## real systemd, the real static add-on binary.

import std/[json, os, strutils, tables, times, unittest]

import repro_test_support/reasoned_skip
import repro_addon/[fingerprint, generation0]

import ./arch_gate_support
import ./arch_update_support
import ./arch_window
import ./snapshot_mirror

const Gate = "e2e_arch_addon_archive_window_replay"

proc expectedFalsifier(mut: string; b: BaseImage): Falsifier =
  raise unknownMutation(Gate, mut)

proc runBase(m: SnapshotMirror; b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newArchGuest(b, diskGiB = 16)
    g.boot()
    g.prepareArchGuest()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let dates = archWindowDates()
    if not g.moveToDate(m, dates[0], step): return fails
    let start = g.pacmanVersions(["systemd", "glibc", "pacman"])
    record["windowStart"] = %start
    step("the window's first date has the pinned systemd and pacman",
         start.getOrDefault("systemd") == ArchWindowSystemdBefore and
           start.getOrDefault("pacman") == ArchWindowPacman and
           start.getOrDefault("glibc") == ArchWindowGlibcBefore, $start)

    g.settleBaseline(step)
    if not g.bootstrapArch(repro, step).ok: return fails
    let exe = g.gen0ReproExe()
    step("generation 0 carries the ALPM hook, as generation 0 renders it",
         g.sha256InGuest(AlpmHookPathInGuest) == sha256Hex(alpmHook(exe)) and
           AlpmHookPathInGuest in g.ledgerOf() and
           g.exec("test -e /etc/apt/apt.conf.d/90repro-addon").exitCode != 0,
         g.run("cat " & AlpmHookPathInGuest & " 2>&1 | head -20"))
    let a1 = g.applyProfile(repro, "gen1", servicesProfile(exe))
    step("gen1: two fixture services and a file apply", a1.exitCode == 0,
         a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails
    let before = g.servicesState()
    step("gen1: both services are active", servicesUnchanged(before, before).ok,
         servicesUnchanged(before, before).detail)

    var prev = start
    var crossed = newJArray()
    var perDate = newJArray()
    var systemdBump, glibcUpgrade: JsonNode
    for date in dates[1 .. ^1]:
      g.pinToDate(m, date)
      let t0 = epochTime()
      let r = g.exec("pacman -Syu --noconfirm " & WindowPacmanFlags & " 2>&1",
                     timeoutSec = 3600)
      let secs = epochTime() - t0
      let said = r.stdout & r.stderr
      step(date & ": pacman -Syu succeeds", r.exitCode == 0,
           said[max(0, said.len - 3000) .. ^1])
      if r.exitCode != 0: return fails
      let now = g.pacmanVersions(["systemd", "glibc", "pacman"])
      let changed = "there is nothing to do" notin said
      var upgraded = 0
      for l in said.splitLines():
        if l.contains("upgrading ") or l.contains("installing "): inc upgraded
      perDate.add(%*{"date": date, "seconds": secs, "changed": changed,
                     "transactionLines": upgraded, "versions": now})
      if changed:
        step(date & ": the ALPM hook ran and reported nothing",
             "repro-addon alpm hook: ok" in said and
               g.logLines(AlpmHookLog).len == 0,
             said[max(0, said.len - 2500) .. ^1] & "\n" &
               g.logLines(AlpmHookLog).join("\n"))
      let svc = servicesUnchanged(before, g.servicesState())
      step(date & ": both services stay active, not restarted", svc.ok,
           svc.detail)
      let p = g.planProfile(repro, "gen1", servicesProfile(exe))
      let line = planBaseLine(p.stdout)
      let major = systemdMajorOf(now.getOrDefault("systemd"))
      let systemdMoved = now.getOrDefault("systemd") != start.getOrDefault("systemd")
      step(date & ": the next plan shows the new base identity, accepted by the matrix",
           p.exitCode == 0 and ("systemd " & major) in line and
             "in the supported matrix" in line and
             (not systemdMoved or
              ("base changed since generation" in p.stdout and
               "systemd:" in p.stdout)),
           "exit " & $p.exitCode & "\n" & p.stdout & p.stderr)
      if systemdMajorOf(prev.getOrDefault("systemd")) != major:
        systemdBump = %*{"date": date, "from": prev.getOrDefault("systemd"),
                         "to": now.getOrDefault("systemd")}
        crossed.add(%*{"package": "systemd", "date": date,
                       "from": prev.getOrDefault("systemd"),
                       "to": now.getOrDefault("systemd")})
      if prev.getOrDefault("glibc") != now.getOrDefault("glibc"):
        glibcUpgrade = %*{"date": date, "from": prev.getOrDefault("glibc"),
                          "to": now.getOrDefault("glibc")}
        crossed.add(%*{"package": "glibc", "date": date,
                       "from": prev.getOrDefault("glibc"),
                       "to": now.getOrDefault("glibc")})
      prev = now
    record["perDate"] = perDate
    record["crossed"] = crossed
    step("the window crossed the pinned systemd major bump",
         systemdBump != nil and systemdBump["date"].getStr() == ArchWindowSystemdBumpDate and
           systemdBump["from"].getStr() == ArchWindowSystemdBefore and
           systemdBump["to"].getStr() == ArchWindowSystemdAfter,
         $systemdBump)
    step("the window crossed the pinned glibc upgrade",
         glibcUpgrade != nil and glibcUpgrade["date"].getStr() == ArchWindowGlibcUpgradeDate and
           glibcUpgrade["from"].getStr() == ArchWindowGlibcBefore and
           glibcUpgrade["to"].getStr() == ArchWindowGlibcAfter,
         $glibcUpgrade)
    step("the ALPM hook ran after the window's transactions (its journal)",
         g.journalOf(AlpmHookTag).count("repro-addon alpm hook: ok") >= 1,
         g.journalOf(AlpmHookTag))

    let a2 = g.applyProfile(repro, "gen1", servicesProfile(exe))
    step("after the window the profile applies again, accepted by the matrix",
         a2.exitCode == 0 and "in the supported matrix" in a2.stdout,
         a2.stdout & a2.stderr)
    let svc = servicesUnchanged(before, g.servicesState())
    step("after the last apply both services are still in their first invocation",
         svc.ok, svc.detail)
    let v = g.exec(repro & " system addon verify")
    step("verify is ok after the window", v.exitCode == 0, v.stdout & v.stderr)
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
  test "pacman -Syu through the pinned window under a running add-on":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      let m = startSnapshotMirror(MirrorStamp)
      m.prewarm(archWindowDates())
      var failures: seq[string]
      try:
        for b in selectedArchBases():
          if isOmarchyBase(b):
            failures.add(b.name & ": " & Gate & " runs on the plain Arch guests")
            continue
          let record = archGateRecord(Gate)
          record["base"] = %b.name
          record["window"] = windowPin()
          let f = runBase(m, b, record)
          record["mirror"] = %*{"requests": m.stats.requests,
                                "upstreamFetches": m.stats.upstream,
                                "refused": m.stats.refused}
          record["verdict"] = %(if f.len == 0: "green" else: "red")
          let judged = judgeRun(Gate, record, f, expectedFalsifier, b)
          echo "record: ", writeRecord(Gate, record)
          failures.add(judged)
      finally:
        m.stop()
      for f in failures: echo "FAIL ", f
      check failures.len == 0
