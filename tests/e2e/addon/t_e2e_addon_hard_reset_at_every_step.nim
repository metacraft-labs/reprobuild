## Gate ``e2e_addon_hard_reset_at_every_step`` (milestone A5), with the
## write-time refusal step of the A4 review (finding F7).
##
## Two generations, A and B, that differ in every way a switch acts on: a
## link-form file whose content changes, one only A has and one only B
## has, a unit whose file changes (restarted), a unit only A has (stopped
## and removed) and one only B has (started). From A, the switch to B is
## stopped at each step of spec §7.2 by the seam build's pause point and
## the guest is hard-reset there with QEMU ``system_reset`` (no shutdown,
## no sync). After the guest boots again:
##
## - its base fingerprint equals A's or B's exactly (both recorded after a
##   clean reboot, so boot-time state is part of both references);
## - every service of that generation is active and the other's are not;
## - the re-assert unit reported ``ok`` and no pending marker is left.
##
## The points are ``step-1`` … ``step-9`` (just after the pending marker
## records that step) and ``mid-write`` (inside steps 4-5: one of the
## drivers' writes is on disk, the rest are not).
##
## Then the write-time refusal (A4 review F7): from A, the switch to B is
## paused before its first write, a foreign symlink is planted on one of
## B's target paths, and the switch resumes. The pre-write guard refuses
## that write; the switch must roll itself back -- static tree flipped
## back, stopped units started -- so the host's fingerprint equals A's
## (but for the planted link) with A's services active, and the apply
## reports ``rolled back``.
##
## Negative control: the mutation ``reassert-skips-recovery`` (the re-assert
## unit leaves an interrupted switch as it finds it) must turn the gate red;
## ``REPRO_ADDON_RESET_POINTS=step-5`` aims it at a point where the host is
## half switched.
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
  BootVariance* = ["mounts:/tmp"]
    ## Differences between two boots of the same base that no switch makes:
    ## the base's tmpfs ``/tmp`` reports ``size=`` in its options at some
    ## boots and not at others (measured on Debian 13 across a QEMU
    ## ``system_reset``: the kernel prints ``size=`` only when the size
    ## differs from its default, half of RAM). The add-on never manages
    ## ``/tmp``.
  Points* = ["step-1", "step-2", "step-3", "mid-write", "step-4", "step-5",
             "step-6", "step-7", "step-8", "step-9"]

proc selectedPoints(): seq[string] =
  ## ``REPRO_ADDON_RESET_POINTS`` (comma-separated) narrows the points, for
  ## a negative control aimed at one step; default: all of them.
  let env = getEnv("REPRO_ADDON_RESET_POINTS")
  if env.len == 0: return @Points
  for p in env.split(','):
    if p.strip() in Points: result.add(p.strip())

proc unitText(gen, desc: string): string =
  "[Unit]\nDescription=" & desc & "\n[Service]\nEnvironment=GEN=" & gen &
    "\nExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target\n"

proc unit(name, content: string): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"" & content &
    "\"\n}\n\n"

proc file(path, content: string): string =
  "fs.systemFile {\n  path = \"" & path & "\"\n  content = \"" & content &
    "\"\n}\n\n"

proc profileA(): string =
  "addOn {\n  managedEtcPrefixes = [\"/etc/repro-fixture/\"]\n}\n\n" &
    file("/etc/repro-fixture/common.conf", "generation A\n") &
    file("/etc/repro-fixture/only-a.conf", "only in A\n") &
    unit("repro-fixture-common.service", unitText("A", "common fixture")) &
    unit("repro-fixture-a.service", unitText("A", "fixture of A"))

proc profileB(): string =
  "addOn {\n  managedEtcPrefixes = [\"/etc/repro-fixture/\"]\n}\n\n" &
    file("/etc/repro-fixture/common.conf", "generation B\n") &
    file("/etc/repro-fixture/only-b.conf", "only in B\n") &
    unit("repro-fixture-common.service", unitText("B", "common fixture")) &
    unit("repro-fixture-b.service", unitText("B", "fixture of B"))

proc activeState(g: Guest; u: string): string =
  g.exec("systemctl is-active " & u).stdout.strip()

