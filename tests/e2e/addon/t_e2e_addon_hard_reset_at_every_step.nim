## Gate ``e2e_addon_hard_reset_at_every_step`` (milestone A5), with the
## write-time refusal step of the A4 review (finding F7).
##
## Two generations, A and B, that differ in every class a switch acts on:
## a link-form file whose content changes, one only A has and one only B
## has, an exclusive unit whose file changes (stop-start) and that B also
## changes with a drop-in, a unit only A has and one only B has, a sysctl
## key with different values, and -- B only -- a sysusers account, a
## tmpfiles directory and a diversion of a package's conffile. From A, the
## switch to B is stopped at a point by the seam build's pause and the
## guest is hard-reset there with QEMU ``system_reset``, after a settle of
## a few seconds (``hardResetAfterSettle``: the journal has committed the
## switch's renames, the page cache has not written unsynced file data).
## Neither the seam nor the gate syncs. After the guest boots again:
##
## - its base fingerprint equals A's or B's exactly (both recorded after a
##   clean reboot), but for B's account when the host is A: an account
##   sysusers created is never deleted (spec §6.4), so it survives a
##   revert;
## - every service of that generation is active and the other's are not;
## - the re-assert unit reported ``ok``, no pending marker is left, and
##   the generation history is intact (`current`'s envelope names its
##   predecessor).
##
## The forward points are ``step-1`` … ``step-9``, ``mid-write`` (one of
## the drivers' writes on disk) and ``commit-envelope`` (inside the commit:
## the envelope durable, `current` not moved).
##
## The revert points: a generation C that is B with a health check that
## fails is rolled back by its own switch; that revert is reset at
## ``revert:step-3``, ``revert:mid-write`` and ``revert:step-8``. The host
## must end in A -- after B's account, directory and diversion had been
## made -- and the attempt is recorded ``rolled-back``.
##
## An unusable record: the plan of a switch paused at ``step-3`` (it may
## have written, and the ledger does not say what) is truncated before the
## reset; recovery must write nothing, report ``degraded`` and keep the
## marker; restoring the plan and running ``repro system addon recover``
## must then finish the recovery. The same at ``step-5``, after the
## drivers' writes: the marker is kept, ``degraded`` names the plan, and
## nothing is reverted -- ``current``, the static tree and the rolled-back
## records stay as the switch left them (decision 27). The same at ``step-2`` (nothing written
## yet but stops): the replay cannot run, so recovery reverts instead --
## the host is A, the unit reports ``ok``, no marker is left and the
## attempt is recorded ``rolled-back`` (§7.2: a replay that fails reverts
## whenever a revert is possible).
##
## Then the write-time refusal (A4 review F7): a foreign symlink planted on
## one of B's target paths before the first write makes the switch roll
## itself back to A, with A's services active.
##
## Controls (``REPRO_ADDON_MUTATION``, aimed with
## ``REPRO_ADDON_RESET_POINTS``):
##
## - ``reassert-skips-recovery`` (negative control): red;
## - ``nofollow-write-skips-fsync`` (the writer of the marker, the record
##   and the managed files without its fsyncs): red -- the gate sees what
##   a missing fsync loses. Deterministically: before every paused switch
##   the guest's writeback is held back (``holdWriteback``: no flusher,
##   ext4 ``commit=600,noauto_da_alloc``), so what nothing fsynced is not
##   on the disk at the reset, and a file renamed into place unsynced is
##   empty there. Without the mutation the same conditions must leave A
##   or B, which is what makes every point a test of the switch's own
##   fsyncs rather than of the kernel's timing;
## - ``current-remove-then-create`` at ``commit-current-removed``: red --
##   a commit that is not one rename loses `current`, and the recovered
##   history no longer names A.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``; QEMU only (a reset needs a disk);
## runs the seam build (``scripts/run_addon_gate.sh`` sets
## ``REPRO_ADDON_TEST_SEAMS=1`` for this gate).
##
## *Mocking.* None: real images, real resets, the real switch. The pause
## points exist only in the seam build, whose digest differs from the
## published artefact's.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  BootVariance* = ["mounts:/tmp", "mounts:/dev", "mounts:/run"]
    ## Differences between two boots of the same base that no switch makes:
    ## the base's tmpfs ``/tmp`` reports ``size=`` in its options at some
    ## boots and not at others (measured on Debian 13 across a QEMU
    ## ``system_reset``: the kernel prints ``size=`` only when the size
    ## differs from its default, half of RAM), and devtmpfs ``/dev`` is
    ## sized from the memory free at boot (``size=998208k`` against
    ## ``998204k``, measured the same way), and so is ``/run``'s tmpfs
    ## (``size=201484k`` against ``201488k`` on Ubuntu 24.04, measured
    ## across a revert in this gate). The add-on manages none of them.
  BAccount = "reprofixb"
  KeptAccount* = ["accounts:user:" & BAccount, "accounts:group:" & BAccount,
                  "etc:/etc/passwd", "etc:/etc/passwd-", "etc:/etc/group",
                  "etc:/etc/group-", "etc:/etc/shadow", "etc:/etc/shadow-",
                  "etc:/etc/gshadow", "etc:/etc/gshadow-"]
    ## B's account, kept after a revert to A (spec §6.4): its records, and
    ## the account databases (and their ``-`` backups) that hold it. Every
    ## other account is still compared, through the ``accounts`` records.
  Points* = ["step-1", "step-2", "step-3", "mid-write", "step-4", "step-5",
             "step-6", "step-7", "step-8", "commit-envelope", "step-9"]
  RevertPoints* = ["revert:step-3", "revert:mid-write", "revert:step-8"]
  MutationOnlyPoints* = ["commit-current-removed"]
  Diverted = "/etc/repro-fixture/fixture.conf"
  StateCurrent = "/var/lib/repro/system/current"

