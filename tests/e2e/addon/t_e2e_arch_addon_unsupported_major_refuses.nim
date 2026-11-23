## Gate ``e2e_arch_addon_unsupported_major_refuses`` (milestone AR6; spec
## ReproOS-Add-On-Mode §6.1, §7.9; §13 decision 91).
##
## The pinned window (``arch_window``) crosses a systemd major version:
## 261.3-1 on 2026-09-24, 262-1 on 2026-09-25. On each Arch guest:
##
## 1. the guest is moved back to 2026-09-24, the add-on bootstrapped, and a
##    generation with two fixture services applied;
## 2. a *test matrix* admitting only systemd 261 is put in place, and the
##    same profile still applies (the positive control: the test matrix
##    admits the base before the crossing);
## 3. ``pacman -Syu`` to 2026-09-25 installs systemd 262 and succeeds; the
##    ALPM hook reports that the base is outside the supported matrix now;
## 4. the first apply after the crossing refuses with
##    ``EAddOnUnsupportedBase`` and changes nothing (the ledger, the current
##    generation), while both services stay active in their invocation;
## 5. with the test matrix gone -- the shipped matrix (systemd 258 or later,
##    pacman 7) -- the same profile applies.
##
## *The test matrix* is a test seam (``seams.nim``): the gate runs the
## add-on's seam build (``REPRO_ADDON_TEST_SEAMS=1``), in which
## ``/var/lib/repro/system/addon/test-arch-systemd-max-major`` caps the Arch
## row's systemd major (``preflight.TestArchMatrixSeam``). Without the file
## the seam build's matrix is the product's; the product build has no such
## file, row or code.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=base-matrix-unchecked``):
## every base is accepted, so the apply after the crossing is not refused
## and the gate goes red at exactly that step (and at the hook's report of
## it), with every step before it green.
##
## Bases: ``REPRO_ADDON_BASES`` (the recipe's default is
## ``arch-btrfs-amd64,arch-ext4-amd64``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_arch_addon_unsupported_major_refuses``).
##
## *Mocking.* The test matrix is a seam of the seam build (above); pacman,
## the archive's snapshots (through the test bed's caching mirror) and
## systemd are real.

import std/[json, os, strutils, tables, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support
import ./arch_update_support
import ./arch_window
import ./snapshot_mirror

const
  Gate = "e2e_arch_addon_unsupported_major_refuses"
  BeforeBump = "2026/09/24"
  SeamFile = "/var/lib/repro/system/addon/test-arch-systemd-max-major"
  Refusal = "the first apply after the crossing refuses with EAddOnUnsupportedBase"

proc expectedFalsifier(mut: string; b: BaseImage): Falsifier =
  case mut
  of "base-matrix-unchecked":
    Falsifier(
      required: @[Refusal],
      mayBeRed: @["the ALPM hook reports the base outside the supported matrix",
                  "the refused apply changed nothing"],
      mustRunGreen: @[
        "the guest is moved back to " & BeforeBump & " of the archive",
        "the guest runs systemd " & ArchWindowSystemdBefore,
        "preflight is compatible", "bootstrap",
        "gen1: two fixture services and a file apply",
        "with the test matrix (systemd 261 only) the profile still applies",
        "pacman -Syu to " & ArchWindowSystemdBumpDate & " succeeds and installs systemd " &
          ArchWindowSystemdAfter,
        "both services stay active, not restarted",
        "with the shipped matrix the profile applies"])
  else: raise unknownMutation(Gate, mut)

proc runBase(m: SnapshotMirror; b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    if not testSeams():
      raise newException(TestBedError, Gate & " runs the seam build " &
        "(REPRO_ADDON_TEST_SEAMS=1): the test matrix is a seam")
    g = newArchGuest(b, diskGiB = 16)
    g.boot()
    g.prepareArchGuest()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.moveToDate(m, BeforeBump, step): return fails
    let v0 = g.pacmanVersions(["systemd", "pacman"])
    step("the guest runs systemd " & ArchWindowSystemdBefore,
         v0.getOrDefault("systemd") == ArchWindowSystemdBefore, $v0)
    g.settleBaseline(step)
    if not g.bootstrapArch(repro, step).ok: return fails
    let exe = g.gen0ReproExe()
    let a1 = g.applyProfile(repro, "gen1", servicesProfile(exe))
    step("gen1: two fixture services and a file apply", a1.exitCode == 0,
         a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails
    discard g.run("printf '%s\\n' " & $ArchWindowEarlierSystemdMajor & " > " &
                  SeamFile)
    let a2 = g.applyProfile(repro, "gen1", servicesProfile(exe))
    step("with the test matrix (systemd 261 only) the profile still applies",
         a2.exitCode == 0, a2.stdout & a2.stderr)
    let before = g.servicesState()

    g.pinToDate(m, ArchWindowSystemdBumpDate)
    let r = g.exec("pacman -Syu --noconfirm " & WindowPacmanFlags & " 2>&1",
                     timeoutSec = 3600)
    let v1 = g.pacmanVersions(["systemd", "pacman"])
    let said = r.stdout & r.stderr
    step("pacman -Syu to " & ArchWindowSystemdBumpDate & " succeeds and installs systemd " &
           ArchWindowSystemdAfter,
         r.exitCode == 0 and v1.getOrDefault("systemd") == ArchWindowSystemdAfter,
         $v1 & "\n" & said[max(0, said.len - 3000) .. ^1])
    if r.exitCode != 0: return fails
    step("the ALPM hook reports the base outside the supported matrix",
         "outside the supported matrix" in said and
           g.logLines(AlpmHookLog).join("\n").contains("outside the supported matrix"),
         said[max(0, said.len - 2500) .. ^1] & "\n" &
           g.logLines(AlpmHookLog).join("\n"))
    let ledgerBefore = g.ledgerOf()
    let currentBefore = g.currentGeneration()
    let a3 = g.applyProfile(repro, "gen1", servicesProfile(exe))
    let said3 = a3.stdout & a3.stderr
    step(Refusal, a3.exitCode != 0 and "EAddOnUnsupportedBase" in said3 and
           "systemd 262" in said3,
         "exit " & $a3.exitCode & "\n" & said3)
    step("the refused apply changed nothing",
         g.ledgerOf() == ledgerBefore and g.currentGeneration() == currentBefore,
         "current " & currentBefore & " -> " & g.currentGeneration())
    let svc = servicesUnchanged(before, g.servicesState())
    step("both services stay active, not restarted", svc.ok, svc.detail)
    discard g.run("rm -f " & SeamFile)
    let a4 = g.applyProfile(repro, "gen1", servicesProfile(exe))
    step("with the shipped matrix the profile applies",
         a4.exitCode == 0 and "in the supported matrix" in a4.stdout,
         a4.stdout & a4.stderr)
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
  test "a systemd major outside the (test) matrix refuses the next apply":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      let m = sharedSnapshotMirror(MirrorStamp)
      m.prewarm(archWindowDates())
      var failures: seq[string]
      try:
        for b in selectedArchBases():
          if isOmarchyBase(b):
            failures.add(b.name & ": " & Gate & " runs on the plain Arch guests")
            continue
          let record = archGateRecord(Gate)
          record["base"] = %b.name
          record["window"] = windowPin()
          let f = runBase(m, b, record)
          record["verdict"] = %(if f.len == 0: "green" else: "red")
          let judged = judgeRun(Gate, record, f, expectedFalsifier, b)
          echo "record: ", writeRecord(Gate, record)
          failures.add(judged)
      finally:
        m.stop()
      for f in failures: echo "FAIL ", f
      check failures.len == 0
