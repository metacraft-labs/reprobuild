## HLX-M0 verification gate
## `unit_hcr_linux_x86_64_trampoline_encoding_and_atomicity_preconditions`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §4.2, §4.3, §4.4, §4.5.
##
## `allowed_mocks: none`. This gate drives the PRODUCTION provider code, not a
## reimplementation of it: `libs/repro_hcr_agent/c/repro_hcr_linux_x86_64.h` is
## the same header the C agent includes, re-exported for the test through
## `repro_hcr_linux_x86_64_probe.c`. The publication section additionally runs
## the real `mmap`/`mprotect`/aligned-store path against real executable memory
## and calls the patched stub, so a broken encoder shows up as a wrong return
## value rather than as a mismatched byte array.
##
## What it asserts:
##
##   1. the emitted `E9 rel32` bytes equal hand-computed encodings for
##      representative displacements, and the C and Nim encoders agree;
##   2. a misaligned entry, an absent sled, a short sled and a non-NOP sled are
##      each refused with a DISTINCT named diagnostic — and so is the fifth case
##      the design's rule implies but does not name, a window that is aligned
##      but does not fall on an instruction boundary (measured: this is exactly
##      what Clang emits under `-fcf-protection`);
##   3. publication is one naturally aligned 8-byte store containing five jump
##      bytes and three `0x90`s, never a straddling write;
##   4. re-patching an already-published window succeeds (design §4.5) and a
##      window changed behind the provider's back is refused rather than
##      overwritten.
##
## No silent skips on Linux x86_64. `MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE`
## and the `mprotect` RW->RX round trip are asserted AVAILABLE rather than
## probed-and-tolerated: if a future host lacks either, this gate must fail
## loudly so someone resolves HLX-OQ-3 / HLX-OQ-1 rather than shipping a
## provider that quietly stops synchronizing cores.

