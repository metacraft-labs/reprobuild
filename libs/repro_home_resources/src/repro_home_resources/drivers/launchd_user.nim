## `launchd.userAgent` driver — Phase B.
##
## Writes a plist under `~/Library/LaunchAgents/<label>.plist` and
## runs `launchctl load`. Drift = file digest changed.

import std/[os, osproc]

import ./../errors
import ./../manifest_record
import ./../types

proc agentPlistPath*(homeDir, label: string): string =
  homeDir / "Library" / "LaunchAgents" / (label & ".plist")

proc observeLaunchAgent*(homeDir, label: string): ObservedState =
  when defined(macosx):
    let path = agentPlistPath(homeDir, label)
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
    raiseNotImplementedPlatform("launchd.userAgent", "macosx")

proc applyLaunchAgent*(homeDir, label, plistContent: string;
                      runAtLoad: bool): seq[byte] =
  when defined(macosx):
    let path = agentPlistPath(homeDir, label)
    createDir(parentDir(path))
    writeFile(path, plistContent)
    discard execCmd("launchctl load " & path)
    if runAtLoad:
      discard execCmd("launchctl start " & label)
    result = newSeq[byte](plistContent.len)
    for i, ch in plistContent:
      result[i] = byte(ord(ch))
  else:
    raiseNotImplementedPlatform("launchd.userAgent", "macosx")

proc destroyLaunchAgent*(homeDir, label: string) =
  when defined(macosx):
    let path = agentPlistPath(homeDir, label)
    discard execCmd("launchctl unload " & path)
    if fileExists(path):
      try: removeFile(path) except OSError: discard
  else:
    raiseNotImplementedPlatform("launchd.userAgent", "macosx")
