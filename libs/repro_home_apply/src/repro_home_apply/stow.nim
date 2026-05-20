## Phase B: stow-style dotfile materialization (see
## [Home-Profile-Intent-Layer.md] "Stow-Style Dotfile Support").
##
## Two responsibilities:
##
##   1. **Discovery**: walk `<profile-dir>/stow/` and synthesize one
##      `PlannedGeneratedFile` per regular file, with
##      `sourceKind = pgfsStowFile` and `stowSourcePath` set. The
##      planner appends these to its `generatedFiles` list before
##      handing the plan to the suppression layer.
##   2. **Materialization**: per file, try the link decision tree
##      (symlink → junction → copy). The chosen mode is recorded as
##      `stow-symlink`, `stow-junction`, or `stow-copy` on the
##      manifest record.
##
## The decision tree is observable through two test hooks:
##
##   * `REPRO_TEST_STOW_DISABLE_SYMLINK=1` — every symlink attempt
##     fails as if `SeCreateSymbolicLinkPrivilege` were missing.
##   * `REPRO_TEST_STOW_DISABLE_JUNCTION=1` — every junction attempt
##     fails. Combined with the symlink env var this forces the
##     copy fallback.
##
## These hooks exist so the gates can drive each branch without
## requiring administrator privileges (or the lack thereof) on the
## CI host.
##
## M72 Deliverable 3 — non-destructive materialization:
##   The materializer NEVER blindly `removeFile`s a pre-existing
##   target. Three cases:
##     * target absent              → create the link.
##     * target is ALREADY the correct symlink/junction to the stow
##       source → no-op CACHE-HIT (the link is not deleted+recreated).
##     * target is a regular file, OR a link to a DIFFERENT source →
##       CONFLICT: the target is left byte-identical and
##       `EStowConflict` is raised, unless the caller passes a
##       reconcile-drift policy (then the prior content is recorded
##       and the target is replaced).
##   The copy fallback obeys the same rule: a pre-existing differing
##   file is never overwritten without the drift gate.

import std/[os, strutils]

import blake3
import repro_home_generations

import ./errors
import ./plan

const
  DisableSymlinkEnvVar* = "REPRO_TEST_STOW_DISABLE_SYMLINK"
  DisableJunctionEnvVar* = "REPRO_TEST_STOW_DISABLE_JUNCTION"
  StowSubdirName* = "stow"

type
  StowMaterializationMode* = enum
    smSymlink
    smJunction
    smCopy

  StowReconcilePolicy* = enum
    ## M72 Deliverable 3: how the materializer treats a pre-existing
    ## target that conflicts with the desired stow link.
    srpFailClosed                     ## conflict → raise EStowConflict
    srpReconcileDrift                  ## conflict → record prior, replace

  StowEntry* = object
    ## One stow file the discovery pass surfaced.
    sourceAbsolutePath*: string
    homeRelativePath*: string
    targetAbsolutePath*: string       ## $HOME/<rel>

  AppliedStowRecord* = object
    sourceAbsolutePath*: string
    homeRelativePath*: string
    targetAbsolutePath*: string
    mode*: StowMaterializationMode
    postWriteDigest*: Digest256       ## blake3 of the source content
    hasPreWriteDigest*: bool
    preWriteDigest*: Digest256
    wasCacheHit*: bool
      ## M72: true when the target already existed as the correct
      ## symlink/junction to the stow source — materialized as a
      ## no-op (the existing link was NOT deleted and recreated).
    wasReconciled*: bool
      ## M72: true when a conflicting target was replaced under a
      ## reconcile-drift policy. `preWriteDigest` then carries the
      ## prior content digest so rollback can restore it.

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

proc discoverStowEntries*(profileDir, homeDir: string): seq[StowEntry] =
  let stowRoot = profileDir / StowSubdirName
  if not dirExists(stowRoot):
    return @[]
  for path in walkDirRec(stowRoot, yieldFilter = {pcFile, pcLinkToFile},
      relative = true):
    let normalized = path.replace('\\', '/')
    var entry: StowEntry
    entry.sourceAbsolutePath = stowRoot / path
    entry.homeRelativePath = normalized
    entry.targetAbsolutePath = homeDir / path
    result.add entry