proc selectedPoints(all: openArray[string]): seq[string] =
  ## ``REPRO_ADDON_RESET_POINTS`` (comma-separated) narrows the points, for
  ## a control aimed at one step; default: all of them.
  let env = getEnv("REPRO_ADDON_RESET_POINTS")
  if env.len == 0: return @all
  for p in env.split(','):
    if p.strip() in all or p.strip() in MutationOnlyPoints:
      result.add(p.strip())

proc unitText(gen, desc: string): string =
  "[Unit]\nDescription=" & desc & "\n[Service]\nEnvironment=GEN=" & gen &
    "\nExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target\n"

proc unit(name, content: string; extra = ""): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"" & content &
    "\"\n" & extra & "}\n\n"

proc file(path, content: string; extra = ""): string =
  "fs.systemFile {\n  path = \"" & path & "\"\n  content = \"" & content &
    "\"\n" & extra & "}\n\n"

proc sysctl(value: string): string =
  "linux.sysctl {\n  key = \"net.core.somaxconn\"\n  value = \"" & value &
    "\"\n}\n\n"

proc prefixes(timeout = 0): string =
  "addOn {\n  managedEtcPrefixes = [\"/etc/repro-fixture/\"]\n" &
    (if timeout > 0: "  confirmTimeout = " & $timeout & "\n" else: "") & "}\n\n"

proc profileA(): string =
  prefixes() &
    file("/etc/repro-fixture/common.conf", "generation A\n") &
    file("/etc/repro-fixture/only-a.conf", "only in A\n") &
    unit("repro-fixture-common.service", unitText("A", "common fixture"),
         "  exclusive = true\n") &
    unit("repro-fixture-a.service", unitText("A", "fixture of A")) &
    sysctl("1024")

