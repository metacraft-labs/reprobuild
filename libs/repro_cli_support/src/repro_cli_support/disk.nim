## M9.R.22.4 — ``repro disk`` CLI subcommand surface.
##
## Spec: ``reprobuild-specs/ReproOS-Disko-Port.md`` §4.
##
## Surface::
##
##   repro disk plan <disko.nim>            (M9.R.22, v1)
##   repro disk apply <disko.nim> --confirm (stub, M9.R.22b)
##   repro disk mount <disko.nim> --target /mnt (stub, M9.R.22b)
##   repro disk unmount <disko.nim> --target /mnt (stub, M9.R.22b)
##   repro disk generate --probe /          (stub, M9.R.22c)
##   repro disk image <disko.nim> --output reproos.img (stub, M9.R.22c)
##
## v1 implements ``repro disk plan`` fully: it loads the hardware.nim
## (or any Nim source emitting a ``hardware "<id>":`` block whose
## body contains ``disko:``) by running it as a subprocess and reading
## the emitted JSON from stdout, then prints a human-readable summary
## of the planned operations.
##
## ``apply`` / ``mount`` / ``unmount`` / ``generate`` / ``image`` are
## stubs that print a clear "implementation pending" message and
## return exit code 2; they parse arguments fully so the CLI surface
## is testable today (M9.R.22.3) and the implementation lands in
## M9.R.22b / M9.R.22c without further surface-area churn.

import std/[options, os, osproc, strutils, tables]

import repro_profile/emit
import repro_profile/types
import repro_profile/disk_tools
import repro_profile/disk_apply

# ---------------------------------------------------------------------
# Plan output: human-readable summary of a DiskLayout.
# ---------------------------------------------------------------------

proc indentLines(text: string; spaces: int): string =
  let pad = " ".repeat(spaces)
  result = ""
  for ln in text.splitLines():
    if ln.len == 0 and result.len > 0 and result[^1] == '\n':
      result.add "\n"
    else:
      result.add pad
      result.add ln
      result.add "\n"

proc renderContent(c: ContentSpec; depth: int): string

proc renderEncryption(e: EncryptionSpec): string =
  result = "encryption:\n"
  result.add "  type:           " & (if e.`type`.len > 0: e.`type` else: "luks2") & "\n"
  result.add "  keyFile:        " & (if e.keyFile.len > 0: e.keyFile else: "(prompt at boot)") & "\n"
  if e.cipher.len > 0:
    result.add "  cipher:         " & e.cipher & "\n"
  result.add "  allowDiscards:  " & (if e.allowDiscards: "yes" else: "no") & "\n"

proc renderSubvols(svs: seq[BtrfsSubvolSpec]): string =
  result = "subvolumes:\n"
  for s in svs:
    result.add "  " & s.path
    if s.options.len > 0:
      result.add "  [" & s.options.join(", ") & "]"
    result.add "\n"

proc renderContent(c: ContentSpec; depth: int): string =
  case c.kind
  of cfsNone:
    result = "(unset)\n"
  of cfsFilesystem:
    result = "filesystem " & c.format & " → " &
             (if c.mountpoint.len > 0: c.mountpoint else: "(no mountpoint)") & "\n"
    if c.mountOptions.len > 0:
      result.add "  mount options: " & c.mountOptions.join(", ") & "\n"
    if c.label.len > 0:
      result.add "  label:         " & c.label & "\n"
    if c.subvols.len > 0:
      result.add indentLines(renderSubvols(c.subvols), 2)
  of cfsEncrypted:
    result = "encrypted (LUKS)\n"
    result.add indentLines(renderEncryption(c.encryption), 2)
    if not c.inner.isNil:
      result.add "  inner:\n"
      result.add indentLines(renderContent(c.inner[], depth + 1), 4)
  of cfsLvm:
    result = "LVM volume-group: " & c.vg & "\n"
    for v in c.volumes:
      result.add "  LV " & v.name & " (size " & v.size & ")\n"
      if not v.content.isNil:
        result.add indentLines(renderContent(v.content[], depth + 1), 4)
  of cfsZfs:
    result = "ZFS dataset: " & c.dataset & " (pool: " & c.pool & ")"
    if c.zfsMountpoint.len > 0:
      result.add " → " & c.zfsMountpoint
    result.add "\n"
    if c.zfsProperties.len > 0:
      result.add "  properties:\n"
      for k, v in c.zfsProperties:
        result.add "    " & k & " = " & v & "\n"
  of cfsSwap:
    result = "swap (priority " & $c.swapPriority
    if c.swapDiscardPolicy.len > 0:
      result.add ", discard=" & c.swapDiscardPolicy
    result.add ")\n"

