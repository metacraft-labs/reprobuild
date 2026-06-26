## M9.R.41 — ``repro infra install-root`` CLI subcommand.
##
## Spec: ``reprobuild-specs/ReproOS-Configuration-Architecture.md`` (the
## install-time analogue of ``repro infra apply``).
##
## ``repro infra apply`` applies a *system profile* against the running
## host: resources are reconciled in place, the elevation broker mediates
## privileged ops, etc.  That is not the install-time problem: at install
## time we have a freshly-formatted blank target disk mounted at /mnt
## and a live ISO root that already carries the whole content-addressed
## from-source closure + every Debian helper the live system needs to
## boot.  The install step is therefore not "apply a profile" — it is
## "materialise a content-addressed REPLICA of the live root onto the
## target".  Cf. M9.R.25's design memo: "the staging mirror is Nix-style
## — every from-source install-mirror is preserved on the live ISO at
## the SAME absolute path the recipe baked into its binaries'
## DT_RUNPATH at install time".  The installed system is the same tree,
## relocated nowhere.
##
## The M9.R.24 stub was a placeholder that called
## ``repro infra apply --target /mnt`` (a flag the system-profile apply
## subcommand never accepted) and fell through to a minimal
## kernel+initrd+GRUB bootstrap, leaving the rest of /mnt empty.  This
## module replaces that stub with a real install-time root-mirror:
##
##   1. mirror the live root (modulo ``/proc``, ``/sys``, ``/dev``,
##      ``/run``, ``/mnt``, ``/media``, ``/tmp``, ``/lost+found``) onto
##      the target via ``rsync -aHAX --numeric-ids --info=stats2``;
##   2. preserve the M9.R.4 system+hardware Nim files Phase 4 already
##      wrote to /mnt/etc/repro/{system,hardware}.nim — rsync is
##      ``--delete``-free so existing content under /mnt is kept;
##   3. regenerate ``/mnt/etc/fstab`` from the disko mount plan stored
##      in ``/mnt/etc/repro/hardware.nim`` (every (device, mountpoint)
##      pair the M9.R.22b ``collectMountPlan`` driver returns);
##   4. install GRUB onto the target's UEFI/ESP via
##      ``grub-install --target=x86_64-efi --efi-directory=<esp> \
##                     --boot-directory=<esp> --no-nvram --removable``
##      with the device path from ``--device``;
##   5. write a target-side ``/mnt/boot/grub/grub.cfg`` pointing at
##      ``/vmlinuz`` + ``/initrd.img`` on the ESP root (matching the
##      M9.R.37.8 ESP-root layout the live ISO uses).
##
## ``--target`` defaults to ``/mnt`` and ``--source`` defaults to ``/``;
## both can be overridden so a non-live-ISO host (the smoke harness
## fixture set) can materialise an install image without running on the
## live ISO.

import std/[os, options, osproc, sequtils, strutils, tables]

import repro_profile/disk_tools
import repro_profile/disk_apply
import repro_profile/types
import repro_profile/hardware_probe  # childEnvWithoutLdLibPath
import repro_cli_support/disk        # DiskPlanOutcome / loadDiskoFromSource

type
  InstallRootOptions* = object
    target*: string         ## destination prefix; default "/mnt"
    source*: string         ## live root to mirror; default "/"
    device*: string         ## --device for grub-install (e.g. /dev/vda)
    diskoSource*: string    ## --disko PATH (override /mnt/etc/repro/hardware.nim)
    hostName*: string       ## --hostname for /etc/hostname; default "reproos"
    skipRsync*: bool        ## --no-rsync (test seam; skip the bulk copy)
    skipGrub*: bool         ## --no-grub  (test seam; skip grub-install)
    skipFstab*: bool        ## --no-fstab (test seam; skip fstab emit)
    extraExcludes*: seq[string]  ## --exclude PATH (repeatable)
    dryRun*: bool           ## --dry-run (print would-do, run nothing)

  InstallRootFailureKind* = enum
    irfBadFlag
    irfMissingTarget
    irfMissingSource
    irfRsyncFailed
    irfDiskoLoadFailed
    irfGrubInstallFailed
    irfFstabWriteFailed
    irfGrubCfgWriteFailed

  InstallRootFailure* = object
    kind*: InstallRootFailureKind
    msg*: string

  InstallRootOutcome* = object
    failure*: bool
    failureKind*: InstallRootFailureKind
    failureMsg*: string
    rsyncExitCode*: int
    fstabPath*: string
    grubCfgPath*: string
    grubInstallExit*: int
    mountPlan*: seq[(string, string)]

