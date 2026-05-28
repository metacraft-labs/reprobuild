## Rollback orchestrator. The reverse of M63's apply pipeline:
##
##   1. Acquire `apply.lock`.
##   2. Load CURRENT pointer + activation manifest from CAS.
##   3. Resolve TARGET generation id (explicit arg, prefix match, or
##      "the immediately previous one").
##   4. Load TARGET pointer + activation manifest from CAS.
##   5. Build the diff plan (`diff_plan.nim`).
##   6. Walk the plan, digest-checking every record before its
##      destructive op. Raise `EUserEditDetected` unless
##      `--accept-overwrite` was passed.
##   7. Execute the plan:
##        a. Remove files / blocks / launchers no longer in target.
##        b. Restore + Update from target (reading content bytes from
##           CAS via `storeContentHash`).
##   8. Rotate `current` to the target generation.
##   9. Touch the target generation directory's mtime to record the
##      re-activation time.
##  10. Release the lock.

import std/[algorithm, os, strutils, times]
from repro_core/paths import extendedPath

import repro_home_apply
import repro_home_generations
import repro_home_intent
import repro_home_resources
import repro_launch_plan
import repro_local_store

import ./diff_plan
import ./digest_check
import ./errors

const
  AcceptOverwriteEnvVar* = "REPRO_HOME_ROLLBACK_ACCEPT_OVERWRITE"
    ## Test/operator override that toggles `--accept-overwrite` without
    ## requiring the CLI plumbing. Reserved; the public CLI flag is the
    ## supported surface.

type
  RollbackOptions* = object
    stateDir*: string                  ## "" -> resolveStateDir()
    storeRoot*: string                 ## "" -> resolveStoreRoot()
    host*: string                      ## "" -> currentHost()
    homeDir*: string                   ## "" -> getHomeDir()
    targetGenerationId*: string        ## "" -> "the immediately previous"
    acceptOverwrite*: bool
    activationTimestamp*: int64        ## 0 -> getTime().toUnix

  RollbackOutcome* = object
    fromGenerationIdHex*: string       ## the generation we rolled FROM
    toGenerationIdHex*: string         ## the generation we rolled TO
    fileOpsApplied*: int
    blockOpsApplied*: int
    launcherOpsApplied*: int
    resourceOpsApplied*: int           ## M68 resource ops
    driftedPaths*: seq[string]         ## drift surface; populated only
                                       ## when --accept-overwrite was
                                       ## passed and the executor
                                       ## clobbered a drifted record

# ---------------------------------------------------------------------------
# Option resolution.
# ---------------------------------------------------------------------------

proc resolveOptions(opts: RollbackOptions): RollbackOptions =
  result = opts
  if result.stateDir.len == 0:
    result.stateDir = resolveStateDir()
  if result.storeRoot.len == 0:
    result.storeRoot = resolveStoreRoot()
  if result.host.len == 0:
    result.host = currentHost()
  if result.homeDir.len == 0:
    result.homeDir = getHomeDir()
  if result.activationTimestamp == 0:
    result.activationTimestamp = getTime().toUnix

proc userPathHostFromIdentity(resourceId: string): string =
  when defined(windows):
    ""
  else:
    let hash = resourceId.rfind('#')
    if hash > 0:
      resourceId[0 ..< hash]
    else:
      ""

# ---------------------------------------------------------------------------
# Generation-id resolution.
# ---------------------------------------------------------------------------

proc listGenerationIds(stateDir: string): seq[string] =
  let root = generationsRoot(stateDir)
  if not dirExists(extendedPath(root)):
    return @[]
  for kind, entry in walkDir(extendedPath(root), relative = false):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let leaf = extractFilename(entry)
    if leaf.startsWith("."):
      continue
    let p = entry / PointerFileName
    if fileExists(extendedPath(p)):
      result.add(leaf)

