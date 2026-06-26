## M9.R.22b.2 — apply driver for the disko DSL.
##
## Spec: ``reprobuild-specs/ReproOS-Disko-Port.md`` §6.2 + §7 +
## ``repro_cli_support/disk.nim:renderPlan`` (the 9-step plan output is
## the apply-driver order).
##
## Walks a ``DiskLayout`` value and executes the operations the
## ``renderPlan`` describes, in the canonical disko order:
##
##   1. Unmount any existing mounts on target devices       (umount -lf)
##   2. Wipe filesystem signatures                           (wipefs -af)
##   3. Create partition tables                              (parted mklabel)
##   4. Create partitions                                    (sgdisk -n)
##   5. Setup encryption                                     (cryptsetup luksFormat + open)
##   6. Create LVM PVs/VGs/LVs                               (pvcreate + vgcreate + lvcreate)
##   7. Create filesystems                                   (mkfs.*)
##   8. Create btrfs subvols                                 (btrfs subvolume create)
##   9. Create ZFS pools + datasets                          (zpool create + zfs create)
##
## All operations go through ``./disk_tools.nim`` so the apply path is
## uniformly dry-run-able (``REPRO_DISK_DRY_RUN=1``) and uniformly
## errors via ``DiskToolError``.
##
## M9.R.42.1: when ``REPRO_DISK_DIAG=<path>`` is set, a kernel-state
## snapshot is appended to ``<path>`` around each sgdisk + partprobe
## call so the udev/devtmpfs/sgdisk race the M9.R.41 close-out
## documented can be characterised end-to-end on the live ISO. The
## snapshot includes ``/proc/partitions``, ``ls /dev/<diskBase>*``,
## ``ls /sys/class/block``, and an ``udevadm settle --timeout=10`` exit
## code.

import std/[algorithm, options, os, osproc, sequtils, strutils, tables, times]

import ./types
import ./disk_tools

type
  DiskApplyResult* = object
    ## Structured outcome of a full apply. ``operations`` is the
    ## ordered list of ExecResults that ran (so the caller can log /
    ## re-render them); ``failure`` flips to true on the first
    ## ``DiskToolError`` and ``failureMsg`` carries the diagnostic.
    operations*: seq[ExecResult]
    failure*: bool
    failureMsg*: string
    failureStep*: string         ## "wipefs" / "parted" / ...
    failureTool*: string         ## tool name from DiskToolError

  ApplyContext = ref object
    ## Mutable thread of state passed top-down through the recursion:
    ## tracks the current device under examination + the LUKS-passphrase
    ## map so an inner encrypted-content node can read it back.
    layout: DiskLayout
    passphrases: Table[string, string]
      ## Per-disk-or-partition LUKS passphrases, keyed by the disk name
      ## + "." + partition name (e.g. "main.luks"). Tests supply
      ## "swordfish" for every key.
    result: DiskApplyResult

# ---------------------------------------------------------------------
# Top-level public entry point.
# ---------------------------------------------------------------------

proc newApplyContext*(layout: DiskLayout;
                     passphrases: Table[string, string]):
                     ApplyContext =
  ApplyContext(layout: layout, passphrases: passphrases)

proc recordOperation(ctx: ApplyContext; ex: ExecResult) =
  ctx.result.operations.add ex

# ---------------------------------------------------------------------
# M9.R.42.1 — kernel-state diagnostic hook around sgdisk + partprobe.
# ---------------------------------------------------------------------

proc diagPath*(): string {.inline.} =
  ## Returns the value of ``REPRO_DISK_DIAG`` or an empty string when
  ## diagnostics are off. The env-var is read on every call so the
  ## installer / test harness can flip it at runtime without restarting.
  getEnv("REPRO_DISK_DIAG")

proc diagAppend(text: string) =
  ## Append ``text`` to the diag file. Best-effort: if writing fails
  ## (e.g. the path is unwritable) we silently swallow — the diag
  ## channel must never crash the apply driver, only inform.
  let p = diagPath()
  if p.len == 0: return
  try:
    let f = open(p, fmAppend)
    defer: f.close()
    f.write(text)
  except CatchableError:
    discard