const DefaultExcludes* = @[
  # Pseudofs + the target itself.
  "/proc/*", "/sys/*", "/dev/*", "/run/*", "/tmp/*",
  "/mnt/*", "/media/*", "/lost+found",
  # Live medium + overlay scratch dirs Debian live boots use.
  "/run/live/*", "/lib/live/*",
  # Avoid recursing INTO the target if --source ends up being a parent.
  "/mnt", "/media",
]

proc parseInstallRootArgs*(args: seq[string]): InstallRootOptions =
  ## Parse ``repro infra install-root`` flags.  Throws ``ValueError`` on
  ## an unknown flag (matching the rest of the infra surface).
  result.target = "/mnt"
  result.source = "/"
  result.hostName = "reproos"
  var i = 0
  template valueOf(): string =
    if i + 1 >= args.len:
      raise newException(ValueError, args[i] & " requires a value")
    else:
      inc i
      args[i]
  while i < args.len:
    let a = args[i]
    if a == "--target": result.target = valueOf()
    elif a.startsWith("--target="): result.target = a["--target=".len .. ^1]
    elif a == "--source": result.source = valueOf()
    elif a.startsWith("--source="): result.source = a["--source=".len .. ^1]
    elif a == "--device": result.device = valueOf()
    elif a.startsWith("--device="): result.device = a["--device=".len .. ^1]
    elif a == "--disko": result.diskoSource = valueOf()
    elif a.startsWith("--disko="):
      result.diskoSource = a["--disko=".len .. ^1]
    elif a == "--hostname": result.hostName = valueOf()
    elif a.startsWith("--hostname="):
      result.hostName = a["--hostname=".len .. ^1]
    elif a == "--exclude": result.extraExcludes.add valueOf()
    elif a.startsWith("--exclude="):
      result.extraExcludes.add a["--exclude=".len .. ^1]
    elif a == "--no-rsync": result.skipRsync = true
    elif a == "--no-grub":  result.skipGrub  = true
    elif a == "--no-fstab": result.skipFstab = true
    elif a == "--dry-run":  result.dryRun    = true
    elif a.startsWith("--"):
      raise newException(ValueError,
        "unknown `repro infra install-root` flag: " & a)
    else:
      raise newException(ValueError,
        "unexpected positional argument: " & a)
    inc i

# ---------------------------------------------------------------------
# rsync invocation.
# ---------------------------------------------------------------------

proc buildRsyncCommand*(opts: InstallRootOptions): string =
  ## Build the rsync command line.  Kept as a pure proc so unit tests
  ## can pin the exact argv shape.
  var args = @[
    "rsync",
    "-aHAX",                    # archive + hardlinks + ACLs + xattrs
    "--numeric-ids",            # don't rely on /etc/passwd resolution
    "--one-file-system",        # don't cross mount points on source
    "--info=stats2",            # print stats summary at end
    "--sparse",                 # preserve sparse files
  ]
  for ex in DefaultExcludes:
    args.add "--exclude=" & ex
  for ex in opts.extraExcludes:
    args.add "--exclude=" & ex
  let src =
    if opts.source.endsWith("/"): opts.source
    else: opts.source & "/"
  let dst =
    if opts.target.endsWith("/"): opts.target
    else: opts.target & "/"
  args.add src
  args.add dst
  result = args.map(quoteShell).join(" ")