proc resolveTargetId(stateDir, currentId, requested: string): string =
  ## If `requested` is empty, return the immediately previous
  ## generation id (the second-most-recent by activation timestamp).
  ## Otherwise resolve a full or prefix match.
  if requested.len == 0:
    let all = enumerateGenerations(stateDir)
    if all.len <= 1:
      raiseNoPreviousGeneration()
    # `enumerateGenerations` returns oldest-first. The active one is
    # the most recent; "previous" is the one immediately before it
    # by activation timestamp. If `current` happens not to point at
    # the newest entry (a partial recovery state), we still pick the
    # newest entry that ISN'T the current one — that's the most
    # natural "go back one step".
    var ordered: seq[string]
    for rec in all:
      ordered.add(rec.generationId)
    # newest first
    ordered.reverse()
    for id in ordered:
      if id != currentId:
        return id
    raiseNoPreviousGeneration()
  let allIds = listGenerationIds(stateDir)
  # Exact-match first.
  for id in allIds:
    if id == requested:
      return id
  # Prefix match. Must be unambiguous.
  var matches: seq[string]
  for id in allIds:
    if id.startsWith(requested):
      matches.add(id)
  if matches.len == 0:
    raiseUnknownGeneration(requested, allIds)
  if matches.len > 1:
    matches.sort()
    raiseAmbiguousGeneration(requested, matches)
  result = matches[0]

# ---------------------------------------------------------------------------
# Manifest loading.
# ---------------------------------------------------------------------------

proc digestToPrefixId(d: Digest256): PrefixIdBytes =
  for i in 0 ..< 32:
    result[i] = d[i]

proc digestFromKey(key: PrefixIdBytes): Digest256 =
  for i in 0 ..< 32:
    result[i] = key[i]

proc loadManifestFor(stateDir: string; generationId: string;
                    store: var Store):
    tuple[envelope: PointerEnvelope; manifest: ActivationManifest] =
  let pointerFile = pointerPath(stateDir, generationId)
  if not fileExists(extendedPath(pointerFile)):
    raiseUnknownGeneration(generationId, listGenerationIds(stateDir))
  result.envelope = readPointerFile(pointerFile)
  let manifestKey = digestToPrefixId(result.envelope.activationManifestDigest)
  let manifestBytes = readCasBlob(store, manifestKey)
  result.manifest = decodeManifestBytes(manifestBytes)

# ---------------------------------------------------------------------------
# Drift-checking pass.
# ---------------------------------------------------------------------------

proc checkPlanForDrift*(plan: RollbackPlan; stateDir, currentGenIdHex: string):
    seq[string] =
  ## Walk every destructive op and verify the on-disk state matches
  ## the CURRENT manifest's recorded post-write digest. Returns the
  ## list of paths that drifted, in operation order.
  ##
  ## "Destructive" = `rokRemove*` (we're about to delete the live
  ## bytes) and `rokUpdate*` (we're about to overwrite them).
  ## `rokRestore*` is not destructive — it writes a file that the
  ## current manifest does not claim to own, so any pre-existing
  ## bytes there are user-owned and rollback refuses to clobber them
  ## anyway (handled at execution time).
  for op in plan.fileOps:
    case op.kind
    of rokRemoveFile, rokUpdateFile:
      if not op.hasCurrentRecord:
        continue
      let r = verifyFileAgainstCurrent(op.currentRecord)
      if r.drifted:
        result.add(op.absoluteOutputPath)
    else:
      discard
  for op in plan.blockOps:
    case op.kind
    of rokRemoveBlock, rokUpdateBlock:
      if not op.hasCurrentRecord:
        continue
      let r = verifyManagedBlockAgainstCurrent(op.currentRecord)
      if r.drifted:
        result.add(op.hostFilePath & "#" & op.blockId)
    else:
      discard
  for op in plan.launcherOps:
    case op.kind
    of rokRemoveLauncher, rokUpdateLauncher:
      if not op.hasCurrentRecord:
        continue
      let r = verifyLauncherAgainstCurrent(stateDir, currentGenIdHex,
        op.currentRecord)
      if r.drifted:
        result.add("launcher:" & op.commandName)
    else:
      discard

