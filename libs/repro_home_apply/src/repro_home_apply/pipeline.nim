## Apply pipeline orchestrator. Owns the 11-step sequence from
## [Home-Profile-Generations-And-State.md] "Apply Pipeline":
##
##   Step  1.  Acquire `apply.lock`
##   Step  2.  Load intent layer (M60)
##   Step  3.  Finalize configurables (M58, Phase A no-op)
##   Step  4.  Compute generation id
##   Step  5.  Plan diff against current generation
##   Step  6.  No-op short-circuit
##   Step  7.  Realize packages (M55/M56)
##   Step  8.  Stage generated files + managed blocks (M59)
##   Step  9.  Materialize launch plans (M57)
##   Step 10.  Atomic switch of `current`
##   Step 11.  Commit manifest + register store roots + eager GC
##
## Test injection: setting `REPRO_TEST_APPLY_KILL_AFTER_STEP=<N>`
## causes the pipeline to write the partial-apply marker and raise
## `EApplyKilledByTestHook` after completing step N. The marker is
## intentionally left in place so the next apply's recovery sweep
## can quarantine the partial generation.

import std/[os, sequtils, strutils, tables, times]

import blake3
import repro_home_generations
import repro_home_intent
import repro_local_store

import ./errors
import ./plan
import ./realize
import ./materialize_files
import ./materialize_managed_blocks
import ./materialize_launchers
import ./current_rotation
import ./partial_recovery
import ./stow
import ./suppression

const
  KillStepEnvVar* = "REPRO_TEST_APPLY_KILL_AFTER_STEP"
  PackageGeneratesEnvVar* = "REPRO_TEST_PACKAGE_GENERATES"
    ## Phase B test hook: semicolon-separated
    ## `<pkg>=<home-rel-path>:<content>` entries. Each entry asks the
    ## planner to synthesize a package-output `GeneratedFile` for the
    ## named package. The gate 6 fixture uses this hook to stage a
    ## `git-config` package that would write `~/.gitconfig` so the
    ## stow-suppression code path is exercised end-to-end without
    ## requiring the full M59 stdlib.
  PackageManagedBlocksEnvVar* = "REPRO_TEST_PACKAGE_MANAGED_BLOCKS"
    ## M64 test hook: semicolon-separated
    ## `<pkg>=<home-rel-host>#<block-id>:<content>` entries. Each entry
    ## asks the pipeline to materialize a managed block in the named
    ## host file with the named id and content. Used by the M64
    ## rollback gates to populate managed blocks in `~/.bashrc` without
    ## requiring the full M59 `fs.managedBlock` stdlib hook.
  NoOpLogPrefix* = "no-op: generation matches; verified "
    ## Stable rendering used by gate 2's assertion.

type
  ApplyOutcomeKind* = enum
    aokFreshApplied = "fresh-applied"
    aokNoOpVerified = "noop-verified"

  ApplyOutcome* = object
    kind*: ApplyOutcomeKind
    generationIdHex*: string
    activationManifestDigestHex*: string
    diagnostics*: seq[StowDiagnostic]
    abortedRecovered*: seq[AbortedGenerationRecord]
    verifiedDigestCount*: int
    gcResult*: GcReport
      ## Step 11 eager-GC report. `gcResult.ranAt == 0` iff the
      ## pipeline took the no-op short-circuit (eager GC only runs on
      ## the fresh-applied branch). On `aokFreshApplied`, `ranAt` is
      ## non-zero and the per-record sequences (`quarantined`,
      ## `quarantinedPaths`, `reclaimed`) are authoritative.

  ApplyOptions* = object
    profileDir*: string                ## "" → resolveProfileDir()
    profilePath*: string               ## "" → resolveProfilePath()
    host*: string                      ## "" → currentHost()
    stateDir*: string                  ## "" → resolveStateDir()
    storeRoot*: string                 ## "" → resolveStoreRoot()
    homeDir*: string                   ## "" → getHomeDir()
    activationTimestamp*: int64        ## 0 → getTime().toUnix

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc digestOf(content: openArray[byte]): Digest256 =
  let raw = blake3.digest(content)
  for i in 0 ..< 32:
    result[i] = raw[i]

