when not defined(windows):
  {.error: "repro_monitor_depfile/windows_injector is Windows-only".}

# Windows: CreateRemoteThread + LoadLibraryW injector used by fs_snoop on
# Windows. macOS uses DYLD_INSERT_LIBRARIES which Windows lacks; the Windows
# substitute is the documented "spawn the target suspended, allocate a buffer
# in the remote address space, write the DLL path into it, then call
# LoadLibraryW via CreateRemoteThread" pattern. After LoadLibraryW returns,
# we optionally invoke an init entry point in the loaded DLL (also via
# CreateRemoteThread), then resume the original main thread.

{.push raises: [OSError].}

import std/[os, strutils]
from repro_core/paths import extendedPath
# strutils is used for cmpIgnoreCase and allCharsInSet in argument quoting.

type
  HANDLE = pointer
  DWORD = uint32
  WORD = uint16
  BOOL = int32
  SIZE_T = uint
  LPVOID = pointer
  LPCVOID = pointer
  LPCSTR = cstring
  LPSTR = cstring
  LPCWSTR = ptr uint16
  LPWSTR = ptr uint16
  LPSECURITY_ATTRIBUTES = pointer

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
  CREATE_SUSPENDED = 0x00000004'u32
  CREATE_UNICODE_ENVIRONMENT = 0x00000400'u32
  STARTF_USESTDHANDLES = 0x00000100'u32
  MEM_COMMIT = 0x00001000'u32
  MEM_RESERVE = 0x00002000'u32
  MEM_RELEASE = 0x00008000'u32
  PAGE_READWRITE = 0x04'u32
  INFINITE = 0xFFFFFFFF'u32
  WAIT_OBJECT_0 = 0'u32
  HANDLE_FLAG_INHERIT = 0x00000001'u32
  STD_INPUT_HANDLE = 0xFFFFFFF6'u32
  STD_OUTPUT_HANDLE = 0xFFFFFFF5'u32
  STD_ERROR_HANDLE = 0xFFFFFFF4'u32

proc LoadLibraryWRaw(lpLibFileName: LPCWSTR): HANDLE
  {.importc: "LoadLibraryW", stdcall, dynlib: "kernel32".}
proc FreeLibraryRaw(hLibModule: HANDLE): BOOL
  {.importc: "FreeLibrary", stdcall, dynlib: "kernel32".}

proc EnumProcessModulesEx(hProcess: HANDLE, lphModule: ptr pointer,
                          cb: DWORD, lpcbNeeded: ptr DWORD,
                          dwFilterFlag: DWORD): BOOL
  {.importc, stdcall, dynlib: "psapi".}
proc GetModuleBaseNameW(hProcess: HANDLE, hModule: HANDLE,
                       lpBaseName: LPWSTR, nSize: DWORD): DWORD
  {.importc, stdcall, dynlib: "psapi".}

proc CreateProcessW(lpApplicationName: LPCWSTR, lpCommandLine: LPWSTR,
                    lpProcessAttributes: LPSECURITY_ATTRIBUTES,
                    lpThreadAttributes: LPSECURITY_ATTRIBUTES,
                    bInheritHandles: BOOL, dwCreationFlags: DWORD,
                    lpEnvironment: LPVOID, lpCurrentDirectory: LPCWSTR,
                    lpStartupInfo: ptr STARTUPINFOW,
                    lpProcessInformation: ptr PROCESS_INFORMATION): BOOL
  {.importc, stdcall, dynlib: "kernel32".}
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
proc GetExitCodeProcess(hProcess: HANDLE, lpExitCode: ptr DWORD): BOOL
  {.importc, stdcall, dynlib: "kernel32".}
proc GetExitCodeThread(hThread: HANDLE, lpExitCode: ptr DWORD): BOOL
  {.importc, stdcall, dynlib: "kernel32".}
proc ResumeThread(hThread: HANDLE): DWORD
  {.importc, stdcall, dynlib: "kernel32".}
proc TerminateProcess(hProcess: HANDLE, uExitCode: DWORD): BOOL
  {.importc, stdcall, dynlib: "kernel32".}
proc CloseHandle(hObject: HANDLE): BOOL
  {.importc, stdcall, dynlib: "kernel32".}