proc raiseFirstDrift*(plan: RollbackPlan;
                     stateDir, currentGenIdHex: string) =
  ## Walk the same ops as `checkPlanForDrift` but raise on the first
  ## drift hit, populating `EUserEditDetected` with structured
  ## context. Used when `--accept-overwrite` is NOT set.
  for op in plan.fileOps:
    case op.kind
    of rokRemoveFile, rokUpdateFile:
      if not op.hasCurrentRecord: continue
      let r = verifyFileAgainstCurrent(op.currentRecord)
      if r.drifted:
        raiseUserEditDetected(op.absoluteOutputPath, "generated-file",
          r.expectedHex, r.observedHex)
    else: discard
  for op in plan.blockOps:
    case op.kind
    of rokRemoveBlock, rokUpdateBlock:
      if not op.hasCurrentRecord: continue
      let r = verifyManagedBlockAgainstCurrent(op.currentRecord)
      if r.drifted:
        raiseUserEditDetected(op.hostFilePath & "#" & op.blockId,
          "managed-block", r.expectedHex, r.observedHex)
    else: discard
  for op in plan.launcherOps:
    case op.kind
    of rokRemoveLauncher, rokUpdateLauncher:
      if not op.hasCurrentRecord: continue
      let r = verifyLauncherAgainstCurrent(stateDir, currentGenIdHex,
        op.currentRecord)
      if r.drifted:
        raiseUserEditDetected("launcher:" & op.commandName, "launcher",
          r.expectedHex, r.observedHex)
    else: discard

# ---------------------------------------------------------------------------
# Execution helpers.
# ---------------------------------------------------------------------------

proc bytesFromString(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ord(ch))

proc stringFromBytes(b: openArray[byte]): string =
  result = newString(b.len)
  for i, v in b:
    result[i] = char(v)

proc atomicWriteBytes(dst: string; content: openArray[byte]) =
  let parent = parentDir(dst)
  if parent.len > 0:
    createDir(extendedPath(parent))
  let tmp = dst & ".repro.tmp"
  writeFile(extendedPath(tmp), stringFromBytes(content))
  if fileExists(extendedPath(dst)):
    try: removeFile(extendedPath(dst)) except OSError: discard
  moveFile(extendedPath(tmp), extendedPath(dst))

proc removeFileIfPresent(path: string) =
  if symlinkExists(extendedPath(path)) or fileExists(extendedPath(path)):
    try: removeFile(extendedPath(path)) except OSError: discard

proc loadContentBytes(store: var Store; rec: GeneratedFile): seq[byte] =
  ## Pull a file's content bytes back out of the CAS using the
  ## manifest's recorded `storeContentHash`. The apply pipeline seals
  ## the bytes there at write time (see `pipeline.nim` step 8).
  let key = digestToPrefixId(rec.storeContentHash)
  try:
    result = readCasBlob(store, key)
  except CatchableError:
    raiseContentMissing(digestHex(rec.storeContentHash), rec.absoluteOutputPath)

proc restoreFileFromTarget(store: var Store; rec: GeneratedFile;
                          homeDir: string) =
  ## Restore one generated-file record by reading its bytes from CAS
  ## and writing them through the standard staging-then-rename
  ## protocol. Stow-symlink / stow-junction records re-create the
  ## link (where possible) pointing at the recorded stow source.
  case rec.ownershipPolicy
  of gfoStowSymlink:
    removeFileIfPresent(rec.absoluteOutputPath)
    let parent = parentDir(rec.absoluteOutputPath)
    if parent.len > 0:
      createDir(extendedPath(parent))
    if rec.stowSource.len > 0 and fileExists(extendedPath(rec.stowSource)):
      try:
        createSymlink(extendedPath(rec.stowSource), extendedPath(rec.absoluteOutputPath))
      except OSError:
        # Symlink unavailable; fall back to a CAS-content copy.
        let bytes = loadContentBytes(store, rec)
        atomicWriteBytes(rec.absoluteOutputPath, bytes)
    else:
      let bytes = loadContentBytes(store, rec)
      atomicWriteBytes(rec.absoluteOutputPath, bytes)
  of gfoStowJunction:
    # Junction restore is best-effort cross-platform; fall back to a
    # copy of the recorded bytes.
    let bytes = loadContentBytes(store, rec)
    atomicWriteBytes(rec.absoluteOutputPath, bytes)
  of gfoOwned, gfoMerged, gfoExistingPreserved, gfoStowCopy:
    let bytes = loadContentBytes(store, rec)
    atomicWriteBytes(rec.absoluteOutputPath, bytes)

