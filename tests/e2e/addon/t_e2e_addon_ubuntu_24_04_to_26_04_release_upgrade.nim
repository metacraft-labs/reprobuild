## Gate ``e2e_addon_ubuntu_24_04_to_26_04_release_upgrade`` (milestone A10;
## spec §7.6, §7.9).
##
## The Debian release-upgrade gate's counterpart for Ubuntu: a 24.04 guest
## with the add-on and two store-closure services runs ``do-release-upgrade``
## to 26.04 LTS (https://documentation.ubuntu.com/server/how-to/software/upgrade-your-release/),
## non-interactively (``-f DistUpgradeViewNonInteractive``), then reboots.
## The upgrader reads the next LTS from ``meta-release-lts`` (its URL set to
## the ``http://`` spelling in ``/etc/update-manager/meta-release`` so it
## goes through the mirror), served from a
## committed copy dated 2026-10-31 (26.04.1 offered to 24.04), and fetches
## itself and every package from the archive as it was at ``Snapshot``
## (snapshot_mirror.nim; ``http_proxy`` for its own downloads). As the
## upgrader requires, the release is brought up to date and rebooted first,
## before the add-on is installed. What must hold afterwards is in
## ``release_upgrade_support.runReleaseUpgrade``.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_addon_ubuntu_24_04_to_26_04_release_upgrade``).
##
## *Mocking.* See ``release_upgrade_support.nim``.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./release_upgrade_support
import ./snapshot_mirror
import ./upgrade_support

const
  Gate = "e2e_addon_ubuntu_24_04_to_26_04_release_upgrade"
  Snapshot = "20261028T000000Z"

proc upToDate(g: Guest; m: SnapshotMirror) =
  discard g.run(NonInteractiveApt & "full-upgrade < /dev/null > /dev/null 2>&1",
                timeoutSec = 3600)
  discard g.rebootAndWait()
  g.setGuestClock(m.timestamp)
  # The upgrader fetches meta-release over https by default; its own
  # configuration file names the URL, and the http spelling goes through
  # the mirror like every other download.
  discard g.run("sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades; " &
    "sed -i 's#https://changelogs.ubuntu.com#http://changelogs.ubuntu.com#' " &
    "/etc/update-manager/meta-release")

proc ubuntuUpgrade(g: Guest; m: SnapshotMirror;
                   step: proc(name: string; ok: bool; detail: string)): bool =
  let r = g.exec("export DEBIAN_FRONTEND=noninteractive http_proxy=" &
    g.guestProxyUrl(m) & " HTTP_PROXY=" & g.guestProxyUrl(m) & "; " &
    "do-release-upgrade -f DistUpgradeViewNonInteractive < /dev/null 2>&1",
    timeoutSec = 7200)
  let tail = r.stdout[max(0, r.stdout.len - 6000) .. ^1]
  step("do-release-upgrade succeeds", r.exitCode == 0, "exit " &
       $r.exitCode & "\n" & tail)
  let rel = g.exec(". /etc/os-release; echo $VERSION_ID").stdout.strip()
  step("vacuity guard: the upgrade installed 26.04 (os-release before reboot)",
       rel == "26.04", rel)
  r.exitCode == 0 and rel == "26.04"

suite Gate:
  test "the add-on survives the Ubuntu 24.04 to 26.04 release upgrade":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_ubuntu_24_04_to_26_04_release_upgrade)")
    else:
      let m = startSnapshotMirror(Snapshot)
      var failures: seq[string]
      try:
        for b in selectedBases():
          let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
            "backend": "qemu", "mutation": mutation(), "reprobuild": gitHead(),
            "started": $now().utc}
          let f = runReleaseUpgrade(m, b, Snapshot, "ubuntu 26.04",
                                    ubuntuUpgrade, record, prepare = upToDate)
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
