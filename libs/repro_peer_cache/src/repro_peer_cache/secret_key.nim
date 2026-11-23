## Private keys held outside the garbage-collected heap and wiped across
## `fork()` — Distributed-Execution M7 (threat model G16;
## deployment-security-architecture.md CRED-1, CRED-4).
##
## WHY. `repro-daemon` forks a build worker for every hosted build. Before
## this module the daemon's leaf private key lived in ordinary Nim objects
## (`LeafCredential`, the server's and client's `ourCert`, every TLS
## connection's key buffer), so every forked build worker inherited copies
## of it: zeroing the obvious field left the others behind, and the fork
## copies memory, not references.
##
## WHAT. A `SecretKey` is one P-256 private scalar in its own anonymous
## `mmap` page, never in the GC heap:
##
## * the page is excluded from core dumps and, where the kernel allows,
##   locked in memory (best effort);
## * on Linux it is `madvise(MADV_WIPEONFORK)`: a forked child sees zeros;
##   on macOS (and the BSDs) it is `minherit(VM_INHERIT_NONE)`: a forked
##   child does not have the page at all — every accessor checks the owning
##   pid first and never dereferences the page in another process;
## * keys a child must keep (the pre-minted `build-worker` leaf a daemon
##   hands to its build workers) are created with `inheritable = true`;
## * the page is zeroed with volatile stores and unmapped when the key is
##   destroyed.
##
## The scalar reaches BearSSL only through `withKeypair`, which materializes
## a transient `PeerKeypair` on the caller's stack and zeroes it again, or
## through `keyAddress` for a TLS connection, which points BearSSL at the
## page itself (the connection keeps the key alive).
##
## What this does NOT protect against: code running as the same user, which
## can read the key FILE (`host-ca.key`) from disk or attach to the process.
## That is the owning account's boundary, not this process's (see the threat
## model §8).

import std/[os, volatile]
when defined(posix):
  import std/posix

import ./key_types

when defined(linux):
  const
    MADV_DONTDUMP = cint(16)
    MADV_WIPEONFORK = cint(18)
  proc c_madvise(a: pointer; len: csize_t; advice: cint): cint {.
    importc: "madvise", header: "<sys/mman.h>".}
elif defined(macosx) or defined(freebsd) or defined(openbsd) or
    defined(netbsd):
  const VM_INHERIT_NONE = cint(2)
  proc c_minherit(a: pointer; len: csize_t; inherit: cint): cint {.
    importc: "minherit", header: "<sys/mman.h>".}

type
  SecretKeyObj = object
    page: pointer
    pageLen: int
    ownerPid: int
    inheritable: bool
    wiped: bool
    publicKey*: PublicKeyBytes

  SecretKey* = ref SecretKeyObj
    ## One private scalar in a protected page (see the module doc).

  SecretKeyError* = object of CatchableError