# ---- Managed-block restoration ----

proc rewriteManagedBlock(hostFilePath, blockId: string;
                        blockBytes: openArray[byte]) =
  ## Re-insert `blockBytes` between the sentinels in the host file
  ## (creating the file if missing). Mirrors the writer in
  ## `repro_home_apply/materialize_managed_blocks.nim`.
  let parent = parentDir(hostFilePath)
  if parent.len > 0:
    createDir(extendedPath(parent))
  var existing = ""
  if fileExists(extendedPath(hostFilePath)):
    existing = readFile(extendedPath(hostFilePath))
  let openS = OpenSentinelPrefix & blockId & OpenSentinelSuffix
  let closeS = CloseSentinelPrefix & blockId & CloseSentinelSuffix
  let openIdx = existing.find(openS)
  let closeIdx = existing.find(closeS)
  let bodyText = stringFromBytes(blockBytes)
  var rewritten = ""
  if openIdx >= 0 and closeIdx >= 0 and closeIdx > openIdx:
    let lineEndAfterOpen = existing.find('\n', openIdx)
    let bodyStart = if lineEndAfterOpen >= 0: lineEndAfterOpen + 1
                    else: openIdx + openS.len
    rewritten = existing[0 ..< bodyStart] & bodyText &
      (if bodyText.len > 0 and not bodyText.endsWith("\n"): "\n" else: "") &
      existing[closeIdx .. ^1]
  else:
    let sep = if existing.len == 0 or existing.endsWith("\n"): "" else: "\n"
    rewritten = existing & sep & openS & "\n" & bodyText &
      (if bodyText.len > 0 and not bodyText.endsWith("\n"): "\n" else: "") &
      closeS & "\n"
  let tmp = hostFilePath & ".repro.tmp"
  writeFile(extendedPath(tmp), rewritten)
  if fileExists(extendedPath(hostFilePath)):
    try: removeFile(extendedPath(hostFilePath)) except OSError: discard
  moveFile(extendedPath(tmp), extendedPath(hostFilePath))

proc removeManagedBlock(hostFilePath, blockId: string) =
  ## Strip the sentinel-delimited region (and the sentinel lines)
  ## from the host file. Leaves the file alone if the sentinels are
  ## missing.
  if not fileExists(extendedPath(hostFilePath)):
    return
  let existing = readFile(extendedPath(hostFilePath))
  let openS = OpenSentinelPrefix & blockId & OpenSentinelSuffix
  let closeS = CloseSentinelPrefix & blockId & CloseSentinelSuffix
  let openIdx = existing.find(openS)
  let closeIdx = existing.find(closeS)
  if openIdx < 0 or closeIdx < 0 or closeIdx <= openIdx:
    return
  # Drop the open line, the body, the close line, and the trailing
  # newline if any.
  let openLineStart = block:
    var s = openIdx
    while s > 0 and existing[s - 1] != '\n':
      dec s
    s
  let closeLineEnd = block:
    var e = closeIdx + closeS.len
    if e < existing.len and existing[e] == '\n':
      inc e
    e
  let rewritten = existing[0 ..< openLineStart] & existing[closeLineEnd .. ^1]
  let tmp = hostFilePath & ".repro.tmp"
  writeFile(extendedPath(tmp), rewritten)
  if fileExists(extendedPath(hostFilePath)):
    try: removeFile(extendedPath(hostFilePath)) except OSError: discard
  moveFile(extendedPath(tmp), extendedPath(hostFilePath))

# ---- Launcher restoration ----

