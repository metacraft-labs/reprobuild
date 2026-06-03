when not defined(windows):
  {.error: "repro_monitor_shim/windows_interpose is Windows-only".}

# Windows: Reprobuild monitor shim DLL — feature-parity counterpart to
# macos_interpose.nim. On macOS the shim is injected via
# DYLD_INSERT_LIBRARIES and uses ct_interpose's function interposition.
# On Windows there is no DYLD_INSERT_LIBRARIES equivalent, so this DLL
# is injected via CreateProcess(CREATE_SUSPENDED) + CreateRemoteThread
# (the call site lives in repro_monitor_depfile/fs_snoop.nim) and uses
# IAT patching to redirect calls to CreateFileW / ReadFile / WriteFile /
# CloseHandle / GetFileAttributesExW / CreateProcessW / CreateProcessA.
#
# M26: the shim no longer wires its IAT-installed trampolines directly to
# bespoke hook bodies. Instead, each Win32 API is dispatched through
# ct_interpose's ``hook_registry`` (see windows_hook_registry.nim and
# ``codetracer-native-recorder/ct_interpose/src/ct_interpose/hook_registry.nim``).
# The monitor's snoop logic is registered as a HookCallback at priority
# ShimSnoopPriority (100). The hook chain's ``original`` callback wraps
# the captured original Win32 function pointer. Other interposers (e.g.
# the codetracer recorder when co-resident) can register against the
# same chain at their own priorities without colliding with the shim.

import std/[locks, os, strutils, tables]
from repro_core/paths import extendedPath

import repro_monitor_depfile/types
import repro_monitor_depfile/writer

import repro_monitor_shim/windows_iat_patcher
import repro_monitor_shim/windows_hook_registry as hr

{.push raises: [].}

# ---------------------------------------------------------------------------
# M72 — inline-hook backend for the dynlib-resolved Win32 call sites.
#
# IAT patching catches CRT-internal forwarding (statically-linked
# ``__declspec(dllimport)`` callers like the C runtime's
# ``_wspawnvp`` → ``CreateProcessW``). It does NOT catch Nim's
# ``{.importc, dynlib: "kernel32".}`` declarations: Nim's codegen
# lowers those to ``nimGetProcAddr``-resolved function pointers cached
# in a module-global, then calls through the pointer directly. The
# IAT is bypassed entirely, so a Nim ``startProcess`` call spawns its
# grandchild without the shim seeing the spawn — and without
# propagating the shim into that grandchild for further capture. That
# bypass is unacceptable: the monitor's contract is "no bypass under
# any dispatch mechanism", and the only place a call ALWAYS converges
# is the function body in kernel32 itself.
#
# Mirror the codetracer-native-recorder's M50.2 inline-hook primitive
# (``ct_inline_hook/install_windows.c``): install a 5-byte
# ``JMP rel32`` at the start of ``kernel32!CreateProcessW`` /
# ``kernel32!CreateProcessA`` redirecting to the same trampolines the
# IAT path already routes through. The capture is now sourced from
# the kernel32 function body, not from any per-module IAT slot, so
# Nim dynlib calls land in our trampoline along with everything else.
#
# The C source files live in the recorder repo's ``ct_inline_hook``
# directory. Resolve their path at compile time, anchored on
# ``currentSourcePath`` so a vendored copy under
# ``libs/repro_monitor_shim/vendor/ct_inline_hook`` would also work
# if the recorder sibling checkout is missing.

const ctInlineHookDir {.strdefine.}: string =
  currentSourcePath().parentDir().parentDir().parentDir().parentDir()
    .parentDir().parentDir() /
    "codetracer-native-recorder" / "ct_inline_hook"

when fileExists(ctInlineHookDir / "install_windows.c"):
  {.passC: "-I" & ctInlineHookDir & " -D_CRT_SECURE_NO_WARNINGS".}
  {.compile: ctInlineHookDir / "length_decoder.c".}
  {.compile: ctInlineHookDir / "rel32_fixup.c".}
  {.compile: ctInlineHookDir / "install_windows.c".}
  const ctInlineHookAvailable = true
else:
  {.warning: "ct_inline_hook sources not found at " & ctInlineHookDir &
    "; Nim dynlib-resolved CreateProcessW calls will bypass the monitor.".}
  const ctInlineHookAvailable = false

when ctInlineHookAvailable:
  proc ctInlineHookInstall(target: pointer, hook: pointer,
                           outTrampoline: ptr pointer): cint
    {.importc: "ct_inline_hook_install", cdecl.}

# --- Win32 typedefs ---------------------------------------------------------

type
  HANDLE = pointer
  DWORD = uint32
  WORD = uint16
  BOOL = int32
  LPCSTR = cstring
  LPCWSTR = ptr uint16
  LPSTR = cstring
  LPWSTR = ptr uint16
  LPVOID = pointer
  LPCVOID = pointer
  LPSECURITY_ATTRIBUTES = pointer
  LPOVERLAPPED = pointer
  LARGE_INTEGER = int64

  STARTUPINFOA {.bycopy.} = object
    cb: DWORD
    lpReserved: LPSTR
    lpDesktop: LPSTR
    lpTitle: LPSTR
    dwX: DWORD
    dwY: DWORD
    dwXSize: DWORD
    dwYSize: DWORD
    dwXCountChars: DWORD
    dwYCountChars: DWORD
    dwFillAttribute: DWORD
    dwFlags: DWORD
    wShowWindow: WORD
    cbReserved2: WORD
    lpReserved2: ptr byte
    hStdInput: HANDLE
    hStdOutput: HANDLE
    hStdError: HANDLE

  STARTUPINFOW {.bycopy.} = object
    cb: DWORD
    lpReserved: LPWSTR
    lpDesktop: LPWSTR
    lpTitle: LPWSTR
    dwX: DWORD
    dwY: DWORD
    dwXSize: DWORD
    dwYSize: DWORD
    dwXCountChars: DWORD
    dwYCountChars: DWORD
    dwFillAttribute: DWORD
    dwFlags: DWORD
    wShowWindow: WORD
    cbReserved2: WORD
    lpReserved2: ptr byte
    hStdInput: HANDLE
    hStdOutput: HANDLE
    hStdError: HANDLE

  PROCESS_INFORMATION {.bycopy.} = object
    hProcess: HANDLE
    hThread: HANDLE
    dwProcessId: DWORD
    dwThreadId: DWORD

const
  GENERIC_WRITE = 0x40000000'u32
  GENERIC_READ = 0x80000000'u32
  CREATE_ALWAYS = 2'u32
  CREATE_NEW = 1'u32
  OPEN_ALWAYS = 4'u32
  TRUNCATE_EXISTING = 5'u32
  OPEN_EXISTING = 3'u32

# Windows: INVALID_HANDLE_VALUE is documented as (HANDLE)(-1). We can't use a
# const because Nim insists on a typed integer literal, so a `let` initialised
# from a typed expression suffices.
let INVALID_HANDLE_VALUE {.used.}: HANDLE = cast[HANDLE](cast[uint](0'i64 - 1'i64))

# --- Win32 imports ---------------------------------------------------------

proc GetCurrentProcessId(): DWORD
  {.importc, stdcall, dynlib: "kernel32".}
proc GetCurrentThreadId(): DWORD
  {.importc, stdcall, dynlib: "kernel32".}
proc GetLastError(): DWORD
  {.importc, stdcall, dynlib: "kernel32".}
proc SetLastError(dwErrCode: DWORD): void
  {.importc, stdcall, dynlib: "kernel32".}
proc OutputDebugStringA(lpOutputString: cstring): void
  {.importc, stdcall, dynlib: "kernel32".}
proc GetEnvironmentVariableA(lpName: cstring, lpBuffer: cstring,
                              nSize: DWORD): DWORD
  {.importc, stdcall, dynlib: "kernel32".}
proc WideCharToMultiByte(CodePage: DWORD, dwFlags: DWORD,
                         lpWideCharStr: LPCWSTR, cchWideChar: int32,
                         lpMultiByteStr: LPSTR, cbMultiByte: int32,
                         lpDefaultChar: LPCSTR,
                         lpUsedDefaultChar: ptr BOOL): int32
  {.importc, stdcall, dynlib: "kernel32".}
proc lstrlenW(lpString: LPCWSTR): int32
  {.importc, stdcall, dynlib: "kernel32".}