proc renderPartition(name: string; p: PartitionSpec): string =
  result = "partition \"" & name & "\" (kind: " &
    (if p.`type`.len > 0: p.`type` else: "(unspecified)") &
    ", size: " & p.size
  if p.bootable: result.add ", bootable"
  result.add ")\n"
  result.add indentLines(renderContent(p.content, 0), 2)

proc renderPlan*(spec: SystemHardwareSpec): string =
  ## Render a human-readable plan of the disko intent. Used by
  ## ``repro disk plan`` to print the layout the user is about to
  ## install with ``repro disk apply``.
  result = "# `repro disk plan` for hardware id: " & spec.id & "\n"
  if spec.disko.isNone:
    result.add "\n(no `disko:` block — nothing to plan)\n"
    return
  let dl = spec.disko.get()
  if dl.disks.len == 0 and dl.pools.len == 0:
    result.add "\n(empty `disko:` block — no disks or pools declared)\n"
    return
  if dl.disks.len > 0:
    result.add "\nDisks (" & $dl.disks.len & "):\n"
    for diskName, d in dl.disks:
      result.add "  \"" & diskName & "\": device=" & d.device &
        ", table=" & (if d.`type`.len > 0: d.`type` else: "gpt") & "\n"
      for pName, p in d.partitions:
        result.add indentLines(renderPartition(pName, p), 4)
  if dl.pools.len > 0:
    result.add "\nZFS pools (" & $dl.pools.len & "):\n"
    for p in dl.pools:
      result.add "  \"" & p.name & "\": layout=" &
        (if p.layout.len > 0: p.layout else: "stripe") & "\n"
      if p.devices.len > 0:
        result.add "    devices:\n"
        for dev in p.devices:
          result.add "      " & dev & "\n"
      if p.options.len > 0:
        result.add "    options: " & p.options.join(", ") & "\n"
  result.add "\nOperations (would be performed by `repro disk apply`):\n"
  result.add "  1. unmount any current mounts on the target devices\n"
  result.add "  2. wipe each target device's partition table\n"
  if dl.disks.len > 0:
    var step = 3
    for diskName, d in dl.disks:
      result.add "  " & $step & ". sgdisk: write " &
        (if d.`type`.len > 0: d.`type` else: "gpt") &
        " table on " & d.device & "\n"
      inc step
      for pName, p in d.partitions:
        result.add "  " & $step & ". create partition \"" & pName &
          "\" (" & p.size & ")\n"
        inc step
  for p in dl.pools:
    result.add "  zpool create " & p.name & " (" &
      (if p.layout.len > 0: p.layout else: "stripe") & ", " &
      $p.devices.len & " devices)\n"
  result.add "\nNon-destructive. Re-run with `repro disk apply ... --confirm` to execute.\n"

# ---------------------------------------------------------------------
# Source-file loading: run a ``hardware "<id>":`` Nim source file and
# capture the emitted JSON. The hardware macro `echo`s
# ``emitSystemHardwareJson(...)`` and then quits, so a subprocess gives
# us the SystemHardwareSpec back.
# ---------------------------------------------------------------------

type
  DiskPlanFailureKind* = enum
    dpfMissingFile
    dpfCompileFailed
    dpfRunFailed
    dpfParseFailed
    dpfNoDisko

  DiskPlanFailure* = object
    kind*: DiskPlanFailureKind
    msg*: string

  DiskPlanOutcome* = object
    spec*: SystemHardwareSpec
    text*: string                ## human-readable plan
    failure*: bool
    failureKind*: DiskPlanFailureKind
    failureMsg*: string

