## The current working directory of ANOTHER running process, read from the
## operating system rather than from anything the process says about itself.
##
## WHY A TEST NEEDS IT. A daemon `repro` starts outlives its starter, and the
## directory it runs in stays pinned for its whole life: on Windows a process's
## current directory can be neither deleted nor renamed, which is how an
## auto-started `runquotad` running in its install's `bin\` blocked every
## in-place bundle upgrade. The property is
## "the daemon's current directory is not X", and only the kernel's record of
## the process answers it.
##
## HOW, PER PLATFORM.
##
## * Linux: the `/proc/<pid>/cwd` symbolic link
##   (https://man7.org/linux/man-pages/man5/proc_pid_cwd.5.html).
## * macOS: `proc_pidinfo(PROC_PIDVNODEPATHINFO)`, whose
##   `struct proc_vnodepathinfo` starts with the current directory's
##   `vnode_info_path` (`<sys/proc_info.h>`).
## * Windows: there is no documented API. The value lives in the target's
##   `RTL_USER_PROCESS_PARAMETERS.CurrentDirectory.DosPath`, reached through
##   `NtQueryInformationProcess(ProcessBasicInformation)` -> `PEB` ->
##   `ProcessParameters`, and read with `ReadProcessMemory`
##   (https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntqueryinformationprocess,
##   https://learn.microsoft.com/windows/win32/api/winternl/ns-winternl-peb).
##   The offsets are those of the 64-bit layout, the only one this suite
##   builds for on Windows (x86_64, aarch64); a 32-bit build refuses at
##   compile time instead of reading the wrong field. The process's own
##   `CurrentDirectory.Handle` is the handle that pins the directory, so this
##   is the value that matters.

import std/os

when defined(windows):
  import std/winlean
  from std/strutils import toHex

  const
    ProcessBasicInformationClass = 0'i32
    ProcessQueryInformation = 0x0400'i32
    ProcessVmRead = 0x0010'i32
    PebProcessParametersOffset = 0x20
    ParametersCurrentDirectoryOffset = 0x38
      ## `CURDIR.DosPath`, a `UNICODE_STRING`: `Length` (bytes, u16),
      ## `MaximumLength` (u16), 4 bytes of padding, `Buffer` (pointer).

  when sizeof(pointer) != 8:
    {.error: "processWorkingDirectory reads the 64-bit PEB layout only".}

  type ProcessBasicInformation = object
    exitStatus: int
    pebBaseAddress: uint
    affinityMask: uint
    basePriority: int
    uniqueProcessId: uint
    inheritedFromUniqueProcessId: uint

  proc ntQueryInformationProcess(process: Handle; class: int32;
      information: pointer; length: uint32; returnLength: ptr uint32): int32
      {.stdcall, dynlib: "ntdll", importc: "NtQueryInformationProcess".}

  proc readProcessMemory(process: Handle; base: uint; buffer: pointer;
      size: csize_t; read: ptr csize_t): WINBOOL
      {.stdcall, dynlib: "kernel32", importc: "ReadProcessMemory".}

  proc readExactly(process: Handle; address: uint; buffer: pointer;
                   size: int; what: string) =
    var got: csize_t = 0
    if readProcessMemory(process, address, buffer, csize_t(size),
        addr got) == 0 or int(got) != size:
      raiseOSError(osLastError(), "ReadProcessMemory (" & what & ")")

elif defined(macosx):
  const
    ProcPidVnodePathInfo = 9.cint
    VnodeInfoSize = 152
      ## `sizeof(struct vnode_info)`, the part of `vnode_info_path` before
      ## its `vip_path[MAXPATHLEN]`.
    MaxPathLen = 1024

  proc procPidinfo(pid: cint; flavor: cint; arg: uint64; buffer: pointer;
                   size: cint): cint {.importc: "proc_pidinfo",
                   header: "<libproc.h>".}

proc processWorkingDirectory*(pid: int): string =
  ## The current working directory of the live process `pid`, as the
  ## operating system records it. Raises `OSError` when it cannot be read
  ## (no such process, access denied). On Windows the answer ends with a
  ## path separator, as the process parameters store it.
  when defined(linux):
    expandSymlink("/proc/" & $pid & "/cwd")
  elif defined(macosx):
    var buffer: array[2 * (VnodeInfoSize + MaxPathLen), char]
    let got = procPidinfo(cint(pid), ProcPidVnodePathInfo, 0, addr buffer[0],
      cint(sizeof(buffer)))
    if got <= 0:
      raiseOSError(osLastError(), "proc_pidinfo(PROC_PIDVNODEPATHINFO)")
    $cast[cstring](addr buffer[VnodeInfoSize])
  elif defined(windows):
    let process = openProcess(ProcessQueryInformation or ProcessVmRead,
      0, DWORD(pid))
    if process == 0:
      raiseOSError(osLastError(), "OpenProcess " & $pid)
    defer: discard closeHandle(process)
    var basic: ProcessBasicInformation
    let status = ntQueryInformationProcess(process,
      ProcessBasicInformationClass, addr basic, uint32(sizeof(basic)), nil)
    if status != 0:
      raise newException(OSError, "NtQueryInformationProcess " & $pid &
        " failed with NTSTATUS 0x" & toHex(status))
    var parameters: uint = 0
    readExactly(process, basic.pebBaseAddress + PebProcessParametersOffset,
      addr parameters, sizeof(parameters), "PEB.ProcessParameters")
    var length: uint16 = 0
    readExactly(process, parameters + ParametersCurrentDirectoryOffset,
      addr length, sizeof(length), "CurrentDirectory.DosPath.Length")
    var buffer: uint = 0
    readExactly(process, parameters + ParametersCurrentDirectoryOffset + 8,
      addr buffer, sizeof(buffer), "CurrentDirectory.DosPath.Buffer")
    if length == 0 or buffer == 0:
      return ""
    var wide = newSeq[uint16](int(length) div 2 + 1)
    readExactly(process, buffer, addr wide[0], int(length),
      "CurrentDirectory.DosPath")
    wide[^1] = 0
    $cast[WideCString](addr wide[0])
  else:
    raise newException(OSError,
      "processWorkingDirectory is not implemented on this platform")