proc secureZero*(p: pointer; n: int) =
  ## Zeroes `n` bytes at `p` with volatile stores, so the compiler cannot
  ## drop the writes as dead.
  if p.isNil or n <= 0:
    return
  let bytes = cast[ptr UncheckedArray[byte]](p)
  for i in 0 ..< n:
    volatileStore(addr bytes[i], 0'u8)

template secureZeroVar*(x: typed) =
  ## `secureZero` over a local variable (an array, an object).
  secureZero(addr x, sizeof(x))

proc pageSize(): int =
  when defined(posix):
    int(sysconf(SC_PAGESIZE))
  else:
    4096

proc `=destroy`(x: SecretKeyObj) =
  if x.page.isNil:
    return
  when defined(posix):
    # In a forked child the page is either already zero (Linux) or absent
    # (macOS); only the owner touches or unmaps it.
    if x.ownerPid == getCurrentProcessId() or x.inheritable:
      secureZero(x.page, P256PrivLen)
      discard munmap(x.page, x.pageLen)
  else:
    secureZero(x.page, P256PrivLen)
    dealloc(x.page)

proc `=copy`(dst: var SecretKeyObj; src: SecretKeyObj) {.error.}
proc `=dup`(src: SecretKeyObj): SecretKeyObj {.error.}

proc allocatePage(inheritable: bool): tuple[page: pointer; len: int] =
  let len = pageSize()
  when defined(posix):
    let p = mmap(nil, len, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
    if p == MAP_FAILED:
      raise newException(SecretKeyError, "cannot map a page for a private key: " &
        osErrorMsg(osLastError()))
    discard mlock(p, len)   # best effort: never swapped out
    when defined(linux):
      discard c_madvise(p, csize_t(len), MADV_DONTDUMP)
      if not inheritable and c_madvise(p, csize_t(len), MADV_WIPEONFORK) != 0:
        discard munmap(p, len)
        raise newException(SecretKeyError,
          "MADV_WIPEONFORK is unavailable (Linux >= 4.14 is required): a " &
          "forked build worker would inherit the private key")
    elif defined(macosx) or defined(freebsd) or defined(openbsd) or
        defined(netbsd):
      if not inheritable and c_minherit(p, csize_t(len), VM_INHERIT_NONE) != 0:
        discard munmap(p, len)
        raise newException(SecretKeyError,
          "minherit(VM_INHERIT_NONE) failed: a forked build worker would " &
          "inherit the private key")
    (p, len)
  else:
    (alloc0(len), len)

proc newSecretKey*(priv: var PrivateKeyBytes; publicKey: PublicKeyBytes;
                   inheritable = false): SecretKey =
  ## Moves `priv` into a protected page and ZEROES `priv`. `inheritable`
  ## keys survive `fork()` (only for a credential a child must hold).
  let (page, len) = allocatePage(inheritable)
  result = SecretKey(page: page, pageLen: len,
    ownerPid: getCurrentProcessId(), inheritable: inheritable,
    publicKey: publicKey)
  copyMem(page, addr priv[0], P256PrivLen)
  secureZeroVar(priv)

proc newSecretKey*(kp: var PeerKeypair; inheritable = false): SecretKey =
  ## Moves `kp.privateKey` into a protected page and zeroes it in `kp`.
  newSecretKey(kp.privateKey, kp.publicKey, inheritable)

proc usable(k: SecretKey): bool =
  not k.isNil and not k.page.isNil and not k.wiped and
    (k.inheritable or k.ownerPid == getCurrentProcessId())

proc available*(k: SecretKey): bool =
  ## Whether this process may use the key: it was created here (or is
  ## inheritable), has not been wiped, and is not all zeros (a Linux
  ## child's wiped page).
  if not k.usable:
    return false
  let bytes = cast[ptr UncheckedArray[byte]](k.page)
  for i in 0 ..< P256PrivLen:
    if bytes[i] != 0:
      return true
  false

proc wipe*(k: SecretKey) =
  ## Zeroes the key now (the page stays mapped until the key is destroyed).
  if k.isNil or k.page.isNil:
    return
  if k.usable:
    secureZero(k.page, P256PrivLen)
  k.wiped = true

proc keyAddress*(k: SecretKey): ptr byte =
  ## The page's address for BearSSL's `EcPrivateKey.x` — only while the
  ## caller keeps `k` alive. Raises when the key is not usable here.
  if not k.available:
    raise newException(SecretKeyError,
      "this process does not hold the private key")
  cast[ptr byte](k.page)

template withKeypair*(k: SecretKey; kp, body: untyped) =
  ## Runs `body` with `kp` a transient `PeerKeypair` (on this stack frame)
  ## holding `k`'s scalar; zeroes it afterwards, also on an exception.
  block:
    if not available(k):
      raise newException(SecretKeyError,
        "this process does not hold the private key")
    var kp {.inject.}: PeerKeypair
    try:
      kp.publicKey = k.publicKey
      copyMem(addr kp.privateKey[0], keyAddress(k), P256PrivLen)
      body
    finally:
      secureZeroVar(kp)

proc maskedScalarForTesting*(k: SecretKey; mask: PrivateKeyBytes):
    PrivateKeyBytes =
  ## The scalar XOR `mask`, for a memory-scan test that must find the key
  ## without ever holding a plain copy of it. Never use for anything else.
  if not k.available:
    return
  let bytes = cast[ptr UncheckedArray[byte]](k.page)
  for i in 0 ..< P256PrivLen:
    result[i] = bytes[i] xor mask[i]

proc scrubStackBelow*() {.noinline.} =
  ## Zeroes 512 KiB of this thread's stack below the current frame. Called
  ## in a freshly forked child: the parent's stale frames (a signature
  ## computed a moment before the fork) lie below the child's stack pointer
  ## and would otherwise survive in it.
  var area: array[512 * 1024, byte]
  secureZero(addr area[0], area.len)
