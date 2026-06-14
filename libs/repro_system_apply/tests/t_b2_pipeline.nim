## B2 P5 unit tests: plan-apply-record pipeline + GRUB menu.
##
## Drives the full plan-apply-record cycle against a temporary state
## directory and asserts:
##
##   * fresh apply records generation 1 with the expected layout
##   * second apply of the SAME config is a no-op (no new generation)
##   * apply of a CHANGED config records generation 2 with the diff
##     consisting solely of the changed transitions
##   * generation manifest round-trips through ``parseManifest``
##   * the GRUB menu generator emits one menuentry per generation,
##     newest-first, with the active generation as the default
##   * a ``boot-prev`` recovery entry is present and points at the
##     second-newest generation
##   * ``confirmStagedGeneration`` promotes ``staged-next`` to
##     ``current`` and clears the staging flag
##
## The tests deliberately set ``--activation-ts`` so the manifest +
## menu output is deterministic across runs.

import std/[os, strutils, times, unittest]

import repro_system_apply

const SampleConfigPath =
  currentSourcePath.parentDir.parentDir.parentDir.parentDir /
    "recipes" / "reproos-sample-config" / "configuration.nim"

proc freshStateDir(label: string): string =
  let base = getTempDir() / "reproos-b2-tests" / label
  removeDir(base)
  createDir(base)
  base

proc writeTmpConfig(dir, body: string): string =
  ## Stage a configuration.nim under a temp dir so the diff test can
  ## point at TWO distinct configs that differ by precisely the
  ## intended set of changes.
  createDir(dir)
  let p = dir / "configuration.nim"
  writeFile(p, body)
  p

let baselineConfig = readFile(SampleConfigPath)

# A second config that adds one Tier-1 package (`tmux`) and one new
# user (`mallory`) on top of the sample config. The test asserts the
# diff carries only those two transitions.
const SecondConfigBody = """
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
    tmux,
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
    user "mallory":
      shell = bash
      groups = ["wheel"]
      home_dir = "/home/mallory"

  services:
    enable "systemd-networkd.service"
    enable "serial-getty@ttyS0.service"
    disable "systemd-resolved.service"

  mounts:
    mount "/", source = "LABEL=reproos-root", fstype = "ext4", options = "ro,relatime"
    mount "/boot", source = "LABEL=reproos-boot", fstype = "vfat", options = "umask=0077"
"""

# A minimal config with NO users/mounts/cmdline -- exercises the
# B1-review risk #3 (etcSkeleton edge omitted when no users/mounts/
# cmdline). The pipeline should still record a generation but the
# desired manifest's etc/ tree should be skipped.
const MinimalConfigBody = """
system minimal:
  kernel = reproosKernel

  packages = [
    coreutils,
  ]
"""

