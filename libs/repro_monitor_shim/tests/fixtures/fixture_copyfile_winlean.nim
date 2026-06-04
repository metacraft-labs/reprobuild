# M73 Phase 5 — winlean dispatch for CopyFileW.
#
# Nim 2.2.8 `lib/windows/winlean.nim:320-324` declares:
#   proc copyFileW*(lpExistingFileName, lpNewFileName: WideCString,
#                   bFailIfExists: WINBOOL): WINBOOL
#     {.importc: "CopyFileW", stdcall, dynlib: "kernel32".}
#
# Dynlib-dispatched, IAT bypassed. Each successful call emits TWO
# depfile records: an mrFileOpen (read) for the source path with detail
# "CopyFileW:src", and an mrFileWrite for the destination with detail
# "CopyFileW:dst". The test asserts the destination-side count equals N.
#
# Invocation: fixture_copyfile_winlean.exe <marker> <count>

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
  # Pre-create the source file once; CopyFileW reads it count times.
  let src = marker & ".src"
  writeFile(src, "")
  let wsrc = newWideCString(src)
  for i in 0 ..< count:
    let dst = marker & "." & $i & ".dst"
    let wdst = newWideCString(dst)
    # bFailIfExists=0 so re-runs don't error out and the per-call count
    # stays stable across the suite.
    let rc = copyFileW(wsrc, wdst, 0)
    if rc == 0:
      stderr.writeLine("copyFileW returned 0 for " & dst)
