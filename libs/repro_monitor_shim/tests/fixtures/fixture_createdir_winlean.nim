# M73 Phase 5 — winlean dispatch for CreateDirectoryW.
#
# Nim 2.2.8 `lib/windows/winlean.nim:231-233` declares:
#   proc createDirectoryW*(pathName: WideCString, security: pointer=nil): int32
#     {.importc: "CreateDirectoryW", stdcall, dynlib: "kernel32".}
#
# Same dynlib-dispatch pattern as createFileW: the call goes through
# Nim's nimGetProcAddr-cached function pointer (the IAT is bypassed) so
# only the Phase 5 inline detour at kernel32!CreateDirectoryW catches it.
#
# Invocation: fixture_createdir_winlean.exe <marker> <count>
#
# Creates <marker>.<i>.dir for i in [0, count). Each call emits one
# mrFileWrite record with detail "CreateDirectoryW".

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
  for i in 0 ..< count:
    let path = marker & "." & $i & ".dir"
    let wpath = newWideCString(path)
    let rc = createDirectoryW(wpath, nil)
    if rc == 0:
      # Diagnostic — the depfile records the call regardless of return.
      # Likely cause is "directory already exists" on a re-run, which is
      # fine for the per-call count assertion the test makes.
      stderr.writeLine("createDirectoryW non-zero rc for " & path)