proc digestFromKey(key: PrefixIdBytes): Digest256 =
  for i in 0 ..< 32:
    result[i] = key[i]

proc resolveOptions(opts: ApplyOptions): ApplyOptions =
  result = opts
  if result.profileDir.len == 0:
    result.profileDir = resolveProfileDir()
  if result.profilePath.len == 0:
    result.profilePath = result.profileDir / HomeProfileAnchor
  if result.host.len == 0:
    result.host = currentHost()
  if result.stateDir.len == 0:
    result.stateDir = resolveStateDir()
  if result.storeRoot.len == 0:
    result.storeRoot = resolveStoreRoot()
  if result.homeDir.len == 0:
    result.homeDir = getHomeDir()
  if result.activationTimestamp == 0:
    result.activationTimestamp = getTime().toUnix

proc shouldKillAfter(step: int): bool =
  let raw = getEnv(KillStepEnvVar)
  if raw.len == 0:
    return false
  try:
    parseInt(raw.strip()) == step
  except ValueError:
    false

proc parseSyntheticPackageGenerates(homeDir: string;
                                    declaredPackages: seq[string]):
    seq[PlannedGeneratedFile] =
  ## Read `REPRO_TEST_PACKAGE_GENERATES` and synthesize one
  ## `PlannedGeneratedFile` per declared `<pkg>=<rel>:<content>` entry
  ## whose package is in `declaredPackages`. Packages not in the plan
  ## (because no activity references them) are silently dropped — the
  ## suppression layer cannot suppress what wasn't going to happen.
  let raw = getEnv(PackageGeneratesEnvVar)
  if raw.len == 0:
    return
  for piece in raw.split(';'):
    let trimmed = piece.strip()
    if trimmed.len == 0:
      continue
    let eq = trimmed.find('=')
    if eq <= 0:
      continue
    let pkg = trimmed[0 ..< eq].strip()
    if pkg notin declaredPackages:
      continue
    let rest = trimmed[eq + 1 .. ^1]
    let colon = rest.find(':')
    if colon <= 0:
      continue
    let relPath = rest[0 ..< colon].strip()
    let content = rest[colon + 1 .. ^1]
    var contentBytes = newSeq[byte](content.len)
    for i, ch in content:
      contentBytes[i] = byte(ord(ch))
    result.add(PlannedGeneratedFile(
      absoluteOutputPath: homeDir / relPath,
      relativeHomePath: relPath.replace('\\', '/'),
      sourceKind: pgfsPackageOutput,
      contributingPackage: pkg,
      stowSourcePath: "",
      contentBytes: contentBytes))

proc parseSyntheticPackageManagedBlocks(homeDir: string;
                                        declaredPackages: seq[string]):
    seq[PlannedManagedBlock] =
  ## Read `REPRO_TEST_PACKAGE_MANAGED_BLOCKS` and synthesize one
  ## `PlannedManagedBlock` per declared
  ## `<pkg>=<rel-host>#<block-id>:<content>` entry whose package is
  ## in `declaredPackages`. The M64 rollback gates use this to stage
  ## a managed block in `~/.bashrc` without needing the full M59
  ## `fs.managedBlock` stdlib hook wired in.
  let raw = getEnv(PackageManagedBlocksEnvVar)
  if raw.len == 0:
    return
  for piece in raw.split(';'):
    let trimmed = piece.strip()
    if trimmed.len == 0:
      continue
    let eq = trimmed.find('=')
    if eq <= 0:
      continue
    let pkg = trimmed[0 ..< eq].strip()
    if pkg notin declaredPackages:
      continue
    let rest = trimmed[eq + 1 .. ^1]
    let hash = rest.find('#')
    if hash <= 0:
      continue
    let relHost = rest[0 ..< hash].strip()
    let afterHash = rest[hash + 1 .. ^1]
    let colon = afterHash.find(':')
    if colon <= 0:
      continue
    let blockId = afterHash[0 ..< colon].strip()
    let content = afterHash[colon + 1 .. ^1]
    result.add(PlannedManagedBlock(
      hostFilePath: homeDir / relHost,
      blockId: blockId,
      blockBytes: content))

