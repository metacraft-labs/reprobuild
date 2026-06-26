## M9.R.22b.1 — typed Nim wrappers for the disko underlying tools.
##
## Spec: ``reprobuild-specs/ReproOS-Disko-Port.md`` §1.1 + §6.2.
##
## Each wrapper here is a thin, deterministic adapter over one
## underlying disk-storage tool (parted / sgdisk / cryptsetup / mkfs.* /
## btrfs / lvm2 / zfs / mdadm / losetup). The wrappers build their
## argv vectors from typed inputs from ``repro_profile/types.nim`` and
## shell out via ``osproc.execCmdEx``.
##
## Test mode: setting the env-var ``REPRO_DISK_DRY_RUN=1`` causes every
## wrapper to skip the subprocess spawn and return a canned successful
## ``ExecResult`` whose ``cmd`` field captures the argv that *would* have
## run. Used by ``tests/unit/t_m9r22b_1_disk_tools.nim`` to verify the
## argv shape across the matrix without needing the real tools (or
## destructive privilege) on the test host.
##
## Error model: a non-zero exit code from any wrapper raises
## ``DiskToolError`` carrying the failing argv + exit + combined
## stdout/stderr. The apply driver (``./disk_apply.nim``) catches these
## and surfaces them as a structured ``DiskApplyResult`` failure.

import std/[algorithm, os, osproc, streams, strformat, strutils, tables]

import ./types

type
  DiskToolError* = object of CatchableError
    ## Raised by any wrapper when the underlying subprocess exits
    ## non-zero. Catch at the apply-driver level to surface a structured
    ## diagnostic; callers do NOT swallow these silently.
    tool*: string         ## tool name (e.g. "parted", "mkfs.ext4")
    argv*: seq[string]    ## the argv that ran
    exit*: int
    output*: string       ## combined stdout/stderr

  ExecResult* = object
    ## Diagnostic record of one tool invocation. Used by apply-driver
    ## logging + the dry-run mode's test inspection.
    tool*: string
    argv*: seq[string]
    cmd*: string          ## the rendered command line (for logging)
    exit*: int
    output*: string

# ---------------------------------------------------------------------
# Dry-run mode and the central exec wrapper.
# ---------------------------------------------------------------------

proc isDryRun*(): bool {.inline.} =
  ## Returns true when ``REPRO_DISK_DRY_RUN=1`` is set. The unit tests
  ## flip this so the wrappers can be exercised against a deterministic
  ## argv shape on hosts that don't have parted/mkfs.* installed.
  getEnv("REPRO_DISK_DRY_RUN") == "1"

proc renderArgv*(argv: seq[string]): string =
  ## Render ``argv`` as a shell-safe single-line command. Used for
  ## logging + the dry-run mode's expected-command shape.
  result = ""
  for i, a in argv:
    if i > 0: result.add ' '
    result.add quoteShell(a)

proc execTool*(tool: string; argv: seq[string]): ExecResult =
  ## Central exec point: every wrapper routes through this so dry-run
  ## mode + diagnostic logging are uniform. The first element of
  ## ``argv`` SHOULD be the program name (e.g. ``"parted"``); the rest
  ## are flags + positional args. Raises ``DiskToolError`` on non-zero
  ## exit unless dry-run is on.
  result.tool = tool
  result.argv = argv
  result.cmd = renderArgv(argv)
  if isDryRun():
    result.exit = 0
    result.output = "(dry-run) " & result.cmd
    return
  if argv.len == 0:
    raise newException(DiskToolError,
      "execTool: empty argv for tool " & tool)
  let prog = argv[0]
  let rest = argv[1 .. ^1]
  let (output, exit) = execCmdEx(quoteShell(prog) & " " &
    renderArgv(rest))
  result.exit = exit
  result.output = output
  if exit != 0:
    var e = newException(DiskToolError,
      tool & " failed (exit " & $exit & "): " & result.cmd &
      "\n--- output ---\n" & output)
    e.tool = tool
    e.argv = argv
    e.exit = exit
    e.output = output
    raise e

# ---------------------------------------------------------------------
# parted / sgdisk — partition tables and partition creation.
# ---------------------------------------------------------------------

