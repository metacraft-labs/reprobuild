import std/[deques, os, sets, strutils, tables]
from repro_core/paths import extendedPath
when defined(windows):
  import std/winlean

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
        if not fileExists(extendedPath(path)) and not dirExists(extendedPath(path)):
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

elif defined(windows):
  # Windows: backend uses ReadDirectoryChangesW. kqueue can watch arbitrary
  # file descriptors (including individual files); Win32 only delivers
  # directory-scoped notifications. Each requested path therefore becomes:
  #   * a directory watch (path itself), or
  #   * a parent-directory watch with a per-record basename filter so a single
  #     file path produces the same one-event-per-change behaviour as kqueue.
  const
    FILE_LIST_DIRECTORY = 0x0001'i32
    FILE_NOTIFY_CHANGE_FILE_NAME = 0x00000001'i32
    FILE_NOTIFY_CHANGE_DIR_NAME = 0x00000002'i32
    FILE_NOTIFY_CHANGE_ATTRIBUTES = 0x00000004'i32
    FILE_NOTIFY_CHANGE_SIZE = 0x00000008'i32
    FILE_NOTIFY_CHANGE_LAST_WRITE = 0x00000010'i32
    FILE_ACTION_ADDED = 0x00000001'i32
    FILE_ACTION_REMOVED = 0x00000002'i32
    FILE_ACTION_MODIFIED = 0x00000003'i32
    FILE_ACTION_RENAMED_OLD_NAME = 0x00000004'i32
    FILE_ACTION_RENAMED_NEW_NAME = 0x00000005'i32
    WatchBufferBytes = 64 * 1024
    # Windows: WaitForMultipleObjects caps at MAXIMUM_WAIT_OBJECTS (64). We
    # never expect more watched paths than that in practice (reprobuild
    # typically watches a project root + a few source files), but enforce it
    # explicitly so a future blow-up surfaces as a clear OSError instead of
    # silent truncation.
    MaxWatchHandles = 64

  type
    # Windows: declared here because std/winlean does not expose
    # FILE_NOTIFY_INFORMATION nor ReadDirectoryChangesW.
    FileNotifyInformation {.pure, inheritable, bycopy.} = object
      nextEntryOffset: DWORD
      action: DWORD
      fileNameLength: DWORD # bytes, not chars
      fileName: array[1, Utf16Char] # variable-length tail follows

  proc readDirectoryChangesW(hDirectory: Handle; lpBuffer: pointer;
                             nBufferLength: DWORD; bWatchSubtree: WINBOOL;
                             dwNotifyFilter: DWORD;
                             lpBytesReturned: ptr DWORD;
                             lpOverlapped: POVERLAPPED;
                             lpCompletionRoutine: pointer): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "ReadDirectoryChangesW".}
  proc cancelIoEx(hFile: Handle; lpOverlapped: POVERLAPPED): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "CancelIoEx".}

  type
    # Windows: one WatchEntry per opened directory handle. `matchBasename` is
    # populated when the caller asked to watch a specific file rather than a
    # directory — only events whose record filename equals this string are
    # emitted, mirroring kqueue's per-fd granularity.
    WatchEntry = ref object
      dirHandle: Handle
      overlapped: OVERLAPPED
      buffer: pointer
      reportPath: string      # original path the caller passed in
      matchBasename: string   # empty => watch all entries in dirHandle
      readPending: bool

    FilesystemWatcher* = ref object
      entries: seq[WatchEntry]
      pending: Deque[FilesystemWatchEvent]

  proc actionDetail(action: DWORD): string =
    # Windows: kqueue can OR multiple NOTE_* flags into one event; Win32
    # delivers a single Action per record. The detail string therefore
    # carries one token but uses the same vocabulary as the kqueue path
    # ("write"/"delete"/"rename"/"attrib") with extras for add/modify.
    case action
    of FILE_ACTION_ADDED: "add"
    of FILE_ACTION_REMOVED: "delete"
    of FILE_ACTION_MODIFIED: "write"
    of FILE_ACTION_RENAMED_OLD_NAME: "rename"
    of FILE_ACTION_RENAMED_NEW_NAME: "rename"
    else: "unknown"

  proc watchFilter(): DWORD =
    DWORD(FILE_NOTIFY_CHANGE_FILE_NAME or FILE_NOTIFY_CHANGE_DIR_NAME or
      FILE_NOTIFY_CHANGE_ATTRIBUTES or FILE_NOTIFY_CHANGE_SIZE or
      FILE_NOTIFY_CHANGE_LAST_WRITE)

  proc utf16ToString(p: ptr Utf16Char; charCount: int): string =
    # Windows: FILE_NOTIFY_INFORMATION packs a UTF-16 filename inline with
    # no terminator. We must reconstruct a Nim string from a known byte
    # length. Use the runtime's WideCString helper after copying into a
    # temporary terminated buffer.
    if charCount <= 0:
      return ""
    var tmp = newWideCString("", charCount)
    let dst = cast[ptr UncheckedArray[Utf16Char]](addr tmp[0])
    let src = cast[ptr UncheckedArray[Utf16Char]](p)
    for i in 0 ..< charCount:
      dst[i] = src[i]
    # newWideCString sized for charCount + 1 elements; ensure NUL terminator.
    dst[charCount] = Utf16Char(0)
    $tmp

  proc closeEntry(entry: WatchEntry) =
    if entry.isNil:
      return
    if entry.dirHandle != INVALID_HANDLE_VALUE:
      # Windows: cancel any outstanding overlapped read before closing.
      # Closing the handle alone would also cancel, but doing it explicitly
      # avoids a small race where the kernel completes the I/O after the
      # handle is gone but before we drop the buffer.
      if entry.readPending:
        discard cancelIoEx(entry.dirHandle, addr entry.overlapped)
        var bytes: DWORD = 0
        discard getOverlappedResult(entry.dirHandle, addr entry.overlapped,
          bytes, WINBOOL(1))
        entry.readPending = false
      discard closeHandle(entry.dirHandle)
      entry.dirHandle = INVALID_HANDLE_VALUE
    if entry.overlapped.hEvent != Handle(0):
      discard closeHandle(entry.overlapped.hEvent)
      entry.overlapped.hEvent = Handle(0)
    if entry.buffer != nil:
      dealloc(entry.buffer)
      entry.buffer = nil

  proc closeFilesystemWatcher*(watcher: FilesystemWatcher) =
    if watcher.isNil:
      return
    for entry in watcher.entries:
      closeEntry(entry)
    watcher.entries.setLen(0)
    watcher.pending.clear()

  proc postRead(entry: WatchEntry) =
    # Windows: reset OVERLAPPED before each call. ReadDirectoryChangesW
    # writes back internal/internalHigh fields and expects them zeroed
    # between requests for a fresh wait.
    entry.overlapped.internal = nil
    entry.overlapped.internalHigh = nil
    entry.overlapped.offset = 0
    entry.overlapped.offsetHigh = 0
    var bytesReturned: DWORD = 0
    let ok = readDirectoryChangesW(entry.dirHandle, entry.buffer,
      DWORD(WatchBufferBytes), WINBOOL(0), watchFilter(),
      addr bytesReturned, addr entry.overlapped, nil)
    if ok == 0:
      let err = getLastError()
      raise newException(OSError,
        "ReadDirectoryChangesW failed: error " & $err)
    entry.readPending = true

  proc openWatchEntry(dirPath, reportPath, matchBasename: string): WatchEntry =
    # Windows: opens a directory for change notifications. Must use
    # FILE_FLAG_BACKUP_SEMANTICS to open a directory handle and
    # FILE_FLAG_OVERLAPPED so ReadDirectoryChangesW returns immediately
    # with ERROR_IO_PENDING and signals via OVERLAPPED.hEvent.
    var wpath = newWideCString(dirPath)
    let share = DWORD(FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE)
    let flags = DWORD(FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OVERLAPPED)
    let h = createFileW(wpath, DWORD(FILE_LIST_DIRECTORY), share,
      nil, DWORD(OPEN_EXISTING), flags, Handle(0))
    if h == INVALID_HANDLE_VALUE:
      return nil
    # Windows: manual-reset event so multiple events that complete between
    # waits do not lose the signal; we reset implicitly via successive
    # ReadDirectoryChangesW calls. CreateEventW takes a 0/1 manual flag.
    let hEvent = createEvent(nil, DWORD(1), DWORD(0), nil)
    if hEvent == Handle(0):
      discard closeHandle(h)
      return nil
    result = WatchEntry(
      dirHandle: h,
      buffer: alloc0(WatchBufferBytes),
      reportPath: reportPath,
      matchBasename: matchBasename)
    result.overlapped.hEvent = hEvent
    try:
      postRead(result)
    except CatchableError:
      closeEntry(result)
      raise

  proc openFilesystemWatcher*(paths: openArray[string]): FilesystemWatcher =
    # Windows: parallels the kqueue branch's openFilesystemWatcher. Same
    # de-duplication + "skip non-existent paths" semantics so reprobuild's
    # caller does not need to know about the platform difference.
    result = FilesystemWatcher(pending: initDeque[FilesystemWatchEvent]())
    var seen = initHashSet[string]()
    try:
      for rawPath in paths:
        if rawPath.len == 0:
          continue
        let path = rawPath.normalizedPath
        if seen.contains(path):
          continue
        seen.incl(path)
        var dirPath: string
        var matchBasename: string
        if dirExists(extendedPath(path)):
          dirPath = path
          matchBasename = ""
        elif fileExists(extendedPath(path)):
          dirPath = parentDir(path)
          if dirPath.len == 0:
            dirPath = "."
          matchBasename = extractFilename(path)
        else:
          continue
        if result.entries.len >= MaxWatchHandles:
          raise newException(OSError,
            "repro watch on Windows supports at most " & $MaxWatchHandles &
              " distinct watch paths (WaitForMultipleObjects limit)")
        let entry = openWatchEntry(dirPath, path, matchBasename)
        if entry.isNil:
          continue
        result.entries.add(entry)
      if result.entries.len == 0:
        raise newException(ValueError,
          "no existing filesystem paths could be watched")
    except CatchableError:
      result.closeFilesystemWatcher()
      raise

  proc watchedPathCount*(watcher: FilesystemWatcher): int =
    if watcher.isNil:
      0
    else:
      watcher.entries.len

  proc consumeBuffer(entry: WatchEntry; bytes: DWORD;
                     out_events: var Deque[FilesystemWatchEvent]) =
    # Windows: parse the linked list of FILE_NOTIFY_INFORMATION records
    # ReadDirectoryChangesW packed into the buffer. nextEntryOffset == 0
    # marks the last record. A zero-byte return means the kernel ran out
    # of buffer space and dropped notifications (handled in the caller by
    # emitting a synthetic "overflow" event so the build loop still
    # rebuilds).
    if bytes == 0:
      out_events.addLast(FilesystemWatchEvent(
        path: entry.reportPath, detail: "overflow"))
      return
    var offset: uint = 0
    while true:
      let recordPtr = cast[uint](entry.buffer) + offset
      let record = cast[ptr FileNotifyInformation](recordPtr)
      let nameBytes = int(record.fileNameLength)
      let nameChars = nameBytes div 2
      let name = utf16ToString(cast[ptr Utf16Char](addr record.fileName[0]),
        nameChars).replace('\\', '/').replace('/', DirSep)
      let emit =
        if entry.matchBasename.len == 0:
          true
        else:
          # Windows: ReadDirectoryChangesW reports paths relative to the
          # watched directory. For file-targeted watches we filter by the
          # leaf component so siblings do not leak events.
          extractFilename(name) == entry.matchBasename
      if emit:
        let reportPath =
          if entry.matchBasename.len > 0:
            entry.reportPath
          else:
            entry.reportPath / name
        out_events.addLast(FilesystemWatchEvent(
          path: reportPath, detail: actionDetail(record.action)))
      let nextOffset = record.nextEntryOffset
      if nextOffset == 0:
        break
      offset += uint(nextOffset)

  proc collectCompleted(watcher: FilesystemWatcher) =
    # Windows: drain every entry whose overlapped event is currently
    # signalled, parse records, and immediately re-post the read so the
    # next wait sees fresh notifications. WaitForSingleObject with
    # timeout 0 polls without blocking.
    for entry in watcher.entries:
      if not entry.readPending:
        continue
      let waitRes = waitForSingleObject(entry.overlapped.hEvent, 0)
      if waitRes != WAIT_OBJECT_0:
        continue
      var bytes: DWORD = 0
      let ok = getOverlappedResult(entry.dirHandle, addr entry.overlapped,
        bytes, WINBOOL(0))
      entry.readPending = false
      if ok == 0:
        # Windows: ERROR_NOTIFY_ENUM_DIR (1022) means the buffer overflowed
        # and the kernel discarded events. Treat like the kqueue path's
        # NOTE_REVOKE — surface a single event so the caller rebuilds.
        watcher.pending.addLast(FilesystemWatchEvent(
          path: entry.reportPath, detail: "overflow"))
      else:
        consumeBuffer(entry, bytes, watcher.pending)
      postRead(entry)

  proc waitForEvent*(watcher: FilesystemWatcher): FilesystemWatchEvent =
    # Windows: matches kqueue's blocking semantics. First drain anything
    # already buffered, then wait on the entries' OVERLAPPED.hEvent set
    # until at least one fires. WaitForMultipleObjects(bWaitAll=FALSE)
    # returns WAIT_OBJECT_0 + index of the first signalled handle.
    collectCompleted(watcher)
    while watcher.pending.len == 0:
      if watcher.entries.len == 0:
        raise newException(OSError, "filesystem watcher has no entries")
      var handles: WOHandleArray
      var count: int32 = 0
      for entry in watcher.entries:
        if entry.readPending:
          handles[count] = entry.overlapped.hEvent
          count.inc
      if count == 0:
        # All entries somehow lost their pending read; re-post and retry.
        for entry in watcher.entries:
          postRead(entry)
        continue
      # Windows: INFINITE is signed int32(-1) in winlean but the API param
      # is DWORD; cast preserves the all-ones bit pattern that means "no
      # timeout". A 0xFFFFFFFF return value indicates WAIT_FAILED.
      let res = waitForMultipleObjects(DWORD(count),
        cast[PWOHandleArray](addr handles), WINBOOL(0), cast[DWORD](INFINITE))
      if res == cast[DWORD](0xFFFFFFFF'u32):
        raise newException(OSError,
          "WaitForMultipleObjects failed: error " & $getLastError())
      collectCompleted(watcher)
    result = watcher.pending.popFirst()

  proc drainDebouncedEvents*(watcher: FilesystemWatcher; debounceMs: int): int =
    # Windows: poll-and-coalesce, mirroring the kqueue zero-timeout drain.
    # During the debounce window we sleep, then sweep every entry for
    # already-completed notifications. The integer returned is the count
    # of additional events squashed, matching the kqueue contract.
    if debounceMs > 0:
      sleep(debounceMs)
    collectCompleted(watcher)
    result = watcher.pending.len
    watcher.pending.clear()

else:
  type
    FilesystemWatcher* = ref object

  proc openFilesystemWatcher*(paths: openArray[string]): FilesystemWatcher =
    raise newException(OSError,
      "repro watch currently supports macOS kqueue and Windows " &
        "ReadDirectoryChangesW only; Linux backend is deferred")

  proc closeFilesystemWatcher*(watcher: FilesystemWatcher) =
    discard

  proc watchedPathCount*(watcher: FilesystemWatcher): int =
    0

  proc waitForEvent*(watcher: FilesystemWatcher): FilesystemWatchEvent =
    raise newException(OSError,
      "repro watch currently supports macOS kqueue and Windows " &
        "ReadDirectoryChangesW only; Linux backend is deferred")

  proc drainDebouncedEvents*(watcher: FilesystemWatcher; debounceMs: int): int =
    0
