## Partial-apply recovery (apply pipeline contract from
## [Home-Profile-Generations-And-State.md] "Partial Apply Recovery").
##
## Mechanism:
##
##   1. When the pipeline commits to creating a new generation (after
##      lock acquisition + intent load + id derivation), it writes a
##      `<state-dir>/apply.in-progress` marker file containing the
##      hex generation id it is about to materialize.
##   2. On clean completion the marker is removed.
##   3. On the next apply, this module first reads the marker; if
##      present, the matching `generations/<id>/` directory is moved
##      to `generations/.aborted/<id>-<reason>/`. The marker is then
##      cleared.
##   4. As a second sweep, every directory under `generations/` that
##      lacks a parseable `pointer.bin` is also moved to
##      `.aborted/<id>-incomplete/`. This catches the case where the
##      marker write itself raced with a power loss before the
##      pipeline could ever write its first state-dir byte.
##
## The current pointer is never touched here — rotation lives in
## `./current_rotation.nim`, and rotation is step 10 of the pipeline.
## So a kill at any earlier step leaves `current` intact.

import std/[os, strutils, times]
from repro_core/paths import extendedPath

import repro_home_generations

const
  ApplyInProgressMarkerName* = "apply.in-progress"
  AbortedDirName* = ".aborted"

type
  AbortedGenerationRecord* = object
    ## Returned by `recoverPartialApply` so the caller can log the
    ## quarantined dirs (the gates assert specific paths).
    originalPath*: string
    quarantinedPath*: string
    reason*: string

proc applyInProgressMarkerPath*(stateDir: string): string =
  stateDir / ApplyInProgressMarkerName

proc abortedDir*(stateDir: string): string =
  generationsRoot(stateDir) / AbortedDirName

proc writeMarker*(stateDir, generationId, reason: string) =
  ## Write the marker. `reason` is recorded so a future post-mortem
  ## tooling can distinguish "killed by signal" from "killed by test
  ## hook" — Phase A only writes "in-progress" but the field is
  ## reserved.
  ensureStateDir(stateDir)
  let p = applyInProgressMarkerPath(stateDir)
  let payload = generationId & "\n" & reason & "\n"
  let tmp = p & ".tmp"
  writeFile(extendedPath(tmp), payload)
  if fileExists(extendedPath(p)):
    try: removeFile(extendedPath(p)) except OSError: discard
  moveFile(extendedPath(tmp), extendedPath(p))

proc clearMarker*(stateDir: string) =
  let p = applyInProgressMarkerPath(stateDir)
  if fileExists(extendedPath(p)):
    try: removeFile(extendedPath(p)) except OSError: discard

proc readMarker*(stateDir: string): tuple[present: bool;
                                          generationId, reason: string] =
  let p = applyInProgressMarkerPath(stateDir)
  if not fileExists(extendedPath(p)):
    return (false, "", "")
  let raw = readFile(extendedPath(p))
  let lines = raw.split('\n')
  result.present = true
  if lines.len >= 1: result.generationId = lines[0].strip()
  if lines.len >= 2: result.reason = lines[1].strip()

proc quarantineGenerationDir(stateDir, generationId, reason: string):
    string =
  ## Move `<state-dir>/generations/<id>/` to
  ## `<state-dir>/generations/.aborted/<id>-<reason>-<timestamp>/`.
  ## Returns the destination path so the caller can record it.
  let src = generationDir(stateDir, generationId)
  if not dirExists(extendedPath(src)):
    return ""
  let aborted = abortedDir(stateDir)
  createDir(extendedPath(aborted))
  let stamp = $getTime().toUnix
  let leaf = generationId & "-" & reason & "-" & stamp
  result = aborted / leaf
  try:
    moveDir(extendedPath(src), extendedPath(result))
  except OSError as err:
    raise newException(IOError,
      "could not quarantine aborted generation " & src & " -> " & result &
      ": " & err.msg)

proc recoverPartialApply*(stateDir: string): seq[AbortedGenerationRecord] =
  ## Run partial-apply recovery on startup of `repro home apply`.
  ## Returns one record per quarantined directory; the caller logs
  ## these to stderr so users see what happened.
  ##
  ## Two sweeps:
  ##   A. The `apply.in-progress` marker is honoured: if it names a
  ##      generation, that generation is unconditionally quarantined.
  ##   B. Every other directory under `generations/` (excluding
  ##      `.aborted/`) that lacks a `pointer.bin` is quarantined as
  ##      `incomplete`.
  if not dirExists(extendedPath(stateDir)):
    return @[]
  let marker = readMarker(stateDir)
  if marker.present and marker.generationId.len > 0:
    let src = generationDir(stateDir, marker.generationId)
    if dirExists(extendedPath(src)):
      let dst = quarantineGenerationDir(stateDir, marker.generationId,
        if marker.reason.len > 0: marker.reason else: "incomplete")
      if dst.len > 0:
        result.add(AbortedGenerationRecord(
          originalPath: src,
          quarantinedPath: dst,
          reason: if marker.reason.len > 0: marker.reason else: "incomplete"))
    clearMarker(stateDir)
  let root = generationsRoot(stateDir)
  if dirExists(extendedPath(root)):
    # TODO(win-longpath): walk results escape; needs review
    for kind, entry in walkDir(root, relative = false):
      if kind notin {pcDir, pcLinkToDir}:
        continue
      let leaf = extractFilename(entry)
      if leaf == AbortedDirName:
        continue
      let pointerFile = entry / PointerFileName
      if fileExists(pointerFile):
        continue
      let dst = quarantineGenerationDir(stateDir, leaf, "incomplete")
      if dst.len > 0:
        result.add(AbortedGenerationRecord(
          originalPath: entry, quarantinedPath: dst,
          reason: "incomplete"))
