## HLX-M7 verification gate
## `integration_hcr_linux_claim_conflict_with_recorder_refused`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §10.1.
##
## THE RULE BEING TESTED, in the claim map's own words
## (`ct_inline_hook/claimed_guest_text.h:59-63`):
##
##   *"No patcher may steal a byte another patcher has already claimed. A
##   patcher claims [start, end) BEFORE it writes, the claim is refused if it
##   intersects a live claim, and a refusal must route to a transport that does
##   not need the contested bytes — never to a silent skip."*
##
## `allowed_mocks: none`, and what that means precisely here. Both sides are
## production code:
##
##   * the claim map is `codetracer-native-recorder/ct_inline_hook/
##     claimed_guest_text.c`, compiled from the sibling checkout — the same
##     translation unit `libct_interpose.so` links;
##   * the patcher is `libs/repro_hcr_agent/c/repro_hcr_linux_x86_64.h`, the
##     same header the live C agent includes, reached through the existing
##     no-mock probe shim;
##   * the sled and the target text are real: a real `mmap`ed executable page
##     carrying real 16-byte NOP sleds, published into by the real aligned
##     8-byte store.
##
## The recorder's side of the conflict is a REAL CLAIM taken through the real
## `ct_claimed_guest_text_claim` with a real MCR owner id — the identical call
## `atomic_callsite_patch_posix.c:2480-2493` makes before its `E9`. What is not
## run is the rest of MCR's patcher, because the map is the entire arbitration
## surface: intersection does not consult anything else, and the bytes MCR would
## write are irrelevant to whether HCR is refused. Stated rather than implied,
## so nobody has to guess how much of the recorder is in the loop.
##
## The asymmetry matters and both directions are asserted. It is not enough that
## HCR yields to MCR; MCR must also be refused the bytes HCR holds, or the
## coexistence story is "whoever runs second wins".

import std/[strutils, unittest]