proc diagCmd(label, cmd: string): string =
  ## Run ``cmd`` via ``execCmdEx``, capture stdout+stderr+exit, and
  ## render a labelled block for the diag file. Never raises.
  result = "  $ " & cmd & "\n"
  try:
    let pair = execCmdEx(cmd)
    result.add "    [exit=" & $pair.exitCode & "]\n"
    if pair.output.len > 0:
      var lineCount = 0
      for ln in pair.output.splitLines():
        if lineCount >= 40:
          result.add "    ... (truncated)\n"
          break
        result.add "    " & ln & "\n"
        inc lineCount
  except CatchableError as e:
    result.add "    [exec-failed: " & e.msg & "]\n"

proc snapshotKernelState*(label, device: string): string =
  ## Render a labelled snapshot of /proc/partitions, /sys/class/block,
  ## /dev/<diskBase>*, and the most recent udev/kobject events visible
  ## to userspace. Returns the rendered block as a string. Called
  ## twice around each sgdisk invocation (before + after) when
  ## ``REPRO_DISK_DIAG`` is set so the time-series of kernel state can
  ## be inspected post-mortem.
  let ts = $now()
  result = "\n=== M9.R.42.1 SNAPSHOT label=" & label & " device=" &
    device & " ts=" & ts & " ===\n"
  let base = extractFilename(device)
  result.add diagCmd("cat /proc/partitions",
    "cat /proc/partitions 2>&1")
  result.add diagCmd("ls -la /dev/" & base & "*",
    "ls -la /dev/" & base & "* 2>&1")
  result.add diagCmd("ls /sys/class/block",
    "ls /sys/class/block 2>&1")
  result.add diagCmd("ls /sys/block/" & base & "/",
    "ls /sys/block/" & base & "/ 2>&1")
  result.add diagCmd("cat /sys/block/" & base & "/size",
    "cat /sys/block/" & base & "/size 2>&1")
  result.add diagCmd("ls /dev/disk/by-partuuid",
    "ls /dev/disk/by-partuuid 2>&1")
  # Force udev to drain its queue and report how long it took. If udev
  # is the source of the /dev/<base>1 absence this exit will be non-
  # zero or take a long time.
  result.add diagCmd("udevadm settle --timeout=10 + status",
    "udevadm settle --timeout=10 2>&1; echo settle-exit=$?")

proc diagSnapshot*(label, device: string) =
  ## Emit a labelled snapshot to ``REPRO_DISK_DIAG`` (if set). No-op
  ## when diag is off — the apply-driver hot path stays clean.
  if diagPath().len == 0: return
  diagAppend(snapshotKernelState(label, device))

# Forward declarations for the content-walker so applyDiskLayout can
# call applyContentNode and applyContentNode can call its variants.
proc applyContentNode*(ctx: ApplyContext; device, ctxKey: string;
                      content: ContentSpec)

proc tryUmountDevice(ctx: ApplyContext; device: string) =
  ## ``umount -lf <device>`` ignoring errors — the device may simply
  ## not be mounted. We deliberately don't raise on failure here.
  if isDryRun():
    let ex = execTool("umount", @["umount", "-lf", device])
    ctx.recordOperation(ex)
    return
  let argv = @["umount", "-lf", device]
  let cmdLine = renderArgv(argv)
  var ex: ExecResult
  ex.tool = "umount"
  ex.argv = argv
  ex.cmd = cmdLine
  # Run it; capture but don't raise. mount/umount errors here are
  # expected (device not mounted).
  var output = ""
  var exit = 1
  try:
    let pair = osproc.execCmdEx(renderArgv(argv))
    output = pair.output
    exit = pair.exitCode
  except CatchableError:
    discard
  ex.exit = exit
  ex.output = output
  ctx.recordOperation(ex)