proc loadDiskoFromSource*(diskoNim: string): DiskPlanOutcome =
  ## Compile + run ``diskoNim`` via ``nim r`` and capture the emitted
  ## SystemHardwareSpec JSON. The file must contain a single
  ## ``hardware "<id>":`` block whose body includes a ``disko:`` block.
  if not fileExists(diskoNim):
    result.failure = true
    result.failureKind = dpfMissingFile
    result.failureMsg = "no such file: " & diskoNim
    return
  let cmd = "nim r --hints:off --warnings:off --verbosity:0 " &
    quoteShell(diskoNim)
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    result.failure = true
    result.failureKind = dpfCompileFailed
    result.failureMsg = "nim r failed (exit " & $exitCode & "):\n" & output
    return
  # The hardware macro emits JSON on the last non-empty stdout line.
  var jsonLine = ""
  for line in output.splitLines():
    let t = line.strip()
    if t.len > 0 and t[0] == '{':
      jsonLine = t
  if jsonLine.len == 0:
    result.failure = true
    result.failureKind = dpfRunFailed
    result.failureMsg = "no JSON output captured from " & diskoNim
    return
  try:
    result.spec = parseSystemHardwareJson(jsonLine)
  except CatchableError as e:
    result.failure = true
    result.failureKind = dpfParseFailed
    result.failureMsg = "parse JSON failed: " & e.msg
    return
  if result.spec.disko.isNone:
    result.failure = true
    result.failureKind = dpfNoDisko
    result.failureMsg =
      "loaded " & diskoNim & " but it has no `disko:` block; " &
      "nothing to plan."
    return
  result.text = renderPlan(result.spec)

# ---------------------------------------------------------------------
# Argument parsing — shared parser for the `repro disk` subcommands.
# ---------------------------------------------------------------------

type
  DiskSubcommand* = enum
    dscPlan
    dscApply
    dscMount
    dscUnmount
    dscGenerate
    dscImage
    dscNone     ## no/invalid subcommand supplied

  DiskCliOptions* = object
    sub*: DiskSubcommand
    source*: string         ## path to disko.nim / hardware.nim
    target*: string         ## /mnt (mount/unmount/apply target-prefix)
    device*: string         ## --device override for apply
    output*: string         ## --output for image
    probe*: string          ## --probe root for generate
    sizeStr*: string        ## --size for image
    confirm*: bool

proc parseDiskArgs*(args: seq[string]): DiskCliOptions =
  if args.len == 0:
    result.sub = dscNone
    return
  case args[0]
  of "plan":     result.sub = dscPlan
  of "apply":    result.sub = dscApply
  of "mount":    result.sub = dscMount
  of "unmount":  result.sub = dscUnmount
  of "generate": result.sub = dscGenerate
  of "image":    result.sub = dscImage
  else:
    raise newException(ValueError,
      "unknown `repro disk` subcommand: `" & args[0] & "`; " &
      "expected one of plan/apply/mount/unmount/generate/image")
  var i = 1
  while i < args.len:
    let a = args[i]
    case a
    of "--confirm": result.confirm = true
    of "--target":
      if i + 1 >= args.len:
        raise newException(ValueError, "--target requires a PATH")
      result.target = args[i + 1]; inc i
    of "--device":
      if i + 1 >= args.len:
        raise newException(ValueError, "--device requires a PATH")
      result.device = args[i + 1]; inc i
    of "--output":
      if i + 1 >= args.len:
        raise newException(ValueError, "--output requires a PATH")
      result.output = args[i + 1]; inc i
    of "--probe":
      if i + 1 >= args.len:
        raise newException(ValueError, "--probe requires a PATH")
      result.probe = args[i + 1]; inc i
    of "--size":
      if i + 1 >= args.len:
        raise newException(ValueError, "--size requires a value")
      result.sizeStr = args[i + 1]; inc i
    else:
      if a.startsWith("--target="):
        result.target = a["--target=".len .. ^1]
      elif a.startsWith("--device="):
        result.device = a["--device=".len .. ^1]
      elif a.startsWith("--output="):
        result.output = a["--output=".len .. ^1]
      elif a.startsWith("--probe="):
        result.probe = a["--probe=".len .. ^1]
      elif a.startsWith("--size="):
        result.sizeStr = a["--size=".len .. ^1]
      elif a.startsWith("--"):
        raise newException(ValueError,
          "unknown `repro disk " & $result.sub & "` flag: " & a)
      else:
        # First positional argument = source file path.
        if result.source.len > 0:
          raise newException(ValueError,
            "extra positional argument: " & a)
        result.source = a
    inc i

