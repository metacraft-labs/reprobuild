## Distributed-Execution M7, threat model G16: a daemon-forked build worker
## holds NO copy of the daemon's private keys — not its leaf key, not its host
## CA key — anywhere in its memory.
##
## Before the fix the build worker zeroed one field and kept the rest: the
## host's `tls.cert`, the server's and the client's `ourCert`, and every TLS
## connection's key buffer were all copies of the daemon leaf's key. Now the
## daemon's keys live in `secret_key.SecretKey` pages that a forked child does
## not inherit (Linux `MADV_WIPEONFORK`, macOS `VM_INHERIT_NONE`), and the
## build worker presents a `build-worker` leaf the daemon minted for it
## before the fork (the one inheritable key).
##
## The observation is a SCAN OF THE CHILD'S MEMORY: every private, writable
## mapping, byte by byte, for the daemon leaf's scalar and the host CA's
## scalar. The test never holds a plain copy of either: it compares against
## the scalar XOR a random mask, computed from inside the key's own page
## (`maskedScalarForTesting`). So:
##
##   * positive control 1: the same scan in the PARENT finds both keys (the
##     scanner can see them where they are);
##   * positive control 2: the child's scan finds the `build-worker` leaf it
##     legitimately holds;
##   * the assertion: the child finds neither the daemon leaf nor the CA.
##
## The node is a production `PeerCacheHost` with live TLS connections in
## both directions at the moment of the fork (each one holds a reference to
## the daemon leaf's key), and the child runs the production fork path:
## `releaseInheritedHost` then `startWorkerPeerCacheSession`.
##
## PROFILE: HARDENED (explicit below). This is a hardened-profile property:
## a hardened daemon holds a per-host CA and a one-hour leaf, and neither may
## reach its forked build worker. In the TRUSTED profile the build worker
## DOES inherit the daemon's long-lived host key, by design (threat model
## §7.1, §8, G16): it runs as the same uid that can already read the key
## file, which the operator accepted for single-owner fleets. What the
## trusted profile guarantees instead is that a LEASE — the action — cannot
## read the key, on disk or in memory
## (`t_worker_executes_only_the_hydrated_graph`, trusted case,
## `read-host-key`).
##
## MOCK POLICY — none: real hosts, real TLS, a real fork; the scanner reads
## the process's own memory.

import std/[asyncdispatch, os, posix, sysrand, tempfiles, unittest]

import repro_peer_cache
import repro_cli_support/peer_cache_wiring

import ../../repro_peer_cache/tests/m7_test_pki

{.emit: """/*INCLUDESECTION*/
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_vm.h>
#endif
""".}

{.emit: """
static int repro_m7_match_at(const uint8_t *p, const uint8_t *masked, const uint8_t *mask) {
  for (int i = 0; i < 32; i++)
    if ((uint8_t)(p[i] ^ masked[i]) != mask[i]) return 0;
  return 1;
}

static long repro_m7_scan_range(uintptr_t lo, uintptr_t hi, const uint8_t *masked,
                                const uint8_t *mask, uintptr_t skip_lo, uintptr_t skip_hi) {
  long found = 0;
  if (hi - lo < 32) return 0;
  for (uintptr_t a = lo; a + 32 <= hi; a++) {
    if (a >= skip_lo && a < skip_hi) continue;
    const uint8_t *p = (const uint8_t *)a;
    if ((uint8_t)(p[0] ^ masked[0]) != mask[0]) continue;
    if (repro_m7_match_at(p, masked, mask)) found++;
  }
  return found;
}

/* How many times the scalar `masked ^ mask` occurs in this process's
   private, writable memory. */
long repro_m7_scan_memory(const uint8_t *masked, const uint8_t *mask) {
  long found = 0;
  uintptr_t skip_lo = (uintptr_t)masked, skip_hi = skip_lo + 32;
#if defined(__linux__)
  FILE *f = fopen("/proc/self/maps", "re");
  if (!f) return -1;
  char line[4096];
  while (fgets(line, sizeof line, f)) {
    unsigned long lo, hi, off, inode; char perms[8]; unsigned dmaj, dmin;
    if (sscanf(line, "%lx-%lx %7s %lx %x:%x %lu", &lo, &hi, perms, &off, &dmaj, &dmin, &inode) != 7) continue;
    if (perms[0] != 'r' || perms[1] != 'w' || perms[3] != 'p') continue;
    if (strstr(line, "[vvar]") || strstr(line, "[vsyscall]")) continue;
    if (inode != 0) continue;   /* file-backed: not where a key is copied */
    found += repro_m7_scan_range(lo, hi, masked, mask, skip_lo, skip_hi);
  }
  fclose(f);
#elif defined(__APPLE__)
  mach_vm_address_t addr = 0;
  for (;;) {
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = mach_vm_region(mach_task_self(), &addr, &size,
      VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (kr != KERN_SUCCESS) break;
    if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE) &&
        !info.shared)
      found += repro_m7_scan_range((uintptr_t)addr, (uintptr_t)(addr + size), masked, mask,
                                   skip_lo, skip_hi);
    addr += size;
  }
#endif
  return found;
}
""".}