import std/[strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_linker

  {.compile: "../../libs/repro_hcr_agent/c/repro_hcr_linux_x86_64_probe.c".}

  proc probeNopLength(bytes: ptr uint8; avail: csize_t): csize_t {.importc:
    "repro_hcr_lx_probe_nop_length", cdecl.}
  proc probePlanSled(bytes: ptr uint8; capacity: csize_t; sledAddress: uint64;
                     sledEnd: ptr uint64; sledLength: ptr uint32;
                     windowAddress: ptr uint64;
                     windowOffset: ptr uint32): cint {.importc:
    "repro_hcr_lx_probe_plan_sled", cdecl.}
  proc probeEncodeJmpRel32(windowAddress, targetAddress: uint64;
                           outBytes: ptr uint8): cint {.importc:
    "repro_hcr_lx_probe_encode_jmp_rel32", cdecl.}
  proc probePublishedWord(jmpBytes: ptr uint8): uint64 {.importc:
    "repro_hcr_lx_probe_published_word", cdecl.}
  proc probeRefusalName(code: cint): cstring {.importc:
    "repro_hcr_lx_probe_refusal_name", cdecl.}
  proc probeTextProtectionRoundtrip(): cint {.importc:
    "repro_hcr_lx_probe_text_protection_roundtrip", cdecl.}
  proc probeMembarrierSyncCore(): cint {.importc:
    "repro_hcr_lx_probe_membarrier_sync_core", cdecl.}
  proc probeMembarrierQueryMask(): int64 {.importc:
    "repro_hcr_lx_probe_membarrier_query_mask", cdecl.}
  proc probeMembarrierSyncCoreCmd(): cint {.importc:
    "repro_hcr_lx_probe_membarrier_sync_core_cmd", cdecl.}
  proc probeMembarrierRegisterCmd(): cint {.importc:
    "repro_hcr_lx_probe_membarrier_register_cmd", cdecl.}
  proc probeApplyDirectPatchAt(entryAddress, sledAddress: uint64;
                               patchBytes: ptr uint8;
                               patchLen: csize_t): uint64 {.importc:
    "repro_hcr_lx_probe_apply_direct_patch_at", cdecl.}
  proc probeLastRefusal(): cint {.importc:
    "repro_hcr_lx_probe_last_refusal", cdecl.}
  proc probeLastWindowAddress(): uint64 {.importc:
    "repro_hcr_lx_probe_last_window_address", cdecl.}
  proc probeLastWindowOffset(): uint32 {.importc:
    "repro_hcr_lx_probe_last_window_offset", cdecl.}
  proc probeLastOriginalWord(): uint64 {.importc:
    "repro_hcr_lx_probe_last_original_word", cdecl.}
  proc probeLastPublishedWord(): uint64 {.importc:
    "repro_hcr_lx_probe_last_published_word", cdecl.}
  proc probeLastGeneration(): uint64 {.importc:
    "repro_hcr_lx_probe_last_generation", cdecl.}
  proc probeLastMembarrierResult(): clong {.importc:
    "repro_hcr_lx_probe_last_membarrier_result", cdecl.}
  proc probeMap(length: csize_t; protection: cint): pointer {.importc:
    "repro_hcr_lx_probe_map", cdecl.}
  proc probeUnmap(address: pointer; length: csize_t): cint {.importc:
    "repro_hcr_lx_probe_unmap", cdecl.}
  proc probePageSize(): csize_t {.importc:
    "repro_hcr_lx_probe_page_size", cdecl.}
  proc probeRawMprotect(address: uint64; length: csize_t;
                        protection: cint): clong {.importc:
    "repro_hcr_lx_probe_raw_mprotect", cdecl.}

  const
    ProtRead = 1.cint
    ProtWrite = 2.cint
    ProtExec = 4.cint

    RefusedAbsentSled = 1.cint
    RefusedNonNopSled = 2.cint
    RefusedShortSled = 3.cint
    RefusedMisalignedEntry = 4.cint
    RefusedWindowNotBoundary = 5.cint
    RefusedEntryModified = 6.cint
    RefusedOutOfRange = 7.cint

  type SledPlanResult = object
    refusal: cint
    sledEnd: uint64
    sledLength: uint32
    windowAddress: uint64
    windowOffset: uint32

  proc planSled(bytes: seq[byte]; sledAddress: uint64): SledPlanResult =
    var buffer = bytes
    if buffer.len == 0:
      buffer = @[0'u8]
    result.refusal = probePlanSled(addr buffer[0], csize_t(bytes.len),
      sledAddress, addr result.sledEnd, addr result.sledLength,
      addr result.windowAddress, addr result.windowOffset)

  proc nopLength(bytes: seq[byte]): int =
    var buffer = bytes
    if buffer.len == 0:
      return 0
    int(probeNopLength(addr buffer[0], csize_t(buffer.len)))

  proc refusalName(code: cint): string = $probeRefusalName(code)

  proc encodeC(windowAddress, targetAddress: uint64): tuple[rc: cint,
      bytes: seq[byte]] =
    var out5 = newSeq[byte](5)
    result.rc = probeEncodeJmpRel32(windowAddress, targetAddress, addr out5[0])
    result.bytes = out5

  proc hexOf(bytes: openArray[byte]): string =
    for b in bytes:
      result.add toHex(int(b), 2).toLowerAscii()

  # Real GCC output, measured: `-O2 -falign-functions=16 -fcf-protection=full
  # -fpatchable-function-entry=16,0` gives `endbr64` then 16 single-byte NOPs.
  const GccSled = @[
    0x90'u8, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90]

  # Real Clang output, measured with the same flags: one 15-byte multi-byte NOP
  # followed by a single 0x90. Its only interior instruction boundary is at +15.
  const ClangSled = @[
    0x66'u8, 0x66, 0x66, 0x66, 0x66, 0x2e, 0x66, 0x0f, 0x1f, 0x84, 0x00,
    0x00, 0x02, 0x00, 0x00, 0x90]

  suite "unit_hcr_linux_x86_64_trampoline_encoding_and_atomicity_preconditions":

    test "E9 rel32 encoder matches hand-computed bytes for representative displacements":
      # target == window + 5 => displacement 0.
      let (rc0, bytes0) = encodeC(0x1000'u64, 0x1005'u64)
      check rc0 == 0
      check hexOf(bytes0) == "e900000000"

      # forward 0x100 bytes past the end of the instruction.
      let (rc1, bytes1) = encodeC(0x1000'u64, 0x1105'u64)
      check rc1 == 0
      check hexOf(bytes1) == "e900010000"

      # backward: target 0x100 before the window => -0x105.
      let (rc2, bytes2) = encodeC(0x1000'u64, 0x0f00'u64)
      check rc2 == 0
      check hexOf(bytes2) == "e9fbfeffff"

      # exactly reachable forward extreme: displacement == 0x7fffffff.
      let (rc3, bytes3) = encodeC(0x1000'u64, 0x1005'u64 + 0x7fffffff'u64)
      check rc3 == 0
      check hexOf(bytes3) == "e9ffffff7f"

      # exactly reachable backward extreme: displacement == -0x80000000.
      let (rc4, bytes4) = encodeC(0x8000_0000'u64, 0x8000_0005'u64 - 0x8000_0000'u64)
      check rc4 == 0
      check hexOf(bytes4) == "e900000080"

      # one byte beyond the forward extreme is refused, never truncated.
      let (rc5, _) = encodeC(0x1000'u64, 0x1005'u64 + 0x8000_0000'u64)
      check rc5 == RefusedOutOfRange
      check refusalName(rc5) == "patch-body-out-of-rel32-range"

    test "portable Nim encoder agrees with the C agent byte for byte":
      for (window, target) in [
          (0x0000_1000'u64, 0x0000_1005'u64),
          (0x0000_1000'u64, 0x0000_1105'u64),
          (0x0000_1000'u64, 0x0000_0f00'u64),
          (0x7fff_0000_0000'u64, 0x7fff_0000_5000'u64)]:
        let (rc, cBytes) = encodeC(window, target)
        check rc == 0
        let plan = x86_64JmpRel32(window, target, nopSledBytes = 16)
        check plan.kind == tkX86_64JmpRel32
        check plan.bytes == cBytes
        check decodeX86_64JmpRel32Destination(window, plan.bytes) == target
        # The published word is the jump plus a 0x90 tail, exactly 8 bytes.
        let windowBytes = x86_64PublishedWindowBytes(plan)
        check windowBytes.len == 8
        check windowBytes[5] == 0x90'u8
        check windowBytes[6] == 0x90'u8
        check windowBytes[7] == 0x90'u8
        var cJmp = cBytes
        check probePublishedWord(addr cJmp[0]) == x86_64PublishedWindowWord(plan)

      # A window that is not 8-byte aligned has no atomic publication and the
      # portable encoder refuses it rather than emitting a straddling store.
      expect(ValueError):
        discard x86_64JmpRel32(0x1004'u64, 0x2000'u64, nopSledBytes = 16)

    test "NOP predicate decodes real GCC and Clang sled encodings by length":
      check nopLength(@[0x90'u8]) == 1
      check nopLength(@[0x66'u8, 0x90]) == 2
      check nopLength(@[0x0f'u8, 0x1f, 0x00]) == 3
      check nopLength(@[0x0f'u8, 0x1f, 0x40, 0x00]) == 4
      check nopLength(@[0x0f'u8, 0x1f, 0x44, 0x00, 0x08]) == 5
      check nopLength(@[0x66'u8, 0x0f, 0x1f, 0x84, 0x00, 0x00, 0x02, 0x00,
                        0x00]) == 9
      check nopLength(ClangSled) == 15
      # Not NOPs.
      check nopLength(@[0x55'u8, 0x48, 0x89, 0xe5]) == 0
      check nopLength(@[0xc3'u8]) == 0
      check nopLength(@[0xe9'u8, 0x00, 0x00, 0x00, 0x00]) == 0
      # A multi-byte NOP truncated by the end of the view is not a NOP: the
      # decoder must never claim bytes it cannot see.
      check nopLength(ClangSled[0 ..< 10]) == 0

    test "each refusal cause has a distinct named diagnostic":
      # Absent sled: nothing to decode at all.
      let absent = planSled(@[], 0x1000'u64)
      check absent.refusal == RefusedAbsentSled
      check refusalName(absent.refusal) == "absent-sled"

      # Non-NOP sled: the first instruction is a real prologue.
      let nonNop = planSled(@[0x55'u8, 0x48, 0x89, 0xe5, 0x90, 0x90, 0x90, 0x90],
        0x1000'u64)
      check nonNop.refusal == RefusedNonNopSled
      check refusalName(nonNop.refusal) == "non-nop-sled"
      check nonNop.sledLength == 0'u32

      # Short sled: four NOPs then real code. `-fpatchable-function-entry=8,4`
      # (the M25 fixture's setting) leaves exactly this.
      let short = planSled(@[0x90'u8, 0x90, 0x90, 0x90, 0x55, 0x48, 0x89, 0xe5],
        0x1000'u64)
      check short.refusal == RefusedShortSled
      check refusalName(short.refusal) == "short-sled"
      check short.sledLength == 4'u32

      # Misaligned entry: eight NOP bytes, but placed so that no 8-byte-aligned
      # 8-byte window lies wholly inside them.
      let misaligned = planSled(
        @[0x90'u8, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x55], 0x1004'u64)
      check misaligned.refusal == RefusedMisalignedEntry
      check refusalName(misaligned.refusal) == "misaligned-entry"
      check misaligned.sledLength == 8'u32

      # Aligned window exists but is not an instruction boundary. This is the
      # measured Clang + `-fcf-protection` layout: sled at entry+4 (entry is
      # 16-aligned), one 15-byte NOP, so the only boundaries are +0 and +15 and
      # neither is 8-aligned with room for the window.
      let clangCase = planSled(ClangSled, 0x1004'u64)
      check clangCase.refusal == RefusedWindowNotBoundary
      check refusalName(clangCase.refusal) ==
        "sled-window-not-instruction-boundary"
      check clangCase.sledLength == 16'u32

      # All five names are pairwise distinct.
      var names: seq[string] = @[]
      for code in [RefusedAbsentSled, RefusedNonNopSled, RefusedShortSled,
                   RefusedMisalignedEntry, RefusedWindowNotBoundary,
                   RefusedEntryModified]:
        let name = refusalName(code)
        check not names.contains(name)
        check name.len > 0
        names.add name

    test "the GCC sled yields an 8-byte-aligned window wholly inside it":
      # entry 16-aligned, `endbr64` at +0, sled at +4: the lowest usable window
      # is at entry+8, i.e. sled+4. Offset 0 is wrong and offset 4 (from the
      # entry) is guaranteed misaligned — design §4.2.
      let plan = planSled(GccSled, 0x1004'u64)
      check plan.refusal == 0
      check plan.sledLength == 16'u32
      check plan.windowAddress == 0x1008'u64
      check plan.windowOffset == 4'u32
      check (plan.windowAddress and 7'u64) == 0'u64
      check plan.windowAddress + 8'u64 <= plan.sledEnd

      # Without CET the sled starts at the 16-aligned entry itself, and the
      # window is at offset 0. The provider computes both; it assumes neither.
      let noCet = planSled(GccSled, 0x1000'u64)
      check noCet.refusal == 0
      check noCet.windowAddress == 0x1000'u64
      check noCet.windowOffset == 0'u32

    test "host provides SYNC_CORE membarrier and an mprotect RW/RX round trip":
      # Design §4.4: SYNC_CORE is the cross-modifying-code requirement, not an
      # i-cache concern, and it is required on x86_64. Design §5.2: the RW->RX
      # round trip is probed at agent start so a hardened host is refused at
      # negotiation rather than mid-commit. Both are asserted, not tolerated.
      check probeMembarrierSyncCoreCmd() == 32 # 1 << 5, linux/membarrier.h
      check probeMembarrierRegisterCmd() == 64 # 1 << 6
      check probeMembarrierQueryMask() > 0
      check (probeMembarrierQueryMask() and 32'i64) != 0'i64
      check probeMembarrierSyncCore() == 1
      check probeTextProtectionRoundtrip() == 1

    test "publication is one aligned store, and re-patching the same site works":
      # Build a real executable stub carrying a real GCC-shaped patchable entry:
      # `endbr64` + 16 single-byte NOPs + `mov $11,%eax; ret`. The bytes are the
      # ones GCC 15.2 emits for `int f(void){return 11;}` under
      # `-fcf-protection=full -fpatchable-function-entry=16,0`.
      let pageSize = int(probePageSize())
      let page = probeMap(csize_t(pageSize), ProtRead or ProtWrite)
      check page != nil
      let pageAddress = cast[uint64](page)
      # Place the entry at a 16-aligned offset, as -falign-functions=16 does.
      let entryOffset = 0x40
      let entryAddress = pageAddress + uint64(entryOffset)
      check (entryAddress and 15'u64) == 0'u64
      var stub: seq[byte] = @[0xf3'u8, 0x0f, 0x1e, 0xfa]
      for _ in 0 ..< 16:
        stub.add 0x90'u8
      stub.add @[0xb8'u8, 0x0b, 0x00, 0x00, 0x00, 0xc3] # mov $11,%eax; ret
      copyMem(cast[pointer](entryAddress), addr stub[0], stub.len)
      check probeRawMprotect(pageAddress, csize_t(pageSize),
        ProtRead or ProtExec) == 0

      type StubFn = proc (): cint {.cdecl.}
      let call = cast[StubFn](cast[pointer](entryAddress))
      check call() == 11

      # Real patch bodies: `endbr64; mov $77,%eax; ret` and the same with 99.
      var body77: seq[byte] =
        @[0xf3'u8, 0x0f, 0x1e, 0xfa, 0xb8, 0x4d, 0x00, 0x00, 0x00, 0xc3]
      var body99: seq[byte] =
        @[0xf3'u8, 0x0f, 0x1e, 0xfa, 0xb8, 0x63, 0x00, 0x00, 0x00, 0xc3]

      let sledAddress = entryAddress + 4'u64
      let dispatch1 = probeApplyDirectPatchAt(entryAddress, sledAddress,
        addr body77[0], csize_t(body77.len))
      if dispatch1 == 0:
        checkpoint("first publication refused: " &
          refusalName(probeLastRefusal()))
      check dispatch1 != 0
      check probeLastRefusal() == 0
      check probeLastGeneration() == 1'u64
      check probeLastMembarrierResult() == 0
      let windowAddress = probeLastWindowAddress()
      check windowAddress == entryAddress + 8'u64
      check (windowAddress and 7'u64) == 0'u64
      check probeLastWindowOffset() == 4'u32
      # The saved original word is the all-NOP window, which is what a rollback
      # in HLX-M3 will restore.
      check probeLastOriginalWord() == 0x9090909090909090'u64

      # The published word is exactly the encoder's word for that dispatch.
      let expectedPlan = x86_64JmpRel32(windowAddress, dispatch1,
        nopSledBytes = 16)
      check probeLastPublishedWord() == x86_64PublishedWindowWord(expectedPlan)

      # `endbr64` at the entry survived, and nothing outside the 8-byte window
      # moved.
      var observed = newSeq[byte](26)
      copyMem(addr observed[0], cast[pointer](entryAddress), observed.len)
      check hexOf(observed[0 ..< 4]) == "f30f1efa"   # endbr64 preserved
      check hexOf(observed[4 ..< 8]) == "90909090"   # sled head untouched
      check observed[8] == 0xe9'u8                   # published jump
      check hexOf(observed[13 ..< 16]) == "909090"   # tail of the same store
      check hexOf(observed[16 ..< 20]) == "90909090" # sled tail untouched
      check hexOf(observed[20 ..< 26]) == "b80b000000c3" # old body retained

      check call() == 77

      # Re-patch (design §4.5). The window now holds `E9 rel32 90 90 90`, so a
      # naive all-NOP precondition would refuse here and the provider would work
      # exactly once.
      let dispatch2 = probeApplyDirectPatchAt(entryAddress, sledAddress,
        addr body99[0], csize_t(body99.len))
      if dispatch2 == 0:
        checkpoint("re-patch refused: " & refusalName(probeLastRefusal()))
      check dispatch2 != 0
      check dispatch2 != dispatch1
      check probeLastGeneration() == 2'u64
      check probeLastWindowAddress() == windowAddress
      # Rollback still targets the ORIGINAL word, not generation 1's.
      check probeLastOriginalWord() == 0x9090909090909090'u64
      check call() == 99

      # A window changed behind the provider's back is refused, never
      # overwritten.
      check probeRawMprotect(pageAddress, csize_t(pageSize),
        ProtRead or ProtWrite) == 0
      var tamper = 0x9090909090909090'u64
      copyMem(cast[pointer](windowAddress), addr tamper, sizeof(tamper))
      check probeRawMprotect(pageAddress, csize_t(pageSize),
        ProtRead or ProtExec) == 0
      let refused = probeApplyDirectPatchAt(entryAddress, sledAddress,
        addr body77[0], csize_t(body77.len))
      check refused == 0
      check probeLastRefusal() == RefusedEntryModified
      check refusalName(probeLastRefusal()) == "entry-modified-externally"

      check probeUnmap(page, csize_t(pageSize)) == 0

else:
  suite "unit_hcr_linux_x86_64_trampoline_encoding_and_atomicity_preconditions":
    test "HLX-M0 x86_64 trampoline gate is linux-x86_64-only":
      skip()
