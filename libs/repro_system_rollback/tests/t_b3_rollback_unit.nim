## B3 P1 + P2 unit tests for ``repro_system_rollback``.
##
## Drives the rollback / switch / list / gc / repair primitives against
## temporary state directories. The pipeline+grub regression tests in
## ``libs/repro_system_apply/tests/t_b2_pipeline.nim`` cover the apply
## side; this suite covers what B3 adds on top.

import std/[os, strutils, times, unittest]

import repro_system_apply
import repro_system_rollback

const SampleConfigPath =
  currentSourcePath.parentDir.parentDir.parentDir.parentDir /
    "recipes" / "reproos-sample-config" / "configuration.nim"

proc freshStateDir(label: string): string =
  let base = getTempDir() / "reproos-b3-tests" / label
  removeDir(base)
  createDir(base)
  base

proc writeTmpConfig(dir, body: string): string =
  createDir(dir)
  let p = dir / "configuration.nim"
  writeFile(p, body)
  p

const KernelChangedConfigBody = """
system reproosSampleConfig:
  kernel = reproosKernelHardened

  kernel_cmdline = [
    "console=ttyS0,115200n8",
    "init=/sbin/init",
    "rw",
  ]

  packages = [
    coreutils,
    bash,
    systemd,
    package(apt, "vim", snapshot = "debian/bookworm/20260601T000000Z"),
  ]

  users:
    user "root":
      shell = bash
      password_hash = "$y$j9T$rootpw"
    user "ada":
      shell = bash
      groups = ["wheel", "video", "audio"]
      home_dir = "/home/ada"

  services:
    enable "systemd-networkd.service"
    enable "serial-getty@ttyS0.service"
    disable "systemd-resolved.service"

  mounts:
    mount "/", source = "LABEL=reproos-root", fstype = "ext4", options = "ro,relatime"
    mount "/boot", source = "LABEL=reproos-boot", fstype = "vfat", options = "umask=0077"
"""

const ServiceOnlyConfigBody = """
system reproosSampleConfig:
  kernel = reproosKernel

  kernel_cmdline = [
    "console=ttyS0,115200n8",
    "init=/sbin/init",
    "rw",
  ]

  packages = [
    coreutils,
    bash,
    systemd,
    package(apt, "vim", snapshot = "debian/bookworm/20260601T000000Z"),
  ]

  users:
    user "root":
      shell = bash
      password_hash = "$y$j9T$rootpw"
    user "ada":
      shell = bash
      groups = ["wheel", "video", "audio"]
      home_dir = "/home/ada"

  services:
    enable "systemd-networkd.service"
    enable "serial-getty@ttyS0.service"
    enable "systemd-resolved.service"

  mounts:
    mount "/", source = "LABEL=reproos-root", fstype = "ext4", options = "ro,relatime"
    mount "/boot", source = "LABEL=reproos-boot", fstype = "vfat", options = "umask=0077"
"""

proc applyConfig(state: string; configBody: string; ts: int64): int =
  let cfgPath = if configBody.len == 0: SampleConfigPath
                else: writeTmpConfig(state / "cfg-" & $ts, configBody)
  let cfg = parseSystemConfigFile(cfgPath)
  var opts: ApplyOptions
  opts.stateDir = state
  opts.bootDir = state / "boot"
  opts.runtimeDir = state / "run"
  opts.activationTimestamp = ts
  let rec = planApplyRecord(cfg, opts)
  rec.manifest.generationNumber

suite "B3 P1: listGenerations":

  test "lists every recorded generation with current/staged markers":
    let state = freshStateDir("list-basic")
    let n1 = applyConfig(state, "", 1_700_000_000)
    discard confirmStagedGeneration(state)
    let n2 = applyConfig(state, ServiceOnlyConfigBody, 1_700_001_000)
    check n1 == 1
    check n2 == 2
    let summaries = listGenerations(state)
    check summaries.len == 2
    check summaries[0].number == 1
    check summaries[1].number == 2
    check summaries[0].marker == gmCurrent
    check summaries[1].marker == gmStaged