proc partedMklabel*(device: string; kind: string): ExecResult
    {.discardable.} =
  ## ``parted -s <device> mklabel <gpt|msdos>``. The ``kind`` argument
  ## must be one of ``"gpt"`` (the disko default) or ``"msdos"`` (the
  ## MBR escape hatch).
  let canonical =
    case kind
    of "", "gpt": "gpt"
    of "mbr", "msdos": "msdos"
    else:
      raise newException(DiskToolError,
        "partedMklabel: unsupported table kind: " & kind &
        " (expected gpt | mbr | msdos)")
  execTool("parted", @["parted", "-s", device, "mklabel", canonical])

proc sgdiskCreatePartition*(device: string; num: int;
                            start, size, gptType, label: string):
                            ExecResult {.discardable.} =
  ## ``sgdisk -n <num>:<start>:<size> [-t <num>:<type>] [-c <num>:<label>] <device>``.
  ##
  ## ``num`` is the GPT partition number (1-based). ``start`` and
  ## ``size`` are sgdisk-format sectors / sizes — empty string means
  ## "default" (e.g. start=0 → first free sector, size=0 → fill).
  ## ``gptType`` is the GPT type-GUID short code (``EF00`` for ESP,
  ## ``8300`` for Linux data, ``8200`` for swap, ``8E00`` for LVM,
  ## ``8309`` for LUKS, ``FD00`` for RAID, ``BF00`` for ZFS).
  if num < 1:
    raise newException(DiskToolError,
      "sgdiskCreatePartition: partition number must be >= 1, got " &
      $num)
  let startStr = if start.len == 0: "0" else: start
  let sizeStr  = if size.len  == 0: "0" else: size
  # M9.R.41: pin alignment to 2048 sectors (1 MiB) — the canonical
  # alignment that GPT partitioning tools use for SSD/HDD-friendly
  # geometry.  sgdisk's auto-alignment falls back to sector 34 (just
  # past the GPT entries) on Debian Trixie kernel 6.12.86 + virtio-
  # blk, which produces partitions that sgdisk itself then rejects
  # on the second call.  ``-a 2048`` is per-invocation so we set it
  # on every ``sgdisk -n`` we drive.
  var argv = @["sgdisk",
    "-a", "2048",
    "-n", $num & ":" & startStr & ":" & sizeStr]
  if gptType.len > 0:
    argv.add "-t"; argv.add $num & ":" & gptType
  if label.len > 0:
    argv.add "-c"; argv.add $num & ":" & label
  argv.add device
  # M9.R.41: tolerate sgdisk exit code 4 when the partition actually
  # got written.  sgdisk on Debian Trixie kernel 6.12.86 + virtio-blk
  # exits 4 ("Could not create partition N from S to E") for
  # partition 1 EVEN WHEN the partition was successfully written to
  # the on-disk GPT (verified post-hoc via fdisk -l + kernel re-read
  # showing /dev/<dev>1 with the expected range).  This is a sgdisk
  # quirk specific to this kernel/virtio combination; the actual
  # partitioning succeeded.  The post-step partprobe forces the
  # kernel to re-read so the next sgdisk + mkfs calls see the
  # written state.
  try:
    result = execTool("sgdisk", argv)
  except DiskToolError as e:
    if e.exit == 4:
      # Probe: did the partition actually get written?
      # Inline the partition-device-path computation (the dedicated
      # ``partitionDevicePath`` helper is declared later in the same
      # file and Nim's single-pass resolution can't see it here).
      let base = extractFilename(device)
      let probeDev =
        if "/by-id/" in device or "/by-path/" in device:
          device & "-part" & $num
        elif base.len > 0 and base[^1] in {'0'..'9'}:
          device & "p" & $num
        else:
          device & $num
      # Wait a tick + partprobe so the kernel sees the new partition.
      # We retry the probe up to 10 times with a 200ms sleep between
      # each so the kernel + udev have time to materialise the device
      # node after sgdisk's write.
      var found = false
      for retry in 0 ..< 10:
        discard execCmdEx("sync")
        if findExe("partprobe").len > 0:
          discard execCmdEx("partprobe " & quoteShell(device))
        if fileExists(probeDev) or fileExists("/sys/class/block/" &
            extractFilename(probeDev)):
          found = true
          break
        # Sleep 200ms before re-probing.
        discard execCmdEx("sleep 0.2")
      if found:
        # The partition node exists — sgdisk's exit 4 was a false-
        # alarm.  Synthesize a success result so the disko driver
        # continues to mkfs + mount.
        result.tool = "sgdisk"
        result.argv = argv
        result.cmd = renderArgv(argv)
        result.exit = 0
        result.output = "[M9.R.41 false-alarm] sgdisk exited 4 but " &
          probeDev & " exists; treating as success.  Original " &
          "stderr:\n" & e.output
        return result
    raise e