proc stowEntriesToPlanned*(entries: seq[StowEntry]): seq[PlannedGeneratedFile] =
  for e in entries:
    var content: seq[byte]
    if fileExists(e.sourceAbsolutePath):
      let raw = readFile(e.sourceAbsolutePath)
      content = newSeq[byte](raw.len)
      for i, ch in raw:
        content[i] = byte(ord(ch))
    result.add(PlannedGeneratedFile(
      absoluteOutputPath: e.targetAbsolutePath,
      relativeHomePath: e.homeRelativePath,
      sourceKind: pgfsStowFile,
      contributingPackage: "",
      stowSourcePath: e.sourceAbsolutePath,
      contentBytes: content))

# ---------------------------------------------------------------------------
# Materialization
# ---------------------------------------------------------------------------

proc digestBytes(content: openArray[byte]): Digest256 =
  let raw = blake3.digest(content)
  for i in 0 ..< 32:
    result[i] = raw[i]

proc readPreWriteDigest(dst: string): tuple[has: bool; digest: Digest256] =
  if not fileExists(dst):
    return (false, default(Digest256))
  let raw = readFile(dst)
  var buf = newSeq[byte](raw.len)
  for i, ch in raw:
    buf[i] = byte(ord(ch))
  (true, digestBytes(buf))

# ---------------------------------------------------------------------------
# M72 Deliverable 3: non-destructive target inspection
# ---------------------------------------------------------------------------

type
  TargetState = enum
    tsAbsent                          ## nothing at the target path
    tsCorrectLink                     ## already the right symlink/junction
    tsWrongLink                       ## a link, but to a different source
    tsRegularFile                     ## a plain file (or dir) — conflict

  TargetInspection = object
    state: TargetState
    existingKind: string              ## human label for the diagnostic
    existingTarget: string            ## resolved link target, if a link

proc linkPointsAtSource(linkPath, desiredSource: string): bool =
  ## Decide whether the link at `linkPath` resolves to the SAME file
  ## as `desiredSource`. Uses `os.sameFile` (file-identity comparison
  ## by volume serial + file index on Windows, inode on POSIX) — a
  ## symlink resolves to its target's identity, so this is true iff
  ## the link points at the stow source. This is robust where
  ## `expandSymlink` is not: `GetFinalPathNameByHandle` on Windows
  ## can return the link's own canonical path rather than the
  ## reparse-point target, which would misclassify a correct link as
  ## a wrong link.
  try:
    if not fileExists(desiredSource):
      return false
    # `sameFile` follows the link on both arguments. If `linkPath`'s
    # target was deleted it will raise; treat that as "not the same".
    sameFile(linkPath, desiredSource)
  except OSError, IOError:
    false

proc readLinkTargetBestEffort(linkPath: string): string =
  ## Best-effort resolution of a link's target, only for the
  ## human-readable diagnostic. `sameFile` already drives the
  ## decision; this is purely cosmetic.
  try:
    result = expandSymlink(linkPath)
  except OSError, IOError:
    result = ""

proc inspectTarget(target, desiredSource: string): TargetInspection =
  ## Classify what currently lives at `target` relative to the desired
  ## stow link. NEVER mutates the filesystem — this is the read the
  ## non-destructive decision tree branches on.
  if not fileExists(target) and not symlinkExists(target) and
     not dirExists(target):
    return TargetInspection(state: tsAbsent)
  if symlinkExists(target):
    # A symlink (file or dir). Compare by file identity — robust
    # across Windows reparse-point resolution quirks.
    if linkPointsAtSource(target, desiredSource):
      return TargetInspection(state: tsCorrectLink,
        existingKind: "symlink",
        existingTarget: readLinkTargetBestEffort(target))
    return TargetInspection(state: tsWrongLink,
      existingKind: "symlink",
      existingTarget: readLinkTargetBestEffort(target))
  # A regular file (or a real directory). On Windows a junction to a
  # directory reports via `dirExists` but not `symlinkExists`; the
  # stow files this module materializes are always FILES, so a
  # directory at a file's target path is itself a conflict.
  if dirExists(target):
    return TargetInspection(state: tsRegularFile,
      existingKind: "directory")
  return TargetInspection(state: tsRegularFile,
    existingKind: "regular-file")

