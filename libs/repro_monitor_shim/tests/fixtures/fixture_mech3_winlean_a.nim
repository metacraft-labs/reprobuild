# M73 Phase 3 — dispatch-mechanism 3A: Nim winlean `{.importc, stdcall,
# dynlib: "kernel32".}` createFileA.
#
# Parallel of fixture_mech3_winlean.nim but targeting the ANSI variant.
# Nim 2.2.8's `lib/windows/winlean.nim:659-663` declares:
#
#     proc createFileA*(lpFileName: cstring, dwDesiredAccess, dwShareMode: DWORD,
#                       lpSecurityAttributes: pointer,
#                       dwCreationDisposition, dwFlagsAndAttributes: DWORD,
#                       hTemplateFile: Handle): Handle {.
#         stdcall, dynlib: "kernel32", importc: "CreateFileA".}
#
# (Verified at D:\metacraft-dev-deps\nim\2.2.8\prebuilt\nim-2.2.8\lib\
# windows\winlean.nim:659.) This is the same `{.dynlib.}` lowering as
# createFileW: Nim's codegen lowers it to a `nimGetProcAddr` call at
# module-init time and caches the function pointer in a module-global.
# Every call site jumps through that cached pointer, NOT this binary's
# IAT. The shim's hookTable entry HookCreateFileA + the inline detour
# at the kernel32 function body (landed in Phase 1) must catch it.
#
# Invocation: fixture_mech3_winlean_a.exe <marker> <count>

import std/[os, strutils, winlean]

const
  GENERIC_READ = 0x80000000'i32
  FILE_SHARE_READ = 0x1'i32
  OPEN_ALWAYS = 4'i32
  FILE_ATTRIBUTE_NORMAL = 0x80'i32

let INVALID_HANDLE_VALUE_LIT: Handle = cast[Handle](-1)

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
    let path = marker & "." & $i & ".txt"
    # winlean.createFileA takes `lpFileName: cstring` — Nim's string is
    # convertible to cstring as long as it's not collected mid-call; we
    # keep `path` live through the call by binding it to a `let` in this
    # loop body.
    let h = createFileA(path.cstring, GENERIC_READ.DWORD,
                        FILE_SHARE_READ.DWORD, nil,
                        OPEN_ALWAYS.DWORD, FILE_ATTRIBUTE_NORMAL.DWORD,
                        Handle(0))
    if h != INVALID_HANDLE_VALUE_LIT:
      discard closeHandle(h)
    else:
      stderr.writeLine("createFileA failed for " & path)
