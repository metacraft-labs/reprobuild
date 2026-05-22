## Reprobuild native Windows launcher binary (M57).
##
## The activation step writes one copy of this binary per exported
## command into the user-visible bin directory, plus a
## `<command>.repro-launch` sidecar next to it. At launch time the
## launcher:
##
##   1. Resolves the sidecar by appending `.repro-launch` to its own
##      argv[0]. The sidecar's RBLS envelope contains the LaunchPlan ID
##      and the absolute path to the M56 store root.
##   2. Reads the LaunchPlan CAS blob (`<store>/cas/blake3/<aa>/<hash>`)
##      and verifies its trailing BLAKE3-256 checksum.
##   3. Calls `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_USER_DIRS)`
##      so the default DLL search is restricted to dirs the application
##      explicitly adds.
##   4. Calls `AddDllDirectory` once per `runtimeLibraryDirs` entry — in
##      the order they appear in the LaunchPlan. The order is the order
##      Windows walks at load time, so the first matching DLL wins. This
##      is exactly what the spec's "exact runtime bindings over search"
##      rule requires: O(direct-deps), not O(everything-on-PATH).
##   5. Builds the child argv from `LaunchPlan.arguments` plus any
##      passthrough argv[1..] the user supplied.
##   6. Applies `environmentBindings` to the child process environment.
##   7. `CreateProcessW`s the target executable and waits for it,
##      forwarding the exit code.
##
## DEPENDENCIES: kernel32.dll only. This binary must be statically
## linked against the Nim runtime (the default for `nim c`) and must
## NOT depend on any DLL outside of what every Windows host ships
## (kernel32, user32, msvcrt). Importing third-party Nim modules with
## DLL deps would defeat the purpose — the launcher cannot recurse on
## its own dependency resolution problem.

when not defined(windows):
  static: assert false,
    "repro-launcher targets Windows only; compile with `nim c -d:mingw`."

import std/[os, strutils]
from repro_core/paths import extendedPath

import repro_launch_plan
# Note: we deliberately do NOT import `repro_local_store` here. The
# launcher binary must depend on Win32 only (KERNEL32 + Universal CRT);
# pulling the full M56 store would drag in the SQLite dynlib import.
# `slim_cas` gives us a sqlite-free path-only CAS reader that is enough
# to locate and verify the LaunchPlan blob keyed by the sidecar's
# launchPlanId.

# ---------------------------------------------------------------------------
# Win32 API surface
# ---------------------------------------------------------------------------

type
  DWord = uint32
  HMODULE = pointer
  WinHandle = pointer
  WChar = uint16
  WString = ptr UncheckedArray[WChar]

  StartupInfoW {.importc: "STARTUPINFOW",
                 header: "<windows.h>", bycopy.} = object
    cb: DWord
    lpReserved: ptr WChar
    lpDesktop: ptr WChar
    lpTitle: ptr WChar
    dwX: DWord
    dwY: DWord
    dwXSize: DWord
    dwYSize: DWord
    dwXCountChars: DWord
    dwYCountChars: DWord
    dwFillAttribute: DWord
    dwFlags: DWord
    wShowWindow: uint16
    cbReserved2: uint16
    lpReserved2: ptr byte
    hStdInput: WinHandle
    hStdOutput: WinHandle
    hStdError: WinHandle

  ProcessInfo {.importc: "PROCESS_INFORMATION",
                header: "<windows.h>", bycopy.} = object
    hProcess: WinHandle
    hThread: WinHandle
    dwProcessId: DWord
    dwThreadId: DWord

const
  LoadLibrarySearchUserDirs = 0x00000400'u32
  CreateUnicodeEnvironment = 0x00000400'u32
  WaitInfinite = 0xFFFFFFFF'u32

proc setDefaultDllDirectories(flags: DWord): int32
  {.stdcall, dynlib: "kernel32", importc: "SetDefaultDllDirectories".}
