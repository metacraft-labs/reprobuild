## `linux.gsettings` driver — Phase B.
##
## Reads / writes / resets GNOME's dconf database via the
## `gsettings` command-line tool. Phase A ships the skeleton so the
## umbrella import compiles on every platform; the Phase A gates
## skip the Linux leg.
##
## Per the spec ("`linux.gsettings`"):
##   - get: `gsettings get <schema>[:<path>] <key>`
##   - set: `gsettings set <schema>[:<path>] <key> <value>`
##   - reset: `gsettings reset <schema>[:<path>] <key>`
##
## Drift detection: compare the `get` output verbatim against the
## recorded post-write payload.

import std/[osproc, strutils]

import ./../errors
import ./../manifest_record
import ./../types

proc gsettingsSchemaSpec*(schema, path: string): string =
  if path.len == 0: schema
  else: schema & ":" & path

proc observeGsettings*(schema, path, key: string): ObservedState =
  when defined(linux):
    let spec = gsettingsSchemaSpec(schema, path)
    let (output, exitCode) = execCmdEx("gsettings get " & spec & " " & key)
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
    raiseNotImplementedPlatform("linux.gsettings", "linux")

proc applyGsettings*(schema, path, key, valueLiteral: string):
    seq[byte] =
  when defined(linux):
    let spec = gsettingsSchemaSpec(schema, path)
    let cmd = "gsettings set " & spec & " " & key & " " & valueLiteral
    let exitCode = execCmd(cmd)
    if exitCode != 0:
      raiseResourceDriver("gsettings:" & spec & ":" & key,
        "linux.gsettings", "gsettings set",
        "exit " & $exitCode)
    result = newSeq[byte](valueLiteral.len)
    for i, ch in valueLiteral:
      result[i] = byte(ord(ch))
  else:
    raiseNotImplementedPlatform("linux.gsettings", "linux")

proc destroyGsettings*(schema, path, key: string) =
  when defined(linux):
    let spec = gsettingsSchemaSpec(schema, path)
    let cmd = "gsettings reset " & spec & " " & key
    discard execCmd(cmd)
  else:
    raiseNotImplementedPlatform("linux.gsettings", "linux")
