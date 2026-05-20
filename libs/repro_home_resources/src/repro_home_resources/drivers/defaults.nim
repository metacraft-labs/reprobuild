## `macos.userDefault` driver — Phase B.
##
## Reads / writes / deletes per-user macOS preferences via the
## `defaults` command-line tool. Detects sandboxed-app container
## plists and falls back to `EUnsupportedDomain` when the domain
## is not writable from the current process.
##
## Optional `restartTarget` runs `killall <target>` after a write
## that actually changed the value (a cache-hit re-apply does NOT
## invoke `killall`).
##
## Phase A ships the skeleton; gate 3 (`e2e_macos_user_default_
## restart_target`) runs on macOS hosts and skips on Windows.

import std/[osproc, strutils]

import ./../errors
import ./../manifest_record
import ./../types

proc observeUserDefault*(domain, key: string): ObservedState =
  when defined(macosx):
    let (output, exitCode) = execCmdEx("defaults read " & domain & " " & key)
    if exitCode != 0:
      result.present = false
      result.digest = zeroDigest()
      return
    let val = output.strip()
    var raw = newSeq[byte](val.len)
    for i, ch in val:
      raw[i] = byte(ord(ch))
    result.present = true
    result.rawBytes = raw
    result.digest = digestOfBytes(raw)
  else:
    raiseNotImplementedPlatform("macos.userDefault", "macosx")

proc applyUserDefault*(domain, key, valueLiteral: string;
                      restartTarget: string;
                      valueChanged: bool):
    seq[byte] =
  when defined(macosx):
    let cmd = "defaults write " & domain & " " & key & " " & valueLiteral
    let exitCode = execCmd(cmd)
    if exitCode != 0:
      raiseUnsupportedDomain(domain,
        "defaults write returned exit " & $exitCode)
    if restartTarget.len > 0 and valueChanged:
      discard execCmd("killall " & restartTarget)
    result = newSeq[byte](valueLiteral.len)
    for i, ch in valueLiteral:
      result[i] = byte(ord(ch))
  else:
    raiseNotImplementedPlatform("macos.userDefault", "macosx")

proc destroyUserDefault*(domain, key, restartTarget: string) =
  when defined(macosx):
    discard execCmd("defaults delete " & domain & " " & key)
    if restartTarget.len > 0:
      discard execCmd("killall " & restartTarget)
  else:
    raiseNotImplementedPlatform("macos.userDefault", "macosx")