# ---------------------------------------------------------------------
# Subcommand handlers.
# ---------------------------------------------------------------------

const PendingNotice* =
  "M9.R.22b/c implementation pending — surface defined, operation " &
  "will be implemented in a follow-up milestone."

proc runDiskPlan(opts: DiskCliOptions): int =
  if opts.source.len == 0:
    stderr.writeLine("repro disk plan: missing source file argument\n" &
      "usage: repro disk plan <disko.nim>")
    return 2
  let outcome = loadDiskoFromSource(opts.source)
  if outcome.failure:
    stderr.writeLine("repro disk plan: " & outcome.failureMsg)
    case outcome.failureKind
    of dpfMissingFile, dpfNoDisko: return 2
    of dpfCompileFailed, dpfRunFailed, dpfParseFailed: return 1
  stdout.write outcome.text
  return 0

proc runDiskApply(opts: DiskCliOptions): int =
  if opts.source.len == 0:
    stderr.writeLine("repro disk apply: missing source file argument\n" &
      "usage: repro disk apply <disko.nim> [--device DEV] --confirm")
    return 2
  if not opts.confirm:
    # --confirm is the explicit destructive opt-in. Print the plan
    # the user is about to run and abort with exit-2 so it's
    # impossible to wipe a disk on a typo.
    let outcome = loadDiskoFromSource(opts.source)
    if outcome.failure:
      stderr.writeLine("repro disk apply: " & outcome.failureMsg)
      return 2
    stderr.writeLine("repro disk apply: refusing to run destructive " &
      "operation without --confirm")
    stderr.writeLine("Planned operations (re-run with --confirm to " &
      "execute):")
    stderr.writeLine(outcome.text)
    return 2
  # --confirm given: load the layout + run the apply driver.
  let outcome = loadDiskoFromSource(opts.source)
  if outcome.failure:
    stderr.writeLine("repro disk apply: " & outcome.failureMsg)
    case outcome.failureKind
    of dpfMissingFile, dpfNoDisko: return 2
    of dpfCompileFailed, dpfRunFailed, dpfParseFailed: return 1
  let dl = outcome.spec.disko.get()
  # --target / --device scoping: when --device is set, only operate
  # on that one disk (safety guard against typos in a multi-disk
  # disko.nim).
  var scoped: DiskLayout
  if opts.device.len > 0:
    var found = false
    for diskName, d in dl.disks:
      if d.device == opts.device:
        scoped.disks[diskName] = d
        found = true
    if not found:
      stderr.writeLine("repro disk apply: --device " & opts.device &
        " does not match any disk in " & opts.source)
      stderr.writeLine("Available devices:")
      for _, d in dl.disks:
        stderr.writeLine("  " & d.device)
      return 2
    # Scope ZFS pools too: keep only the pools whose devices all
    # match the scoped disks.
    for pool in dl.pools:
      var allMatch = true
      for pd in pool.devices:
        if pd != opts.device:
          allMatch = false; break
      if allMatch: scoped.pools.add pool
  else:
    scoped = dl
  let passphrases = initTable[string, string]()
  let r = applyDiskLayout(scoped, passphrases)
  # Log every operation that ran so the user can audit.
  for op in r.operations:
    stderr.writeLine("[apply] " & op.tool & ": " & op.cmd &
      " (exit " & $op.exit & ")")
  if r.failure:
    stderr.writeLine("repro disk apply: FAILED at step " &
      r.failureStep & " — " & r.failureMsg)
    return 1
  stderr.writeLine("repro disk apply: OK (" & $r.operations.len &
    " operations)")
  return 0

