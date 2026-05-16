when not defined(macosx):
  {.error: "repro_monitor_shim/macos_interpose is macOS-only".}

import std/[locks, os, tables]

import ct_interpose/macos_interpose_runtime
import repro_monitor_depfile/types
import repro_monitor_depfile/writer

const
  OAccMode = 0x0003.cint
  OWrOnly = 0x0001.cint
  ORdWr = 0x0002.cint
  OCreat = 0x0200.cint
  OTrunc = 0x0400.cint
  OAppend = 0x0008.cint

var
  initialized = false
  locksReady = false
  initLockVar: Lock
  recordLock: Lock
  fdLock: Lock
  dirLock: Lock
  fragmentDir: string
  nextProcessSeq: uint64 = 0
  fdPaths = initTable[cint, string]()
  dirPaths = initTable[uint, string]()

var disabled {.threadvar.}: int

proc c_getpid(): cint {.importc: "getpid", header: "<unistd.h>".}
proc c_getppid(): cint {.importc: "getppid", header: "<unistd.h>".}
proc pthread_threadid_np(thread: pointer; threadId: ptr uint64): cint
  {.importc: "pthread_threadid_np", header: "<pthread.h>".}

proc currentThreadId(): uint64 =
  var tid: uint64 = 0
  if pthread_threadid_np(nil, addr tid) == 0:
    result = tid

proc processSeq(): uint64 =
  acquire(recordLock)
  inc nextProcessSeq
  result = nextProcessSeq
  release(recordLock)

template withShimMuted(body: untyped) =
  inc disabled
  try:
    body
  except CatchableError:
    discard
  dec disabled

proc baseRecord(kind: MonitorRecordKind; observationKind: MonitorObservationKind): MonitorRecord =
  MonitorRecord(
    kind: kind,
    observationKind: observationKind,
    seq: processSeq(),
    osPid: uint64(c_getpid()),
    parentOsPid: uint64(c_getppid()),
    threadId: currentThreadId(),
    probeResult: prUnknown)

proc emitRecord(record: MonitorRecord) {.raises: [].} =
  if not initialized or fragmentDir.len == 0 or disabled > 0:
    return
  withShimMuted:
    appendFragmentRecord(fragmentDir, record)

proc recordProcessStart() {.raises: [].} =
  var record = baseRecord(mrProcessStart, moProcessStart)
  record.detail = "shim-loaded"
  emitRecord(record)

proc observationForOpen(flags: cint): MonitorObservationKind =
  if (flags and (OCreat or OTrunc or OAppend)) != 0:
    moFileWrite
  else:
    let acc = flags and OAccMode
    if acc == OWrOnly or acc == ORdWr:
      moFileWrite
    else:
      moFileOpen

proc updateFdPath(fd: cint; path: cstring) =
  if fd < 0 or path == nil:
    return
  acquire(fdLock)
  fdPaths[fd] = $path
  release(fdLock)

proc removeFdPath(fd: cint) =
  acquire(fdLock)
  fdPaths.del(fd)
  release(fdLock)

proc pathForFd(fd: cint): string =
  acquire(fdLock)
  result = fdPaths.getOrDefault(fd, "")
  release(fdLock)

proc dirKey(dirp: pointer): uint =
  cast[uint](dirp)

proc updateDirPath(dirp: pointer; path: cstring) =
  if dirp == nil or path == nil:
    return
  acquire(dirLock)
  dirPaths[dirKey(dirp)] = $path
  release(dirLock)

proc removeDirPath(dirp: pointer) =
  acquire(dirLock)
  dirPaths.del(dirKey(dirp))
  release(dirLock)

proc pathForDir(dirp: pointer): string =
  acquire(dirLock)
  result = dirPaths.getOrDefault(dirKey(dirp), "")
  release(dirLock)

proc probeFromResult(callResult: cint): ProbeResult =
  if callResult == 0:
    prExistingOther
  else:
    prAbsent

proc repro_monitor_shim_init*(configPath: cstring): cint {.exportc, dynlib.} =
  if not locksReady:
    initLock(initLockVar)
    initLock(recordLock)
    initLock(fdLock)
    initLock(dirLock)
    locksReady = true
  acquire(initLockVar)
  defer: release(initLockVar)
  if initialized:
    return 0
  withShimMuted:
    fragmentDir = getEnv("REPRO_MONITOR_FRAGMENT_DIR")
    if fragmentDir.len > 0:
      createDir(fragmentDir)
  initialized = true
  recordProcessStart()
  result = 0

proc repro_monitor_shim_flush*(): cint {.exportc, dynlib.} = 0
proc repro_monitor_shim_shutdown*(): cint {.exportc, dynlib.} = 0
proc repro_monitor_shim_disable_current_thread*() {.exportc, dynlib.} = inc disabled
proc repro_monitor_shim_enable_current_thread*() {.exportc, dynlib.} =
  if disabled > 0:
    dec disabled
proc repro_monitor_shim_version*(): cstring {.exportc, dynlib.} =
  "repro_monitor_shim_m11"