proc tryCreateSymlink(target, source: string;
                      reconcile: StowReconcilePolicy;
                      outCacheHit, outReconciled: var bool): bool =
  ## M72 Deliverable 3: non-destructive symlink materialization.
  ##
  ##   * target absent                       → create the link.
  ##   * target already the correct symlink  → no-op CACHE-HIT
  ##     (the link is NOT deleted and recreated).
  ##   * target is a regular file / wrong link → CONFLICT: raise
  ##     `EStowConflict` (fail-closed) unless `reconcile` is
  ##     `srpReconcileDrift`, in which case the prior content is
  ##     recorded by the caller and the target is replaced.
  ##
  ## Early-returns when the test hook disables symlinks WITHOUT
  ## mutating the filesystem — pre-creating the target's parent dir
  ## would defeat the junction fallback, which keys off "ancestor
  ## does not yet exist on disk."
  outCacheHit = false
  outReconciled = false
  if getEnv(DisableSymlinkEnvVar) == "1":
    return false
  let inspection = inspectTarget(target, source)
  case inspection.state
  of tsCorrectLink:
    # Already correct — no-op cache-hit. Do NOT delete-and-recreate.
    outCacheHit = true
    return true
  of tsRegularFile, tsWrongLink:
    if reconcile != srpReconcileDrift:
      raiseStowConflict(target, inspection.existingKind, source)
    # Reconcile: the caller already captured the prior content
    # digest via `readPreWriteDigest`. Remove the conflicting target
    # so the link can be created in its place.
    outReconciled = true
    try:
      removeFile(target)
    except OSError, IOError:
      # A directory cannot be removed with removeFile.
      try: removeDir(target) except OSError: discard
  of tsAbsent:
    discard
  try:
    let parent = parentDir(target)
    if parent.len > 0:
      createDir(parent)
    createSymlink(source, target)
    true
  except OSError, IOError:
    false

proc tryCreateJunctionAtAncestor(profileStowRoot, homeDir, homeRel: string;
                                 sourceFile: string;
                                 actualTarget: var string): bool =
  ## Windows-only junction fallback. The spec mandates "deepest
  ## stow-exclusive ancestor". For Phase B's first cut we pick the
  ## immediate parent directory of the target file (if that directory
  ## does not yet exist on disk). Files at the root of the stow tree
  ## (e.g. `stow/.gitconfig`) cannot be junctioned because $HOME
  ## itself can never be replaced.
  when defined(windows):
    if getEnv(DisableJunctionEnvVar) == "1":
      return false
    let relPath = homeRel
    let slash = relPath.rfind('/')
    if slash <= 0:
      return false  # at stow root; not junctionable
    let relParent = relPath[0 ..< slash]
    let homeParent = homeDir / relParent.replace('/', DirSep)
    if dirExists(homeParent):
      return false  # ancestor already populated; would clobber
    let stowParent = profileStowRoot / relParent.replace('/', DirSep)
    if not dirExists(stowParent):
      return false
    try:
      let parentOfParent = parentDir(homeParent)
      if parentOfParent.len > 0:
        createDir(parentOfParent)
      # `mklink /J <link> <target>` creates an NTFS junction.
      let cmd = "cmd /c mklink /J " & quoteShell(homeParent) & " " &
        quoteShell(stowParent)
      let rc = execShellCmd(cmd)
      if rc != 0:
        return false
    except OSError, IOError:
      return false
    actualTarget = homeParent / extractFilename(sourceFile)
    return fileExists(actualTarget)
  else:
    discard
    return false

