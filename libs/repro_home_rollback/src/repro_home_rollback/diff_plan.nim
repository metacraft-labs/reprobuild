## Diff the CURRENT activation manifest against the TARGET activation
## manifest and produce an ordered list of revert operations the
## rollback executor walks.
##
## Per `Home-Profile-Generations-And-State.md` "Rollback":
##
##   * Files present in current but NOT in target -> remove.
##   * Files present in target but NOT in current -> restore.
##   * Files present in both with different `postWriteDigest` -> update
##     (overwrite live target with target manifest's content).
##   * Same logic applies to `ManagedBlock` records (keyed by
##     `(hostFilePath, blockId)`) and `ExportedCommand` records
##     (keyed by `commandName`).
##   * `RealizedPackage` records are NOT operated on directly: rollback
##     does NOT uninstall packages. Eager GC reclaims unreferenced
##     prefixes only after retention drops a generation. The diff
##     simply tracks the target's `realizedPrefixIds` so the new
##     pointer reflects the right set.
##
## Plan ordering: removes first (so a "remove then restore" sequence
## on the SAME path frees disk before re-creating), then restores,
## then updates. Within each bucket, lexicographic by primary key
## (path / `(hostFilePath, blockId)` / commandName). This determinism
## is required so two rollback runs of the same (current, target)
## pair execute the same op sequence — gates can pin the exact order
## as a regression check.

import std/[algorithm, tables]

import repro_home_generations

# ---------------------------------------------------------------------------
# Operation kinds.
# ---------------------------------------------------------------------------

type
  RollbackOpKind* = enum
    rokRemoveFile = "remove-file"
    rokRestoreFile = "restore-file"
    rokUpdateFile = "update-file"
    rokRemoveBlock = "remove-block"
    rokRestoreBlock = "restore-block"
    rokUpdateBlock = "update-block"
    rokRemoveLauncher = "remove-launcher"
    rokRestoreLauncher = "restore-launcher"
    rokUpdateLauncher = "update-launcher"
    rokRemoveResource = "remove-resource"
    rokRestoreResource = "restore-resource"
    rokUpdateResource = "update-resource"

  FileOp* = object
    kind*: RollbackOpKind              ## rokRemove/Restore/UpdateFile
    absoluteOutputPath*: string
    ## For Remove + Update: the CURRENT manifest's record (drives the
    ## drift check).
    currentRecord*: GeneratedFile
    hasCurrentRecord*: bool
    ## For Restore + Update: the TARGET manifest's record (drives the
    ## restored content).
    targetRecord*: GeneratedFile
    hasTargetRecord*: bool

  BlockOp* = object
    kind*: RollbackOpKind              ## rokRemove/Restore/UpdateBlock
    hostFilePath*: string
    blockId*: string
    currentRecord*: ManagedBlock
    hasCurrentRecord*: bool
    targetRecord*: ManagedBlock
    hasTargetRecord*: bool

  LauncherOp* = object
    kind*: RollbackOpKind              ## rokRemove/Restore/UpdateLauncher
    commandName*: string
    currentRecord*: ExportedCommand
    hasCurrentRecord*: bool
    targetRecord*: ExportedCommand
    hasTargetRecord*: bool

  ResourceOp* = object
    ## M68 resource lifecycle op for rollback. Mirrors the file /
    ## block / launcher shape: kind drives the action, current/
    ## target records drive the digest check and the restore
    ## content.
    kind*: RollbackOpKind              ## rokRemove/Restore/UpdateResource
    address*: string
    currentRecord*: ResourceBinding
    hasCurrentRecord*: bool
    targetRecord*: ResourceBinding
    hasTargetRecord*: bool

  RollbackPlan* = object
    ## The full ordered list of revert operations.
    ##
    ## All three op lists are pre-ordered (removes -> restores ->
    ## updates within each category, lex-sorted within each bucket).
    ## The executor walks files first, then blocks, then launchers,
    ## then rotates `current`.
    fileOps*: seq[FileOp]
    blockOps*: seq[BlockOp]
    launcherOps*: seq[LauncherOp]
    resourceOps*: seq[ResourceOp]
      ## M68: per-resource revert operations. Same remove ->
      ## restore -> update ordering as the file / block / launcher
      ## lists.
    ## `targetRealizedPrefixIds` is copied from the target pointer
    ## envelope verbatim and re-installed by the executor when it
    ## writes the new pointer. Rollback never uninstalls packages, so
    ## this list drives ONLY the new pointer's `realizedPrefixIds`
    ## (and via that the store-GC live set).
    targetRealizedPrefixIds*: seq[Digest256]

# ---------------------------------------------------------------------------
# Internal: build keyed tables for set/diff math.
# ---------------------------------------------------------------------------