# --- Grandchild injection: pull the shim into every CreateProcess descendant.
# Without this, descendants of a shim-loaded process spawn naked — their
# CreateFileW calls are not hooked, evidence vanishes, dev-env-edge caching
# decides "no observed inputs" and serves stale artifacts.
#
# Mirrors the top-level injector in repro_monitor_depfile/windows_injector.nim:
# spawn the child CREATE_SUSPENDED, allocate a buffer in its address space,
# write our own DLL path into it, fire LoadLibraryW via CreateRemoteThread,
# wait, free, resume the main thread (unless the caller had asked for
# CREATE_SUSPENDED itself).

const
  CREATE_SUSPENDED = 0x00000004'u32
  MEM_COMMIT = 0x00001000'u32
  MEM_RESERVE = 0x00002000'u32
  MEM_RELEASE = 0x00008000'u32
  PAGE_READWRITE = 0x04'u32
  INFINITE = 0xFFFFFFFF'u32
  GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 0x00000004'u32
  GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = 0x00000002'u32

type SIZE_T = uint

proc GetModuleHandleExW(dwFlags: DWORD, lpModuleName: LPCWSTR,
                        phModule: ptr HANDLE): BOOL
  {.importc, stdcall, dynlib: "kernel32".}
proc GetModuleFileNameW(hModule: HANDLE, lpFilename: LPWSTR,
                        nSize: DWORD): DWORD
  {.importc, stdcall, dynlib: "kernel32".}
proc GetModuleHandleW(lpModuleName: LPCWSTR): HANDLE
  {.importc, stdcall, dynlib: "kernel32".}
proc GetModuleHandleA(lpModuleName: LPCSTR): HANDLE
  {.importc, stdcall, dynlib: "kernel32".}
proc GetProcAddress(hModule: HANDLE, lpProcName: LPCSTR): pointer
  {.importc, stdcall, dynlib: "kernel32".}
proc EnumProcessModulesEx(hProcess: HANDLE, lphModule: ptr pointer,
                          cb: DWORD, lpcbNeeded: ptr DWORD,
                          dwFilterFlag: DWORD): BOOL
  {.importc, stdcall, dynlib: "psapi".}
proc GetModuleBaseNameW(hProcess: HANDLE, hModule: HANDLE,
                        lpBaseName: LPWSTR, nSize: DWORD): DWORD
  {.importc, stdcall, dynlib: "psapi".}
proc VirtualAllocEx(hProcess: HANDLE, lpAddress: LPVOID, dwSize: SIZE_T,
                    flAllocationType: DWORD, flProtect: DWORD): LPVOID
  {.importc, stdcall, dynlib: "kernel32".}
proc VirtualFreeEx(hProcess: HANDLE, lpAddress: LPVOID, dwSize: SIZE_T,
                   dwFreeType: DWORD): BOOL
  {.importc, stdcall, dynlib: "kernel32".}
proc WriteProcessMemory(hProcess: HANDLE, lpBaseAddress: LPVOID,
                        lpBuffer: LPCVOID, nSize: SIZE_T,
                        lpNumberOfBytesWritten: ptr SIZE_T): BOOL
  {.importc, stdcall, dynlib: "kernel32".}
proc CreateRemoteThread(hProcess: HANDLE,
                        lpThreadAttributes: LPSECURITY_ATTRIBUTES,
                        dwStackSize: SIZE_T, lpStartAddress: pointer,
                        lpParameter: LPVOID, dwCreationFlags: DWORD,
                        lpThreadId: ptr DWORD): HANDLE
  {.importc, stdcall, dynlib: "kernel32".}
proc WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD): DWORD
  {.importc, stdcall, dynlib: "kernel32".}
proc ResumeThread(hThread: HANDLE): DWORD
  {.importc, stdcall, dynlib: "kernel32".}
proc CloseHandle(hObject: HANDLE): BOOL
  {.importc, stdcall, dynlib: "kernel32".}

# --- Hook function pointer types (mirror the Win32 API signatures) ---------

type
  CreateFileWProc = proc(lpFileName: LPCWSTR, dwDesiredAccess: DWORD,
                         dwShareMode: DWORD,
                         lpSecurityAttributes: LPSECURITY_ATTRIBUTES,
                         dwCreationDisposition: DWORD,
                         dwFlagsAndAttributes: DWORD,
                         hTemplateFile: HANDLE): HANDLE
                         {.stdcall, raises: [].}

  CreateFileAProc = proc(lpFileName: LPCSTR, dwDesiredAccess: DWORD,
                         dwShareMode: DWORD,
                         lpSecurityAttributes: LPSECURITY_ATTRIBUTES,
                         dwCreationDisposition: DWORD,
                         dwFlagsAndAttributes: DWORD,
                         hTemplateFile: HANDLE): HANDLE
                         {.stdcall, raises: [].}

  ReadFileProc = proc(hFile: HANDLE, lpBuffer: LPVOID,
                      nNumberOfBytesToRead: DWORD,
                      lpNumberOfBytesRead: ptr DWORD,
                      lpOverlapped: LPOVERLAPPED): BOOL
                      {.stdcall, raises: [].}

  WriteFileProc = proc(hFile: HANDLE, lpBuffer: LPCVOID,
                       nNumberOfBytesToWrite: DWORD,
                       lpNumberOfBytesWritten: ptr DWORD,
                       lpOverlapped: LPOVERLAPPED): BOOL
                       {.stdcall, raises: [].}

  CloseHandleProc = proc(hObject: HANDLE): BOOL {.stdcall, raises: [].}

  GetFileAttributesExWProc = proc(lpFileName: LPCWSTR, fInfoLevelId: DWORD,
                                   lpFileInformation: LPVOID): BOOL
                                   {.stdcall, raises: [].}

  GetFileAttributesExAProc = proc(lpFileName: LPCSTR, fInfoLevelId: DWORD,
                                   lpFileInformation: LPVOID): BOOL
                                   {.stdcall, raises: [].}

  GetFileAttributesWProc = proc(lpFileName: LPCWSTR): DWORD
                                 {.stdcall, raises: [].}

  GetFileAttributesAProc = proc(lpFileName: LPCSTR): DWORD
                                 {.stdcall, raises: [].}

  CreateProcessWProc = proc(lpApplicationName: LPCWSTR,
                            lpCommandLine: LPWSTR,
                            lpProcessAttributes: LPSECURITY_ATTRIBUTES,
                            lpThreadAttributes: LPSECURITY_ATTRIBUTES,
                            bInheritHandles: BOOL,
                            dwCreationFlags: DWORD,
                            lpEnvironment: LPVOID,
                            lpCurrentDirectory: LPCWSTR,
                            lpStartupInfo: ptr STARTUPINFOW,
                            lpProcessInformation: ptr PROCESS_INFORMATION): BOOL
                            {.stdcall, raises: [].}

  CreateProcessAProc = proc(lpApplicationName: LPCSTR,
                            lpCommandLine: LPSTR,
                            lpProcessAttributes: LPSECURITY_ATTRIBUTES,
                            lpThreadAttributes: LPSECURITY_ATTRIBUTES,
                            bInheritHandles: BOOL,
                            dwCreationFlags: DWORD,
                            lpEnvironment: LPVOID,
                            lpCurrentDirectory: LPCSTR,
                            lpStartupInfo: ptr STARTUPINFOA,
                            lpProcessInformation: ptr PROCESS_INFORMATION): BOOL
                            {.stdcall, raises: [].}

# --- Original function pointer storage -------------------------------------

var
  origCreateFileW: CreateFileWProc
  origCreateFileA: CreateFileAProc
  origReadFile: ReadFileProc
  origWriteFile: WriteFileProc
  origCloseHandle: CloseHandleProc
  origGetFileAttributesExW: GetFileAttributesExWProc
  origGetFileAttributesExA: GetFileAttributesExAProc
  origGetFileAttributesW: GetFileAttributesWProc
  origGetFileAttributesA: GetFileAttributesAProc
  origCreateProcessW: CreateProcessWProc
  origCreateProcessA: CreateProcessAProc

# --- Runtime state ---------------------------------------------------------

var
  initialized = false
  locksReady = false
  initLockVar: Lock
  recordLock: Lock
  fdLock: Lock
  fragmentDir: string
  nextProcessSeq: uint64 = 0
  handlePaths = initTable[uint64, string]()
  # Grandchild injection: cache of our own DLL path (UTF-16, NUL-terminated)
  # populated lazily on the first CreateProcessW dispatch. Used as the
  # ``LoadLibraryW`` argument when re-injecting into spawned children.
  selfDllPathW: seq[uint16] = @[]
  selfDllPathReady: bool = false

var disabled {.threadvar.}: int

template withShimMuted(body: untyped) =
  inc disabled
  try:
    body
  except CatchableError:
    discard
  dec disabled