proc materializeStowEntry*(profileDir, homeDir: string;
                           entry: StowEntry;
                           reconcile: StowReconcilePolicy = srpFailClosed):
    AppliedStowRecord =
  ## Apply one stow entry through the symlink → junction → copy
  ## decision tree. The selected mode is returned so the pipeline
  ## emits `IStowFellBack` on the first fallback within a generation.
  ##
  ## M72 Deliverable 3: the materializer is non-destructive. A target
  ## that already exists as the correct link is a no-op cache-hit
  ## (`result.wasCacheHit = true`). A target that pre-exists as a
  ## regular file or a link to a different source is a CONFLICT —
  ## `EStowConflict` is raised under `srpFailClosed`, leaving the
  ## target byte-identical; under `srpReconcileDrift` the prior
  ## content is recorded (`preWriteDigest`) and the target replaced.
  result.sourceAbsolutePath = entry.sourceAbsolutePath
  result.homeRelativePath = entry.homeRelativePath
  result.targetAbsolutePath = entry.targetAbsolutePath
  # Capture the prior content BEFORE any mutation. For a correct
  # symlink this reads the (identical) source bytes; for a conflicting
  # regular file / wrong link it captures the bytes rollback restores.
  let preDigest = readPreWriteDigest(entry.targetAbsolutePath)
  result.hasPreWriteDigest = preDigest.has
  if preDigest.has:
    result.preWriteDigest = preDigest.digest
  if not fileExists(entry.sourceAbsolutePath):
    raiseMaterializeFailed(entry.targetAbsolutePath,
      "stow source missing: " & entry.sourceAbsolutePath)
  let raw = readFile(entry.sourceAbsolutePath)
  var buf = newSeq[byte](raw.len)
  for i, ch in raw:
    buf[i] = byte(ord(ch))
  result.postWriteDigest = digestBytes(buf)
  # NOTE: we do NOT eagerly `createDir(parentDir(target))` here.
  # The junction fallback below requires the deepest stow-exclusive
  # ancestor to NOT yet exist on disk; eager parent creation would
  # foreclose the junction option. Each branch creates the parent
  # itself when (and only when) it needs it.
  var cacheHit = false
  var reconciled = false
  if tryCreateSymlink(entry.targetAbsolutePath, entry.sourceAbsolutePath,
      reconcile, cacheHit, reconciled):
    result.mode = smSymlink
    result.wasCacheHit = cacheHit
    result.wasReconciled = reconciled
    return
  when defined(windows):
    let stowRoot = profileDir / StowSubdirName
    var junctioned: string
    if tryCreateJunctionAtAncestor(stowRoot, homeDir, entry.homeRelativePath,
        entry.sourceAbsolutePath, junctioned):
      result.mode = smJunction
      return
  # Copy fallback — same non-destructive rule. A target that already
  # exists is inspected before any write:
  #   * byte-identical regular file  → no-op cache-hit.
  #   * differing regular file / wrong link → conflict (fail-closed)
  #     unless reconcile-drift is in effect.
  let parent = parentDir(entry.targetAbsolutePath)
  let inspection = inspectTarget(entry.targetAbsolutePath,
    entry.sourceAbsolutePath)
  case inspection.state
  of tsCorrectLink:
    # A surviving correct link reached the copy fallback (symlink was
    # disabled by the test hook but the link was already present).
    # Leave it — it already resolves to the source.
    result.mode = smCopy
    result.wasCacheHit = true
    return
  of tsRegularFile:
    if preDigest.has and preDigest.digest == result.postWriteDigest:
      # Byte-identical content already in place — no-op cache-hit.
      result.mode = smCopy
      result.wasCacheHit = true
      return
    if reconcile != srpReconcileDrift:
      raiseStowConflict(entry.targetAbsolutePath, inspection.existingKind,
        entry.sourceAbsolutePath)
    result.wasReconciled = true
    try: removeFile(entry.targetAbsolutePath)
    except OSError:
      try: removeDir(entry.targetAbsolutePath) except OSError: discard
  of tsWrongLink:
    if reconcile != srpReconcileDrift:
      raiseStowConflict(entry.targetAbsolutePath, inspection.existingKind,
        entry.sourceAbsolutePath)
    result.wasReconciled = true
    try: removeFile(entry.targetAbsolutePath) except OSError: discard
  of tsAbsent:
    discard
  if parent.len > 0:
    createDir(parent)
  copyFile(entry.sourceAbsolutePath, entry.targetAbsolutePath)
  result.mode = smCopy

proc modeToOwnershipPolicy*(mode: StowMaterializationMode):
    GeneratedFileOwnership =
  case mode
  of smSymlink: gfoStowSymlink
  of smJunction: gfoStowJunction
  of smCopy: gfoStowCopy
