## Plaintext buffers locked in RAM (ReproOS Add-On Mode §10.3; owner
## decision 2026-10-31: plaintext secrets are kept out of swap by locking
## the buffers that hold them, on every host, with or without a cgroup
## memory controller).
##
## A ``LockedBytes`` is an anonymous private mapping of its own, locked with
## ``mlock(2)`` -- so no page of it is ever written to a swap device, zram
## included -- and marked ``MADV_DONTDUMP``. It is zeroed before it is
## unlocked and unmapped, and it cannot be copied (only moved), so the
## plaintext it holds exists exactly once and is gone when the buffer is.
## The add-on reads, decrypts, compares and writes plaintext only through
## such buffers, never through Nim strings or seqs, whose copies it would
## not control.
##
## Locking is bounded: a buffer is the size of what it holds (one sealed
## payload, one secret file being compared, one secret read from stdin),
## not the whole process (``mlockall``). A root process raises its own
## ``RLIMIT_MEMLOCK`` first (``raiseMemlockLimit``); when ``mlock`` still
## fails, ``newLockedBytes`` refuses with the reason unless the caller asked
## for best effort (the unit tests, which run unprivileged).

import std/posix

import ./mutations

var
  madvDontDump {.importc: "MADV_DONTDUMP", header: "<sys/mman.h>".}: cint
  rlimitMemlock {.importc: "RLIMIT_MEMLOCK", header: "<sys/resource.h>".}: cint
  rlimInfinity {.importc: "RLIM_INFINITY", header: "<sys/resource.h>".}: culong

proc c_madvise(a: pointer; len: csize_t; advice: cint): cint
  {.importc: "madvise", header: "<sys/mman.h>".}

type
  RLimitM {.importc: "struct rlimit", header: "<sys/resource.h>".} = object
    rlim_cur, rlim_max: culong
proc c_setrlimit(resource: cint; rlim: var RLimitM): cint
  {.importc: "setrlimit", header: "<sys/resource.h>".}

type
  LockedBufferError* = object of CatchableError
    ## A buffer could not be mapped or locked.

  LockedBytes* = object
    ## ``len`` bytes of plaintext at ``data``, locked in RAM when ``locked``.
    data*: ptr UncheckedArray[byte]
    len*: int
    mapped: int
    locked*: bool

proc `=destroy`*(b: LockedBytes) =
  if b.data != nil and b.mapped > 0:
    zeroMem(b.data, b.mapped)
    if b.locked: discard munlock(b.data, b.mapped)
    discard munmap(b.data, b.mapped)

proc `=copy`*(a: var LockedBytes; b: LockedBytes) {.error:
  "a LockedBytes holds plaintext exactly once: move it, never copy it".}

proc `=dup`*(b: LockedBytes): LockedBytes {.error:
  "a LockedBytes holds plaintext exactly once: move it, never copy it".}

proc raiseMemlockLimit*() =
  ## Lift this process's ``RLIMIT_MEMLOCK`` (root may; an unprivileged
  ## process keeps its limit). Best effort: a lock the limit still refuses
  ## is reported by ``newLockedBytes``.
  var rl = RLimitM(rlim_cur: rlimInfinity, rlim_max: rlimInfinity)
  discard c_setrlimit(rlimitMemlock, rl)

proc newLockedBytes*(n: int; requireLock: bool): LockedBytes =
  ## A zeroed buffer of ``n`` bytes in a mapping of its own, locked in RAM.
  ## With ``requireLock`` a failed ``mlock`` refuses (``LockedBufferError``
  ## naming the reason and the remedy); without it the buffer is returned
  ## unlocked (``locked`` false).
  if n < 0:
    raise newException(LockedBufferError, "negative buffer size")
  let page = int(sysconf(SC_PAGESIZE))
  let mapped = max(page, ((n + page - 1) div page) * page)
  let p = mmap(nil, mapped, PROT_READ or PROT_WRITE,
               MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
  if p == MAP_FAILED:
    raise newException(LockedBufferError, "cannot map " & $mapped &
      " bytes for plaintext: " & $strerror(errno))
  result = LockedBytes(data: cast[ptr UncheckedArray[byte]](p), len: n,
                       mapped: mapped)
  discard c_madvise(p, csize_t(mapped), madvDontDump)
  when mutated("secrets-plaintext-unlocked") or
       mutated("secrets-plaintext-swappable"):
    # FALSIFYING MUTATION: plaintext buffers are not locked, so their pages
    # may be swapped out under memory pressure.
    discard
  else:
    if mlock(p, mapped) == 0:
      result.locked = true
    elif requireLock:
      let e = errno
      raise newException(LockedBufferError, "cannot lock " & $mapped &
        " bytes of plaintext in RAM (mlock: " & $strerror(e) & "); the " &
        "process needs CAP_IPC_LOCK or an RLIMIT_MEMLOCK of at least that " &
        "(units that open sealed envelopes set LimitMEMLOCK=infinity)")

proc capacity*(b: LockedBytes): int = b.mapped

proc toPtr*(b: LockedBytes; off = 0): pointer =
  if b.len == 0: nil else: addr b.data[off]

proc grow*(b: var LockedBytes; n: int; requireLock: bool) =
  ## Make room for at least ``n`` bytes, keeping ``len`` and the contents:
  ## a larger locked buffer, the old contents moved over and the old
  ## buffer wiped (by its destructor).
  if n <= b.mapped: return
  var bigger = newLockedBytes(max(n, 2 * b.mapped), requireLock)
  if b.len > 0: copyMem(bigger.data, b.data, b.len)
  bigger.len = b.len
  b = move(bigger)

proc equalsAt*(b: LockedBytes; off, len: int; other: LockedBytes): bool =
  ## Whether ``len`` bytes of ``b`` at ``off`` equal ``other`` (in place,
  ## no copy).
  if other.len != len: return false
  len == 0 or equalMem(addr b.data[off], other.data, len)