proc partedSetBootable*(device: string; num: int; bootable: bool):
                       ExecResult {.discardable.} =
  ## ``parted -s <device> set <num> boot on|off``. Used for the MBR
  ## bootable flag + the GPT ``legacy_boot`` flag.
  let onoff = if bootable: "on" else: "off"
  execTool("parted",
    @["parted", "-s", device, "set", $num, "boot", onoff])

# ---------------------------------------------------------------------
# cryptsetup — LUKS open/format.
# ---------------------------------------------------------------------

proc cryptsetupFormat*(device: string; encryption: EncryptionSpec;
                       passphrase: string): ExecResult
                       {.discardable.} =
  ## ``cryptsetup luksFormat`` with the encryption settings from the
  ## DSL. The passphrase is fed via stdin (``--key-file=-``); the test
  ## harness uses a fixed string. Empty passphrase is rejected at this
  ## level — the caller chooses interactive vs. key-file vs. cached.
  if passphrase.len == 0:
    raise newException(DiskToolError,
      "cryptsetupFormat: empty passphrase rejected (caller must " &
      "supply one)")
  let luksType =
    case encryption.`type`
    of "", "luks2": "luks2"
    of "luks1": "luks1"
    else:
      raise newException(DiskToolError,
        "cryptsetupFormat: unsupported LUKS type: " & encryption.`type` &
        " (expected luks1 | luks2)")
  var argv = @["cryptsetup", "luksFormat",
    "--type", luksType,
    "--batch-mode",
    "--key-file=-"]
  if encryption.cipher.len > 0:
    argv.add "--cipher"; argv.add encryption.cipher
  if encryption.allowDiscards:
    argv.add "--allow-discards"
  argv.add device
  # Dry-run path goes through execTool. Real path feeds the passphrase
  # via stdin to cryptsetup's --key-file=-.
  if isDryRun():
    return execTool("cryptsetup", argv)
  let cmdLine = quoteShell(argv[0]) & " " & renderArgv(argv[1..^1])
  let p = startProcess(argv[0], args = argv[1..^1],
    options = {poUsePath, poStdErrToStdOut})
  let s = p.inputStream
  s.write(passphrase)
  s.close()
  let output = p.outputStream.readAll()
  let exit = p.waitForExit()
  p.close()
  result.tool = "cryptsetup"
  result.argv = argv
  result.cmd = cmdLine
  result.exit = exit
  result.output = output
  if exit != 0:
    var e = newException(DiskToolError,
      "cryptsetup luksFormat failed (exit " & $exit & "): " & cmdLine &
      "\n--- output ---\n" & output)
    e.tool = "cryptsetup"
    e.argv = argv
    e.exit = exit
    e.output = output
    raise e

proc cryptsetupOpen*(device: string; name: string;
                     passphrase: string): string {.discardable.} =
  ## ``cryptsetup open <device> <name>`` — opens the LUKS container
  ## under ``/dev/mapper/<name>``. Returns the path of the mapper
  ## device for downstream filesystem creation. Passphrase is fed via
  ## stdin.
  if name.len == 0:
    raise newException(DiskToolError,
      "cryptsetupOpen: name must be non-empty")
  let argv = @["cryptsetup", "open",
    "--type", "luks",
    "--key-file=-",
    device, name]
  if isDryRun():
    discard execTool("cryptsetup", argv)
    return "/dev/mapper/" & name
  let cmdLine = quoteShell(argv[0]) & " " & renderArgv(argv[1..^1])
  let p = startProcess(argv[0], args = argv[1..^1],
    options = {poUsePath, poStdErrToStdOut})
  let s = p.inputStream
  s.write(passphrase)
  s.close()
  let output = p.outputStream.readAll()
  let exit = p.waitForExit()
  p.close()
  if exit != 0:
    var e = newException(DiskToolError,
      "cryptsetup open failed (exit " & $exit & "): " & cmdLine &
      "\n--- output ---\n" & output)
    e.tool = "cryptsetup"
    e.argv = argv
    e.exit = exit
    e.output = output
    raise e
  return "/dev/mapper/" & name

proc cryptsetupClose*(name: string): ExecResult {.discardable.} =
  ## ``cryptsetup close <name>``. Inverse of ``cryptsetupOpen``.
  execTool("cryptsetup",
    @["cryptsetup", "close", name])