proc repro_hook_open*(path: cstring; flags, mode: cint): cint {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_open(path, flags, mode)
  result = ct_macos_interpose_real_open(path, flags, mode)
  updateFdPath(result, path)
  var record = baseRecord(mrFileOpen, observationForOpen(flags))
  record.result = result.int64
  record.flags = uint32(flags)
  if path != nil:
    record.path = $path
  emitRecord(record)

proc repro_hook_openat*(dirfd: cint; path: cstring; flags, mode: cint): cint
    {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_openat(dirfd, path, flags, mode)
  result = ct_macos_interpose_real_openat(dirfd, path, flags, mode)
  updateFdPath(result, path)
  var record = baseRecord(mrFileOpen, observationForOpen(flags))
  record.result = result.int64
  record.flags = uint32(flags)
  if path != nil:
    record.path = $path
  record.detail = "dirfd=" & $dirfd
  emitRecord(record)

proc repro_hook_read*(fd: cint; buf: pointer; count: csize_t): int {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_read(fd, buf, count)
  result = ct_macos_interpose_real_read(fd, buf, count)
  if result >= 0:
    var record = baseRecord(mrFileRead, moFileRead)
    record.path = pathForFd(fd)
    record.result = result.int64
    record.flags = uint32(fd)
    emitRecord(record)

proc repro_hook_write*(fd: cint; buf: pointer; count: csize_t): int {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_write(fd, buf, count)
  result = ct_macos_interpose_real_write(fd, buf, count)
  if result >= 0 and fd > 2:
    var record = baseRecord(mrFileWrite, moFileWrite)
    record.path = pathForFd(fd)
    record.result = result.int64
    record.flags = uint32(fd)
    emitRecord(record)

proc repro_hook_close*(fd: cint): cint {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_close(fd)
  result = ct_macos_interpose_real_close(fd)
  removeFdPath(fd)

proc repro_hook_opendir*(path: cstring): pointer {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_opendir(path)
  inc disabled
  try:
    result = ct_macos_interpose_real_opendir(path)
  finally:
    dec disabled
  if result != nil:
    updateDirPath(result, path)

proc repro_hook_readdir*(dirp: pointer): pointer {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_readdir(dirp)
  let dirPath = pathForDir(dirp)
  inc disabled
  try:
    result = ct_macos_interpose_real_readdir(dirp)
  finally:
    dec disabled
  if result != nil:
    var record = baseRecord(mrDirectoryEnumerate, moDirectoryEnumerate)
    record.path = dirPath
    record.result = 1
    record.detail = "readdir"
    emitRecord(record)

proc repro_hook_closedir*(dirp: pointer): cint {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_closedir(dirp)
  inc disabled
  try:
    result = ct_macos_interpose_real_closedir(dirp)
  finally:
    dec disabled
  removeDirPath(dirp)

proc repro_hook_stat*(path: cstring; buf: pointer): cint {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_stat(path, buf)
  result = ct_macos_interpose_real_stat(path, buf)
  var record = baseRecord(mrPathProbe, moPathProbe)
  record.result = result.int64
  record.probeResult = probeFromResult(result)
  if path != nil:
    record.path = $path
  emitRecord(record)

proc repro_hook_lstat*(path: cstring; buf: pointer): cint {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_lstat(path, buf)
  result = ct_macos_interpose_real_lstat(path, buf)
  var record = baseRecord(mrPathProbe, moPathProbe)
  record.result = result.int64
  record.probeResult = probeFromResult(result)
  if path != nil:
    record.path = $path
  emitRecord(record)

proc repro_hook_fork*(): PidT {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_fork()
  result = ct_macos_interpose_real_fork()
  if result > 0:
    var record = baseRecord(mrProcessSpawn, moExecute)
    record.childOsPid = uint64(result)
    record.result = result.int64
    record.detail = "fork"
    emitRecord(record)
  elif result == 0:
    recordProcessStart()

proc repro_hook_execve*(path: cstring; argv, envp: cstringArray): cint
    {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_execve(path, argv, envp)
  var record = baseRecord(mrProcessExec, moExecute)
  if path != nil:
    record.path = $path
  emitRecord(record)
  result = ct_macos_interpose_real_execve(path, argv, envp)

proc repro_hook_posix_spawn*(pid: ptr PidT; path: cstring; fileActions, attrp: pointer;
    argv, envp: cstringArray): cint {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_posix_spawn(pid, path, fileActions, attrp, argv, envp)
  result = ct_macos_interpose_real_posix_spawn(pid, path, fileActions, attrp, argv, envp)
  if result == 0 and pid != nil:
    var record = baseRecord(mrProcessSpawn, moExecute)
    record.childOsPid = uint64(pid[])
    record.result = result.int64
    if path != nil:
      record.path = $path
    record.detail = "posix_spawn"
    emitRecord(record)

proc repro_hook_posix_spawnp*(pid: ptr PidT; path: cstring; fileActions, attrp: pointer;
    argv, envp: cstringArray): cint {.exportc, cdecl, dynlib.} =
  if disabled > 0 or not initialized:
    return ct_macos_interpose_real_posix_spawnp(pid, path, fileActions, attrp, argv, envp)
  result = ct_macos_interpose_real_posix_spawnp(pid, path, fileActions, attrp, argv, envp)
  if result == 0 and pid != nil:
    var record = baseRecord(mrProcessSpawn, moExecute)
    record.childOsPid = uint64(pid[])
    record.result = result.int64
    if path != nil:
      record.path = $path
    record.detail = "posix_spawnp"
    emitRecord(record)

proc reproRuntimeInit() =
  discard repro_monitor_shim_init(nil)

registerInitCallback(reproRuntimeInit)
registerOpenHook(repro_hook_open)
registerOpenatHook(repro_hook_openat)
registerReadHook(repro_hook_read)
registerWriteHook(repro_hook_write)
registerCloseHook(repro_hook_close)
registerOpendirHook(repro_hook_opendir)
registerReaddirHook(repro_hook_readdir)
registerClosedirHook(repro_hook_closedir)
registerStatHook(repro_hook_stat)
registerLstatHook(repro_hook_lstat)
registerForkHook(repro_hook_fork)
registerExecveHook(repro_hook_execve)
registerPosixSpawnHook(repro_hook_posix_spawn)
registerPosixSpawnpHook(repro_hook_posix_spawnp)
