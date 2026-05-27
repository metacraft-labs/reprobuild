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
# The hook bodies record the same MonitorRecord shape that the macOS
# shim emits, so the existing reader/render/mergeFragments pipeline is
# entirely reused.

import std/[locks, os, tables]
from repro_core/paths import extendedPath

import repro_monitor_depfile/types
import repro_monitor_depfile/writer

import repro_monitor_shim/windows_iat_patcher

{.push raises: [].}

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

# --- Hook bodies -----------------------------------------------------------

proc hookCreateFileW(lpFileName: LPCWSTR, dwDesiredAccess: DWORD,
                     dwShareMode: DWORD,
                     lpSecurityAttributes: LPSECURITY_ATTRIBUTES,
                     dwCreationDisposition: DWORD,
                     dwFlagsAndAttributes: DWORD,
                     hTemplateFile: HANDLE): HANDLE {.stdcall.} =
  if origCreateFileW == nil:
    return INVALID_HANDLE_VALUE
  result = origCreateFileW(lpFileName, dwDesiredAccess, dwShareMode,
                            lpSecurityAttributes, dwCreationDisposition,
                            dwFlagsAndAttributes, hTemplateFile)
  # Windows: every call inside the hook body (Nim allocator, Lock acquire,
  # debug log, table ops) can clobber the thread-local LastError that the
  # real CreateFileW set. CreateFileW notably leaves LastError at
  # ERROR_ALREADY_EXISTS (183) on OPEN_ALWAYS / CREATE_ALWAYS success — a
  # "success with info" code that callers like Rust's std::process::Command
  # inspect to decide retry/error paths. Preserve LastError verbatim across
  # the bookkeeping so the caller sees what the kernel actually returned.
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let path = widePtrToString(lpFileName)
    if result != INVALID_HANDLE_VALUE:
      rememberHandlePath(result, path)
    var record = baseRecord(mrFileOpen,
      observationForCreateFile(dwDesiredAccess, dwCreationDisposition))
    record.result = int64(cast[int](result))
    record.flags = uint32(dwDesiredAccess)
    record.path = path
    record.detail = "CreateFileW"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc hookCreateFileA(lpFileName: LPCSTR, dwDesiredAccess: DWORD,
                     dwShareMode: DWORD,
                     lpSecurityAttributes: LPSECURITY_ATTRIBUTES,
                     dwCreationDisposition: DWORD,
                     dwFlagsAndAttributes: DWORD,
                     hTemplateFile: HANDLE): HANDLE {.stdcall.} =
  if origCreateFileA == nil:
    return INVALID_HANDLE_VALUE
  result = origCreateFileA(lpFileName, dwDesiredAccess, dwShareMode,
                            lpSecurityAttributes, dwCreationDisposition,
                            dwFlagsAndAttributes, hTemplateFile)
  let savedLastError = GetLastError()  # see hookCreateFileW for rationale
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    var path = ""
    if lpFileName != nil:
      path = $lpFileName
    if result != INVALID_HANDLE_VALUE:
      rememberHandlePath(result, path)
    var record = baseRecord(mrFileOpen,
      observationForCreateFile(dwDesiredAccess, dwCreationDisposition))
    record.result = int64(cast[int](result))
    record.flags = uint32(dwDesiredAccess)
    record.path = path
    record.detail = "CreateFileA"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc hookReadFile(hFile: HANDLE, lpBuffer: LPVOID,
                  nNumberOfBytesToRead: DWORD,
                  lpNumberOfBytesRead: ptr DWORD,
                  lpOverlapped: LPOVERLAPPED): BOOL {.stdcall.} =
  if origReadFile == nil:
    return 0
  result = origReadFile(hFile, lpBuffer, nNumberOfBytesToRead,
                         lpNumberOfBytesRead, lpOverlapped)
  # ReadFile preservation is load-bearing. Without it, cargo's
  # std::process::Command::spawn panics with
  # `Os { code: 183, kind: AlreadyExists }` on the rust-binary-with-build-rs
  # fixture. Cargo's Rust stdlib uses STARTUPINFOEXW + UpdateProcThreadAttribute
  # which probes for required buffer size via a path that ends up reading
  # the LastError; if a previous CreateFileW (e.g. on the cargo lockfile)
  # left LastError == 183 and our pre-fix ReadFile hook clobbered it,
  # the subsequent caller-side check would see whatever junk our Nim
  # bookkeeping left behind. (See M11 audit notes.)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    var record = baseRecord(mrFileRead, moFileRead)
    record.path = pathForHandle(hFile)
    if result != 0 and lpNumberOfBytesRead != nil:
      record.result = int64(lpNumberOfBytesRead[])
    else:
      record.result = -1
    record.detail = "ReadFile"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc hookWriteFile(hFile: HANDLE, lpBuffer: LPCVOID,
                   nNumberOfBytesToWrite: DWORD,
                   lpNumberOfBytesWritten: ptr DWORD,
                   lpOverlapped: LPOVERLAPPED): BOOL {.stdcall.} =
  if origWriteFile == nil:
    return 0
  result = origWriteFile(hFile, lpBuffer, nNumberOfBytesToWrite,
                          lpNumberOfBytesWritten, lpOverlapped)
  let savedLastError = GetLastError()  # see hookReadFile / hookCreateFileW
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    var record = baseRecord(mrFileWrite, moFileWrite)
    record.path = pathForHandle(hFile)
    if result != 0 and lpNumberOfBytesWritten != nil:
      record.result = int64(lpNumberOfBytesWritten[])
    else:
      record.result = -1
    record.detail = "WriteFile"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc hookCloseHandle(hObject: HANDLE): BOOL {.stdcall.} =
  if origCloseHandle == nil:
    return 0
  # Windows: CloseHandle is invoked far more frequently than the file
  # operations we care about (cmd.exe alone calls it tens of thousands of
  # times during normal teardown). We gate the bookkeeping on `disabled`
  # and use a try/except wall so any allocator activity inside
  # forgetHandlePath (Nim's table.del / GC bookkeeping) cannot re-enter
  # the hook. If `disabled` is already non-zero we are nested under another
  # hook and must fast-path straight to the original CloseHandle.
  if disabled > 0 or not initialized:
    return origCloseHandle(hObject)
  inc disabled
  try:
    forgetHandlePath(hObject)
  except CatchableError:
    discard
  # Call origCloseHandle AFTER the bookkeeping so the caller observes
  # whatever LastError CloseHandle itself sets (no Nim allocator activity
  # after this point can clobber it).
  result = origCloseHandle(hObject)
  dec disabled

