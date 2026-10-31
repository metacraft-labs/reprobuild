## Size-bounded, best-effort diagnostics shared by daemon and launch clients.
## A stable kernel lock serializes inspection, rotation and append across
## processes. Unlike locking the log itself, it survives replacement of the
## current generation; unlike a PID file, a crash cannot leave it held.

import std/[os, monotimes, times]
when defined(posix):
  import std/posix except Time
  proc cFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}
elif defined(windows):
  import std/winlean

const UserDaemonLogMaxBytes* = 16 * 1024 * 1024
  ## Ceiling per generation; one previous generation is retained.

proc userDaemonLogPreviousGeneration*(path: string): string =
  ## Previous generation read before the current file by `daemon logs`.
  path & ".1"

type LogLock = object
  when defined(posix):
    fd: cint
  elif defined(windows):
    handle: Handle

proc acquireLogLock(path: string): LogLock =
  let deadline = getMonoTime() + initDuration(milliseconds = 1000)
  when defined(posix):
    result.fd = posix.open(cstring(path), O_RDWR or O_CREAT or O_CLOEXEC,
      Mode(0o600))
    if result.fd < 0: raiseOSError(osLastError())
    while cFlock(result.fd, 2.cint or 4.cint) != 0:
      let error = osLastError()
      if (error.int != EWOULDBLOCK.int and error.int != EAGAIN.int and
          error.int != EINTR.int) or getMonoTime() >= deadline:
        discard posix.close(result.fd)
        raiseOSError(error)
      sleep(5)
  elif defined(windows):
    while true:
      result.handle = createFileW(newWideCString(path),
        GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, Handle(0))
      if result.handle != INVALID_HANDLE_VALUE: break
      let error = osLastError()
      if error.int != 32 or getMonoTime() >= deadline:
        raiseOSError(error)
      sleep(5)
  else:
    raise newException(IOError, "daemon log locking unavailable")

proc release(lock: LogLock) =
  when defined(posix):
    discard posix.close(lock.fd)
  elif defined(windows):
    discard closeHandle(lock.handle)

proc boundExisting(path: string; maxBytes: int) =
  ## Read only the retained tail, even when an old version left gigabytes.
  if not fileExists(path): return
  let size = getFileSize(path)
  if size <= int64(maxBytes): return
  var source = open(path, fmRead)
  var tail = newString(maxBytes)
  try:
    source.setFilePos(size - int64(maxBytes))
    if source.readBuffer(addr tail[0], tail.len) != tail.len:
      raise newException(IOError, "short daemon log tail read")
  finally:
    source.close()
  writeFile(path, tail)

proc appendUserDaemonLogLine*(path, message: string;
                              maxBytes = UserDaemonLogMaxBytes) =
  ## Append one timestamped diagnostic. Every successful append bounds both
  ## generations. Lock contention and filesystem failures drop the diagnostic
  ## rather than disrupting the operation being diagnosed. External writes
  ## and filesystem failures are outside this best-effort retention contract.
  try:
    if maxBytes <= 0: return
    let prefix = $now() & " "
    const marker = " [truncated]\n"
    var line: string
    if message.len <= maxBytes - prefix.len - 1:
      line = prefix & message & "\n"
    else:
      # Bound the allocation as well as the output for huge input messages.
      let available = maxBytes - prefix.len - marker.len
      if available >= 0:
        line = prefix & message[0 ..< available] & marker
      else:
        line = marker[max(0, marker.len - maxBytes) ..< marker.len]
    createDir(parentDir(path))
    let lock = acquireLogLock(path & ".lock")
    defer: release(lock)
    let previous = userDaemonLogPreviousGeneration(path)
    boundExisting(previous, maxBytes)
    boundExisting(path, maxBytes)
    if fileExists(path) and getFileSize(path) + int64(line.len) > int64(maxBytes):
      moveFile(path, previous)
    var file = open(path, fmAppend)
    defer: file.close()
    file.write(line)
  except CatchableError:
    discard