proc applyDiskLayout*(layout: DiskLayout;
                     passphrases: Table[string, string] =
                       initTable[string, string]()): DiskApplyResult =
  ## Drive the full create-from-scratch apply per spec §7. Returns a
  ## ``DiskApplyResult`` whose ``operations`` field captures every
  ## subprocess invocation that ran (or would have run, under
  ## dry-run). On the first ``DiskToolError`` the function captures
  ## the failure step + message and returns immediately — no
  ## "graceful continue" or partial apply.
  let ctx = newApplyContext(layout, passphrases)
  try:
    # Step 1: best-effort unmount of every disk + its partitions.
    for diskName, d in ctx.layout.disks:
      tryUmountDevice(ctx, d.device)
      for pName, _ in d.partitions:
        let part = partitionDevicePath(d.device,
          toSeq(d.partitions.keys).find(pName) + 1)
        tryUmountDevice(ctx, part)

    # Step 2: wipefs each top-level disk.
    for _, d in ctx.layout.disks:
      ctx.recordOperation(wipefsAll(d.device))

    # Step 3 + 4: partition tables + partitions.
    # NOTE: parted mklabel + sgdisk -n on the SAME device race against
    # each other for the partition-table metadata. We use sgdisk -o
    # (zap + create a new GPT) for both steps when table=gpt; for mbr
    # we fall back to parted mklabel msdos + sgdisk for partitions
    # (which sgdisk supports via its MBR mode).
    for diskName, d in ctx.layout.disks:
      let tableKind = if d.`type`.len == 0: "gpt" else: d.`type`
      diagSnapshot("before-table-" & diskName, d.device)
      if tableKind == "gpt":
        # `sgdisk -o` zaps any existing GPT and creates a fresh empty
        # GPT in one operation, which avoids the parted-then-sgdisk
        # metadata race.
        ctx.recordOperation(execTool("sgdisk",
          @["sgdisk", "-o", d.device]))
      else:
        # MBR path: parted is the right tool for the label.
        ctx.recordOperation(partedMklabel(d.device, tableKind))
      diagSnapshot("after-table-" & diskName, d.device)
      var num = 1
      for pName, p in d.partitions:
        let gptType = gptTypeCodeFor(p.`type`)
        let sizeArg =
          # disko writes size as "100%" / "512M" / "remaining". We
          # translate into sgdisk's "<start>:<size>" form:
          #   100% / remaining → "0" (fill the disk)
          #   512M             → "+512M"
          if p.size in ["100%", "remaining", ""]: "0"
          else: "+" & p.size
        let startArg =
          # First partition starts at "0" (sgdisk default: first
          # aligned sector); subsequent partitions start at "0"
          # which is sgdisk's "first available sector".
          "0"
        diagSnapshot("before-sgdisk-n-" & pName, d.device)
        ctx.recordOperation(sgdiskCreatePartition(d.device, num,
          startArg, sizeArg, gptType, pName))
        diagSnapshot("after-sgdisk-n-" & pName, d.device)
        if p.bootable:
          ctx.recordOperation(partedSetBootable(d.device, num, true))
        inc num
      # After writing partitions, ask the kernel to re-read the table
      # so /dev/<disk>pN show up for the mkfs / cryptsetup steps.
      if findExe("partprobe").len > 0:
        diagSnapshot("before-partprobe-" & diskName, d.device)
        ctx.recordOperation(execTool("partprobe",
          @["partprobe", d.device]))
        diagSnapshot("after-partprobe-" & diskName, d.device)

    # Step 5 + 6 + 7 + 8: walk each partition's content recursively.
    for diskName, d in ctx.layout.disks:
      var num = 1
      for pName, p in d.partitions:
        let partDev = partitionDevicePath(d.device, num)
        applyContentNode(ctx, partDev,
          diskName & "." & pName, p.content)
        inc num

    # Step 9: ZFS pools + datasets.
    for pool in ctx.layout.pools:
      var props = initTable[string, string]()
      for opt in pool.options:
        let eq = opt.find('=')
        if eq > 0:
          props[opt[0 ..< eq]] = opt[eq + 1 .. ^1]
      ctx.recordOperation(zpoolCreate(pool.name, pool.layout,
        pool.devices, props))

  except DiskToolError as e:
    ctx.result.failure = true
    ctx.result.failureMsg = e.msg
    ctx.result.failureStep = e.tool
    ctx.result.failureTool = e.tool
    return ctx.result

  return ctx.result