proc runDiskMount(opts: DiskCliOptions): int =
  if opts.source.len == 0 or opts.target.len == 0:
    stderr.writeLine("repro disk mount: missing arguments\n" &
      "usage: repro disk mount <disko.nim> --target /mnt")
    return 2
  let outcome = loadDiskoFromSource(opts.source)
  if outcome.failure:
    stderr.writeLine("repro disk mount: " & outcome.failureMsg)
    return 2
  let dl = outcome.spec.disko.get()
  let plan = collectMountPlan(dl, opts.target)
  stderr.writeLine("repro disk mount: " & $plan.len & " entries")
  for (dev, mp) in plan:
    stderr.writeLine("  " & dev & " -> " & mp)
  # Actually mount when --confirm is set; otherwise plan-only.
  if opts.confirm:
    discard mountDiskLayout(dl, opts.target)
    stderr.writeLine("repro disk mount: mounted " & $plan.len &
      " entries under " & opts.target)
  return 0

proc runDiskUnmount(opts: DiskCliOptions): int =
  if opts.source.len == 0 or opts.target.len == 0:
    stderr.writeLine("repro disk unmount: missing arguments\n" &
      "usage: repro disk unmount <disko.nim> --target /mnt")
    return 2
  let outcome = loadDiskoFromSource(opts.source)
  if outcome.failure:
    stderr.writeLine("repro disk unmount: " & outcome.failureMsg)
    return 2
  let dl = outcome.spec.disko.get()
  let plan = collectMountPlan(dl, opts.target)
  stderr.writeLine("repro disk unmount: " & $plan.len & " entries")
  unmountDiskLayout(plan)
  return 0

proc runDiskGenerate(opts: DiskCliOptions): int =
  let probeRoot = if opts.probe.len > 0: opts.probe else: "/"
  stderr.writeLine("repro disk generate: " & PendingNotice)
  stderr.writeLine("  probe root: " & probeRoot)
  return 2

proc runDiskImage(opts: DiskCliOptions): int =
  if opts.source.len == 0 or opts.output.len == 0:
    stderr.writeLine("repro disk image: missing arguments\n" &
      "usage: repro disk image <disko.nim> --output PATH --size SIZE")
    return 2
  stderr.writeLine("repro disk image: " & PendingNotice)
  stderr.writeLine("  source: " & opts.source)
  stderr.writeLine("  output: " & opts.output)
  if opts.sizeStr.len > 0:
    stderr.writeLine("  size:   " & opts.sizeStr)
  return 2

proc renderDiskUsage(): string =
  "usage: repro disk {plan|apply|mount|unmount|generate|image} ...\n" &
  "  repro disk plan <disko.nim>            (v1: full)\n" &
  "  repro disk apply <disko.nim> --confirm [--device DEV] (M9.R.22b: full)\n" &
  "  repro disk mount <disko.nim> --target /mnt [--confirm] (M9.R.22b: full)\n" &
  "  repro disk unmount <disko.nim> --target /mnt (M9.R.22b: full)\n" &
  "  repro disk generate --probe /          (M9.R.22c: pending)\n" &
  "  repro disk image <disko.nim> --output PATH --size SIZE   (M9.R.22c: pending)\n"

proc runDiskCommand*(args: seq[string]): int =
  ## ``repro disk <subcommand>`` dispatcher.
  let opts =
    try: parseDiskArgs(args)
    except ValueError as e:
      stderr.writeLine("repro disk: " & e.msg)
      stderr.writeLine(renderDiskUsage())
      return 2
  case opts.sub
  of dscNone:
    stderr.writeLine(renderDiskUsage())
    return 2
  of dscPlan:     return runDiskPlan(opts)
  of dscApply:    return runDiskApply(opts)
  of dscMount:    return runDiskMount(opts)
  of dscUnmount:  return runDiskUnmount(opts)
  of dscGenerate: return runDiskGenerate(opts)
  of dscImage:    return runDiskImage(opts)
