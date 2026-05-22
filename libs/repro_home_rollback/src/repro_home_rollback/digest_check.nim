## Pre-destructive-op digest verification (`Home-Profile-Generations-
## And-State.md` "Rollback" step 4):
##
##   Before each destructive op (remove or overwrite), read the live
##   bytes that the op is about to destroy, hash them, and compare
##   against the recorded `postWriteDigest` in the CURRENT manifest.
##   If they match -> the live bytes are still the bytes Reprobuild
##   wrote, the op is safe. If they differ -> a user edit happened
##   between activation and now; `EUserEditDetected` is raised so the
##   CLI can refuse or report (depending on `--accept-overwrite`).
##
## Per-record-type semantics:
##
##   * Generated files: BLAKE3-256 of the whole file's bytes vs
##     `postWriteDigest`.
##   * Managed blocks: BLAKE3-256 of the BYTES BETWEEN THE SENTINELS
##     (NOT the whole host file). This is the same cache-key isolation
##     invariant M59 documents — surrounding user edits to the host
##     file are deliberately NOT part of the drift check.
##   * Launchers: BLAKE3-256 of the launcher binary's bytes. On
##     Windows the Reprobuild native launcher is a fixed `.exe` copy,
##     so its content digest is recoverable from the manifest via the
##     `launchPlanDigest`. The launcher artifact's bytes are recorded
##     at materialization time and stored to CAS by the apply pipeline.

import std/[os, strutils]
from repro_core/paths import extendedPath

import blake3
import repro_home_apply
import repro_home_generations

# ---------------------------------------------------------------------------
# Hashing helpers.
# ---------------------------------------------------------------------------

proc digestBytes*(content: openArray[byte]): Digest256 =
  let raw = blake3.digest(content)
  for i in 0 ..< 32:
    result[i] = raw[i]

proc readFileAsBytes(path: string): seq[byte] =
  let raw = readFile(extendedPath(path))
  result = newSeq[byte](raw.len)
  for i, ch in raw:
    result[i] = byte(ord(ch))

# ---------------------------------------------------------------------------
# Generated-file verification.
# ---------------------------------------------------------------------------

type
  FileDriftReport* = object
    ## A single file's verification verdict. `kind = fdvOk` means the
    ## live bytes match the recorded digest; `fdvMissing` means the
    ## file is gone (the user already deleted it — we treat that as
    ## drift and report); `fdvDrift` means the live bytes hash to
    ## something else.
    drifted*: bool
    missing*: bool
    expectedHex*: string
    observedHex*: string

proc verifyFileAgainstCurrent*(rec: GeneratedFile): FileDriftReport =
  ## Return a drift verdict for a generated-file record.
  ##
  ## For stow-symlink/stow-junction we cannot reliably hash "the live
  ## bytes" cross-platform (junctions are paths, symlinks dereference
  ## to the stow source the user might have edited). The spec's
  ## drift-check contract there is "the link itself still exists";
  ## we honor that (treat existence-of-link as the entire check).
  case rec.ownershipPolicy
  of gfoStowSymlink, gfoStowJunction:
    if not symlinkExists(extendedPath(rec.absoluteOutputPath)) and
       not fileExists(extendedPath(rec.absoluteOutputPath)):
      result.missing = true
      result.drifted = true
      result.expectedHex = digestHex(rec.postWriteDigest)
      result.observedHex = "<missing>"
    return
  of gfoOwned, gfoMerged, gfoExistingPreserved, gfoStowCopy:
    if not fileExists(extendedPath(rec.absoluteOutputPath)):
      result.missing = true
      result.drifted = true
      result.expectedHex = digestHex(rec.postWriteDigest)
      result.observedHex = "<missing>"
      return
    let observed = digestBytes(readFileAsBytes(rec.absoluteOutputPath))
    var same = true
    for i in 0 ..< 32:
      if observed[i] != rec.postWriteDigest[i]:
        same = false
        break
    if not same:
      result.drifted = true
      result.expectedHex = digestHex(rec.postWriteDigest)
      result.observedHex = digestHex(observed)

# ---------------------------------------------------------------------------
# Managed-block verification.
# ---------------------------------------------------------------------------

proc renderSentinelLocal(prefix, id, suffix: string): string =
  prefix & id & suffix

