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

proc tryCreateSymlink(target, source: string): bool =
  ## Attempt a symlink. Early-returns when the test hook disables
  ## symlinks WITHOUT mutating the filesystem — pre-creating the
  ## target's parent dir would defeat the junction fallback below,
  ## which keys off "ancestor does not yet exist on disk."
  if getEnv(DisableSymlinkEnvVar) == "1":
    return false
  try:
    if fileExists(target) or symlinkExists(target):
      removeFile(target)
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
                          entry: StowEntry): AppliedStowRecord =
  ## Apply one stow entry through the symlink → junction → copy
  ## decision tree. The selected mode is returned so the pipeline
  ## emits `IStowFellBack` on the first fallback within a generation.
  result.sourceAbsolutePath = entry.sourceAbsolutePath
  result.homeRelativePath = entry.homeRelativePath
  result.targetAbsolutePath = entry.targetAbsolutePath
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
  if tryCreateSymlink(entry.targetAbsolutePath, entry.sourceAbsolutePath):
    result.mode = smSymlink
    return
  when defined(windows):
    let stowRoot = profileDir / StowSubdirName
    var junctioned: string
    if tryCreateJunctionAtAncestor(stowRoot, homeDir, entry.homeRelativePath,
        entry.sourceAbsolutePath, junctioned):
      result.mode = smJunction
      return
  # Copy fallback.
  let parent = parentDir(entry.targetAbsolutePath)
  if parent.len > 0:
    createDir(parent)
  if fileExists(entry.targetAbsolutePath):
    try: removeFile(entry.targetAbsolutePath) except OSError: discard
  copyFile(entry.sourceAbsolutePath, entry.targetAbsolutePath)
  result.mode = smCopy

proc modeToOwnershipPolicy*(mode: StowMaterializationMode):
    GeneratedFileOwnership =
  case mode
  of smSymlink: gfoStowSymlink
  of smJunction: gfoStowJunction
  of smCopy: gfoStowCopy