# ---------------------------------------------------------------------
# mkfs.* — filesystem creation. Each is a thin shim around the
# corresponding ``mkfs.<format>`` binary.
# ---------------------------------------------------------------------

proc mkfsExt4*(device: string; label: string = ""): ExecResult
    {.discardable.} =
  ## ``mkfs.ext4 -F [-L <label>] <device>``. ``-F`` forces overwrite
  ## of any existing signature (the apply pipeline already wipes, but
  ## ``-F`` makes the tool non-interactive on rare residue cases).
  var argv = @["mkfs.ext4", "-F"]
  if label.len > 0:
    argv.add "-L"; argv.add label
  argv.add device
  execTool("mkfs.ext4", argv)

proc mkfsVfat*(device: string; label: string = ""): ExecResult
    {.discardable.} =
  ## ``mkfs.vfat -F 32 [-n <label>] <device>`` — FAT32 for the ESP.
  var argv = @["mkfs.vfat", "-F", "32"]
  if label.len > 0:
    argv.add "-n"; argv.add label
  argv.add device
  execTool("mkfs.vfat", argv)

proc mkfsBtrfs*(device: string; label: string = ""): ExecResult
    {.discardable.} =
  ## ``mkfs.btrfs -f [-L <label>] <device>``. ``-f`` forces overwrite.
  var argv = @["mkfs.btrfs", "-f"]
  if label.len > 0:
    argv.add "-L"; argv.add label
  argv.add device
  execTool("mkfs.btrfs", argv)

proc mkfsSwap*(device: string; label: string = ""): ExecResult
    {.discardable.} =
  ## ``mkswap [-L <label>] <device>``.
  var argv = @["mkswap"]
  if label.len > 0:
    argv.add "-L"; argv.add label
  argv.add device
  execTool("mkswap", argv)

proc mkfsXfs*(device: string; label: string = ""): ExecResult
    {.discardable.} =
  ## ``mkfs.xfs -f [-L <label>] <device>``. ``-f`` forces overwrite.
  var argv = @["mkfs.xfs", "-f"]
  if label.len > 0:
    argv.add "-L"; argv.add label
  argv.add device
  execTool("mkfs.xfs", argv)

# ---------------------------------------------------------------------
# btrfs subvolume management.
# ---------------------------------------------------------------------

proc btrfsCreateSubvol*(parent: string; name: string): ExecResult
    {.discardable.} =
  ## ``btrfs subvolume create <parent>/<name>``. ``parent`` is the
  ## mount-point where the top-level btrfs is currently mounted (the
  ## apply driver mounts it under a scratch dir, creates the subvols,
  ## then unmounts).
  if parent.len == 0 or name.len == 0:
    raise newException(DiskToolError,
      "btrfsCreateSubvol: parent and name must both be non-empty")
  # POSIX path: the apply path always runs on Linux. Use explicit '/'
  # so the wrapper produces /mnt/btrfs/@home even when this code is
  # cross-compiled from Windows for argv-shape verification.
  let trimmed = if parent.endsWith("/"): parent[0 ..< ^1] else: parent
  execTool("btrfs",
    @["btrfs", "subvolume", "create", trimmed & "/" & name])

# ---------------------------------------------------------------------
# LVM.
# ---------------------------------------------------------------------

proc lvmPvCreate*(device: string): ExecResult {.discardable.} =
  ## ``pvcreate -ff -y <device>``. ``-ff -y`` keeps it non-interactive
  ## even on a device that had previous PV metadata.
  execTool("pvcreate", @["pvcreate", "-ff", "-y", device])

proc lvmVgCreate*(vgName: string; devices: seq[string]): ExecResult
    {.discardable.} =
  ## ``vgcreate <vgName> <dev1> [<dev2> ...]``. The volume-group name
  ## must be non-empty and the device list must be non-empty (LVM
  ## requires at least one PV per VG).
  if vgName.len == 0:
    raise newException(DiskToolError,
      "lvmVgCreate: vgName must be non-empty")
  if devices.len == 0:
    raise newException(DiskToolError,
      "lvmVgCreate: need at least one device for VG " & vgName)
  var argv = @["vgcreate", vgName]
  for d in devices: argv.add d
  execTool("vgcreate", argv)