suite "B3 P1: switchGeneration (live)":

  test "service-only diff is applied live, current pointer flips":
    let state = freshStateDir("switch-live")
    discard applyConfig(state, "", 1_700_000_000)
    discard confirmStagedGeneration(state)
    discard applyConfig(state, ServiceOnlyConfigBody, 1_700_001_000)
    discard confirmStagedGeneration(state)
    # Now switch from 2 back to 1 — only service state differs.
    var so: SwitchOptions
    so.stateDir = state
    so.bootDir = state / "boot"
    so.skipUnitRestart = true
    let outcome = switchGeneration(1, so)
    check outcome.mode == smLive
    check outcome.toGeneration == 1
    check outcome.fromGeneration == 2
    check readCurrentGeneration(state) == 1
    check outcome.unitsToReload.len > 0

suite "B3 P1: switchGeneration (staged-for-reboot)":

  test "kernel change requires reboot; staged-next records target":
    let state = freshStateDir("switch-reboot")
    discard applyConfig(state, "", 1_700_000_000)
    discard confirmStagedGeneration(state)
    discard applyConfig(state, KernelChangedConfigBody, 1_700_001_000)
    discard confirmStagedGeneration(state)
    # Switch back to gen 1 — kernel reverts; reboot required.
    var so: SwitchOptions
    so.stateDir = state
    so.bootDir = state / "boot"
    so.skipUnitRestart = true
    let outcome = switchGeneration(1, so)
    check outcome.mode == smStaged
    check outcome.toGeneration == 1
    check "kernel" in outcome.reasonForReboot
    # Current pointer must NOT have moved yet.
    check readCurrentGeneration(state) == 2
    # Staged-next must reference the target.
    let staged = readFile(stagedNextPathFor(state)).strip()
    check staged == "1"

suite "B3 P1: rollbackGeneration":

  test "default rollback flips to immediately previous generation":
    let state = freshStateDir("rollback-1step")
    discard applyConfig(state, "", 1_700_000_000)
    discard confirmStagedGeneration(state)
    discard applyConfig(state, ServiceOnlyConfigBody, 1_700_001_000)
    discard confirmStagedGeneration(state)
    var ro: RollbackOptions
    ro.stateDir = state
    ro.bootDir = state / "boot"
    ro.skipUnitRestart = true
    let outcome = rollbackGeneration(ro)
    check outcome.switch.toGeneration == 1
    check outcome.switch.fromGeneration == 2

  test "rollback fails when only one generation is recorded":
    let state = freshStateDir("rollback-noprev")
    discard applyConfig(state, "", 1_700_000_000)
    discard confirmStagedGeneration(state)
    var ro: RollbackOptions
    ro.stateDir = state
    ro.bootDir = state / "boot"
    ro.skipUnitRestart = true
    expect ENoGenerationAvailable:
      discard rollbackGeneration(ro)

suite "B3 P1: gcGenerations":

  test "gc --older-than=0 drops every non-current/non-staged generation":
    let state = freshStateDir("gc-zero")
    # 3 generations, each ~1000 s apart.
    discard applyConfig(state, "", 1_700_000_000)
    discard confirmStagedGeneration(state)
    discard applyConfig(state, ServiceOnlyConfigBody, 1_700_001_000)
    discard confirmStagedGeneration(state)
    discard applyConfig(state, KernelChangedConfigBody, 1_700_002_000)
    discard confirmStagedGeneration(state)
    var go: GcOptions
    go.stateDir = state
    go.olderThan = initDuration(seconds = 0)
    let res = gcGenerations(go)
    check res.entries.len == 3
    # Gen 1 + Gen 2 should be eligible (older than now); but Gen 3 is
    # current AND most-recent, so kept. Gen 2 is not current/staged,
    # so dropped. Gen 1 same.
    var dropped: seq[int]
    for e in res.entries:
      if e.dropped: dropped.add e.number
    check 1 in dropped
    check 2 in dropped
    check 3 notin dropped
    check not dirExists(state / "generations" / "1")
    check not dirExists(state / "generations" / "2")
    check dirExists(state / "generations" / "3")

  test "gc keeps the staged-next generation":
    let state = freshStateDir("gc-staged")
    discard applyConfig(state, "", 1_700_000_000)
    discard confirmStagedGeneration(state)
    discard applyConfig(state, ServiceOnlyConfigBody, 1_700_001_000)
    # Generation 2 is now staged-next (no confirm).
    var go: GcOptions
    go.stateDir = state
    go.olderThan = initDuration(seconds = 0)
    let res = gcGenerations(go)
    # Gen 1 = current = kept; Gen 2 = staged + most-recent = kept.
    var kept: seq[int]
    for e in res.entries:
      if not e.dropped: kept.add e.number
    check 1 in kept
    check 2 in kept

