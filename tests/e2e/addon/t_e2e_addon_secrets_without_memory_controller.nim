## Gate ``e2e_addon_secrets_without_memory_controller`` (milestone A7, review
## round 4; spec §10.3 and §13's owner decision of 2026-10-31; threat model
## T17).
##
## A host whose kernel has no cgroup memory controller (Raspberry Pi kernels
## boot without one) cannot give a unit ``MemorySwapMax=0``. Secrets work
## there out of the box, and their plaintext stays out of swap because the
## add-on locks every buffer that holds it in RAM (``mlock``).
##
## On each base (the seam build), the guest is booted with
## ``cgroup_disable=memory`` (checked: ``memory`` is not in
## ``/sys/fs/cgroup/cgroup.controllers``), then:
##
## A. *no swap*: a secret put and a profile with a unit loading it apply,
##    the unit reads it; a switch hard-reset at step 5 is finished by the
##    boot recovery (the new generation's unit file is in place, the unit
##    reads the secret, the re-assert unit is not degraded);
## B. *a swap file active from boot*:
##    1. the same reset-and-recover, with swap on during the recovery;
##    2. the same with the recipient key made unusable (``0644``) before
##       the reset: the replay cannot materialise the secrets, and it still
##       FINISHES the switch -- the new unit file is in place -- and the
##       re-assert unit reports ``degraded`` naming the secrets; with the
##       key restored, ``repro system addon secrets`` materialises them;
##    3. a ``secret put`` is held at ``secrets-holding-plaintext`` with a
##       16 MiB secret C6 in its heap (``VmLck`` >= 16 MiB), memory
##       pressure pushes anonymous memory into the swap file (vacuity
##       guard: the pressure pattern is found there), and the raw disk image
##       holds no form of C6.
##
## *Falsifying mutations*: ``secrets-plaintext-unlocked`` (plaintext buffers
## not locked) puts C6 into the swap file; ``replay-reverts-on-secrets``
## reverts the replay in B.2 (the old unit file is back).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``; the seam build, which
## ``scripts/run_addon_gate.sh`` selects for this gate.
##
## *Mocking.* None.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./addon_secrets_support

proc profile(version: string): string =
  "secrets.secretFile {\n  service = \"nm-web\"\n  name = \"token\"\n}\n\n" &
    "systemd.systemUnit {\n  name = \"nm-web.service\"\n" &
    "  content = \"[Unit]\nDescription=nm reader " & version & "\n\n[Service]\n" &
    "RuntimeDirectory=nm-web\nRuntimeDirectoryMode=0755\n" &
    "ExecStart=/bin/sh -c 'cat $$CREDENTIALS_DIRECTORY/token > /run/nm-web/seen; " &
    "exec sleep infinity'\n\n[Install]\nWantedBy=multi-user.target\n\"\n" &
    "  credentials = [\"token\"]\n}\n"

proc seen(g: Guest; want: string): string =
  g.exec("for i in $(seq 1 30); do [ \"$(cat /run/nm-web/seen 2>/dev/null)\" = '" &
         want & "' ] && break; sleep 1; done; cat /run/nm-web/seen 2>/dev/null").stdout

