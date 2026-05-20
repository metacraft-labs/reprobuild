## `systemd.userUnit` driver — Phase B.
##
## Manages a systemd user unit:
##   - apply:   write `~/.config/systemd/user/<name>`, then
##              `systemctl --user daemon-reload`, then optionally
##              `systemctl --user enable --now <name>`.
##   - destroy: `systemctl --user disable --now <name>`, remove the
##              unit file, then `systemctl --user daemon-reload`.
##   - observe: read the unit file + `systemctl --user is-enabled`.
##
## Every filesystem write lives INSIDE the `when defined(linux)`
## guard — the off-Linux path must NOT touch the disk; it raises
## `ENotImplementedPlatform` (fail-closed). On any non-Linux host
## the apply / destroy / observe entry points raise immediately.
##
## ## Pure logic isolated for off-Linux unit testing
##
## `userUnitPath` (the unit-file path derivation) is a pure function
## exercised by the Windows smoke suite.

import std/[osproc, strutils]

when defined(linux):
  import std/os

import ./../errors
import ./../manifest_record
import ./../types

# ---------------------------------------------------------------------------
# Unit-file path derivation (pure).
# ---------------------------------------------------------------------------

proc userUnitPath*(homeDir, name: string): string =
  ## The on-disk location of a systemd user unit. Uses a forward-
  ## slash join so the derivation is platform-independent (the unit
  ## only ever lands on Linux, but the pure helper is unit-tested
  ## on Windows).
  var h = homeDir
  if h.len > 0 and (h[^1] == '/' or h[^1] == '\\'):
    h = h[0 ..< h.len - 1]
  h & "/.config/systemd/user/" & name

# ---------------------------------------------------------------------------
# Driver entry points (platform-bound).
# ---------------------------------------------------------------------------

proc observeUserUnit*(homeDir, name: string): ObservedState =
  ## Read the unit file and query `systemctl --user is-enabled`. The
  ## canonical bytes the digest covers are the unit-file contents.
  when defined(linux):
    let path = userUnitPath(homeDir, name)
    if not fileExists(path):
      result.present = false
      result.digest = zeroDigest()
      return
    let content = readFile(path)
    var raw = newSeq[byte](content.len)
    for i, ch in content:
      raw[i] = byte(ord(ch))
    result.present = true
    result.rawBytes = raw
    result.digest = digestOfBytes(raw)
    # `is-enabled` is read for completeness (drift on the file
    # content is what the lifecycle compares); the exit code is not
    # an error here — a disabled unit is still a valid observation.
    discard execCmdEx("systemctl --user is-enabled " & name)
  else:
    raiseNotImplementedPlatform("systemd.userUnit", "linux")

proc applyUserUnit*(homeDir, name, unitContent: string; enabled: bool):
    seq[byte] =
  ## Write the unit file, `daemon-reload`, then optionally
  ## `enable --now`. All filesystem I/O is inside the linux guard.
  when defined(linux):
    let path = userUnitPath(homeDir, name)
    createDir(parentDir(path))
    writeFile(path, unitContent)
    let (reloadOut, reloadCode) = execCmdEx("systemctl --user daemon-reload")
    if reloadCode != 0:
      raiseResourceDriver("systemd:user:" & name, "systemd.userUnit",
        "systemctl --user daemon-reload",
        "exit " & $reloadCode & ": " & reloadOut.strip())
    if enabled:
      let (enableOut, enableCode) = execCmdEx(
        "systemctl --user enable --now " & name)
      if enableCode != 0:
        raiseResourceDriver("systemd:user:" & name, "systemd.userUnit",
          "systemctl --user enable --now",
          "exit " & $enableCode & ": " & enableOut.strip())
    result = newSeq[byte](unitContent.len)
    for i, ch in unitContent:
      result[i] = byte(ord(ch))
  else:
    raiseNotImplementedPlatform("systemd.userUnit", "linux")

proc destroyUserUnit*(homeDir, name: string) =
  ## `disable --now`, remove the unit file, then `daemon-reload`.
  when defined(linux):
    let path = userUnitPath(homeDir, name)
    discard execCmd("systemctl --user disable --now " & name)
    if fileExists(path):
      try: removeFile(path)
      except OSError: discard
    discard execCmd("systemctl --user daemon-reload")
  else:
    raiseNotImplementedPlatform("systemd.userUnit", "linux")