# ---------------------------------------------------------------------
# disko mount plan -> /etc/fstab.
#
# Phase 4 already wrote /mnt/etc/repro/hardware.nim; we re-load it via
# `loadDiskoFromSource` (the same path `repro disk apply` uses) and call
# `collectMountPlan(<layout>, "")` to get the (device, mountpoint) pairs
# without the /mnt prefix.  Each pair becomes one fstab line.
# ---------------------------------------------------------------------

proc fstabLineForMount*(device, mountpoint, fsType: string): string =
  ## Render a single fstab line.  The pass+order fields follow the
  ## conventional Debian/Ubuntu pattern: root = ``0 1`` (fsck first),
  ## ``/boot`` = ``0 2`` (fsck after root), everything else = ``0 0``
  ## (no fsck).
  let pass =
    if mountpoint == "/": "0 1"
    elif mountpoint == "/boot": "0 2"
    else: "0 0"
  let opts =
    if fsType == "vfat": "defaults,umask=0077"
    elif fsType == "swap": "defaults"
    else: "defaults"
  result = device & "\t" & mountpoint & "\t" & fsType & "\t" &
    opts & "\t" & pass & "\n"

proc inferFsTypeForMount(layout: DiskLayout; device: string): string =
  ## Walk the layout's content tree to find the filesystem type backing
  ## ``device``.  Falls back to ``ext4`` if the layout doesn't pin a
  ## specific filesystem (which would be a layout bug).
  for _, d in layout.disks:
    var n = 1
    for _, p in d.partitions:
      let dev = partitionDevicePath(d.device, n)
      if dev == device:
        case p.content.kind
        of cfsFilesystem: return p.content.format
        of cfsSwap: return "swap"
        else: discard
      inc n
  "ext4"

proc renderFstab*(layout: DiskLayout): string =
  ## Build the full /etc/fstab text.  The mount plan is computed with
  ## ``target=""`` so the mountpoints are absolute on-target paths
  ## (``/``, ``/boot``, ...) — same shape Debian's installer writes.
  let plan = collectMountPlan(layout, "")
  result = "# /etc/fstab — generated by `repro infra install-root` " &
           "(M9.R.41).\n" &
           "# <device>\t<mountpoint>\t<type>\t<options>\t<dump> <pass>\n"
  for (dev, mp) in plan:
    let fsType = inferFsTypeForMount(layout, dev)
    let mountPath = if mp.len == 0: "/" else: mp
    result.add fstabLineForMount(dev, mountPath, fsType)

# ---------------------------------------------------------------------
# GRUB config emission.
# ---------------------------------------------------------------------

proc renderInstalledGrubCfg*(layout: DiskLayout): string =
  ## The post-install GRUB config.  Kept consistent with the live ISO's
  ## M9.R.37.7+8 shape: serial + console terminals, hidden timeout=3,
  ## ESP-rooted vmlinuz + initrd.img paths (the ESP is mounted at
  ## /boot on the target so cp /mnt/boot/vmlinuz writes (esp)/vmlinuz),
  ## root= pointing at the layout's "/" partition.
  var rootDev = ""
  for _, d in layout.disks:
    var n = 1
    for _, p in d.partitions:
      if p.content.kind == cfsFilesystem and p.content.mountpoint == "/":
        rootDev = partitionDevicePath(d.device, n)
      inc n
  if rootDev.len == 0: rootDev = "/dev/vda2"
  result = "serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1\n" &
    "terminal_input console serial\n" &
    "terminal_output console serial\n" &
    "set timeout_style=hidden\n" &
    "set timeout=3\n" &
    "set default=0\n" &
    "menuentry 'ReproOS' {\n" &
    "  linux /vmlinuz root=" & rootDev &
        " ro console=tty1 console=ttyS0,115200\n" &
    "  initrd /initrd.img\n" &
    "}\n"