proc filesByPath(manifest: ActivationManifest): Table[string, GeneratedFile] =
  result = initTable[string, GeneratedFile]()
  for f in manifest.generatedFiles:
    result[f.absoluteOutputPath] = f

proc blocksByKey(manifest: ActivationManifest):
    Table[string, ManagedBlock] =
  ## Key = "hostFilePath\x1ablockId". The intermediate \x1a (SUB) byte
  ## cannot legally appear in a managed-block path or id, so the
  ## composite key is collision-free.
  result = initTable[string, ManagedBlock]()
  for b in manifest.managedBlocks:
    result[b.hostFilePath & "\x1a" & b.blockId] = b

proc launchersByName(manifest: ActivationManifest):
    Table[string, ExportedCommand] =
  result = initTable[string, ExportedCommand]()
  for ec in manifest.exportedCommands:
    result[ec.commandName] = ec

proc resourcesByAddress(manifest: ActivationManifest):
    Table[string, ResourceBinding] =
  result = initTable[string, ResourceBinding]()
  for rb in manifest.resourceBindings:
    # Only consider records carrying the M68 typed fields (V2);
    # V1 records (M62 reserved-empty stubs) have an empty kind tag
    # and are skipped here so rollback doesn't synthesize ops for
    # them.
    if rb.resourceKind.len == 0:
      continue
    result[rb.resourceAddress] = rb

# ---------------------------------------------------------------------------
# Build the plan.
# ---------------------------------------------------------------------------

proc digestsDiffer(a, b: Digest256): bool =
  for i in 0 ..< 32:
    if a[i] != b[i]:
      return true
  false

