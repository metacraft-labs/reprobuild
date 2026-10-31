## Snapshot index mutations require a real cross-process lock.
##
## No mocks: actual SnapshotStore publication/sweep and CAS, real unique
## temporary directories, and a separate process making a one-shot native
## nonblocking lock attempt. A directory at the lock-file path forces a real
## open failure on every tested uid, including root; no permission simulation.
## The manifests are structurally valid storage-test records with opaque tree
## ids, not claims that a Git checkout or remote execution was qualified.
##
## The raw contender is intentionally independent of the extracted lock API:
## while the parent API holds the lock it must observe the kernel's BUSY error,
## and after release it must acquire. No scheduler-delay inference or sleeps.
## This does not test close-on-exec inheritance: the ordinary process launcher
## could close handles itself. O_CLOEXEC / noninheritable Windows handles remain
## source guarantees pending a properly inheriting native control.

import std/[os, osproc, strutils, tempfiles, unittest]

import blake3
import repro_core/file_lock
import repro_peer_cache/snapshot_blobs
import repro_workspace_snapshot/manifest
from repro_workspace_snapshot/git_tree import gitBlobOid

const
  RawProbeFlag = "--snapshot-index-raw-lock-probe"
  ProbeAcquired = 0
  ProbeBusy = 73
  ProbeError = 74

when defined(windows):
  type RawHandle = pointer
  proc rawCreateFileW(path: WideCString; access, sharing: uint32;
      security: pointer; disposition, flags: uint32;
      templateFile: RawHandle): RawHandle
    {.stdcall, dynlib: "kernel32", importc: "CreateFileW".}
  proc rawCloseHandle(handle: RawHandle): int32
    {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}
  proc rawGetLastError(): uint32
    {.stdcall, dynlib: "kernel32", importc: "GetLastError".}

  proc rawTryLock(path: string): int =
    # One nonblocking kernel attempt, not the API's retry/acquisition logic.
    let handle = rawCreateFileW(newWideCString(path), 0xC0000000'u32,
      0, nil, 4'u32, 0x80'u32, nil)
    if cast[int](handle) != -1:
      discard rawCloseHandle(handle)
      echo "ACQUIRED"
      return ProbeAcquired
    let error = rawGetLastError()
    if error == 32'u32: # ERROR_SHARING_VIOLATION, not arbitrary access failure
      echo "BUSY GetLastError=", error
      return ProbeBusy
    echo "ERROR GetLastError=", error
    ProbeError
else:
  import std/posix
  proc rawFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

  proc rawTryLock(path: string): int =
    let fd = posix.open(path.cstring, O_RDWR or O_CREAT or O_CLOEXEC, Mode(0o600))
    if fd < 0:
      echo "ERROR open errno=", errno
      return ProbeError
    defer: discard posix.close(fd)
    if rawFlock(fd, 2.cint or 4.cint) == 0: # LOCK_EX | LOCK_NB
      echo "ACQUIRED"
      return ProbeAcquired
    let error = errno
    if error == EWOULDBLOCK or error == EAGAIN:
      echo "BUSY errno=", error
      return ProbeBusy
    echo "ERROR flock errno=", error
    ProbeError

if paramCount() == 2 and paramStr(1) == RawProbeFlag:
  quit(rawTryLock(paramStr(2)))

proc kernelProbe(path: string): tuple[output: string; exitCode: int] =
  # The child always uses a nonblocking kernel operation, so the parent's
  # returned lock is tested directly rather than inferred from delayed work.
  execCmdEx(quoteShellCommand([getAppFilename(), RawProbeFlag, path]))

proc emptyManifest(tag: string): WorkspaceSnapshotManifest =
  WorkspaceSnapshotManifest(schema: ManifestSchema,
    primaryRepo: RepoSnapshot(repoId: tag, baseCommitSha: repeat('a', 40),
      gitTreeSha1: repeat('b', 40)))

proc lockPath(store: SnapshotStore): string =
  store.root / "snapshots.index.lock"

