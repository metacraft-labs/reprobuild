## Gate ``e2e_addon_no_plaintext_secret_on_disk`` (milestone A7; spec §10.3;
## threat model G18, T17).
##
## A 32-byte random canary secret is delivered and consumed by a fixture
## service through ``$CREDENTIALS_DIRECTORY``; the guest is shut down and
## its raw disk image is scanned for the canary (and its base64 and hex
## forms): zero hits. Repeated after the apply is killed during
## materialisation.
##
## On each base:
##
## 1. bootstrap; a producer on the test host publishes manifest 1, whose
##    sealed section carries canary C1 as ``canary-web/canary`` and whose
##    profile runs ``canary-web.service`` (``DynamicUser=yes``) loading it
##    through ``credentials``; the tick applies it. The service writes the
##    SHA-256 of what it read to ``/run`` (a tmpfs): it must equal C1's;
## 2. the operator path: a second canary C2, generated in the guest, goes
##    in through ``repro system addon secret put`` on stdin, and a profile
##    declaring it is applied; the service reads it too. (The test reads
##    C2 back from ``/run/repro/secrets`` to know what to scan for.)
##    Modes: the directories ``0700`` root, the files ``0400`` root;
## 3. vacuity guard: a random 32-byte probe is written to a file in the
##    guest and synced, so the scan must find it;
## 4. power off; ``qemu-img convert`` the disk to raw; scan for C1 and C2
##    in every form (bytes, base64, base64url, hex, HEX): zero hits; the
##    probe: found;
## 5. boot again: the re-assert unit re-materialises both secrets from the
##    retained envelope (the service reads C1 again after the boot);
## 6. *killed mid-materialisation*: manifest 2 carries a new canary C3; its
##    tick runs with the seam build's pause at ``secrets-mid-write`` (C3 is
##    in place in the tmpfs, the switch is mid-step-6), is killed with
##    SIGKILL there, and the guest is powered off; the raw image is scanned
##    for C1, C2 and C3: zero hits.
## 7. *swap* (after a boot): a 16 MiB secret of a repeated canary C4 goes
##    in through ``secret put``, a 1.5 GiB swap file is enabled, and a
##    process fills more memory than the guest has with a known pattern;
##    the guest is powered off and the image scanned: the pattern is found
##    (vacuity guard: swap was written), C4 is not. The secrets directory
##    is a ramfs, whose pages are never swapped. During the pressure a
##    second ``secret put`` is held at the seam ``secrets-holding-plaintext``
##    with a 16 MiB secret C5 in its heap: it runs in a scope with
##    ``MemorySwapMax=0`` (checked in its cgroup), so C5 is not on the image
##    either; the boot secrets and re-assert units carry ``MemorySwapMax=0``.
##
## *Falsifying mutations*: ``secrets-on-tmpfs`` accepts a plain directory
## on /run's tmpfs, so the swap pass finds C4 in the swap file;
## ``secrets-plaintext-swappable`` neither locks the plaintext buffers in RAM
## nor runs the processes and units that hold them with ``MemorySwapMax=0``,
## so the held C5 reaches the swap file;
## ``secrets-on-disk`` materialises into
## ``/var/lib/repro/secrets`` (the root filesystem) with the tmpfs check
## off; the scan then finds the canaries and the gate goes red
## (``REPRO_ADDON_MUTATION=secrets-on-disk``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``; the seam build (step 6), which
## ``scripts/run_addon_gate.sh`` selects for this gate.
##
## *Mocking.* None: a real guest, real systemd credentials, the real
## static binary; the producer is the deploy agent's own code on the host.

import std/[json, os, strutils, times, unittest]

import nimcrypto/[hash, sha2]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./addon_secrets_support

const Target = "addon-tb"

proc sha256Hex(s: string): string =
  ($sha256.digest(s)).toLowerAscii()

