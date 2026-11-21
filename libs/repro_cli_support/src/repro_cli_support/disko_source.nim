## The library half of ``repro disk``: load a disko layout from a
## ``hardware "<id>":`` Nim source (or its pre-computed JSON) and render
## the human-readable plan.
##
## Kept apart from ``disk.nim`` -- which holds the command handlers and
## takes its command line from repro's description -- so that importing it
## does not import repro's command-line program. The ReproOS Anywhere
## storage broker (reproos ``tools/anywhere/anywhere_disk.nim``) compiles
## this module, ``infra_install_root`` and ``repro_profile`` into a
## RAM-resident installer without the rest of repro; an import of
## ``cli_program`` here or there breaks that build.

import std/[options, os, osproc, strutils, tables, tempfiles]

import repro_profile/emit
import repro_profile/types

from repro_core/source_root import resolveReprobuildSourceRoot

proc diskoCompilerRoot*(): string =
  ## Locate the reprobuild sources needed when compiling a user-authored
  ## ``hardware.nim`` file. The command may be invoked from any working
  ## directory, so the process cwd is only a fallback.
  ##
  ## Resolved by `resolveReprobuildSourceRoot`, the resolver every
  ## post-install compile uses. This used to try `$REPROBUILD_SOURCE_ROOT`
  ## and then the checkout this module was COMPILED in
  ## (``currentSourcePath()``), which for a released engine is the release
  ## job's checkout: a dead path on the user's machine, so an installed
  ## archive without that variable never reached the ``share/repro/source``
  ## it ships, and a binary copied out of a checkout silently compiled
  ## against whatever that checkout held now.
  proc hasProfileSources(root: string): bool =
    dirExists(root / "libs" / "repro_profile" / "src")

  let resolved = resolveReprobuildSourceRoot()
  if hasProfileSources(resolved):
    return resolved
  getCurrentDir()

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
  ##
  ## M9.R.24.2 -- if ``diskoNim`` ends in ``.json``, skip the ``nim r``
  ## compile step and parse the file directly as a pre-computed
  ## SystemHardwareSpec JSON. Lets the reproos-installer's --automated
  ## path run on the live ISO without bundling a Nim toolchain.
  if not fileExists(diskoNim):
    result.failure = true
    result.failureKind = dpfMissingFile
    result.failureMsg = "no such file: " & diskoNim
    return
  var jsonLine = ""
  if diskoNim.endsWith(".json"):
    # Pre-computed JSON path -- read the file directly.
    try:
      jsonLine = readFile(diskoNim).strip()
    except CatchableError as e:
      result.failure = true
      result.failureKind = dpfRunFailed
      result.failureMsg = "read " & diskoNim & " failed: " & e.msg
      return
  else:
    let repoRoot = diskoCompilerRoot()
    let nimcache = createTempDir("repro-disk-nimcache-", "")
    defer: removeDir(nimcache)
    var pathArgs = " --path:" & quoteShell(getCurrentDir())
    if repoRoot != getCurrentDir():
      pathArgs.add " --path:" & quoteShell(repoRoot)
    let libsRoot = repoRoot / "libs"
    if dirExists(libsRoot):
      for kind, path in walkDir(libsRoot):
        if kind == pcDir and dirExists(path / "src"):
          pathArgs.add " --path:" & quoteShell(path / "src")
    let cmd = "nim r --hints:off --warnings:off --verbosity:0" &
      " --nimcache:" & quoteShell(nimcache) &
      pathArgs & " " & quoteShell(absolutePath(diskoNim))
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      result.failure = true
      result.failureKind = dpfCompileFailed
      result.failureMsg = "nim r failed (exit " & $exitCode & "):\n" & output
      return
    # The hardware macro emits JSON on the last non-empty stdout line.
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
