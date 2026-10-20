## Kernel-owned session exclusion and a handle to the helper's supervisor.
## Lock files remain in place: unlinking a held lock permits two owners.
import std/[atomics, json, os]
from repro_core import extendedPath

when defined(windows):
  type NativeHandle = pointer
  proc createFile(path: WideCString; access, share: uint32; security: pointer;
                  disposition, flags: uint32; templateFile: pointer): NativeHandle
    {.stdcall, dynlib: "kernel32", importc: "CreateFileW".}
  proc closeHandle(handle: NativeHandle): int32
    {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}
  proc openProcess(access: uint32; inherit: int32; pid: uint32): NativeHandle
    {.stdcall, dynlib: "kernel32", importc: "OpenProcess".}
  proc waitForSingleObject(handle: NativeHandle; milliseconds: uint32): uint32
    {.stdcall, dynlib: "kernel32", importc: "WaitForSingleObject".}
  proc getLastError(): uint32
    {.stdcall, dynlib: "kernel32", importc: "GetLastError".}
else:
  import std/posix
  proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}

type SessionProcessBusyError* = object of IOError
  ## Exclusion is held by another process, rather than unavailable due to
  ## permissions or another filesystem failure.

type SessionProcessLock* = object
  held: bool
  when defined(windows):
    handle: NativeHandle
  else:
    fd: cint

proc acquireSessionProcessLock*(path: string): SessionProcessLock =
  when defined(windows):
    result.handle = createFile(newWideCString(extendedPath(path)), 0xC0000000'u32, 0,
      nil, 4, 0x80, nil)
    if result.handle == cast[pointer](-1):
      let error = getLastError()
      if error == 32: # ERROR_SHARING_VIOLATION
        raise newException(SessionProcessBusyError,
          "session already has an owner: " & path)
      raiseOSError(OSErrorCode(error), path)
  else:
    result.fd = posix.open(path.cstring, O_RDWR or O_CREAT or O_CLOEXEC,
      Mode(0o600))
    if result.fd < 0:
      raiseOSError(osLastError(), path)
    if flock(result.fd, 2 or 4) != 0: # LOCK_EX | LOCK_NB
      let error = errno
      discard posix.close(result.fd)
      if error == EAGAIN or error == EWOULDBLOCK:
        raise newException(SessionProcessBusyError,
          "session already has an owner: " & path)
      raiseOSError(OSErrorCode(error), path)
  result.held = true

proc release*(lock: SessionProcessLock) =
  if not lock.held: return
  when defined(windows):
    discard closeHandle(lock.handle)
  else:
    discard posix.close(lock.fd)

proc sessionProcessAlive*(pid: int): bool =
  ## Reuse requires the recorded supervisor to exist as well as a live API:
  ## a lingering helper must not stand in for its dead owner.
  if pid <= 0: return false
  when defined(windows):
    let handle = openProcess(0x00100000, 0, uint32(pid)) # SYNCHRONIZE
    if handle == nil: return false
    defer: discard closeHandle(handle)
    waitForSingleObject(handle, 0) == 258 # WAIT_TIMEOUT
  else:
    posix.kill(Pid(pid), 0) == 0 or errno == EPERM

type SessionParent* = object
  when defined(windows):
    handle: NativeHandle
  else:
    pid: int

proc openSessionParent*(pid: int): SessionParent =
  if pid <= 0:
    raise newException(ValueError, "session HTTP helper requires --parent-pid")
  when defined(windows):
    result.handle = openProcess(0x00100000, 0, uint32(pid)) # SYNCHRONIZE
    if result.handle == nil:
      raiseOSError(osLastError(), "open session supervisor")
  else:
    result.pid = pid

proc alive*(parent: SessionParent): bool =
  when defined(windows):
    waitForSingleObject(parent.handle, 0) == 258 # WAIT_TIMEOUT
  else:
    int(getppid()) == parent.pid

proc close*(parent: SessionParent) =
  when defined(windows):
    discard closeHandle(parent.handle)

proc removeOwnedReady*(sessionDir: string) =
  let path = extendedPath(sessionDir / "http-ready.json")
  try:
    if parseJson(readFile(path)){"pid"}.getInt() == getCurrentProcessId():
      removeFile(path)
  except CatchableError:
    discard

type SessionWatchdogArgs* = tuple[parent: SessionParent, dir: string,
                                  stopped: ptr Atomic[bool]]

proc watchSessionParent*(args: SessionWatchdogArgs) {.thread.} =
  # An independent thread is required: an HTTP client can block accept,
  # recv, send, or an event stream. None may extend the owner's lifetime.
  while not args.stopped[].load():
    if not args.parent.alive() or fileExists(extendedPath(args.dir / "stop.request.json")):
      args.dir.removeOwnedReady()
      quit(0)
    sleep(100)