proc hookGetFileAttributesExW(lpFileName: LPCWSTR, fInfoLevelId: DWORD,
                               lpFileInformation: LPVOID): BOOL {.stdcall.} =
  if origGetFileAttributesExW == nil:
    return 0
  result = origGetFileAttributesExW(lpFileName, fInfoLevelId, lpFileInformation)
  let savedLastError = GetLastError()  # ERROR_FILE_NOT_FOUND on absent path
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    var record = baseRecord(mrPathProbe, moPathProbe)
    record.path = widePtrToString(lpFileName)
    record.result = int64(result)
    record.probeResult = probeFromBool(result)
    record.detail = "GetFileAttributesExW"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc hookGetFileAttributesExA(lpFileName: LPCSTR, fInfoLevelId: DWORD,
                               lpFileInformation: LPVOID): BOOL {.stdcall.} =
  if origGetFileAttributesExA == nil:
    return 0
  result = origGetFileAttributesExA(lpFileName, fInfoLevelId, lpFileInformation)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    var record = baseRecord(mrPathProbe, moPathProbe)
    if lpFileName != nil:
      record.path = $lpFileName
    record.result = int64(result)
    record.probeResult = probeFromBool(result)
    record.detail = "GetFileAttributesExA"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc hookGetFileAttributesW(lpFileName: LPCWSTR): DWORD {.stdcall.} =
  if origGetFileAttributesW == nil:
    return 0xFFFFFFFF'u32
  result = origGetFileAttributesW(lpFileName)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    var record = baseRecord(mrPathProbe, moPathProbe)
    record.path = widePtrToString(lpFileName)
    record.result = int64(result)
    record.probeResult =
      if result == 0xFFFFFFFF'u32: prAbsent else: prExistingOther
    record.detail = "GetFileAttributesW"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc hookGetFileAttributesA(lpFileName: LPCSTR): DWORD {.stdcall.} =
  if origGetFileAttributesA == nil:
    return 0xFFFFFFFF'u32
  result = origGetFileAttributesA(lpFileName)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    var record = baseRecord(mrPathProbe, moPathProbe)
    if lpFileName != nil:
      record.path = $lpFileName
    record.result = int64(result)
    record.probeResult =
      if result == 0xFFFFFFFF'u32: prAbsent else: prExistingOther
    record.detail = "GetFileAttributesA"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc hookCreateProcessW(lpApplicationName: LPCWSTR,
                        lpCommandLine: LPWSTR,
                        lpProcessAttributes: LPSECURITY_ATTRIBUTES,
                        lpThreadAttributes: LPSECURITY_ATTRIBUTES,
                        bInheritHandles: BOOL,
                        dwCreationFlags: DWORD,
                        lpEnvironment: LPVOID,
                        lpCurrentDirectory: LPCWSTR,
                        lpStartupInfo: ptr STARTUPINFOW,
                        lpProcessInformation: ptr PROCESS_INFORMATION): BOOL
                        {.stdcall.} =
  if origCreateProcessW == nil:
    return 0
  result = origCreateProcessW(lpApplicationName, lpCommandLine,
                               lpProcessAttributes, lpThreadAttributes,
                               bInheritHandles, dwCreationFlags,
                               lpEnvironment, lpCurrentDirectory,
                               lpStartupInfo, lpProcessInformation)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    var record = baseRecord(mrProcessSpawn, moExecute)
    if result != 0 and lpProcessInformation != nil:
      record.childOsPid = uint64(lpProcessInformation[].dwProcessId)
    record.result = int64(result)
    var path = ""
    if lpApplicationName != nil:
      path = widePtrToString(lpApplicationName)
    elif lpCommandLine != nil:
      path = widePtrToString(cast[LPCWSTR](lpCommandLine))
    record.path = path
    record.detail = "CreateProcessW"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc hookCreateProcessA(lpApplicationName: LPCSTR,
                        lpCommandLine: LPSTR,
                        lpProcessAttributes: LPSECURITY_ATTRIBUTES,
                        lpThreadAttributes: LPSECURITY_ATTRIBUTES,
                        bInheritHandles: BOOL,
                        dwCreationFlags: DWORD,
                        lpEnvironment: LPVOID,
                        lpCurrentDirectory: LPCSTR,
                        lpStartupInfo: ptr STARTUPINFOA,
                        lpProcessInformation: ptr PROCESS_INFORMATION): BOOL
                        {.stdcall.} =
  if origCreateProcessA == nil:
    return 0
  result = origCreateProcessA(lpApplicationName, lpCommandLine,
                               lpProcessAttributes, lpThreadAttributes,
                               bInheritHandles, dwCreationFlags,
                               lpEnvironment, lpCurrentDirectory,
                               lpStartupInfo, lpProcessInformation)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    var record = baseRecord(mrProcessSpawn, moExecute)
    if result != 0 and lpProcessInformation != nil:
      record.childOsPid = uint64(lpProcessInformation[].dwProcessId)
    record.result = int64(result)
    var path = ""
    if lpApplicationName != nil:
      path = $lpApplicationName
    elif lpCommandLine != nil:
      path = $cast[cstring](lpCommandLine)
    record.path = path
    record.detail = "CreateProcessA"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