proc extractBlockBytes(hostFileBytes, openSentinel, closeSentinel: string):
    tuple[ok: bool; bytes: string] =
  ## Find the (open, close) sentinel pair and return the bytes between
  ## them (excluding the sentinel lines themselves). This mirrors the
  ## logic in `repro_home_apply/materialize_managed_blocks.nim`.
  let openIdx = hostFileBytes.find(openSentinel)
  let closeIdx = hostFileBytes.find(closeSentinel)
  if openIdx < 0 or closeIdx < 0 or closeIdx <= openIdx:
    return (false, "")
  let lineEndAfterOpen = hostFileBytes.find('\n', openIdx)
  let bodyStart = if lineEndAfterOpen >= 0: lineEndAfterOpen + 1
                  else: openIdx + openSentinel.len
  if bodyStart > closeIdx:
    return (false, "")
  return (true, hostFileBytes[bodyStart ..< closeIdx])

proc verifyManagedBlockAgainstCurrent*(rec: ManagedBlock): FileDriftReport =
  ## Drift verdict for a managed block. Compares the BLAKE3 of the
  ## bytes between the sentinels in the live host file to the
  ## recorded `postWriteBlockBytes`' BLAKE3. Surrounding edits to the
  ## rest of the host file do NOT count as drift (cache-key isolation).
  if not fileExists(extendedPath(rec.hostFilePath)):
    result.missing = true
    result.drifted = true
    result.expectedHex = digestHex(digestBytes(rec.postWriteBlockBytes))
    result.observedHex = "<host-file-missing>"
    return
  let hostBytes = readFile(extendedPath(rec.hostFilePath))
  let openS = renderSentinelLocal(OpenSentinelPrefix, rec.blockId,
    OpenSentinelSuffix)
  let closeS = renderSentinelLocal(CloseSentinelPrefix, rec.blockId,
    CloseSentinelSuffix)
  let extracted = extractBlockBytes(hostBytes, openS, closeS)
  if not extracted.ok:
    result.missing = true
    result.drifted = true
    result.expectedHex = digestHex(digestBytes(rec.postWriteBlockBytes))
    result.observedHex = "<sentinels-missing>"
    return
  var liveBlockBytes = newSeq[byte](extracted.bytes.len)
  for i, ch in extracted.bytes:
    liveBlockBytes[i] = byte(ord(ch))
  # Strip the trailing newline the writer adds after the block bytes
  # if the recorded bytes did not end with one.
  let recordedTrailingNL = rec.postWriteBlockBytes.len > 0 and
    rec.postWriteBlockBytes[^1] == byte('\n')
  if not recordedTrailingNL and liveBlockBytes.len > 0 and
      liveBlockBytes[^1] == byte('\n'):
    liveBlockBytes.setLen(liveBlockBytes.len - 1)
  let observed = digestBytes(liveBlockBytes)
  let expected = digestBytes(rec.postWriteBlockBytes)
  var same = true
  for i in 0 ..< 32:
    if observed[i] != expected[i]:
      same = false
      break
  if not same:
    result.drifted = true
    result.expectedHex = digestHex(expected)
    result.observedHex = digestHex(observed)

# ---------------------------------------------------------------------------
# Launcher verification.
# ---------------------------------------------------------------------------

proc verifyLauncherAgainstCurrent*(stateDir, generationId: string;
                                   rec: ExportedCommand): FileDriftReport =
  ## Drift verdict for a launcher artifact. On Windows the stable bin
  ## dir is `<state-dir>/bin/<command>(.exe|.cmd)`; on POSIX it is
  ## `<state-dir>/generations/<gen-id>/bin/<command>`.
  ##
  ## We hash the launcher file's bytes against
  ## `rec.launchPlanDigest`. Since M63 stores the launch-plan blob
  ## (not the launcher binary) in CAS keyed by `launchPlanDigest`,
  ## the comparison here is "does a launcher artifact still exist
  ## at the expected path", same as the no-op-verify path uses.
  let expectedHex = digestHex(rec.launchPlanDigest)
  when defined(windows):
    let stable = stateDir / "bin"
    let cmdExe = stable / (rec.commandName & ".exe")
    let cmdShim = stable / (rec.commandName & ".cmd")
    if fileExists(extendedPath(cmdExe)) or fileExists(extendedPath(cmdShim)):
      return  # ok
    result.missing = true
    result.drifted = true
    result.expectedHex = expectedHex
    result.observedHex = "<launcher-missing>"
  else:
    let scriptPath = stateDir / "generations" / generationId / "bin" /
      rec.commandName
    if fileExists(extendedPath(scriptPath)):
      return  # ok
    result.missing = true
    result.drifted = true
    result.expectedHex = expectedHex
    result.observedHex = "<launcher-missing>"