when defined(linux) and defined(amd64):
  import std/os

  const recorderClaimMap =
    "../../../codetracer-native-recorder/ct_inline_hook/claimed_guest_text.c"

  static:
    # A LOUD failure, not a skip. This gate is about two repositories agreeing;
    # if the sibling checkout is missing there is nothing to agree with, and a
    # green run in that state would be the campaign's silent-self-pass pattern
    # for the twelfth time.
    doAssert fileExists(currentSourcePath().parentDir / recorderClaimMap),
      "HLX-M7 claim-conflict gate needs the codetracer-native-recorder " &
      "checkout beside this repo: " & recorderClaimMap & " is not there. " &
      "The cross-patcher claim map is the arbitration surface itself, so " &
      "there is no version of this gate that does not need it."

  {.compile: recorderClaimMap.}
  {.compile: "../../libs/repro_hcr_agent/c/repro_hcr_linux_x86_64_probe.c".}

  # --- the recorder's side of the map ---------------------------------------
  proc cgtClaim(start: uint, len: csize_t, owner: cuint,
                holder: ptr cuint): cint
    {.importc: "ct_claimed_guest_text_claim", cdecl.}
  proc cgtRelease(start: uint) {.importc: "ct_claimed_guest_text_release", cdecl.}
  proc cgtLookup(address: uint, startOut: ptr uint, ownerOut: ptr cuint): csize_t
    {.importc: "ct_claimed_guest_text_lookup", cdecl.}
  proc cgtCount(): cuint {.importc: "ct_claimed_guest_text_count", cdecl.}
  proc cgtRefusals(): cuint {.importc: "ct_claimed_guest_text_refusals", cdecl.}
  proc cgtReset() {.importc: "ct_claimed_guest_text_reset", cdecl.}

  # --- the provider ----------------------------------------------------------
  proc probeApply(entryAddress, sledAddress: uint64; patchBytes: ptr uint8;
                  patchLen: csize_t): uint64
    {.importc: "repro_hcr_lx_probe_apply_direct_patch_at", cdecl.}
  proc probeLastRefusal(): cint {.importc: "repro_hcr_lx_probe_last_refusal", cdecl.}
  proc probeRefusalName(code: cint): cstring
    {.importc: "repro_hcr_lx_probe_refusal_name", cdecl.}
  proc probeLastWindowAddress(): uint64
    {.importc: "repro_hcr_lx_probe_last_window_address", cdecl.}
  proc probeLastClaimHolder(): cuint
    {.importc: "repro_hcr_lx_probe_last_claim_holder", cdecl.}
  proc probeLastClaimHeld(): cint
    {.importc: "repro_hcr_lx_probe_last_claim_held", cdecl.}
  proc probeLastGeneration(): uint64
    {.importc: "repro_hcr_lx_probe_last_generation", cdecl.}
  proc probeResetSites() {.importc: "repro_hcr_lx_probe_reset_sites", cdecl.}
  proc probeMap(length: csize_t; protection: cint): pointer
    {.importc: "repro_hcr_lx_probe_map", cdecl.}
  proc probeUnmap(address: pointer; length: csize_t): cint
    {.importc: "repro_hcr_lx_probe_unmap", cdecl.}
  proc probePageSize(): csize_t {.importc: "repro_hcr_lx_probe_page_size", cdecl.}

  const
    ProtRead = 0x1.cint
    ProtWrite = 0x2.cint
    ProtExec = 0x4.cint
    OwnerAtomicJmp = 1'u32     ## CT_CGT_OWNER_ATOMIC_JMP — MCR's E9 transport
    OwnerReproHcr = 7'u32      ## CT_CGT_OWNER_REPRO_HCR — added by HLX-M7
    WindowBytes = 8
    SledBytes = 16
    # `mov eax, 4242; ret` — the same shape of body the Godot demo publishes.
    PatchBody = [0xb8'u8, 0x92, 0x10, 0x00, 0x00, 0xc3]

  type TargetPage = object
    base: pointer
    size: csize_t

  proc newTargetPage(): TargetPage =
    ## A real executable page carrying a real 16-NOP patchable sled at offset 0,
    ## which is what the compiler emits under `-fpatchable-function-entry=16,0`
    ## without CET (measured on the Godot engine: `90` x16, window at +0).
    let size = probePageSize()
    let page = probeMap(size, ProtRead or ProtWrite or ProtExec)
    doAssert page != nil, "could not map an executable scratch page"
    let bytes = cast[ptr UncheckedArray[uint8]](page)
    for i in 0 ..< int(size):
      bytes[i] = 0xCC'u8            # int3 everywhere else, so a stray jump traps
    for i in 0 ..< SledBytes:
      bytes[i] = 0x90'u8
    TargetPage(base: page, size: size)

  proc dispose(p: TargetPage) =
    discard probeUnmap(p.base, p.size)

  proc windowWord(p: TargetPage): uint64 =
    let bytes = cast[ptr UncheckedArray[uint8]](p.base)
    for i in countdown(WindowBytes - 1, 0):
      result = (result shl 8) or uint64(bytes[i])

  proc applyInto(p: TargetPage): uint64 =
    var body = PatchBody
    probeApply(uint64(cast[uint](p.base)), uint64(cast[uint](p.base)),
               addr body[0], csize_t(body.len))

  suite "HLX-M7 HCR/MCR claim arbitration":

    setup:
      cgtReset()
      probeResetSites()

    test "a window MCR has claimed is refused, named, and left untouched":
      let page = newTargetPage()
      defer: page.dispose()
      let windowAddress = cast[uint](page.base)
      let before = page.windowWord()
      check before == 0x9090909090909090'u64

      # The recorder claims the bytes first — the same call its E9 transport
      # makes at `atomic_callsite_patch_posix.c:2480-2493`.
      var holder = 0'u32
      check cgtClaim(windowAddress, csize_t(WindowBytes), OwnerAtomicJmp,
                     addr holder) == 0
      let refusalsBefore = cgtRefusals()

      let dispatch = applyInto(page)

      # 1. The provider refused.
      check dispatch == 0'u64
      # 2. With the NAMED reason §10.1 requires, not a generic failure.
      check $probeRefusalName(probeLastRefusal()) == "claimed-by-recorder"
      # 3. Carrying the holder out, so the report can say WHO.
      check probeLastClaimHolder() == OwnerAtomicJmp
      check probeLastClaimHeld() == 0
      # 4. And — the property the whole map exists for — it did not write.
      check page.windowWord() == before
      # 5. The refusal was counted by the map itself, so the two sides agree
      #    that a refusal happened rather than the provider merely declining.
      check cgtRefusals() == refusalsBefore + 1

      # 6. The recorder's claim is intact: the loser did not damage the winner.
      var claimStart = 0'u
      var claimOwner = 0'u32
      check cgtLookup(windowAddress + 4, addr claimStart, addr claimOwner) ==
        csize_t(WindowBytes)
      check claimStart == windowAddress
      check claimOwner == OwnerAtomicJmp
      check cgtCount() == 1'u32

    test "with the recorder's claim released the same publication succeeds":
      # The control for the case above. Without it, "refused" is equally
      # consistent with a provider that cannot patch this page at all — which
      # is the shape of a gate that passes for the wrong reason.
      let page = newTargetPage()
      defer: page.dispose()
      let windowAddress = cast[uint](page.base)

      var holder = 0'u32
      check cgtClaim(windowAddress, csize_t(WindowBytes), OwnerAtomicJmp,
                     addr holder) == 0
      check applyInto(page) == 0'u64
      check $probeRefusalName(probeLastRefusal()) == "claimed-by-recorder"

      cgtRelease(windowAddress)
      check cgtCount() == 0'u32

      let dispatch = applyInto(page)
      check dispatch != 0'u64
      check $probeRefusalName(probeLastRefusal()) == "ok"
      # The published word is the aligned 8-byte store: `E9 rel32` + three NOPs.
      let published = page.windowWord()
      check (published and 0xFF'u64) == 0xE9'u64
      check ((published shr 40) and 0xFFFFFF'u64) == 0x909090'u64
      # And the provider now holds the claim, with the map agreeing.
      check probeLastClaimHeld() == 1
      var claimStart = 0'u
      var claimOwner = 0'u32
      check cgtLookup(windowAddress, addr claimStart, addr claimOwner) ==
        csize_t(WindowBytes)
      check claimOwner == OwnerReproHcr

    test "MCR is refused the bytes HCR holds — the arbitration is symmetric":
      # Coexistence is not "HCR yields". If the recorder could take bytes the
      # provider had already published into, the outcome would depend only on
      # which patcher ran second, and the claim map would be decoration.
      let page = newTargetPage()
      defer: page.dispose()
      let windowAddress = cast[uint](page.base)

      check applyInto(page) != 0'u64
      check probeLastClaimHeld() == 1

      var holder = 0'u32
      check cgtClaim(windowAddress + 2, csize_t(4), OwnerAtomicJmp,
                     addr holder) == -2
      check holder == OwnerReproHcr

    test "the claim is RETAINED across re-patch generations, not re-taken":
      # Design §4.5 + §10.1. Re-claiming on generation 2 would be refused by the
      # provider's OWN live claim, and releasing between generations would open
      # a window in which the recorder could take the bytes from under a site
      # still being published into.
      let page = newTargetPage()
      defer: page.dispose()
      let windowAddress = cast[uint](page.base)

      check applyInto(page) != 0'u64
      check probeLastGeneration() == 1'u64
      check cgtCount() == 1'u32

      check applyInto(page) != 0'u64
      check probeLastGeneration() == 2'u64
      check probeLastClaimHeld() == 1
      # Still exactly one claim: retained, not re-taken, not duplicated.
      check cgtCount() == 1'u32
      var claimStart = 0'u
      var claimOwner = 0'u32
      check cgtLookup(windowAddress, addr claimStart, addr claimOwner) ==
        csize_t(WindowBytes)
      check claimOwner == OwnerReproHcr

    test "a publication that fails after claiming RELEASES the claim":
      # §10.1: "HCR releases its claim on rollback." A claim leaked by a failed
      # publication is worse than no claim at all — it refuses everyone,
      # including the next reload, for bytes nobody is using.
      let page = newTargetPage()
      defer: page.dispose()
      check cgtCount() == 0'u32

      # A body larger than a page cannot be placed, and the refusal happens
      # AFTER the claim is taken. This drives the real rollback path rather
      # than a simulated one.
      var oversized = newSeq[uint8](int(probePageSize()) + 64)
      for i in 0 ..< oversized.len:
        oversized[i] = 0x90'u8
      let dispatch = probeApply(uint64(cast[uint](page.base)),
                                uint64(cast[uint](page.base)),
                                addr oversized[0], csize_t(oversized.len))
      check dispatch == 0'u64
      check $probeRefusalName(probeLastRefusal()) == "invalid-argument"
      check probeLastClaimHeld() == 0
      check cgtCount() == 0'u32

      # And the window is still claimable by anyone, which is the point.
      var holder = 0'u32
      check cgtClaim(cast[uint](page.base), csize_t(WindowBytes),
                     OwnerAtomicJmp, addr holder) == 0

else:
  suite "HLX-M7 HCR/MCR claim arbitration":
    test "linux/amd64 only":
      # Not a silent skip: the claim map's raw-syscall backend refuses to
      # compile off x86_64 Linux by `#error`, and the provider arm this gate
      # drives does not exist on other hosts.
      skip()
