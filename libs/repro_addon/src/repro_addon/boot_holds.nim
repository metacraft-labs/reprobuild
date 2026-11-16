## Start holds across a reboot (ReproOS Add-On Mode spec §10.1, §13
## decision 159; A9 review round 15).
##
## A switch's start holds are runtime drop-ins (``/run/systemd/system/
## <unit>.d/zz-repro-addon-floor-hold.conf``), and a reboot empties
## ``/run``. A switch that is still pending at the reboot -- a revert whose
## persistent hold could not be written, a switch a reset cut short -- is
## replayed by the boot re-assertion, which puts the holds back; but the
## re-assertion runs after ``basic.target``, and the socket, path and timer
## units of ``sockets.target`` / ``paths.target`` / ``timers.target`` start
## before it and cannot be ordered after it (systemd.special(7)). So:
##
## - the switch records the drop-in directories of the start holds it
##   writes, and the hold's text beside them (``writeBootHoldRecord``),
##   durably, before its pending marker; the record goes when the switch
##   lifts its holds (``static_tree.clearBootHoldRecord``) or with the
##   marker;
## - ``repro-addon-boot-hold.service`` (``generation0.bootHoldUnit``), wanted
##   by and ordered before ``sysinit.target``, conditioned on the marker,
##   copies the recorded holds back into place with the base's ``/bin/sh``
##   and reloads systemd once, before any of those units can start;
## - once the re-assertion has resolved the switch (no marker left), it
##   lifts the holds the boot wrote (``releaseBootHolds``). A switch whose
##   check passes clears every start hold in any case
##   (``clearStaleStartHolds``), so an engine without this release leaves
##   them only until its next passing switch.

import std/[os, strutils]

import repro_infra/start_holds

import ./effective_floor
import ./generation0
import ./static_tree

proc validHoldDirName*(name: string): bool =
  ## A record line names one drop-in directory directly under the runtime
  ## unit directory: ``<unit>.d``, no separator, not hidden -- the rule the
  ## boot-hold unit's shell applies too (``bootHoldScript``).
  name.len > 2 and name.endsWith(".d") and '/' notin name and
    '\0' notin name and not name.startsWith(".")

proc writeBootHoldRecord*(stateDir: string; holds: openArray[string]) =
  ## Record the drop-in directories of ``holds`` (start-hold paths) and the
  ## hold's text for the boot-hold unit, each durably (``writeHoldFile``:
  ## written, synced, read back), the text first, so a record is never
  ## there without it. No holds removes the record. Raises ``OSError`` when
  ## either cannot be written: the switch then stops before its marker, so
  ## a pending switch never lacks the record of its holds.
  var lines: seq[string]
  for h in holds:
    let d = extractFilename(parentDir(h))
    if validHoldDirName(d) and d notin lines: lines.add(d)
  if lines.len == 0:
    clearBootHoldRecord(stateDir)
    return
  createDir(parentDir(bootHoldRecordPath(stateDir)))
  writeHoldFile(bootHoldTextPath(stateDir), StartHoldText)
  writeHoldFile(bootHoldRecordPath(stateDir), lines.join("\n") & "\n")

proc readBootHoldRecord*(stateDir: string): seq[string] =
  ## The recorded drop-in directory names, invalid lines dropped.
  let p = bootHoldRecordPath(stateDir)
  if symlinkExists(p) or not fileExists(p): return
  for l in readFile(p).splitLines():
    let d = l.strip()
    if validHoldDirName(d) and d notin result: result.add(d)

proc releaseBootHolds*(stateDir: string; reload: proc () {.closure.};
                       writtenPath = BootHoldsWrittenList): seq[string] =
  ## After the re-assertion: when no switch is pending any more, lift the
  ## holds this boot wrote -- each only while it still holds exactly the
  ## start hold's text or the minimal hold's -- and reload. A switch still pending keeps them.
  if hasPendingMarker(stateDir): return
  if symlinkExists(writtenPath) or not fileExists(writtenPath): return
  var lifted: seq[string]
  for l in readFile(writtenPath).splitLines():
    let p = l.strip()
    if p.len == 0 or not p.endsWith("/" & StartHoldName) or
        not validHoldDirName(extractFilename(parentDir(p))) or p in lifted:
      continue
    if symlinkExists(p) or not fileExists(p): continue
    var c = ""
    try: c = readFile(p)
    except IOError, OSError: continue
    # The start hold, or the minimal one the script writes when it cannot
    # copy that text (A9 review round 17, finding 9).
    if c != StartHoldText and c != MinimalHoldText: continue
    removeHolds([p])
    lifted.add(p)
  removeFile(writtenPath)
  if lifted.len > 0:
    try:
      reload()
      result.add("lifted the boot's " & $lifted.len & " start hold(s): " &
                 "the pending switch is resolved")
    except CatchableError as e:
      result.add("lifted the boot's start holds but systemd was not " &
                 "reloaded: " & e.msg)