proc buildRollbackPlan*(currentManifest, targetManifest: ActivationManifest;
                       targetEnvelope: PointerEnvelope): RollbackPlan =
  ## Compute the ordered revert plan. Pure function; does not touch
  ## the live filesystem.
  let curFiles = filesByPath(currentManifest)
  let tgtFiles = filesByPath(targetManifest)
  let curBlocks = blocksByKey(currentManifest)
  let tgtBlocks = blocksByKey(targetManifest)
  let curLaunchers = launchersByName(currentManifest)
  let tgtLaunchers = launchersByName(targetManifest)

  # Files.
  var removes, restores, updates: seq[FileOp]
  for path, rec in curFiles:
    if path notin tgtFiles:
      removes.add(FileOp(kind: rokRemoveFile,
        absoluteOutputPath: path,
        currentRecord: rec, hasCurrentRecord: true,
        hasTargetRecord: false))
  for path, rec in tgtFiles:
    if path notin curFiles:
      restores.add(FileOp(kind: rokRestoreFile,
        absoluteOutputPath: path,
        hasCurrentRecord: false,
        targetRecord: rec, hasTargetRecord: true))
    else:
      let cur = curFiles[path]
      if digestsDiffer(cur.postWriteDigest, rec.postWriteDigest) or
         cur.ownershipPolicy != rec.ownershipPolicy:
        updates.add(FileOp(kind: rokUpdateFile,
          absoluteOutputPath: path,
          currentRecord: cur, hasCurrentRecord: true,
          targetRecord: rec, hasTargetRecord: true))
  removes.sort(proc(a, b: FileOp): int = cmp(a.absoluteOutputPath, b.absoluteOutputPath))
  restores.sort(proc(a, b: FileOp): int = cmp(a.absoluteOutputPath, b.absoluteOutputPath))
  updates.sort(proc(a, b: FileOp): int = cmp(a.absoluteOutputPath, b.absoluteOutputPath))
  result.fileOps = removes & restores & updates

  # Managed blocks.
  var bRemoves, bRestores, bUpdates: seq[BlockOp]
  for key, rec in curBlocks:
    if key notin tgtBlocks:
      bRemoves.add(BlockOp(kind: rokRemoveBlock,
        hostFilePath: rec.hostFilePath, blockId: rec.blockId,
        currentRecord: rec, hasCurrentRecord: true,
        hasTargetRecord: false))
  for key, rec in tgtBlocks:
    if key notin curBlocks:
      bRestores.add(BlockOp(kind: rokRestoreBlock,
        hostFilePath: rec.hostFilePath, blockId: rec.blockId,
        hasCurrentRecord: false,
        targetRecord: rec, hasTargetRecord: true))
    else:
      let cur = curBlocks[key]
      var blockDiffers = cur.postWriteBlockBytes.len != rec.postWriteBlockBytes.len
      if not blockDiffers:
        for i in 0 ..< cur.postWriteBlockBytes.len:
          if cur.postWriteBlockBytes[i] != rec.postWriteBlockBytes[i]:
            blockDiffers = true
            break
      if blockDiffers or digestsDiffer(cur.postWriteFileDigest,
          rec.postWriteFileDigest):
        bUpdates.add(BlockOp(kind: rokUpdateBlock,
          hostFilePath: rec.hostFilePath, blockId: rec.blockId,
          currentRecord: cur, hasCurrentRecord: true,
          targetRecord: rec, hasTargetRecord: true))
  proc blockKey(op: BlockOp): string = op.hostFilePath & "\x1a" & op.blockId
  bRemoves.sort(proc(a, b: BlockOp): int = cmp(blockKey(a), blockKey(b)))
  bRestores.sort(proc(a, b: BlockOp): int = cmp(blockKey(a), blockKey(b)))
  bUpdates.sort(proc(a, b: BlockOp): int = cmp(blockKey(a), blockKey(b)))
  result.blockOps = bRemoves & bRestores & bUpdates

  # Launchers.
  var lRemoves, lRestores, lUpdates: seq[LauncherOp]
  for name, rec in curLaunchers:
    if name notin tgtLaunchers:
      lRemoves.add(LauncherOp(kind: rokRemoveLauncher,
        commandName: name,
        currentRecord: rec, hasCurrentRecord: true,
        hasTargetRecord: false))
  for name, rec in tgtLaunchers:
    if name notin curLaunchers:
      lRestores.add(LauncherOp(kind: rokRestoreLauncher,
        commandName: name,
        hasCurrentRecord: false,
        targetRecord: rec, hasTargetRecord: true))
    else:
      let cur = curLaunchers[name]
      if digestsDiffer(cur.launchPlanDigest, rec.launchPlanDigest) or
         cur.binDirArtifactKind != rec.binDirArtifactKind or
         cur.binDirRelativePath != rec.binDirRelativePath:
        lUpdates.add(LauncherOp(kind: rokUpdateLauncher,
          commandName: name,
          currentRecord: cur, hasCurrentRecord: true,
          targetRecord: rec, hasTargetRecord: true))
  lRemoves.sort(proc(a, b: LauncherOp): int = cmp(a.commandName, b.commandName))
  lRestores.sort(proc(a, b: LauncherOp): int = cmp(a.commandName, b.commandName))
  lUpdates.sort(proc(a, b: LauncherOp): int = cmp(a.commandName, b.commandName))
  result.launcherOps = lRemoves & lRestores & lUpdates

  # M68: Resources.
  let curResources = resourcesByAddress(currentManifest)
  let tgtResources = resourcesByAddress(targetManifest)
  var rRemoves, rRestores, rUpdates: seq[ResourceOp]
  proc resourceContentDiffers(a, b: ResourceBinding): bool =
    if a.payloadBytes.len != b.payloadBytes.len: return true
    for i in 0 ..< a.payloadBytes.len:
      if a.payloadBytes[i] != b.payloadBytes[i]: return true
    if digestsDiffer(a.postWriteDigest, b.postWriteDigest): return true
    if a.resourceKind != b.resourceKind: return true
    false
  for addr1, rec in curResources:
    if addr1 notin tgtResources:
      rRemoves.add(ResourceOp(kind: rokRemoveResource,
        address: addr1,
        currentRecord: rec, hasCurrentRecord: true,
        hasTargetRecord: false))
  for addr1, rec in tgtResources:
    if addr1 notin curResources:
      rRestores.add(ResourceOp(kind: rokRestoreResource,
        address: addr1,
        hasCurrentRecord: false,
        targetRecord: rec, hasTargetRecord: true))
    else:
      let cur = curResources[addr1]
      if resourceContentDiffers(cur, rec):
        rUpdates.add(ResourceOp(kind: rokUpdateResource,
          address: addr1,
          currentRecord: cur, hasCurrentRecord: true,
          targetRecord: rec, hasTargetRecord: true))
  rRemoves.sort(proc(a, b: ResourceOp): int = cmp(a.address, b.address))
  rRestores.sort(proc(a, b: ResourceOp): int = cmp(a.address, b.address))
  rUpdates.sort(proc(a, b: ResourceOp): int = cmp(a.address, b.address))
  result.resourceOps = rRemoves & rRestores & rUpdates

  # Realized prefix ids come from the target pointer verbatim.
  result.targetRealizedPrefixIds = targetEnvelope.realizedPrefixIds

# ---------------------------------------------------------------------------
# Summaries.
# ---------------------------------------------------------------------------

proc isEmpty*(plan: RollbackPlan): bool =
  plan.fileOps.len == 0 and plan.blockOps.len == 0 and
    plan.launcherOps.len == 0 and plan.resourceOps.len == 0
