# M73 Phase 2 — dispatch-mechanism 3: Nim winlean `{.importc, stdcall,
# dynlib: "kernel32".}` declaration.
#
# This is the load-bearing case that motivated M73. Nim's codegen
# lowers a `{.dynlib.}`-imported proc to a `nimGetProcAddr` call at
# module-init time; the resulting function pointer is cached in a
# module-global and every call site jumps through it. The IAT is
# never consulted, so pre-M73 the shim's IAT-only install missed
# every winlean.* call — including the ones inside Nim's own
# `os.removeFile`, `os.fileExists`, `os.getFileInfo`, etc. Post-M73
# the inline detour at the kernel32 function body catches it.
#
# We use winlean's own `createFileW` so the lowering this fixture
# exercises is bit-for-bit identical to the one production Nim code
# uses. We do NOT route through `std/syncio` `open` or `os.readFile`
# — those go through CRT's `fopen` which hits a CRT-internal IAT
# slot; the IAT slot IS hooked by the legacy IAT-patch fallback, so
# a test built around fopen would silently pass even if the inline
# path were broken. Calling winlean's dynlib-resolved proc directly
# guarantees the call goes through the cached function pointer that
# only the inline detour can catch.
#
# Invocation: fixture_mech3_winlean.exe <marker> <count>

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
    let wpath = newWideCString(path)
    # winlean.createFileW is declared
    # `{.importc, stdcall, dynlib: "kernel32".}` so the call goes
    # through Nim's nimGetProcAddr-cached function pointer — the IAT
    # is bypassed. The shim's inline detour at the kernel32 function
    # body MUST intercept it; the depfile records exactly one
    # mrFileOpen record per iteration with the marker substring in
    # its path.
    let h = createFileW(wpath, GENERIC_READ.DWORD, FILE_SHARE_READ.DWORD,
                        nil, OPEN_ALWAYS.DWORD, FILE_ATTRIBUTE_NORMAL.DWORD,
                        Handle(0))
    if h != INVALID_HANDLE_VALUE_LIT:
      discard closeHandle(h)
    else:
      # Diagnostic; the depfile records the call regardless. We do
      # NOT exit on failure — every call must reach the depfile so
      # the per-mechanism record count equals exactly N.
      stderr.writeLine("createFileW failed for " & path)