# --- Helpers ---------------------------------------------------------------

proc CreateFileARaw(lpFileName: cstring, dwDesiredAccess: DWORD,
                     dwShareMode: DWORD,
                     lpSecurityAttributes: LPSECURITY_ATTRIBUTES,
                     dwCreationDisposition: DWORD,
                     dwFlagsAndAttributes: DWORD,
                     hTemplateFile: HANDLE): HANDLE
  {.importc: "CreateFileA", stdcall, dynlib: "kernel32".}
proc SetFilePointer(hFile: HANDLE, lDistanceToMove: int32,
                     lpDistanceToMoveHigh: ptr int32, dwMoveMethod: DWORD): DWORD
  {.importc, stdcall, dynlib: "kernel32".}
proc WriteFileRaw(hFile: HANDLE, lpBuffer: LPCVOID,
                   nNumberOfBytesToWrite: DWORD,
                   lpNumberOfBytesWritten: ptr DWORD,
                   lpOverlapped: LPOVERLAPPED): BOOL
  {.importc: "WriteFile", stdcall, dynlib: "kernel32".}
proc CloseHandleRaw(hObject: HANDLE): BOOL
  {.importc: "CloseHandle", stdcall, dynlib: "kernel32".}

proc dbg(msg: cstring) =
  OutputDebugStringA(msg)
  # Windows: also append to a fixed-path log so we can debug injection from
  # outside the process. Controlled by the REPRO_MONITOR_SHIM_DEBUG_LOG env
  # variable. We MUST use the raw kernel32 APIs (which themselves get hooked
  # for the IATs of *other* modules, but not of our own DLL via the loader-
  # critical module skip in windows_iat_patcher.nim) so no recursion occurs.
  var logBuf: array[1024, char]
  let n = GetEnvironmentVariableA("REPRO_MONITOR_SHIM_DEBUG_LOG",
                                  cast[cstring](addr logBuf[0]),
                                  DWORD(logBuf.len))
  if n == 0 or n >= DWORD(logBuf.len):
    return
  logBuf[int(n)] = '\0'
  const OPEN_ALWAYS = 4'u32
  const FILE_APPEND_DATA = 0x4'u32
  const FILE_SHARE_READ = 0x1'u32
  const FILE_SHARE_WRITE = 0x2'u32
  const FILE_END = 2'u32
  let h = CreateFileARaw(cast[cstring](addr logBuf[0]),
    FILE_APPEND_DATA,
    FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_ALWAYS, 0'u32, nil)
  if h == nil:
    return
  if cast[uint](h) == high(uint):  # INVALID_HANDLE_VALUE
    return
  discard SetFilePointer(h, 0, nil, FILE_END)
  var written: DWORD = 0
  var msgLen: int32 = 0
  while msg[msgLen] != '\0':
    inc msgLen
  discard WriteFileRaw(h, msg, DWORD(msgLen), addr written, nil)
  discard CloseHandleRaw(h)

proc widePtrToString(ws: LPCWSTR): string =
  ## Convert a NUL-terminated UTF-16 path to UTF-8 string.
  if ws == nil:
    return ""
  let wlen = lstrlenW(ws)
  if wlen <= 0:
    return ""
  let needed = WideCharToMultiByte(65001'u32, 0'u32, ws, wlen,
                                   nil, 0'i32, nil, nil)
  if needed <= 0:
    return ""
  result = newString(needed)
  discard WideCharToMultiByte(65001'u32, 0'u32, ws, wlen,
                              cast[LPSTR](addr result[0]), needed, nil, nil)

proc handleKey(h: HANDLE): uint64 {.inline.} =
  cast[uint64](h)

proc rememberHandlePath(h: HANDLE, path: string) =
  if h == nil or h == INVALID_HANDLE_VALUE or path.len == 0:
    return
  acquire(fdLock)
  handlePaths[handleKey(h)] = path
  release(fdLock)

proc forgetHandlePath(h: HANDLE) =
  if h == nil or h == INVALID_HANDLE_VALUE:
    return
  acquire(fdLock)
  handlePaths.del(handleKey(h))
  release(fdLock)

proc pathForHandle(h: HANDLE): string =
  if h == nil or h == INVALID_HANDLE_VALUE:
    return ""
  acquire(fdLock)
  result = handlePaths.getOrDefault(handleKey(h), "")
  release(fdLock)

proc processSeq(): uint64 =
  acquire(recordLock)
  inc nextProcessSeq
  result = nextProcessSeq
  release(recordLock)

proc currentParentOsPid(): uint64 =
  ## Windows: parent pid lookup is non-trivial (requires NtQueryInformationProcess
  ## or toolhelp snapshot). For the monitor depfile we set parent to 0 — the
  ## fragment merge already groups by osPid so parentless leaves are fine.
  0'u64

proc baseRecord(kind: MonitorRecordKind;
                observationKind: MonitorObservationKind): MonitorRecord =
  MonitorRecord(
    kind: kind,
    observationKind: observationKind,
    seq: processSeq(),
    osPid: uint64(GetCurrentProcessId()),
    parentOsPid: currentParentOsPid(),
    threadId: uint64(GetCurrentThreadId()),
    probeResult: prUnknown)

proc emitRecord(record: MonitorRecord) {.raises: [].} =
  if not initialized or fragmentDir.len == 0 or disabled > 0:
    return
  withShimMuted:
    try:
      appendFragmentRecord(fragmentDir, record)
    except CatchableError:
      discard

proc observationForCreateFile(desiredAccess, creationDisposition: DWORD):
    MonitorObservationKind =
  # Windows: classify as write if GENERIC_WRITE bit is set or the disposition
  # creates/truncates the file. Otherwise treat as a plain open.
  if (desiredAccess and GENERIC_WRITE) != 0 or
      creationDisposition == CREATE_ALWAYS or
      creationDisposition == CREATE_NEW or
      creationDisposition == OPEN_ALWAYS or
      creationDisposition == TRUNCATE_EXISTING:
    moFileWrite
  else:
    moFileOpen

proc probeFromBool(callResult: BOOL): ProbeResult =
  if callResult != 0:
    prExistingOther
  else:
    prAbsent

proc readEnvString(name: cstring): string =
  var buf: array[32768, char]
  let n = GetEnvironmentVariableA(name, cast[cstring](addr buf[0]),
                                  DWORD(buf.len))
  if n == 0 or n >= DWORD(buf.len):
    return ""
  result = newString(int(n))
  for i in 0 ..< int(n):
    result[i] = buf[i]

proc ensureFragmentDir() =
  if fragmentDir.len == 0:
    return
  try:
    createDir(extendedPath(fragmentDir))
  except OSError:
    discard
  except IOError:
    discard
  except ValueError:
    discard

proc recordProcessStart() =
  var record = baseRecord(mrProcessStart, moProcessStart)
  record.detail = "shim-loaded"
  emitRecord(record)

# --- Hook chain context layout ---------------------------------------------
#
# Win32 trampolines pack their stdcall arguments into HookContext.args as
# uint64s, in source-order. The "original" callback unpacks them back into
# the typed Win32 ABI to invoke the captured origXxx pointer; the monitor's
# snoop callback unpacks the args it cares about (the path, the access
# flags) plus ctx.result for the post-call observation.
#
# Argument slot conventions (per hook name):
#
#   CreateFileW / CreateFileA:
#     args[0]: lpFileName            (LPCWSTR/LPCSTR)
#     args[1]: dwDesiredAccess       (DWORD)
#     args[2]: dwShareMode           (DWORD)
#     args[3]: lpSecurityAttributes  (LPSECURITY_ATTRIBUTES)
#     args[4]: dwCreationDisposition (DWORD)
#     args[5]: dwFlagsAndAttributes  (DWORD)
#     args[6]: hTemplateFile         (HANDLE)
#
#   ReadFile / WriteFile: hFile, lpBuffer, nBytes, lpBytesXfer, lpOverlapped
#   CloseHandle: hObject
#   GetFileAttributesExW/A: lpFileName, fInfoLevelId, lpFileInformation
#   GetFileAttributesW/A: lpFileName
#   CreateProcessW/A: 10 args matching the Win32 signature

# --- Original-callback wrappers --------------------------------------------
#
# Each original wrapper unpacks the HookContext.args back into the typed
# Win32 ABI, calls the captured origXxx pointer, and stores the result
# back into ctx.result. These are registered as the chain's ``original``
# via setOriginalCallback so that the snoop callback's callNext eventually
# reaches the real Win32 API.

proc originalCreateFileW(ctx: var hr.HookContext) {.raises: [].} =
  if origCreateFileW == nil:
    ctx.result = cast[uint64](INVALID_HANDLE_VALUE)
    return
  let lpFileName        = cast[LPCWSTR](ctx.args[0])
  let dwDesiredAccess   = DWORD(ctx.args[1])
  let dwShareMode       = DWORD(ctx.args[2])
  let lpSecAttr         = cast[LPSECURITY_ATTRIBUTES](ctx.args[3])
  let dwCreationDisp    = DWORD(ctx.args[4])
  let dwFlagsAndAttrs   = DWORD(ctx.args[5])
  let hTemplateFile     = cast[HANDLE](ctx.args[6])
  let r = origCreateFileW(lpFileName, dwDesiredAccess, dwShareMode,
                          lpSecAttr, dwCreationDisp, dwFlagsAndAttrs,
                          hTemplateFile)
  ctx.result = cast[uint64](r)

proc originalCreateFileA(ctx: var hr.HookContext) {.raises: [].} =
  if origCreateFileA == nil:
    ctx.result = cast[uint64](INVALID_HANDLE_VALUE)
    return
  let lpFileName        = cast[LPCSTR](ctx.args[0])
  let dwDesiredAccess   = DWORD(ctx.args[1])
  let dwShareMode       = DWORD(ctx.args[2])
  let lpSecAttr         = cast[LPSECURITY_ATTRIBUTES](ctx.args[3])
  let dwCreationDisp    = DWORD(ctx.args[4])
  let dwFlagsAndAttrs   = DWORD(ctx.args[5])
  let hTemplateFile     = cast[HANDLE](ctx.args[6])
  let r = origCreateFileA(lpFileName, dwDesiredAccess, dwShareMode,
                          lpSecAttr, dwCreationDisp, dwFlagsAndAttrs,
                          hTemplateFile)
  ctx.result = cast[uint64](r)

proc originalReadFile(ctx: var hr.HookContext) {.raises: [].} =
  if origReadFile == nil:
    ctx.result = 0
    return
  let hFile         = cast[HANDLE](ctx.args[0])
  let lpBuffer      = cast[LPVOID](ctx.args[1])
  let nBytes        = DWORD(ctx.args[2])
  let lpBytesRead   = cast[ptr DWORD](ctx.args[3])
  let lpOverlapped  = cast[LPOVERLAPPED](ctx.args[4])
  let r = origReadFile(hFile, lpBuffer, nBytes, lpBytesRead, lpOverlapped)
  ctx.result = uint64(uint32(r))

proc originalWriteFile(ctx: var hr.HookContext) {.raises: [].} =
  if origWriteFile == nil:
    ctx.result = 0
    return
  let hFile          = cast[HANDLE](ctx.args[0])
  let lpBuffer       = cast[LPCVOID](ctx.args[1])
  let nBytes         = DWORD(ctx.args[2])
  let lpBytesWritten = cast[ptr DWORD](ctx.args[3])
  let lpOverlapped   = cast[LPOVERLAPPED](ctx.args[4])
  let r = origWriteFile(hFile, lpBuffer, nBytes, lpBytesWritten, lpOverlapped)
  ctx.result = uint64(uint32(r))

proc originalCloseHandle(ctx: var hr.HookContext) {.raises: [].} =
  if origCloseHandle == nil:
    ctx.result = 0
    return
  let hObject = cast[HANDLE](ctx.args[0])
  let r = origCloseHandle(hObject)
  ctx.result = uint64(uint32(r))

proc originalGetFileAttributesExW(ctx: var hr.HookContext) {.raises: [].} =
  if origGetFileAttributesExW == nil:
    ctx.result = 0
    return
  let lpFileName        = cast[LPCWSTR](ctx.args[0])
  let fInfoLevelId      = DWORD(ctx.args[1])
  let lpFileInformation = cast[LPVOID](ctx.args[2])
  let r = origGetFileAttributesExW(lpFileName, fInfoLevelId, lpFileInformation)
  ctx.result = uint64(uint32(r))

proc originalGetFileAttributesExA(ctx: var hr.HookContext) {.raises: [].} =
  if origGetFileAttributesExA == nil:
    ctx.result = 0
    return
  let lpFileName        = cast[LPCSTR](ctx.args[0])
  let fInfoLevelId      = DWORD(ctx.args[1])
  let lpFileInformation = cast[LPVOID](ctx.args[2])
  let r = origGetFileAttributesExA(lpFileName, fInfoLevelId, lpFileInformation)
  ctx.result = uint64(uint32(r))

proc originalGetFileAttributesW(ctx: var hr.HookContext) {.raises: [].} =
  if origGetFileAttributesW == nil:
    ctx.result = 0xFFFFFFFF'u64
    return
  let lpFileName = cast[LPCWSTR](ctx.args[0])
  let r = origGetFileAttributesW(lpFileName)
  ctx.result = uint64(r)

proc originalGetFileAttributesA(ctx: var hr.HookContext) {.raises: [].} =
  if origGetFileAttributesA == nil:
    ctx.result = 0xFFFFFFFF'u64
    return
  let lpFileName = cast[LPCSTR](ctx.args[0])
  let r = origGetFileAttributesA(lpFileName)
  ctx.result = uint64(r)

proc originalCreateProcessW(ctx: var hr.HookContext) {.raises: [].} =
  if origCreateProcessW == nil:
    ctx.result = 0
    return
  let lpApplicationName  = cast[LPCWSTR](ctx.args[0])
  let lpCommandLine      = cast[LPWSTR](ctx.args[1])
  let lpProcAttr         = cast[LPSECURITY_ATTRIBUTES](ctx.args[2])
  let lpThreadAttr       = cast[LPSECURITY_ATTRIBUTES](ctx.args[3])
  let bInheritHandles    = BOOL(ctx.args[4])
  let dwCreationFlags    = DWORD(ctx.args[5])
  let lpEnvironment      = cast[LPVOID](ctx.args[6])
  let lpCurrentDirectory = cast[LPCWSTR](ctx.args[7])
  let lpStartupInfo      = cast[ptr STARTUPINFOW](ctx.args[8])
  let lpProcessInfo      = cast[ptr PROCESS_INFORMATION](ctx.args[9])
  let r = origCreateProcessW(lpApplicationName, lpCommandLine,
                              lpProcAttr, lpThreadAttr, bInheritHandles,
                              dwCreationFlags, lpEnvironment,
                              lpCurrentDirectory, lpStartupInfo,
                              lpProcessInfo)
  ctx.result = uint64(uint32(r))

proc originalCreateProcessA(ctx: var hr.HookContext) {.raises: [].} =
  if origCreateProcessA == nil:
    ctx.result = 0
    return
  let lpApplicationName  = cast[LPCSTR](ctx.args[0])
  let lpCommandLine      = cast[LPSTR](ctx.args[1])
  let lpProcAttr         = cast[LPSECURITY_ATTRIBUTES](ctx.args[2])
  let lpThreadAttr       = cast[LPSECURITY_ATTRIBUTES](ctx.args[3])
  let bInheritHandles    = BOOL(ctx.args[4])
  let dwCreationFlags    = DWORD(ctx.args[5])
  let lpEnvironment      = cast[LPVOID](ctx.args[6])
  let lpCurrentDirectory = cast[LPCSTR](ctx.args[7])
  let lpStartupInfo      = cast[ptr STARTUPINFOA](ctx.args[8])
  let lpProcessInfo      = cast[ptr PROCESS_INFORMATION](ctx.args[9])
  let r = origCreateProcessA(lpApplicationName, lpCommandLine,
                              lpProcAttr, lpThreadAttr, bInheritHandles,
                              dwCreationFlags, lpEnvironment,
                              lpCurrentDirectory, lpStartupInfo,
                              lpProcessInfo)
  ctx.result = uint64(uint32(r))

# --- Snoop callbacks (registered against the chain at ShimSnoopPriority) ---
#
# Each snoop callback follows the same pattern:
#   1. callNext(ctx)         — runs the rest of the chain, ultimately the
#                              real Win32 API (which sets LastError).
#   2. Save LastError        — Nim allocator + Lock ops can clobber it.
#   3. Bookkeeping           — read ctx.args / ctx.result, build a
#                              MonitorRecord, append to the fragment.
#   4. Restore LastError     — caller sees what the kernel actually set.
#
# M11.7 outstanding follow-up: the Save/Restore dance can be retired once
# the IAT path is replaced with the M50.2 inline-hook primitive (which
# preserves LastError implicitly via the JMP rel32 trampoline). Today the
# IAT-installed Nim trampoline still allocates inside the snoop body so
# the dance is load-bearing.

proc snoopCreateFileW(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpFileName = cast[LPCWSTR](ctx.args[0])
    let dwDesiredAccess = DWORD(ctx.args[1])
    let dwCreationDisp = DWORD(ctx.args[4])
    let path = widePtrToString(lpFileName)
    let h = cast[HANDLE](ctx.result)
    if h != INVALID_HANDLE_VALUE:
      rememberHandlePath(h, path)
    var record = baseRecord(mrFileOpen,
      observationForCreateFile(dwDesiredAccess, dwCreationDisp))
    record.result = int64(cast[int](h))
    record.flags = uint32(dwDesiredAccess)
    record.path = path
    record.detail = "CreateFileW"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopCreateFileA(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpFileName = cast[LPCSTR](ctx.args[0])
    let dwDesiredAccess = DWORD(ctx.args[1])
    let dwCreationDisp = DWORD(ctx.args[4])
    var path = ""
    if lpFileName != nil:
      path = $lpFileName
    let h = cast[HANDLE](ctx.result)
    if h != INVALID_HANDLE_VALUE:
      rememberHandlePath(h, path)
    var record = baseRecord(mrFileOpen,
      observationForCreateFile(dwDesiredAccess, dwCreationDisp))
    record.result = int64(cast[int](h))
    record.flags = uint32(dwDesiredAccess)
    record.path = path
    record.detail = "CreateFileA"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopReadFile(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  # ReadFile preservation is load-bearing. Without it, cargo's
  # std::process::Command::spawn panics with
  # `Os { code: 183, kind: AlreadyExists }` on the rust-binary-with-build-rs
  # fixture. (See M11 audit notes.)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let hFile = cast[HANDLE](ctx.args[0])
    let lpBytesRead = cast[ptr DWORD](ctx.args[3])
    let callOk = BOOL(ctx.result) != 0
    var record = baseRecord(mrFileRead, moFileRead)
    record.path = pathForHandle(hFile)
    if callOk and lpBytesRead != nil:
      record.result = int64(lpBytesRead[])
    else:
      record.result = -1
    record.detail = "ReadFile"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopWriteFile(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let hFile = cast[HANDLE](ctx.args[0])
    let lpBytesWritten = cast[ptr DWORD](ctx.args[3])
    let callOk = BOOL(ctx.result) != 0
    var record = baseRecord(mrFileWrite, moFileWrite)
    record.path = pathForHandle(hFile)
    if callOk and lpBytesWritten != nil:
      record.result = int64(lpBytesWritten[])
    else:
      record.result = -1
    record.detail = "WriteFile"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopCloseHandle(ctx: var hr.HookContext) {.raises: [].} =
  # Windows: CloseHandle is invoked far more frequently than the file
  # operations we care about. We do the bookkeeping BEFORE callNext so
  # any allocator activity inside forgetHandlePath cannot clobber the
  # LastError that the real CloseHandle will set.
  if disabled > 0 or not initialized:
    hr.callNext(ctx)
    return
  inc disabled
  try:
    let hObject = cast[HANDLE](ctx.args[0])
    forgetHandlePath(hObject)
  except CatchableError:
    discard
  hr.callNext(ctx)
  dec disabled

proc snoopGetFileAttributesExW(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()  # ERROR_FILE_NOT_FOUND on absent path
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpFileName = cast[LPCWSTR](ctx.args[0])
    let r = BOOL(ctx.result)
    var record = baseRecord(mrPathProbe, moPathProbe)
    record.path = widePtrToString(lpFileName)
    record.result = int64(r)
    record.probeResult = probeFromBool(r)
    record.detail = "GetFileAttributesExW"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopGetFileAttributesExA(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpFileName = cast[LPCSTR](ctx.args[0])
    let r = BOOL(ctx.result)
    var record = baseRecord(mrPathProbe, moPathProbe)
    if lpFileName != nil:
      record.path = $lpFileName
    record.result = int64(r)
    record.probeResult = probeFromBool(r)
    record.detail = "GetFileAttributesExA"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopGetFileAttributesW(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpFileName = cast[LPCWSTR](ctx.args[0])
    let r = DWORD(ctx.result)
    var record = baseRecord(mrPathProbe, moPathProbe)
    record.path = widePtrToString(lpFileName)
    record.result = int64(r)
    record.probeResult =
      if r == 0xFFFFFFFF'u32: prAbsent else: prExistingOther
    record.detail = "GetFileAttributesW"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopGetFileAttributesA(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpFileName = cast[LPCSTR](ctx.args[0])
    let r = DWORD(ctx.result)
    var record = baseRecord(mrPathProbe, moPathProbe)
    if lpFileName != nil:
      record.path = $lpFileName
    record.result = int64(r)
    record.probeResult =
      if r == 0xFFFFFFFF'u32: prAbsent else: prExistingOther
    record.detail = "GetFileAttributesA"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

# Lazily populate the shim's own DLL path so we can re-inject it into
# CreateProcess descendants. ``GetModuleHandleExW`` with
# ``FROM_ADDRESS`` flag locates the module containing the address of
# ``snoopCreateProcessW`` itself; that's our own DLL by definition. We
# then read its file path with ``GetModuleFileNameW``. The
# ``UNCHANGED_REFCOUNT`` flag avoids artificially bumping our own load
# count.
proc ensureSelfDllPath() =
  if selfDllPathReady:
    return
  var hSelf: HANDLE = nil
  # Cast through ``ByteAddress`` (Nim's ``int``-sized integer alias)
  # so the C codegen emits ``(NU16*)(long)x`` instead of
  # ``(NU16*)x``. Going through an integer breaks gcc's
  # ``-Wincompatible-pointer-types`` warn-as-error path that fires on
  # function-pointer → data-pointer direct conversions; the runtime
  # bit pattern is the literal address of our own ``ensureSelfDllPath``
  # function, which is the probe value ``GetModuleHandleExW`` needs.
  let selfProbe = cast[ByteAddress](ensureSelfDllPath)
  if GetModuleHandleExW(
      GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS or
        GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
      cast[LPCWSTR](selfProbe),
      addr hSelf) == 0 or hSelf == nil:
    selfDllPathReady = true
    return
  var buf: array[1024, uint16]
  let n = GetModuleFileNameW(hSelf, cast[LPWSTR](addr buf[0]),
    DWORD(buf.len))
  if n == 0'u32 or n >= DWORD(buf.len):
    selfDllPathReady = true
    return
  selfDllPathW = newSeq[uint16](int(n) + 1)
  for i in 0 ..< int(n):
    selfDllPathW[i] = buf[i]
  selfDllPathW[int(n)] = 0'u16
  selfDllPathReady = true

# Inject the shim DLL into ``hProcess`` by allocating a buffer in the
# remote address space, writing our own DLL path into it, and firing
# LoadLibraryW via CreateRemoteThread. LoadLibraryW's entry-point
# address is identical in the child because kernel32 maps at the same
# base across processes for the lifetime of the OS boot session.
#
# Returns true on success. Failures are swallowed silently — child
# might still run with degraded (but correct) monitoring evidence,
# which beats crashing the child or killing the parent.
proc injectShimIntoChild(hProcess: HANDLE): bool {.raises: [].} =
  if selfDllPathW.len == 0:
    return false
  let bufSize = SIZE_T(selfDllPathW.len * sizeof(uint16))
  let remoteBuf = VirtualAllocEx(hProcess, nil, bufSize,
    MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE)
  if remoteBuf == nil:
    return false
  defer: discard VirtualFreeEx(hProcess, remoteBuf, 0, MEM_RELEASE)
  var written: SIZE_T = 0
  if WriteProcessMemory(hProcess, remoteBuf, addr selfDllPathW[0],
      bufSize, addr written) == 0:
    return false
  var kernel32Name = [uint16(ord('k')), uint16(ord('e')), uint16(ord('r')),
    uint16(ord('n')), uint16(ord('e')), uint16(ord('l')),
    uint16(ord('3')), uint16(ord('2')), uint16(ord('.')),
    uint16(ord('d')), uint16(ord('l')), uint16(ord('l')), 0'u16]
  let kernel32 = GetModuleHandleW(cast[LPCWSTR](addr kernel32Name[0]))
  if kernel32 == nil:
    return false
  let loadLibraryW = GetProcAddress(kernel32, "LoadLibraryW")
  if loadLibraryW == nil:
    return false
  let hThread = CreateRemoteThread(hProcess, nil, 0, loadLibraryW,
    remoteBuf, 0, nil)
  if hThread == nil:
    return false
  discard WaitForSingleObject(hThread, INFINITE)
  discard CloseHandle(hThread)
  # The shim DLL is now mapped into the child but its
  # ``repro_monitor_shim_init`` has NOT run — Nim doesn't expose
  # user-code on DLL_PROCESS_ATTACH, so an explicit second
  # CreateRemoteThread call against the init proc is required to
  # actually arm the IAT + inline detours in the child. Mirror the
  # production fs-snoop injector (``windows_injector.nim``): enumerate
  # the child's loaded modules to find our shim DLL's child-side base,
  # compute the init proc's RVA from our own copy, then
  # CreateRemoteThread at (childBase + RVA).
  var ourSelf: HANDLE = nil
  if GetModuleHandleExW(
      GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS or
        GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
      cast[LPCWSTR](cast[ByteAddress](ensureSelfDllPath)),
      addr ourSelf) == 0 or ourSelf == nil:
    return true  # DLL loaded but init won't run; degraded but not fatal
  let ourInit = GetProcAddress(ourSelf, "repro_runtime_init")
  if ourInit == nil:
    return true
  let ourBase = cast[uint](ourSelf)
  let rva = cast[uint](ourInit) - ourBase
  # Find the matching module in the child by basename.
  var wantBaseName = newString(0)
  block computeBaseName:
    var i = selfDllPathW.len - 2  # skip terminating NUL
    while i >= 0 and selfDllPathW[i] != 0'u16 and
        char(selfDllPathW[i] and 0xFF) != '\\' and
        char(selfDllPathW[i] and 0xFF) != '/':
      dec i
    inc i
    while i < selfDllPathW.len and selfDllPathW[i] != 0'u16:
      wantBaseName.add(char(selfDllPathW[i] and 0xFF))
      inc i
  if wantBaseName.len == 0:
    return true
  var childMods: array[1024, HANDLE]
  var modCb: DWORD = 0
  if EnumProcessModulesEx(hProcess, cast[ptr pointer](addr childMods[0]),
      DWORD(sizeof(childMods)), addr modCb, 0x3'u32) == 0:
    return true
  let modCount = int(modCb) div sizeof(HANDLE)
  var foundShim: HANDLE = nil
  for i in 0 ..< min(modCount, 1024):
    var nameBuf: array[1024, uint16]
    let nameLen = GetModuleBaseNameW(hProcess, childMods[i],
      cast[LPWSTR](addr nameBuf[0]), DWORD(nameBuf.len))
    if nameLen == 0:
      continue
    var got = newString(int(nameLen))
    for j in 0 ..< int(nameLen):
      got[j] = char(nameBuf[j] and 0xFF)
    if got.cmpIgnoreCase(wantBaseName) == 0:
      foundShim = childMods[i]
      break
  if foundShim == nil:
    return true
  let childInit = cast[pointer](cast[uint](foundShim) + rva)
  let initThread = CreateRemoteThread(hProcess, nil, 0, childInit,
    nil, 0, nil)
  if initThread != nil:
    discard WaitForSingleObject(initThread, INFINITE)
    discard CloseHandle(initThread)
  true

proc snoopCreateProcessW(ctx: var hr.HookContext) {.raises: [].} =
  # Grandchild injection (Windows fs-snoop): force CREATE_SUSPENDED into
  # the child's creation flags BEFORE the real CreateProcessW runs, so
  # the child is suspended on its initial thread when control returns.
  # We then inject our own DLL via CreateRemoteThread(LoadLibraryW),
  # wait for LoadLibraryW to return inside the child, and resume the
  # main thread — unless the original caller already asked for
  # CREATE_SUSPENDED themselves, in which case we leave the suspension
  # exactly as they requested.
  let callerCreationFlags = DWORD(ctx.args[5])
  let callerAskedForSuspended =
    (callerCreationFlags and CREATE_SUSPENDED) != 0
  if initialized and disabled == 0:
    ensureSelfDllPath()
    if selfDllPathW.len > 0:
      ctx.args[5] = uint64(callerCreationFlags or CREATE_SUSPENDED)
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpApplicationName = cast[LPCWSTR](ctx.args[0])
    let lpCommandLine = cast[LPWSTR](ctx.args[1])
    let lpProcessInfo = cast[ptr PROCESS_INFORMATION](ctx.args[9])
    let r = BOOL(ctx.result)
    var record = baseRecord(mrProcessSpawn, moExecute)
    if r != 0 and lpProcessInfo != nil:
      record.childOsPid = uint64(lpProcessInfo[].dwProcessId)
    record.result = int64(r)
    var path = ""
    if lpApplicationName != nil:
      path = widePtrToString(lpApplicationName)
    elif lpCommandLine != nil:
      path = widePtrToString(cast[LPCWSTR](lpCommandLine))
    record.path = path
    record.detail = "CreateProcessW"
    emitRecord(record)
    # On success, inject and (if needed) resume the main thread. The
    # caller's flags determine whether we are responsible for the
    # resume — if they passed CREATE_SUSPENDED we MUST NOT touch the
    # main thread, otherwise the caller's own ResumeThread call later
    # double-resumes.
    if r != 0 and lpProcessInfo != nil and selfDllPathW.len > 0:
      let pi = lpProcessInfo[]
      discard injectShimIntoChild(pi.hProcess)
      if not callerAskedForSuspended:
        discard ResumeThread(pi.hThread)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopCreateProcessA(ctx: var hr.HookContext) {.raises: [].} =
  let savedFlagsA = DWORD(ctx.args[5])
  let callerAskedForSuspendedA =
    (savedFlagsA and CREATE_SUSPENDED) != 0
  if initialized and disabled == 0:
    ensureSelfDllPath()
    if selfDllPathW.len > 0:
      ctx.args[5] = uint64(savedFlagsA or CREATE_SUSPENDED)
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpApplicationName = cast[LPCSTR](ctx.args[0])
    let lpCommandLine = cast[LPSTR](ctx.args[1])
    let lpProcessInfo = cast[ptr PROCESS_INFORMATION](ctx.args[9])
    let r = BOOL(ctx.result)
    var record = baseRecord(mrProcessSpawn, moExecute)
    if r != 0 and lpProcessInfo != nil:
      record.childOsPid = uint64(lpProcessInfo[].dwProcessId)
    record.result = int64(r)
    var path = ""
    if lpApplicationName != nil:
      path = $lpApplicationName
    elif lpCommandLine != nil:
      path = $cast[cstring](lpCommandLine)
    record.path = path
    record.detail = "CreateProcessA"
    emitRecord(record)
    if r != 0 and lpProcessInfo != nil and selfDllPathW.len > 0:
      let pi = lpProcessInfo[]
      discard injectShimIntoChild(pi.hProcess)
      if not callerAskedForSuspendedA:
        discard ResumeThread(pi.hThread)
  except CatchableError:
    discard
  SetLastError(savedLastError)

# --- Win32 trampolines installed into the IAT ------------------------------
#
# Each trampoline matches the corresponding Win32 stdcall signature. Its job
# is to pack args into a HookContext, dispatch through the registry, and
# unpack ctx.result back to the Win32 return type. The registry walks the
# chain (snoop → original) for us.

proc trampolineCreateFileW(lpFileName: LPCWSTR, dwDesiredAccess: DWORD,
                            dwShareMode: DWORD,
                            lpSecurityAttributes: LPSECURITY_ATTRIBUTES,
                            dwCreationDisposition: DWORD,
                            dwFlagsAndAttributes: DWORD,
                            hTemplateFile: HANDLE): HANDLE {.stdcall.} =
  if origCreateFileW == nil:
    return INVALID_HANDLE_VALUE
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpFileName),
    uint64(dwDesiredAccess),
    uint64(dwShareMode),
    cast[uint64](lpSecurityAttributes),
    uint64(dwCreationDisposition),
    uint64(dwFlagsAndAttributes),
    cast[uint64](hTemplateFile)
  ])
  hr.dispatchShimHook(hr.HookCreateFileW, ctx)
  result = cast[HANDLE](ctx.result)

proc trampolineCreateFileA(lpFileName: LPCSTR, dwDesiredAccess: DWORD,
                            dwShareMode: DWORD,
                            lpSecurityAttributes: LPSECURITY_ATTRIBUTES,
                            dwCreationDisposition: DWORD,
                            dwFlagsAndAttributes: DWORD,
                            hTemplateFile: HANDLE): HANDLE {.stdcall.} =
  if origCreateFileA == nil:
    return INVALID_HANDLE_VALUE
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpFileName),
    uint64(dwDesiredAccess),
    uint64(dwShareMode),
    cast[uint64](lpSecurityAttributes),
    uint64(dwCreationDisposition),
    uint64(dwFlagsAndAttributes),
    cast[uint64](hTemplateFile)
  ])
  hr.dispatchShimHook(hr.HookCreateFileA, ctx)
  result = cast[HANDLE](ctx.result)

proc trampolineReadFile(hFile: HANDLE, lpBuffer: LPVOID,
                         nNumberOfBytesToRead: DWORD,
                         lpNumberOfBytesRead: ptr DWORD,
                         lpOverlapped: LPOVERLAPPED): BOOL {.stdcall.} =
  if origReadFile == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](hFile),
    cast[uint64](lpBuffer),
    uint64(nNumberOfBytesToRead),
    cast[uint64](lpNumberOfBytesRead),
    cast[uint64](lpOverlapped)
  ])
  hr.dispatchShimHook(hr.HookReadFile, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineWriteFile(hFile: HANDLE, lpBuffer: LPCVOID,
                          nNumberOfBytesToWrite: DWORD,
                          lpNumberOfBytesWritten: ptr DWORD,
                          lpOverlapped: LPOVERLAPPED): BOOL {.stdcall.} =
  if origWriteFile == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](hFile),
    cast[uint64](lpBuffer),
    uint64(nNumberOfBytesToWrite),
    cast[uint64](lpNumberOfBytesWritten),
    cast[uint64](lpOverlapped)
  ])
  hr.dispatchShimHook(hr.HookWriteFile, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineCloseHandle(hObject: HANDLE): BOOL {.stdcall.} =
  if origCloseHandle == nil:
    return 0
  var ctx = hr.HookContext(args: @[cast[uint64](hObject)])
  hr.dispatchShimHook(hr.HookCloseHandle, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineGetFileAttributesExW(lpFileName: LPCWSTR, fInfoLevelId: DWORD,
                                     lpFileInformation: LPVOID): BOOL
                                     {.stdcall.} =
  if origGetFileAttributesExW == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpFileName),
    uint64(fInfoLevelId),
    cast[uint64](lpFileInformation)
  ])
  hr.dispatchShimHook(hr.HookGetFileAttributesExW, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineGetFileAttributesExA(lpFileName: LPCSTR, fInfoLevelId: DWORD,
                                     lpFileInformation: LPVOID): BOOL
                                     {.stdcall.} =
  if origGetFileAttributesExA == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpFileName),
    uint64(fInfoLevelId),
    cast[uint64](lpFileInformation)
  ])
  hr.dispatchShimHook(hr.HookGetFileAttributesExA, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineGetFileAttributesW(lpFileName: LPCWSTR): DWORD {.stdcall.} =
  if origGetFileAttributesW == nil:
    return 0xFFFFFFFF'u32
  var ctx = hr.HookContext(args: @[cast[uint64](lpFileName)])
  hr.dispatchShimHook(hr.HookGetFileAttributesW, ctx)
  result = DWORD(ctx.result)

proc trampolineGetFileAttributesA(lpFileName: LPCSTR): DWORD {.stdcall.} =
  if origGetFileAttributesA == nil:
    return 0xFFFFFFFF'u32
  var ctx = hr.HookContext(args: @[cast[uint64](lpFileName)])
  hr.dispatchShimHook(hr.HookGetFileAttributesA, ctx)
  result = DWORD(ctx.result)

proc trampolineCreateProcessW(lpApplicationName: LPCWSTR,
                               lpCommandLine: LPWSTR,
                               lpProcessAttributes: LPSECURITY_ATTRIBUTES,
                               lpThreadAttributes: LPSECURITY_ATTRIBUTES,
                               bInheritHandles: BOOL,
                               dwCreationFlags: DWORD,
                               lpEnvironment: LPVOID,
                               lpCurrentDirectory: LPCWSTR,
                               lpStartupInfo: ptr STARTUPINFOW,
                               lpProcessInformation: ptr PROCESS_INFORMATION):
                               BOOL {.stdcall.} =
  if origCreateProcessW == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpApplicationName),
    cast[uint64](lpCommandLine),
    cast[uint64](lpProcessAttributes),
    cast[uint64](lpThreadAttributes),
    uint64(uint32(bInheritHandles)),
    uint64(dwCreationFlags),
    cast[uint64](lpEnvironment),
    cast[uint64](lpCurrentDirectory),
    cast[uint64](lpStartupInfo),
    cast[uint64](lpProcessInformation)
  ])
  hr.dispatchShimHook(hr.HookCreateProcessW, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineCreateProcessA(lpApplicationName: LPCSTR,
                               lpCommandLine: LPSTR,
                               lpProcessAttributes: LPSECURITY_ATTRIBUTES,
                               lpThreadAttributes: LPSECURITY_ATTRIBUTES,
                               bInheritHandles: BOOL,
                               dwCreationFlags: DWORD,
                               lpEnvironment: LPVOID,
                               lpCurrentDirectory: LPCSTR,
                               lpStartupInfo: ptr STARTUPINFOA,
                               lpProcessInformation: ptr PROCESS_INFORMATION):
                               BOOL {.stdcall.} =
  if origCreateProcessA == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpApplicationName),
    cast[uint64](lpCommandLine),
    cast[uint64](lpProcessAttributes),
    cast[uint64](lpThreadAttributes),
    uint64(uint32(bInheritHandles)),
    uint64(dwCreationFlags),
    cast[uint64](lpEnvironment),
    cast[uint64](lpCurrentDirectory),
    cast[uint64](lpStartupInfo),
    cast[uint64](lpProcessInformation)
  ])
  hr.dispatchShimHook(hr.HookCreateProcessA, ctx)
  result = BOOL(uint32(ctx.result))