proc scanMemory(masked, mask: ptr byte): clong {.importc: "repro_m7_scan_memory", nodecl.}

proc randomMask(): PrivateKeyBytes =
  let bytes = urandom(32)
  for i in 0 ..< 32: result[i] = bytes[i]

proc countIn(masked, mask: PrivateKeyBytes): int =
  var m = masked
  var k = mask
  int(scanMemory(addr m[0], addr k[0]))

suite "Distributed-Execution M7: a build worker holds no daemon key (G16)":

  test "hardened profile: the forked build worker's memory holds neither the daemon leaf nor the host CA":
    let base = createTempDir("m7-g16-", "")
    defer: removeDir(base)
    var a = newTestNode(base, "a")
    var b = newTestNode(base, "b")
    mutualTrust([a, b])
    let hostB = startPeerCacheHost(tlsConfig(b, profile = tpHardened),
      b.identity.hostId, cacheRoot = base / "b-cache")
    defer: hostB.stop()
    # A dials B, and B dials A back: A holds TLS connections in both
    # directions, each referencing A's daemon leaf key.
    let hostA = startPeerCacheHost(tlsConfig(a, seeds = @[initEndpoint(
      "127.0.0.1", hostB.actualPort)], profile = tpHardened), a.identity.hostId,
      cacheRoot = base / "a-cache")
    check hostA.config.trustProfile == tpHardened
    defer: hostA.stop()
    discard waitFor hostB.client.connectKnownPeers()
    for _ in 0 ..< 20: hostA.tick(25)
    check hostA.client.isConnected(b.identity.hostId)
    check hostB.client.isConnected(a.identity.hostId)
    let mask = randomMask()
    let leafMasked = hostA.leaf.key.maskedScalarForTesting(mask)
    let caMasked = hostA.identity.caKey.maskedScalarForTesting(mask)
    let bwMasked = hostA.buildWorkerLeaf.key.maskedScalarForTesting(mask)
    var zero: PrivateKeyBytes
    check leafMasked != zero and caMasked != zero and bwMasked != zero
    # Positive control 1: the scanner finds both keys in the parent.
    let parentLeaf = countIn(leafMasked, mask)
    let parentCa = countIn(caMasked, mask)
    checkpoint("parent: daemon leaf found " & $parentLeaf & "x, host CA " &
      $parentCa & "x")
    check parentLeaf >= 1
    check parentCa >= 1
    let members = hostA.membershipEndpoints()
    let pid = fork()
    if pid == 0:
      # The build worker: the production fork path, then the scan.
      var code = 0
      try:
        hostA.releaseInheritedHost()
        let session = startWorkerPeerCacheSession(hostA, members,
          a.identity.hostId)
        if session.leaf.role != lrBuildWorker: code = code or 8
        if countIn(leafMasked, mask) > 0: code = code or 1
        if countIn(caMasked, mask) > 0: code = code or 2
        if countIn(bwMasked, mask) == 0: code = code or 4   # control 2
      except CatchableError:
        code = 16
      posix.exitnow(cint(code))
    var status: cint = 0
    check waitpid(pid, status, 0) == pid
    let code = if WIFEXITED(status): int(WEXITSTATUS(status)) else: 100
    checkpoint("child exit " & $code & " (1: daemon leaf found, 2: host CA " &
      "found, 4: build-worker leaf NOT found, 8: wrong leaf role, 16: error)")
    check (code and 1) == 0       # no copy of the daemon leaf's key
    check (code and 2) == 0       # no copy of the host CA's key
    check (code and 4) == 0       # control: its own leaf IS there
    check (code and 8) == 0
    check (code and 16) == 0
    check code == 0