proc removeLauncherArtifact(stateDir, currentGenIdHex: string;
                           rec: ExportedCommand) =
  ## Drop the launcher artifact. On Windows: drop the .exe + sidecar
  ## AND the .cmd shim from the stable bin dir. On POSIX: drop the
  ## script from `<state-dir>/generations/<gen-id>/bin/`.
  when defined(windows):
    let stable = stateDir / "bin"
    let cmdExe = stable / (rec.commandName & ".exe")
    let sidecar = cmdExe & ".repro-launch"
    let cmdShim = stable / (rec.commandName & ".cmd")
    if fileExists(extendedPath(cmdExe)): removeFile(extendedPath(cmdExe))
    if fileExists(extendedPath(sidecar)): removeFile(extendedPath(sidecar))
    if fileExists(extendedPath(cmdShim)): removeFile(extendedPath(cmdShim))
  else:
    # POSIX launchers live inside immutable per-generation bin dirs.
    # Rolling away from a generation is just a `current` pointer move;
    # deleting from the source generation would corrupt it for a later
    # rollback-forward.
    discard stateDir
    discard currentGenIdHex
    discard rec

proc launchPlanDigestToKey(digest: Digest256): PrefixIdBytes =
  for i in 0 ..< 32:
    result[i] = digest[i]

