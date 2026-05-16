import std/[os, sets, strutils, tables]

type
  FilesystemWatchEvent* = object
    path*: string
    detail*: string

when defined(macosx):
  type
    Kevent {.importc: "struct kevent", header: "<sys/event.h>", bycopy.} = object
      ident*: uint
      filter*: cshort
      flags*: cushort
      fflags*: cuint
      data*: clong
      udata*: pointer

    Timespec {.importc: "struct timespec", header: "<time.h>", bycopy.} = object
      tv_sec*: clong
      tv_nsec*: clong

    FilesystemWatcher* = ref object
      kq: cint
      fds: seq[cint]
      pathsByFd: Table[cint, string]

  const
    EvFilterVnode = -4.cshort
    EvAdd = 0x0001.cushort
    EvEnable = 0x0004.cushort
    EvClear = 0x0020.cushort
    NoteDelete = 0x00000001.cuint
    NoteWrite = 0x00000002.cuint
    NoteExtend = 0x00000004.cuint
    NoteAttrib = 0x00000008.cuint
    NoteLink = 0x00000010.cuint
    NoteRename = 0x00000020.cuint
    NoteRevoke = 0x00000040.cuint
    OEvOnly = 0x00008000.cint

  proc kqueue(): cint {.importc, header: "<sys/event.h>".}
  proc kevent(kq: cint; changelist: ptr Kevent; nchanges: cint;
              eventlist: ptr Kevent; nevents: cint;
              timeout: ptr Timespec): cint {.importc, header: "<sys/event.h>".}
  proc cOpen(path: cstring; flags: cint): cint
      {.importc: "open", header: "<fcntl.h>", varargs.}
  proc cClose(fd: cint): cint {.importc: "close", header: "<unistd.h>".}

  proc watchFlags(): cuint =
    NoteDelete or NoteWrite or NoteExtend or NoteAttrib or NoteLink or
      NoteRename or NoteRevoke

  proc eventDetail(fflags: cuint): string =
    var parts: seq[string] = @[]
    if (fflags and NoteDelete) != 0: parts.add("delete")
    if (fflags and NoteWrite) != 0: parts.add("write")
    if (fflags and NoteExtend) != 0: parts.add("extend")
    if (fflags and NoteAttrib) != 0: parts.add("attrib")
    if (fflags and NoteLink) != 0: parts.add("link")
    if (fflags and NoteRename) != 0: parts.add("rename")
    if (fflags and NoteRevoke) != 0: parts.add("revoke")
    if parts.len == 0:
      "unknown"
    else:
      parts.join(",")

  proc closeFilesystemWatcher*(watcher: FilesystemWatcher) =
    if watcher.isNil:
      return
    for fd in watcher.fds:
      discard cClose(fd)
    watcher.fds.setLen(0)
    if watcher.kq >= 0:
      discard cClose(watcher.kq)
      watcher.kq = -1

  proc openFilesystemWatcher*(paths: openArray[string]): FilesystemWatcher =
    result = FilesystemWatcher(kq: kqueue())
    if result.kq < 0:
      raise newException(OSError, "kqueue failed")
    var seen = initHashSet[string]()
    try:
      for rawPath in paths:
        if rawPath.len == 0:
          continue
        let path = rawPath.normalizedPath
        if seen.contains(path):
          continue
        seen.incl(path)
        if not fileExists(path) and not dirExists(path):
          continue
        let fd = cOpen(path.cstring, OEvOnly)
        if fd < 0:
          continue
        var event = Kevent(
          ident: uint(fd),
          filter: EvFilterVnode,
          flags: EvAdd or EvEnable or EvClear,
          fflags: watchFlags(),
          data: 0,
          udata: nil)
        let registered = kevent(result.kq, addr event, 1, nil, 0, nil)
        if registered != 0:
          discard cClose(fd)
          continue
        result.fds.add(fd)
        result.pathsByFd[fd] = path
      if result.fds.len == 0:
        raise newException(ValueError,
          "no existing filesystem paths could be watched")
    except CatchableError:
      result.closeFilesystemWatcher()
      raise

  proc watchedPathCount*(watcher: FilesystemWatcher): int =
    if watcher.isNil:
      0
    else:
      watcher.fds.len

  proc waitForEvent*(watcher: FilesystemWatcher): FilesystemWatchEvent =
    var event: Kevent
    let n = kevent(watcher.kq, nil, 0, addr event, 1, nil)
    if n < 0:
      raise newException(OSError, "kevent wait failed")
    let fd = cint(event.ident)
    result.path = watcher.pathsByFd.getOrDefault(fd, "<unknown>")
    result.detail = eventDetail(event.fflags)

  proc drainDebouncedEvents*(watcher: FilesystemWatcher; debounceMs: int): int =
    if debounceMs > 0:
      sleep(debounceMs)
    var timeout = Timespec(tv_sec: 0, tv_nsec: 0)
    while true:
      var event: Kevent
      let n = kevent(watcher.kq, nil, 0, addr event, 1, addr timeout)
      if n <= 0:
        break
      result.inc

else:
  type
    FilesystemWatcher* = ref object

  proc openFilesystemWatcher*(paths: openArray[string]): FilesystemWatcher =
    raise newException(OSError,
      "repro watch currently supports macOS kqueue only; Linux and Windows " &
        "filesystem watch backends are deferred")

  proc closeFilesystemWatcher*(watcher: FilesystemWatcher) =
    discard

  proc watchedPathCount*(watcher: FilesystemWatcher): int =
    0

  proc waitForEvent*(watcher: FilesystemWatcher): FilesystemWatchEvent =
    raise newException(OSError,
      "repro watch currently supports macOS kqueue only; Linux and Windows " &
        "filesystem watch backends are deferred")

  proc drainDebouncedEvents*(watcher: FilesystemWatcher; debounceMs: int): int =
    0