proc profileB(check = ""; timeout = 0): string =
  prefixes(timeout) &
    file("/etc/repro-fixture/common.conf", "generation B\n") &
    file("/etc/repro-fixture/only-b.conf", "only in B\n") &
    file(Diverted, "ours\n", "  collision = \"divert\"\n") &
    unit("repro-fixture-common.service", unitText("B", "common fixture"),
         "  exclusive = true\n") &
    "systemd.systemDropIn {\n  unit = \"repro-fixture-common.service\"\n" &
      "  name = \"fixture\"\n  content = \"[Service]\nEnvironment=DROPIN=b\n\"\n}\n\n" &
    unit("repro-fixture-b.service", unitText("B", "fixture of B"),
         (if check.len > 0: "  healthCheck = \"" & check & "\"\n" else: "")) &
    sysctl("2048") &
    "linux.sysusersEntry {\n  name = \"" & BAccount & "\"\n  description = \"A5 fixture\"\n}\n\n" &
    "linux.tmpfilesRule {\n  name = \"repro-fixture-b.conf\"\n  content = \"d /var/lib/repro-fixture-b 0750 root root -\n\"\n}\n\n"

proc activeState(g: Guest; u: string): string =
  g.exec("systemctl is-active " & u).stdout.strip()

proc servicesOf(g: Guest; gen: string): tuple[ok: bool; detail: string] =
  ## Every service of ``gen`` active, the other generation's own one not,
  ## and the generation's configuration in effect.
  let common = activeState(g, "repro-fixture-common.service")
  let a = activeState(g, "repro-fixture-a.service")
  let b = activeState(g, "repro-fixture-b.service")
  let env = g.exec("systemctl show -p Environment --value " &
                   "repro-fixture-common.service").stdout.strip()
  let somax = g.exec("cat /proc/sys/net/core/somaxconn").stdout.strip()
  let detail = "common=" & common & " (" & env & ") a=" & a & " b=" & b &
    " somaxconn=" & somax
  if gen == "A":
    (common == "active" and a == "active" and b != "active" and
     env == "GEN=A" and somax == "1024", detail)
  else:
    (common == "active" and b == "active" and a != "active" and
     "GEN=B" in env and "DROPIN=b" in env and somax == "2048", detail)

