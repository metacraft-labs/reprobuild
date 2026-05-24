when not defined(linux):
  {.error: "repro_monitor_shim/linux_preload is Linux-only".}

import std/[locks, os, tables]
from repro_core/paths import extendedPath

import repro_monitor_depfile/types
import repro_monitor_depfile/writer
import repro_monitor_hooks/linux_preload_runtime

const
  OAccMode = 0x0003.cint
  OWrOnly = 0x0001.cint
  ORdWr = 0x0002.cint
  OCreat = 0x0040.cint
  OTrunc = 0x0200.cint
  OAppend = 0x0400.cint

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

var
  disabled {.threadvar.}: int
  inForkChild {.threadvar.}: bool

{.emit: """
#include <sys/syscall.h>
#include <unistd.h>
#include <errno.h>

long repro_linux_gettid(void) {
  return syscall(SYS_gettid);
}

int repro_linux_get_errno(void) {
  return errno;
}

void repro_linux_set_errno(int value) {
  errno = value;
}

extern int repro_monitor_shim_init(char *configPath);

__attribute__((constructor))
static void repro_linux_monitor_constructor(void) {
  repro_monitor_shim_init(NULL);
}
""".}

proc c_getpid(): cint {.importc: "getpid", header: "<unistd.h>".}
proc c_getppid(): cint {.importc: "getppid", header: "<unistd.h>".}
proc c_gettid(): clong {.importc: "repro_linux_gettid", raises: [].}
proc c_get_errno(): cint {.importc: "repro_linux_get_errno", raises: [].}
proc c_set_errno(value: cint) {.importc: "repro_linux_set_errno", raises: [].}

proc currentThreadId(): uint64 =
  uint64(c_gettid())

proc processSeq(): uint64 =
  acquire(recordLock)
  inc nextProcessSeq
  result = nextProcessSeq
  release(recordLock)

template withShimMuted(body: untyped) =
  inc disabled
  try:
    try:
      body
    except CatchableError:
      discard
  finally:
    dec disabled

proc shouldBypass(): bool {.inline, raises: [].} =
  disabled > 0 or inForkChild

proc baseRecord(kind: MonitorRecordKind;
                observationKind: MonitorObservationKind): MonitorRecord =
  MonitorRecord(
    kind: kind,
    observationKind: observationKind,
    seq: processSeq(),
    osPid: uint64(c_getpid()),
    parentOsPid: uint64(c_getppid()),
    threadId: currentThreadId(),
    probeResult: prUnknown)

proc emitRecord(record: MonitorRecord) {.raises: [].} =
  if not initialized or fragmentDir.len == 0 or shouldBypass():
    return
  withShimMuted:
    appendFragmentRecord(fragmentDir, record)

proc recordProcessStart() {.raises: [].} =
  var record = baseRecord(mrProcessStart, moProcessStart)
  record.detail = "linux-preload-hooks"
  emitRecord(record)

proc repro_monitor_shim_init*(configPath: cstring): cint
    {.exportc, dynlib, raises: [].}

proc ensureInitialized() {.raises: [].} =
  if not initialized:
    discard repro_monitor_shim_init(nil)

proc ensureInitializedPreservingErrno() {.raises: [].} =
  let savedErrno = c_get_errno()
  ensureInitialized()
  c_set_errno(savedErrno)

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

proc repro_monitor_shim_init*(configPath: cstring): cint
    {.exportc, dynlib, raises: [].} =
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
      createDir(extendedPath(fragmentDir))
  initialized = true
  recordProcessStart()
  result = 0

proc repro_monitor_shim_flush*(): cint {.exportc, dynlib, raises: [].} = 0
proc repro_monitor_shim_shutdown*(): cint {.exportc, dynlib, raises: [].} = 0
proc repro_monitor_shim_disable_current_thread*() {.exportc, dynlib, raises: [].} =
  inc disabled
proc repro_monitor_shim_enable_current_thread*() {.exportc, dynlib, raises: [].} =
  if disabled > 0:
    dec disabled
proc repro_monitor_shim_version*(): cstring {.exportc, dynlib, raises: [].} =
  "repro_monitor_shim_m11"

proc recordOpen(path: cstring; flags, mode, fd: cint) {.raises: [].} =
  updateFdPath(fd, path)
  var record = baseRecord(mrFileOpen, observationForOpen(flags))
  record.result = fd.int64
  record.flags = uint32(flags)
  if path != nil:
    record.path = $path
  emitRecord(record)

