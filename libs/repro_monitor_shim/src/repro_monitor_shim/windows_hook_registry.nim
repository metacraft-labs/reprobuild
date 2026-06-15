when not defined(windows):
  {.error: "repro_monitor_shim/windows_hook_registry is Windows-only".}

## M26: ct_interpose hook_registry integration for the Windows monitor shim.
##
## Before M26 the monitor shim wired its IAT patches directly to its own
## ``hookCreateFileW`` / ``hookReadFile`` / etc. bodies — one IAT slot, one
## hard-coded hook body. That worked but baked the monitoring policy into
## the hook body itself, leaving no seam for other interposers (e.g. the
## codetracer recorder loaded into the same process) to participate.
##
## M26 inserts ct_interpose's ``hook_registry`` between the IAT slot and
## the monitor's snoop logic. Each hooked Win32 API now has:
##
##   1. A *trampoline* — the function that gets stored in the IAT. Its
##      job is to pack the Win32 args into a ``HookContext.args`` seq and
##      dispatch through the registry.
##   2. A *chain* of one or more hook callbacks registered against the
##      API name. The monitor's snoop logic is the *first* callback
##      (priority 100). Other consumers can register additional hooks
##      with their own priorities and the chain dispatches them in order.
##   3. An *original* callback — wraps the captured original Win32 API
##      function pointer. Sits at the tail of the chain; the snoop
##      callback's ``callNext`` ultimately reaches it.
##
## See ``reprobuild-specs/Standard-Provider-Implementation.milestones.org``
## §M26 for the spec and §M11 (outstanding tasks) for the rationale.

import std/tables
import stackable_hooks/hook_registry
export hook_registry

{.push raises: [].}

# --- Win32 typedefs (mirror windows_interpose.nim) -------------------------

type
  HANDLE* = pointer
  DWORD* = uint32
  WORD* = uint16
  BOOL* = int32
  LPCSTR* = cstring
  LPCWSTR* = ptr uint16
  LPSTR* = cstring
  LPWSTR* = ptr uint16
  LPVOID* = pointer
  LPCVOID* = pointer
  LPSECURITY_ATTRIBUTES* = pointer
  LPOVERLAPPED* = pointer

# --- Process-global registry instance --------------------------------------

# The shim owns a single HookRegistry. Initialised once via initShimRegistry
# from repro_monitor_shim_init. All Win32 trampolines dispatch through this
# instance.

var
  gShimRegistry {.global.}: HookRegistry
  gShimRegistryReady {.global.}: bool = false

proc initShimRegistry*() =
  ## Initialise the process-global hook registry. Idempotent.
  if not gShimRegistryReady:
    gShimRegistry = initHookRegistry()
    gShimRegistryReady = true

proc shimRegistry*(): ptr HookRegistry =
  ## Return a pointer to the process-global registry. The pointer is stable
  ## once initShimRegistry has been called.
  result = addr gShimRegistry

proc shimRegistryReady*(): bool {.inline.} =
  gShimRegistryReady

# --- Canonical Win32 API hook names ----------------------------------------
#
# These names match the strings the IAT patcher passes to GetProcAddress /
# the import-by-name walk; using them as the registry keys keeps a single
# source of truth across the chain. ct_interpose's recorder uses the same
# names for its own hook registrations (when active in the same process),
# which is precisely the "single point of interpose maintenance" benefit
# M26 set out to capture.

const
  HookCreateFileW* = "CreateFileW"
  HookCreateFileA* = "CreateFileA"
  HookReadFile* = "ReadFile"
  HookWriteFile* = "WriteFile"
  HookCloseHandle* = "CloseHandle"
  HookGetFileAttributesExW* = "GetFileAttributesExW"
  HookGetFileAttributesExA* = "GetFileAttributesExA"
  HookGetFileAttributesW* = "GetFileAttributesW"
  HookGetFileAttributesA* = "GetFileAttributesA"
  HookCreateProcessW* = "CreateProcessW"
  HookCreateProcessA* = "CreateProcessA"
  # M73 Phase 5 — additional Win32 entry points from
  # Monitor-Hook-Shim.md §Windows Hook Surface.
  HookDeleteFileW* = "DeleteFileW"
  HookDeleteFileA* = "DeleteFileA"
  HookCreateDirectoryW* = "CreateDirectoryW"
  HookCreateDirectoryA* = "CreateDirectoryA"
  HookCopyFileW* = "CopyFileW"
  HookCopyFileA* = "CopyFileA"
  HookMoveFileExW* = "MoveFileExW"
  HookMoveFileExA* = "MoveFileExA"
  HookGetFileInformationByHandleEx* = "GetFileInformationByHandleEx"
  HookSetCurrentDirectoryW* = "SetCurrentDirectoryW"
  HookSetCurrentDirectoryA* = "SetCurrentDirectoryA"
  # NT Native API backstop — lives in ntdll.dll, not kernel32.
  HookNtCreateFile* = "NtCreateFile"
  # libuv on Windows routes fs.statSync through NtQueryAttributesFile /
  # NtQueryFullAttributesFile (no handle is opened), and fs.readdirSync
  # through NtQueryDirectoryFile. None of these cross the kernel32 layer
  # so they're invisible to the GetFileAttributesExW / FindFirstFileW
  # hooks — we need to catch them in ntdll directly.
  HookNtQueryAttributesFile* = "NtQueryAttributesFile"
  HookNtQueryFullAttributesFile* = "NtQueryFullAttributesFile"
  HookNtQueryDirectoryFile* = "NtQueryDirectoryFile"
  # NtQueryInformationByName — libuv 1.52's fs.statSync fast-path on
  # Win11 22000+. Lowered from kernel32!GetFileInformationByName. Without
  # this hook, fs.statSync on non-existent paths is invisible to the
  # shim because libuv returns ENOENT directly without falling through
  # to CreateFileW.
  HookNtQueryInformationByName* = "NtQueryInformationByName"
  # NtQueryDirectoryFileEx — Win10 1709+ replacement for
  # NtQueryDirectoryFile. libuv may use either depending on the OS
  # capability probe; we hook both for coverage.
  HookNtQueryDirectoryFileEx* = "NtQueryDirectoryFileEx"
  # FindFirstFile / FindNextFile / FindClose — Node.js / libuv 1.52
  # imports these directly from kernel32 for fs.readdirSync rather than
  # going through the NtQueryDirectoryFile NT export. Hooking them at
  # the kernel32 layer is the safe coverage point (the NT-layer detour
  # crashed Node — see project_codetracer_webpack_wedge_postsuccess).
  HookFindFirstFileW* = "FindFirstFileW"
  HookFindFirstFileExW* = "FindFirstFileExW"
  HookFindNextFileW* = "FindNextFileW"
  HookFindClose* = "FindClose"
  # GetProcAddress — intercepted so we can substitute our wrapper for
  # ntdll!NtQueryDirectoryFile when libuv requests its address at
  # init. The inline detour on NtQueryDirectoryFile itself is
  # irrelocatable on Win11 26100 (length-decoder bug on the syscall
  # stub prologue), so we have to intercept the pointer LOOKUP
  # instead of the function body.
  HookGetProcAddress* = "GetProcAddress"