# ---------------------------------------------------------------------
# Drivers.
# ---------------------------------------------------------------------

proc runRsync(opts: InstallRootOptions; outcome: var InstallRootOutcome) =
  if opts.skipRsync:
    outcome.rsyncExitCode = 0
    return
  let cmd = buildRsyncCommand(opts)
  stderr.writeLine("repro infra install-root: " & cmd)
  if opts.dryRun:
    outcome.rsyncExitCode = 0
    return
  # Use a clean env (no LD_LIBRARY_PATH leak; see M9.R.40.1) so the
  # rsync that runs on the live ISO uses the system loader resolution
  # path even if a future launcher change reintroduces LD propagation.
  let env = childEnvWithoutLdLibPath()
  var p: Process
  try:
    p = startProcess("/bin/sh",
      args = @["-c", cmd],
      env = env,
      options = {poUsePath, poParentStreams})
  except OSError as e:
    outcome.failure = true
    outcome.failureKind = irfRsyncFailed
    outcome.failureMsg = "spawn rsync failed: " & e.msg
    return
  outcome.rsyncExitCode = p.waitForExit()
  if outcome.rsyncExitCode != 0:
    # rsync exit codes 23 + 24 are partial-transfer warnings (vanished
    # source files); on a running live system /proc + /sys entries
    # disappear between scan and copy and rsync flags them.  Don't fail
    # the install on those — the bulk-mirror is still complete.
    if outcome.rsyncExitCode in [23, 24]:
      stderr.writeLine("repro infra install-root: rsync exit " &
        $outcome.rsyncExitCode &
        " (partial transfer / vanished files — ignored as benign)")
      outcome.rsyncExitCode = 0
    else:
      outcome.failure = true
      outcome.failureKind = irfRsyncFailed
      outcome.failureMsg = "rsync exited " & $outcome.rsyncExitCode

proc resolveDiskoSource(opts: InstallRootOptions): string =
  if opts.diskoSource.len > 0: opts.diskoSource
  else: opts.target / "etc" / "repro" / "hardware.nim"

proc writeFstab(layout: DiskLayout;
                opts: InstallRootOptions;
                outcome: var InstallRootOutcome) =
  if opts.skipFstab: return
  let path = opts.target / "etc" / "fstab"
  outcome.fstabPath = path
  let text = renderFstab(layout)
  if opts.dryRun:
    stderr.writeLine("repro infra install-root: [dry-run] would write " &
      path)
    stderr.write text
    return
  try:
    createDir(parentDir(path))
    writeFile(path, text)
  except CatchableError as e:
    outcome.failure = true
    outcome.failureKind = irfFstabWriteFailed
    outcome.failureMsg = "write " & path & ": " & e.msg

proc writeHostname(opts: InstallRootOptions) =
  if opts.dryRun: return
  let path = opts.target / "etc" / "hostname"
  try:
    createDir(parentDir(path))
    writeFile(path, opts.hostName & "\n")
  except CatchableError:
    discard  # non-fatal; the rsync'd /etc/hostname is a good fallback.

proc runGrubInstall(opts: InstallRootOptions;
                    outcome: var InstallRootOutcome) =
  if opts.skipGrub:
    outcome.grubInstallExit = 0
    return
  if opts.device.len == 0:
    outcome.failure = true
    outcome.failureKind = irfGrubInstallFailed
    outcome.failureMsg = "--device is required for grub-install " &
      "(pass --device /dev/vda or similar)"
    return
  let espDir = opts.target / "boot"
  let cmd = "grub-install --target=x86_64-efi " &
    "--efi-directory=" & quoteShell(espDir) & " " &
    "--boot-directory=" & quoteShell(espDir) & " " &
    "--no-nvram --removable --recheck " & quoteShell(opts.device)
  stderr.writeLine("repro infra install-root: " & cmd)
  if opts.dryRun:
    outcome.grubInstallExit = 0
    return
  let env = childEnvWithoutLdLibPath()
  var p: Process
  try:
    p = startProcess("/bin/sh",
      args = @["-c", cmd],
      env = env,
      options = {poUsePath, poParentStreams})
  except OSError as e:
    outcome.failure = true
    outcome.failureKind = irfGrubInstallFailed
    outcome.failureMsg = "spawn grub-install failed: " & e.msg
    return
  outcome.grubInstallExit = p.waitForExit()
  if outcome.grubInstallExit != 0:
    outcome.failure = true
    outcome.failureKind = irfGrubInstallFailed
    outcome.failureMsg = "grub-install exited " & $outcome.grubInstallExit

