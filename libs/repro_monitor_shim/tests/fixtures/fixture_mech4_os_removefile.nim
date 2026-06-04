# M73 Phase 5 — dispatch-mechanism 4 (parallel form): real-world Nim
# `os.removeFile` caller landing on winlean's dynlib-dispatched
# `deleteFileW`.
#
# Phase 2 (commit 09f6c66) substituted `os.fileExists` for `os.removeFile`
# because DeleteFileW was not yet in the shim's hookTable; Phase 5 added
# `HookDeleteFileW` so the originally-spec'd mechanism 4 surface is now
# observable end-to-end. This fixture is the retirement of that
# substitution: it exercises the same call path the M73 motivating case
# called out ("Nim `os.removeFile` -> `winlean.deleteFileW` should not
# bypass the monitor").
#
# Nim 2.2.8 verification (`lib/std/private/osfiles.nim`):
#   line 335: `template deleteFile(file: untyped): untyped = deleteFileW(file)`
#   line 339: `result = tryRemoveFile(...)` inside `os.removeFile`
# `winlean.deleteFileW` (`lib/windows/winlean.nim:657-659`):
#   `proc deleteFileW*(pathName: WideCString): int32 {.
#       importc: "DeleteFileW", stdcall, dynlib: "kernel32".}`
#
# Invocation: fixture_mech4_os_removefile.exe <marker> <count>
#
# Pre-creates a file at <marker>.<i>.txt for each i in [0, count) and then
# calls `os.removeFile` on it. Each removeFile invocation lands on
# `winlean.deleteFileW`, which the Phase-5 inline detour at kernel32
# catches. The depfile MUST contain exactly `count` mrFileWrite records
# whose path contains the marker substring and whose detail field equals
# "DeleteFileW".

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
  # Pre-create the files so DeleteFileW actually has something to remove;
  # the depfile records the call regardless of return value, but a
  # successful removal proves the install path is not subtly corrupting
  # the call ABI.
  for i in 0 ..< count:
    let path = marker & "." & $i & ".txt"
    writeFile(path, "")
  for i in 0 ..< count:
    let path = marker & "." & $i & ".txt"
    # os.removeFile -> tryRemoveFile -> winlean.deleteFileW (dynlib-
    # dispatched, IAT bypassed — the Phase 5 inline detour at
    # kernel32!DeleteFileW catches it).
    try:
      removeFile(path)
    except OSError as e:
      stderr.writeLine("removeFile failed for " & path & ": " & e.msg)
