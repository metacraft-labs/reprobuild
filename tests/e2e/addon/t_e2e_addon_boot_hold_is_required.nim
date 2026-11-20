## Add-on VM gate: the boot-hold unit is required by ``sysinit.target``,
## so an ordering cycle through it never deletes its job, and nothing it
## runs can fail the boot (ReproOS Add-On Mode spec §6.2 step 4, §10.1;
## §13 decision 172, the owner's decision of 2026-11-16 on A9 review round
## 17, finding 2).
##
## On each base:
##
## 1. a floored service only its socket starts applies; its next apply is
##    refused and its revert cannot write the holds (both drop-in
##    directories full), so the switch is pending with its start holds
##    recorded for the boot-hold unit;
## 2. the base gets a socket the profile does not declare, ordered
##    ``Before=repro-addon-boot-hold.service`` with default dependencies: a
##    cycle through the boot-hold unit, which only the base can close (the
##    profile's own is refused, step 4). At the reboot systemd breaks the
##    cycle by deleting the base socket's job, never the boot-hold unit's:
##    the boot-hold unit runs, puts the holds back, and the held socket
##    stays down; ``multi-user.target`` is reached;
## 3. a pending switch whose record the boot-hold unit cannot use (a link):
##    the unit holds every socket, timer and path unit, exits with success,
##    and the boot reaches ``multi-user.target`` (finding 9: hold
##    conservatively, never fail the boot);
## 3a. a manual ``systemctl stop`` of the unit is refused, so it cannot
##    stop ``sysinit.target`` and every unit that requires it;
## 4. the effective half: a profile socket ordered before a base service
##    that is ordered before ``-.mount`` -- a chain the parse half cannot
##    see -- is refused ``boot-hold-cycle`` by the switch's check.
##
## 5. a plain unit ordered after the boot-hold unit and, through a base
##    unit, before ``-.mount`` is refused by the effective half (round 18,
##    M2); the parse half refuses a socket ``Before=-.mount`` on the host.
##
## 6. a drop-in of the profile on a base unit ordering it, through a base
##    unit, before ``-.mount`` is refused by the effective half; one naming
##    the boot-hold unit in ``Conflicts=``, or ordering the base unit
##    before ``-.mount``, by the parse half (round 19, finding 3).
##
## 7. (round 20) a pending marker with no record: the unit holds every
##    socket, timer and path unit, says so, and the boot reaches
##    ``multi-user.target``; and the ``systemd.systemDropIn`` form of step 6.
##    Before each reboot the record and the ``sysinit.target.requires``
##    link are recorded, and after it the unit's condition result, exit
##    status, start time and whole journal.
##
## Falsifying builds, red here: ``boot-hold-record-absent-skips`` (step 7),
## ``boot-hold-systemdropin-unchecked`` and
## ``boot-hold-systemdropin-effective-unchecked`` (step 7's drop-in cases),
## ``boot-hold-wanted`` (step 2: the unit is
## only wanted, so systemd deletes its job and the held socket listens),
## ``boot-hold-cycle-effective-unchecked`` (step 4: the socket applies),
## ``boot-hold-dropins-effective-unchecked`` (step 6, the effective case),
## ``boot-hold-dropins-unchecked`` (step 6, the parse cases).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``; QEMU or Incus.
##
## *Mocking.* None: the real add-on, the base's own systemd and its boot
## transaction.