proc repro_hook_open*(ctx: var OpenContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  callNext(ctx)
  let savedErrno = c_get_errno()
  recordOpen(ctx.path, ctx.flags, ctx.mode, ctx.result)
  c_set_errno(savedErrno)

proc repro_hook_open64*(ctx: var OpenContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  callNext(ctx)
  let savedErrno = c_get_errno()
  recordOpen(ctx.path, ctx.flags, ctx.mode, ctx.result)
  c_set_errno(savedErrno)

proc repro_hook_openat*(ctx: var OpenatContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  callNext(ctx)
  let savedErrno = c_get_errno()
  recordOpen(ctx.path, ctx.flags, ctx.mode, ctx.result)
  c_set_errno(savedErrno)

proc repro_hook_openat64*(ctx: var OpenatContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  callNext(ctx)
  let savedErrno = c_get_errno()
  recordOpen(ctx.path, ctx.flags, ctx.mode, ctx.result)
  c_set_errno(savedErrno)

proc repro_hook_read*(ctx: var ReadContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  callNext(ctx)
  let savedErrno = c_get_errno()
  if ctx.result >= 0:
    var record = baseRecord(mrFileRead, moFileRead)
    record.path = pathForFd(ctx.fd)
    record.result = ctx.result.int64
    record.flags = uint32(ctx.fd)
    emitRecord(record)
  c_set_errno(savedErrno)

proc repro_hook_write*(ctx: var WriteContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  callNext(ctx)
  let savedErrno = c_get_errno()
  if ctx.result >= 0 and ctx.fd > 2:
    var record = baseRecord(mrFileWrite, moFileWrite)
    record.path = pathForFd(ctx.fd)
    record.result = ctx.result.int64
    record.flags = uint32(ctx.fd)
    emitRecord(record)
  c_set_errno(savedErrno)

proc repro_hook_close*(ctx: var CloseContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  callNext(ctx)
  let savedErrno = c_get_errno()
  removeFdPath(ctx.fd)
  c_set_errno(savedErrno)

proc emitProbe(path: cstring; callResult: cint) {.raises: [].} =
  var record = baseRecord(mrPathProbe, moPathProbe)
  record.result = callResult.int64
  record.probeResult = probeFromResult(callResult)
  if path != nil:
    record.path = $path
  emitRecord(record)

proc repro_hook_stat*(ctx: var StatContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  callNext(ctx)
  let savedErrno = c_get_errno()
  emitProbe(ctx.path, ctx.result)
  c_set_errno(savedErrno)

proc repro_hook_lstat*(ctx: var StatContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  callNext(ctx)
  let savedErrno = c_get_errno()
  emitProbe(ctx.path, ctx.result)
  c_set_errno(savedErrno)

proc repro_hook_opendir*(ctx: var OpendirContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  callNext(ctx)
  let savedErrno = c_get_errno()
  updateDirPath(ctx.result, ctx.path)
  c_set_errno(savedErrno)

proc repro_hook_readdir*(ctx: var ReaddirContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  let dirPath = pathForDir(ctx.dirp)
  callNext(ctx)
  let savedErrno = c_get_errno()
  if ctx.result != nil:
    var record = baseRecord(mrDirectoryEnumerate, moDirectoryEnumerate)
    record.path = dirPath
    record.result = 1
    record.detail = "readdir"
    emitRecord(record)
  c_set_errno(savedErrno)

proc repro_hook_closedir*(ctx: var ClosedirContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  callNext(ctx)
  let savedErrno = c_get_errno()
  removeDirPath(ctx.dirp)
  c_set_errno(savedErrno)

proc repro_hook_fork*(ctx: var ForkContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  callNext(ctx)
  let savedErrno = c_get_errno()
  if ctx.result > 0:
    var record = baseRecord(mrProcessSpawn, moExecute)
    record.childOsPid = uint64(ctx.result)
    record.result = ctx.result.int64
    record.detail = "fork"
    emitRecord(record)
  elif ctx.result == 0:
    # After fork only the calling thread survives. Other threads may have held
    # Nim locks when fork happened, so the child must avoid monitor bookkeeping
    # until exec loads a fresh image and runs the preload constructor again.
    inForkChild = true
  c_set_errno(savedErrno)

proc repro_hook_execve*(ctx: var ExecveContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  var record = baseRecord(mrProcessExec, moExecute)
  if ctx.path != nil:
    record.path = $ctx.path
  emitRecord(record)
  ctx.envp = envWithPreload(ctx.envp)
  callNext(ctx)

proc repro_hook_posix_spawn*(ctx: var PosixSpawnContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  ctx.envp = envWithPreload(ctx.envp)
  callNext(ctx)
  let savedErrno = c_get_errno()
  if ctx.result == 0 and ctx.pid != nil:
    var record = baseRecord(mrProcessSpawn, moExecute)
    record.childOsPid = uint64(ctx.pid[])
    record.result = ctx.result.int64
    if ctx.path != nil:
      record.path = $ctx.path
    record.detail = "posix_spawn"
    emitRecord(record)
  c_set_errno(savedErrno)

proc repro_hook_posix_spawnp*(ctx: var PosixSpawnContext) {.raises: [].} =
  if shouldBypass():
    callNext(ctx)
    return
  ensureInitializedPreservingErrno()
  ctx.envp = envWithPreload(ctx.envp)
  callNext(ctx)
  let savedErrno = c_get_errno()
  if ctx.result == 0 and ctx.pid != nil:
    var record = baseRecord(mrProcessSpawn, moExecute)
    record.childOsPid = uint64(ctx.pid[])
    record.result = ctx.result.int64
    if ctx.path != nil:
      record.path = $ctx.path
    record.detail = "posix_spawnp"
    emitRecord(record)
  c_set_errno(savedErrno)

setPreloadShimEnvVar("REPRO_MONITOR_SHIM_LIB")
registerOpenHook(repro_hook_open)
registerOpen64Hook(repro_hook_open64)
registerOpenatHook(repro_hook_openat)
registerOpenat64Hook(repro_hook_openat64)
registerReadHook(repro_hook_read)
registerWriteHook(repro_hook_write)
registerCloseHook(repro_hook_close)
registerStatHook(repro_hook_stat)
registerLstatHook(repro_hook_lstat)
registerOpendirHook(repro_hook_opendir)
registerReaddirHook(repro_hook_readdir)
registerClosedirHook(repro_hook_closedir)
registerForkHook(repro_hook_fork)
registerExecveHook(repro_hook_execve)
registerPosixSpawnHook(repro_hook_posix_spawn)
registerPosixSpawnpHook(repro_hook_posix_spawnp)
