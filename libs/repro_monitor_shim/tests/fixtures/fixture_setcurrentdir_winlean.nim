# M73 Phase 5 — winlean dispatch for SetCurrentDirectoryW.
#
# Nim 2.2.8 `lib/windows/winlean.nim:229-230` declares:
#   proc setCurrentDirectoryW*(lpPathName: WideCString): int32
#     {.importc: "SetCurrentDirectoryW", stdcall, dynlib: "kernel32".}
#
# Dynlib-dispatched. Each call emits one mrFileOpen record (mapped to
# moExecute observation kind, see snoop comment in windows_interpose.nim)
# with detail "SetCurrentDirectoryW" and the requested path. The test
# asserts the count of mrFileOpen records whose detail is
# "SetCurrentDirectoryW" and whose path contains the marker substring
# equals N.
#
# Invocation: fixture_setcurrentdir_winlean.exe <marker> <count>

import std/[os, strutils, winlean]

when isMainModule:
  if paramCount() != 2:
    stderr.writeLine("usage: " & getAppFilename() & " <marker> <count>")
    quit(2)
  let marker = paramStr(1)
  let count = parseInt(paramStr(2))
  if count <= 0:
    stderr.writeLine("count must be > 0")
    quit(2)
  # Pre-create directories so the kernel actually accepts the cwd switch.
  # SetCurrentDirectoryW fails (returns 0) if the path doesn't exist,
  # but the depfile record is emitted regardless.
  let originalCwd = getCurrentDir()
  for i in 0 ..< count:
    let dir = marker & "." & $i & ".dir"
    createDir(dir)
    let wdir = newWideCString(dir)
    let rc = setCurrentDirectoryW(wdir)
    if rc == 0:
      stderr.writeLine("setCurrentDirectoryW returned 0 for " & dir)
    # Restore cwd after each call so subsequent relative paths still
    # resolve to <marker>.<i+1>.dir under the originalCwd.
    let woriginal = newWideCString(originalCwd)
    discard setCurrentDirectoryW(woriginal)
