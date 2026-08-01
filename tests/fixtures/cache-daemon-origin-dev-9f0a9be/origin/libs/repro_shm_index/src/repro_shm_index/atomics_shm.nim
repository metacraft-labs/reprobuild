## Offset-addressed atomic primitives over an `mmap`'d shared region.
##
## Everything in the shared-memory action index is addressed by a BYTE OFFSET
## from the mapped base — never by an absolute pointer — so a process that maps
## the region at any base observes a correct structure (Action-Cache-Per-Edge-
## Store.md §4.1). These helpers turn a `(base, offset)` pair into a typed
## atomic access using the C11/GCC atomic builtins Nim exposes
## (`atomicLoadN` / `atomicStoreN` / `atomicCompareExchangeN` /
## `atomicAddFetch`). No process-shared mutex is ever used.

when not (defined(linux) or defined(macosx)):
  {.error: "atomics_shm is POSIX-only; guard imports with shmIndexSupported".}

type
  ShmBase* = ptr UncheckedArray[byte]
    ## The mapped base of the shared region; offsets are relative to this.

template atField[T](base: ShmBase; offset: int): ptr T =
  ## The typed lvalue at `base + offset`. Callers guarantee `offset` is
  ## naturally aligned for `T` (the layout constants below enforce this).
  cast[ptr T](addr base[offset])

# --- 64-bit atomics -------------------------------------------------------

proc loadU64Acquire*(base: ShmBase; offset: int): uint64 {.inline.} =
  atomicLoadN(atField[uint64](base, offset), ATOMIC_ACQUIRE)

proc loadU64Relaxed*(base: ShmBase; offset: int): uint64 {.inline.} =
  atomicLoadN(atField[uint64](base, offset), ATOMIC_RELAXED)

proc storeU64Release*(base: ShmBase; offset: int; value: uint64) {.inline.} =
  atomicStoreN(atField[uint64](base, offset), value, ATOMIC_RELEASE)

proc storeU64Relaxed*(base: ShmBase; offset: int; value: uint64) {.inline.} =
  atomicStoreN(atField[uint64](base, offset), value, ATOMIC_RELAXED)

proc casU64*(base: ShmBase; offset: int; expected: var uint64;
    desired: uint64): bool {.inline.} =
  ## Strong compare-and-swap with acq_rel success / acquire failure ordering.
  ## On failure `expected` is updated to the observed value (GCC semantics).
  atomicCompareExchangeN(atField[uint64](base, offset), addr expected, desired,
    false, ATOMIC_ACQ_REL, ATOMIC_ACQUIRE)

proc fetchAddU64*(base: ShmBase; offset: int; delta: uint64): uint64 {.inline.} =
  ## Returns the NEW value after adding `delta` (atomicAddFetch semantics).
  atomicAddFetch(atField[uint64](base, offset), delta, ATOMIC_SEQ_CST)

# --- 32-bit atomics -------------------------------------------------------

proc loadU32Acquire*(base: ShmBase; offset: int): uint32 {.inline.} =
  atomicLoadN(atField[uint32](base, offset), ATOMIC_ACQUIRE)

proc storeU32Release*(base: ShmBase; offset: int; value: uint32) {.inline.} =
  atomicStoreN(atField[uint32](base, offset), value, ATOMIC_RELEASE)

proc casU32*(base: ShmBase; offset: int; expected: var uint32;
    desired: uint32): bool {.inline.} =
  atomicCompareExchangeN(atField[uint32](base, offset), addr expected, desired,
    false, ATOMIC_ACQ_REL, ATOMIC_ACQUIRE)

# --- non-atomic byte access (payload copies inside a seqlock window) -------

proc copyIn*(base: ShmBase; offset: int; src: openArray[byte]) {.inline.} =
  ## Non-atomic bulk write of `src` into the region at `offset`. Only valid
  ## between a seqlock odd->even transition (writer-exclusive) or before the
  ## slot is published, so no reader can observe a partial copy as stable.
  if src.len > 0:
    copyMem(addr base[offset], unsafeAddr src[0], src.len)

proc copyOut*(base: ShmBase; offset: int; dst: var openArray[byte];
    count: int) {.inline.} =
  ## Non-atomic bulk read of `count` bytes from `offset` into `dst`. Callers
  ## re-validate a seqlock `seq` afterwards to reject a torn snapshot.
  if count > 0:
    copyMem(addr dst[0], addr base[offset], count)
