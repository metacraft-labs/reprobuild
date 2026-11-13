## Gate ``e2e_addon_unattended_upgrades_week`` (milestone A10; spec §7.8).
##
## ``unattended-upgrades`` stays the distribution's business and keeps
## running under the add-on. This gate runs it for a simulated week: on a
## guest from an image published weeks earlier, with the add-on and its
## fixture services installed, each of seven days moves the snapshot mirror
## and the guest's clock to 06:00 UTC of that day and runs the
## distribution's own daily units -- ``apt-daily.service`` (``apt-get
## update`` through ``apt.systemd.daily``) and ``apt-daily-upgrade.service``
## (``unattended-upgrade``) -- exactly as their timers would, with
## ``APT::Periodic`` deciding by the clock whether each step is due.
##
## Every day both units must succeed and ``unattended-upgrades``' own log
## must carry no error. Over the week: *vacuity guards* -- packages were
## really upgraded and the apt hook really ran after dpkg; the add-on's
## services stay active, are not restarted and serve; the hook recorded
## nothing (no drift report); ``verify`` is ok; the next plan shows no
## change and no transition; no add-on unit failed.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_unattended_upgrades_week``).
##
## *Mocking.* None: the real units, ``unattended-upgrades`` and apt, against
## the archive as it was that week (snapshot_mirror.nim). The only thing
## not as on a production host is time itself, which is set rather than
## waited for.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./snapshot_mirror
import ./upgrade_support

const
  Gate = "e2e_addon_unattended_upgrades_week"
  FirstDay = [("debian-13-20260831-amd64", "20260914T060000Z"),
              ("ubuntu-24.04-20251213-amd64", "20260112T060000Z"),
              ("ubuntu-26.04-20260731-amd64", "20260810T060000Z")]
  WeekConf = "/etc/apt/apt.conf.d/52repro-testbed-week"

proc firstDay(b: BaseImage): string =
  for (n, s) in FirstDay:
    if n == b.name: return s
  raise newException(TestBedError, b.name & " has no simulated week")

proc runBase(m: SnapshotMirror; b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    let day0 = parseStamp(firstDay(b))
    m.setTimestamp(firstDay(b))
    let closure = busyboxClosure(m, b)
    g = newMirroredGuest(b, m)
    g.boot()
    g.prepareMirroredBase(m)
    # The base as an operator runs it: unattended-upgrades installed and on,
    # daily. RandomSleep 0: the units' random delay of up to 30 minutes is
    # the timer's spreading, not part of what runs.
    discard g.run(NonInteractiveApt & "install unattended-upgrades " &
                  "< /dev/null >/dev/null 2>&1", timeoutSec = 1800)
    discard g.run("systemctl unmask unattended-upgrades.service; " &
      "printf 'APT::Periodic::Update-Package-Lists \"1\";\\n" &
      "APT::Periodic::Unattended-Upgrade \"1\";\\n' > /etc/apt/apt.conf.d/20auto-upgrades; " &
      "printf 'APT::Periodic::RandomSleep \"0\";\\n' > " & WeekConf)
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    g.seedClosureCache(closure)
    let a = g.applyProfile(repro, "fixture", fixtureProfile(closure))
    step("fixture applied", a.exitCode == 0, a.stdout & a.stderr)
    if a.exitCode != 0: return fails
    var inv: seq[string]
    for u in FixtureUnits: inv.add(g.serviceState(u).invocation)
    let logBefore = g.hookLogLines().len
    let dpkgLines = parseInt(g.run("cat /var/log/dpkg.log 2>/dev/null | wc -l").strip())
    var days = newJArray()
    for i in 0 ..< 7:
      let stamp = snapshotStamp(day0 + initDuration(days = i))
      m.setTimestamp(stamp)
      g.setGuestClock(stamp, plusHours = 0)
      let u = g.exec("systemctl start apt-daily.service; " &
        "systemctl start apt-daily-upgrade.service; " &
        "systemctl show -p Result --value apt-daily.service apt-daily-upgrade.service",
        timeoutSec = 3600)
      let results = u.stdout.splitWhitespace()
      let uulog = g.exec("cat /var/log/unattended-upgrades/unattended-upgrades.log " &
                         "2>/dev/null").stdout
      days.add(%*{"day": stamp, "results": results})
      step("day " & $(i + 1) & " (" & stamp & "): both daily units succeed",
           u.exitCode == 0 and results == @["success", "success"],
           u.stdout & u.stderr)
      step("day " & $(i + 1) & ": unattended-upgrades logged no error",
           "ERROR" notin uulog and "Traceback" notin uulog,
           uulog[max(0, uulog.len - 3000) .. ^1])
    record["days"] = days
    let upgraded = g.run("tail -n +" & $(dpkgLines + 1) &
      " /var/log/dpkg.log 2>/dev/null | grep -c ' upgrade ' || true").strip()
    record["upgradedPackages"] = %upgraded
    step("vacuity guard: unattended-upgrades upgraded packages during the week",
         (try: parseInt(upgraded) > 0 except ValueError: false), upgraded)
    let j = g.hookJournal()
    step("vacuity guard: the apt hook ran after dpkg", "apt hook: ok" in j, j)
    for i, unit in FixtureUnits:
      let s = g.serviceState(unit)
      step(unit & " stayed active and was not restarted",
           s.active == "active" and s.invocation == inv[i],
           s.active & " " & s.invocation & " (before " & inv[i] & ")")
    step("the fixture services serve", g.serves(WebPort) and g.serves(DocsPort), "")
    let lines = g.hookLogLines()
    step("no add-on drift report: the hook recorded nothing",
         lines.len == logBefore and "finding" notin j and "verify-" notin j,
         lines.join("\n") & "\n" & j)
    let v = g.exec(repro & " system addon verify")
    step("verify reports ok", v.exitCode == 0 and "verify: ok" in v.stdout,
         v.stdout & v.stderr)
    let failed = g.exec("systemctl --failed --no-legend --plain | grep repro || true").stdout
    step("no add-on unit failed", failed.strip().len == 0, failed)
    let p = g.planProfile(repro, "fixture", fixtureProfile(closure))
    step("the next plan shows no change and no transition",
         p.exitCode == 0 and "ledger diff: no change" in p.stdout and
         "service transitions: none" in p.stdout, p.stdout & p.stderr)
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
  test "unattended-upgrades runs a week under the add-on":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_unattended_upgrades_week)")
    else:
      let m = startSnapshotMirror(FirstDay[0][1])
      var failures: seq[string]
      try:
        for b in selectedBases():
          let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
            "backend": "qemu", "mutation": mutation(), "reprobuild": gitHead(),
            "started": $now().utc}
          let f = runBase(m, b, record)
          record["mirror"] = %*{"requests": m.stats.requests,
                                "upstreamFetches": m.stats.upstream,
                                "refused": m.stats.refused}
          record["verdict"] = %(if f.len == 0: "green" else: "red")
          record["finished"] = %($now().utc)
          echo "record: ", writeRecord(Gate, record)
          failures.add(f)
      finally:
        m.stop()
      for f in failures: echo "FAIL ", f
      check failures.len == 0