proc lvmLvCreate*(vgName, lvName: string; size: string): ExecResult
    {.discardable.} =
  ## ``lvcreate -n <lvName> -L <size> <vgName>`` for fixed sizes, or
  ## ``lvcreate -n <lvName> -l 100%FREE <vgName>`` for the
  ## ``100%FREE`` extents-percentage form.
  if vgName.len == 0 or lvName.len == 0:
    raise newException(DiskToolError,
      "lvmLvCreate: vgName and lvName must both be non-empty")
  if size.len == 0:
    raise newException(DiskToolError,
      "lvmLvCreate: size must be non-empty (e.g. \"20G\" or " &
      "\"100%FREE\")")
  var argv = @["lvcreate", "-n", lvName]
  if "%" in size:
    argv.add "-l"; argv.add size
  else:
    argv.add "-L"; argv.add size
  argv.add vgName
  execTool("lvcreate", argv)

# ---------------------------------------------------------------------
# ZFS.
# ---------------------------------------------------------------------

proc zpoolCreate*(name: string; layout: string; devices: seq[string];
                  properties: Table[string, string]): ExecResult
                  {.discardable.} =
  ## ``zpool create [-o <prop>=<val> ...] <name> [<layout>] <dev>...``.
  ##
  ## ``layout`` is the disko top-level pool layout — ``""`` /
  ## ``"stripe"`` maps to "no layout keyword" (zpool's default is
  ## stripe); ``"mirror"``/``"raidz"``/``"raidz2"``/``"raidz3"`` are
  ## the vdev keywords. Properties are emitted in sorted order so the
  ## argv is deterministic across runs.
  if name.len == 0:
    raise newException(DiskToolError,
      "zpoolCreate: pool name must be non-empty")
  if devices.len == 0:
    raise newException(DiskToolError,
      "zpoolCreate: need at least one device for pool " & name)
  var argv = @["zpool", "create"]
  var keys: seq[string] = @[]
  for k in properties.keys: keys.add k
  keys.sort()
  for k in keys:
    argv.add "-o"; argv.add k & "=" & properties[k]
  argv.add name
  case layout
  of "", "stripe": discard
  of "mirror", "raidz", "raidz1", "raidz2", "raidz3":
    argv.add layout
  else:
    raise newException(DiskToolError,
      "zpoolCreate: unsupported layout: " & layout &
      " (expected stripe | mirror | raidz | raidz2 | raidz3)")
  for d in devices: argv.add d
  execTool("zpool", argv)

proc zfsCreate*(dataset: string;
                properties: Table[string, string]): ExecResult
                {.discardable.} =
  ## ``zfs create [-o <prop>=<val> ...] <dataset>``. Properties sorted
  ## for determinism.
  if dataset.len == 0:
    raise newException(DiskToolError,
      "zfsCreate: dataset must be non-empty")
  var argv = @["zfs", "create"]
  var keys: seq[string] = @[]
  for k in properties.keys: keys.add k
  keys.sort()
  for k in keys:
    argv.add "-o"; argv.add k & "=" & properties[k]
  argv.add dataset
  execTool("zfs", argv)

# ---------------------------------------------------------------------
# mdraid.
# ---------------------------------------------------------------------

proc mdadmCreate*(device: string; level: string;
                  devices: seq[string]): ExecResult {.discardable.} =
  ## ``mdadm --create <device> --level=<level> --raid-devices=<N>
  ##  <dev>...`` with ``--metadata=1.2`` (the disko default) and
  ## ``--run`` to skip the interactive yes/no.
  if device.len == 0:
    raise newException(DiskToolError,
      "mdadmCreate: target md device must be non-empty")
  if devices.len < 2:
    raise newException(DiskToolError,
      "mdadmCreate: need at least 2 devices to create an md array " &
      "(got " & $devices.len & ")")
  let lvl =
    case level
    of "0", "raid0", "stripe":   "0"
    of "1", "raid1", "mirror":   "1"
    of "5", "raid5":             "5"
    of "6", "raid6":             "6"
    of "10", "raid10":           "10"
    else:
      raise newException(DiskToolError,
        "mdadmCreate: unsupported RAID level: " & level &
        " (expected 0 | 1 | 5 | 6 | 10)")
  var argv = @["mdadm",
    "--create", device,
    "--level=" & lvl,
    "--raid-devices=" & $devices.len,
    "--metadata=1.2",
    "--run"]
  for d in devices: argv.add d
  execTool("mdadm", argv)

# ---------------------------------------------------------------------
# Loop devices (used for testing).
# ---------------------------------------------------------------------