# --- Registry wiring -------------------------------------------------------
#
# Called once from repro_monitor_shim_init AFTER the registry has been
# allocated but BEFORE IAT installation kicks in. Registers each snoop
# callback at ShimSnoopPriority. The chain's ``original`` callback is set
# inside installIATHooks below, once we know the captured origXxx pointer
# is non-nil.

proc registerMonitorSnoopCallbacks*() =
  hr.registerMonitorHook(hr.HookCreateFileW,        snoopCreateFileW)
  hr.registerMonitorHook(hr.HookCreateFileA,        snoopCreateFileA)
  hr.registerMonitorHook(hr.HookReadFile,           snoopReadFile)
  hr.registerMonitorHook(hr.HookWriteFile,          snoopWriteFile)
  hr.registerMonitorHook(hr.HookCloseHandle,        snoopCloseHandle)
  hr.registerMonitorHook(hr.HookGetFileAttributesExW, snoopGetFileAttributesExW)
  hr.registerMonitorHook(hr.HookGetFileAttributesExA, snoopGetFileAttributesExA)
  hr.registerMonitorHook(hr.HookGetFileAttributesW,   snoopGetFileAttributesW)
  hr.registerMonitorHook(hr.HookGetFileAttributesA,   snoopGetFileAttributesA)
  hr.registerMonitorHook(hr.HookCreateProcessW,     snoopCreateProcessW)
  hr.registerMonitorHook(hr.HookCreateProcessA,     snoopCreateProcessA)

