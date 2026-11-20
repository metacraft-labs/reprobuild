## Partial-apply recovery (apply pipeline contract from
## [Home-Profile-Generations-And-State.md] "Partial Apply Recovery").
##
## Mechanism:
##
##   1. When the pipeline commits to creating a new generation (after
##      lock acquisition + intent load + id derivation), it writes a
##      `<state-dir>/apply.in-progress` marker file containing the
##      hex generation id it is about to materialize, and whether that
##      generation's directory was already there (a re-apply of an
##      earlier profile: generation ids are content-addressed).
##   2. The pipeline commits the generation (`pointer.bin`), moves
##      `current` to it, and then removes the marker.
##   3. On the next apply, this module first reads the marker; if
##      present, the matching `generations/<id>/` directory is moved
##      to `generations/.aborted/<id>-<reason>/` -- unless it is
##      committed: `current` names it (the apply died after its
##      switch), or it was there before the apply and still carries a
##      valid `pointer.bin` (a retained generation the apply re-applied).
##      Quarantining either would take away a committed generation:
##      the first leaves `current` naming a directory that is gone, the
##      second deletes a rollback target. The marker is then cleared.
##   4. As a second sweep, every directory under `generations/` that
##      lacks a parseable `pointer.bin` is also moved to
##      `.aborted/<id>-incomplete/`. This catches the case where the
##      marker write itself raced with a power loss before the
##      pipeline could ever write its first state-dir byte.
##   5. A quarantined generation that step 9 committed still has the
##      `profile` store root `writeGeneration` registered under its id;
##      left in place, it keeps the generation's prefixes live through
##      store GC although no generation accounts for them.
##      `releaseQuarantinedRoots` deletes it. The apply calls it after its
##      own switch, just before its eager GC, and on its no-op path --
##      never here, at the start: the usual next step after a crash is to
##      run the same profile again, which reproduces the same id, and its
##      prefixes must stay held until that apply has committed the
##      generation again. Working from what `.aborted/` holds, not from
##      what one recovery moved, also releases a root that a kill between
##      the move and the release, or an older build's recovery, left.
##
## The current pointer is never moved here — rotation lives in
## `./current_rotation.nim`, after the commit. On Windows the stable
## `<state-dir>\bin\` mirror is rebuilt from the generation `current`
## names, because a crash during rotation's mirror copy leaves it holding
## launchers of two generations (`resyncStableBin`).

import std/[os, strutils, times]
from repro_core/paths import extendedPath

import repro_home_generations
import repro_local_store

import ./current_rotation

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

proc writeMarker*(stateDir, generationId, reason: string;
                  preexisting = false) =
  ## Write the marker. `reason` is recorded so a future post-mortem
  ## tooling can distinguish "killed by signal" from "killed by test
  ## hook" — Phase A only writes "in-progress" but the field is
  ## reserved. `preexisting` records that the generation's directory
  ## was already present before this apply, so recovery keeps it.
  ensureStateDir(stateDir)
  let p = applyInProgressMarkerPath(stateDir)
  let payload = generationId & "\n" & reason & "\n" &
    (if preexisting: "preexisting" else: "new") & "\n"
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
                                          generationId, reason: string;
                                          preexisting: bool] =
  ## A marker written before the third line existed reads as `new`.
  let p = applyInProgressMarkerPath(stateDir)
  if not fileExists(extendedPath(p)):
    return (false, "", "", false)
  let raw = readFile(extendedPath(p))
  let lines = raw.split('\n')
  result.present = true
  if lines.len >= 1: result.generationId = lines[0].strip()
  if lines.len >= 2: result.reason = lines[1].strip()
  if lines.len >= 3: result.preexisting = lines[2].strip() == "preexisting"

proc hasValidPointer(stateDir, generationId: string): bool =
  ## False only when `pointer.bin` is missing or structurally corrupt
  ## (torn write, bad magic, length or checksum): the shape an apply that
  ## died before its commit leaves. Recovery moves generations aside on
  ## this answer, on every apply, so anything that does not prove an
  ## unfinished generation keeps it: a schema version this build does not
  ## understand (written by a newer `repro`; going back to an older build
  ## must not quarantine every rollback target) and an I/O error reading
  ## the file (a transient sharing violation on Windows) both read as valid.
  try:
    discard readPointerFile(pointerPath(stateDir, generationId))
    true
  except EPointerCorrupt as err:
    err.field == "schemaVersion"
  except CatchableError:
    true

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