const MonitorShimHookNames*: array[33, string] = [
  HookCreateFileW, HookCreateFileA, HookReadFile, HookWriteFile,
  HookCloseHandle,
  HookGetFileAttributesExW, HookGetFileAttributesExA,
  HookGetFileAttributesW, HookGetFileAttributesA,
  HookCreateProcessW, HookCreateProcessA,
  HookDeleteFileW, HookDeleteFileA,
  HookCreateDirectoryW, HookCreateDirectoryA,
  HookCopyFileW, HookCopyFileA,
  HookMoveFileExW, HookMoveFileExA,
  HookGetFileInformationByHandleEx,
  HookSetCurrentDirectoryW, HookSetCurrentDirectoryA,
  HookNtCreateFile,
  HookNtQueryAttributesFile, HookNtQueryFullAttributesFile,
  HookNtQueryDirectoryFile, HookNtQueryInformationByName,
  HookNtQueryDirectoryFileEx,
  HookFindFirstFileW, HookFindFirstFileExW, HookFindNextFileW, HookFindClose,
  HookGetProcAddress
]

# --- Standard hook priorities ----------------------------------------------
#
# The monitor's snoop callbacks run at the *front* of the chain (priority
# 100). Other consumers (e.g. a future codetracer recorder co-resident in
# the same process) would register at priority 50 to run BEFORE the snoop
# or at priority 200 to run AFTER. Priority 0 is reserved for the chain's
# pseudo-original (set via setOriginal, not registerHook).

const
  ShimSnoopPriority* = 100
  RecorderPriority* = 50
  TrailingDiagPriority* = 200

# --- Helpers for hook callbacks --------------------------------------------

proc registerMonitorHook*(name: string; cb: HookCallback) =
  ## Register the monitor shim's snoop callback for the given Win32 API
  ## name at ShimSnoopPriority. The IAT trampoline will dispatch through
  ## the registered chain; this callback observes the call (records the
  ## MonitorRecord) and forwards to ``callNext`` so the chain continues
  ## to the original Win32 API.
  if not gShimRegistryReady:
    return
  gShimRegistry.registerHook(name, ShimSnoopPriority, cb)

proc setOriginalCallback*(name: string; cb: HookCallback) =
  ## Wire the captured original Win32 function pointer (wrapped in a
  ## HookCallback that unpacks ctx.args and calls through). Called once
  ## per API after the IAT swap succeeds.
  if not gShimRegistryReady:
    return
  gShimRegistry.setOriginal(name, cb)

proc dispatchShimHook*(name: string; ctx: var HookContext) {.inline.} =
  ## Convenience: dispatch a call through the shim's registry. The IAT
  ## trampoline calls this with its own HookContext populated from the
  ## stdcall args; the dispatcher walks the chain (monitor first, then
  ## the original).
  if not gShimRegistryReady:
    return
  gShimRegistry.dispatch(name, ctx)

# --- Registered-hook introspection (for tests + diagnostics) ---------------

proc registeredHookNames*(): seq[string] =
  ## Return the list of hook names with at least one registered callback.
  ## Used by ``test_windows_hook_registry`` to assert the shim wires every
  ## expected Win32 API through the registry.
  result = @[]
  if not gShimRegistryReady:
    return
  for name, _ in gShimRegistry.chains:
    result.add(name)

proc hookCount*(name: string): int =
  ## Return the number of hooks registered for ``name`` (excluding the
  ## ``original`` callback). Returns 0 if the chain doesn't exist.
  if not gShimRegistryReady:
    return 0
  try:
    if name in gShimRegistry.chains:
      result = gShimRegistry.chains[name].hooks.len
    else:
      result = 0
  except KeyError:
    result = 0

proc hasOriginal*(name: string): bool =
  ## Return true if the chain for ``name`` has an ``original`` callback set.
  if not gShimRegistryReady:
    return false
  try:
    if name in gShimRegistry.chains:
      result = gShimRegistry.chains[name].original != nil
    else:
      result = false
  except KeyError:
    result = false

{.pop.}
