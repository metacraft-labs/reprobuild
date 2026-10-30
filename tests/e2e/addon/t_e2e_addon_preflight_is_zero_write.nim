## Gate ``e2e_addon_preflight_is_zero_write``.
##
## On each base of the matrix, in a disposable QEMU guest:
##
## 1. **zero write**: after the base is prepared the guest is shut down and
##    its qcow2 overlay hashed; the guest is booted again with the disk
##    write-protected below it (QEMU ``readonly=on``, the "independently
##    enforced read-only environment" of the ReproOS Anywhere preflight), the
##    add-on binary is copied to tmpfs and verified, the preflight is run and
##    must produce a compatible plan; the guest is shut down and the qcow2
##    must be byte-identical. A preflight that needed to write would fail
##    under the write-protected disk, so success there is itself evidence;
##    the hash comparison is the Anywhere M1 check.
## 2. **vacuity guard**: a normal read-write boot of the same disk changes
##    the qcow2, so the comparison above can see a write; and the preflight
##    run read-write must print the same plan digest as the read-only run
##    (the digest does not depend on whether the root happened to be
##    mounted read-only).
## 3. **refusals** (the preflight exits 2 and names the failing check):
##    a foreign ``/etc/repro``; an unsupported ``VERSION_ID``; and a
##    non-systemd PID 1, built from the same guest and rebooted: real
##    sysvinit (``sysvinit-core``, reporting from ``rc.local``) where the
##    base packages it (Debian), otherwise -- Ubuntu 24.04 ships no init
##    package that replaces PID 1 -- a shell script named with ``init=`` on
##    the kernel command line. Either reports on the serial console, since
##    the fixture has no systemd to bring the network and sshd up.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=preflight-writes``): a
## preflight that writes one file under ``/var/lib``. Under the
## write-protected disk it fails, so step 1 goes red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_preflight_is_zero_write``).
##
## *Mocking.* None.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const FixtureReport = """#!/bin/sh
# repro add-on test fixture: report the preflight on the serial console.
{
  echo "REPRO-ADDON-FIXTURE pid1=$(cat /proc/1/comm)"
  /root/addon/repro system addon preflight
  echo "REPRO-ADDON-FIXTURE preflight-exit=$?"
} > /dev/console 2>&1
"""

const SysvinitFixture = """set -e
export DEBIAN_FRONTEND=noninteractive
# systemd-sysv is Protected and conflicts with sysvinit-core: name its
# removal explicitly, or the solver keeps it and refuses.
apt-get install -y -qq --allow-remove-essential sysvinit-core systemd-sysv- >/dev/null
cp /root/addon/fixture-report /etc/rc.local
echo poweroff >> /etc/rc.local
chmod 0755 /etc/rc.local
"""

const InitFixture = """set -e
# Ubuntu 24.04 ships no sysvinit-core (nor any other init package that
# replaces PID 1), so the non-systemd init here is a shell script named on
# the kernel command line: it mounts the API filesystems, reports, and
# powers off.
cat > /root/addon/fixture-init <<'INIT'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -o remount,rw / 2>/dev/null
/root/addon/fixture-report
sync
poweroff -f
INIT
chmod 0755 /root/addon/fixture-init
mkdir -p /etc/default/grub.d
echo 'GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX init=/root/addon/fixture-init"' > /etc/default/grub.d/99-repro-addon-fixture.cfg
update-grub >/dev/null 2>&1
"""

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
    let (repro, sha) = g.installArtefact()   # on disk: used by later steps
    record["artefactSha256"] = %sha
    g.shutdown()
    let h0 = g.diskSha256()

    # 1. Zero write.
    g.boot(readonly = true)
    let a = artefact(b.debArch)
    # A private tmpfs on /mnt (an existing directory: mounting on it writes
    # nothing to the disk). /run and /dev/shm are mounted noexec.
    discard g.run("mount -t tmpfs -o mode=0700,size=64m repro-addon-preflight /mnt")
    g.copyTo(a.path, "/mnt/repro")
    discard g.run("cd /mnt && echo '" & a.sha256 &
                  "  repro' | sha256sum -c - && chmod 0755 repro")
    let ro = g.exec("/mnt/repro system addon preflight")
    step("preflight on a write-protected disk is compatible", ro.exitCode == 0,
         ro.stdout & ro.stderr)
    g.shutdown()
    let h1 = g.diskSha256()
    step("qcow2 byte-identical after the read-only preflight", h0 == h1,
         "before " & h0 & " after " & h1)
    if ro.exitCode != 0: return fails
    let roDigest = planDigestOf(ro.stdout)

    # 2. Vacuity guard: a read-write boot does write, and the plan is the same.
    g.boot()
    let rw = g.exec(repro & " system addon preflight")
    step("read-write preflight is compatible", rw.exitCode == 0,
         rw.stdout & rw.stderr)
    if rw.exitCode == 0:
      let rwDigest = planDigestOf(rw.stdout)
      step("plan digest is the same read-only and read-write",
           rwDigest == roDigest, "ro " & roDigest & " rw " & rwDigest)

    # 3a. A foreign /etc/repro.
    discard g.run("mkdir /etc/repro")
    let foreign = g.exec(repro & " system addon preflight")
    step("refuses a foreign /etc/repro",
         foreign.exitCode == 2 and "fail foreign-occupants" in foreign.stdout,
         foreign.stdout)
    discard g.run("rmdir /etc/repro")

    # 3b. An unsupported VERSION_ID.
    discard g.run("cp --remove-destination \"$(readlink -f /etc/os-release)\" " &
                  "/etc/os-release && sed -i 's/^VERSION_ID=.*/VERSION_ID=\"11\"/' " &
                  "/etc/os-release")
    let ver = g.exec(repro & " system addon preflight")
    step("refuses an unsupported VERSION_ID",
         ver.exitCode == 2 and "fail distribution" in ver.stdout and
         "VERSION_ID=11" in ver.stdout, ver.stdout)
    discard g.run("ln -sf ../usr/lib/os-release /etc/os-release")
    let back = g.exec(repro & " system addon preflight")
    step("compatible again once os-release is restored", back.exitCode == 0,
         back.stdout)

    # 3c. A non-systemd PID 1: real sysvinit where the base packages it
    # (Debian), otherwise an init script named on the kernel command line.
    writeFile(g.runDir / "fixture-report", FixtureReport)
    g.copyTo(g.runDir / "fixture-report", "/root/addon/fixture-report")
    discard g.run("chmod 0755 /root/addon/fixture-report")
    let hasSysvinit = g.exec("apt-cache policy sysvinit-core | grep -q 'Candidate: [0-9]'").exitCode == 0
    let fixture = if hasSysvinit: "sysvinit-core" else: "init= script"
    record["initFixture"] = %fixture
    let inst = g.exec((if hasSysvinit: SysvinitFixture else: InitFixture),
                      timeoutSec = 1800)
    step("non-systemd init fixture installs (" & fixture & ")",
         inst.exitCode == 0, inst.stdout & inst.stderr)
    if inst.exitCode == 0:
      discard g.exec("systemctl reboot || reboot", timeoutSec = 30)
      discard g.waitPoweredOff(300)
      g.bootNoWait()
      let serial = g.waitSerial("preflight-exit=", 900)
      discard g.waitPoweredOff(120)
      let pid1 = serial.contains("REPRO-ADDON-FIXTURE pid1=init") or
                 serial.contains("REPRO-ADDON-FIXTURE pid1=fixture-init")
      step("the fixture's PID 1 is not systemd", pid1,
           serial[max(0, serial.len - 3000) .. ^1])
      step("refuses a non-systemd PID 1",
           "preflight-exit=2" in serial and "fail init-system" in serial,
           serial[max(0, serial.len - 3000) .. ^1])
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

suite "e2e_addon_preflight_is_zero_write":
  test "the preflight writes nothing and refuses what it must":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_addon_preflight_is_zero_write)")
    elif useIncus():
      skip("zero-write is checked on a disk image; QEMU only")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_preflight_is_zero_write",
          "base": b.name, "arch": b.debArch, "backend": "qemu",
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_preflight_is_zero_write", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