proc profile(names: seq[string]): string =
  var decls = ""
  for n in names:
    decls.add("secrets.secretFile {\n  service = \"canary-web\"\n  name = \"" &
              n & "\"\n}\n\n")
  var quoted: seq[string]
  for n in names: quoted.add("\"" & n & "\"")
  # The service hashes each credential into /run (a tmpfs) and stays up.
  var script = ""
  for n in names:
    script.add("sha256sum $$CREDENTIALS_DIRECTORY/" & n &
               " | cut -c1-64 > /run/canary-proof/" & n & "; ")
  decls & "systemd.systemUnit {\n  name = \"canary-web.service\"\n" &
    "  content = \"[Unit]\nDescription=canary consumer\n\n[Service]\n" &
    "DynamicUser=yes\nRuntimeDirectory=canary-proof\n" &
    "RuntimeDirectoryMode=0755\n" &
    "ExecStart=/bin/sh -c '" & script & "exec sleep infinity'\n\n" &
    "[Install]\nWantedBy=multi-user.target\n\"\n" &
    "  credentials = [" & quoted.join(", ") & "]\n}\n"

proc proof(g: Guest; name: string): string =
  g.exec("for i in $(seq 1 30); do [ -s /run/canary-proof/" & name &
         " ] && break; sleep 1; done; cat /run/canary-proof/" & name &
         " 2>/dev/null").stdout.strip()

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
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let (ok, anchors) = g.bootstrapAddonWithAnchors(repro, step)
    if not ok: return fails
    let signer = anchors.deploySignerKeys[0]
    let pub = g.recipientPubHex()
    # 1. The producer's sealed section, applied by the tick.
    let c1 = randomBytes(32)
    let m1 = g.publishManifest(signer, Target, 1, profile(@["canary"]),
      @[("canary-web/canary", c1)], pub)
    var r = g.tick(repro, Target, @[m1])
    step("tick 1 applies the manifest with the sealed canary",
         r.exitCode == 0 and r.outcomeOf() == "aoApplied", r.stdout & r.stderr)
    step("the service read the canary through $CREDENTIALS_DIRECTORY",
         g.proof("canary") == sha256Hex(c1), g.proof("canary"))
    # 2. The operator path.
    r = g.exec("head -c 32 /dev/urandom | " & repro &
      " system addon secret put --service canary-web --name put")
    step("secret put (stdin) succeeds", r.exitCode == 0, r.stdout & r.stderr)
    r = g.applyProfile(repro, "p2", profile(@["canary", "put"]))
    step("a profile declaring the put secret applies", r.exitCode == 0,
         r.stdout & r.stderr)
    # Read back from wherever this build materialises (the
    # `secrets-on-disk` mutation build puts it on the root filesystem).
    let c2hex = g.exec("f=/run/repro/secrets/canary-web/put; " &
      "[ -e $f ] || f=/var/lib/repro/secrets/canary-web/put; " &
      "od -An -v -tx1 $f | tr -d ' \\n'").stdout.strip()
    var c2 = ""
    for i in countup(0, c2hex.len - 2, 2): c2.add(char(parseHexInt(c2hex[i .. i + 1])))
    step("the put secret is 32 bytes and the service read it",
         c2.len == 32 and g.proof("put") == sha256Hex(c2), $c2.len)
    let modes = g.exec("stat -c '%a %U %n' /run/repro/secrets " &
      "/run/repro/secrets/canary-web /run/repro/secrets/canary-web/canary " &
      "/run/repro/secrets/canary-web/put; findmnt -no FSTYPE -T " &
      "/run/repro/secrets").stdout
    step("secrets: directories 0700 root, files 0400 root, on a ramfs",
         "700 root /run/repro/secrets\n" in modes and
         "700 root /run/repro/secrets/canary-web\n" in modes and
         "400 root /run/repro/secrets/canary-web/canary" in modes and
         "400 root /run/repro/secrets/canary-web/put" in modes and
         modes.strip().endsWith("ramfs"), modes)
    # 3. The vacuity guard.
    let probe = randomBytes(32)
    let probeHex = canaryForms(probe)[3].bytes
    discard g.run("python3 -c 'import sys; sys.stdout.buffer.write(" &
                  "bytes.fromhex(\"" & probeHex & "\"))' > /root/scan-probe; sync")
    # 4. Off, and scan.
    g.shutdown()
    var needles = canaryForms(c1)
    for f in canaryForms(c2): needles.add(("put-" & f.form, f.bytes))
    let hits = g.scanDiskImage(needles & @[("probe", probe)])
    record["scan1"] = hitsJson(hits)
    var canaryHits = 0
    var probeHits = 0
    for h in hits:
      if h.form == "probe": probeHits = h.hits else: canaryHits += h.hits
    step("vacuity guard: the scan finds the probe written to disk",
         probeHits > 0, $hits)
    step("no plaintext secret on disk (bytes, base64, hex)", canaryHits == 0,
         $hits)
    # 5. Boot again: re-materialised from the retained envelope.
    g.boot()
    discard g.waitReasserted()
    step("after a reboot the re-assert unit re-materialised the secrets",
         g.proof("canary") == sha256Hex(c1) and g.proof("put") == sha256Hex(c2),
         g.exec("journalctl -b -o cat -u repro-addon-reassert.service " &
                "-u canary-web.service --no-pager | tail -20").stdout)
    # 6. Killed in the middle of a materialisation.
    if testSeams():
      let c3 = randomBytes(32)
      # The retained envelope is replaced by the producer's, which must
      # carry every declared entry: C2 travels in it too now.
      let m2 = g.publishManifest(signer, Target, 2, profile(@["canary", "put"]),
        @[("canary-web/canary", c3), ("canary-web/put", c2)], pub)
      discard g.run("rm -f " & SeamDir & "/test-paused-at /root/addon/tick2.rc; " &
        "printf 'secrets-mid-write\\n' > " & SeamDir & "/test-pause-at")
      discard g.run("setsid nohup sh -c '" & repro & " system addon agent-tick " &
        "--target " & Target & " --source " & m2 & " > /root/addon/tick2.log " &
        "2>&1; echo $? > /root/addon/tick2.rc' > /dev/null 2>&1 < /dev/null &")
      var paused = false
      for i in 0 ..< 600:
        if g.exec("cat " & SeamDir & "/test-paused-at 2>/dev/null").stdout.strip() ==
            "secrets-mid-write":
          paused = true
          break
        sleep(500)
      step("the tick paused mid-materialisation", paused,
           g.exec("cat /root/addon/tick2.log").stdout)
      let inPlace = g.exec("od -An -v -tx1 /run/repro/secrets/canary-web/canary" &
                           " | tr -d ' \\n'").stdout.strip()
      step("C3 was in the secrets directory when the tick was killed",
           inPlace == canaryForms(c3)[3].bytes, inPlace)
      discard g.exec("pkill -9 -f '[a]ddon agent-tick'; sleep 1")
      step("the tick is dead", g.exec("pgrep -f '[a]ddon agent-tick'").exitCode != 0, "")
      g.shutdown()
      var n2 = needles
      for f in canaryForms(c3): n2.add(("c3-" & f.form, f.bytes))
      let hits2 = g.scanDiskImage(n2)
      record["scan2"] = hitsJson(hits2)
      step("no plaintext secret on disk after the kill", hits2.totalHits == 0,
           $hits2)
      # 7. Swap: a large secret no unit reads (its pages are the coldest
      # there are), then memory pressure on a guest with a swap file. A
      # ramfs page is never swapped; a tmpfs page would be.
      g.boot()
      discard g.waitReasserted()
      # The canaries reach the guest through a ramfs of the test's own, so
      # that no command line, environment or file on disk ever holds them:
      # only the add-on's processes do.
      discard g.run("mkdir -p /mnt/a7probe && mount -t ramfs -o mode=0700 " &
                    "a7probe /mnt/a7probe")
      let c4 = randomBytes(32)
      writeFile(g.runDir / "c4.bin", c4)
      g.copyTo(g.runDir / "c4.bin", "/mnt/a7probe/c4")
      const Gen = "python3 -c 'import sys; d=open(\"/mnt/a7probe/%s\",\"rb\")" &
        ".read(); sys.stdout.buffer.write(d * (16 * 32768))'"
      r = g.exec(Gen.replace("%s", "c4") & " | " & repro &
        " system addon secret put --service swap-probe --name big")
      step("swap pass: a 16 MiB secret of a repeated canary is put",
           r.exitCode == 0, r.stdout & r.stderr)
      r = g.applyProfile(repro, "p3", profile(@["canary", "put"]) &
        "\nsecrets.secretFile {\n  service = \"swap-probe\"\n  name = \"big\"\n}\n")
      step("swap pass: a profile declaring it applies", r.exitCode == 0,
           r.stdout & r.stderr)
      let swapOn = g.exec("fallocate -l 1536M /a7-swapfile && chmod 600 " &
        "/a7-swapfile && mkswap /a7-swapfile >/dev/null && swapon " &
        "/a7-swapfile && swapon --show --noheadings")
      step("swap pass: a swap file is in use", swapOn.exitCode == 0 and
           "a7-swapfile" in swapOn.stdout, swapOn.stdout & swapOn.stderr)
      # The boot units that open envelopes may not swap, and an operator
      # command that holds plaintext runs in a scope that may not: one is
      # held, with a 16 MiB secret C5 in its heap, through the pressure.
      var unitSwap: seq[string]
      for u in ["repro-addon-secrets.service", "repro-addon-reassert.service"]:
        unitSwap.add(g.exec("systemctl show -p MemorySwapMax --value " & u).stdout.strip())
      step("swap pass: the boot secrets and re-assert units have MemorySwapMax=0",
           unitSwap == @["0", "0"], $unitSwap)
      let c5 = randomBytes(32)
      writeFile(g.runDir / "c5.bin", c5)
      g.copyTo(g.runDir / "c5.bin", "/mnt/a7probe/c5")
      discard g.run("rm -f " & SeamDir & "/test-paused-at; printf " &
        "'secrets-holding-plaintext\\n' > " & SeamDir & "/test-pause-at")
      writeFile(g.runDir / "held.sh", Gen.replace("%s", "c5") & " | " & repro &
        " system addon secret put --service swap-probe --name held " &
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
      # The put itself (its command line starts with the binary's path), not
      # the shell around the pipe.
      let heldCg = g.exec("for p in $(pgrep -f '^/[^ ]*repro system addon " &
        "secret put --service swap-probe --name held'); do cat " &
        "/sys/fs/cgroup$(cut -d: -f3 /proc/$p/cgroup)/memory.swap.max; done").stdout
      let heldLines = heldCg.strip().splitLines()
      let heldLck = g.exec("for p in $(pgrep -f '^/[^ ]*repro system addon " &
        "secret put --service swap-probe --name held'); do grep VmLck " &
        "/proc/$p/status | tr -dc 0-9; done").stdout.strip()
      step("swap pass: a secret put holds C5 locked in RAM (VmLck >= 16 MiB) " &
           "in a group that may not swap",
           held and heldLines.len == 1 and heldLines[0] == "0" and
           heldLck.len > 0 and parseInt(heldLck) >= 16384,
           "VmLck kB " & heldLck & " / swap.max " &
           heldCg & g.exec("cat /root/addon/held.log; ps -eo pid,cgroup,args | " &
                           "grep '[s]ecret put'").stdout)
      let fill = randomBytes(32)
      let fillHex = canaryForms(fill)[3].bytes
      # Anonymous memory beyond RAM, filled with a known pattern: some of it
      # must land in swap, which the vacuity guard below checks.
      discard g.exec("python3 -c 'import time; b=bytes.fromhex(\"" & fillHex &
        "\")*32768; m=[bytearray(b) for _ in range(2600)]; time.sleep(3)' " &
        ">/dev/null 2>&1; sync", timeoutSec = 900)
      let used = g.exec("swapon --show=NAME,USED --noheadings --bytes").stdout
      record["swapUsed"] = %used
      discard g.exec("pkill -9 -f '[s]ecret put --service swap-probe'; sleep 1")
      g.shutdown()
      var n3 = needles
      for f in canaryForms(c4): n3.add(("c4-" & f.form, f.bytes))
      for f in canaryForms(c5): n3.add(("c5-" & f.form, f.bytes))
      n3.add(("fill", fill))
      let hits3 = g.scanDiskImage(n3)
      record["scan3"] = hitsJson(hits3)
      var fillHits, secretHits = 0
      for h in hits3:
        if h.form == "fill": fillHits = h.hits else: secretHits += h.hits
      step("swap pass vacuity guard: anonymous memory reached the swap file",
           fillHits > 0, $hits3 & " swap: " & used)
      step("no plaintext secret on disk with swap under pressure",
           secretHits == 0, $hits3)
    else:
      step("the killed-mid-materialisation pass needs the seam build", false,
           "REPRO_ADDON_TEST_SEAMS=1")
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

suite "e2e_addon_no_plaintext_secret_on_disk":
  test "no canary, base64 or hex, reaches the disk; also after a kill mid-write":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_no_plaintext_secret_on_disk)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_no_plaintext_secret_on_disk",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_no_plaintext_secret_on_disk", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