suite "B3 P2: risk fixes":

  test "risk #1: concurrent acquireApplyLock blocks the second caller":
    let state = freshStateDir("lock-concurrent")
    var lock1 = acquireApplyLock(state)
    var raised = false
    try:
      var lock2 = acquireApplyLock(state, timeoutSeconds = 1)
      releaseApplyLock(lock2)
    except ESystemApplyBusy:
      raised = true
    releaseApplyLock(lock1)
    check raised

  test "risk #4: repairPartialApply drops half-written directories":
    let state = freshStateDir("repair-partial")
    discard applyConfig(state, "", 1_700_000_000)
    discard confirmStagedGeneration(state)
    # Simulate a crash mid-apply: create generations/2/ with no
    # manifest.txt + a dangling 'boot/' sub-tree.
    let bad = state / "generations" / "2"
    createDir(bad / "boot")
    writeFile(bad / "boot" / "vmlinuz", "fake")
    let res = repairPartialApply(state)
    check res.removedCount >= 1
    check not dirExists(bad)
    var sawPartial = false
    for f in res.findings:
      if f.kind == rrkPartial: sawPartial = true
    check sawPartial

  test "risk #4: applyTransitions is idempotent after repair":
    let state = freshStateDir("repair-recovery")
    discard applyConfig(state, "", 1_700_000_000)
    discard confirmStagedGeneration(state)
    # Crash a future gen 2.
    let bad = state / "generations" / "2"
    createDir(bad)
    # Now re-apply a non-trivial change — pipeline must repair first,
    # then record generation 2 cleanly.
    let g2 = applyConfig(state, ServiceOnlyConfigBody, 1_700_001_000)
    check g2 == 2
    check fileExists(state / "generations" / "2" / "manifest.txt")

  test "risk #5: repair surfaces orphan staged-next":
    let state = freshStateDir("repair-orphan-staged")
    discard applyConfig(state, "", 1_700_000_000)
    # staged-next points at gen 1 (not yet confirmed). Manually delete
    # the gen directory to simulate the orphan.
    removeDir(state / "generations" / "1")
    let res = repairPartialApply(state)
    var sawOrphan = false
    for f in res.findings:
      if f.kind == rrkOrphanStaged: sawOrphan = true
    check sawOrphan
    check not fileExists(stagedNextPathFor(state))

  test "risk #6: single-gen grub menu omits boot-prev":
    let state = freshStateDir("grub-single-gen")
    discard applyConfig(state, "", 1_700_000_000)
    let inputs = enumerateGenerations(state)
    let menu = generateGrubMenu(inputs, 1)
    check "set fallback=" notin menu
    check "reproos-boot-prev" notin menu

  test "risk #7: two-gen grub menu emits set fallback":
    let state = freshStateDir("grub-two-gen")
    discard applyConfig(state, "", 1_700_000_000)
    discard confirmStagedGeneration(state)
    discard applyConfig(state, ServiceOnlyConfigBody, 1_700_001_000)
    let inputs = enumerateGenerations(state)
    let menu = generateGrubMenu(inputs, 2)
    check "set fallback=\"reproos-boot-prev\"" in menu

suite "B3 P1: bootFailureAutoRollback":

  test "clears staged-next and flips GRUB default back to current":
    let state = freshStateDir("auto-rollback")
    discard applyConfig(state, "", 1_700_000_000)
    discard confirmStagedGeneration(state)
    discard applyConfig(state, ServiceOnlyConfigBody, 1_700_001_000)
    check readCurrentGeneration(state) == 1
    check readFile(stagedNextPathFor(state)).strip == "2"
    var ao: AutoRollbackOptions
    ao.stateDir = state
    ao.bootDir = state / "boot"
    ao.deadlineSeconds = 60
    let outcome = bootFailureAutoRollback(ao)
    check outcome.triggered
    check outcome.fromGeneration == 2
    check outcome.toGeneration == 1
    check not fileExists(stagedNextPathFor(state))
    # GRUB menu's default flipped back to gen 1.
    let grub = readFile(state / "boot" / "grub" / "grub.cfg")
    check "set default=\"reproos-gen-1\"" in grub
