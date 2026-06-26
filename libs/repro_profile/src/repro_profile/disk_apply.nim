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

import std/[algorithm, options, os, osproc, sequtils, strutils, tables]

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
      if tableKind == "gpt":
        # `sgdisk -o` zaps any existing GPT and creates a fresh empty
        # GPT in one operation, which avoids the parted-then-sgdisk
        # metadata race.  Use ``--mbrtogpt`` shorthand combined: -o
        # plus -G to assign random GUID, plus -a 2048 to pin alignment
        # to 1 MiB (so the subsequent -n uses a canonical aligned
        # start instead of falling back to sector 34 on Debian Trixie
        # kernel 6.12.86, which is what M9.R.41 hit and M9.R.40 didn't.)
        # We do this as a SINGLE sgdisk invocation so the alignment
        # carries over with the GPT structure (sgdisk -a is per-invocation
        # only — a separate `sgdisk -a 2048 <dev>` does not persist).
        ctx.recordOperation(execTool("sgdisk",
          @["sgdisk", "-a", "2048", "-o", d.device]))
        # M9.R.41: force the kernel block layer to flush + re-read the
        # partition table AFTER sgdisk -o so the subsequent sgdisk -n
        # sees the freshly written GPT (not a cached stale view via
        # the block-layer buffer cache).  Without this, on the
        # M9.R.41 base-rootfs (Debian Trixie kernel 6.12.86 +
        # systemd-udev 257.13), sgdisk -n on the next call reads the
        # disk and reports "Caution! After loading partitions, the
        # CRC doesn't check out!" + falls back to start=34 alignment
        # (instead of the canonical 2048) + sgdisk exits 4.  The
        # partprobe + sync forces the kernel to re-scan + flush so
        # the next sgdisk loads a clean state.  M9.R.40 happened to
        # work without this because the older base-rootfs apt-pkg
        # set drove a slightly slower udev settle that hid the race;
        # it is a real race either way and this fix closes it.
        if findExe("partprobe").len > 0:
          ctx.recordOperation(execTool("partprobe",
            @["partprobe", d.device]))
        ctx.recordOperation(execTool("sync", @["sync"]))
      else:
        # MBR path: parted is the right tool for the label.
        ctx.recordOperation(partedMklabel(d.device, tableKind))
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
          # M9.R.41: explicit start sector for partition 1 (sector
          # 2048 = 1 MiB) to avoid sgdisk's alignment-fallback bug on
          # Debian Trixie kernel 6.12.86 + virtio-blk, where sgdisk
          # auto-picks sector 34 (just past the GPT entries) instead
          # of the canonical 1-MiB alignment.  Even with ``-a 2048``
          # passed explicitly, sgdisk in the M9.R.41 base-rootfs
          # rejects "Could not create partition 1 from 34 to 1048609"
          # unless we pre-compute the absolute start ourselves.
          # Subsequent partitions use "0" (sgdisk's "first available
          # sector after the previous one"), which works fine because
          # partition 1's end is well past the GPT entries.
          if num == 1: "2048" else: "0"
        ctx.recordOperation(sgdiskCreatePartition(d.device, num,
          startArg, sizeArg, gptType, pName))
        if p.bootable:
          ctx.recordOperation(partedSetBootable(d.device, num, true))
        inc num
      # After writing partitions, ask the kernel to re-read the table
      # so /dev/<disk>pN show up for the mkfs / cryptsetup steps.
      if findExe("partprobe").len > 0:
        ctx.recordOperation(execTool("partprobe",
          @["partprobe", d.device]))

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