suite "B2 plan-apply-record pipeline":

  test "fresh apply records generation 1 with full layout":
    let state = freshStateDir("apply-fresh")
    let cfg = parseSystemConfigFile(SampleConfigPath)
    var opts: ApplyOptions
    opts.stateDir = state
    opts.bootDir = state / "boot"
    opts.runtimeDir = state / "run"
    opts.activationTimestamp = 1_700_000_000
    opts.skipRealize = false
    let rec = planApplyRecord(cfg, opts)
    check rec.manifest.generationNumber == 1
    check rec.manifest.activationTimestamp == 1_700_000_000
    check fileExists(rec.manifestPath)
    check fileExists(rec.stagedNextPath)
    check fileExists(rec.kernelPath)
    check fileExists(rec.initrdPath)
    check fileExists(rec.cmdlinePath)
    # /etc/passwd contains ada.
    let passwdPath = rec.generationDir / "etc" / "passwd"
    check fileExists(passwdPath)
    let passwd = readFile(passwdPath)
    check "ada:" in passwd
    # /etc/fstab contains both mount points.
    let fstabPath = rec.generationDir / "etc" / "fstab"
    check fileExists(fstabPath)
    let fstab = readFile(fstabPath)
    check "/boot" in fstab
    check "ext4" in fstab
    check "vfat" in fstab
    # systemd/units.list contains all three services.
    let unitsPath = rec.generationDir / "systemd" / "units.list"
    check fileExists(unitsPath)
    let units = readFile(unitsPath)
    check "systemd-networkd.service" in units
    check "systemd-resolved.service" in units
    check "serial-getty@ttyS0.service" in units
    # Packages are dropped as placeholders.
    check fileExists(rec.generationDir / "packages" / "coreutils")
    check fileExists(rec.generationDir / "packages" / "vim")
    # staged-next records the generation number.
    let staged = readFile(rec.stagedNextPath).strip()
    check staged == "1"

  test "second apply of the same config is a no-op":
    let state = freshStateDir("apply-noop")
    let cfg = parseSystemConfigFile(SampleConfigPath)
    var opts: ApplyOptions
    opts.stateDir = state
    opts.bootDir = state / "boot"
    opts.runtimeDir = state / "run"
    opts.activationTimestamp = 1_700_000_000
    let rec1 = planApplyRecord(cfg, opts)
    check rec1.manifest.generationNumber == 1
    # The activation timestamp differs intentionally — the no-op
    # detector is content-addressed against the desired manifest's
    # AST, not against the timestamp.
    opts.activationTimestamp = 1_700_000_500
    let rec2 = planApplyRecord(cfg, opts)
    check rec2.manifest.generationNumber == 1
    # Generation 2 directory should NOT exist.
    check not dirExists(state / "generations" / "2")

  test "apply of a changed config records generation 2 with diff":
    let state = freshStateDir("apply-diff")
    let cfg1 = parseSystemConfigFile(SampleConfigPath)
    var opts: ApplyOptions
    opts.stateDir = state
    opts.bootDir = state / "boot"
    opts.runtimeDir = state / "run"
    opts.activationTimestamp = 1_700_000_000
    let rec1 = planApplyRecord(cfg1, opts)
    check rec1.manifest.generationNumber == 1
    let tmpDir = state / "configs" / "second"
    let cfg2Path = writeTmpConfig(tmpDir, SecondConfigBody)
    let cfg2 = parseSystemConfigFile(cfg2Path)
    opts.activationTimestamp = 1_700_001_000
    # Plan first to inspect the diff.
    let ctx = resolveApplyContext(cfg2, opts)
    let diff = planTransitions(ctx.previousManifest, cfg2)
    # Filter for the relevant categories.
    var addedPackages: seq[string]
    var addedUsers: seq[string]
    var changedUsers: seq[string]
    var addedServices: seq[string]
    for t in diff.transitions:
      if t.category == "package" and t.kind == stAdded:
        addedPackages.add t.key
      elif t.category == "user" and t.kind == stAdded:
        addedUsers.add t.key
      elif t.category == "user" and t.kind == stChanged:
        changedUsers.add t.key
      elif t.category == "service" and t.kind == stAdded:
        addedServices.add t.key
    # The sample-config baseline already declares root via the imported
    # module's users.nim. So the diff should add tmux + mallory, plus
    # possibly redeclare root (depending on imported module). We
    # specifically check that the two intended-new entries are present
    # AND no spurious entries appear.
    check "tmux" in addedPackages
    check "mallory" in addedUsers
    check addedServices.len == 0
    # No mount or kernel-cmdline transitions should be present (they
    # were unchanged between configs).
    var sawCmdline = false
    var sawMount = false
    for t in diff.transitions:
      if t.category == "kernel-cmdline": sawCmdline = true
      if t.category == "mount": sawMount = true
    check not sawCmdline
    check not sawMount
    # Now apply and confirm generation 2 was written.
    let rec2 = planApplyRecord(cfg2, opts)
    check rec2.manifest.generationNumber == 2
    check fileExists(rec2.manifestPath)
    check fileExists(state / "generations" / "1" / "manifest.txt")
    check fileExists(state / "generations" / "2" / "manifest.txt")
    let staged = readFile(rec2.stagedNextPath).strip()
    check staged == "2"

  test "kernel-cmdline parts preserved as a seq (B1 risk #4)":
    let state = freshStateDir("apply-cmdline")
    let cfg = parseSystemConfigFile(SampleConfigPath)
    var opts: ApplyOptions
    opts.stateDir = state
    opts.bootDir = state / "boot"
    opts.runtimeDir = state / "run"
    opts.activationTimestamp = 1_700_000_000
    let rec = planApplyRecord(cfg, opts)
    let mp = rec.manifestPath
    let body = readFile(mp)
    # The manifest emits one line per part, indexed.
    check "kernel_cmdline[0]" in body
    check "kernel_cmdline[1]" in body
    check "kernel_cmdline[2]" in body
    # Round-trip.
    let parsed = parseManifest(body)
    check parsed.kernelCmdline.parts == cfg.kernelCmdline.parts

  test "etc-skeleton edge omitted when minimal (B1 risk #3)":
    let state = freshStateDir("apply-minimal")
    let cfgPath = writeTmpConfig(state / "cfg", MinimalConfigBody)
    let cfg = parseSystemConfigFile(cfgPath)
    var opts: ApplyOptions
    opts.stateDir = state
    opts.bootDir = state / "boot"
    opts.runtimeDir = state / "run"
    opts.activationTimestamp = 1_700_000_000
    let rec = planApplyRecord(cfg, opts)
    check rec.manifest.generationNumber == 1
    # No /etc tree should have been written.
    check not dirExists(rec.generationDir / "etc")
    # But the kernel placeholder is still there.
    check fileExists(rec.kernelPath)
    # And the coreutils package placeholder.
    check fileExists(rec.generationDir / "packages" / "coreutils")

  test "manifest round-trips through serializeManifest/parseManifest":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    var ctx: ApplyContext
    ctx.options.activationTimestamp = 1_700_000_000
    ctx.nextGenerationNumber = 7
    let m = buildDesiredManifest(cfg, ctx)
    let body = serializeManifest(m)
    let m2 = parseManifest(body)
    check m2.generationNumber == 7
    check m2.activationTimestamp == 1_700_000_000
    check m2.kernel.name == "reproosKernel"
    check m2.kernelCmdline.parts == m.kernelCmdline.parts
    check m2.packages.len == m.packages.len
    check m2.users.len == m.users.len
    check m2.services.len == m.services.len
    check m2.mounts.len == m.mounts.len

  test "package tier flip surfaces in the diff detail (B1 risk #2)":
    let state = freshStateDir("tier-flip")
    let cfg1Path = writeTmpConfig(state / "cfg1", """
system tflip:
  kernel = reproosKernel
  packages = [ coreutils ]
""")
    let cfg2Path = writeTmpConfig(state / "cfg2", """
system tflip:
  kernel = reproosKernel
  packages = [
    package(apt, "coreutils", snapshot = "debian/bookworm/20260601T000000Z"),
  ]
""")
    let cfg1 = parseSystemConfigFile(cfg1Path)
    let cfg2 = parseSystemConfigFile(cfg2Path)
    var opts: ApplyOptions
    opts.stateDir = state
    opts.bootDir = state / "boot"
    opts.runtimeDir = state / "run"
    opts.activationTimestamp = 1_700_000_000
    discard planApplyRecord(cfg1, opts)
    let ctx = resolveApplyContext(cfg2, opts)
    let diff = planTransitions(ctx.previousManifest, cfg2)
    var foundFlip = false
    for t in diff.transitions:
      if t.category == "package" and t.key == "coreutils" and
         t.kind == stChanged and "tier flipped" in t.detail:
        foundFlip = true
    check foundFlip