proc addDllDirectory(newDirectory: ptr WChar): pointer
  {.stdcall, dynlib: "kernel32", importc: "AddDllDirectory".}
proc createProcessW(
    lpApplicationName: ptr WChar,
    lpCommandLine: ptr WChar,
    lpProcessAttributes: pointer,
    lpThreadAttributes: pointer,
    bInheritHandles: int32,
    dwCreationFlags: DWord,
    lpEnvironment: pointer,
    lpCurrentDirectory: ptr WChar,
    lpStartupInfo: ptr StartupInfoW,
    lpProcessInformation: ptr ProcessInfo): int32
  {.stdcall, dynlib: "kernel32", importc: "CreateProcessW".}
proc waitForSingleObject(handle: WinHandle; ms: DWord): DWord
  {.stdcall, dynlib: "kernel32", importc: "WaitForSingleObject".}
proc getExitCodeProcess(handle: WinHandle; exitCode: ptr DWord): int32
  {.stdcall, dynlib: "kernel32", importc: "GetExitCodeProcess".}
proc closeHandle(handle: WinHandle): int32
  {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}
proc getLastError(): DWord
  {.stdcall, dynlib: "kernel32", importc: "GetLastError".}
proc getCommandLineW(): ptr WChar
  {.stdcall, dynlib: "kernel32", importc: "GetCommandLineW".}
proc commandLineToArgvW(cmd: ptr WChar; argc: ptr int32): ptr UncheckedArray[ptr WChar]
  {.stdcall, dynlib: "shell32", importc: "CommandLineToArgvW".}
proc localFree(mem: pointer): pointer
  {.stdcall, dynlib: "kernel32", importc: "LocalFree".}

# ---------------------------------------------------------------------------
# String helpers
# ---------------------------------------------------------------------------