proc losetupCreate*(imageFile: string): string {.discardable.} =
  ## ``losetup --find --show <imageFile>``. Returns ``/dev/loopN``
  ## (the path the kernel allocated). In dry-run mode returns a fixed
  ## ``/dev/loop99`` so the integration tests have a deterministic
  ## device path to match against.
  if imageFile.len == 0:
    raise newException(DiskToolError,
      "losetupCreate: imageFile must be non-empty")
  let argv = @["losetup", "--find", "--show", imageFile]
  if isDryRun():
    discard execTool("losetup", argv)
    return "/dev/loop99"
  let (output, exit) = execCmdEx(renderArgv(argv))
  if exit != 0:
    var e = newException(DiskToolError,
      "losetup --find --show failed (exit " & $exit & "): " &
      renderArgv(argv) & "\n--- output ---\n" & output)
    e.tool = "losetup"
    e.argv = argv
    e.exit = exit
    e.output = output
    raise e
  return output.strip()

proc losetupDetach*(loopDevice: string): ExecResult {.discardable.} =
  ## ``losetup --detach <loopDevice>``.
  if loopDevice.len == 0:
    raise newException(DiskToolError,
      "losetupDetach: loopDevice must be non-empty")
  execTool("losetup",
    @["losetup", "--detach", loopDevice])

# ---------------------------------------------------------------------
# Wipe / mount / unmount.
# ---------------------------------------------------------------------

proc wipefsAll*(device: string): ExecResult {.discardable.} =
  ## ``wipefs -af <device>``. First step of every apply: kill any
  ## stale filesystem / partition-table signature so the new layout
  ## doesn't collide with the old one.
  execTool("wipefs",
    @["wipefs", "-af", device])

proc mountFs*(device, mountpoint: string;
              fsType: string = "";
              options: seq[string] = @[]): ExecResult {.discardable.} =
  ## ``mount [-t <fsType>] [-o <opts>] <device> <mountpoint>``.
  var argv = @["mount"]
  if fsType.len > 0:
    argv.add "-t"; argv.add fsType
  if options.len > 0:
    argv.add "-o"; argv.add options.join(",")
  argv.add device
  argv.add mountpoint
  execTool("mount", argv)

proc umountFs*(target: string): ExecResult {.discardable.} =
  ## ``umount <target>``. ``target`` may be either a device path or a
  ## mountpoint; ``umount`` accepts both.
  execTool("umount",
    @["umount", target])

# ---------------------------------------------------------------------
# Helpers for the apply driver.
# ---------------------------------------------------------------------

proc gptTypeCodeFor*(partitionType: string): string =
  ## Map our PartitionSpec.`type` field to an sgdisk type-GUID short
  ## code. Closed-set per ReproOS-Disko-Port.md §2.2. Unknown values
  ## return ``""`` (no ``-t`` flag emitted; sgdisk defaults to Linux
  ## filesystem 8300).
  case partitionType
  of "esp", "ptEsp":                "EF00"
  of "bios", "ptBios":              "EF02"
  of "linux", "linuxData", "ptLinuxData": "8300"
  of "luks", "ptLinuxLuks":         "8309"
  of "lvm", "ptLinuxLvm":           "8E00"
  of "swap", "ptLinuxSwap":         "8200"
  of "raid", "ptLinuxRaid":         "FD00"
  of "zfs", "ptZfs":                "BF00"
  else: ""

proc partitionDevicePath*(diskDevice: string; num: int): string =
  ## Compute the kernel device path for the ``num``-th partition of
  ## ``diskDevice``. Handles the kernel's two conventions:
  ##
  ## - ``/dev/sda`` -> ``/dev/sda1`` (no separator)
  ## - ``/dev/nvme0n1`` -> ``/dev/nvme0n1p1`` (with ``p`` separator)
  ## - ``/dev/loop0`` -> ``/dev/loop0p1`` (with ``p`` separator)
  ## - ``/dev/disk/by-id/...`` -> ``/dev/disk/by-id/...-part1``
  ##
  ## The selection rule: if the device basename ends in a digit, use
  ## ``p<N>`` (nvme/loop/mmcblk); otherwise use ``<N>`` directly. By-id
  ## symlinks use the ``-partN`` suffix.
  if num < 1:
    raise newException(DiskToolError,
      "partitionDevicePath: partition number must be >= 1, got " &
      $num)
  if "/by-id/" in diskDevice or "/by-path/" in diskDevice:
    return diskDevice & "-part" & $num
  let base = extractFilename(diskDevice)
  if base.len > 0 and base[^1] in {'0'..'9'}:
    return diskDevice & "p" & $num
  return diskDevice & $num