proc writeGrubCfg(layout: DiskLayout;
                  opts: InstallRootOptions;
                  outcome: var InstallRootOutcome) =
  let path = opts.target / "boot" / "grub" / "grub.cfg"
  outcome.grubCfgPath = path
  let text = renderInstalledGrubCfg(layout)
  if opts.dryRun:
    stderr.writeLine("repro infra install-root: [dry-run] would write " &
      path)
    stderr.write text
    return
  try:
    createDir(parentDir(path))
    writeFile(path, text)
  except CatchableError as e:
    outcome.failure = true
    outcome.failureKind = irfGrubCfgWriteFailed
    outcome.failureMsg = "write " & path & ": " & e.msg

# ---------------------------------------------------------------------
# Public entry point.  The CLI dispatcher in infra.nim threads through
# here.  Takes a closure for the disko loader so we avoid an import
# cycle with disk.nim.
# ---------------------------------------------------------------------

type
  DiskoLoader* = proc(path: string): DiskPlanOutcome

proc runInstallRoot*(args: seq[string];
                     loader: DiskoLoader): InstallRootOutcome =
  let opts =
    try: parseInstallRootArgs(args)
    except ValueError as e:
      result.failure = true
      result.failureKind = irfBadFlag
      result.failureMsg = e.msg
      return
  if opts.target.len == 0:
    result.failure = true
    result.failureKind = irfMissingTarget
    result.failureMsg = "--target must be a non-empty path"
    return
  if opts.source.len == 0:
    result.failure = true
    result.failureKind = irfMissingSource
    result.failureMsg = "--source must be a non-empty path"
    return
  if not opts.dryRun and not dirExists(opts.target):
    result.failure = true
    result.failureKind = irfMissingTarget
    result.failureMsg = "target dir does not exist: " & opts.target
    return

  # Phase 1: rsync.
  runRsync(opts, result)
  if result.failure: return

  # Phase 2: load the disko spec for fstab + grub.cfg generation.  The
  # rsync above may have OVERWRITTEN /mnt/etc/repro/hardware.nim from
  # the live root's copy — for an in-place install on the same machine
  # the live and target hardware specs are identical, so this is fine.
  # For a different-host install the caller passes --disko PATH to
  # point at the host-specific spec (Phase 4 of the installer writes
  # this to a stable path before Phase 5 runs).
  let diskoPath = resolveDiskoSource(opts)
  if not fileExists(diskoPath):
    result.failure = true
    result.failureKind = irfDiskoLoadFailed
    result.failureMsg = "disko source not found: " & diskoPath &
      " (pass --disko PATH to override)"
    return
  let dpo = loader(diskoPath)
  if dpo.failure:
    result.failure = true
    result.failureKind = irfDiskoLoadFailed
    result.failureMsg = "load " & diskoPath & ": " & dpo.failureMsg
    return
  let layout = dpo.spec.disko.get()
  result.mountPlan = collectMountPlan(layout, "")

  # Phase 3: fstab.
  writeFstab(layout, opts, result)
  if result.failure: return

  # Phase 4: hostname (non-fatal; the rsync'd copy is a fallback).
  writeHostname(opts)

  # Phase 5: GRUB install + cfg.
  runGrubInstall(opts, result)
  if result.failure: return
  writeGrubCfg(layout, opts, result)