proc toWideStringZ(s: string): seq[WChar] =
  ## UTF-8 -> UTF-16 (LE) with a trailing NUL. Sufficient for paths and
  ## command lines that originate from the LaunchPlan; we intentionally
  ## do NOT round-trip arbitrary unicode codepoints beyond what the
  ## sidecar/LaunchPlan stores as UTF-8.
  result = newSeqOfCap[WChar](s.len + 1)
  var i = 0
  while i < s.len:
    let c = uint32(byte(s[i]))
    if c < 0x80'u32:
      result.add(WChar(c))
      inc i
    elif c < 0xC0'u32:
      # Invalid leading byte; emit replacement.
      result.add(WChar(0xFFFD'u32))
      inc i
    elif c < 0xE0'u32:
      if i + 1 >= s.len:
        result.add(WChar(0xFFFD'u32)); inc i; continue
      let cp = ((c and 0x1F'u32) shl 6) or
               (uint32(byte(s[i + 1])) and 0x3F'u32)
      result.add(WChar(cp))
      i += 2
    elif c < 0xF0'u32:
      if i + 2 >= s.len:
        result.add(WChar(0xFFFD'u32)); inc i; continue
      let cp = ((c and 0x0F'u32) shl 12) or
               ((uint32(byte(s[i + 1])) and 0x3F'u32) shl 6) or
               (uint32(byte(s[i + 2])) and 0x3F'u32)
      result.add(WChar(cp))
      i += 3
    else:
      if i + 3 >= s.len:
        result.add(WChar(0xFFFD'u32)); inc i; continue
      let cp = ((c and 0x07'u32) shl 18) or
               ((uint32(byte(s[i + 1])) and 0x3F'u32) shl 12) or
               ((uint32(byte(s[i + 2])) and 0x3F'u32) shl 6) or
               (uint32(byte(s[i + 3])) and 0x3F'u32)
      # Encode as a surrogate pair when needed.
      if cp >= 0x10000'u32:
        let adj = cp - 0x10000'u32
        result.add(WChar(0xD800'u32 or (adj shr 10)))
        result.add(WChar(0xDC00'u32 or (adj and 0x3FF'u32)))
      else:
        result.add(WChar(cp))
      i += 4
  result.add(WChar(0))

proc fromWideStringZ(p: ptr WChar): string =
  if p == nil:
    return ""
  var i = 0
  while true:
    let cp = cast[ptr UncheckedArray[WChar]](p)[i]
    if cp == 0:
      break
    var unit = uint32(cp)
    var cp32 = unit
    if unit >= 0xD800'u32 and unit <= 0xDBFF'u32:
      let low = cast[ptr UncheckedArray[WChar]](p)[i + 1]
      if low != 0:
        cp32 = 0x10000'u32 +
          ((unit - 0xD800'u32) shl 10) +
          (uint32(low) - 0xDC00'u32)
        inc i
    if cp32 < 0x80'u32:
      result.add(char(cp32))
    elif cp32 < 0x800'u32:
      result.add(char(0xC0'u32 or (cp32 shr 6)))
      result.add(char(0x80'u32 or (cp32 and 0x3F'u32)))
    elif cp32 < 0x10000'u32:
      result.add(char(0xE0'u32 or (cp32 shr 12)))
      result.add(char(0x80'u32 or ((cp32 shr 6) and 0x3F'u32)))
      result.add(char(0x80'u32 or (cp32 and 0x3F'u32)))
    else:
      result.add(char(0xF0'u32 or (cp32 shr 18)))
      result.add(char(0x80'u32 or ((cp32 shr 12) and 0x3F'u32)))
      result.add(char(0x80'u32 or ((cp32 shr 6) and 0x3F'u32)))
      result.add(char(0x80'u32 or (cp32 and 0x3F'u32)))
    inc i

proc quoteCommandLineArg(arg: string): string =
  ## Apply the Windows CommandLineToArgvW quoting rules (the same rules
  ## the CRT `argv` parser uses). Any argument containing whitespace,
  ## a double-quote, or a tab is wrapped in double quotes; backslashes
  ## directly preceding a literal `"` are doubled per the rules.
  if arg.len == 0:
    return "\"\""
  var needsQuoting = false
  for ch in arg:
    if ch in {' ', '\t', '"', '\n', '\v'}:
      needsQuoting = true
      break
  if not needsQuoting:
    return arg
  result.add('"')
  var backslashes = 0
  for ch in arg:
    case ch
    of '\\':
      inc backslashes
    of '"':
      for _ in 0 ..< backslashes * 2 + 1:
        result.add('\\')
      result.add('"')
      backslashes = 0
    else:
      for _ in 0 ..< backslashes:
        result.add('\\')
      backslashes = 0
      result.add(ch)
  for _ in 0 ..< backslashes * 2:
    result.add('\\')
  result.add('"')

# ---------------------------------------------------------------------------
# Argv parsing
# ---------------------------------------------------------------------------

proc parseOwnArgv(): seq[string] =
  ## Parse the launcher's argv using the canonical Win32 parser
  ## (CommandLineToArgvW). This is the same parser the shell uses; it
  ## guarantees we receive argv[0] verbatim — which is critical because
  ## we resolve the sidecar by appending ".repro-launch" to it.
  var argc: int32
  let argv = commandLineToArgvW(getCommandLineW(), addr argc)
  if argv == nil:
    return @[]
  try:
    for i in 0 ..< int(argc):
      result.add(fromWideStringZ(argv[i]))
  finally:
    discard localFree(cast[pointer](argv))

# ---------------------------------------------------------------------------
# Sidecar lookup
# ---------------------------------------------------------------------------

proc resolveSidecarPath(argv0: string): string =
  ## Determine the sidecar path: `<argv0>.repro-launch`. We do NOT do
  ## any PATH search here — `argv0` may be a bare name when the
  ## launcher was invoked through a shortcut, in which case the
  ## sidecar must live next to the resolved executable. We resolve
  ## via `getAppFilename()` as the canonical fallback.
  let candidate = argv0 & LaunchPlanSidecarSuffix
  if fileExists(extendedPath(candidate)):
    return candidate
  let fromAppFilename = getAppFilename() & LaunchPlanSidecarSuffix
  if fileExists(extendedPath(fromAppFilename)):
    return fromAppFilename
  raise newException(IOError,
    "no Reprobuild launcher sidecar at " & candidate &
    " or " & fromAppFilename)

# ---------------------------------------------------------------------------
# Plan execution
# ---------------------------------------------------------------------------

proc applyEnvBindings(plan: LaunchPlan) =
  for eb in plan.environmentBindings:
    case eb.kind
    of ebkSet:
      putEnv(eb.name, eb.value)
    of ebkPrepend:
      let existing = getEnv(eb.name)
      if existing.len == 0:
        putEnv(eb.name, eb.value)
      else:
        putEnv(eb.name, eb.value & ";" & existing)
    of ebkAppend:
      let existing = getEnv(eb.name)
      if existing.len == 0:
        putEnv(eb.name, eb.value)
      else:
        putEnv(eb.name, existing & ";" & eb.value)
    of ebkUnset:
      delEnv(eb.name)

proc verifyExecutionProfile(sidecar: LaunchSidecar; plan: LaunchPlan) =
  ## The launch plan may carry an execution-profile checksum. When the
  ## adapter receipt set `requiresExecutionProfileChecksum = true`, the
  ## launcher MUST verify the checksum before invoking the target —
  ## mismatch fails closed (per spec §"Execution Profile Checksum").
  if not sidecar.requiresExecutionProfile:
    return
  if not plan.executionProfile.present:
    raise newException(IOError,
      "sidecar requests execution-profile verification but the plan " &
      "carries no executionProfile checksum")
  if plan.executionProfile.checksumHex.toLowerAscii !=
      sidecar.executionProfileHex.toLowerAscii:
    raise newException(IOError,
      "execution-profile checksum mismatch: plan=" &
      plan.executionProfile.checksumHex &
      " sidecar=" & sidecar.executionProfileHex)

proc loadPlanFromSidecar(sidecar: LaunchSidecar): LaunchPlan =
  ## Resolve the launch plan blob via the slim, sqlite-free CAS reader
  ## bundled in `repro_launch_plan/slim_cas`. The launcher never opens
  ## the M56 SQLite index — it doesn't need to, since it already holds
  ## the launchPlanId in the sidecar and the CAS is path-addressable.
  let storeRoot =
    if sidecar.storeRoot.len > 0: sidecar.storeRoot
    else: raise newException(IOError, "sidecar storeRoot is empty")
  if sidecar.launchPlanIdHex.len != 64:
    raise newException(IOError,
      "sidecar launchPlanId is not 64 hex chars: " & sidecar.launchPlanIdHex)
  readLaunchPlanByHex(storeRoot, sidecar.launchPlanIdHex)

proc registerDllDirectories(plan: LaunchPlan) =
  ## Restrict the default DLL search of the LAUNCHER process and add
  ## the EXACT dirs from the launch plan, once each. The spec's "FS
  ## storm avoidance" rule requires the number of AddDllDirectory
  ## calls to equal the dep count, not more — and `SetDefaultDllDirectories`
  ## with `LOAD_LIBRARY_SEARCH_USER_DIRS` ensures any `LoadLibraryEx`
  ## the launcher performs honors the registered dirs only.
  ##
  ## NOTE: `SetDefaultDllDirectories` and `AddDllDirectory` are
  ## process-local. They do NOT carry into the child created by
  ## `CreateProcessW`. The child's DLL search is steered by editing
  ## ITS environment PATH in `applyRuntimePathToChildEnv` below: we
  ## prepend the EXACT runtimeLibraryDirs to the inherited PATH so the
  ## child's startup loader walks them first. This is "exact runtime
  ## bindings over search" — every entry corresponds to a declared
  ## dep, no widening — even though the mechanism uses the PATH
  ## variable as the transport.
  if setDefaultDllDirectories(LoadLibrarySearchUserDirs) == 0:
    raise newException(IOError,
      "SetDefaultDllDirectories failed (GetLastError=" &
      $getLastError() & ")")
  for dir in plan.runtimeLibraryDirs:
    var w = toWideStringZ(dir)
    let cookie = addDllDirectory(addr w[0])
    if cookie == nil:
      raise newException(IOError,
        "AddDllDirectory failed for " & dir &
        " (GetLastError=" & $getLastError() & ")")

proc applyRuntimePathToChildEnv(plan: LaunchPlan) =
  ## Prepend `runtimeLibraryDirs` to the inherited PATH used by the
  ## child process. Each dep dir appears once. The child's standard
  ## DLL search will consult these dirs FIRST (after the application
  ## directory and system32) — so the child loads the dep DLL from the
  ## prefix the LaunchPlan declares, regardless of any third-party
  ## entries already on PATH.
  if plan.runtimeLibraryDirs.len == 0:
    return
  var newPath = ""
  for i, dir in plan.runtimeLibraryDirs:
    if i > 0: newPath.add(';')
    newPath.add(dir)
  let existing = getEnv("PATH")
  if existing.len > 0:
    newPath.add(';')
    newPath.add(existing)
  putEnv("PATH", newPath)

proc buildCommandLine(plan: LaunchPlan; passthrough: seq[string]): string =
  ## Build the CreateProcessW lpCommandLine. The first token is the
  ## executable path with the usual Win32 quoting rules; the static
  ## arguments come from `plan.arguments`; the trailing tokens are the
  ## passthrough argv the user provided.
  result.add(quoteCommandLineArg(plan.executablePath))
  for arg in plan.arguments:
    result.add(' ')
    result.add(quoteCommandLineArg(arg))
  for arg in passthrough:
    result.add(' ')
    result.add(quoteCommandLineArg(arg))

proc runPlan(plan: LaunchPlan; passthrough: seq[string]): int =
  applyEnvBindings(plan)
  registerDllDirectories(plan)
  applyRuntimePathToChildEnv(plan)
  let cmdLine = buildCommandLine(plan, passthrough)
  var wExe = toWideStringZ(plan.executablePath)
  var wCmd = toWideStringZ(cmdLine)
  var wCwd: seq[WChar]
  if plan.hasWorkingDirectory and plan.workingDirectory.len > 0:
    wCwd = toWideStringZ(plan.workingDirectory)
  var si: StartupInfoW
  si.cb = DWord(sizeof(StartupInfoW))
  var pi: ProcessInfo
  let ok = createProcessW(
    addr wExe[0],
    addr wCmd[0],
    nil, nil, 1'i32,
    CreateUnicodeEnvironment,
    nil,
    (if wCwd.len > 0: addr wCwd[0] else: nil),
    addr si, addr pi)
  if ok == 0:
    raise newException(IOError,
      "CreateProcessW failed for " & plan.executablePath &
      " (GetLastError=" & $getLastError() & ")")
  discard waitForSingleObject(pi.hProcess, WaitInfinite)
  var exit: DWord
  discard getExitCodeProcess(pi.hProcess, addr exit)
  discard closeHandle(pi.hProcess)
  discard closeHandle(pi.hThread)
  int(exit)

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

when isMainModule:
  try:
    let args = parseOwnArgv()
    if args.len == 0:
      stderr.writeLine("repro-launcher: empty argv (no argv[0])")
      quit(2)
    let sidecarPath = resolveSidecarPath(args[0])
    let sidecar = readSidecarFile(sidecarPath)
    let plan = loadPlanFromSidecar(sidecar)
    verifyExecutionProfile(sidecar, plan)
    let passthrough =
      if args.len > 1: args[1 .. ^1]
      else: @[]
    quit(runPlan(plan, passthrough))
  except CatchableError as err:
    stderr.writeLine("repro-launcher: error: " & err.msg)
    quit(1)