# --- IAT hook installation -------------------------------------------------

proc installIATHooks() =
  # Windows: install the IAT redirections across every loaded module so we
  # catch calls regardless of which DLL routed them. The IAT patcher returns
  # the original function pointer that was previously in the slot, which we
  # save once for pass-through (wired as the chain's ``original`` callback
  # the FIRST time we see the slot — subsequent IAT slots already point at
  # our trampoline so they'd shadow the real pointer with our hook). We try
  # multiple source DLLs because some modern binaries link against
  # ``api-ms-win-*`` umbrella sets or kernelbase directly rather than
  # kernel32.
  #
  # M11.6 outstanding follow-up: the IAT walk in
  # ``repro_monitor_shim/windows_iat_patcher.nim`` is by-name only and does
  # not handle ordinal imports. ct_interpose's
  # ``ct_interpose/iat_patcher.nim`` has the M49-Corpus #1 ordinal-aware
  # walk; reprobuild's hook surface is all by-name kernel32 imports so this
  # is not a live gap, but the structural divergence remains.
  template hook(dll, name, tramp, storage, kind, origCb: untyped) =
    if storage == nil:
      let orig = patchIATAllModules(dll, name, cast[pointer](tramp))
      if orig != nil:
        storage = cast[kind](orig)
        hr.setOriginalCallback(name, origCb)
        dbg("[repro_monitor_shim] hooked " & name & " from " & dll & "\n")
    else:
      # We already captured the real function pointer; only redirect the IAT.
      discard patchIATAllModules(dll, name, cast[pointer](tramp))

  for dll in ["kernel32.dll", "kernelbase.dll",
              "api-ms-win-core-file-l1-1-0.dll",
              "api-ms-win-core-file-l1-2-0.dll",
              "api-ms-win-core-file-l2-1-0.dll",
              "api-ms-win-core-handle-l1-1-0.dll",
              "api-ms-win-core-processthreads-l1-1-0.dll",
              "api-ms-win-core-processthreads-l1-1-1.dll"]:
    hook(dll, hr.HookCreateFileW,        trampolineCreateFileW,
         origCreateFileW, CreateFileWProc, originalCreateFileW)
    hook(dll, hr.HookCreateFileA,        trampolineCreateFileA,
         origCreateFileA, CreateFileAProc, originalCreateFileA)
    hook(dll, hr.HookReadFile,           trampolineReadFile,
         origReadFile, ReadFileProc, originalReadFile)
    hook(dll, hr.HookWriteFile,          trampolineWriteFile,
         origWriteFile, WriteFileProc, originalWriteFile)
    hook(dll, hr.HookCloseHandle,        trampolineCloseHandle,
         origCloseHandle, CloseHandleProc, originalCloseHandle)
    hook(dll, hr.HookGetFileAttributesExW, trampolineGetFileAttributesExW,
         origGetFileAttributesExW, GetFileAttributesExWProc,
         originalGetFileAttributesExW)
    hook(dll, hr.HookGetFileAttributesExA, trampolineGetFileAttributesExA,
         origGetFileAttributesExA, GetFileAttributesExAProc,
         originalGetFileAttributesExA)
    hook(dll, hr.HookGetFileAttributesW, trampolineGetFileAttributesW,
         origGetFileAttributesW, GetFileAttributesWProc,
         originalGetFileAttributesW)
    hook(dll, hr.HookGetFileAttributesA, trampolineGetFileAttributesA,
         origGetFileAttributesA, GetFileAttributesAProc,
         originalGetFileAttributesA)
    # M72: CreateProcessW/A are intentionally NOT installed via the
    # IAT loop. Nim's ``startProcess`` resolves these from
    # ``winlean.createProcessW`` through ``nimGetProcAddr`` (runtime
    # dlsym), which bypasses the import address table entirely — so
    # an IAT-only hook would miss every Nim-spawned grandchild.
    # ``installInlineHooks`` below puts a 5-byte JMP rel32 at the
    # function body in kernel32 instead; that catches both the IAT
    # path (which would have landed at the same body anyway) and the
    # nimGetProcAddr-resolved pointer path.