proc materializeLauncherFromTarget(stateDir, targetGenIdHex: string;
                                   store: var Store;
                                   rec: ExportedCommand) =
  ## (Re-)materialize a launcher from the target generation. The
  ## target generation's per-generation bin dir was populated at the
  ## time it was the active generation; we mirror its bytes to the
  ## stable bin dir on Windows. On POSIX no work is needed because
  ## `rotateCurrent` flips the `current` symlink at the per-gen bin
  ## dir directly.
  let perGenBin = stateDir / "generations" / targetGenIdHex / "bin"
  when defined(windows):
    let stable = stateDir / "bin"
    createDir(extendedPath(stable))
    let cmdExe = perGenBin / (rec.commandName & ".exe")
    let cmdShim = perGenBin / (rec.commandName & ".cmd")
    let sidecar = cmdExe & ".repro-launch"
    if fileExists(extendedPath(cmdExe)):
      copyFile(extendedPath(cmdExe), extendedPath(stable / (rec.commandName & ".exe")))
      if fileExists(extendedPath(sidecar)):
        copyFile(extendedPath(sidecar), extendedPath(stable / (rec.commandName & ".exe.repro-launch")))
    elif fileExists(extendedPath(cmdShim)):
      copyFile(extendedPath(cmdShim), extendedPath(stable / (rec.commandName & ".cmd")))
  else:
    let scriptPath = perGenBin / rec.commandName
    if fileExists(extendedPath(scriptPath)):
      return
    createDir(extendedPath(perGenBin))
    var plan = loadLaunchPlan(store, launchPlanDigestToKey(
      rec.launchPlanDigest))
    plan.binding = when defined(macosx): lbkMacosScript else: lbkLinuxScript
    let scriptBody = generatePosixLauncherScript(plan,
      when defined(macosx): "DYLD_LIBRARY_PATH" else: "LD_LIBRARY_PATH")
    writeFile(extendedPath(scriptPath), scriptBody)
    try:
      setFilePermissions(extendedPath(scriptPath), {fpUserExec, fpUserWrite, fpUserRead,
        fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
    except OSError:
      discard

# ---------------------------------------------------------------------------
# Public entry point.
# ---------------------------------------------------------------------------

proc touchMtime(path: string; timestamp: int64) =
  if not dirExists(extendedPath(path)) and not fileExists(extendedPath(path)):
    return
  try:
    setLastModificationTime(extendedPath(path), fromUnix(timestamp))
  except OSError:
    # Best-effort: an mtime update failure should not abort the rollback.
    discard

proc runRollback*(rawOpts: RollbackOptions): RollbackOutcome =
  ## Execute the rollback. Synchronous; takes the M62 `apply.lock` for
  ## the duration.
  let opts = resolveOptions(rawOpts)
  ensureStateDir(opts.stateDir)

  let activeIdHex = readCurrentGenerationId(opts.stateDir)
  if activeIdHex.len == 0:
    raiseNoActiveGeneration()
  result.fromGenerationIdHex = activeIdHex

  # ---- Step 1: acquire apply lock ----
  var lock = acquireApplyLock(opts.stateDir, timeoutSeconds = 30)
  try:
    var store = openStore(opts.storeRoot)
    var storeClosed = false
    try:
      # ---- Step 2-4: load current + target manifests ----
      let targetIdHex = resolveTargetId(opts.stateDir, activeIdHex,
        opts.targetGenerationId)
      result.toGenerationIdHex = targetIdHex
      let cur = loadManifestFor(opts.stateDir, activeIdHex, store)
      let tgt = loadManifestFor(opts.stateDir, targetIdHex, store)

      # ---- Step 5: build plan ----
      let plan = buildRollbackPlan(cur.manifest, tgt.manifest, tgt.envelope)

      # ---- Step 6: digest-check ----
      if not opts.acceptOverwrite:
        # Fail closed on first drift.
        raiseFirstDrift(plan, opts.stateDir, activeIdHex)
      else:
        # Record every drifted path for the outcome / log.
        result.driftedPaths = checkPlanForDrift(plan, opts.stateDir,
          activeIdHex)

      # ---- Step 7: execute ----
      # Files.
      for op in plan.fileOps:
        case op.kind
        of rokRemoveFile:
          removeFileIfPresent(op.absoluteOutputPath)
        of rokRestoreFile:
          restoreFileFromTarget(store, op.targetRecord, opts.homeDir)
        of rokUpdateFile:
          restoreFileFromTarget(store, op.targetRecord, opts.homeDir)
        else: discard
        inc result.fileOpsApplied
      # Managed blocks.
      for op in plan.blockOps:
        case op.kind
        of rokRemoveBlock:
          removeManagedBlock(op.hostFilePath, op.blockId)
        of rokRestoreBlock, rokUpdateBlock:
          rewriteManagedBlock(op.hostFilePath, op.blockId,
            op.targetRecord.postWriteBlockBytes)
        else: discard
        inc result.blockOpsApplied
      # Launchers.
      for op in plan.launcherOps:
        case op.kind
        of rokRemoveLauncher:
          removeLauncherArtifact(opts.stateDir, activeIdHex, op.currentRecord)
        of rokRestoreLauncher, rokUpdateLauncher:
          materializeLauncherFromTarget(opts.stateDir, targetIdHex, store,
            op.targetRecord)
        else: discard
        inc result.launcherOpsApplied
      # M68 resources.
      for op in plan.resourceOps:
        let rec =
          case op.kind
          of rokRemoveResource: op.currentRecord
          of rokRestoreResource, rokUpdateResource: op.targetRecord
          else: continue
        let kindEnum =
          try: resourceKindFromString(rec.resourceKind)
          except ValueError: rkFsManagedBlock
        case op.kind
        of rokRemoveResource:
          # The current generation had this resource; the target
          # didn't. Reverse the write: delete the value / strip
          # the managed block / etc.
          case kindEnum
          of rkWindowsRegistryValue:
            when defined(windows):
              let bs = rec.realWorldIdentity.rfind('\\')
              if bs > 0:
                let subkey = stripHkcuPrefix(
                  rec.realWorldIdentity[0 ..< bs])
                deleteRegistryValue(subkey,
                  rec.realWorldIdentity[bs + 1 .. ^1])
          of rkEnvUserVariable:
            when defined(windows):
              let bs = rec.realWorldIdentity.rfind('\\')
              if bs > 0:
                applyUserVariableDestroy(
                  rec.realWorldIdentity[bs + 1 .. ^1])
          of rkEnvUserPath:
            let entries = parseRecordedPathEntries(rec.payloadBytes)
            removeUserPathContribution(entries,
              userPathHostFromIdentity(rec.realWorldIdentity))
          of rkWindowsStartup:
            when defined(windows):
              let bs = rec.realWorldIdentity.rfind('\\')
              if bs > 0:
                destroyStartup(rec.realWorldIdentity[bs + 1 .. ^1])
          of rkShellIntegration, rkFsManagedBlock:
            let hash = rec.realWorldIdentity.rfind('#')
            if hash > 0:
              destroyManagedBlockResource(
                rec.realWorldIdentity[0 ..< hash],
                rec.realWorldIdentity[hash + 1 .. ^1])
          of rkFsUserFile:
            # The whole-file owner: rolling away from a generation
            # that created this file means deleting it. The recorded
            # `realWorldIdentity` is the resolved host path verbatim.
            destroyUserFileResource(rec.realWorldIdentity)
          else: discard
        of rokRestoreResource, rokUpdateResource:
          # Re-apply the target generation's recorded bytes.
          case kindEnum
          of rkWindowsRegistryValue:
            when defined(windows):
              let bs = rec.realWorldIdentity.rfind('\\')
              if bs > 0:
                let subkey = stripHkcuPrefix(
                  rec.realWorldIdentity[0 ..< bs])
                let name = rec.realWorldIdentity[bs + 1 .. ^1]
                # Recover the regType from payloadKind.
                let kindStr = rec.payloadKind
                var regType: uint32 = 1'u32
                if kindStr.len > 0:
                  try:
                    regType = registryValueKindToRegType(
                      registryValueKindFromString(kindStr))
                  except ValueError:
                    regType = 1'u32
                writeRegistryValue(subkey, name, regType,
                  rec.payloadBytes)
          of rkEnvUserVariable:
            when defined(windows):
              let bs = rec.realWorldIdentity.rfind('\\')
              if bs > 0:
                let name = rec.realWorldIdentity[bs + 1 .. ^1]
                let regType =
                  if rec.payloadKind == "expandString": 2'u32
                  else: 1'u32
                writeRegistryValue(EnvironmentSubkey, name, regType,
                  rec.payloadBytes)
                broadcastEnvironmentChange()
          of rkEnvUserPath:
            let entries = parseRecordedPathEntries(rec.payloadBytes)
            # Subtract the CURRENT generation's contribution first
            # so the merged value is computed against the live PATH
            # minus the entries we just rolled away from.
            var priorContribution: seq[string] = @[]
            if op.hasCurrentRecord:
              priorContribution = parseRecordedPathEntries(
                op.currentRecord.payloadBytes)
            discard applyUserPath(entries, priorContribution,
              userPathHostFromIdentity(rec.realWorldIdentity))
          of rkWindowsStartup:
            when defined(windows):
              let bs = rec.realWorldIdentity.rfind('\\')
              if bs > 0:
                let name = rec.realWorldIdentity[bs + 1 .. ^1]
                writeRegistryValue(RunSubkey, name, 1'u32,
                  rec.payloadBytes)
          of rkShellIntegration, rkFsManagedBlock:
            let hash = rec.realWorldIdentity.rfind('#')
            if hash > 0:
              # Re-decode the payload bytes to UTF-8 content.
              var content = newString(rec.payloadBytes.len)
              for i, b in rec.payloadBytes:
                content[i] = char(b)
              discard applyManagedBlockResource(
                rec.realWorldIdentity[0 ..< hash],
                rec.realWorldIdentity[hash + 1 .. ^1], content)
          of rkFsUserFile:
            # Re-apply the target generation's recorded bytes. The
            # mode is not currently round-tripped through the
            # binding (the manifest record carries `payloadKind`
            # and `payloadBytes` only — extending the binding to
            # carry per-kind metadata like the mode is a future
            # refinement); rollback restores the bytes and leaves
            # the mode unchanged from whatever the file system has
            # currently. The next forward apply re-converges the
            # mode against the target generation's source-of-truth.
            var content = newString(rec.payloadBytes.len)
            for i, b in rec.payloadBytes:
              content[i] = char(b)
            discard applyUserFileResource(
              rec.realWorldIdentity, content, "")
          else: discard
        else: discard
        inc result.resourceOpsApplied

      # ---- Step 8: rotate `current` ----
      rotateCurrent(opts.stateDir, targetIdHex)

      # ---- Step 9: touch target generation directory mtime ----
      let targetDir = generationDir(opts.stateDir, targetIdHex)
      touchMtime(targetDir, opts.activationTimestamp)

      store.close()
      storeClosed = true
    finally:
      if not storeClosed:
        try: store.close() except CatchableError: discard
  finally:
    releaseApplyLock(lock)