# ---------------------------------------------------------------------
# Content-node walker — handles each ContentKind recursively.
# ---------------------------------------------------------------------

proc applyFilesystem(ctx: ApplyContext; device: string;
                    c: ContentSpec) =
  case c.format
  of "ext4":  ctx.recordOperation(mkfsExt4(device, c.label))
  of "vfat", "fat32":
              ctx.recordOperation(mkfsVfat(device, c.label))
  of "btrfs":
    ctx.recordOperation(mkfsBtrfs(device, c.label))
    # Subvolumes need the btrfs to be mounted; the apply driver
    # mounts under /tmp/disko-mount-<basename>, creates the subvols,
    # then unmounts. The mount path is captured in operations[].
    if c.subvols.len > 0:
      let scratchDir = "/tmp/disko-mount-" &
        device.extractFilename().replace("/", "_")
      if not isDryRun():
        createDir(scratchDir)
      ctx.recordOperation(mountFs(device, scratchDir, fsType = "btrfs"))
      for s in c.subvols:
        ctx.recordOperation(btrfsCreateSubvol(scratchDir, s.path))
      ctx.recordOperation(umountFs(scratchDir))
  of "xfs":   ctx.recordOperation(mkfsXfs(device, c.label))
  of "swap":  ctx.recordOperation(mkfsSwap(device, c.label))
  else:
    raise newException(DiskToolError,
      "applyFilesystem: unsupported filesystem format: " & c.format)

proc applyEncrypted(ctx: ApplyContext; device, ctxKey: string;
                   c: ContentSpec) =
  let passphrase = ctx.passphrases.getOrDefault(ctxKey, "swordfish")
  ctx.recordOperation(cryptsetupFormat(device, c.encryption, passphrase))
  let mapper = cryptsetupOpen(device,
    extractFilename(ctxKey).replace(".", "_") & "_crypt",
    passphrase)
  if not c.inner.isNil:
    applyContentNode(ctx, mapper, ctxKey & ".inner", c.inner[])

proc applyLvm(ctx: ApplyContext; device, ctxKey: string;
             c: ContentSpec) =
  ctx.recordOperation(lvmPvCreate(device))
  ctx.recordOperation(lvmVgCreate(c.vg, @[device]))
  for vol in c.volumes:
    ctx.recordOperation(lvmLvCreate(c.vg, vol.name, vol.size))
    let lvDev = "/dev/" & c.vg & "/" & vol.name
    if not vol.content.isNil:
      applyContentNode(ctx, lvDev,
        ctxKey & "." & vol.name, vol.content[])

proc applyZfsDataset(ctx: ApplyContext; c: ContentSpec) =
  var props = initTable[string, string]()
  for k, v in c.zfsProperties:
    props[k] = v
  if c.zfsMountpoint.len > 0:
    props["mountpoint"] = c.zfsMountpoint
  ctx.recordOperation(zfsCreate(c.dataset, props))

proc applyContentNode*(ctx: ApplyContext; device, ctxKey: string;
                      content: ContentSpec) =
  case content.kind
  of cfsNone:
    discard  # User declared no content for this slot; nothing to do.
  of cfsFilesystem:
    applyFilesystem(ctx, device, content)
  of cfsEncrypted:
    applyEncrypted(ctx, device, ctxKey, content)
  of cfsLvm:
    applyLvm(ctx, device, ctxKey, content)
  of cfsZfs:
    applyZfsDataset(ctx, content)
  of cfsSwap:
    ctx.recordOperation(mkfsSwap(device))