proc installInlineHooks() =
  ## Install inline detours for the Win32 entry points that Nim's
  ## dynlib-resolved callers reach without going through the IAT.
  ## See ``ct_inline_hook/install_windows.h`` for the underlying
  ## primitive's contract.
  when not ctInlineHookAvailable:
    return
  else:
    let kernel32 = GetModuleHandleA("kernel32.dll")
    if kernel32 == nil:
      dbg("[repro_monitor_shim] installInlineHooks: kernel32 GetModuleHandle returned NULL\n")
      return

    template installInline(name: cstring; tramp: untyped; storage: untyped;
                           kind: untyped; origCb: untyped) =
      if storage == nil:
        let target = GetProcAddress(kernel32, name)
        if target != nil:
          var trampPtr: pointer = nil
          let rc = ctInlineHookInstall(target, cast[pointer](tramp),
                                       addr trampPtr)
          if rc == 0 and trampPtr != nil:
            storage = cast[kind](trampPtr)
            hr.setOriginalCallback($name, origCb)
            dbg("[repro_monitor_shim] inline-hooked " & $name & "\n")
          else:
            dbg("[repro_monitor_shim] inline-hook FAILED for " & $name &
              " (rc=" & $rc & ")\n")

    installInline("CreateProcessW", trampolineCreateProcessW,
      origCreateProcessW, CreateProcessWProc, originalCreateProcessW)
    installInline("CreateProcessA", trampolineCreateProcessA,
      origCreateProcessA, CreateProcessAProc, originalCreateProcessA)

