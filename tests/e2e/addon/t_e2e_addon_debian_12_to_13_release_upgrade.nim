## Gate ``e2e_addon_debian_12_to_13_release_upgrade`` (milestone A10; spec
## §7.6, §7.9).
##
## A Debian 12 guest with the add-on and two store-closure services goes
## through the documented upgrade to 13 (the Debian 13 release notes,
## https://www.debian.org/releases/trixie/release-notes/upgrading.en.html):
## the sources rewritten from ``bookworm`` to ``trixie``, ``apt update``,
## ``apt upgrade --without-new-pkgs``, ``apt full-upgrade``, reboot -- run
## non-interactively, keeping local conffiles, against the archive as it
## was at ``Snapshot`` (snapshot_mirror.nim). What must hold afterwards is
## in ``release_upgrade_support.runReleaseUpgrade``.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_debian_12_to_13_release_upgrade``).
##
## *Mocking.* See ``release_upgrade_support.nim``.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./release_upgrade_support
import ./snapshot_mirror
import ./upgrade_support

const
  Gate = "e2e_addon_debian_12_to_13_release_upgrade"
  Snapshot = "20261028T000000Z"

proc debianUpgrade(g: Guest; m: SnapshotMirror;
                   step: proc(name: string; ok: bool; detail: string)): bool =
  let rw = g.exec("set -e; for f in /etc/apt/sources.list " &
    "/etc/apt/sources.list.d/* /etc/apt/mirrors/*; do [ -f \"$f\" ] && " &
    "sed -i 's/bookworm/trixie/g' \"$f\"; done; " &
    "grep -rh trixie /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null")
  step("sources rewritten to trixie", rw.exitCode == 0 and "trixie" in rw.stdout,
       rw.stdout & rw.stderr)
  let u = g.exec("apt-get update -o APT::Update::Error-Mode=any 2>&1",
                 timeoutSec = 1800)
  step("apt update (trixie)", u.exitCode == 0, u.stdout)
  if u.exitCode != 0: return false
  let a = g.exec(NonInteractiveApt & "upgrade --without-new-pkgs < /dev/null 2>&1",
                 timeoutSec = 3600)
  step("apt upgrade --without-new-pkgs", a.exitCode == 0,
       a.stdout[max(0, a.stdout.len - 4000) .. ^1])
  if a.exitCode != 0: return false
  let f = g.exec(NonInteractiveApt & "full-upgrade < /dev/null 2>&1",
                 timeoutSec = 3600)
  step("apt full-upgrade", f.exitCode == 0,
       f.stdout[max(0, f.stdout.len - 4000) .. ^1])
  f.exitCode == 0

suite Gate:
  test "the add-on survives the Debian 12 to 13 release upgrade":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_debian_12_to_13_release_upgrade)")
    else:
      let m = startSnapshotMirror(Snapshot)
      var failures: seq[string]
      try:
        for b in selectedBases():
          let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
            "backend": "qemu", "mutation": mutation(), "reprobuild": gitHead(),
            "started": $now().utc}
          let f = runReleaseUpgrade(m, b, Snapshot, "debian 13", debianUpgrade,
                                    record)
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
