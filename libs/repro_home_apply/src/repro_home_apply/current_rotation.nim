## Apply pipeline step 10: rotate the `current` pointer to the new
## generation.
##
## Per-platform contracts from
## [Home-Profile-Generations-And-State.md] "State Directory" and
## [Launch-Plans-And-Platform-Launchers.md] "Materialization Into
## Home Profile Bin Dirs":
##
##   * Linux / macOS: `<state-dir>/current` is a symlink to
##     `<state-dir>/generations/<gen-id>`. Rotation is `remove +
##     createSymlink` (atomic from the user's perspective because
##     `current` always exists either with the old target or the
##     new one — the brief window between remove and create is the
##     standard POSIX symlink-rotation race, accepted by the spec).
##   * Windows: there is no symlink. Instead the pipeline keeps a
##     stable bin dir at `<state-dir>/bin/` (referenced once by the
##     user's PATH) and mirrors the new generation's per-generation
##     `bin/` into it. The `current.txt` text file is updated last;
##     readers that race in between still observe the previous
##     generation's id because the mirror copy is committed before
##     `current.txt`.

import std/[os]

import repro_home_generations

import ./errors

const
  StableBinDirName* = "bin"
    ## Windows: lives at `<state-dir>/bin/`. On POSIX this name is
    ## unused; the per-generation `bin/` is reached through the
    ## `current` symlink instead.

proc stableBinDir*(stateDir: string): string =
  stateDir / StableBinDirName

proc generationBinDir*(stateDir, generationId: string): string =
  generationDir(stateDir, generationId) / "bin"

proc clearDirEntries(dir: string) =
  if not dirExists(dir):
    return
  for kind, entry in walkDir(dir, relative = false):
    case kind
    of pcFile, pcLinkToFile:
      try:
        removeFile(entry)
      except OSError:
        discard
    of pcDir:
      try:
        removeDir(entry)
      except OSError:
        discard
    of pcLinkToDir:
      when defined(windows):
        # NTFS junction: removeDir would recurse into the target;
        # use `rmdir` which removes the reparse point only.
        try:
          removeDir(entry)
        except OSError:
          discard
      else:
        try:
          removeFile(entry)
        except OSError:
          discard

proc mirrorBinDir(srcBinDir, dstBinDir: string) =
  ## Copy every entry from `srcBinDir` into `dstBinDir`. The src dir
  ## was already populated by `materializeLaunchers`; we copy because
  ## the stable dir lives outside any one generation and survives
  ## rollback.
  createDir(dstBinDir)
  for kind, entry in walkDir(srcBinDir, relative = false):
    let leaf = extractFilename(entry)
    let dst = dstBinDir / leaf
    case kind
    of pcFile, pcLinkToFile:
      try:
        copyFile(entry, dst)
      except OSError as err:
        raiseCurrentRotationFailed(dst,
          "could not mirror launcher file into stable bin dir: " & err.msg)
    of pcDir, pcLinkToDir:
      # Phase A has no nested per-command dirs; if a future plan does,
      # extend this with a recursive copy. For now, skip with a
      # diagnostic so corruption is visible rather than silent.
      raiseCurrentRotationFailed(dst,
        "unexpected nested directory in per-generation bin/: " & entry)

proc rotateCurrent*(stateDir, generationId: string) =
  ## Switch the `current` pointer to the new generation.
  ##
  ## After this returns, the user's shell PATH (which has either
  ## `<state-dir>/current/bin` on POSIX or `<state-dir>/bin` on
  ## Windows on it) reaches the new generation's launchers.
  ##
  ## The function NEVER raises after `current` has been advanced —
  ## any post-rotation error is the responsibility of step 11
  ## (manifest commit), and step 11's only failure mode is an I/O
  ## error during CAS seal, which the pipeline classifies as a
  ## "committed-but-unsealed" condition that is recoverable on the
  ## next apply.
  let genDir = generationDir(stateDir, generationId)
  if not dirExists(genDir):
    raiseCurrentRotationFailed(genDir,
      "expected generation directory does not exist on disk")
  when defined(windows):
    let stable = stableBinDir(stateDir)
    let srcBin = generationBinDir(stateDir, generationId)
    if dirExists(srcBin):
      # Wipe the stable bin dir, then mirror the new generation's
      # bin entries in. Wiping is safe because every entry in the
      # stable dir was put there by a previous apply and is fully
      # described by the previous generation's activation manifest;
      # the next apply re-populates with the current generation's
      # entries.
      clearDirEntries(stable)
      createDir(stable)
      mirrorBinDir(srcBin, stable)
    writeCurrentGenerationId(stateDir, generationId)
  else:
    writeCurrentGenerationId(stateDir, generationId)

proc demoteCurrent*(stateDir: string) =
  ## Reset `current` to "no active generation". Used by the partial-
  ## apply recovery path when the only generation present is the one
  ## we just aborted.
  let p = currentPath(stateDir)
  if fileExists(p) or symlinkExists(p):
    try: removeFile(p) except OSError: discard
  when defined(windows):
    clearDirEntries(stableBinDir(stateDir))