proc GetModuleHandleW(lpModuleName: LPCWSTR): HANDLE
  {.importc, stdcall, dynlib: "kernel32".}
proc GetProcAddress(hModule: HANDLE, lpProcName: LPCSTR): pointer
  {.importc, stdcall, dynlib: "kernel32".}
proc GetLastError(): DWORD
  {.importc, stdcall, dynlib: "kernel32".}
proc MultiByteToWideChar(CodePage: DWORD, dwFlags: DWORD,
                         lpMultiByteStr: LPCSTR, cbMultiByte: int32,
                         lpWideCharStr: LPWSTR, cchWideChar: int32): int32
  {.importc, stdcall, dynlib: "kernel32".}
proc GetStdHandle(nStdHandle: DWORD): HANDLE
  {.importc, stdcall, dynlib: "kernel32".}
proc SetHandleInformation(hObject: HANDLE, dwMask: DWORD, dwFlags: DWORD): BOOL
  {.importc, stdcall, dynlib: "kernel32".}
proc CreatePipe(hReadPipe: ptr HANDLE; hWritePipe: ptr HANDLE;
                lpPipeAttributes: LPSECURITY_ATTRIBUTES;
                nSize: DWORD): BOOL
  {.importc, stdcall, dynlib: "kernel32".}
proc ReadFile(hFile: HANDLE; lpBuffer: LPVOID; nNumberOfBytesToRead: DWORD;
              lpNumberOfBytesRead: ptr DWORD;
              lpOverlapped: pointer): BOOL
  {.importc, stdcall, dynlib: "kernel32".}
proc WriteFile(hFile: HANDLE; lpBuffer: LPCVOID; nNumberOfBytesToWrite: DWORD;
               lpNumberOfBytesWritten: ptr DWORD;
               lpOverlapped: pointer): BOOL
  {.importc, stdcall, dynlib: "kernel32".}
proc PeekNamedPipe(hNamedPipe: HANDLE; lpBuffer: LPVOID;
                   nBufferSize: DWORD; lpBytesRead: ptr DWORD;
                   lpTotalBytesAvail: ptr DWORD;
                   lpBytesLeftThisMessage: ptr DWORD): BOOL
  {.importc, stdcall, dynlib: "kernel32".}

type
  SECURITY_ATTRIBUTES {.bycopy.} = object
    nLength: DWORD
    lpSecurityDescriptor: LPVOID
    bInheritHandle: BOOL

proc toWideCStringSeq(s: string): seq[uint16] =
  ## Convert a UTF-8 string to a NUL-terminated UTF-16 buffer.
  if s.len == 0:
    result = @[0'u16]
    return
  let needed = MultiByteToWideChar(65001'u32, 0'u32,
    cast[cstring](unsafeAddr s[0]), int32(s.len), nil, 0'i32)
  if needed <= 0:
    raise newException(OSError, "MultiByteToWideChar measure failed for: " & s)
  result = newSeq[uint16](needed + 1)
  let written = MultiByteToWideChar(65001'u32, 0'u32,
    cast[cstring](unsafeAddr s[0]), int32(s.len),
    cast[LPWSTR](addr result[0]), int32(needed))
  if written <= 0:
    raise newException(OSError, "MultiByteToWideChar failed for: " & s)
  result[needed] = 0'u16

proc quoteWindowsArg(arg: string): string =
  ## Quote a single argv element using the MSVCRT/CommandLineToArgvW rules.
  if arg.len > 0 and arg.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9',
      '-', '_', '.', '/', ':', '\\'}):
    return arg
  result = "\""
  var backslashes = 0
  for ch in arg:
    if ch == '\\':
      inc backslashes
      result.add(ch)
    elif ch == '"':
      for _ in 0 ..< backslashes:
        result.add('\\')
      backslashes = 0
      result.add('\\')
      result.add('"')
    else:
      backslashes = 0
      result.add(ch)
  for _ in 0 ..< backslashes:
    result.add('\\')
  result.add('"')

proc buildCommandLine(argv: openArray[string]): string =
  var parts: seq[string] = @[]
  for i, a in argv:
    parts.add(quoteWindowsArg(a))
  result = parts.join(" ")