# --- IAT hook installation -------------------------------------------------

proc installIATHooks() =
  # Windows: install the IAT redirections across every loaded module so we
  # catch calls regardless of which DLL routed them. The IAT patcher returns
  # the original function pointer that was previously in the slot, which we
  # save once for pass-through. We try multiple source DLLs because some
  # modern binaries link against `api-ms-win-*` umbrella sets or kernelbase
  # directly rather than kernel32. Importantly, after the first iteration
  # the IAT is already pointing at our hook, so subsequent calls return our
  # hook as "the original" — we must NOT overwrite the saved pointer once
  # set, otherwise origXxx would point at hookXxx and we would infinitely
  # recurse on pass-through.
  template hook(dll, name, hk, storage, kind: untyped) =
    if storage == nil:
      let orig = patchIATAllModules(dll, name, cast[pointer](hk))
      if orig != nil:
        storage = cast[kind](orig)
        dbg("[repro_monitor_shim] hooked " & name & " from " & dll & "\n")
    else:
      # We already captured the real function pointer; only redirect the IAT.
      discard patchIATAllModules(dll, name, cast[pointer](hk))

  for dll in ["kernel32.dll", "kernelbase.dll",
              "api-ms-win-core-file-l1-1-0.dll",
              "api-ms-win-core-file-l1-2-0.dll",
              "api-ms-win-core-file-l2-1-0.dll",
              "api-ms-win-core-handle-l1-1-0.dll",
              "api-ms-win-core-processthreads-l1-1-0.dll",
              "api-ms-win-core-processthreads-l1-1-1.dll"]:
    hook(dll, "CreateFileW", hookCreateFileW,
         origCreateFileW, CreateFileWProc)
    hook(dll, "CreateFileA", hookCreateFileA,
         origCreateFileA, CreateFileAProc)
    hook(dll, "ReadFile", hookReadFile,
         origReadFile, ReadFileProc)
    hook(dll, "WriteFile", hookWriteFile,
         origWriteFile, WriteFileProc)
    hook(dll, "CloseHandle", hookCloseHandle,
         origCloseHandle, CloseHandleProc)
    hook(dll, "GetFileAttributesExW", hookGetFileAttributesExW,
         origGetFileAttributesExW, GetFileAttributesExWProc)
    hook(dll, "GetFileAttributesExA", hookGetFileAttributesExA,
         origGetFileAttributesExA, GetFileAttributesExAProc)
    hook(dll, "GetFileAttributesW", hookGetFileAttributesW,
         origGetFileAttributesW, GetFileAttributesWProc)
    hook(dll, "GetFileAttributesA", hookGetFileAttributesA,
         origGetFileAttributesA, GetFileAttributesAProc)
    hook(dll, "CreateProcessW", hookCreateProcessW,
         origCreateProcessW, CreateProcessWProc)
    hook(dll, "CreateProcessA", hookCreateProcessA,
         origCreateProcessA, CreateProcessAProc)

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
  initialized = true
  release(initLockVar)
  recordProcessStart()
  installIATHooks()
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
  "repro_monitor_shim_m11"

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
