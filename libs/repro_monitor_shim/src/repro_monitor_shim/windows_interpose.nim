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
import repro_monitor_shim/install_audit

# Framework's safer grandchild-injection primitive — replaces the
# bespoke INFINITE-wait inject_dll path with concurrent-injection cap
# + per-call deadline + already-mapped probe + resume-before-init.
import stackable_hooks/propagation_windows as shProp

{.push raises: [].}

# ---------------------------------------------------------------------------
# M73 — dispatch-mechanism-agnostic install backend.
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
# M72 introduced inline hooking for CreateProcessW/A only; M73 promotes
# every hooked Win32 API to the same install path. Mirror the
# codetracer-native-recorder's M50.2 inline-hook primitive
# (``ct_inline_hook/install_windows.c``): install a 5-byte
# ``JMP rel32`` at the start of each ``kernel32!Xxx`` function
# redirecting to the existing trampolines. IAT patching is retained
# only as the fallback for entries the inline backend rejects.
#
# The C source files live in the recorder repo's ``ct_inline_hook``
# directory. Resolve their path at compile time, anchored on
# ``currentSourcePath`` so a vendored copy under
# ``libs/repro_monitor_shim/vendor/ct_inline_hook`` would also work
# if the recorder sibling checkout is missing.

# M73 used to {.compile.} the ct_inline_hook C sources directly out of
# the codetracer-native-recorder sibling checkout. That entangled
# reprobuild's build with the recorder's source tree; with the
# stackable-hooks split the inline-detour primitive now lives in
# ``metacraft-labs/nim-stackable-hooks`` and we pull it via a Nim
# wrapper that handles the {.compile.} blocks under the hood.
import stackable_hooks/inline_hook/windows_inline_hook

const ctInlineHookAvailable = true

template ctInlineHookInstall(target, hook: pointer;
                             outTrampoline: ptr pointer): cint =
  inlineHookInstall(target, hook, outTrampoline)

template ctInlineHookBeginTransaction(): cint =
  inlineHookBeginTransaction()

template ctInlineHookCommitTransaction(): cint =
  inlineHookCommitTransaction()

template ctInlineHookAbortTransaction(): cint =
  inlineHookAbortTransaction()

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

  # M73 Phase 5 — extended hook surface ----------------------------------

  DeleteFileWProc = proc(lpFileName: LPCWSTR): BOOL {.stdcall, raises: [].}
  DeleteFileAProc = proc(lpFileName: LPCSTR): BOOL {.stdcall, raises: [].}

  CreateDirectoryWProc = proc(lpPathName: LPCWSTR,
                              lpSecurityAttributes: LPSECURITY_ATTRIBUTES): BOOL
                              {.stdcall, raises: [].}
  CreateDirectoryAProc = proc(lpPathName: LPCSTR,
                              lpSecurityAttributes: LPSECURITY_ATTRIBUTES): BOOL
                              {.stdcall, raises: [].}

  # CopyFileW/A: per MSDN the signature is (lpExistingFileName,
  # lpNewFileName, bFailIfExists) -> BOOL.
  CopyFileWProc = proc(lpExistingFileName: LPCWSTR,
                       lpNewFileName: LPCWSTR,
                       bFailIfExists: BOOL): BOOL {.stdcall, raises: [].}
  CopyFileAProc = proc(lpExistingFileName: LPCSTR,
                       lpNewFileName: LPCSTR,
                       bFailIfExists: BOOL): BOOL {.stdcall, raises: [].}

  # MoveFileExW/A: per MSDN (lpExistingFileName, lpNewFileName, dwFlags) -> BOOL.
  # lpNewFileName MAY be NULL when MOVEFILE_DELAY_UNTIL_REBOOT + delete-on-reboot
  # semantics are requested.
  MoveFileExWProc = proc(lpExistingFileName: LPCWSTR,
                         lpNewFileName: LPCWSTR,
                         dwFlags: DWORD): BOOL {.stdcall, raises: [].}
  MoveFileExAProc = proc(lpExistingFileName: LPCSTR,
                         lpNewFileName: LPCSTR,
                         dwFlags: DWORD): BOOL {.stdcall, raises: [].}

  # GetFileInformationByHandleEx: (hFile, FileInformationClass,
  # lpFileInformation, dwBufferSize) -> BOOL. FILE_INFO_BY_HANDLE_CLASS
  # is an enum (int32-equivalent); we pass it through as DWORD slot.
  GetFileInformationByHandleExProc = proc(hFile: HANDLE,
                                          FileInformationClass: DWORD,
                                          lpFileInformation: LPVOID,
                                          dwBufferSize: DWORD): BOOL
                                          {.stdcall, raises: [].}

  SetCurrentDirectoryWProc = proc(lpPathName: LPCWSTR): BOOL
                                  {.stdcall, raises: [].}
  SetCurrentDirectoryAProc = proc(lpPathName: LPCSTR): BOOL
                                  {.stdcall, raises: [].}

  # NtCreateFile lives in ntdll. Signature (per MSDN /
  # phnt headers) is:
  #   NTSTATUS NtCreateFile(
  #     PHANDLE            FileHandle,
  #     ACCESS_MASK        DesiredAccess,
  #     POBJECT_ATTRIBUTES ObjectAttributes,
  #     PIO_STATUS_BLOCK   IoStatusBlock,
  #     PLARGE_INTEGER     AllocationSize,
  #     ULONG              FileAttributes,
  #     ULONG              ShareAccess,
  #     ULONG              CreateDisposition,
  #     ULONG              CreateOptions,
  #     PVOID              EaBuffer,
  #     ULONG              EaLength);
  # ACCESS_MASK is a DWORD-sized value; NTSTATUS is a 32-bit signed
  # integer; both pack into uint64 ABI slots cleanly on x64 stdcall.
  NTSTATUS = int32
  NtCreateFileProc = proc(FileHandle: ptr HANDLE,
                          DesiredAccess: DWORD,
                          ObjectAttributes: pointer,
                          IoStatusBlock: pointer,
                          AllocationSize: ptr LARGE_INTEGER,
                          FileAttributes: DWORD,
                          ShareAccess: DWORD,
                          CreateDisposition: DWORD,
                          CreateOptions: DWORD,
                          EaBuffer: pointer,
                          EaLength: DWORD): NTSTATUS
                          {.stdcall, raises: [].}

  # NtQueryAttributesFile / NtQueryFullAttributesFile catch libuv's
  # uv_fs_stat fast-path (Node.js 20+). Path lives in OBJECT_ATTRIBUTES.
  NtQueryAttributesFileProc = proc(ObjectAttributes: pointer;
                                   FileInformation: pointer): NTSTATUS
                                   {.stdcall, raises: [].}

  # NtQueryDirectoryFile catches libuv's uv_fs_scandir. The directory
  # handle was opened earlier via NtCreateFile / CreateFileW; we look
  # up its path in handlePaths for attribution.
  NtQueryDirectoryFileProc = proc(FileHandle: HANDLE;
                                  Event: HANDLE;
                                  ApcRoutine: pointer;
                                  ApcContext: pointer;
                                  IoStatusBlock: pointer;
                                  FileInformation: pointer;
                                  Length: DWORD;
                                  FileInformationClass: DWORD;
                                  ReturnSingleEntry: BOOL;
                                  FileName: pointer;
                                  RestartScan: BOOL): NTSTATUS
                                  {.stdcall, raises: [].}

  # NtQueryInformationByName — libuv 1.52's fs.statSync fast-path.
  # Path lives in ObjectAttributes (same as NtCreateFile / etc.).
  NtQueryInformationByNameProc = proc(ObjectAttributes: pointer;
                                       IoStatusBlock: pointer;
                                       FileInformation: pointer;
                                       Length: DWORD;
                                       FileInformationClass: DWORD): NTSTATUS
                                       {.stdcall, raises: [].}

  # NtQueryDirectoryFileEx — Win10 1709+ scandir API. Same handle-based
  # contract as NtQueryDirectoryFile but uses a QueryFlags bitmask
  # (SL_RESTART_SCAN = 0x01) instead of separate ReturnSingleEntry +
  # RestartScan BOOL args. 10 stdcall args (vs 11 for the original).
  NtQueryDirectoryFileExProc = proc(FileHandle: HANDLE;
                                    Event: HANDLE;
                                    ApcRoutine: pointer;
                                    ApcContext: pointer;
                                    IoStatusBlock: pointer;
                                    FileInformation: pointer;
                                    Length: DWORD;
                                    FileInformationClass: DWORD;
                                    QueryFlags: DWORD;
                                    FileName: pointer): NTSTATUS
                                    {.stdcall, raises: [].}

  # FindFirstFileW / FindFirstFileExW / FindNextFileW / FindClose —
  # kernel32 directory-enumerate surface used by libuv 1.52 / Node 24
  # for fs.readdirSync. The HANDLE returned by FindFirstFile* is the
  # SEARCH handle (distinct from the file-handle type), but we only
  # need to record the path that the search was started on, so we
  # don't track it across FindNextFileW.
  FindFirstFileWProc = proc(lpFileName: LPCWSTR;
                             lpFindFileData: pointer): HANDLE
                             {.stdcall, raises: [].}
  FindFirstFileExWProc = proc(lpFileName: LPCWSTR;
                              fInfoLevelId: DWORD;
                              lpFindFileData: pointer;
                              fSearchOp: DWORD;
                              lpSearchFilter: pointer;
                              dwAdditionalFlags: DWORD): HANDLE
                              {.stdcall, raises: [].}
  FindNextFileWProc = proc(hFindFile: HANDLE;
                            lpFindFileData: pointer): BOOL
                            {.stdcall, raises: [].}
  FindCloseProc = proc(hFindFile: HANDLE): BOOL
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
  # M73 Phase 5 — extended hook surface.
  origDeleteFileW: DeleteFileWProc
  origDeleteFileA: DeleteFileAProc
  origCreateDirectoryW: CreateDirectoryWProc
  origCreateDirectoryA: CreateDirectoryAProc
  origCopyFileW: CopyFileWProc
  origCopyFileA: CopyFileAProc
  origMoveFileExW: MoveFileExWProc
  origMoveFileExA: MoveFileExAProc
  origGetFileInformationByHandleEx: GetFileInformationByHandleExProc
  origSetCurrentDirectoryW: SetCurrentDirectoryWProc
  origSetCurrentDirectoryA: SetCurrentDirectoryAProc
  origNtCreateFile: NtCreateFileProc
  origNtQueryAttributesFile: NtQueryAttributesFileProc
  origNtQueryFullAttributesFile: NtQueryAttributesFileProc
  origNtQueryDirectoryFile: NtQueryDirectoryFileProc
  origNtQueryInformationByName: NtQueryInformationByNameProc
  origNtQueryDirectoryFileEx: NtQueryDirectoryFileExProc
  origFindFirstFileW: FindFirstFileWProc
  origFindFirstFileExW: FindFirstFileExWProc
  origFindNextFileW: FindNextFileWProc
  origFindClose: FindCloseProc

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

