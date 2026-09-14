## Action-Cache-Per-Edge-Store.md §6.8 — the Tier-2 index selects an arm its
## HOST can actually build, and the unsupported arm behaves as the spec says.
##
## WHY THIS EXISTS. `action_index.nim` publishes exactly one switch,
## `actionIndexSupported`, and everything behind it is POSIX: the chain anchor
## is claimed with an exclusive `link(2)` and flatteners serialise on it with
## `flock(2)`. That switch was written as a plain alias of `nim-shm-gset`'s
## `shmGSetSupported`, which answers a DIFFERENT question — whether the
## grow-only set can be mapped and mutated. The two agreed only for as long as
## the library was POSIX-only. When `nim-shm-gset` gained its Windows arm
## (`MapViewOfFileEx` / `LockFileEx`), `shmGSetSupported` went true on Windows
## and the alias selected the POSIX arm on a kernel that has neither call.
##
## WHY THAT BREAKAGE NEEDS A TEST AND NOT JUST A COMMENT. Nim emits C only for
## procs that are REACHED, so `nim check` on the module passed, and so did any
## binary that merely read the constant. The failure appeared at the C stage
## (`implicit declaration of function 'link'` / `'flock'` from gcc) only in a
## binary that actually touched the index — which is why it survived in
## `dev`. The load-bearing half of this file is therefore its COMPILATION: the
## procs below are called unconditionally, outside any
## `when actionIndexSupported`, so building this test forces the host's chosen
## arm through the C compiler and the linker. On a host whose arm does not
## build, this test does not fail an assertion — it fails to exist, which is
## the louder of the two.
##
## NO MOCKS. The module under test is the shipped one and the cache root is a
## real empty temp directory; nothing here is stubbed, and the file asserts only
## what §6.8 states normatively.

import std/[os, tempfiles, unittest]

import repro_hash
import repro_local_store

proc digestFor(name: string): ContentDigest =
  var bytes = newSeq[byte](name.len)
  for i, ch in name:
    bytes[i] = byte(ord(ch))
  blake3DomainDigest(bytes, hdActionFingerprint)

suite "action index — platform arm (§6.8)":

  test "the arm is Linux and macOS, and Windows is Tier-1 only":
    # §6.8: "Platform. Linux and macOS ... On any other platform the chain is
    # not created and the cache runs on Tier 1 only, which is correct." The
    # status table books the Windows shared-memory arm as an OPEN item.
    when defined(windows):
      check not actionIndexSupported
    elif defined(linux) or defined(macosx):
      check actionIndexSupported
    else:
      check not actionIndexSupported

  test "index availability never exceeds gset availability":
    # The narrowing is one-directional by construction: this module needs
    # everything the set needs AND two POSIX calls the set does not use. An
    # index declared available where the set is not would be a chain nobody
    # can map.
    check (not actionIndexSupported) or shmGSetSupported

  test "the surface links on this host and an empty root attaches nothing":
    # Every call below is unconditional ON PURPOSE — see the header. On a
    # POSIX host these reach the real `link`/`flock` bodies; on Windows they
    # reach the unavailable arm. Either way the host's arm must build.
    let root = createTempDir("repro-ac-arm-", "-test")
    defer: removeDir(root)

    var idx = openActionIndex(root)
    defer: closeActionIndex(idx)

    let weak = digestFor("action-index.arm.weak")
    let strong = digestFor("action-index.arm.strong")

    when actionIndexSupported:
      # A supported host creates the chain on demand, so the only claim this
      # test makes is that the surface is live; the element-level properties
      # belong to the §6.4/§6.5 integration tests.
      check idx.attached
      check idx.insertRecord(weak, strong) != isUnavailable
    else:
      # §6.8 + §8 step 5: no chain, and every mutation reports unavailable so
      # the caller falls back to the authoritative Tier-1 union read rather
      # than mistaking an absent index for an empty one.
      check not idx.attached
      check idx.failure == afMissing
      check idx.insertRecord(weak, strong) == isUnavailable
      check idx.insertEdgeComplete(weak) == isUnavailable
      check idx.evictRecord(weak, strong) == isUnavailable
      check idx.evictEdgeComplete(weak) == isUnavailable
      check not idx.flattenChain()
      check idx.shardCount == 0
      check idx.liveElementCount == 0'u64
      check not idx.enumerateEdge(weak).attached
