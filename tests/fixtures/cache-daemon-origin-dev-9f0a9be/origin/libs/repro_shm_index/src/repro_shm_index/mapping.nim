## File-backed `mmap` MAP_SHARED region lifecycle (create / attach / detach).
##
## A `MappedRegion` owns a fixed-size file mapped `PROT_READ|PROT_WRITE`,
## MAP_SHARED, so every process that maps the same path sees the same bytes.
## Creation is race-tolerant: the file is grown to `size` with `ftruncate`
## before mapping, and a fresh region is created via a temp-file + atomic
## `rename()` so a concurrent attacher never sees a half-initialised file.

import std/[os, posix, times]

import ./atomics_shm

type
  MappedRegion* = object
    base*: ShmBase       ## mapped base (offsets are relative to this)
    size*: int           ## byte length of the mapping
    fd: cint             ## backing file descriptor (kept open for the mapping)
    path*: string        ## backing file path

proc isValid*(r: MappedRegion): bool {.inline.} =
  not r.base.isNil and r.size > 0

proc mapFd(fd: cint; size: int): ShmBase =
  let p = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0)
  if p == MAP_FAILED:
    return nil
  cast[ShmBase](p)

proc attachRegion*(path: string; size: int): MappedRegion =
  ## Attach to an EXISTING backing file of exactly `size` bytes. Returns an
  ## invalid region (base=nil) if the file is missing or the wrong size.
  result.path = path
  result.size = size
  result.fd = -1
  if not fileExists(path):
    return
  if int(getFileSize(path)) != size:
    return
  let fd = open(path.cstring, O_RDWR)
  if fd < 0:
    return
  let p = mapFd(fd, size)
  if p.isNil:
    discard close(fd)
    return
  result.fd = fd
  result.base = p

proc createRegionAtomically*(path: string; size: int): MappedRegion =
  ## Create a fresh, zero-filled backing file of `size` bytes and map it.
  ## Written to a unique temp file then `rename()`d into place so a concurrent
  ## attacher either sees the old file or the fully-sized new one — never a
  ## partially-truncated file. If a concurrent creator wins the rename, the
  ## caller re-attaches the winner's file.
  result.path = path
  result.size = size
  result.fd = -1
  createDir(parentDir(path))
  let uniq = int(epochTime() * 1_000_000) mod 1_000_000
  let tmp = path & ".tmp." & $getCurrentProcessId() & "." & $uniq
  let tfd = open(tmp.cstring, O_RDWR or O_CREAT or O_EXCL, 0o600)
  if tfd < 0:
    return
  if ftruncate(tfd, Off(size)) != 0:
    discard close(tfd)
    removeFile(tmp)
    return
  discard close(tfd)
  # Atomic publish. `moveFile` maps to rename(2) on POSIX.
  try:
    moveFile(tmp, path)
  except OSError:
    removeFile(tmp)
    return
  result = attachRegion(path, size)

proc detach*(r: var MappedRegion) =
  ## Unmap and close. Does NOT unlink the backing file (the region survives for
  ## other processes; the daemon unlinks reclaimed segments in AC-2b).
  if not r.base.isNil:
    discard munmap(cast[pointer](r.base), r.size)
    r.base = nil
  if r.fd >= 0:
    discard close(r.fd)
    r.fd = -1

proc syncRegion*(r: MappedRegion) =
  ## Flush dirty pages to the backing file (best-effort; a shm cache needs
  ## consistency, not durability, so callers rarely need this).
  if not r.base.isNil:
    discard msync(cast[pointer](r.base), r.size, MS_ASYNC)