type
  WindowsInjectionResult* = object
    exitCode*: int

proc runWithMonitorShim*(argv: openArray[string], dllPath: string,
    cwd = ""; captureStdio = false;
    captureStdioPath = ""): WindowsInjectionResult =
  ## Windows: Spawn `argv` in a CREATE_SUSPENDED state, inject the monitor
  ## shim DLL via CreateRemoteThread+LoadLibraryW, optionally invoke the
  ## shim's `repro_runtime_init` entry point, then resume the main thread.
  ## Returns when the child process exits.
  ##
  ## When ``captureStdio`` is true, the child's stdout+stderr (merged) are
  ## captured into a pipe owned by this proc and drained while waiting
  ## for the child to exit. This mirrors the reprobuild engine's
  ## ``osproc.startProcess`` default behaviour (pipe-captured stdio +
  ## pollCompletion drain) so integration tests at the fs-snoop level can
  ## reproduce wedges that only manifest under the build engine.
  if argv.len == 0:
    raise newException(OSError, "runWithMonitorShim: empty argv")
  let dllExists =
    try: fileExists(extendedPath(dllPath))
    except ValueError: false
  if not dllExists:
    raise newException(OSError, "shim DLL not found: " & dllPath)

  let commandLine = buildCommandLine(argv)
  var cmdLineW = toWideCStringSeq(commandLine)
  var cwdW: seq[uint16] = @[]
  if cwd.len > 0:
    cwdW = toWideCStringSeq(cwd)

  # Pipe for captured stdio mode (anonymous pipe; merged stdout+stderr).
  var stdoutReadPipe: HANDLE = nil
  var stdoutWritePipe: HANDLE = nil
  if captureStdio:
    var sa: SECURITY_ATTRIBUTES
    sa.nLength = DWORD(sizeof(sa))
    sa.bInheritHandle = BOOL(1)
    sa.lpSecurityDescriptor = nil
    if CreatePipe(addr stdoutReadPipe, addr stdoutWritePipe,
                  cast[LPSECURITY_ATTRIBUTES](addr sa), 0'u32) == 0:
      raise newException(OSError,
        "CreatePipe failed (err=" & $GetLastError() & ")")
    # The READ end stays with us; mark it non-inheritable so the child
    # doesn't accidentally inherit a copy of the read handle.
    discard SetHandleInformation(stdoutReadPipe, HANDLE_FLAG_INHERIT, 0'u32)

  var si: STARTUPINFOW
  si.cb = DWORD(sizeof(si))
  si.dwFlags = STARTF_USESTDHANDLES
  if captureStdio:
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE)
    si.hStdOutput = stdoutWritePipe
    si.hStdError = stdoutWritePipe
  else:
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE)
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE)
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE)
  # Make the parent's std handles inheritable for the child.
  discard SetHandleInformation(si.hStdInput, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)
  if not captureStdio:
    discard SetHandleInformation(si.hStdOutput, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)
    discard SetHandleInformation(si.hStdError, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)

  var pi: PROCESS_INFORMATION

  let ok = CreateProcessW(nil,
    cast[LPWSTR](addr cmdLineW[0]),
    nil, nil, BOOL(1),
    CREATE_SUSPENDED,
    nil,
    if cwdW.len > 0: cast[LPCWSTR](addr cwdW[0]) else: nil,
    addr si, addr pi)
  if ok == 0:
    raise newException(OSError,
      "CreateProcessW failed (err=" & $GetLastError() & "): " & commandLine)

  template safeClose(h: HANDLE) =
    if h != nil:
      discard CloseHandle(h)

  try:
    # 1. Allocate a buffer in the child for the wide DLL path.
    var dllPathW = toWideCStringSeq(dllPath)
    let bufSize = SIZE_T(dllPathW.len * sizeof(uint16))
    let remoteBuf = VirtualAllocEx(pi.hProcess, nil, bufSize,
      MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE)
    if remoteBuf == nil:
      raise newException(OSError,
        "VirtualAllocEx failed (err=" & $GetLastError() & ")")

    # 2. Write the DLL path into the buffer.
    var written: SIZE_T = 0
    if WriteProcessMemory(pi.hProcess, remoteBuf, addr dllPathW[0],
        bufSize, addr written) == 0:
      discard VirtualFreeEx(pi.hProcess, remoteBuf, 0, MEM_RELEASE)
      raise newException(OSError,
        "WriteProcessMemory failed (err=" & $GetLastError() & ")")

    # 3. Resolve LoadLibraryW in our own kernel32 — its address is identical
    #    in the child because kernel32 is loaded at the same base.
    var kernel32Name = toWideCStringSeq("kernel32.dll")
    let kernel32 = GetModuleHandleW(cast[LPCWSTR](addr kernel32Name[0]))
    if kernel32 == nil:
      discard VirtualFreeEx(pi.hProcess, remoteBuf, 0, MEM_RELEASE)
      raise newException(OSError,
        "GetModuleHandleW(kernel32) returned NULL")
    let loadLibraryW = GetProcAddress(kernel32, "LoadLibraryW")
    if loadLibraryW == nil:
      discard VirtualFreeEx(pi.hProcess, remoteBuf, 0, MEM_RELEASE)
      raise newException(OSError,
        "GetProcAddress(LoadLibraryW) returned NULL")

    # 4. CreateRemoteThread(LoadLibraryW, remoteBuf).
    let llThread = CreateRemoteThread(pi.hProcess, nil, 0,
      loadLibraryW, remoteBuf, 0, nil)
    if llThread == nil:
      discard VirtualFreeEx(pi.hProcess, remoteBuf, 0, MEM_RELEASE)
      raise newException(OSError,
        "CreateRemoteThread(LoadLibraryW) failed (err=" & $GetLastError() & ")")

    discard WaitForSingleObject(llThread, INFINITE)
    var llExit: DWORD = 0
    discard GetExitCodeThread(llThread, addr llExit)
    discard CloseHandle(llThread)
    discard VirtualFreeEx(pi.hProcess, remoteBuf, 0, MEM_RELEASE)

    if llExit == 0:
      raise newException(OSError,
        "LoadLibraryW in child returned NULL — the shim DLL did not load. " &
        "Check that the DLL and its dependencies are present.")

    # 5. Resolve repro_runtime_init in the child's copy of the shim DLL.
    #    GetExitCodeThread truncates the 64-bit HMODULE returned by
    #    LoadLibraryW to 32 bits, so we cannot use the thread exit code as
    #    the child-side HMODULE. Instead we enumerate the child's module
    #    list, find the entry whose basename matches our shim DLL, and use
    #    its 64-bit base address. Because our DLL was just LoadLibraryW'd
    #    into the child, the basename of the path we sent into the child
    #    is what the loader will report.
    var foundShim: HANDLE = nil
    let wantBaseName = block:
      let (_, tail) = splitPath(dllPath)
      tail
    var childMods: array[1024, HANDLE]
    var modCb: DWORD = 0
    if EnumProcessModulesEx(pi.hProcess, cast[ptr pointer](addr childMods[0]),
        DWORD(sizeof(childMods)), addr modCb, 0x3'u32) != 0:
      let modCount = int(modCb) div sizeof(HANDLE)
      for i in 0 ..< min(modCount, 1024):
        var nameBuf: array[1024, uint16]
        let nameLen = GetModuleBaseNameW(pi.hProcess, childMods[i],
          cast[LPWSTR](addr nameBuf[0]), DWORD(nameBuf.len))
        if nameLen == 0:
          continue
        # Convert UTF-16 basename to a plain ASCII string for comparison.
        var got = ""
        for j in 0 ..< int(nameLen):
          got.add(chr(int(nameBuf[j]) and 0xFF))
        if cmpIgnoreCase(got, wantBaseName) == 0:
          foundShim = childMods[i]
          break

    if foundShim != nil:
      # GetProcAddress returns the offset relative to the DLL base. Both our
      # process and the child loaded the same image, so the RVA matches. We
      # compute "init proc in child" as (foundShim base + (initProc - our
      # base)) where "our base" is the LoadLibraryW result inside the
      # parent (re-LoadLibrary on the parent's side).
      var parentDllPathW = toWideCStringSeq(dllPath)
      let parentShim = LoadLibraryWRaw(cast[LPCWSTR](addr parentDllPathW[0]))
      if parentShim != nil:
        let parentInit = GetProcAddress(parentShim, "repro_runtime_init")
        if parentInit != nil:
          let parentBase = cast[uint](parentShim)
          let parentInitU = cast[uint](parentInit)
          let rva = parentInitU - parentBase
          let childInit = cast[pointer](cast[uint](foundShim) + rva)
          let initThread = CreateRemoteThread(pi.hProcess, nil, 0,
            childInit, nil, 0, nil)
          if initThread != nil:
            discard WaitForSingleObject(initThread, INFINITE)
            discard CloseHandle(initThread)
        discard FreeLibraryRaw(parentShim)

    # 6. Resume the suspended main thread.
    discard ResumeThread(pi.hThread)

    # 7. Wait for the child to exit. In capture mode we close our write
    # end first so the read returns EOF when the child closes its end,
    # then drain in a poll loop alongside the WaitForSingleObject.
    if captureStdio:
      # Close the parent-side write end. The child still holds its
      # inheritable copy so PeekNamedPipe / ReadFile on our read end
      # will keep returning data until the child closes everything.
      if stdoutWritePipe != nil:
        discard CloseHandle(stdoutWritePipe)
        stdoutWritePipe = nil
      var captureBuf: array[8192, char]
      var captureOut: File
      let writeToFile = captureStdioPath.len > 0
      if writeToFile:
        try:
          captureOut = open(captureStdioPath, fmWrite)
        except IOError, OSError:
          captureOut = nil
      while true:
        # Drain everything PeekNamedPipe reports as available, then
        # check process exit. WaitForSingleObject with 50ms timeout
        # caps the drain latency so we don't spin.
        while true:
          var avail: DWORD = 0
          if PeekNamedPipe(stdoutReadPipe, nil, 0, nil, addr avail, nil) == 0:
            break
          if avail == 0:
            break
          var got: DWORD = 0
          if ReadFile(stdoutReadPipe, addr captureBuf[0],
                      DWORD(captureBuf.len), addr got, nil) == 0:
            break
          if got == 0:
            break
          if writeToFile and captureOut != nil:
            try:
              discard captureOut.writeBuffer(addr captureBuf[0], int(got))
              captureOut.flushFile()
            except IOError:
              discard
          # If no path was specified we just discard — the goal in
          # tests is to mimic the engine's "drain to /dev/null" path
          # (engine keeps the bytes in memory but tests rarely need
          # them).
        let waitStatus = WaitForSingleObject(pi.hProcess, 50'u32)
        if waitStatus == WAIT_OBJECT_0:
          break
      # Final drain after exit — anything in the buffer that wasn't
      # consumed during the 50ms slice.
      while true:
        var got: DWORD = 0
        if ReadFile(stdoutReadPipe, addr captureBuf[0],
                    DWORD(captureBuf.len), addr got, nil) == 0:
          break
        if got == 0:
          break
        if writeToFile and captureOut != nil:
          try:
            discard captureOut.writeBuffer(addr captureBuf[0], int(got))
            captureOut.flushFile()
          except IOError:
            discard
      if writeToFile and captureOut != nil:
        try: captureOut.close()
        except IOError: discard
      if stdoutReadPipe != nil:
        discard CloseHandle(stdoutReadPipe)
        stdoutReadPipe = nil
    else:
      discard WaitForSingleObject(pi.hProcess, INFINITE)
    var exit: DWORD = 0
    discard GetExitCodeProcess(pi.hProcess, addr exit)
    result.exitCode = int(exit)
  except OSError:
    discard TerminateProcess(pi.hProcess, 1'u32)
    safeClose(pi.hThread)
    safeClose(pi.hProcess)
    if stdoutWritePipe != nil:
      discard CloseHandle(stdoutWritePipe)
      stdoutWritePipe = nil
    if stdoutReadPipe != nil:
      discard CloseHandle(stdoutReadPipe)
      stdoutReadPipe = nil
    raise
  safeClose(pi.hThread)
  safeClose(pi.hProcess)
  if stdoutWritePipe != nil:
    discard CloseHandle(stdoutWritePipe)
  if stdoutReadPipe != nil:
    discard CloseHandle(stdoutReadPipe)

{.pop.}
