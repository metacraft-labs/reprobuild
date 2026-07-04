# repro_shm_index

Shared-memory action-cache **hot-tier data structures** (AC-2a of
[Action-Cache-Per-Edge-Store.md](../../../reprobuild-specs/Action-Cache-Per-Edge-Store.md)
§4). Pure data structures only — no daemon logic (AC-2b) and no engine wiring
(AC-2c).

## What it provides

- **Control region** `action-index.ctl` — a fixed-size, file-backed `mmap`
  MAP_SHARED region: self-describing header (magic / formatVersion /
  creatorBootId), atomic `currentGeneration`, daemon pid + heartbeat, a
  reader-epoch table (`readerEpochs[MAX_READERS]` for RCU reclamation), and the
  MPSC submission ring. Created/attached with a **version + boot guard** that
  recreates the region empty on mismatch or corruption.
- **Generation segment** `action-index.<gen>.seg` — a fixed open-addressed slot
  array `{ keyDigest(32B), seq(u64 seqlock), recLen(u16), recBytes[256] }`
  holding metadata-only records. Oversized records (> `SlotInlineCap`) are
  reported not-shm-cacheable (the caller falls to Tier-1 disk).

## Primitives

- **Lock-free seqlock read** (`lookupSlot`): snapshot `seq` (acquire); odd ⇒
  being-written; copy `recBytes`; re-load `seq` and accept only if unchanged +
  even. A raced slot yields a retry status.
- **Single-writer slot write** (`writeSlot`): `seq` even→odd (release), write
  keyDigest + record, `seq`→next-even (release). Exposed here for the AC-2a
  test stand-in consumer; the real writer is the AC-2b daemon.
- **Open-addressed probe** (linear) for lookup/insert by keyDigest; `evictSlot`
  is the eviction *mechanism* (the policy is AC-2b).
- **MPSC ring**: `append` reserves a ticket by CAS-bumping `tail`, writes the
  slot, and publishes via a per-slot `ready` field; `tryDrainOne` is the single
  consumer. Bounded — **drop-on-full is signalled** via an atomic `dropped`
  counter, never silent.

## Addressing + platform

Every internal reference is a **byte offset** from the mapped base (no absolute
pointers), so a process mapping at any base is correct. Uses POSIX `mmap` +
C11/GCC atomic builtins (`atomicLoadN` / `atomicStoreN` /
`atomicCompareExchangeN` / `atomicAddFetch`) — **no `pthread_mutex` / process-
shared mutex**. Linux + macOS only; on other platforms the library compiles but
`shmIndexSupported` is false and `openShmIndex` returns an unavailable handle.