proc quarantinedGenerationId(leaf: string): string =
  ## The generation id a `.aborted/` entry was named after
  ## (`<id>-<reason>-<timestamp>`, `generationIdHex`: lowercase hex), or ""
  ## for an entry this module did not name.
  let dash = leaf.find('-')
  result = if dash < 0: leaf else: leaf[0 ..< dash]
  if result.len != 2 * GenerationIdSize:
    return ""
  for ch in result:
    if ch notin {'0'..'9', 'a'..'f'}:
      return ""

proc releaseQuarantinedRoots*(stateDir: string; store: var Store):
    seq[string] =
  ## Delete the `profile` root of every generation id quarantined under
  ## `.aborted/` that has no directory under `generations/` and is not the
  ## one `current` names. Returns the ids whose roots were deleted
  ## (deleting a root that is already gone changes nothing).
  ##
  ## An id that still names a directory under `generations/` keeps its
  ## root: generation ids are content-addressed, so the same profile
  ## applied again since the crash recreated the generation, and it holds
  ## its prefixes through the same root. Only real directories count, in
  ## `.aborted/` and in `generations/`: a symlink is neither a quarantined
  ## generation nor a live one.
  let aborted = abortedDir(stateDir)
  if not dirExists(extendedPath(aborted)):
    return @[]
  let active = readCurrentGenerationId(stateDir)
  # TODO(win-longpath): walk results escape; needs review
  for kind, entry in walkDir(aborted, relative = false):
    if kind != pcDir:
      continue
    let id = quarantinedGenerationId(extractFilename(entry))
    if id.len == 0 or id == active or id in result:
      continue
    let live = generationDir(stateDir, id)
    if dirExists(extendedPath(live)) or symlinkExists(extendedPath(live)):
      continue
    result.add(id)
  for id in result:
    store.deleteRoot(id)

proc recoverPartialApply*(stateDir: string): seq[AbortedGenerationRecord] =
  ## Run partial-apply recovery on startup of `repro home apply`.
  ## Returns one record per quarantined directory; the caller logs
  ## these to stderr so users see what happened.
  ##
  ## Two sweeps:
  ##   A. The `apply.in-progress` marker is honoured: if it names a
  ##      generation, that generation is quarantined unless it is
  ##      committed -- `current` names it, or it predates the apply and
  ##      its `pointer.bin` is valid. On Windows the stable bin mirror
  ##      is then rebuilt from the generation `current` names.
  ##   B. Every other directory under `generations/` (excluding
  ##      `.aborted/` and the one `current` names) whose `pointer.bin`
  ##      is missing or unreadable is quarantined as `incomplete`.
  if not dirExists(extendedPath(stateDir)):
    return @[]
  let marker = readMarker(stateDir)
  if marker.present and marker.generationId.len > 0:
    let src = generationDir(stateDir, marker.generationId)
    let committed =
      readCurrentGenerationId(stateDir) == marker.generationId or
      (marker.preexisting and hasValidPointer(stateDir, marker.generationId))
    if dirExists(extendedPath(src)) and not committed:
      let dst = quarantineGenerationDir(stateDir, marker.generationId,
        if marker.reason.len > 0: marker.reason else: "incomplete")
      if dst.len > 0:
        result.add(AbortedGenerationRecord(
          originalPath: src,
          quarantinedPath: dst,
          reason: if marker.reason.len > 0: marker.reason else: "incomplete"))
  if marker.present:
    # Clear the marker first: the generation decision above is final, and
    # a resync that fails (a running launcher Windows will not let us
    # replace) must not leave a marker that fails every later apply. The
    # apply's own switch rewrites the stable bin dir in full anyway.
    clearMarker(stateDir)
    try:
      resyncStableBin(stateDir)
    except CatchableError as err:
      stderr.writeLine("warning: partial-apply recovery could not rebuild " &
        "the stable launcher directory from the current generation (" &
        err.msg & "); a launcher may still be running. The next " &
        "successful apply rewrites it.")
  let root = generationsRoot(stateDir)
  # The generation `current` names is never quarantined, whatever its
  # pointer: moving it away would leave `current` naming nothing.
  let active = readCurrentGenerationId(stateDir)
  if dirExists(extendedPath(root)):
    # TODO(win-longpath): walk results escape; needs review
    for kind, entry in walkDir(root, relative = false):
      if kind notin {pcDir, pcLinkToDir}:
        continue
      let leaf = extractFilename(entry)
      if leaf == AbortedDirName or leaf == active:
        continue
      if hasValidPointer(stateDir, leaf):
        continue
      let dst = quarantineGenerationDir(stateDir, leaf, "incomplete")
      if dst.len > 0:
        result.add(AbortedGenerationRecord(
          originalPath: entry, quarantinedPath: dst,
          reason: "incomplete"))