proc unicodeStringToString(uniPtr: pointer): string =
  ## Extract a Nim string from a Windows UNICODE_STRING.
  ## Layout (x64): USHORT Length; USHORT MaxLen; PWSTR Buffer (offset 8).
  if uniPtr == nil:
    return ""
  let lengthBytes = cast[ptr uint16](uniPtr)[]
  if lengthBytes == 0:
    return ""
  let bufferPtr = cast[ptr ptr uint16](
    cast[ByteAddress](uniPtr) + 8)[]
  if bufferPtr == nil:
    return ""
  let codeUnits = int32(lengthBytes div 2)
  let needed = WideCharToMultiByte(65001'u32, 0'u32,
    cast[LPCWSTR](bufferPtr), codeUnits, nil, 0'i32, nil, nil)
  if needed <= 0:
    return ""
  result = newString(needed)
  discard WideCharToMultiByte(65001'u32, 0'u32,
    cast[LPCWSTR](bufferPtr), codeUnits,
    cast[LPSTR](addr result[0]), needed, nil, nil)

proc objectAttributesToString(oaPtr: pointer): string =
  ## Extract the path from a Windows OBJECT_ATTRIBUTES.
  ## ObjectName field at offset 16 (x64). Strips NT-style prefixes
  ## (\??\, \DosDevices\) so downstream record consumers see the same
  ## form GetFileAttributesExW records.
  if oaPtr == nil:
    return ""
  let objectName = cast[ptr pointer](
    cast[ByteAddress](oaPtr) + 16)[]
  if objectName == nil:
    return ""
  let raw = unicodeStringToString(objectName)
  if raw.len >= 4 and raw[0 .. 3] == "\\??\\":
    return raw[4 .. ^1]
  if raw.len >= 12 and raw[0 .. 11] == "\\DosDevices\\":
    return raw[12 .. ^1]
  raw

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

# --- M73 Phase 5: original-callback wrappers for the extended hook surface.

proc originalDeleteFileW(ctx: var hr.HookContext) {.raises: [].} =
  if origDeleteFileW == nil:
    ctx.result = 0
    return
  let lpFileName = cast[LPCWSTR](ctx.args[0])
  let r = origDeleteFileW(lpFileName)
  ctx.result = uint64(uint32(r))

proc originalDeleteFileA(ctx: var hr.HookContext) {.raises: [].} =
  if origDeleteFileA == nil:
    ctx.result = 0
    return
  let lpFileName = cast[LPCSTR](ctx.args[0])
  let r = origDeleteFileA(lpFileName)
  ctx.result = uint64(uint32(r))

proc originalCreateDirectoryW(ctx: var hr.HookContext) {.raises: [].} =
  if origCreateDirectoryW == nil:
    ctx.result = 0
    return
  let lpPathName = cast[LPCWSTR](ctx.args[0])
  let lpSecAttr = cast[LPSECURITY_ATTRIBUTES](ctx.args[1])
  let r = origCreateDirectoryW(lpPathName, lpSecAttr)
  ctx.result = uint64(uint32(r))

proc originalCreateDirectoryA(ctx: var hr.HookContext) {.raises: [].} =
  if origCreateDirectoryA == nil:
    ctx.result = 0
    return
  let lpPathName = cast[LPCSTR](ctx.args[0])
  let lpSecAttr = cast[LPSECURITY_ATTRIBUTES](ctx.args[1])
  let r = origCreateDirectoryA(lpPathName, lpSecAttr)
  ctx.result = uint64(uint32(r))

proc originalCopyFileW(ctx: var hr.HookContext) {.raises: [].} =
  if origCopyFileW == nil:
    ctx.result = 0
    return
  let lpExisting = cast[LPCWSTR](ctx.args[0])
  let lpNew      = cast[LPCWSTR](ctx.args[1])
  let bFail      = BOOL(ctx.args[2])
  let r = origCopyFileW(lpExisting, lpNew, bFail)
  ctx.result = uint64(uint32(r))

proc originalCopyFileA(ctx: var hr.HookContext) {.raises: [].} =
  if origCopyFileA == nil:
    ctx.result = 0
    return
  let lpExisting = cast[LPCSTR](ctx.args[0])
  let lpNew      = cast[LPCSTR](ctx.args[1])
  let bFail      = BOOL(ctx.args[2])
  let r = origCopyFileA(lpExisting, lpNew, bFail)
  ctx.result = uint64(uint32(r))

proc originalMoveFileExW(ctx: var hr.HookContext) {.raises: [].} =
  if origMoveFileExW == nil:
    ctx.result = 0
    return
  let lpExisting = cast[LPCWSTR](ctx.args[0])
  let lpNew      = cast[LPCWSTR](ctx.args[1])
  let dwFlags    = DWORD(ctx.args[2])
  let r = origMoveFileExW(lpExisting, lpNew, dwFlags)
  ctx.result = uint64(uint32(r))

proc originalMoveFileExA(ctx: var hr.HookContext) {.raises: [].} =
  if origMoveFileExA == nil:
    ctx.result = 0
    return
  let lpExisting = cast[LPCSTR](ctx.args[0])
  let lpNew      = cast[LPCSTR](ctx.args[1])
  let dwFlags    = DWORD(ctx.args[2])
  let r = origMoveFileExA(lpExisting, lpNew, dwFlags)
  ctx.result = uint64(uint32(r))

proc originalGetFileInformationByHandleEx(ctx: var hr.HookContext)
    {.raises: [].} =
  if origGetFileInformationByHandleEx == nil:
    ctx.result = 0
    return
  let hFile             = cast[HANDLE](ctx.args[0])
  let infoClass         = DWORD(ctx.args[1])
  let lpFileInformation = cast[LPVOID](ctx.args[2])
  let dwBufferSize      = DWORD(ctx.args[3])
  let r = origGetFileInformationByHandleEx(hFile, infoClass,
                                            lpFileInformation, dwBufferSize)
  ctx.result = uint64(uint32(r))

proc originalSetCurrentDirectoryW(ctx: var hr.HookContext) {.raises: [].} =
  if origSetCurrentDirectoryW == nil:
    ctx.result = 0
    return
  let lpPathName = cast[LPCWSTR](ctx.args[0])
  let r = origSetCurrentDirectoryW(lpPathName)
  ctx.result = uint64(uint32(r))

proc originalSetCurrentDirectoryA(ctx: var hr.HookContext) {.raises: [].} =
  if origSetCurrentDirectoryA == nil:
    ctx.result = 0
    return
  let lpPathName = cast[LPCSTR](ctx.args[0])
  let r = origSetCurrentDirectoryA(lpPathName)
  ctx.result = uint64(uint32(r))

proc originalNtCreateFile(ctx: var hr.HookContext) {.raises: [].} =
  if origNtCreateFile == nil:
    # STATUS_UNSUCCESSFUL (0xC0000001) — caller sees an NTSTATUS failure
    # rather than a silent 0 (which is STATUS_SUCCESS!) when the
    # original was never captured.
    ctx.result = uint64(uint32(0xC0000001'u32))
    return
  let FileHandle        = cast[ptr HANDLE](ctx.args[0])
  let DesiredAccess     = DWORD(ctx.args[1])
  let ObjectAttributes  = cast[pointer](ctx.args[2])
  let IoStatusBlock     = cast[pointer](ctx.args[3])
  let AllocationSize    = cast[ptr LARGE_INTEGER](ctx.args[4])
  let FileAttributes    = DWORD(ctx.args[5])
  let ShareAccess       = DWORD(ctx.args[6])
  let CreateDisposition = DWORD(ctx.args[7])
  let CreateOptions     = DWORD(ctx.args[8])
  let EaBuffer          = cast[pointer](ctx.args[9])
  let EaLength          = DWORD(ctx.args[10])
  let r = origNtCreateFile(FileHandle, DesiredAccess, ObjectAttributes,
                            IoStatusBlock, AllocationSize, FileAttributes,
                            ShareAccess, CreateDisposition, CreateOptions,
                            EaBuffer, EaLength)
  # NTSTATUS is signed 32-bit; pack as unsigned for the uint64 slot and
  # let the trampoline reinterpret on the way out.
  ctx.result = uint64(uint32(r))

proc originalNtQueryAttributesFile(ctx: var hr.HookContext) {.raises: [].} =
  if origNtQueryAttributesFile == nil:
    ctx.result = uint64(uint32(0xC0000001'u32))
    return
  let ObjectAttributes = cast[pointer](ctx.args[0])
  let FileInformation  = cast[pointer](ctx.args[1])
  let r = origNtQueryAttributesFile(ObjectAttributes, FileInformation)
  ctx.result = uint64(uint32(r))

proc originalNtQueryFullAttributesFile(ctx: var hr.HookContext) {.raises: [].} =
  if origNtQueryFullAttributesFile == nil:
    ctx.result = uint64(uint32(0xC0000001'u32))
    return
  let ObjectAttributes = cast[pointer](ctx.args[0])
  let FileInformation  = cast[pointer](ctx.args[1])
  let r = origNtQueryFullAttributesFile(ObjectAttributes, FileInformation)
  ctx.result = uint64(uint32(r))

proc originalNtQueryDirectoryFileEx(ctx: var hr.HookContext) {.raises: [].} =
  if origNtQueryDirectoryFileEx == nil:
    ctx.result = uint64(uint32(0xC0000001'u32))
    return
  let FileHandle           = cast[HANDLE](ctx.args[0])
  let Event                = cast[HANDLE](ctx.args[1])
  let ApcRoutine           = cast[pointer](ctx.args[2])
  let ApcContext           = cast[pointer](ctx.args[3])
  let IoStatusBlock        = cast[pointer](ctx.args[4])
  let FileInformation      = cast[pointer](ctx.args[5])
  let Length               = DWORD(ctx.args[6])
  let FileInformationClass = DWORD(ctx.args[7])
  let QueryFlags           = DWORD(ctx.args[8])
  let FileName             = cast[pointer](ctx.args[9])
  let r = origNtQueryDirectoryFileEx(FileHandle, Event, ApcRoutine, ApcContext,
                                     IoStatusBlock, FileInformation, Length,
                                     FileInformationClass, QueryFlags, FileName)
  ctx.result = uint64(uint32(r))

proc originalFindFirstFileW(ctx: var hr.HookContext) {.raises: [].} =
  if origFindFirstFileW == nil:
    ctx.result = cast[uint64](INVALID_HANDLE_VALUE)
    return
  let lpFileName    = cast[LPCWSTR](ctx.args[0])
  let lpFindFileData = cast[pointer](ctx.args[1])
  let r = origFindFirstFileW(lpFileName, lpFindFileData)
  ctx.result = cast[uint64](r)

proc originalFindFirstFileExW(ctx: var hr.HookContext) {.raises: [].} =
  if origFindFirstFileExW == nil:
    ctx.result = cast[uint64](INVALID_HANDLE_VALUE)
    return
  let lpFileName       = cast[LPCWSTR](ctx.args[0])
  let fInfoLevelId     = DWORD(ctx.args[1])
  let lpFindFileData   = cast[pointer](ctx.args[2])
  let fSearchOp        = DWORD(ctx.args[3])
  let lpSearchFilter   = cast[pointer](ctx.args[4])
  let dwAdditionalFlags = DWORD(ctx.args[5])
  let r = origFindFirstFileExW(lpFileName, fInfoLevelId, lpFindFileData,
                                fSearchOp, lpSearchFilter, dwAdditionalFlags)
  ctx.result = cast[uint64](r)

proc originalFindNextFileW(ctx: var hr.HookContext) {.raises: [].} =
  if origFindNextFileW == nil:
    ctx.result = uint64(0'u32)
    return
  let hFindFile       = cast[HANDLE](ctx.args[0])
  let lpFindFileData  = cast[pointer](ctx.args[1])
  let r = origFindNextFileW(hFindFile, lpFindFileData)
  ctx.result = uint64(uint32(r))

proc originalFindClose(ctx: var hr.HookContext) {.raises: [].} =
  if origFindClose == nil:
    ctx.result = uint64(0'u32)
    return
  let hFindFile = cast[HANDLE](ctx.args[0])
  let r = origFindClose(hFindFile)
  ctx.result = uint64(uint32(r))

proc originalNtQueryInformationByName(ctx: var hr.HookContext) {.raises: [].} =
  if origNtQueryInformationByName == nil:
    ctx.result = uint64(uint32(0xC0000001'u32))
    return
  let ObjectAttributes     = cast[pointer](ctx.args[0])
  let IoStatusBlock        = cast[pointer](ctx.args[1])
  let FileInformation      = cast[pointer](ctx.args[2])
  let Length               = DWORD(ctx.args[3])
  let FileInformationClass = DWORD(ctx.args[4])
  let r = origNtQueryInformationByName(ObjectAttributes, IoStatusBlock,
                                       FileInformation, Length,
                                       FileInformationClass)
  ctx.result = uint64(uint32(r))

proc originalNtQueryDirectoryFile(ctx: var hr.HookContext) {.raises: [].} =
  if origNtQueryDirectoryFile == nil:
    ctx.result = uint64(uint32(0xC0000001'u32))
    return
  let FileHandle           = cast[HANDLE](ctx.args[0])
  let Event                = cast[HANDLE](ctx.args[1])
  let ApcRoutine           = cast[pointer](ctx.args[2])
  let ApcContext           = cast[pointer](ctx.args[3])
  let IoStatusBlock        = cast[pointer](ctx.args[4])
  let FileInformation      = cast[pointer](ctx.args[5])
  let Length               = DWORD(ctx.args[6])
  let FileInformationClass = DWORD(ctx.args[7])
  let ReturnSingleEntry    = BOOL(ctx.args[8])
  let FileName             = cast[pointer](ctx.args[9])
  let RestartScan          = BOOL(ctx.args[10])
  let r = origNtQueryDirectoryFile(FileHandle, Event, ApcRoutine, ApcContext,
                                   IoStatusBlock, FileInformation, Length,
                                   FileInformationClass, ReturnSingleEntry,
                                   FileName, RestartScan)
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
# the IAT fallback path is removed entirely (M73 Phase 6). Today the
# trampoline (inline or IAT) still allocates inside the snoop body so
# the dance is load-bearing regardless of which install path landed.

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

proc selfDllPath(): string {.raises: [].} =
  ## Narrow string form of ``selfDllPathW`` for callers that need a
  ## native ``string`` (e.g. the stackable-hooks framework's
  ## ``injectShimIntoChild`` takes the library path as a UTF-8 string
  ## and re-widens it internally). The shim DLL path is always plain
  ## ASCII so the ``[i] and 0xFF`` low-byte extract is lossless.
  let last = selfDllPathW.len - 1
  if last <= 0:
    return ""
  result = newString(last)
  for i in 0 ..< last:
    result[i] = char(selfDllPathW[i] and 0xFF)

# Inject the shim DLL into ``hProcess`` by allocating a buffer in the
# remote address space, writing our own DLL path into it, and firing
# LoadLibraryW via CreateRemoteThread. LoadLibraryW's entry-point
# address is identical in the child because kernel32 maps at the same
# base across processes for the lifetime of the OS boot session.
#
# Returns true on success. Failures are swallowed silently — child
# might still run with degraded (but correct) monitoring evidence,
# which beats crashing the child or killing the parent.
#
# **Legacy code path**: This proc is retained for backwards compat
# with non-snoop callers that still reach for the bespoke injector.
# The snoop hooks now route through
# ``stackable_hooks/propagation_windows`` which adds the four safety
# knobs documented in that module (maxInFlight semaphore, deadline
# replacing INFINITE wait, EnumProcessModulesEx skip,
# resume-before-init ordering). For new call sites, prefer the
# framework's ``injectShimIntoChild(hProcess, libraryPath,
# initSymbol)``.
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
      discard shProp.injectShimIntoChild(pi.hProcess, selfDllPath(),
        "repro_runtime_init")
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
      discard shProp.injectShimIntoChild(pi.hProcess, selfDllPath(),
        "repro_runtime_init")
      if not callerAskedForSuspendedA:
        discard ResumeThread(pi.hThread)
  except CatchableError:
    discard
  SetLastError(savedLastError)

# --- M73 Phase 5 snoop callbacks -------------------------------------------
#
# Schema decisions (no MonitorRecordKind additions — option (b) from the
# Phase 5 milestone notes):
#
#   DeleteFileW/A      -> mrFileWrite + moFileWrite, detail = "DeleteFileW"
#                          /"DeleteFileA". The record's `flags` field is left
#                          at zero; the `detail` string carries the mutation
#                          class for downstream interpretation.
#   CreateDirectoryW/A -> mrFileWrite + moFileWrite, detail =
#                          "CreateDirectoryW"/"CreateDirectoryA". Same
#                          rationale: mutation event with a directory-create
#                          discriminator in `detail`.
#   CopyFileW/A        -> TWO records per call: source (mrFileOpen +
#                          moFileRead, detail = "CopyFileW:src") and dest
#                          (mrFileWrite + moFileWrite,
#                          detail = "CopyFileW:dst"). Mirrors
#                          Monitor-Hook-Shim.md §"CopyFileW / CopyFileA |
#                          Read source and create/write destination".
#   MoveFileExW/A      -> TWO records: source (mrFileWrite + moFileWrite,
#                          detail = "MoveFileExW:src") and dest (mrFileWrite +
#                          moFileWrite, detail = "MoveFileExW:dst"). lpNewFileName
#                          MAY be NULL (delete-on-reboot); in that case only
#                          the source record is emitted with the
#                          MOVEFILE_DELAY_UNTIL_REBOOT-aware detail.
#   GetFileInformationByHandleEx -> mrPathProbe + moPathProbe with the path
#                          resolved via `pathForHandle`. detail =
#                          "GetFileInformationByHandleEx". When the handle's
#                          path is unknown (caller passed a handle the shim
#                          didn't see open), we still emit the record with
#                          path = "" so the per-call count is preserved.
#   SetCurrentDirectoryW/A -> mrFileOpen + moExecute with the new cwd in
#                          `path`, detail = "SetCurrentDirectoryW"/A. The
#                          spec calls it "update process cwd model"; the
#                          existing schema has no cwd-specific kind so we
#                          pick the closest "process-context update" pair.
#   NtCreateFile       -> mrFileOpen + moFileOpen, detail = "NtCreateFile",
#                          path = "" (extraction deferred — the path lives
#                          inside OBJECT_ATTRIBUTES.ObjectName and decoding
#                          it under the shim hot-path requires more care
#                          than Phase 5 allows; the dispatch-mechanism test
#                          only requires the snoop FIRE, not preserve the
#                          path).

proc snoopDeleteFileW(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpFileName = cast[LPCWSTR](ctx.args[0])
    let r = BOOL(ctx.result)
    var record = baseRecord(mrFileWrite, moFileWrite)
    record.path = widePtrToString(lpFileName)
    record.result = int64(r)
    record.detail = "DeleteFileW"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopDeleteFileA(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpFileName = cast[LPCSTR](ctx.args[0])
    let r = BOOL(ctx.result)
    var record = baseRecord(mrFileWrite, moFileWrite)
    if lpFileName != nil:
      record.path = $lpFileName
    record.result = int64(r)
    record.detail = "DeleteFileA"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopCreateDirectoryW(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpPathName = cast[LPCWSTR](ctx.args[0])
    let r = BOOL(ctx.result)
    var record = baseRecord(mrFileWrite, moFileWrite)
    record.path = widePtrToString(lpPathName)
    record.result = int64(r)
    record.detail = "CreateDirectoryW"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopCreateDirectoryA(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpPathName = cast[LPCSTR](ctx.args[0])
    let r = BOOL(ctx.result)
    var record = baseRecord(mrFileWrite, moFileWrite)
    if lpPathName != nil:
      record.path = $lpPathName
    record.result = int64(r)
    record.detail = "CreateDirectoryA"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopCopyFileW(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpExisting = cast[LPCWSTR](ctx.args[0])
    let lpNew      = cast[LPCWSTR](ctx.args[1])
    let r = BOOL(ctx.result)
    var src = baseRecord(mrFileOpen, moFileRead)
    src.path = widePtrToString(lpExisting)
    src.result = int64(r)
    src.detail = "CopyFileW:src"
    emitRecord(src)
    var dst = baseRecord(mrFileWrite, moFileWrite)
    dst.path = widePtrToString(lpNew)
    dst.result = int64(r)
    dst.detail = "CopyFileW:dst"
    emitRecord(dst)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopCopyFileA(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpExisting = cast[LPCSTR](ctx.args[0])
    let lpNew      = cast[LPCSTR](ctx.args[1])
    let r = BOOL(ctx.result)
    var src = baseRecord(mrFileOpen, moFileRead)
    if lpExisting != nil:
      src.path = $lpExisting
    src.result = int64(r)
    src.detail = "CopyFileA:src"
    emitRecord(src)
    var dst = baseRecord(mrFileWrite, moFileWrite)
    if lpNew != nil:
      dst.path = $lpNew
    dst.result = int64(r)
    dst.detail = "CopyFileA:dst"
    emitRecord(dst)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopMoveFileExW(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpExisting = cast[LPCWSTR](ctx.args[0])
    let lpNew      = cast[LPCWSTR](ctx.args[1])
    let r = BOOL(ctx.result)
    var src = baseRecord(mrFileWrite, moFileWrite)
    src.path = widePtrToString(lpExisting)
    src.result = int64(r)
    src.detail = "MoveFileExW:src"
    emitRecord(src)
    # lpNewFileName MAY be nil when MOVEFILE_DELAY_UNTIL_REBOOT is set
    # WITHOUT a target (i.e. delete-on-reboot of the source). Emit a
    # destination record only when we actually have a target path.
    if lpNew != nil:
      var dst = baseRecord(mrFileWrite, moFileWrite)
      dst.path = widePtrToString(lpNew)
      dst.result = int64(r)
      dst.detail = "MoveFileExW:dst"
      emitRecord(dst)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopMoveFileExA(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpExisting = cast[LPCSTR](ctx.args[0])
    let lpNew      = cast[LPCSTR](ctx.args[1])
    let r = BOOL(ctx.result)
    var src = baseRecord(mrFileWrite, moFileWrite)
    if lpExisting != nil:
      src.path = $lpExisting
    src.result = int64(r)
    src.detail = "MoveFileExA:src"
    emitRecord(src)
    if lpNew != nil:
      var dst = baseRecord(mrFileWrite, moFileWrite)
      dst.path = $lpNew
      dst.result = int64(r)
      dst.detail = "MoveFileExA:dst"
      emitRecord(dst)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopGetFileInformationByHandleEx(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let hFile = cast[HANDLE](ctx.args[0])
    let r = BOOL(ctx.result)
    var record = baseRecord(mrPathProbe, moPathProbe)
    record.path = pathForHandle(hFile)
    record.result = int64(r)
    record.probeResult = probeFromBool(r)
    record.detail = "GetFileInformationByHandleEx"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopSetCurrentDirectoryW(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpPathName = cast[LPCWSTR](ctx.args[0])
    let r = BOOL(ctx.result)
    var record = baseRecord(mrFileOpen, moExecute)
    record.path = widePtrToString(lpPathName)
    record.result = int64(r)
    record.detail = "SetCurrentDirectoryW"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopSetCurrentDirectoryA(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpPathName = cast[LPCSTR](ctx.args[0])
    let r = BOOL(ctx.result)
    var record = baseRecord(mrFileOpen, moExecute)
    if lpPathName != nil:
      record.path = $lpPathName
    record.result = int64(r)
    record.detail = "SetCurrentDirectoryA"
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopNtCreateFile(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let oaPtr = cast[pointer](ctx.args[2])
    let path = objectAttributesToString(oaPtr)
    let desiredAccess = uint32(ctx.args[1] and 0xFFFFFFFF'u64)
    let createDisposition = uint32(ctx.args[7] and 0xFFFFFFFF'u64)
    # Data-access bits in ACCESS_MASK. None set ⇒ stat-class probe.
    const dataAccessBits =
      0x00000001'u32 or  # FILE_READ_DATA / FILE_LIST_DIRECTORY
      0x00000002'u32 or  # FILE_WRITE_DATA / FILE_ADD_FILE
      0x00000004'u32 or  # FILE_APPEND_DATA / FILE_ADD_SUBDIRECTORY
      0x80000000'u32 or  # GENERIC_READ
      0x40000000'u32 or  # GENERIC_WRITE
      0x10000000'u32     # GENERIC_ALL
    let isProbe = (desiredAccess and dataAccessBits) == 0'u32
    let writeAccess =
      (desiredAccess and (0x00000002'u32 or 0x00000004'u32 or
                          0x40000000'u32)) != 0'u32
    let writeDisposition = createDisposition == 2'u32 or
                           createDisposition == 3'u32 or
                           createDisposition == 5'u32
    let isWrite = writeAccess or writeDisposition
    let nt = cast[NTSTATUS](uint32(ctx.result and 0xFFFFFFFF'u64))
    if isProbe:
      var record = baseRecord(mrPathProbe, moPathProbe)
      record.path = path
      record.result = int64(nt)
      record.detail = "NtCreateFile"
      emitRecord(record)
    else:
      let recKind = if isWrite: mrFileWrite else: mrFileOpen
      let recMode = if isWrite: moFileWrite else: moFileOpen
      var record = baseRecord(recKind, recMode)
      record.path = path
      record.result = int64(nt)
      record.detail = "NtCreateFile"
      emitRecord(record)
      if path.len > 0 and nt >= 0:
        let phPtr = cast[ptr HANDLE](ctx.args[0])
        if phPtr != nil:
          let h = phPtr[]
          if h != nil and h != INVALID_HANDLE_VALUE:
            rememberHandlePath(h, path)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopNtQueryAttributesFileImpl(ctx: var hr.HookContext;
                                     detail: string) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let oaPtr = cast[pointer](ctx.args[0])
    let path = objectAttributesToString(oaPtr)
    let nt = cast[NTSTATUS](uint32(ctx.result and 0xFFFFFFFF'u64))
    var record = baseRecord(mrPathProbe, moPathProbe)
    record.path = path
    record.result = int64(nt)
    record.detail = detail
    emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopNtQueryAttributesFile(ctx: var hr.HookContext) {.raises: [].} =
  snoopNtQueryAttributesFileImpl(ctx, "NtQueryAttributesFile")

proc snoopNtQueryFullAttributesFile(ctx: var hr.HookContext) {.raises: [].} =
  snoopNtQueryAttributesFileImpl(ctx, "NtQueryFullAttributesFile")

proc snoopNtQueryInformationByName(ctx: var hr.HookContext) {.raises: [].} =
  ## libuv's uv_fs_stat fast-path on Win11. Emits an mrPathProbe.
  snoopNtQueryAttributesFileImpl(ctx, "NtQueryInformationByName")

proc emitFindFirstRecord(searchPath: string; resultHandle: HANDLE;
                         detail: string) {.raises: [].} =
  ## Emit mrDirectoryEnumerate for a FindFirstFile*W call. The search
  ## ``lpFileName`` is typically a directory followed by ``\*`` or
  ## ``\<pattern>``; strip the trailing pattern so the path identifies
  ## the directory itself. We don't track the returned HANDLE for
  ## subsequent FindNextFileW because each readdir() typically issues
  ## ONE FindFirstFileExW plus FindNextFileW calls until end-of-list,
  ## so one mrDirectoryEnumerate per FindFirstFileExW is the right
  ## granularity.
  if searchPath.len == 0:
    return
  var dirPath = searchPath
  # Strip trailing "\*" or "\\*" or "/*"/"\*.<ext>" — keep the directory.
  let lastSep = max(dirPath.rfind('\\'), dirPath.rfind('/'))
  if lastSep > 0:
    let tail = dirPath[lastSep + 1 .. ^1]
    if tail.startsWith("*") or tail == "*.*" or tail == "*":
      dirPath = dirPath[0 ..< lastSep]
  let success =
    resultHandle != INVALID_HANDLE_VALUE and resultHandle != nil
  var record = baseRecord(mrDirectoryEnumerate, moDirectoryEnumerate)
  record.path = dirPath
  record.result = if success: 1'i64 else: 0'i64
  record.detail = detail
  emitRecord(record)

proc snoopFindFirstFileW(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpFileName = cast[LPCWSTR](ctx.args[0])
    let searchPath = widePtrToString(lpFileName)
    let hFind = cast[HANDLE](ctx.result)
    emitFindFirstRecord(searchPath, hFind, "FindFirstFileW")
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopFindFirstFileExW(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let lpFileName = cast[LPCWSTR](ctx.args[0])
    let searchPath = widePtrToString(lpFileName)
    let hFind = cast[HANDLE](ctx.result)
    emitFindFirstRecord(searchPath, hFind, "FindFirstFileExW")
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopFindNextFileW(ctx: var hr.HookContext) {.raises: [].} =
  # FindNextFileW iterates the search handle — no per-call record is
  # emitted (the enclosing FindFirstFile already accounted for the
  # readdir). Forward through the chain unobserved.
  hr.callNext(ctx)

proc snoopFindClose(ctx: var hr.HookContext) {.raises: [].} =
  hr.callNext(ctx)

proc snoopNtQueryDirectoryFileEx(ctx: var hr.HookContext) {.raises: [].} =
  ## libuv's uv_fs_scandir on Win10 1709+. The handle was opened via
  ## NtCreateFile / CreateFileW with FILE_LIST_DIRECTORY; lookup its
  ## remembered path. Multiple chunked calls per readdir() — record
  ## only the first per handle.
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    # SL_RESTART_SCAN = 0x00000001. Anything else (SL_RETURN_ON_DISK_FULL,
    # SL_QUERY_DIRECTORY_MASK, SL_INDEX_SPECIFIED, ...) is irrelevant
    # for the first-call-per-handle gate.
    let queryFlags = DWORD(ctx.args[8])
    let restartScan = (queryFlags and 0x00000001'u32) != 0'u32
    let h = cast[HANDLE](ctx.args[0])
    var shouldRecord = restartScan
    var dirPath = ""
    acquire(fdLock)
    try:
      let key = handleKey(h)
      if handlePaths.hasKey(key):
        dirPath = handlePaths[key]
        if not dirPath.startsWith("[enum]:"):
          shouldRecord = true
          handlePaths[key] = "[enum]:" & dirPath
        elif restartScan:
          shouldRecord = true
          dirPath = dirPath["[enum]:".len .. ^1]
    finally:
      release(fdLock)
    let nt = cast[NTSTATUS](uint32(ctx.result and 0xFFFFFFFF'u64))
    if shouldRecord and dirPath.len > 0:
      var record = baseRecord(mrDirectoryEnumerate, moDirectoryEnumerate)
      record.path = dirPath
      record.result = int64(nt)
      record.detail = "NtQueryDirectoryFileEx"
      emitRecord(record)
  except CatchableError:
    discard
  SetLastError(savedLastError)

proc snoopNtQueryDirectoryFile(ctx: var hr.HookContext) {.raises: [].} =
  ## libuv's uv_fs_scandir → NtQueryDirectoryFile on a handle that was
  ## opened earlier via NtCreateFile / CreateFileW. Multiple calls per
  ## readdir() typically occur (chunked enumeration); we record only
  ## the first call per handle by mutating its entry in handlePaths.
  hr.callNext(ctx)
  let savedLastError = GetLastError()
  if disabled > 0 or not initialized:
    SetLastError(savedLastError)
    return
  try:
    let restartScan = BOOL(ctx.args[10])
    let h = cast[HANDLE](ctx.args[0])
    var shouldRecord = restartScan != 0
    var dirPath = ""
    acquire(fdLock)
    try:
      let key = handleKey(h)
      if handlePaths.hasKey(key):
        dirPath = handlePaths[key]
        if not dirPath.startsWith("[enum]:"):
          shouldRecord = true
          handlePaths[key] = "[enum]:" & dirPath
        elif restartScan != 0:
          shouldRecord = true
          dirPath = dirPath["[enum]:".len .. ^1]
    finally:
      release(fdLock)
    let nt = cast[NTSTATUS](uint32(ctx.result and 0xFFFFFFFF'u64))
    if shouldRecord and dirPath.len > 0:
      var record = baseRecord(mrDirectoryEnumerate, moDirectoryEnumerate)
      record.path = dirPath
      record.result = int64(nt)
      record.detail = "NtQueryDirectoryFile"
      emitRecord(record)
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

# --- M73 Phase 5 trampolines (matched stdcall signatures) ------------------

proc trampolineDeleteFileW(lpFileName: LPCWSTR): BOOL {.stdcall.} =
  if origDeleteFileW == nil:
    return 0
  var ctx = hr.HookContext(args: @[cast[uint64](lpFileName)])
  hr.dispatchShimHook(hr.HookDeleteFileW, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineDeleteFileA(lpFileName: LPCSTR): BOOL {.stdcall.} =
  if origDeleteFileA == nil:
    return 0
  var ctx = hr.HookContext(args: @[cast[uint64](lpFileName)])
  hr.dispatchShimHook(hr.HookDeleteFileA, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineCreateDirectoryW(lpPathName: LPCWSTR,
                                 lpSecurityAttributes: LPSECURITY_ATTRIBUTES):
                                 BOOL {.stdcall.} =
  if origCreateDirectoryW == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpPathName),
    cast[uint64](lpSecurityAttributes)
  ])
  hr.dispatchShimHook(hr.HookCreateDirectoryW, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineCreateDirectoryA(lpPathName: LPCSTR,
                                 lpSecurityAttributes: LPSECURITY_ATTRIBUTES):
                                 BOOL {.stdcall.} =
  if origCreateDirectoryA == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpPathName),
    cast[uint64](lpSecurityAttributes)
  ])
  hr.dispatchShimHook(hr.HookCreateDirectoryA, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineCopyFileW(lpExistingFileName: LPCWSTR,
                          lpNewFileName: LPCWSTR,
                          bFailIfExists: BOOL): BOOL {.stdcall.} =
  if origCopyFileW == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpExistingFileName),
    cast[uint64](lpNewFileName),
    uint64(uint32(bFailIfExists))
  ])
  hr.dispatchShimHook(hr.HookCopyFileW, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineCopyFileA(lpExistingFileName: LPCSTR,
                          lpNewFileName: LPCSTR,
                          bFailIfExists: BOOL): BOOL {.stdcall.} =
  if origCopyFileA == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpExistingFileName),
    cast[uint64](lpNewFileName),
    uint64(uint32(bFailIfExists))
  ])
  hr.dispatchShimHook(hr.HookCopyFileA, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineMoveFileExW(lpExistingFileName: LPCWSTR,
                            lpNewFileName: LPCWSTR,
                            dwFlags: DWORD): BOOL {.stdcall.} =
  if origMoveFileExW == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpExistingFileName),
    cast[uint64](lpNewFileName),
    uint64(dwFlags)
  ])
  hr.dispatchShimHook(hr.HookMoveFileExW, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineMoveFileExA(lpExistingFileName: LPCSTR,
                            lpNewFileName: LPCSTR,
                            dwFlags: DWORD): BOOL {.stdcall.} =
  if origMoveFileExA == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpExistingFileName),
    cast[uint64](lpNewFileName),
    uint64(dwFlags)
  ])
  hr.dispatchShimHook(hr.HookMoveFileExA, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineGetFileInformationByHandleEx(hFile: HANDLE,
                                              FileInformationClass: DWORD,
                                              lpFileInformation: LPVOID,
                                              dwBufferSize: DWORD): BOOL
                                              {.stdcall.} =
  if origGetFileInformationByHandleEx == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](hFile),
    uint64(FileInformationClass),
    cast[uint64](lpFileInformation),
    uint64(dwBufferSize)
  ])
  hr.dispatchShimHook(hr.HookGetFileInformationByHandleEx, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineSetCurrentDirectoryW(lpPathName: LPCWSTR): BOOL {.stdcall.} =
  if origSetCurrentDirectoryW == nil:
    return 0
  var ctx = hr.HookContext(args: @[cast[uint64](lpPathName)])
  hr.dispatchShimHook(hr.HookSetCurrentDirectoryW, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineSetCurrentDirectoryA(lpPathName: LPCSTR): BOOL {.stdcall.} =
  if origSetCurrentDirectoryA == nil:
    return 0
  var ctx = hr.HookContext(args: @[cast[uint64](lpPathName)])
  hr.dispatchShimHook(hr.HookSetCurrentDirectoryA, ctx)
  result = BOOL(uint32(ctx.result))

proc trampolineNtCreateFile(FileHandle: ptr HANDLE,
                             DesiredAccess: DWORD,
                             ObjectAttributes: pointer,
                             IoStatusBlock: pointer,
                             AllocationSize: ptr LARGE_INTEGER,
                             FileAttributes: DWORD,
                             ShareAccess: DWORD,
                             CreateDisposition: DWORD,
                             CreateOptions: DWORD,
                             EaBuffer: pointer,
                             EaLength: DWORD): NTSTATUS {.stdcall.} =
  if origNtCreateFile == nil:
    return NTSTATUS(0xC0000001'i32)  # STATUS_UNSUCCESSFUL
  var ctx = hr.HookContext(args: @[
    cast[uint64](FileHandle),
    uint64(DesiredAccess),
    cast[uint64](ObjectAttributes),
    cast[uint64](IoStatusBlock),
    cast[uint64](AllocationSize),
    uint64(FileAttributes),
    uint64(ShareAccess),
    uint64(CreateDisposition),
    uint64(CreateOptions),
    cast[uint64](EaBuffer),
    uint64(EaLength)
  ])
  hr.dispatchShimHook(hr.HookNtCreateFile, ctx)
  # NTSTATUS reinterpret: ctx.result holds the uint32-packed status.
  # Same-size cast avoids `chckRange64` (per the
  # nim_cast_narrowing_rangecheck memo).
  result = cast[NTSTATUS](uint32(ctx.result and 0xFFFFFFFF'u64))

proc trampolineNtQueryAttributesFile(ObjectAttributes: pointer;
                                      FileInformation: pointer):
                                      NTSTATUS {.stdcall.} =
  if origNtQueryAttributesFile == nil:
    return NTSTATUS(0xC0000001'i32)
  var ctx = hr.HookContext(args: @[
    cast[uint64](ObjectAttributes),
    cast[uint64](FileInformation)
  ])
  hr.dispatchShimHook(hr.HookNtQueryAttributesFile, ctx)
  result = cast[NTSTATUS](uint32(ctx.result and 0xFFFFFFFF'u64))

proc trampolineNtQueryFullAttributesFile(ObjectAttributes: pointer;
                                          FileInformation: pointer):
                                          NTSTATUS {.stdcall.} =
  if origNtQueryFullAttributesFile == nil:
    return NTSTATUS(0xC0000001'i32)
  var ctx = hr.HookContext(args: @[
    cast[uint64](ObjectAttributes),
    cast[uint64](FileInformation)
  ])
  hr.dispatchShimHook(hr.HookNtQueryFullAttributesFile, ctx)
  result = cast[NTSTATUS](uint32(ctx.result and 0xFFFFFFFF'u64))

proc trampolineNtQueryDirectoryFileEx(FileHandle: HANDLE;
                                       Event: HANDLE;
                                       ApcRoutine: pointer;
                                       ApcContext: pointer;
                                       IoStatusBlock: pointer;
                                       FileInformation: pointer;
                                       Length: DWORD;
                                       FileInformationClass: DWORD;
                                       QueryFlags: DWORD;
                                       FileName: pointer):
                                       NTSTATUS {.stdcall.} =
  if origNtQueryDirectoryFileEx == nil:
    return NTSTATUS(0xC0000001'i32)
  var ctx = hr.HookContext(args: @[
    cast[uint64](FileHandle),
    cast[uint64](Event),
    cast[uint64](ApcRoutine),
    cast[uint64](ApcContext),
    cast[uint64](IoStatusBlock),
    cast[uint64](FileInformation),
    uint64(Length),
    uint64(FileInformationClass),
    uint64(QueryFlags),
    cast[uint64](FileName)
  ])
  hr.dispatchShimHook(hr.HookNtQueryDirectoryFileEx, ctx)
  result = cast[NTSTATUS](uint32(ctx.result and 0xFFFFFFFF'u64))

proc trampolineNtQueryInformationByName(ObjectAttributes: pointer;
                                         IoStatusBlock: pointer;
                                         FileInformation: pointer;
                                         Length: DWORD;
                                         FileInformationClass: DWORD):
                                         NTSTATUS {.stdcall.} =
  if origNtQueryInformationByName == nil:
    return NTSTATUS(0xC0000001'i32)
  var ctx = hr.HookContext(args: @[
    cast[uint64](ObjectAttributes),
    cast[uint64](IoStatusBlock),
    cast[uint64](FileInformation),
    uint64(Length),
    uint64(FileInformationClass)
  ])
  hr.dispatchShimHook(hr.HookNtQueryInformationByName, ctx)
  result = cast[NTSTATUS](uint32(ctx.result and 0xFFFFFFFF'u64))

proc trampolineFindFirstFileW(lpFileName: LPCWSTR;
                               lpFindFileData: pointer):
                               HANDLE {.stdcall.} =
  if origFindFirstFileW == nil:
    return INVALID_HANDLE_VALUE
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpFileName),
    cast[uint64](lpFindFileData)
  ])
  hr.dispatchShimHook(hr.HookFindFirstFileW, ctx)
  result = cast[HANDLE](ctx.result)

proc trampolineFindFirstFileExW(lpFileName: LPCWSTR;
                                 fInfoLevelId: DWORD;
                                 lpFindFileData: pointer;
                                 fSearchOp: DWORD;
                                 lpSearchFilter: pointer;
                                 dwAdditionalFlags: DWORD):
                                 HANDLE {.stdcall.} =
  if origFindFirstFileExW == nil:
    return INVALID_HANDLE_VALUE
  var ctx = hr.HookContext(args: @[
    cast[uint64](lpFileName),
    uint64(fInfoLevelId),
    cast[uint64](lpFindFileData),
    uint64(fSearchOp),
    cast[uint64](lpSearchFilter),
    uint64(dwAdditionalFlags)
  ])
  hr.dispatchShimHook(hr.HookFindFirstFileExW, ctx)
  result = cast[HANDLE](ctx.result)

proc trampolineFindNextFileW(hFindFile: HANDLE;
                              lpFindFileData: pointer):
                              BOOL {.stdcall.} =
  if origFindNextFileW == nil:
    return 0
  var ctx = hr.HookContext(args: @[
    cast[uint64](hFindFile),
    cast[uint64](lpFindFileData)
  ])
  hr.dispatchShimHook(hr.HookFindNextFileW, ctx)
  result = BOOL(ctx.result)

proc trampolineFindClose(hFindFile: HANDLE): BOOL {.stdcall.} =
  if origFindClose == nil:
    return 0
  var ctx = hr.HookContext(args: @[cast[uint64](hFindFile)])
  hr.dispatchShimHook(hr.HookFindClose, ctx)
  result = BOOL(ctx.result)

proc trampolineNtQueryDirectoryFile(FileHandle: HANDLE;
                                     Event: HANDLE;
                                     ApcRoutine: pointer;
                                     ApcContext: pointer;
                                     IoStatusBlock: pointer;
                                     FileInformation: pointer;
                                     Length: DWORD;
                                     FileInformationClass: DWORD;
                                     ReturnSingleEntry: BOOL;
                                     FileName: pointer;
                                     RestartScan: BOOL):
                                     NTSTATUS {.stdcall.} =
  if origNtQueryDirectoryFile == nil:
    return NTSTATUS(0xC0000001'i32)
  var ctx = hr.HookContext(args: @[
    cast[uint64](FileHandle),
    cast[uint64](Event),
    cast[uint64](ApcRoutine),
    cast[uint64](ApcContext),
    cast[uint64](IoStatusBlock),
    cast[uint64](FileInformation),
    uint64(Length),
    uint64(FileInformationClass),
    uint64(ReturnSingleEntry),
    cast[uint64](FileName),
    uint64(RestartScan)
  ])
  hr.dispatchShimHook(hr.HookNtQueryDirectoryFile, ctx)
  result = cast[NTSTATUS](uint32(ctx.result and 0xFFFFFFFF'u64))

# --- Registry wiring -------------------------------------------------------
#
# Called once from repro_monitor_shim_init AFTER the registry has been
# allocated but BEFORE inline/IAT installation kicks in. Registers each
# snoop callback at ShimSnoopPriority. The chain's ``original`` callback
# is set by ``installInlineFor`` / ``installIatFor`` below, once we know
# the captured origXxx pointer (or trampoline returned by ct_inline_hook)
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
  # M73 Phase 5 — extended hook surface.
  hr.registerMonitorHook(hr.HookDeleteFileW,        snoopDeleteFileW)
  hr.registerMonitorHook(hr.HookDeleteFileA,        snoopDeleteFileA)
  hr.registerMonitorHook(hr.HookCreateDirectoryW,   snoopCreateDirectoryW)
  hr.registerMonitorHook(hr.HookCreateDirectoryA,   snoopCreateDirectoryA)
  hr.registerMonitorHook(hr.HookCopyFileW,          snoopCopyFileW)
  hr.registerMonitorHook(hr.HookCopyFileA,          snoopCopyFileA)
  hr.registerMonitorHook(hr.HookMoveFileExW,        snoopMoveFileExW)
  hr.registerMonitorHook(hr.HookMoveFileExA,        snoopMoveFileExA)
  hr.registerMonitorHook(hr.HookGetFileInformationByHandleEx,
                         snoopGetFileInformationByHandleEx)
  hr.registerMonitorHook(hr.HookSetCurrentDirectoryW,
                         snoopSetCurrentDirectoryW)
  hr.registerMonitorHook(hr.HookSetCurrentDirectoryA,
                         snoopSetCurrentDirectoryA)
  hr.registerMonitorHook(hr.HookNtCreateFile,       snoopNtCreateFile)
  hr.registerMonitorHook(hr.HookNtQueryAttributesFile,
                         snoopNtQueryAttributesFile)
  hr.registerMonitorHook(hr.HookNtQueryFullAttributesFile,
                         snoopNtQueryFullAttributesFile)
  # Temporarily disabled — the inline detour on NtQueryDirectoryFile /
  # NtQueryDirectoryFileEx is destabilising libuv's readdir path. The
  # crash is reproducible with the readdir-bundle fixture; the cause
  # is most likely a thread-safety issue in handlePaths access during
  # the chunked enumeration. The hooks remain compiled in (HookSpec
  # entries still install the inline detour) but the snoop callback
  # is not registered, so the chain calls the original directly. Fix
  # tracked separately; stat-class hooks are unaffected.
  # hr.registerMonitorHook(hr.HookNtQueryDirectoryFile,
  #                        snoopNtQueryDirectoryFile)
  hr.registerMonitorHook(hr.HookNtQueryInformationByName,
                         snoopNtQueryInformationByName)
  # kernel32 directory-enumerate hooks (libuv 1.52 fs.readdirSync).
  hr.registerMonitorHook(hr.HookFindFirstFileW, snoopFindFirstFileW)
  hr.registerMonitorHook(hr.HookFindFirstFileExW, snoopFindFirstFileExW)
  hr.registerMonitorHook(hr.HookFindNextFileW, snoopFindNextFileW)
  hr.registerMonitorHook(hr.HookFindClose, snoopFindClose)
  # hr.registerMonitorHook(hr.HookNtQueryDirectoryFileEx,
  #                        snoopNtQueryDirectoryFileEx)

# --- Unified install backend (M73 Phase 1) ---------------------------------
#
# Per Monitor-Hook-Shim.md §"Install Backend Requirement:
# dispatch-mechanism-agnostic", the shim's install backend MUST catch every
# call to a hooked Win32 API regardless of how the caller resolved the entry
# point (IAT-routed, runtime-resolved via GetProcAddress, late-bound from a
# DLL loaded after init, CRT-forwarded). The only point where every
# dispatch mechanism converges is the kernel32 function body itself, so the
# primary install for every hooked API is a 5-byte JMP rel32 inline detour
# at the function body via ct_inline_hook. IAT patching is retained ONLY as
# the fallback path for APIs whose prologue the ct_inline_hook length
# decoder cannot safely relocate (see ct_inline_hook/install_windows.h
# error code -2). A hook landing on the IAT fallback is by spec an
# acceptance issue, not a permanent design choice — Phase 4 will install an
# audit accessor that hard-fails on non-zero fallback counts.
#
# Expected install mechanism on supported Windows versions (Win10 1809+,
# Win11): every hook lands on the INLINE path. The IAT fallback path is
# reserved for the rare prologue layout the length decoder rejects; in
# practice none of the eleven kernel32 APIs in this table have shipped
# with such a prologue. The dispatch-mechanism coverage test (Phase 2)
# proves all five caller dispatch mechanisms converge on the inline
# trampoline; the install audit (Phase 4) verifies the first five bytes
# of each kernel32 target are an E9-class detour after init.

type
  HookSpec = object
    name: string                # e.g. "CreateFileW"
    trampoline: pointer         # cast[pointer](trampolineCreateFileW)
    origStorage: ptr pointer    # cast[ptr pointer](addr origCreateFileW)
    origCallback: hr.HookCallback
    iatDlls: seq[string]        # Fallback search list when inline rejects.
    moduleDll: string           # M73 Phase 5: target module the inline +
                                # audit paths resolve the function from
                                # (default "kernel32.dll"). NtCreateFile
                                # sets this to "ntdll.dll".

const kernel32FileIatDlls = @[
  "kernel32.dll", "kernelbase.dll",
  "api-ms-win-core-file-l1-1-0.dll",
  "api-ms-win-core-file-l1-2-0.dll",
  "api-ms-win-core-file-l2-1-0.dll",
  "api-ms-win-core-handle-l1-1-0.dll",
  "api-ms-win-core-processthreads-l1-1-0.dll",
  "api-ms-win-core-processthreads-l1-1-1.dll"
]

# NtCreateFile lives in ntdll. Only ntdll.dll itself exports it; the
# api-ms-win-* shims forward to it but no module advertises it under a
# different ExportName, so the IAT-fallback list can stay minimal here.
const ntdllNtIatDlls = @["ntdll.dll"]

# Module-global hook table. Built once with the trampoline + origStorage
# pointers — these are addresses of module-level statics so they're known
# at module-init time; a `let` binding is sufficient.
let hookTable {.global.}: seq[HookSpec] = @[
  HookSpec(name: hr.HookCreateFileW,
    trampoline: cast[pointer](trampolineCreateFileW),
    origStorage: cast[ptr pointer](addr origCreateFileW),
    origCallback: originalCreateFileW,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookCreateFileA,
    trampoline: cast[pointer](trampolineCreateFileA),
    origStorage: cast[ptr pointer](addr origCreateFileA),
    origCallback: originalCreateFileA,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookReadFile,
    trampoline: cast[pointer](trampolineReadFile),
    origStorage: cast[ptr pointer](addr origReadFile),
    origCallback: originalReadFile,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookWriteFile,
    trampoline: cast[pointer](trampolineWriteFile),
    origStorage: cast[ptr pointer](addr origWriteFile),
    origCallback: originalWriteFile,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookCloseHandle,
    trampoline: cast[pointer](trampolineCloseHandle),
    origStorage: cast[ptr pointer](addr origCloseHandle),
    origCallback: originalCloseHandle,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookGetFileAttributesExW,
    trampoline: cast[pointer](trampolineGetFileAttributesExW),
    origStorage: cast[ptr pointer](addr origGetFileAttributesExW),
    origCallback: originalGetFileAttributesExW,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookGetFileAttributesExA,
    trampoline: cast[pointer](trampolineGetFileAttributesExA),
    origStorage: cast[ptr pointer](addr origGetFileAttributesExA),
    origCallback: originalGetFileAttributesExA,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookGetFileAttributesW,
    trampoline: cast[pointer](trampolineGetFileAttributesW),
    origStorage: cast[ptr pointer](addr origGetFileAttributesW),
    origCallback: originalGetFileAttributesW,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookGetFileAttributesA,
    trampoline: cast[pointer](trampolineGetFileAttributesA),
    origStorage: cast[ptr pointer](addr origGetFileAttributesA),
    origCallback: originalGetFileAttributesA,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookCreateProcessW,
    trampoline: cast[pointer](trampolineCreateProcessW),
    origStorage: cast[ptr pointer](addr origCreateProcessW),
    origCallback: originalCreateProcessW,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookCreateProcessA,
    trampoline: cast[pointer](trampolineCreateProcessA),
    origStorage: cast[ptr pointer](addr origCreateProcessA),
    origCallback: originalCreateProcessA,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  # M73 Phase 5 — extended Win32 entry points (kernel32.dll).
  HookSpec(name: hr.HookDeleteFileW,
    trampoline: cast[pointer](trampolineDeleteFileW),
    origStorage: cast[ptr pointer](addr origDeleteFileW),
    origCallback: originalDeleteFileW,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookDeleteFileA,
    trampoline: cast[pointer](trampolineDeleteFileA),
    origStorage: cast[ptr pointer](addr origDeleteFileA),
    origCallback: originalDeleteFileA,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookCreateDirectoryW,
    trampoline: cast[pointer](trampolineCreateDirectoryW),
    origStorage: cast[ptr pointer](addr origCreateDirectoryW),
    origCallback: originalCreateDirectoryW,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookCreateDirectoryA,
    trampoline: cast[pointer](trampolineCreateDirectoryA),
    origStorage: cast[ptr pointer](addr origCreateDirectoryA),
    origCallback: originalCreateDirectoryA,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookCopyFileW,
    trampoline: cast[pointer](trampolineCopyFileW),
    origStorage: cast[ptr pointer](addr origCopyFileW),
    origCallback: originalCopyFileW,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookCopyFileA,
    trampoline: cast[pointer](trampolineCopyFileA),
    origStorage: cast[ptr pointer](addr origCopyFileA),
    origCallback: originalCopyFileA,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookMoveFileExW,
    trampoline: cast[pointer](trampolineMoveFileExW),
    origStorage: cast[ptr pointer](addr origMoveFileExW),
    origCallback: originalMoveFileExW,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookMoveFileExA,
    trampoline: cast[pointer](trampolineMoveFileExA),
    origStorage: cast[ptr pointer](addr origMoveFileExA),
    origCallback: originalMoveFileExA,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookGetFileInformationByHandleEx,
    trampoline: cast[pointer](trampolineGetFileInformationByHandleEx),
    origStorage: cast[ptr pointer](addr origGetFileInformationByHandleEx),
    origCallback: originalGetFileInformationByHandleEx,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookSetCurrentDirectoryW,
    trampoline: cast[pointer](trampolineSetCurrentDirectoryW),
    origStorage: cast[ptr pointer](addr origSetCurrentDirectoryW),
    origCallback: originalSetCurrentDirectoryW,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookSetCurrentDirectoryA,
    trampoline: cast[pointer](trampolineSetCurrentDirectoryA),
    origStorage: cast[ptr pointer](addr origSetCurrentDirectoryA),
    origCallback: originalSetCurrentDirectoryA,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  # NT Native API backstop — lives in ntdll, not kernel32.
  HookSpec(name: hr.HookNtCreateFile,
    trampoline: cast[pointer](trampolineNtCreateFile),
    origStorage: cast[ptr pointer](addr origNtCreateFile),
    origCallback: originalNtCreateFile,
    iatDlls: ntdllNtIatDlls,
    moduleDll: "ntdll.dll"),
  # NT stat-class hooks (libuv fast-path for fs.statSync).
  HookSpec(name: hr.HookNtQueryAttributesFile,
    trampoline: cast[pointer](trampolineNtQueryAttributesFile),
    origStorage: cast[ptr pointer](addr origNtQueryAttributesFile),
    origCallback: originalNtQueryAttributesFile,
    iatDlls: ntdllNtIatDlls,
    moduleDll: "ntdll.dll"),
  HookSpec(name: hr.HookNtQueryFullAttributesFile,
    trampoline: cast[pointer](trampolineNtQueryFullAttributesFile),
    origStorage: cast[ptr pointer](addr origNtQueryFullAttributesFile),
    origCallback: originalNtQueryFullAttributesFile,
    iatDlls: ntdllNtIatDlls,
    moduleDll: "ntdll.dll"),
  # NT path-information hook (libuv 1.52 fast-path on Win11 for stat).
  HookSpec(name: hr.HookNtQueryInformationByName,
    trampoline: cast[pointer](trampolineNtQueryInformationByName),
    origStorage: cast[ptr pointer](addr origNtQueryInformationByName),
    origCallback: originalNtQueryInformationByName,
    iatDlls: ntdllNtIatDlls,
    moduleDll: "ntdll.dll"),
  # kernel32 directory-enumerate hooks (libuv 1.52 fs.readdirSync uses
  # FindFirstFileExW + FindNextFileW + FindClose, not the NT
  # NtQueryDirectoryFile export; the NT-layer detour crashed Node so
  # we hook the kernel32 entry points instead).
  HookSpec(name: hr.HookFindFirstFileW,
    trampoline: cast[pointer](trampolineFindFirstFileW),
    origStorage: cast[ptr pointer](addr origFindFirstFileW),
    origCallback: originalFindFirstFileW,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookFindFirstFileExW,
    trampoline: cast[pointer](trampolineFindFirstFileExW),
    origStorage: cast[ptr pointer](addr origFindFirstFileExW),
    origCallback: originalFindFirstFileExW,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookFindNextFileW,
    trampoline: cast[pointer](trampolineFindNextFileW),
    origStorage: cast[ptr pointer](addr origFindNextFileW),
    origCallback: originalFindNextFileW,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll"),
  HookSpec(name: hr.HookFindClose,
    trampoline: cast[pointer](trampolineFindClose),
    origStorage: cast[ptr pointer](addr origFindClose),
    origCallback: originalFindClose,
    iatDlls: kernel32FileIatDlls,
    moduleDll: "kernel32.dll")
]

proc queueInlineInstall(spec: HookSpec; hModule: HANDLE): cint =
  ## Queue an inline JMP rel32 install for ``spec.name`` against
  ## ``hModule``'s function body (kernel32 for the M73 Phase 1-4 surface;
  ## ntdll for the M73 Phase 5 NtCreateFile backstop). Under an active
  ## transaction, the call returns 0 as soon as the op is queued; the
  ## trampoline pointer is written into ``spec.origStorage[]`` at commit
  ## time.
  ##
  ## Importantly, the ``out_trampoline`` argument we pass is
  ## ``spec.origStorage`` itself (the module-global ``addr origXxx``).
  ## Under a transaction the install primitive holds onto that pointer
  ## and writes through it at commit; a stack-local pointer would
  ## dangle by then. Wiring the chain's "original" callback MUST
  ## therefore be deferred until after ``ctInlineHookCommitTransaction``
  ## returns — otherwise, with the inline JMP already landed at the
  ## function body but ``origXxx`` still holding the (now-patched) real
  ## entry, the chain's "original" recurses through the trampoline.
  when not ctInlineHookAvailable:
    return -4
  else:
    if spec.origStorage[] != nil:
      # Already installed (idempotent call). Treat as success.
      return 0
    let target = GetProcAddress(hModule, cast[LPCSTR](spec.name.cstring))
    if target == nil:
      return -1
    ctInlineHookInstall(target, spec.trampoline, spec.origStorage)

proc installIatFor(spec: HookSpec) =
  ## Fallback IAT install for an entry point that the inline path rejected.
  ## Walks every fallback DLL the spec declares and patches the first IAT
  ## slot that yields a non-nil original pointer; subsequent DLLs only
  ## redirect (the chain already has the original wired).
  for dll in spec.iatDlls:
    if spec.origStorage[] == nil:
      let orig = patchIATAllModules(dll.cstring, spec.name.cstring,
                                    spec.trampoline)
      if orig != nil:
        spec.origStorage[] = orig
        hr.setOriginalCallback(spec.name, spec.origCallback)
        dbg(cstring("[repro_monitor_shim] hooked " & spec.name &
          " from " & dll & " (IAT fallback)\n"))
    else:
      # We already captured the real function pointer; only redirect the IAT.
      discard patchIATAllModules(dll.cstring, spec.name.cstring,
                                 spec.trampoline)

proc installAllHooks(): int =
  ## Install every entry in ``hookTable``. Inline is preferred for every
  ## hook (dispatch-mechanism-agnostic, per Monitor-Hook-Shim.md spec);
  ## the IAT path is only walked for hooks the inline backend rejected.
  ## All inline installs are grouped inside a single transaction so the
  ## thread-suspend window happens once for the whole table rather than
  ## once per hook (see ct_inline_hook/install_windows.h "Transactions").
  ## Returns the count of hooks that fell through to the IAT fallback —
  ## tests treat any non-zero count as an acceptance issue.
  result = 0
  var failed: seq[HookSpec] = @[]
  # Per-spec record of "did the queued-install call succeed?" — only
  # specs that queued successfully will have their trampoline filled at
  # commit time, so only those should have ``setOriginalCallback`` wired
  # post-commit. The same vector also tells us which specs need the IAT
  # fallback (the ones where queueing was rejected OR commit failed).
  var inlineQueued = newSeq[bool](hookTable.len)
  var commitOk = false
  when ctInlineHookAvailable:
    # Per-spec hModule resolution. Cache module handles by name so we
    # don't burn a GetModuleHandleA per entry on the kernel32 surface.
    var moduleHandles = initTable[string, HANDLE]()
    proc resolveModule(name: string): HANDLE {.raises: [].} =
      try:
        if name in moduleHandles:
          return moduleHandles[name]
        let h = GetModuleHandleA(cast[LPCSTR](name.cstring))
        moduleHandles[name] = h
        return h
      except KeyError:
        # Defensive: `name in moduleHandles` already guarded the lookup;
        # the catch is here to satisfy `{.raises: [].}` on the outer
        # installAllHooks contract.
        return GetModuleHandleA(cast[LPCSTR](name.cstring))

    let beginRc = ctInlineHookBeginTransaction()
    let inTransaction = (beginRc == 0)
    if not inTransaction:
      dbg(cstring("[repro_monitor_shim] installAllHooks: begin_transaction failed rc=" & $beginRc & "; installing per-hook\n"))
    for i, spec in hookTable:
      let modName =
        if spec.moduleDll.len > 0: spec.moduleDll else: "kernel32.dll"
      let hModule = resolveModule(modName)
      if hModule == nil:
        dbg(cstring("[repro_monitor_shim] installAllHooks: " &
          "GetModuleHandleA(" & modName & ") returned NULL; falling back to IAT for " &
          spec.name & "\n"))
        failed.add(spec)
        continue
      let rc = queueInlineInstall(spec, hModule)
      if rc == 0:
        inlineQueued[i] = true
      else:
        dbg(cstring("[repro_monitor_shim] inline-hook FAILED for " &
          spec.name & " (rc=" & $rc & "); will try IAT fallback\n"))
        failed.add(spec)
    if inTransaction:
      let commitRc = ctInlineHookCommitTransaction()
      if commitRc == 0:
        commitOk = true
      else:
        dbg(cstring("[repro_monitor_shim] installAllHooks: commit_transaction failed rc=" & $commitRc & "\n"))
        # Commit failed -> ct_inline_hook rolls back the
        # partially-applied batch and origStorage[] stays nil for
        # every queued spec. Re-route them all to the IAT fallback.
        for i, spec in hookTable:
          if inlineQueued[i]:
            inlineQueued[i] = false
            failed.add(spec)
    else:
      # No transaction was active; each ctInlineHookInstall call ran
      # synchronously and wrote spec.origStorage[] in-line. The
      # successful ones are already committed.
      commitOk = true
  else:
    # ct_inline_hook sources unavailable — every hook degrades to IAT.
    for spec in hookTable:
      failed.add(spec)

  # Post-commit pass 1: wire the chain's "original" callback for every
  # spec whose inline install actually landed (trampoline pointer is now
  # non-nil in spec.origStorage[]). Pass 1 runs to completion BEFORE any
  # dbg log line — dbg itself dispatches through CreateFileA (and the
  # CRT path under it touches GetFileAttributesW), and emitting a log
  # line while any chain.original is still nil would short-circuit the
  # log file's own CreateFileA / GetFileAttributesW calls to a fake "fail"
  # path. Pass 2 below is the actual log emission, after every chain is
  # fully wired.
  var commitEmpty = newSeq[bool](hookTable.len)
  when ctInlineHookAvailable:
    if commitOk:
      for i, spec in hookTable:
        if inlineQueued[i]:
          if spec.origStorage[] != nil:
            hr.setOriginalCallback(spec.name, spec.origCallback)
          else:
            commitEmpty[i] = true
            failed.add(spec)

  # Post-commit pass 2: emit diagnostic lines. By this point every spec
  # in hookTable either has a wired chain (origStorage[] non-nil +
  # chain.original set) or is on the failed list awaiting IAT fallback.
  when ctInlineHookAvailable:
    if commitOk:
      for i, spec in hookTable:
        if inlineQueued[i] and not commitEmpty[i]:
          dbg(cstring("[repro_monitor_shim] inline-hooked " & spec.name & "\n"))
        elif commitEmpty[i]:
          dbg(cstring("[repro_monitor_shim] inline-hook commit-empty for " &
            spec.name & "; will try IAT fallback\n"))

  for spec in failed:
    installIatFor(spec)
    if spec.origStorage[] == nil:
      dbg(cstring("[repro_monitor_shim] install FAILED for " & spec.name &
        " (neither inline nor IAT landed a hook)\n"))
  result = failed.len

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
  # callbacks BEFORE installing the inline/IAT patches. installAllHooks
  # wires the captured origXxx into the chain's ``original`` slot once
  # the inline-hook trampoline (or IAT-captured real pointer) is in
  # hand; the snoop callbacks are already in place so the very first
  # hooked call sees a fully-built chain.
  hr.initShimRegistry()
  registerMonitorSnoopCallbacks()
  initialized = true
  release(initLockVar)
  recordProcessStart()
  # M73 Phase 1: single dispatch-mechanism-agnostic install pass.
  # Prefers ct_inline_hook (5-byte JMP rel32 at the kernel32 function
  # body — catches every dispatch mechanism), falls back to IAT
  # patching only for entry points the inline backend rejects. The
  # returned count is logged so any fall-through is visible in the
  # debug output and a future control-ABI accessor (Phase 4) can
  # surface it programmatically.
  let iatFallbackCount = installAllHooks()
  dbg(cstring("[repro_monitor_shim] installAllHooks: " &
    $iatFallbackCount & " hook(s) fell through to IAT fallback\n"))
  # M73 Phase 4: post-install audit. Walk the hookTable, resolve each
  # spec's kernel32 address, and classify the first five bytes at the
  # target. The audit MUST run synchronously here — Monitor-Hook-Shim.md
  # §"Install Backend Requirement" requires the post-install state be
  # captured before any other code can uninstall hooks. Cost is ~11 *
  # (GetProcAddress + 5-byte read) = microseconds, well within the
  # loader's critical-path budget.
  block:
    # M73 Phase 5: every spec carries its own ``moduleDll`` so the audit
    # can resolve kernel32 + ntdll entries through one walk. Cache the
    # module handles to keep the GetModuleHandleA calls minimal.
    var auditModules = initTable[string, HANDLE]()
    var targets: seq[(string, pointer)] = @[]
    for spec in hookTable:
      let modName =
        if spec.moduleDll.len > 0: spec.moduleDll else: "kernel32.dll"
      var hMod: HANDLE = nil
      try:
        if modName in auditModules:
          hMod = auditModules[modName]
        else:
          hMod = GetModuleHandleA(cast[LPCSTR](modName.cstring))
          auditModules[modName] = hMod
      except KeyError:
        hMod = GetModuleHandleA(cast[LPCSTR](modName.cstring))
      if hMod == nil:
        dbg(cstring("[repro_monitor_shim] install-audit SKIPPED for " &
          spec.name & ": GetModuleHandleA(" & modName & ") returned NULL\n"))
        # Pass nil so the audit module reports the failure consistently
        # with its existing "addr == nil -> failing name" branch.
        targets.add((spec.name, pointer(nil)))
        continue
      let addr0 = GetProcAddress(hMod, cast[LPCSTR](spec.name.cstring))
      targets.add((spec.name, addr0))
    runInstallAudit(targets, dbg)
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