# --- Public exports ---------------------------------------------------------

proc repro_monitor_shim_init*(configPath: cstring): cint
    {.exportc, dynlib, cdecl.} =
  dbg("[repro_monitor_shim] repro_monitor_shim_init entered\n")
  if not locksReady:
    initLock(initLockVar)
    initLock(recordLock)
    initLock(fdLock)
    locksReady = true
  acquire(initLockVar)
  if initialized:
    release(initLockVar)
    return 0
  withShimMuted:
    fragmentDir = readEnvString("REPRO_MONITOR_FRAGMENT_DIR")
    ensureFragmentDir()
  let dbgMsg = "[repro_monitor_shim] fragmentDir=" & fragmentDir & "\n"
  dbg(cstring(dbgMsg))
  # M26: initialise the hook registry + register the monitor's snoop
  # callbacks BEFORE installing the IAT patches. installIATHooks wires the
  # captured origXxx into the chain's ``original`` slot once it knows the
  # real pointer; the snoop callbacks are already in place so the very
  # first hooked call sees a fully-built chain.
  hr.initShimRegistry()
  registerMonitorSnoopCallbacks()
  initialized = true
  release(initLockVar)
  recordProcessStart()
  installIATHooks()
  installInlineHooks()
  dbg("[repro_monitor_shim] initialization complete\n")
  result = 0