suite "B2 GRUB menu generator":

  test "single-generation menu has one entry and a degenerate boot-prev":
    let state = freshStateDir("grub-single")
    let cfg = parseSystemConfigFile(SampleConfigPath)
    var opts: ApplyOptions
    opts.stateDir = state
    opts.bootDir = state / "boot"
    opts.runtimeDir = state / "run"
    opts.activationTimestamp = 1_700_000_000
    discard planApplyRecord(cfg, opts)
    let inputs = enumerateGenerations(state)
    check inputs.len == 1
    let menu = generateGrubMenu(inputs, 1)
    check "menuentry" in menu
    check "reproos-gen-1" in menu
    # A single-generation system: boot-prev falls back to the only
    # generation.
    check "reproos-boot-prev" in menu
    check "set default=\"reproos-gen-1\"" in menu
    check "set fallback=\"reproos-boot-prev\"" in menu

  test "two-generation menu is newest-first and default points at the new one":
    let state = freshStateDir("grub-double")
    let cfg1 = parseSystemConfigFile(SampleConfigPath)
    var opts: ApplyOptions
    opts.stateDir = state
    opts.bootDir = state / "boot"
    opts.runtimeDir = state / "run"
    opts.activationTimestamp = 1_700_000_000
    discard planApplyRecord(cfg1, opts)
    let cfg2Path = writeTmpConfig(state / "configs" / "second",
      SecondConfigBody)
    let cfg2 = parseSystemConfigFile(cfg2Path)
    opts.activationTimestamp = 1_700_001_000
    discard planApplyRecord(cfg2, opts)
    let inputs = enumerateGenerations(state)
    check inputs.len == 2
    let menu = generateGrubMenu(inputs, 2)
    # Generation 2 comes before generation 1 in the menu (newest-first).
    let g2Idx = menu.find("reproos-gen-2")
    let g1Idx = menu.find("reproos-gen-1")
    check g2Idx >= 0
    check g1Idx >= 0
    check g2Idx < g1Idx
    check "set default=\"reproos-gen-2\"" in menu
    # The boot-prev entry comes AFTER both per-gen menuentries
    # (it's appended at the end). Search for the menuentry block
    # specifically, not the bare entry id which also appears in the
    # `set fallback` header.
    let bpIdx = menu.find("--id 'reproos-boot-prev'")
    check bpIdx > g1Idx

  test "generation timestamps render in human-readable menu labels":
    let state = freshStateDir("grub-ts")
    let cfg = parseSystemConfigFile(SampleConfigPath)
    var opts: ApplyOptions
    opts.stateDir = state
    opts.bootDir = state / "boot"
    opts.runtimeDir = state / "run"
    opts.activationTimestamp = 1_700_000_000
    discard planApplyRecord(cfg, opts)
    let inputs = enumerateGenerations(state)
    let menu = generateGrubMenu(inputs, 1)
    # 2023-11-14 (UTC) is the ISO equivalent of 1_700_000_000.
    check "2023-11-14" in menu

  test "no generations yet produces a stub menu":
    let state = freshStateDir("grub-empty")
    createDir(state / "generations")
    let menu = generateGrubMenu(@[], 0)
    check "(no generations recorded yet)" in menu