suite "snapshot index locking fails closed":
  test "failed lock-file open cannot enter publication or sweep mutations":
    let root = createTempDir("repro-snapshot-lock-failure-", "")
    defer: removeDir(root)
    let failed = openSnapshotStore(root / "failed-publication")
    defer: failed.close()
    let m = emptyManifest("failed-open")
    require validateManifest(m) == ""
    let digest = blake3.digest(encodeManifest(m))
    createDir(failed.lockPath())
    var raised = false
    try:
      discard failed.publishSnapshot(m)
    except IOError:
      raised = true
    check raised
    check not failed.hasBlob(digest) # no CAS write from the protected body
    check not fileExists(failed.root / "snapshots.index")

    let seeded = openSnapshotStore(root / "failed-sweep")
    defer: seeded.close()
    discard seeded.publishSnapshot(m)
    require seeded.hasBlob(digest)
    let before = readFile(seeded.root / "snapshots.index")
    if fileExists(seeded.lockPath()): removeFile(seeded.lockPath())
    createDir(seeded.lockPath())
    # Use the real clock and the API's explicit zero-retention policy; this
    # tests exclusion, not elapsed retention. Nothing sleeps or fakes time.
    check seeded.sweepSnapshotStore(retentionSeconds = 0) == 0
    check seeded.hasBlob(digest)
    check readFile(seeded.root / "snapshots.index") == before
    # Positive control: once acquisition can succeed, the same real sweep
    # policy actually expires this publication rather than always doing nothing.
    removeDir(seeded.lockPath())
    check seeded.sweepSnapshotStore(retentionSeconds = 0) > 0
    check not seeded.hasBlob(digest)

  test "a kernel contender is excluded while the API holds the lock":
    let root = createTempDir("repro-snapshot-lock-contender-", "")
    defer: removeDir(root)
    let path = root / "index.lock"
    var held = acquireExclusiveFileLock(path)
    try:
      let blocked = kernelProbe(path)
      checkpoint blocked.output
      check blocked.exitCode == ProbeBusy
      check blocked.output.startsWith("BUSY ")
      var second: ReproFileLock
      try:
        check not tryAcquireExclusiveFileLock(path, second)
      finally:
        releaseExclusiveFileLock(second)
    finally:
      releaseExclusiveFileLock(held)
    releaseExclusiveFileLock(held) # idempotent; must not close another resource
    let free = kernelProbe(path)
    checkpoint free.output
    check free.exitCode == ProbeAcquired
    check free.output.strip() == "ACQUIRED"
    var next: ReproFileLock
    require tryAcquireExclusiveFileLock(path, next)
    releaseExclusiveFileLock(next)

  test "a publication exception releases the actual caller's index lock":
    let root = createTempDir("repro-snapshot-lock-exception-", "")
    defer: removeDir(root)
    let store = openSnapshotStore(root / "store")
    defer: store.close()
    var m = emptyManifest("missing-blob")
    let missing = @[byte 1, 2, 3, 4]
    let missingDigest = blake3.digest(missing)
    m.primaryRepo.modified = @[ModifiedFileEntry(relPath: "missing.bin",
      mode: ModeRegular, gitOid: gitBlobOid(missing),
      blake3Digest: missingDigest, size: uint64(missing.len))]
    require validateManifest(m) == ""
    require not store.hasBlob(missingDigest)
    let manifestDigest = blake3.digest(encodeManifest(m))
    var raised = false
    try:
      discard store.publishSnapshot(m)
    except ValueError as err:
      check "is not in the snapshot store" in err.msg
      raised = true
    check raised
    # The actual protected body stored the manifest before the missing-blob
    # refusal. Orphan manifest rollback is not the contract this test asserts.
    check store.hasBlob(manifestDigest)
    check not fileExists(store.root / "snapshots.index")
    let free = kernelProbe(store.lockPath())
    checkpoint free.output
    check free.exitCode == ProbeAcquired
    check free.output.strip() == "ACQUIRED"