# ---------------------------------------------------------------------------
# Plan derivation
# ---------------------------------------------------------------------------

proc loadProfileOrRaise(profilePath: string): Profile =
  try:
    return loadProfile(profilePath)
  except CatchableError as err:
    raiseIntentLoad(profilePath, err.msg)

proc deriveGenerationId(plan: ApplyPlan;
                        intentSnapshotDigest: Digest256): GenerationId =
  ## Per the spec ("Generation Identity") the generation id is
  ## content-addressed over the resolved plan + intent snapshot +
  ## host identity. It explicitly does NOT include the activation
  ## timestamp, the holder pid, the OS clock, or any other run-
  ## environment fact: two identical applies (back to back on the
  ## same machine, hours apart, on two machines) produce the same
  ## id. This is what makes the no-op short-circuit possible.
  var buf = canonicalPlanBytes(plan)
  for b in intentSnapshotDigest: buf.add(b)
  for ch in plan.hostIdentity: buf.add(byte(ord(ch)))
  let full = blake3.digest(buf)
  for i in 0 ..< GenerationIdSize:
    result[i] = full[i]

# ---------------------------------------------------------------------------
# No-op verification
# ---------------------------------------------------------------------------

proc verifyManifestDigests(stateDir: string; store: var Store;
                           activeGenIdHex: string;
                           outVerified: var int): bool =
  ## Apply pipeline step 6: load the active generation's pointer +
  ## manifest, then verify every recorded post-write digest against
  ## the live filesystem. Returns true when everything matches.
  let pointerFile = pointerPath(stateDir, activeGenIdHex)
  if not fileExists(pointerFile):
    return false
  let env = readPointerFile(pointerFile)
  var manifestKey: PrefixIdBytes
  for i in 0 ..< 32:
    manifestKey[i] = env.activationManifestDigest[i]
  let manifestBytes = readCasBlob(store, manifestKey)
  let manifest = decodeManifestBytes(manifestBytes)
  outVerified = 0
  # Generated files: postWriteDigest matches live content (for owned/
  # merged) or stow source still resolves (for stow-symlink / stow-
  # junction; phase A treats both as "live link exists").
  for gf in manifest.generatedFiles:
    case gf.ownershipPolicy
    of gfoStowSymlink, gfoStowJunction:
      # The link itself must exist; phase B can extend to verify the
      # link target.
      if not symlinkExists(gf.absoluteOutputPath) and
         not fileExists(gf.absoluteOutputPath):
        return false
    of gfoOwned, gfoMerged, gfoExistingPreserved, gfoStowCopy:
      if not fileExists(gf.absoluteOutputPath):
        return false
      let raw = readFile(gf.absoluteOutputPath)
      var buf = newSeq[byte](raw.len)
      for i, ch in raw:
        buf[i] = byte(ord(ch))
      if digestOf(buf) != gf.postWriteDigest:
        return false
    inc outVerified
  for ec in manifest.exportedCommands:
    when defined(windows):
      let binDir = stableBinDir(stateDir)
      let cmdExe = binDir / (ec.commandName & ".exe")
      let cmdShim = binDir / (ec.commandName & ".cmd")
      if not fileExists(cmdExe) and not fileExists(cmdShim):
        return false
    else:
      let binDir = generationBinDir(stateDir, activeGenIdHex)
      let cmdScript = binDir / ec.commandName
      if not fileExists(cmdScript):
        return false
    inc outVerified
  true

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc runApply*(rawOpts: ApplyOptions): ApplyOutcome =
  ## Execute the apply pipeline. Synchronous; takes the `apply.lock`
  ## for the duration. Returns an `ApplyOutcome` summarizing what
  ## happened so the CLI layer can render a single status line.
  let opts = resolveOptions(rawOpts)

  # ---- Pre-step: partial-apply recovery ----------------------------------
  ensureStateDir(opts.stateDir)
  let recovered = recoverPartialApply(opts.stateDir)
  result.abortedRecovered = recovered

  # ---- Step 1: acquire apply lock ---------------------------------------
  var lock = acquireApplyLock(opts.stateDir, timeoutSeconds = 30)
  try:
    if shouldKillAfter(1):
      writeMarker(opts.stateDir, "", "killed-after-step-1")
      raiseKilledByTestHook(1)

    # ---- Step 2: load intent layer --------------------------------------
    if not fileExists(opts.profilePath):
      raiseIntentLoad(opts.profilePath,
        "no home.nim at expected path (profile-dir: " & opts.profileDir &
        ")")
    let profile = loadProfileOrRaise(opts.profilePath)
    if shouldKillAfter(2):
      writeMarker(opts.stateDir, "", "killed-after-step-2")
      raiseKilledByTestHook(2)

    # ---- Step 3: finalize configurables (Phase A: no-op) ----------------
    # Phase A profiles don't enable any package that drives a
    # configurable-resolved file output, so the M58 resolve pass is a
    # pure pass-through here.
    if shouldKillAfter(3):
      writeMarker(opts.stateDir, "", "killed-after-step-3")
      raiseKilledByTestHook(3)

    # ---- Step 4: derive ApplyPlan (package walk + stow discovery) -------
    var applyPlan = buildPlan(profile, opts.profileDir, opts.host)
    # Phase B: pull in any synthetic package-output entries the test
    # hook declared. In production this seam will be fed by the M59
    # stdlib renderer.
    var packageIds: seq[string]
    for p in applyPlan.packages:
      packageIds.add(p.packageId)
    let synthetic = parseSyntheticPackageGenerates(opts.homeDir, packageIds)
    for s in synthetic:
      applyPlan.generatedFiles.add(s)
    let stowEntries = discoverStowEntries(opts.profileDir, opts.homeDir)
    if stowEntries.len > 0:
      let stowPlanned = stowEntriesToPlanned(stowEntries)
      for sp in stowPlanned:
        applyPlan.generatedFiles.add(sp)
    # Suppression deduplicates by `relativeHomePath`. The stow entry
    # wins where it overlaps a package output; diagnostics are emitted
    # for shadowed package outputs and dead config: contributions.
    let suppressed = suppressStowShadowed(applyPlan.generatedFiles,
      applyPlan.configContributions)
    applyPlan.generatedFiles = suppressed.files
    for d in suppressed.diagnostics:
      applyPlan.diagnostics.add(d)
    result.diagnostics = applyPlan.diagnostics
    if shouldKillAfter(4):
      writeMarker(opts.stateDir, "", "killed-after-step-4")
      raiseKilledByTestHook(4)

    # ---- Step 5: load active generation's manifest (for diff) -----------
    let activeGenIdHex = readCurrentGenerationId(opts.stateDir)
    var store = openStore(opts.storeRoot)
    var storeClosed = false
    try:
      # ---- Step 6: no-op short-circuit ----------------------------------
      let intentSnapshot = IntentSnapshot(schemaVersion: 1'u16,
        files: defaultWalkProfileFiles(opts.profileDir))
      let snapshotBytes = encodeSnapshot(intentSnapshot)
      let snapshotDig = digestOf(snapshotBytes)
      let candidateId = deriveGenerationId(applyPlan, snapshotDig)
      # No-op detection (spec §"No-Op Detection"): a re-apply is a
      # no-op iff the planner's content id matches the active
      # generation's recorded id AND all of the active generation's
      # post-write digests still verify against the live filesystem.
      # Both halves are required: an intent edit that removes a
      # package would otherwise verify as a "no-op" until the next
      # apply rewrites the bin dir, because the active generation's
      # files are still on disk.
      var verifyCount = 0
      if activeGenIdHex.len > 0:
        # The pointer's `generationId` IS the content id (we set it
        # to `deriveGenerationId` which the writer copies in verbatim
        # — the writer leaves the id slot alone and only fills the
        # CAS-digest slots).
        let candidateIdHex = generationIdHex(candidateId)
        if candidateIdHex == activeGenIdHex and
           verifyManifestDigests(opts.stateDir, store, activeGenIdHex,
             verifyCount):
          result.kind = aokNoOpVerified
          result.generationIdHex = activeGenIdHex
          result.verifiedDigestCount = verifyCount
          stdout.writeLine(NoOpLogPrefix & $verifyCount & " recorded digests")
          return

      if shouldKillAfter(6):
        writeMarker(opts.stateDir, generationIdHex(candidateId),
          "killed-after-step-6")
        raiseKilledByTestHook(6)

      # ---- Commit: write marker before any destructive step. ------------
      writeMarker(opts.stateDir, generationIdHex(candidateId), "in-progress")
      # Create the per-generation directory eagerly so partial-apply
      # recovery has a target to quarantine even when the kill happens
      # before the launcher / manifest writes that would otherwise
      # populate it. The directory ALONE does not advance `current` —
      # rotation in step 10 is the point of no return.
      let earlyGenDir = generationDir(opts.stateDir,
        generationIdHex(candidateId))
      createDir(earlyGenDir)

      # ---- Step 7: realize packages -------------------------------------
      let realized = realizePlannedPackages(store, applyPlan.packages)
      if shouldKillAfter(7):
        raiseKilledByTestHook(7)

      # ---- Step 8: stage generated files + managed blocks ---------------
      var stagedFiles: seq[StagedFileRecord]
      for entry in stowEntries:
        let rec = materializeStowEntry(opts.profileDir, opts.homeDir, entry)
        var staged: StagedFileRecord
        staged.absoluteOutputPath = rec.targetAbsolutePath
        staged.sourceKind = pgfsStowFile
        staged.stowSource = rec.sourceAbsolutePath
        staged.ownershipPolicy = modeToOwnershipPolicy(rec.mode)
        staged.hasPreWriteDigest = rec.hasPreWriteDigest
        staged.preWriteDigest = rec.preWriteDigest
        staged.postWriteDigest = rec.postWriteDigest
        stagedFiles.add(staged)
        if rec.mode != smSymlink:
          # Emit IStowFellBack once per generation per fallback kind.
          var seenSym = false
          var seenJunc = false
          for d in result.diagnostics:
            if d.code == sdIStowFellBack:
              if d.fallbackTo == "junction": seenJunc = true
              if d.fallbackTo == "copy":
                if d.fallbackFrom == "symlink": seenSym = true
                else: seenJunc = true
          case rec.mode
          of smJunction:
            if not seenJunc:
              result.diagnostics.add(StowDiagnostic(
                severity: dsInfo,
                code: sdIStowFellBack,
                path: rec.targetAbsolutePath,
                fallbackFrom: "symlink",
                fallbackTo: "junction",
                message: "IStowFellBack: symlink unavailable for " &
                  rec.targetAbsolutePath & "; used NTFS junction at " &
                  "the deepest stow-exclusive ancestor."))
          of smCopy:
            if not seenSym:
              result.diagnostics.add(StowDiagnostic(
                severity: dsInfo,
                code: sdIStowFellBack,
                path: rec.targetAbsolutePath,
                fallbackFrom: "symlink",
                fallbackTo: "copy",
                message: "IStowFellBack: symlink and junction both " &
                  "unavailable for " & rec.targetAbsolutePath &
                  "; copied the source file contents."))
          else: discard
      # Package-driven files (Phase A: none).
      for g in applyPlan.generatedFiles:
        if g.sourceKind != pgfsPackageOutput:
          continue
        stagedFiles.add(materializePackageOutput(g))
      # Seal every staged file's content bytes into CAS keyed by the
      # post-write digest. This is what enables M64 rollback to restore
      # files whose live target is being overwritten: the target
      # generation's manifest carries `storeContentHash = postWriteDigest`
      # and the bytes are reachable via `readCasBlob`. M63 only RECORDS
      # the digest; M64 needs the bytes too.
      proc readFileBytes(path: string): seq[byte] =
        let raw = readFile(path)
        result = newSeq[byte](raw.len)
        for i, ch in raw:
          result[i] = byte(ord(ch))
      for g in applyPlan.generatedFiles:
        if g.sourceKind == pgfsPackageOutput:
          discard storeCasBlob(store, g.contentBytes)
      for entry in stowEntries:
        if fileExists(entry.sourceAbsolutePath):
          let bytes = readFileBytes(entry.sourceAbsolutePath)
          discard storeCasBlob(store, bytes)
      # Materialize synthetic managed blocks from the M64 test hook.
      # In production, M65 wires the M59 `fs.managedBlock` stdlib hook
      # to populate this list; for now the gates use the env-var seam.
      var appliedManagedBlocks: seq[AppliedManagedBlockRecord]
      let syntheticBlocks = parseSyntheticPackageManagedBlocks(opts.homeDir,
        packageIds)
      for mb in syntheticBlocks:
        appliedManagedBlocks.add(applyManagedBlock(mb))
      # Diff against the previous generation's manifest: any file or
      # managed block it owned that the new generation does NOT own
      # is removed before we commit. Without this, files that A's plan
      # generated but B's plan no longer mentions would persist on
      # disk across the A -> B transition (and would block M64 rollback's
      # symmetric "remove + restore" plan). The drift here matches the
      # apply pipeline's documented "Step 5: Plan diff against current"
      # spec line; M63 deferred the actual deletion work to a later
      # milestone, and we land it under M64 because rollback's
      # symmetry assumes apply already cleaned up.
      if activeGenIdHex.len > 0:
        let prevPointerFile = pointerPath(opts.stateDir, activeGenIdHex)
        if fileExists(prevPointerFile):
          var newPaths: seq[string]
          for sf in stagedFiles:
            newPaths.add(sf.absoluteOutputPath)
          let prevEnv = readPointerFile(prevPointerFile)
          var prevManifestKey: PrefixIdBytes
          for i in 0 ..< 32:
            prevManifestKey[i] = prevEnv.activationManifestDigest[i]
          try:
            let prevManifestBytes = readCasBlob(store, prevManifestKey)
            let prevManifest = decodeManifestBytes(prevManifestBytes)
            for gf in prevManifest.generatedFiles:
              if gf.absoluteOutputPath notin newPaths:
                deleteRemovedFile(gf.absoluteOutputPath)
            # Same for managed blocks.
            var newBlockKeys: seq[string]
            for mb in appliedManagedBlocks:
              newBlockKeys.add(mb.hostFilePath & "\x1a" & mb.blockId)
            for mb in prevManifest.managedBlocks:
              let k = mb.hostFilePath & "\x1a" & mb.blockId
              if k notin newBlockKeys:
                # Strip the sentinel-delimited region from the host file.
                if fileExists(mb.hostFilePath):
                  let existing = readFile(mb.hostFilePath)
                  let openS = OpenSentinelPrefix & mb.blockId &
                    OpenSentinelSuffix
                  let closeS = CloseSentinelPrefix & mb.blockId &
                    CloseSentinelSuffix
                  let openIdx = existing.find(openS)
                  let closeIdx = existing.find(closeS)
                  if openIdx >= 0 and closeIdx >= 0 and closeIdx > openIdx:
                    var openLineStart = openIdx
                    while openLineStart > 0 and
                        existing[openLineStart - 1] != '\n':
                      dec openLineStart
                    var closeLineEnd = closeIdx + closeS.len
                    if closeLineEnd < existing.len and
                        existing[closeLineEnd] == '\n':
                      inc closeLineEnd
                    let rewritten = existing[0 ..< openLineStart] &
                      existing[closeLineEnd .. ^1]
                    writeFile(mb.hostFilePath, rewritten)
          except CatchableError:
            # The previous manifest may be unreadable in pathological
            # cases (manifest in CAS was GC'd by another tool, etc.).
            # The apply still proceeds; rollback would surface the
            # missing-blob diagnostic later.
            discard
      if shouldKillAfter(8):
        raiseKilledByTestHook(8)

      # ---- Step 9: materialize launch plans -----------------------------
      let perGenBin = generationBinDir(opts.stateDir,
        generationIdHex(candidateId))
      createDir(perGenBin)
      let launchers = materializeLaunchers(store, perGenBin, realized,
        applyPlan.launchers)
      if shouldKillAfter(9):
        raiseKilledByTestHook(9)

      # ---- Step 10: atomic switch of `current` --------------------------
      # Compose the activation manifest before rotation (rotation is
      # the point of no return). The manifest still needs to be sealed
      # into CAS in step 11.
      var manifest = ActivationManifest(schemaVersion: 1'u16)
      for r in realized:
        manifest.realizedPackages.add(RealizedPackage(
          packageId: r.packageId,
          realizedPrefixId: digestFromKey(r.prefixId),
          adapter: $r.adapter,
          provenance: r.provenance))
      for l in launchers:
        manifest.exportedCommands.add(ExportedCommand(
          commandName: l.commandName,
          launchPlanDigest: l.launchPlanDigest,
          binDirRelativePath: l.binDirRelativePath,
          binDirArtifactKind: l.binDirArtifactKind))
      for sf in stagedFiles:
        var gf: GeneratedFile
        gf.absoluteOutputPath = sf.absoluteOutputPath
        gf.storeContentHash = sf.postWriteDigest
        gf.ownershipPolicy = sf.ownershipPolicy
        gf.hasPreWriteDigest = sf.hasPreWriteDigest
        if sf.hasPreWriteDigest:
          gf.preWriteDigest = sf.preWriteDigest
        gf.postWriteDigest = sf.postWriteDigest
        gf.stowSource = sf.stowSource
        manifest.generatedFiles.add(gf)
      # Resource bindings reserved for M68; managed blocks come from
      # the test-hook synthesizer in Phase A.
      for mb in appliedManagedBlocks:
        manifest.managedBlocks.add(ManagedBlock(
          hostFilePath: mb.hostFilePath,
          blockId: mb.blockId,
          preWriteFileDigest: mb.preWriteFileDigest,
          postWriteBlockBytes: mb.postWriteBlockBytes,
          postWriteFileDigest: mb.postWriteFileDigest))
      manifest.resourceBindings = @[]
      let manifestBytes = encodeManifest(manifest)

      # Build the envelope before rotation; writeGeneration also
      # writes it but we need realizedPrefixIds first.
      var envelope = PointerEnvelope(schemaVersion: 1'u16,
        activationTimestamp: opts.activationTimestamp,
        hostIdentity: opts.host)
      for r in realized:
        envelope.realizedPrefixIds.add(digestFromKey(r.prefixId))
      envelope.generationId = candidateId

      # Step 11 (commit): seal manifest + intent snapshot + RBCG into
      # CAS, write pointer.bin, register store root, attach holds.
      # The pipeline runs the commit BEFORE rotation so a crash
      # during CAS sealing leaves the partial-recovery marker in
      # place and the next apply quarantines this generation. After
      # commit, rotation is a single write of `current.txt` (Windows)
      # or symlink swap (POSIX), neither of which can fail in a way
      # that leaves the system in an inconsistent state.
      let rbcgBytes = manifestBytes  # Phase A: no separate RBCG;
                                     # reuse the manifest bytes as
                                     # placeholder until M58 wires
                                     # configurables.
      writeGeneration(opts.stateDir, envelope, manifestBytes,
        snapshotBytes, rbcgBytes, store)
      if shouldKillAfter(10):
        raiseKilledByTestHook(10)

      # ---- Step 10b: rotate current. From this point forward the
      # generation is reachable from `current`. ---------------------
      rotateCurrent(opts.stateDir, generationIdHex(candidateId))

      # ---- Step 11 (eager GC) -------------------------------------
      result.gcResult = gc(store)

      # Clear the partial-apply marker — success.
      clearMarker(opts.stateDir)

      result.kind = aokFreshApplied
      result.generationIdHex = generationIdHex(candidateId)
      result.activationManifestDigestHex = digestHex(envelope.activationManifestDigest)
      store.close()
      storeClosed = true
    finally:
      if not storeClosed:
        try: store.close() except CatchableError: discard
  finally:
    releaseApplyLock(lock)
