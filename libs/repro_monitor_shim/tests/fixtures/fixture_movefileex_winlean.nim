# M73 Phase 5 — winlean dispatch for MoveFileExW.
#
# Nim 2.2.8 `lib/windows/winlean.nim:326-329` declares:
#   proc moveFileExW*(lpExistingFileName, lpNewFileName: WideCString,
#                     dwFlags: DWORD): WINBOOL
#     {.importc: "MoveFileExW", stdcall, dynlib: "kernel32".}
#
# Dynlib-dispatched. The snoop emits TWO records per successful call: an
# mrFileWrite for the source path ("MoveFileExW:src") and an mrFileWrite
# for the destination ("MoveFileExW:dst"). The test asserts the
# destination-side count equals N.
#
# Invocation: fixture_movefileex_winlean.exe <marker> <count>

import std/[os, strutils, winlean]

const MOVEFILE_REPLACE_EXISTING = 0x1'i32
const MOVEFILE_COPY_ALLOWED     = 0x2'i32

when isMainModule:
  if paramCount() != 2:
    stderr.writeLine("usage: " & getAppFilename() & " <marker> <count>")
    quit(2)
  let marker = paramStr(1)
  let count = parseInt(paramStr(2))
  if count <= 0:
    stderr.writeLine("count must be > 0")
    quit(2)
  for i in 0 ..< count:
    let src = marker & "." & $i & ".src"
    let dst = marker & "." & $i & ".dst"
    writeFile(src, "")
    let wsrc = newWideCString(src)
    let wdst = newWideCString(dst)
    let rc = moveFileExW(wsrc, wdst,
      DWORD(MOVEFILE_REPLACE_EXISTING or MOVEFILE_COPY_ALLOWED))
    if rc == 0:
      stderr.writeLine("moveFileExW returned 0 for " & src & " -> " & dst)
