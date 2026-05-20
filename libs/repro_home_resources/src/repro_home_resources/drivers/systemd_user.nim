## `systemd.userUnit` driver — Phase B.
##
## Writes a unit under `~/.config/systemd/user/<name>` and runs
## `systemctl --user daemon-reload`. Drift = file digest changed
## since the recorded post-write digest.

import std/[os, osproc]

import ./../errors
import ./../manifest_record
import ./../types

proc userUnitPath*(homeDir, name: string): string =
  homeDir / ".config" / "systemd" / "user" / name

proc observeUserUnit*(homeDir, name: string): ObservedState =
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
  else:
    raiseNotImplementedPlatform("systemd.userUnit", "linux")

proc applyUserUnit*(homeDir, name, unitContent: string; enabled: bool):
    seq[byte] =
  when defined(linux):
    let path = userUnitPath(homeDir, name)
    createDir(parentDir(path))
    writeFile(path, unitContent)
    discard execCmd("systemctl --user daemon-reload")
    if enabled:
      discard execCmd("systemctl --user enable " & name)
    result = newSeq[byte](unitContent.len)
    for i, ch in unitContent:
      result[i] = byte(ord(ch))
  else:
    raiseNotImplementedPlatform("systemd.userUnit", "linux")

proc destroyUserUnit*(homeDir, name: string) =
  when defined(linux):
    let path = userUnitPath(homeDir, name)
    discard execCmd("systemctl --user disable " & name)
    discard execCmd("systemctl --user stop " & name)
    if fileExists(path):
      try: removeFile(path) except OSError: discard
    discard execCmd("systemctl --user daemon-reload")
  else:
    raiseNotImplementedPlatform("systemd.userUnit", "linux")