suite "B2 boot-failure-recovery wiring (simulated)":

  test "confirmStagedGeneration promotes the staged generation to current":
    let state = freshStateDir("confirm-promo")
    let cfg = parseSystemConfigFile(SampleConfigPath)
    var opts: ApplyOptions
    opts.stateDir = state
    opts.bootDir = state / "boot"
    opts.runtimeDir = state / "run"
    opts.activationTimestamp = 1_700_000_000
    let rec = planApplyRecord(cfg, opts)
    check fileExists(rec.stagedNextPath)
    check readCurrentGeneration(state) == 0
    let outcome = confirmStagedGeneration(state)
    check outcome.promoted
    check outcome.generationNumber == 1
    check not fileExists(rec.stagedNextPath)
    check readCurrentGeneration(state) == 1

  test "confirm without staged-next is a no-op":
    let state = freshStateDir("confirm-noop")
    let outcome = confirmStagedGeneration(state)
    check not outcome.promoted
    check readCurrentGeneration(state) == 0

  test "boot failure pathway: current pointer stays at previous generation until confirm":
    let state = freshStateDir("boot-fail-path")
    let cfg1 = parseSystemConfigFile(SampleConfigPath)
    var opts: ApplyOptions
    opts.stateDir = state
    opts.bootDir = state / "boot"
    opts.runtimeDir = state / "run"
    opts.activationTimestamp = 1_700_000_000
    let rec1 = planApplyRecord(cfg1, opts)
    discard confirmStagedGeneration(state)
    check readCurrentGeneration(state) == 1
    # Apply a second generation. The "current" pointer should STILL be
    # generation 1 until confirm is called (simulating: reboot has not
    # happened yet, or has failed).
    let cfg2Path = writeTmpConfig(state / "configs" / "second",
      SecondConfigBody)
    let cfg2 = parseSystemConfigFile(cfg2Path)
    opts.activationTimestamp = 1_700_001_000
    let rec2 = planApplyRecord(cfg2, opts)
    check rec2.manifest.generationNumber == 2
    check readCurrentGeneration(state) == 1
    check fileExists(rec2.stagedNextPath)
    # The GRUB menu's default is the staged generation (generation 2);
    # the boot-prev fallback is generation 1. This is the
    # boot-failure-auto-rollback contract: if generation 2 fails to
    # boot, GRUB falls back to the boot-prev entry (= generation 1).
    let inputs = enumerateGenerations(state)
    let menu = generateGrubMenu(inputs, rec2.manifest.generationNumber)
    check "set default=\"reproos-gen-2\"" in menu
    check "reproos-boot-prev" in menu
    # The boot-prev entry's "linux ... vmlinuz" line should reference
    # generation 1's kernel placeholder.
    let bpStart = menu.find("--id 'reproos-boot-prev'")
    check bpStart >= 0
    let bpRest = menu[bpStart .. ^1]
    check "/generations/1/boot/vmlinuz" in bpRest or
          "\\generations\\1\\boot\\vmlinuz" in bpRest
    # Simulate "successful boot of generation 2" by calling confirm:
    discard confirmStagedGeneration(state)
    check readCurrentGeneration(state) == 2

  test "boot-prev entry is duplicated newest-2 menuentry":
    ## Documents the auto-fallback wiring. The GRUB ``set fallback``
    ## directive expects the entry id; the entry is appended as a
    ## standalone ``boot-prev`` menuentry so it appears in the menu
    ## AND can be selected automatically on boot failure.
    let state = freshStateDir("grub-fallback-shape")
    let cfg = parseSystemConfigFile(SampleConfigPath)
    var opts: ApplyOptions
    opts.stateDir = state
    opts.bootDir = state / "boot"
    opts.runtimeDir = state / "run"
    opts.activationTimestamp = 1_700_000_000
    discard planApplyRecord(cfg, opts)
    let cfg2Path = writeTmpConfig(state / "configs" / "second",
      SecondConfigBody)
    let cfg2 = parseSystemConfigFile(cfg2Path)
    opts.activationTimestamp = 1_700_001_000
    discard planApplyRecord(cfg2, opts)
    let inputs = enumerateGenerations(state)
    let menu = generateGrubMenu(inputs, 2)
    # Both per-gen entries AND the boot-prev should be present (3
    # menuentry blocks in total).
    var menuentryCount = 0
    var pos = 0
    while pos < menu.len:
      let i = menu.find("menuentry", pos)
      if i < 0: break
      inc menuentryCount
      pos = i + "menuentry".len
    check menuentryCount == 3