proc rebootAndSettle(g: Guest): string =
  discard g.exec("systemctl reboot", timeoutSec = 30)
  discard g.waitPoweredOff(300)
  g.boot()
  result = g.waitReasserted()
  discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                 timeoutSec = 600)

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
    # The package whose conffile B diverts: part of the base.
    g.installEquivs()
    let deb = g.buildEquivsPackage("repro-fixture-conf", "1.0",
      @[(name: "fixture.conf", content: "the package's\n",
         destDir: "/etc/repro-fixture")])
    discard g.run("export DEBIAN_FRONTEND=noninteractive; dpkg -i " & deb &
                  " >/dev/null < /dev/null")
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    # --- The two references, each after a clean reboot.
    var r = g.applyProfile(repro, "a", profileA())
    step("generation A applied", r.exitCode == 0, r.stdout & r.stderr)
    discard rebootAndSettle(g)
    let fpA = g.takeFingerprint(repro)
    let sa = servicesOf(g, "A")
    step("reference A: services", sa.ok, sa.detail)
    r = g.applyProfile(repro, "b", profileB())
    step("generation B applied", r.exitCode == 0, r.stdout & r.stderr)
    discard rebootAndSettle(g)
    let fpB = g.takeFingerprint(repro)
    let sb = servicesOf(g, "B")
    step("reference B: services", sb.ok, sb.detail)
    step("vacuity guard: A and B fingerprints differ",
         not identityReport(fpA, fpB, BootVariance).ok, "")
    step("vacuity guard: B diverted the package's conffile and made its account",
         g.exec("dpkg-divert --list " & Diverted).stdout.contains(Diverted) and
         g.exec("getent passwd " & BAccount).exitCode == 0 and
         g.exec("test -d /var/lib/repro-fixture-b").exitCode == 0, "")
    r = g.applyProfile(repro, "a", profileA())
    step("back to A", r.exitCode == 0, r.stdout & r.stderr & (if r.exitCode == 0: ""
      else: "\n--- units:\n" & g.exec("ls -la /etc/systemd/system/ " &
        "/etc/systemd/system/repro-fixture-common.service.d 2>&1; " &
        "journalctl -o short-precise --no-pager -n 120 2>&1 | grep -i " &
        "'fixture\\|repro' | tail -60").stdout))
    var inB = false
    let outcomes = newJObject()
    let aExceptions = @BootVariance & @KeptAccount

    proc judge(label: string; journal, marker: string): string =
      ## After a reset and boot: which generation the host is in, with
      ## every check of the module header recorded.
      discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                     timeoutSec = 600)
      let fp = g.takeFingerprint(repro)
      let isA = identityReport(fpA, fp, aExceptions)
      let isB = identityReport(fpB, fp, BootVariance)
      result = if isA.ok: "A" elif isB.ok: "B" else: "neither"
      step(label & ": after the reset the host is exactly A or B (" &
           result & ")", isA.ok or isB.ok,
           "vs A:\n" & isA.text & "\nvs B:\n" & isB.text &
           "\nmarker at reset:\n" & marker & "\nreassert:\n" & journal)
      if result != "neither":
        let sv = servicesOf(g, result)
        step(label & ": every service of " & result & " is active", sv.ok,
             sv.detail)
      step(label & ": the re-assert unit reported ok",
           "repro-addon reassert: ok" in journal, journal)
      step(label & ": no pending marker is left",
           g.exec("test ! -e " & SeamDir & "/pending").exitCode == 0, "")
      let status = g.exec(repro & " system addon status").stdout
      var prev = ""
      for line in status.splitLines():
        if line.startsWith("previous generation:"):
          prev = line["previous generation:".len .. ^1].strip()
      step(label & ": the history is intact (current names its predecessor)",
           prev.len > 0, status)

    proc toA(label: string) =
      if inB:
        let back = g.applyProfile(repro, "a", profileA())
        step(label & ": back to A first", back.exitCode == 0,
             back.stdout & back.stderr)
        inB = false

    # --- Forward resets.
    for point in selectedPoints(Points):
      if point.startsWith("revert:"): continue
      toA(point)
      g.holdWriteback()
      let paused = g.startSwitchPausedAt(repro, "b", profileB(), point)
      step(point & ": the switch to B paused there", paused.exitCode == 0,
           paused.stdout & paused.stderr)
      if paused.exitCode != 0: continue
      let marker = g.exec("cat " & SeamDir & "/pending 2>/dev/null").stdout
      g.hardResetAfterSettle()
      g.boot()
      let gen = judge(point, g.waitReasserted(), marker)
      outcomes[point] = %gen
      inB = gen == "B"

    # --- Resets during the revert of a failed switch: must end in A.
    let failing = profileB(check = "tcp:127.0.0.1:1", timeout = 5)
    for point in selectedPoints(RevertPoints):
      if not point.startsWith("revert:"): continue
      toA(point)
      let before = g.rolledBackRecords()
      g.holdWriteback()
      let paused = g.startSwitchPausedAt(repro, "c", failing, point)
      step(point & ": the revert of the failed switch paused there",
           paused.exitCode == 0, paused.stdout & paused.stderr)
      if paused.exitCode != 0: continue
      let marker = g.exec("cat " & SeamDir & "/pending 2>/dev/null").stdout
      g.hardResetAfterSettle()
      g.boot()
      let gen = judge(point, g.waitReasserted(), marker)
      outcomes[point] = %gen
      step(point & ": the recovery finished the revert (the host is A)",
           gen == "A", gen)
      step(point & ": the failed attempt is recorded rolled-back",
           g.rolledBackRecords() > before, $before & " -> " & $g.rolledBackRecords())
      inB = gen == "B"
    record["outcomes"] = outcomes

    if getEnv("REPRO_ADDON_RESET_POINTS").len == 0:
      # --- An unusable record: recovery writes nothing and reports degraded.
      toA("unusable-record")
      let paused = g.startSwitchPausedAt(repro, "b", profileB(), "step-3")
      step("unusable-record: the switch paused at step-3", paused.exitCode == 0,
           paused.stdout & paused.stderr)
      if paused.exitCode == 0:
        # Deliberately synced: this scenario is about the record, not about
        # durability, and the truncation must survive the reset.
        discard g.run("cp " & SeamDir & "/pending.d/plan /root/plan.bak && " &
                      ": > " & SeamDir & "/pending.d/plan && sync")
        g.hardReset()
        g.boot()
        let j = g.waitReasserted()
        step("unusable-record: the re-assert unit reported degraded naming the plan",
             "repro-addon reassert: degraded" in j and "plan" in j, j)
        step("unusable-record: the marker is kept",
             g.exec("test -e " & SeamDir & "/pending").exitCode == 0, "")
        discard g.run("cp /root/plan.bak " & SeamDir & "/pending.d/plan")
        let rec = g.exec(repro & " system addon recover", timeoutSec = 1200)
        step("unusable-record: with the record restored, recover finishes it",
             rec.exitCode == 0 and "reassert: ok" in rec.stdout,
             rec.stdout & rec.stderr)
        let gen = judge("unusable-record", rec.stdout, "")
        inB = gen == "B"

      # --- A record that cannot be used after the drivers' writes (step-5):
      # no revert can tell the switch's writes apart, so recovery keeps the
      # marker, reports degraded and writes nothing -- in particular it
      # starts no partial revert (decision 27). Twice: the plan file
      # unusable (truncated), and the plan readable but the switch
      # unplannable from it (the ledger it began from corrupted).
      proc keptAfterWrites(label, damage, repair, names: string) =
        toA(label)
        let beforeW = g.rolledBackRecords()
        let curW = g.exec("readlink " & StateCurrent).stdout.strip()
        let p5 = g.startSwitchPausedAt(repro, "b", profileB(), "step-5")
        step(label & ": the switch paused at step-5", p5.exitCode == 0,
             p5.stdout & p5.stderr)
        if p5.exitCode != 0: return
        let newTree = g.exec("sed -n 's/^static\\t//p' " & SeamDir &
                             "/pending").stdout.strip()
        discard g.run(damage & " && sync")
        g.hardReset()
        g.boot()
        let j = g.waitReasserted()
        step(label & ": the re-assert unit reported degraded naming " & names,
             "repro-addon reassert: degraded" in j and names in j, j)
        step(label & ": the marker is kept",
             g.exec("test -e " & SeamDir & "/pending").exitCode == 0, "")
        let staticNow = g.exec("readlink /etc/repro/static").stdout.strip()
        let curNow = g.exec("readlink " & StateCurrent).stdout.strip()
        step(label & ": no partial revert (current, the static tree and the " &
             "rolled-back records are as the switch left them)",
             curNow == curW and newTree.len > 0 and staticNow == newTree and
             g.rolledBackRecords() == beforeW,
             "current " & curW & " -> " & curNow & "; static " & staticNow &
             " (switch's tree " & newTree & "); rolled-back " & $beforeW &
             " -> " & $g.rolledBackRecords())
        discard g.run(repair)
        let rec = g.exec(repro & " system addon recover", timeoutSec = 1200)
        step(label & ": with the record repaired, recover finishes it",
             rec.exitCode == 0 and "reassert: ok" in rec.stdout,
             rec.stdout & rec.stderr)
        let gen = judge(label, rec.stdout, "")
        inB = gen == "B"

      keptAfterWrites("unusable-record-after-writes",
        "cp " & SeamDir & "/pending.d/plan /root/plan5.bak && : > " & SeamDir &
          "/pending.d/plan",
        "cp /root/plan5.bak " & SeamDir & "/pending.d/plan", "plan")
      keptAfterWrites("unplannable-record-after-writes",
        "cp " & SeamDir & "/pending.d/from-ledger /root/ledger5.bak && " &
          "echo corrupted > " & SeamDir & "/pending.d/from-ledger",
        "cp /root/ledger5.bak " & SeamDir & "/pending.d/from-ledger",
        "write-ahead record")

      # --- A generation without its own profile copies (one applied before
      # they were kept): a recovery that must revert goes back to the
      # profiles the write-ahead record saved instead of keeping the marker.
      toA("no-profile-copies")
      let beforeN = g.rolledBackRecords()
      let curN = g.exec("readlink " & StateCurrent).stdout.strip()
      discard g.run("rm -f " & StateCurrent & "/addon-own.profile " &
                    StateCurrent & "/addon-user.profile; sync")
      let p6 = g.startSwitchPausedAt(repro, "b", profileB(), "step-2")
      step("no-profile-copies: the switch paused at step-2 (A keeps no profile copies)",
           p6.exitCode == 0 and curN.len > 0, p6.stdout & p6.stderr)
      if p6.exitCode == 0:
        discard g.run(": > " & SeamDir & "/pending.d/plan && sync")
        g.hardReset()
        g.boot()
        let j = g.waitReasserted()
        step("no-profile-copies: the recovery reverted from the record's profiles and reported ok",
             "repro-addon reassert: ok" in j and "reverted to" in j and
             "write-ahead record saved" in j, j)
        step("no-profile-copies: no pending marker is left",
             g.exec("test ! -e " & SeamDir & "/pending").exitCode == 0, "")
        let gen = judge("no-profile-copies", j, "")
        step("no-profile-copies: the host is A", gen == "A", gen)
        step("no-profile-copies: the attempt is recorded rolled-back",
             g.rolledBackRecords() > beforeN,
             $beforeN & " -> " & $g.rolledBackRecords())
        inB = gen == "B"

      # --- An unusable record before any write: recovery reverts.
      toA("unusable-record-before-writes")
      let before2 = g.rolledBackRecords()
      let p3 = g.startSwitchPausedAt(repro, "b", profileB(), "step-2")
      step("unusable-record-before-writes: the switch paused at step-2",
           p3.exitCode == 0, p3.stdout & p3.stderr)
      if p3.exitCode == 0:
        discard g.run(": > " & SeamDir & "/pending.d/plan && sync")
        g.hardReset()
        g.boot()
        let j = g.waitReasserted()
        step("unusable-record-before-writes: the recovery reverted and reported ok",
             "repro-addon reassert: ok" in j and "reverted to" in j, j)
        step("unusable-record-before-writes: no pending marker is left",
             g.exec("test ! -e " & SeamDir & "/pending").exitCode == 0, "")
        let gen = judge("unusable-record-before-writes", j, "")
        step("unusable-record-before-writes: the host is A", gen == "A", gen)
        step("unusable-record-before-writes: the attempt is recorded rolled-back",
             g.rolledBackRecords() > before2,
             $before2 & " -> " & $g.rolledBackRecords())
        inB = gen == "B"

      # --- F7: a write refused at write time rolls the switch back.
      toA("refusal")
      let fpA0 = g.takeFingerprint(repro)
      let p2 = g.startSwitchPausedAt(repro, "b", profileB(), "pre-write")
      step("refusal: the switch to B paused before its first write",
           p2.exitCode == 0, p2.stdout & p2.stderr)
      if p2.exitCode == 0:
        discard g.run("ln -s /tmp/planted-by-the-gate /etc/repro-fixture/only-b.conf")
        let res = g.resumeSwitch()
        step("refusal: the apply failed and says it rolled back",
             res.exitCode != 0 and "rolled back" in res.stdout, res.stdout)
        let fp = g.takeFingerprint(repro)
        let same = identityReport(fpA0, fp, ["etc:/etc/repro-fixture/only-b.conf"])
        step("refusal: the host is A again (but for the planted link)",
             same.ok, same.text)
        let sv = servicesOf(g, "A")
        step("refusal: every service of A is active", sv.ok, sv.detail)
        step("refusal: no pending marker is left",
             g.exec("test ! -e " & SeamDir & "/pending").exitCode == 0, "")
        discard g.run("rm -f /etc/repro-fixture/only-b.conf")
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
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

suite "e2e_addon_hard_reset_at_every_step":
  test "a hard reset at any step of the switch leaves exactly the old or the new generation":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_hard_reset_at_every_step)")
    elif useIncus():
      skip("a hard reset is of a disk image; QEMU only")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_hard_reset_at_every_step",
          "base": b.name, "arch": b.debArch, "backend": "qemu",
          "mutation": mutation(), "testSeams": testSeams(),
          "points": getEnv("REPRO_ADDON_RESET_POINTS"),
          "reprobuild": gitHead(), "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_hard_reset_at_every_step", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
