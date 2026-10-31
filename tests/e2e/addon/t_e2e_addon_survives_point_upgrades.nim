## Gate ``e2e_addon_survives_point_upgrades`` (milestone A10; spec §7.6,
## §7.8).
##
## On a guest booted from an image published BEFORE a point release
## (``debian-13-20260831-amd64``: 13.6; ``debian-12-20260706-amd64``: before
## 12.15; ``ubuntu-24.04-20251213-amd64``: 24.04.3), with apt served by the
## time-shifted snapshot mirror at a timestamp AFTER the point release:
##
## 1. bootstrap the add-on and apply the fixture (two services from a
##    ``busybox-static`` store closure, one managed file); both serve;
## 2. ``apt-get full-upgrade`` (non-interactive, as an unattended run
##    would) succeeds unaided;
## 3. *vacuity guards*: the point version changed (``/etc/debian_version``,
##    os-release ``VERSION``), packages were really upgraded, and the apt
##    hook really ran after dpkg (its ``ok`` line in the journal);
## 4. the add-on's services stay active and are NOT restarted (same
##    invocation as before the upgrade): no apply ran, so the plan predicted
##    no transition -- the next ``repro infra plan`` shows no ledger change
##    and no service transition;
## 5. the hook reported nothing: no line in its event log, no warning in
##    the journal; ``verify`` reports ok.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_survives_point_upgrades``).
##
## *Mocking.* None: real archives (as snapshots), real apt, dpkg, systemd.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./snapshot_mirror
import ./upgrade_support

const
  Gate = "e2e_addon_survives_point_upgrades"
  ## The archive moment each base is upgraded to: after its point release.
  UpgradeTo = [("debian-13-20260831-amd64", "20260920T000000Z"),
               ("debian-12-20260706-amd64", "20260720T000000Z"),
               ("ubuntu-24.04-20251213-amd64", "20260301T000000Z")]
  DefaultPointBases = "debian-12-20260706-amd64,debian-13-20260831-amd64," &
                      "ubuntu-24.04-20251213-amd64"

proc stampFor(b: BaseImage): string =
  for (n, s) in UpgradeTo:
    if n == b.name: return s
  raise newException(TestBedError, b.name & " is not a point-upgrade base")

proc runBase(m: SnapshotMirror; b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    m.setTimestamp(stampFor(b))
    record["snapshot"] = %m.timestamp
    let closure = busyboxClosure(m, b)
    g = newGuest(b)
    g.boot()
    g.prepareMirroredBase(m)
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let before = g.osVersion()
    if not g.bootstrapAddon(repro, step): return fails
    g.seedClosureCache(closure)
    let a = g.applyProfile(repro, "fixture", fixtureProfile(closure))
    step("fixture applied", a.exitCode == 0, a.stdout & a.stderr)
    if a.exitCode != 0: return fails
    step("both fixture services serve", g.serves(WebPort) and g.serves(DocsPort), "")
    let bind0 = g.closureBinding(FixtureUnits[0])
    step("the services run from a store closure", bind0.startsWith("/repro/store/"), bind0)
    var inv: seq[string]
    for u in FixtureUnits: inv.add(g.serviceState(u).invocation)
    discard g.run("journalctl --rotate >/dev/null 2>&1; true")
    let logBefore = g.hookLogLines().len
    let dpkgLines = g.run("cat /var/log/dpkg.log 2>/dev/null | wc -l").strip()

    let up = g.exec(NonInteractiveApt & "full-upgrade < /dev/null 2>&1",
                    timeoutSec = 3600)
    step("apt-get full-upgrade succeeds unaided", up.exitCode == 0,
         "exit " & $up.exitCode & "\n" & up.stdout[max(0, up.stdout.len - 4000) .. ^1])
    let after = g.osVersion()
    record["pointVersion"] = %*{"before": before, "after": after}
    step("vacuity guard: the upgrade crossed a point release", before != after,
         before & " -> " & after)
    let upgraded = g.run("tail -n +" & $(parseInt(dpkgLines) + 1) &
      " /var/log/dpkg.log 2>/dev/null | grep -c ' upgrade ' || true").strip()
    record["upgradedPackages"] = %upgraded
    step("vacuity guard: packages were upgraded",
         (try: parseInt(upgraded) > 0 except ValueError: false), upgraded)
    let j = g.hookJournal()
    step("vacuity guard: the apt hook ran after dpkg", "apt hook: ok" in j, j)

    for i, u in FixtureUnits:
      let s = g.serviceState(u)
      step(u & " stayed active and was not restarted",
           s.active == "active" and s.invocation == inv[i],
           s.active & " " & s.invocation & " (before " & inv[i] & ")")
    step("both fixture services still serve", g.serves(WebPort) and g.serves(DocsPort), "")
    step("the store binding is unchanged", g.closureBinding(FixtureUnits[0]) == bind0, "")
    let lines = g.hookLogLines()
    step("the hook reported nothing", lines.len == logBefore and
         "warning" notin g.exec("journalctl -o short -p warning --no-pager " &
                                "-t repro-addon-apt-hook").stdout.toLowerAscii() and
         "finding" notin j and "verify-" notin j,
         lines.join("\n") & "\n" & j)
    let v = g.exec(repro & " system addon verify")
    step("verify reports ok", v.exitCode == 0 and "verify: ok" in v.stdout,
         v.stdout & v.stderr)
    let p = g.planProfile(repro, "fixture", fixtureProfile(closure))
    step("the next plan predicts nothing: no ledger change, no transition",
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
  test "add-on services survive a point upgrade and the hook reports nothing":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_survives_point_upgrades)")
    else:
      if getEnv("REPRO_ADDON_BASES").len == 0:
        putEnv("REPRO_ADDON_BASES", DefaultPointBases)
      let m = startSnapshotMirror("20260920T000000Z")
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