proc servicesOf(g: Guest; gen: string): tuple[ok: bool; detail: string] =
  ## Every service of ``gen`` active, the other generation's own one not.
  let common = activeState(g, "repro-fixture-common.service")
  let a = activeState(g, "repro-fixture-a.service")
  let b = activeState(g, "repro-fixture-b.service")
  let env = g.exec("systemctl show -p Environment --value " &
                   "repro-fixture-common.service").stdout.strip()
  let detail = "common=" & common & " (" & env & ") a=" & a & " b=" & b
  if gen == "A":
    (common == "active" and a == "active" and b != "active" and
     env == "GEN=A", detail)
  else:
    (common == "active" and b == "active" and a != "active" and
     env == "GEN=B", detail)

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
    r = g.applyProfile(repro, "a", profileA())
    step("back to A", r.exitCode == 0, r.stdout & r.stderr)
    var inB = false
    let outcomes = newJObject()
    record["points"] = %selectedPoints()
    for point in selectedPoints():
      if inB:
        r = g.applyProfile(repro, "a", profileA())
        step(point & ": back to A first", r.exitCode == 0, r.stdout & r.stderr)
      let paused = g.startSwitchPausedAt(repro, "b", profileB(), point)
      step(point & ": the switch to B paused there", paused.exitCode == 0,
           paused.stdout & paused.stderr)
      if paused.exitCode != 0: continue
      let marker = g.exec("cat " & SeamDir & "/pending 2>/dev/null").stdout
      g.hardReset()
      g.boot()
      let journal = g.waitReasserted()
      discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                     timeoutSec = 600)
      let fp = g.takeFingerprint(repro)
      let isA = identityReport(fpA, fp, BootVariance)
      let isB = identityReport(fpB, fp, BootVariance)
      let gen = if isA.ok: "A" elif isB.ok: "B" else: "neither"
      outcomes[point] = %gen
      step(point & ": after the reset the host is exactly A or B (" & gen & ")",
           isA.ok or isB.ok,
           "vs A:\n" & isA.text & "\nvs B:\n" & isB.text & "\nmarker at reset:\n" &
           marker & "\nreassert:\n" & journal)
      if gen != "neither":
        let s = servicesOf(g, gen)
        step(point & ": every service of " & gen & " is active", s.ok, s.detail)
      step(point & ": the re-assert unit reported ok",
           "repro-addon reassert: ok" in journal, journal)
      step(point & ": no pending marker is left",
           g.exec("test ! -e " & SeamDir & "/pending").exitCode == 0, "")
      inB = gen == "B"
    record["outcomes"] = outcomes
    # --- F7: a write refused at write time rolls the switch back.
    if inB:
      r = g.applyProfile(repro, "a", profileA())
      step("refusal: back to A first", r.exitCode == 0, r.stdout & r.stderr)
    let fpA0 = g.takeFingerprint(repro)
    let paused = g.startSwitchPausedAt(repro, "b", profileB(), "pre-write")
    step("refusal: the switch to B paused before its first write",
         paused.exitCode == 0, paused.stdout & paused.stderr)
    if paused.exitCode == 0:
      discard g.run("ln -s /tmp/planted-by-the-gate /etc/repro-fixture/only-b.conf")
      let res = g.resumeSwitch()
      step("refusal: the apply failed and says it rolled back",
           res.exitCode != 0 and "rolled back" in res.stdout, res.stdout)
      let fp = g.takeFingerprint(repro)
      let same = identityReport(fpA0, fp, ["etc:/etc/repro-fixture/only-b.conf"])
      step("refusal: the host is A again (but for the planted link)",
           same.ok, same.text)
      let s = servicesOf(g, "A")
      step("refusal: every service of A is active", s.ok, s.detail)
      step("refusal: no pending marker is left",
           g.exec("test ! -e " & SeamDir & "/pending").exitCode == 0, "")
      step("refusal: the planted link is untouched",
           g.run("readlink /etc/repro-fixture/only-b.conf").strip() ==
             "/tmp/planted-by-the-gate", "")
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
          "reprobuild": gitHead(), "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_hard_reset_at_every_step", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