proc unitVersion(g: Guest): string =
  g.exec("sed -n 's/^Description=nm reader //p' " &
         "/etc/systemd/system/nm-web.service").stdout.strip()

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  proc resetAt(repro, name, version, point: string): bool =
    let r = g.startSwitchPausedAt(repro, name, profile(version), point)
    if r.exitCode != 0:
      step("the switch to " & version & " paused at " & point, false,
           r.stdout & r.stderr)
      return false
    g.hardResetAfterSettle()
    g.boot()
    discard g.waitReasserted()
    true
  try:
    if not testSeams():
      step("this gate needs the seam build", false, "REPRO_ADDON_TEST_SEAMS=1")
      return fails
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    g.addKernelCmdline("cgroup_disable=memory")
    g.rebootGuest()
    let ctl = g.exec("cat /sys/fs/cgroup/cgroup.controllers; cat /proc/cmdline").stdout
    step("the guest runs without the memory controller",
         "cgroup_disable=memory" in ctl and
         "memory" notin ctl.splitLines()[0].splitWhitespace(), ctl)
    # A. No swap.
    step("no swap is active",
         g.exec("tail -n +2 /proc/swaps").stdout.strip().len == 0, "")
    var r = g.exec("printf V1 | " & repro & " system addon secret put " &
                   "--service nm-web --name token")
    step("A: secret put works without a memory controller", r.exitCode == 0,
         r.stdout & r.stderr)
    r = g.applyProfile(repro, "v1", profile("v1"))
    step("A: the profile applies and the unit reads its secret",
         r.exitCode == 0 and g.seen("V1") == "V1", r.stdout & r.stderr)
    if resetAt(repro, "v2", "v2", "step-5"):
      let rep = g.exec("cat /var/lib/repro/system/addon/reassert-report").stdout
      step("A: the boot recovery finished the switch (v2) and is not degraded",
           g.unitVersion() == "v2" and "reassert: degraded" notin rep and
           g.seen("V1") == "V1", g.unitVersion() & " / " & rep)
    # B. A swap file, active from boot on.
    discard g.run("fallocate -l 1536M /a7-swapfile && chmod 600 /a7-swapfile && " &
      "mkswap /a7-swapfile >/dev/null && echo '/a7-swapfile none swap sw 0 0' " &
      ">> /etc/fstab && swapon /a7-swapfile")
    step("B: a swap file is active",
         "a7-swapfile" in g.exec("cat /proc/swaps").stdout, "")
    if resetAt(repro, "v3", "v3", "step-5"):
      let rep = g.exec("cat /var/lib/repro/system/addon/reassert-report").stdout
      step("B.1: with swap on, the boot recovery finished the switch (v3)",
           g.unitVersion() == "v3" and "reassert: degraded" notin rep and
           "a7-swapfile" in g.exec("cat /proc/swaps").stdout and
           g.seen("V1") == "V1", g.unitVersion() & " / " & rep)
    # B.2: the recovery cannot materialise the secrets.
    let started = g.startSwitchPausedAt(repro, "v4", profile("v4"), "step-5")
    if started.exitCode == 0:
      discard g.run("chmod 0644 /var/lib/repro/agent/recipient.key; sync")
      g.hardResetAfterSettle()
      g.boot()
      discard g.waitReasserted()
      let rep = g.exec("cat /var/lib/repro/system/addon/reassert-report").stdout
      step("B.2: a recovery that cannot materialise the secrets still finishes " &
           "the switch (v4), and reports degraded naming the secrets",
           g.unitVersion() == "v4" and "degraded" in rep and "secrets" in rep,
           g.unitVersion() & " / " & rep)
      discard g.run("chmod 0400 /var/lib/repro/agent/recipient.key")
      r = g.exec(repro & " system addon secrets")
      discard g.exec("systemctl restart nm-web.service")
      step("B.2: with the key restored the secrets materialise again",
           r.exitCode == 0 and g.seen("V1") == "V1", r.stdout & r.stderr)
    else:
      step("B.2: the switch to v4 paused at step-5", false,
           started.stdout & started.stderr)
    # B.3: plaintext held through memory pressure.
    discard g.run("mkdir -p /mnt/a7probe && mount -t ramfs -o mode=0700 " &
                  "a7probe /mnt/a7probe")
    let c6 = randomBytes(32)
    writeFile(g.runDir / "c6.bin", c6)
    g.copyTo(g.runDir / "c6.bin", "/mnt/a7probe/c6")
    discard g.run("rm -f " & SeamDir & "/test-paused-at; printf " &
      "'secrets-holding-plaintext\\n' > " & SeamDir & "/test-pause-at")
    writeFile(g.runDir / "held.sh", "python3 -c 'import sys; d=open(\"/mnt/" &
      "a7probe/c6\",\"rb\").read(); sys.stdout.buffer.write(d * (16 * 32768))' | " &
      repro & " system addon secret put --service swap-probe --name held " &
      "> /root/addon/held.log 2>&1\n")
    g.copyTo(g.runDir / "held.sh", "/root/addon/held.sh")
    discard g.run("setsid nohup sh /root/addon/held.sh > /dev/null 2>&1 " &
                  "< /dev/null &")
    var held = false
    for i in 0 ..< 120:
      if g.exec("cat " & SeamDir & "/test-paused-at 2>/dev/null").stdout.strip() ==
          "secrets-holding-plaintext":
        held = true
        break
      sleep(500)
    let lck = g.exec("for p in $(pgrep -f '^/[^ ]*repro system addon secret " &
      "put --service swap-probe --name held'); do grep VmLck /proc/$p/status | " &
      "tr -dc 0-9; done").stdout.strip()
    record["heldVmLckKb"] = %lck
    step("B.3: a secret put holds C6 (16 MiB) at the seam",
         held, g.exec("cat /root/addon/held.log").stdout)
    let fill = randomBytes(32)
    let fillHex = canaryForms(fill)[3].bytes
    discard g.exec("python3 -c 'import time; b=bytes.fromhex(\"" & fillHex &
      "\")*32768; m=[bytearray(b) for _ in range(2600)]; time.sleep(3)' " &
      ">/dev/null 2>&1; sync", timeoutSec = 900)
    discard g.exec("pkill -9 -f '[s]ecret put --service swap-probe'; sleep 1")
    g.shutdown()
    var needles: seq[tuple[form, bytes: string]]
    for f in canaryForms(c6): needles.add(("c6-" & f.form, f.bytes))
    needles.add(("fill", fill))
    let hits = g.scanDiskImage(needles)
    record["scan"] = hitsJson(hits)
    var fillHits, secretHits = 0
    for h in hits:
      if h.form == "fill": fillHits = h.hits else: secretHits += h.hits
    step("B.3 vacuity guard: anonymous memory reached the swap file",
         fillHits > 0, $hits)
    step("B.3: no form of C6 on the disk image (its buffer was locked, " &
         "VmLck " & lck & " kB)", secretHits == 0, $hits)
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

suite "e2e_addon_secrets_without_memory_controller":
  test "secrets work and stay out of swap on a kernel with no memory controller":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_secrets_without_memory_controller)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_secrets_without_memory_controller",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_secrets_without_memory_controller", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