proc repro_monitor_shim_flush*(): cint {.exportc, dynlib, cdecl.} = 0

proc repro_monitor_shim_shutdown*(): cint {.exportc, dynlib, cdecl.} = 0

proc repro_monitor_shim_disable_current_thread*() {.exportc, dynlib, cdecl.} =
  inc disabled

proc repro_monitor_shim_enable_current_thread*() {.exportc, dynlib, cdecl.} =
  if disabled > 0:
    dec disabled

proc repro_monitor_shim_version*(): cstring {.exportc, dynlib, cdecl.} =
  "repro_monitor_shim_m26"

# repro_runtime_init: stdcall entry point invoked by the Windows injector
# via CreateRemoteThread after LoadLibraryW returns. Matches the
# LPTHREAD_START_ROUTINE signature: DWORD WINAPI ThreadProc(LPVOID).
proc repro_runtime_init*(lpParameter: pointer): uint32
    {.stdcall, exportc, dynlib.} =
  result = uint32(repro_monitor_shim_init(nil))

# The exported repro_hook_* signatures mirror the macOS shim so that downstream
# tools that expected to find these symbols (e.g. for integration testing of
# the macOS hooks) can also link against the Windows DLL. They are *not* the
# real injection entry points on Windows — the IAT patcher swaps the imported
# Win32 API pointers directly — but they remain available for symmetry.

type
  PidT = uint32

proc repro_hook_open*(path: cstring; flags, mode: cint): cint
    {.exportc, cdecl, dynlib.} =
  # Windows: POSIX-style open() is not the primary hook surface; we expose this
  # only for ABI parity with macos_interpose.nim. No record is emitted here.
  discard path
  discard flags
  discard mode
  result = -1

proc repro_hook_openat*(dirfd: cint; path: cstring; flags, mode: cint): cint
    {.exportc, cdecl, dynlib.} =
  discard dirfd
  discard path
  discard flags
  discard mode
  result = -1

proc repro_hook_read*(fd: cint; buf: pointer; count: csize_t): int
    {.exportc, cdecl, dynlib.} =
  discard fd
  discard buf
  discard count
  result = -1

proc repro_hook_write*(fd: cint; buf: pointer; count: csize_t): int
    {.exportc, cdecl, dynlib.} =
  discard fd
  discard buf
  discard count
  result = -1

proc repro_hook_stat*(path: cstring; buf: pointer): cint
    {.exportc, cdecl, dynlib.} =
  discard path
  discard buf
  result = -1

proc repro_hook_fork*(): PidT {.exportc, cdecl, dynlib.} =
  # Windows: fork() has no Win32 equivalent; CreateProcess is hooked instead.
  result = PidT(0)

proc repro_hook_execve*(path: cstring; argv, envp: cstringArray): cint
    {.exportc, cdecl, dynlib.} =
  discard path
  discard argv
  discard envp
  result = -1

proc repro_hook_posix_spawn*(pid: ptr PidT; path: cstring;
                              fileActions, attrp: pointer;
                              argv, envp: cstringArray): cint
    {.exportc, cdecl, dynlib.} =
  discard pid
  discard path
  discard fileActions
  discard attrp
  discard argv
  discard envp
  result = -1

{.pop.}