import std/[json, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  Gate = "e2e_addon_boot_hold_is_required"
  Head = "addOn {\n  managedEtcPrefixes = []\n}\n\n"
  Unit = "repro-addon-boot-hold.service"
  Pending = "/var/lib/repro/system/addon/pending"
  Record = "/var/lib/repro/system/addon/boot-holds"

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
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    discard g.run("useradd -r -M -s /usr/sbin/nologin a9h")
    let binary = g.run("ls -d /repro/store/prefixes/repro-addon/*/bin/repro | head -1").strip()
    let unitText = g.exec("cat /etc/systemd/system/" & Unit).stdout
    step("the boot-hold unit is required by sysinit.target",
         "RequiredBy=sysinit.target" in unitText and
         g.exec("test -L /etc/systemd/system/sysinit.target.requires/" & Unit).exitCode == 0,
         unitText)
    let srp = proc (d: string): string =
      Head & "systemd.systemUnit {\n  name = \"a9h-sr.service\"\n" &
        "  content = \"[Unit]\nDescription=" & d & "\n\n[Service]\nType=oneshot\n" &
        "RemainAfterExit=yes\nUser=a9h\nStateDirectory=a9h-sr\nExecStart=" & binary &
        " --version\n\"\n  enabled = false\n}\n" &
        "systemd.systemUnit {\n  name = \"a9h-sr.socket\"\n  content = \"[Socket]\n" &
        "ListenStream=/run/a9h-sr\nService=a9h-sr.service\n\n[Install]\n" &
        "WantedBy=sockets.target\n\"\n  enabled = true\n}\n"
    proc leavePending(label: string): bool =
      ## The next apply refused (a tree the service never made) and its
      ## revert unable to write the holds: pending at the reboot.
      discard g.run("rm -rf /var/lib/a9h-sr; mkdir /var/lib/a9h-sr; touch /var/lib/a9h-sr/theirs; " &
        "for u in service socket; do d=/etc/systemd/system/a9h-sr.$u.d; mkdir -p $d; " &
        "mountpoint -q $d || mount -t tmpfs -o size=4k a9full $d; " &
        "dd if=/dev/zero of=$d/.fill bs=4096 count=4 2>/dev/null; done; true")
      let r = g.applyProfile(repro, label, srp("A9 round 17 " & label))
      step("the apply " & label & " is refused and its revert is pending",
           r.exitCode != 0 and g.exec("test -e " & Pending).exitCode == 0 and
           g.exec("test -s " & Record).exitCode == 0,
           r.stdout & r.stderr)
      r.exitCode != 0
    var r = g.applyProfile(repro, "s1", srp("A9 round 17"))
    step("a floored service only its socket starts applies", r.exitCode == 0,
         r.stdout & r.stderr)
    discard leavePending("s2")
    # A cycle through the boot-hold unit that only the base closes.
    discard g.run("printf '[Service]\\nExecStart=/bin/true\\n' > /etc/systemd/system/a9cyc.service; " &
      "printf '[Unit]\\nBefore=" & Unit & "\\n[Socket]\\nListenStream=/run/a9cyc\\n" &
      "[Install]\\nWantedBy=sockets.target\\n' > /etc/systemd/system/a9cyc.socket; " &
      "systemctl daemon-reload; systemctl enable a9cyc.socket")
    record["cycleBeforeReboot"] = %g.bootHoldBeforeReboot()
    g.rebootGuest()
    discard g.waitReasserted()
    discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true", timeoutSec = 600)
    let journal = g.exec("journalctl -b -o cat --no-pager | grep -e 'to break ordering cycle' " &
      "-e 'repro-addon boot-holds' ; true").stdout
    let hold = g.exec("systemctl show -p Result -p ActiveState -p ExecMainStatus " & Unit).stdout
    let sock = g.exec("systemctl show -p ActiveState -p AssertResult a9h-sr.socket; " &
      "ss -xlH | grep -c ' /run/a9h-sr '; systemctl is-active multi-user.target; true").stdout
    record["cycleBoot"] = %*{"journal": journal, "bootHold": hold, "heldSocket": sock,
                             "unit": g.bootHoldAfterBoot()}
    step("at the reboot systemd deletes the base socket's job, never the " &
         "boot-hold unit's (RequiredBy=sysinit.target, §13 decision 172)",
         "Job a9cyc.socket/start deleted" in journal and
         ("Job " & Unit & "/start deleted") notin journal and
         "held " in journal and "Result=success" in hold,
         journal & "\n" & hold)
    step("the held socket stays down and does not listen, and multi-user.target " &
         "is reached", "ActiveState=active" notin sock and
         sock.splitLines().len >= 4 and sock.splitLines()[2].strip() == "0" and
         sock.splitLines()[3].strip() == "active", sock)
    # A stop of a unit sysinit.target requires would stop every unit that
    # requires sysinit.target: refused, and nothing stops.
    let stop = g.exec("systemctl stop " & Unit)
    let after = g.exec("systemctl is-active sysinit.target ssh.service; true").stdout
    step("a manual stop of the boot-hold unit is refused, and sysinit.target and " &
         "the base's sshd stay up (RefuseManualStop=yes)",
         stop.exitCode != 0 and "refuse" in (stop.stdout & stop.stderr).toLowerAscii() and
         after.splitLines().len >= 2 and after.splitLines()[0].strip() == "active" and
         after.splitLines()[1].strip() == "active",
         stop.stdout & stop.stderr & "\n" & after)
    discard g.run("systemctl disable a9cyc.socket; rm -f /etc/systemd/system/a9cyc.service " &
      "/etc/systemd/system/a9cyc.socket; systemctl daemon-reload")
    # Finding 9: a record the unit cannot use. Pending again, the record
    # replaced by a link to its own copy.
    discard g.run("umount /etc/systemd/system/a9h-sr.service.d /etc/systemd/system/a9h-sr.socket.d " &
      "2>/dev/null; rm -rf /var/lib/a9h-sr; true")
    r = g.applyProfile(repro, "s3", srp("A9 round 17"))
    step("the next apply without the tree passes", r.exitCode == 0, r.stdout & r.stderr)
    if leavePending("s4"):
      discard g.run("cp " & Record & " /root/boot-holds.copy; rm -f " & Record &
        "; ln -s /root/boot-holds.copy " & Record)
      record["linkBeforeReboot"] = %g.bootHoldBeforeReboot()
      g.rebootGuest()
      discard g.waitReasserted()
      discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true", timeoutSec = 600)
      let j2 = g.exec("journalctl -b -o cat --no-pager -u " & Unit & "; true").stdout
      let h2 = g.exec("systemctl show -p Result -p ActiveState " & Unit &
        "; systemctl is-active multi-user.target; true").stdout
      record["linkBoot"] = %*{"journal": j2, "bootHold": h2, "unit": g.bootHoldAfterBoot()}
      step("a record that is a link: every socket, timer and path unit held, the " &
           "unit succeeds and the boot reaches multi-user.target (A9 review round 17, finding 9)",
           "the record is a link" in j2 and "Result=success" in h2 and
           h2.strip().endsWith("active"), j2 & "\n" & h2)
    discard g.run("umount /etc/systemd/system/a9h-sr.service.d /etc/systemd/system/a9h-sr.socket.d " &
      "2>/dev/null; rm -rf /var/lib/a9h-sr; true")
    discard g.exec(repro & " system addon recover", timeoutSec = 1200)
    r = g.applyProfile(repro, "s5", srp("A9 round 17"))
    step("and the host applies again", r.exitCode == 0, r.stdout & r.stderr)
    # A9 review round 20 (the owner's fail-closed design): a pending marker
    # with no record -- the state round 19's script left every activator
    # free in -- holds every socket, timer and path unit.
    if leavePending("s6"):
      discard g.run("rm -f " & Record)
      record["absentBeforeReboot"] = %g.bootHoldBeforeReboot()
      g.rebootGuest()
      discard g.waitReasserted()
      discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true", timeoutSec = 600)
      let ua = g.bootHoldAfterBoot()
      let sa = g.exec("systemctl show -p ActiveState -p AssertResult a9h-sr.socket; " &
        "ss -xlH | grep -c ' /run/a9h-sr '; systemctl is-active multi-user.target; true").stdout
      record["absentBoot"] = %*{"unit": ua, "heldSocket": sa}
      step("a pending marker with no record: every socket, timer and path unit is " &
           "held, said so, the held socket does not listen, and the boot reaches " &
           "multi-user.target (A9 review round 20)",
           "the record is absent" in ua and "Result=success" in ua and
           "ActiveState=active" notin sa and "AssertResult=no" in sa and
           sa.splitLines().len >= 4 and sa.splitLines()[2].strip() == "0" and
           sa.splitLines()[3].strip() == "active", ua & "\n" & sa)
    discard g.run("umount /etc/systemd/system/a9h-sr.service.d /etc/systemd/system/a9h-sr.socket.d " &
      "2>/dev/null; rm -rf /var/lib/a9h-sr; true")
    discard g.exec(repro & " system addon recover", timeoutSec = 1200)
    r = g.applyProfile(repro, "s7", srp("A9 round 17"))
    step("and the host applies once more", r.exitCode == 0, r.stdout & r.stderr)
    # The effective half: a chain only systemd's report shows.
    discard g.run("printf '[Unit]\\nDefaultDependencies=no\\nBefore=-.mount\\n" &
      "[Service]\\nType=oneshot\\nExecStart=/bin/true\\n' > /etc/systemd/system/a9x.service; " &
      "systemctl daemon-reload")
    r = g.applyProfile(repro, "e1", srp("A9 round 17").replace(
      "content = \"[Socket]\n", "content = \"[Unit]\nBefore=a9x.service\n\n[Socket]\n"))
    step("a socket ordered before a base unit that runs before -.mount is " &
         "refused by the effective half (boot-hold-cycle)",
         r.exitCode != 0 and "boot-hold-cycle" in (r.stdout & r.stderr),
         r.stdout & r.stderr)
    # The owner's decision of 2026-11-16 on A9 review round 18, M2: a
    # plain unit -- no floor, no activator -- ordered after the boot-hold
    # unit and before a base unit that runs before -.mount, by a chain only
    # systemd's report shows.
    let plainUnit = srp("A9 round 18") & "systemd.systemUnit {\n  name = \"a9z.service\"\n" &
      "  content = \"[Unit]\nDefaultDependencies=no\nAfter=" & Unit &
      "\nBefore=a9x.service\n\n[Service]\nType=oneshot\nExecStart=/bin/true\n\"\n" &
      "  floorExceptions = [\"serviceFloor: a plain fixture\"]\n  enabled = false\n}\n"
    r = g.applyProfile(repro, "e2", plainUnit)
    step("a plain unit after the boot-hold unit and before a base unit that runs " &
         "before -.mount is refused by the effective half (A9 review round 18, M2)",
         r.exitCode != 0 and "a9z.service" in (r.stdout & r.stderr) and
         "boot-hold-cycle" in (r.stdout & r.stderr), r.stdout & r.stderr)
    # The owner's decision of 2026-11-17 on A9 review round 19, finding 3
    # ("Yes, check drop-ins"): a drop-in of the profile on a base unit
    # (a9b.service, with default dependencies, which the profile does not
    # declare) ordering it before a9x.service closes the same cycle; only
    # systemd's report shows the chain.
    discard g.run("printf '[Unit]\\nDescription=A9 round 19 base unit\\n" &
      "[Service]\\nType=oneshot\\nExecStart=/bin/true\\n' > /etc/systemd/system/a9b.service; " &
      "systemctl daemon-reload")
    let dropOn = proc (body: string): string =
      srp("A9 round 19") & "systemd.systemUnit {\n  name = \"a9b.service\"\n" &
        "  collision = \"dropIn\"\n  content = \"[Unit]\n" & body & "\n\"\n}\n"
    # A9 review round 20, M-1: the same through the systemd.systemDropIn form.
    let sysDropOn = proc (body: string): string =
      srp("A9 round 20") & "systemd.systemDropIn {\n  unit = \"a9b.service\"\n" &
        "  name = \"a9\"\n  content = \"[Unit]\n" & body & "\n\"\n}\n"
    r = g.applyProfile(repro, "e4", sysDropOn("Before=a9x.service"))
    step("a systemd.systemDropIn ordering a base unit before a base unit that runs " &
         "before -.mount is refused by the effective half (A9 review round 20, M-1)",
         r.exitCode != 0 and "a9b.service" in (r.stdout & r.stderr) and
         "boot-hold-cycle" in (r.stdout & r.stderr), r.stdout & r.stderr)
    r = g.applyProfile(repro, "e3", dropOn("Before=a9x.service"))
    step("a drop-in ordering a base unit before a base unit that runs before " &
         "-.mount is refused by the effective half (A9 review round 19, finding 3)",
         r.exitCode != 0 and "a9b.service" in (r.stdout & r.stderr) and
         "boot-hold-cycle" in (r.stdout & r.stderr), r.stdout & r.stderr)
    discard g.run("rm -f /etc/systemd/system/a9x.service; systemctl daemon-reload")
    block:
      let ledger0 = g.ledgerOf()
      r = g.applyProfile(repro, "p2", dropOn("Conflicts=" & Unit))
      step("the parse half refuses a drop-in on a base unit naming the boot-hold " &
           "unit in Conflicts=, writing nothing (round 19, finding 3)",
           r.exitCode != 0 and "in Conflicts=" in (r.stdout & r.stderr) and
           g.ledgerOf() == ledger0,
           r.stdout & r.stderr)
      r = g.applyProfile(repro, "p4", sysDropOn("Conflicts=" & Unit))
      step("the parse half refuses a systemd.systemDropIn on a base unit naming the " &
           "boot-hold unit in Conflicts=, writing nothing (round 20, M-1)",
           r.exitCode != 0 and "in Conflicts=" in (r.stdout & r.stderr) and
           g.ledgerOf() == ledger0, r.stdout & r.stderr)
      r = g.applyProfile(repro, "p3", dropOn("Before=-.mount"))
      step("and one ordering it before -.mount", r.exitCode != 0 and
           "ordering cycle" in (r.stdout & r.stderr) and g.ledgerOf() == ledger0,
           r.stdout & r.stderr)
    # The parse half on a real host (decision 172 asks a VM case of each
    # half): a socket ordered before -.mount is refused before anything is
    # written.
    let before = g.ledgerOf()
    r = g.applyProfile(repro, "p1", srp("A9 round 18").replace(
      "content = \"[Socket]\n", "content = \"[Unit]\nBefore=-.mount\n\n[Socket]\n"))
    step("the parse half refuses a socket ordered before -.mount, writing nothing",
         r.exitCode != 0 and "ordering cycle" in (r.stdout & r.stderr) and
         g.ledgerOf() == before, r.stdout & r.stderr)
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
  test "the boot-hold unit is required, never deleted, and never fails the boot":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(), "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