# ---------------------------------------------------------------------
# Mount driver — separate from the apply path. Walks the layout in
# mount-order (top-level FS first, nested mountpoints by path-depth
# ascending) and returns the (device, mountpoint) pairs the caller
# should unmount on cleanup.
# ---------------------------------------------------------------------

proc walkMounts(acc: var seq[(string, string)];
                target, device: string; c: ContentSpec) =
  ## Recursive helper for ``collectMountPlan``. Pulled out as a free
  ## proc (rather than a closure) so Nim's lent-iterator memory-safety
  ## check is happy.
  case c.kind
  of cfsNone: discard
  of cfsFilesystem:
    if c.mountpoint.len > 0:
      # mountpoint "/" → target, mountpoint "/boot" → target/boot.
      let mp =
        if c.mountpoint == "/": target
        else: target & c.mountpoint
      acc.add((device, mp))
      # btrfs subvolumes mount AFTER the top-level mount; emit each.
      if c.format == "btrfs":
        for s in c.subvols:
          # subvol path is the *mount target* for the subvol; we
          # mount the SAME device with -o subvol=<name>. The walker
          # captures this as a (device, mountpoint) pair where the
          # device repeats — the caller distinguishes by repetition.
          if s.path.len > 0 and s.path != "/":
            let sep =
              if s.path.startsWith("/") or target.endsWith("/"): ""
              else: "/"
            acc.add((device, target & sep & s.path))
  of cfsEncrypted:
    if not c.inner.isNil:
      let mapper = "/dev/mapper/" &
        extractFilename(device).replace(".", "_") & "_crypt"
      walkMounts(acc, target, mapper, c.inner[])
  of cfsLvm:
    for vol in c.volumes:
      if not vol.content.isNil:
        let lvDev = "/dev/" & c.vg & "/" & vol.name
        walkMounts(acc, target, lvDev, vol.content[])
  of cfsZfs:
    if c.zfsMountpoint.len > 0:
      let mp =
        if c.zfsMountpoint == "/": target
        else: target & c.zfsMountpoint
      acc.add((c.dataset, mp))
  of cfsSwap: discard

proc collectMountPlan*(layout: DiskLayout; target: string):
    seq[(string, string)] =
  ## Walk every ContentSpec and emit ``(device, mountpoint)`` pairs in
  ## mount-order (shorter mountpoints first; ties broken by traversal
  ## order). ``target`` is the prefix (typically ``/mnt``); the returned
  ## mountpoints have ``target`` prepended.
  result = @[]
  for _, d in layout.disks:
    var num = 1
    for _, p in d.partitions:
      let partDev = partitionDevicePath(d.device, num)
      walkMounts(result, target, partDev, p.content)
      inc num

  # Sort by mountpoint depth (shallow first) so "/" is mounted before
  # "/boot" / "/home" / etc. Stable sort preserves original ordering on
  # ties (matters for btrfs subvols vs. nested mountpoints).
  result.sort(proc(a, b: (string, string)): int =
    cmp(a[1].count('/'), b[1].count('/')))

proc mountDiskLayout*(layout: DiskLayout; target: string):
    seq[(string, string)] {.discardable.} =
  ## Mount every partition + subvol + ZFS dataset described by
  ## ``layout`` under ``target``. Returns the ``(device, mountpoint)``
  ## list so the caller can unmount in reverse order.
  result = collectMountPlan(layout, target)
  for (dev, mp) in result:
    if not isDryRun():
      createDir(mp)
    discard mountFs(dev, mp)

proc unmountDiskLayout*(plan: seq[(string, string)]) =
  ## Unmount in reverse order so the deeper mountpoints come out
  ## before their parents.
  for i in countdown(plan.high, 0):
    let (_, mp) = plan[i]
    try:
      discard umountFs(mp)
    except DiskToolError:
      discard  # Best-effort on cleanup.
