# M73 Phase 2 — dispatch-mechanism 4: real-world Nim `std/os` caller
# whose underlying winlean dynlib-dispatch lands on a hooked kernel32 API.
#
# The milestone names `os.removeFile` as the canonical example, with a
# pointer to verify the underlying call against Nim 2.2.8's
# `lib/std/private/osfiles.nim`. Verification (2026-06-04 against
# Nim 2.2.8): `os.removeFile` -> `tryRemoveFile` -> `deleteFileW`
# (`lib/std/private/osfiles.nim:339`, template `deleteFile` aliased to
# `winlean.deleteFileW` at line 335). `winlean.deleteFileW` itself is
# declared `{.importc, dynlib: "kernel32", stdcall.}` at
# `lib/windows/winlean.nim:657`.
#
# However: the Reprobuild monitor shim's M73 Phase 1 hookTable hooks
# CreateFileW/A, ReadFile, WriteFile, CloseHandle, GetFileAttributes(Ex)W/A,
# CreateProcessW/A — `DeleteFileW` is on the Phase 5 backlog, not the
# Phase 1 install set. A test built around `os.removeFile` would therefore
# fail today not because the inline-detour install path is broken but
# because the API isn't in the table at all. That confuses the
# acceptance signal mechanism 4 exists to provide.
#
# To preserve mechanism 4's INTENT — "real-world Nim os.* caller whose
# kernel32 call lands on a winlean dynlib-dispatched function pointer
# the inline detour MUST catch" — we use `os.fileExists` instead. Its
# Nim 2.2.8 implementation is (verified at
# `lib/std/private/oscommon.nim:111-126`):
#
#     proc fileExists*(filename: string): bool ... =
#       when defined(windows):
#         wrapUnary(a, getFileAttributesW, filename)
#         if a != -1'i32:
#           result = (a and FILE_ATTRIBUTE_DIRECTORY) == 0'i32
#
# `winlean.getFileAttributesW` is declared `{.importc, stdcall,
# dynlib: "kernel32".}` at `lib/windows/winlean.nim:313`, which is the
# exact dispatch mechanism the inline detour must catch. The shim's
# hookTable does hook `GetFileAttributesW`, so the depfile records a
# `mrPathProbe` record per call with the unique marker substring in
# its path. Loss tolerance zero, same as the milestone demands.
#
# Phase 5 will add DeleteFileW to the hookTable and the
# os.removeFile-based variant becomes feasible alongside this one.
#
# Invocation: fixture_mech4_os_module.exe <marker> <count>

import std/[os, strutils]

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
    # os.fileExists -> winlean.getFileAttributesW (kernel32 dynlib dispatch).
    # We do NOT pre-create the files: the depfile records the probe
    # regardless of whether the file exists, with probeResult = prAbsent.
    # That keeps the fixture cheap and the assertion focused on call
    # count rather than filesystem state.
    discard fileExists(path)
