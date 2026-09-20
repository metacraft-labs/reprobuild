/*
 * Linux x86_64 ELF direct-entry HCR provider primitives (HLX-M0).
 *
 * Implements the publication rule of
 * `reprobuild-specs/HCR/Linux-ELF-Provider.md` §4.2/§4.3/§4.4/§4.5 and the
 * memory-protection rules of §5.1/§5.2:
 *
 *   - the ONLY write this provider makes into live executable text is a single
 *     naturally aligned 8-byte store holding a 5-byte `E9 rel32`;
 *   - the 8-byte window offset is COMPUTED from the observed entry bytes, never
 *     assumed to be 0 (under `-fcf-protection` GCC emits `endbr64` at the entry
 *     label and the natural +4 offset is guaranteed misaligned under
 *     `-falign-functions=16`);
 *   - the sled address comes from the runtime-mapped
 *     `__patchable_function_entries` section, not from the symbol address;
 *   - `mprotect` is issued as a raw syscall, never through libc, so that a
 *     process in which MCR's `libct_interpose` has hooked `mprotect` does not
 *     re-enter the recording path (design §5.1);
 *   - `membarrier(MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE)` is issued after
 *     the publishing store on x86_64 as well as aarch64 (design §4.4). This is
 *     the *cross-modifying code* requirement of Intel SDM §8.1.3/§9.3, which is
 *     a different hazard from i-cache/data coherence. x86_64's coherent i-cache
 *     does NOT discharge it.
 *
 * This header contains only `static` functions and no global state other than
 * the site table and the capability cache, so it can be included from the agent
 * translation unit and, separately, from the unit-test probe shim.
 *
 * Scope note, updated by HLX-M4. HLX-M0 was single threaded by construction.
 * This header now also carries tier-2 quiescence (`repro_hcr_linux_quiesce.h`,
 * design §6.2/§6.3) and the `HLX-OQ-3` fallback. What HLX-M4 did NOT do is make
 * bare tier-1 publication safe for a multithreaded target: design §6.1 point 4
 * — a thread whose PC is inside the published window — is a hazard no aligned
 * store and no membarrier can address, and the provider's only remedy for it is
 * the tier-2 IP adjustment below. A multithreaded target must therefore quiesce.
 */

#ifndef REPRO_HCR_LINUX_X86_64_H
#define REPRO_HCR_LINUX_X86_64_H

/* HLX-M8 split `repro_hcr_lx_apply_direct_patch_at` into a prepare half and a
 * commit half. The agent now calls the two halves directly, so the composed
 * convenience is reached only by the test probe shim — a different translation
 * unit including the same header. Marking it explicitly is what keeps the
 * agent's own build warning-free without deleting a function the probe needs.
 */
#if defined(__GNUC__)
#define REPRO_HCR_LX_MAYBE_UNUSED __attribute__((unused))
#else
#define REPRO_HCR_LX_MAYBE_UNUSED
#endif

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "repro_hcr_mcr_bridge.h"

/* ---------------------------------------------------------------------------
 * Refusal vocabulary. Every refusal cause is distinct and named; §4.3 forbids
 * silently applying a non-atomic or instruction-stealing patch.
 * ------------------------------------------------------------------------- */

enum {
  REPRO_HCR_LX_OK = 0,
  REPRO_HCR_LX_REFUSED_ABSENT_SLED = 1,
  REPRO_HCR_LX_REFUSED_NON_NOP_SLED = 2,
  REPRO_HCR_LX_REFUSED_SHORT_SLED = 3,
  REPRO_HCR_LX_REFUSED_MISALIGNED_ENTRY = 4,
  REPRO_HCR_LX_REFUSED_WINDOW_NOT_INSTRUCTION_BOUNDARY = 5,
  REPRO_HCR_LX_REFUSED_ENTRY_MODIFIED_EXTERNALLY = 6,
  REPRO_HCR_LX_REFUSED_TARGET_OUT_OF_RANGE = 7,
  REPRO_HCR_LX_REFUSED_UNSUPPORTED_HOST = 8,
  REPRO_HCR_LX_REFUSED_NO_PATCH_MEMORY = 9,
  REPRO_HCR_LX_REFUSED_TEXT_PROTECTION_FAILED = 10,
  REPRO_HCR_LX_REFUSED_PATCH_MEMORY_PROTECTION_FAILED = 11,
  REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT = 12,
  REPRO_HCR_LX_REFUSED_SITE_TABLE_FULL = 13,
  /* HLX-M7, design §10.1: MCR's own patchers had already claimed bytes in the
   * window this provider was about to publish into. Distinct from every
   * refusal above because it is not a property of the target's code — the same
   * function is patchable in the same process a moment earlier or later — and
   * because §10.1 requires it be REPORTED to the client as
   * `skippedFunctions[].reason == "claimed-by-recorder"` rather than folded
   * into a whole-patch failure. */
  REPRO_HCR_LX_REFUSED_CLAIMED_BY_RECORDER = 14,
  /* HLX-M4, closing `HLX-OQ-3`. The host cannot give us a
   * context-synchronizing event on every core running the process, AND the
   * caller is not holding quiescence — under which the signal round trip
   * supplies one instead. Publishing anyway is the behaviour this refusal
   * replaces: before HLX-M4 the provider recorded `membarrier_result = -1` and
   * stored into live text regardless, which is precisely the "executing
   * processor performs no serializing operation" case Intel SDM §8.1.3/§9.3
   * leaves undefined. */
  REPRO_HCR_LX_REFUSED_SYNC_CORE_UNAVAILABLE = 15,
  /* HLX-M4, design §6.3. Quiescence was required (the target has more than one
   * thread) and could not be reached inside the bounded wait. The defined
   * outcome is: release everyone who parked, write NOTHING, and report naming
   * the unresponsive tids. Distinct from every refusal above because it is a
   * property of the RUNNING PROCESS at this instant, not of the target's code
   * or the host — the same function is patchable a moment later. */
  REPRO_HCR_LX_REFUSED_QUIESCENCE_FAILED = 16,
  /* HLX-M2, design §4.2 and §12 item 1. The patch body is outside `rel32`
   * reach of the publication window AND no 14-byte island could be placed
   * within +/-2 GiB of that window. Distinct from
   * `patch-body-out-of-rel32-range`, which is the ENCODER refusing a
   * displacement it was handed: this one is the ALLOCATOR reporting that the
   * indirection which exists to make such a displacement unnecessary has
   * nowhere to live. The defined outcome is a refusal reported in
   * `skippedFunctions`; widening the published store to 13 or 14 bytes — which
   * is what `Trampoline-Mechanics.md` §6's unamended ladder would have chosen —
   * is never an option, because a 14-byte write into live text is not
   * atomically publishable. */
  REPRO_HCR_LX_REFUSED_ISLAND_UNPLACEABLE = 17
};

static const char *repro_hcr_lx_refusal_name(int code) {
  switch (code) {
    case REPRO_HCR_LX_OK:
      return "ok";
    case REPRO_HCR_LX_REFUSED_ABSENT_SLED:
      return "absent-sled";
    case REPRO_HCR_LX_REFUSED_NON_NOP_SLED:
      return "non-nop-sled";
    case REPRO_HCR_LX_REFUSED_SHORT_SLED:
      return "short-sled";
    case REPRO_HCR_LX_REFUSED_MISALIGNED_ENTRY:
      return "misaligned-entry";
    case REPRO_HCR_LX_REFUSED_WINDOW_NOT_INSTRUCTION_BOUNDARY:
      return "sled-window-not-instruction-boundary";
    case REPRO_HCR_LX_REFUSED_ENTRY_MODIFIED_EXTERNALLY:
      return "entry-modified-externally";
    case REPRO_HCR_LX_REFUSED_TARGET_OUT_OF_RANGE:
      return "patch-body-out-of-rel32-range";
    case REPRO_HCR_LX_REFUSED_UNSUPPORTED_HOST:
      return "unsupported-host";
    case REPRO_HCR_LX_REFUSED_NO_PATCH_MEMORY:
      return "patch-memory-unavailable";
    case REPRO_HCR_LX_REFUSED_TEXT_PROTECTION_FAILED:
      return "text-protection-failed";
    case REPRO_HCR_LX_REFUSED_PATCH_MEMORY_PROTECTION_FAILED:
      return "patch-memory-protection-failed";
    case REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT:
      return "invalid-argument";
    case REPRO_HCR_LX_REFUSED_SITE_TABLE_FULL:
      return "site-table-full";
    case REPRO_HCR_LX_REFUSED_CLAIMED_BY_RECORDER:
      return "claimed-by-recorder";
    case REPRO_HCR_LX_REFUSED_SYNC_CORE_UNAVAILABLE:
      return "sync-core-unavailable";
    case REPRO_HCR_LX_REFUSED_QUIESCENCE_FAILED:
      return "quiescence-failed";
    case REPRO_HCR_LX_REFUSED_ISLAND_UNPLACEABLE:
      return "island-unplaceable";
    default:
      return "unknown-refusal";
  }
}

/* ---------------------------------------------------------------------------
 * Raw syscalls. Design §5.1: `mprotect` must NOT go through libc, because in a
 * process where MCR's libct_interpose is loaded libc's `mprotect` is interposed
 * and calling it from the patcher re-enters the recording path.
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_LX_NR_MPROTECT 10
#define REPRO_HCR_LX_NR_MEMBARRIER 324
#define REPRO_HCR_LX_NR_PRCTL 157
#define REPRO_HCR_LX_NR_MMAP 9
#define REPRO_HCR_LX_NR_MUNMAP 11
#define REPRO_HCR_LX_NR_FTRUNCATE 77
#define REPRO_HCR_LX_NR_FCNTL 72
#define REPRO_HCR_LX_NR_MEMFD_CREATE 319

/* linux/memfd.h and linux/fcntl.h. HLX-M9. */
#define REPRO_HCR_LX_MFD_CLOEXEC 0x0001U
#define REPRO_HCR_LX_MFD_ALLOW_SEALING 0x0002U
#define REPRO_HCR_LX_F_ADD_SEALS 1033
#define REPRO_HCR_LX_F_GET_SEALS 1034
#define REPRO_HCR_LX_F_SEAL_SEAL 0x0001
#define REPRO_HCR_LX_F_SEAL_SHRINK 0x0002
#define REPRO_HCR_LX_F_SEAL_GROW 0x0004
#define REPRO_HCR_LX_F_SEAL_WRITE 0x0008
#define REPRO_HCR_LX_FINAL_SEALS                                               \
  (REPRO_HCR_LX_F_SEAL_SEAL | REPRO_HCR_LX_F_SEAL_SHRINK |                     \
   REPRO_HCR_LX_F_SEAL_GROW | REPRO_HCR_LX_F_SEAL_WRITE)

#define REPRO_HCR_LX_MAP_SHARED 0x01
#define REPRO_HCR_LX_MAP_PRIVATE 0x02
#define REPRO_HCR_LX_MAP_ANONYMOUS 0x20

/* linux/prctl.h. `PR_GET_MDWE` is read, never set: the provider asks what
 * policy the process is already under so a capability refusal can NAME it
 * instead of describing its symptom. Kernels before 6.3 answer -EINVAL, which
 * is a distinct answer from "no MDWE" and is reported as such. */
#define REPRO_HCR_LX_PR_GET_MDWE 66
#define REPRO_HCR_LX_PR_MDWE_REFUSE_EXEC_GAIN 1
#define REPRO_HCR_LX_PR_MDWE_NO_INHERIT 2

#define REPRO_HCR_LX_PROT_READ 0x1
#define REPRO_HCR_LX_PROT_WRITE 0x2
#define REPRO_HCR_LX_PROT_EXEC 0x4

/* linux/membarrier.h; asserted against the kernel headers by the unit gate. */
#define REPRO_HCR_LX_MEMBARRIER_CMD_QUERY 0
#define REPRO_HCR_LX_MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE (1 << 5)
#define REPRO_HCR_LX_MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED_SYNC_CORE (1 << 6)

static long repro_hcr_lx_syscall3(long number, long a0, long a1, long a2) {
  long result;
  __asm__ volatile("syscall"
                   : "=a"(result)
                   : "a"(number), "D"(a0), "S"(a1), "d"(a2)
                   : "rcx", "r11", "memory");
  return result;
}

/* Returns 0 on success, or the negated errno the kernel reported. */
static long repro_hcr_lx_raw_mprotect(uint64_t address, size_t length,
                                      int protection) {
  return repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_MPROTECT, (long)address,
                               (long)length, (long)protection);
}

static long repro_hcr_lx_raw_membarrier(int command, unsigned int flags) {
  return repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_MEMBARRIER, (long)command,
                               (long)flags, 0);
}

/* HLX-M9. Returns the process's MDWE flags, or the negated errno. Raw for the
 * same reason `mprotect` is: in a process carrying MCR's interpose library,
 * libc entry points are not the provider's to call from the patch path.
 *
 * FIVE ARGUMENTS, and that is load-bearing rather than pedantic. `prctl` takes
 * five and `PR_GET_MDWE` REQUIRES arg2..arg4 to be zero, so issuing it through
 * a three-argument wrapper leaves `r10`/`r8`/`r9` holding whatever the caller
 * left there and the kernel answers `-EINVAL`. Measured: with the
 * three-argument spelling this returned -22 on a kernel that implements
 * `PR_GET_MDWE` perfectly well, and the provider then reported "this kernel
 * does not implement PR_GET_MDWE" — a confidently wrong diagnostic, which is
 * the worst outcome for a field whose entire job is to NAME the policy. */
static long repro_hcr_lx_syscall5(long number, long a0, long a1, long a2,
                                  long a3, long a4) {
  long result;
  register long r10 __asm__("r10") = a3;
  register long r8 __asm__("r8") = a4;
  register long r9 __asm__("r9") = 0;
  __asm__ volatile("syscall"
                   : "=a"(result)
                   : "a"(number), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8),
                     "r"(r9)
                   : "rcx", "r11", "memory");
  return result;
}

static long repro_hcr_lx_raw_get_mdwe(void) {
  return repro_hcr_lx_syscall5(REPRO_HCR_LX_NR_PRCTL,
                               (long)REPRO_HCR_LX_PR_GET_MDWE, 0, 0, 0, 0);
}

/* Tier-2 quiescence (design §6.2/§6.3, HLX-M4). Included here rather than by
 * the agent translation unit because `repro_hcr_lx_apply_direct_patch_at` below
 * consults `repro_hcr_lx_quiesce_is_held()` for the `HLX-OQ-3` fallback: with no
 * `SYNC_CORE` available, the signal round trip is what supplies the
 * context-synchronizing event, so whether quiescence is held decides between
 * publishing and refusing. The header reuses `repro_hcr_lx_syscall3` above and
 * is not standalone. */
#include "repro_hcr_linux_quiesce.h"

/* ---------------------------------------------------------------------------
 * x86_64 NOP decoding.
 *
 * Design §4.2: "genuinely NOPs" is a decode question, not a byte compare. GCC
 * emits N single-byte 0x90 for the patchable sled, but Clang emits a maximal
 * multi-byte NOP (measured: a single 15-byte `data16 x5 cs nopw 0x200(%rax,%rax)`
 * for `-fpatchable-function-entry=16,0`). `ct_inline_hook/length_decoder` is
 * length-only and exports no NOP predicate, so this is new code.
 *
 * Returns the instruction length in bytes if the bytes at `p` decode as a NOP,
 * or 0 if they do not (including truncation against `avail`).
 * ------------------------------------------------------------------------- */

static size_t repro_hcr_lx_nop_length(const uint8_t *p, size_t avail) {
  size_t i = 0;
  uint8_t modrm;
  uint8_t mod_bits;
  uint8_t rm_bits;
  uint8_t sib = 0;
  int have_sib = 0;
  size_t j;

  if (p == NULL || avail == 0) {
    return 0;
  }

  /* Legacy prefixes that may legally decorate a NOP, plus REX. */
  while (i < avail) {
    uint8_t b = p[i];
    if (b == 0x66 || b == 0x2e || b == 0x3e || b == 0x26 || b == 0x36 ||
        b == 0x64 || b == 0x65 || (b >= 0x40 && b <= 0x4f)) {
      i++;
      continue;
    }
    break;
  }
  if (i >= avail) {
    return 0;
  }

  /* `0x90` — and, with a 0x66 prefix, `xchg %ax,%ax`. */
  if (p[i] == 0x90) {
    return i + 1;
  }

  /* `0F 1F /0` multi-byte NOP. */
  if (p[i] != 0x0f) {
    return 0;
  }
  if (i + 1 >= avail || p[i + 1] != 0x1f) {
    return 0;
  }
  j = i + 2;
  if (j >= avail) {
    return 0;
  }
  modrm = p[j];
  j++;
  mod_bits = (uint8_t)(modrm >> 6);
  rm_bits = (uint8_t)(modrm & 0x7);
  if (mod_bits == 0x3) {
    /* register form is not a canonical NOP encoding; refuse rather than guess */
    return 0;
  }
  if (rm_bits == 0x4) {
    if (j >= avail) {
      return 0;
    }
    sib = p[j];
    have_sib = 1;
    j++;
  }
  if (mod_bits == 0x1) {
    j += 1;
  } else if (mod_bits == 0x2) {
    j += 4;
  } else if (mod_bits == 0x0) {
    if (rm_bits == 0x5) {
      j += 4; /* RIP-relative disp32 */
    } else if (have_sib && (sib & 0x7) == 0x5) {
      j += 4; /* SIB with no base: disp32 */
    }
  }
  if (j > avail) {
    return 0;
  }
  return j;
}

/* ---------------------------------------------------------------------------
 * Sled planning.
 *
 * `sled_bytes` is a view of `sled_capacity` bytes starting at `sled_address`.
 * The NOP run is the maximal prefix of that view that decodes as NOP
 * instructions. The publication window is the LOWEST 8-byte-aligned address W
 * such that
 *
 *   (a) W lies at an instruction boundary of the decoded NOP run, so a call
 *       falling through the sled reaches the published `E9` at a boundary; and
 *   (b) [W, W+8) lies wholly inside the NOP run.
 *
 * (a) is not redundant with (b): measured, Clang under `-fcf-protection`
 * emits the whole 16-byte sled as one 15-byte NOP plus one 0x90, whose only
 * interior boundary is at sled+15. Publishing at sled+4 would splice our jump
 * into the middle of a live instruction.
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_LX_MAX_SLED_SCAN 64u
#define REPRO_HCR_LX_WINDOW_BYTES 8u
#define REPRO_HCR_LX_JMP_REL32_BYTES 5u

typedef struct repro_hcr_lx_sled_plan {
  uint64_t sled_address;
  uint64_t sled_end;      /* first byte after the NOP run */
  uint32_t sled_length;   /* sled_end - sled_address */
  uint64_t window_address;/* valid only when refusal == REPRO_HCR_LX_OK */
  uint32_t window_offset; /* window_address - sled_address */
  int refusal;
} repro_hcr_lx_sled_plan;

static int repro_hcr_lx_plan_sled(const uint8_t *sled_bytes,
                                  size_t sled_capacity, uint64_t sled_address,
                                  repro_hcr_lx_sled_plan *out) {
  size_t offset = 0;
  size_t scan_limit;
  uint64_t candidate;
  int aligned_window_exists = 0;

  if (out == NULL) {
    return REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
  }
  memset(out, 0, sizeof(*out));
  out->sled_address = sled_address;
  out->sled_end = sled_address;
  if (sled_bytes == NULL || sled_capacity == 0) {
    out->refusal = REPRO_HCR_LX_REFUSED_ABSENT_SLED;
    return out->refusal;
  }

  scan_limit = sled_capacity < REPRO_HCR_LX_MAX_SLED_SCAN
                   ? sled_capacity
                   : REPRO_HCR_LX_MAX_SLED_SCAN;

  while (offset < scan_limit) {
    size_t len = repro_hcr_lx_nop_length(sled_bytes + offset,
                                         scan_limit - offset);
    if (len == 0) {
      break;
    }
    offset += len;
  }
  out->sled_end = sled_address + (uint64_t)offset;
  out->sled_length = (uint32_t)offset;

  if (offset == 0) {
    out->refusal = REPRO_HCR_LX_REFUSED_NON_NOP_SLED;
    return out->refusal;
  }
  if (offset < REPRO_HCR_LX_WINDOW_BYTES) {
    out->refusal = REPRO_HCR_LX_REFUSED_SHORT_SLED;
    return out->refusal;
  }

  /* Does any 8-byte-aligned 8-byte window lie wholly inside the run at all? */
  candidate = (sled_address + 7u) & ~(uint64_t)7u;
  aligned_window_exists =
      (candidate + REPRO_HCR_LX_WINDOW_BYTES <= out->sled_end) ? 1 : 0;
  if (!aligned_window_exists) {
    /* The run is long enough in bytes but its placement admits no aligned
     * window: an alignment defect of the entry, not a length defect. */
    out->refusal = REPRO_HCR_LX_REFUSED_MISALIGNED_ENTRY;
    return out->refusal;
  }

  /* Walk the instruction boundaries and take the lowest that is 8-aligned and
   * whose window fits. */
  offset = 0;
  while (offset < out->sled_length) {
    uint64_t boundary = sled_address + (uint64_t)offset;
    size_t len;
    if ((boundary & 7u) == 0 &&
        boundary + REPRO_HCR_LX_WINDOW_BYTES <= out->sled_end) {
      out->window_address = boundary;
      out->window_offset = (uint32_t)offset;
      out->refusal = REPRO_HCR_LX_OK;
      return out->refusal;
    }
    len = repro_hcr_lx_nop_length(sled_bytes + offset,
                                  (size_t)out->sled_length - offset);
    if (len == 0) {
      break;
    }
    offset += len;
  }

  out->refusal = REPRO_HCR_LX_REFUSED_WINDOW_NOT_INSTRUCTION_BOUNDARY;
  return out->refusal;
}

/* ---------------------------------------------------------------------------
 * Trampoline encoding: `E9 rel32`, published inside one aligned 8-byte word.
 * ------------------------------------------------------------------------- */

static int repro_hcr_lx_encode_jmp_rel32(uint64_t window_address,
                                         uint64_t target_address,
                                         uint8_t out_bytes[5]) {
  int64_t displacement;
  uint32_t rel;
  if (out_bytes == NULL) {
    return REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
  }
  displacement = (int64_t)target_address -
                 (int64_t)(window_address + REPRO_HCR_LX_JMP_REL32_BYTES);
  if (displacement < -2147483648LL || displacement > 2147483647LL) {
    return REPRO_HCR_LX_REFUSED_TARGET_OUT_OF_RANGE;
  }
  rel = (uint32_t)(int32_t)displacement;
  out_bytes[0] = 0xe9;
  out_bytes[1] = (uint8_t)(rel & 0xffu);
  out_bytes[2] = (uint8_t)((rel >> 8) & 0xffu);
  out_bytes[3] = (uint8_t)((rel >> 16) & 0xffu);
  out_bytes[4] = (uint8_t)((rel >> 24) & 0xffu);
  return REPRO_HCR_LX_OK;
}

/* `E9 dd dd dd dd 90 90 90`, little-endian, as design §4.2 specifies. */
static uint64_t repro_hcr_lx_published_word(const uint8_t jmp_bytes[5]) {
  uint8_t window[REPRO_HCR_LX_WINDOW_BYTES];
  uint64_t word = 0;
  memcpy(window, jmp_bytes, REPRO_HCR_LX_JMP_REL32_BYTES);
  window[5] = 0x90;
  window[6] = 0x90;
  window[7] = 0x90;
  memcpy(&word, window, sizeof(word));
  return word;
}

static int repro_hcr_lx_rel32_reachable(uint64_t window_address,
                                        uint64_t target_address) {
  uint8_t scratch[5];
  return repro_hcr_lx_encode_jmp_rel32(window_address, target_address,
                                       scratch) == REPRO_HCR_LX_OK;
}

/* ---------------------------------------------------------------------------
 * `__patchable_function_entries` lookup — NOT HERE ANY MORE (HLX-M2).
 *
 * HLX-M0 read the table through the linker-synthesised
 * `__start___patchable_function_entries` / `__stop___patchable_function_entries`
 * symbols, which name exactly one object's section: whichever image the agent's
 * own translation unit was linked into. That made a function living in a
 * `dlopen`'d shared library resolve (HLX-M1) and then refuse `absent-sled`,
 * which HLX-M1's residue recorded as owned by this milestone.
 *
 * The lookup now lives in `repro_hcr_linux_elf_symbols.h` as
 * `repro_hcr_elf_sled_address_for_entry`, because it needs the same
 * `dl_iterate_phdr` enumeration and the same per-object load bias the symbol
 * resolver uses. It is supplied to `repro_hcr_lx_apply_direct_patch_at` through
 * its `sled_address` parameter, exactly as before — this header still knows
 * nothing about ELF, and there is exactly ONE sled-discovery path in the
 * provider rather than a general one plus a main-executable fast path.
 * ------------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------
 * Host capability probe (design §5.2).
 *
 * MDWE's measured failure mode is that the RW step SUCCEEDS and only the
 * restore of PROT_EXEC fails, which would leave the target's own text
 * permanently non-executable. So the round trip is probed on a provider-owned
 * scratch mapping at agent start and the host is refused at negotiation, never
 * discovered mid-commit.
 * ------------------------------------------------------------------------- */

typedef struct repro_hcr_lx_capabilities {
  int probed;
  int text_protection_roundtrip;   /* 1 when RW->RX round trip works */
  long protection_probe_rw_result; /* raw syscall result, negated errno on fail */
  long protection_probe_rx_result;
  int membarrier_sync_core;        /* 1 when SYNC_CORE is registered and usable */
  long membarrier_query_mask;
  long membarrier_register_result;
  /* HLX-M4. 1 when the host permits a transient RW|EXEC mapping of live text.
   * This is NOT a nicety. The publication's writable step is an `mprotect` over
   * the page the target is EXECUTING FROM; dropping `PROT_EXEC` for the
   * duration means any thread whose PC is anywhere in that 4 KiB page — not
   * just in the 8-byte window — takes an instruction-fetch fault and dies.
   * With `PROT_EXEC` retained the page stays runnable across the store, and the
   * only remaining concurrency hazard is design §6.1 point 4. */
  int text_rwx_transition;
  long protection_probe_rwx_result;
  int text_left_writable;          /* set if a PROT_EXEC restore ever failed */
  /* HLX-M9. `PR_GET_MDWE` for this process: the flags, or a negated errno.
   * Read so a capability-time refusal can NAME the blocking policy instead of
   * describing its symptom. A host that refuses the round trip WITHOUT MDWE
   * set is a different finding from one that refuses it because MDWE is set,
   * and the two must not be reported with the same sentence. */
  long mdwe_flags;
  /* HX-L-2: 1 when target uses Clang + CET, whose maximal-length NOP sleds
   * placed after `endbr64` leave no admissible 8-byte-aligned window. */
  int clang_cet_unsupported;
} repro_hcr_lx_capabilities;

static repro_hcr_lx_capabilities repro_hcr_lx_caps;
static int repro_hcr_lx_pretend_clang_cet_unsupported = 0;

/* The capability probe may be linked without a patchable-entry section.
 * These bounds are not used by the per-object ELF sled lookup. */
extern const uintptr_t __start___patchable_function_entries[]
    __attribute__((weak));
extern const uintptr_t __stop___patchable_function_entries[]
    __attribute__((weak));

static void repro_hcr_lx_internal_set_pretend_clang_cet_unsupported(int val) {
  repro_hcr_lx_pretend_clang_cet_unsupported = val;
  repro_hcr_lx_caps.clang_cet_unsupported = val ? 1 : 0;
}

/* Provided by the including translation unit: page-aligned anonymous mapping.
 * Kept as a hook so the probe shim and the agent can share this header without
 * the header itself depending on <sys/mman.h> declarations. */
static void *repro_hcr_lx_map_anonymous(void *hint, size_t length,
                                        int protection, int extra_flags);
static int repro_hcr_lx_unmap(void *address, size_t length);
static size_t repro_hcr_lx_page_size(void);

static void repro_hcr_lx_probe_capabilities(void) {
  size_t page_size;
  void *scratch;

  if (repro_hcr_lx_caps.probed) {
    if (repro_hcr_lx_pretend_clang_cet_unsupported) {
      repro_hcr_lx_caps.clang_cet_unsupported = 1;
    }
    return;
  }
  repro_hcr_lx_caps.probed = 1;

  if (repro_hcr_lx_pretend_clang_cet_unsupported) {
    repro_hcr_lx_caps.clang_cet_unsupported = 1;
  } else {
    repro_hcr_lx_caps.clang_cet_unsupported = 0;
    const uintptr_t *start = __start___patchable_function_entries;
    const uintptr_t *stop = __stop___patchable_function_entries;
    if (start != NULL && stop != NULL && stop > start) {
      size_t count = (size_t)(stop - start);
      for (size_t i = 0; i < count; ++i) {
        uint64_t sled_addr = (uint64_t)start[i];
        if (sled_addr >= 4) {
          const uint8_t *entry = (const uint8_t *)(uintptr_t)(sled_addr - 4);
          /* Check whether entry begins with endbr64 landing pad (0xf3, 0x0f, 0x1e, 0xfa) */
          if (entry[0] == 0xf3 && entry[1] == 0x0f && entry[2] == 0x1e && entry[3] == 0xfa) {
            /* Check whether sled begins with a multi-byte NOP (> 1 byte, e.g. Clang 15-byte NOP) */
            size_t first_nop_len = repro_hcr_lx_nop_length((const uint8_t *)(uintptr_t)sled_addr, 16u);
            if (first_nop_len > 1) {
              repro_hcr_lx_sled_plan plan;
              int rc = repro_hcr_lx_plan_sled((const uint8_t *)(uintptr_t)sled_addr, 16u, sled_addr, &plan);
              if (rc == REPRO_HCR_LX_REFUSED_WINDOW_NOT_INSTRUCTION_BOUNDARY) {
                repro_hcr_lx_caps.clang_cet_unsupported = 1;
                break;
              }
            }
          }
        }
      }
    }
  }

  repro_hcr_lx_caps.membarrier_query_mask =
      repro_hcr_lx_raw_membarrier(REPRO_HCR_LX_MEMBARRIER_CMD_QUERY, 0);
  repro_hcr_lx_caps.membarrier_register_result = repro_hcr_lx_raw_membarrier(
      REPRO_HCR_LX_MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED_SYNC_CORE, 0);
  repro_hcr_lx_caps.membarrier_sync_core =
      (repro_hcr_lx_caps.membarrier_query_mask > 0 &&
       (repro_hcr_lx_caps.membarrier_query_mask &
        REPRO_HCR_LX_MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE) != 0 &&
       repro_hcr_lx_caps.membarrier_register_result == 0)
          ? 1
          : 0;

  repro_hcr_lx_caps.mdwe_flags = repro_hcr_lx_raw_get_mdwe();

  page_size = repro_hcr_lx_page_size();
  scratch = repro_hcr_lx_map_anonymous(
      NULL, page_size, REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_EXEC, 0);
  if (scratch == NULL) {
    repro_hcr_lx_caps.text_protection_roundtrip = 0;
    return;
  }
  repro_hcr_lx_caps.protection_probe_rw_result = repro_hcr_lx_raw_mprotect(
      (uint64_t)(uintptr_t)scratch, page_size,
      REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE);
  if (repro_hcr_lx_caps.protection_probe_rw_result == 0) {
    /* Prove the mapping really is writable, not merely reported so. */
    memset(scratch, 0x90, REPRO_HCR_LX_WINDOW_BYTES);
    repro_hcr_lx_caps.protection_probe_rx_result = repro_hcr_lx_raw_mprotect(
        (uint64_t)(uintptr_t)scratch, page_size,
        REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_EXEC);
  } else {
    repro_hcr_lx_caps.protection_probe_rx_result = -1;
  }
  repro_hcr_lx_caps.text_protection_roundtrip =
      (repro_hcr_lx_caps.protection_probe_rw_result == 0 &&
       repro_hcr_lx_caps.protection_probe_rx_result == 0)
          ? 1
          : 0;
  /*
   * Probed on the same provider-owned scratch page, for the same reason the
   * RW/RX round trip is: a host that refuses RWX must be discovered at agent
   * start, not in the middle of a publication. MDWE and some SELinux policies
   * refuse it; on such a host the provider falls back to the plain RW
   * transient, which drops `PROT_EXEC` for the whole 4 KiB page and so faults
   * ANY thread whose PC is anywhere in it.
   *
   * WHERE THAT COUPLING IS ACTUALLY ENFORCED, stated precisely because this
   * comment used to claim a check that did not exist ("therefore REQUIRES
   * quiescence"): there is no `text_rwx_transition`-conditioned refusal in
   * this file. The property holds for the production path only because
   * `repro_hcr_apply_direct_patch` quiesces whenever the target has more than
   * one thread, independently of RWX. A caller that reaches
   * `repro_hcr_lx_apply_direct_patch_at` directly, as the test probe shim
   * does, gets no such protection on a host that refuses RWX. Recorded as a
   * known gap rather than asserted as a guarantee; a host that refuses RWX is
   * needed to gate it and none is available here.
   */
  repro_hcr_lx_caps.protection_probe_rwx_result = repro_hcr_lx_raw_mprotect(
      (uint64_t)(uintptr_t)scratch, page_size,
      REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE |
          REPRO_HCR_LX_PROT_EXEC);
  repro_hcr_lx_caps.text_rwx_transition =
      repro_hcr_lx_caps.protection_probe_rwx_result == 0 ? 1 : 0;
  if (repro_hcr_lx_caps.text_rwx_transition) {
    (void)repro_hcr_lx_raw_mprotect(
        (uint64_t)(uintptr_t)scratch, page_size,
        REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_EXEC);
  }
  repro_hcr_lx_unmap(scratch, page_size);
}

static const repro_hcr_lx_capabilities *repro_hcr_lx_capability_report(void) {
  repro_hcr_lx_probe_capabilities();
  return &repro_hcr_lx_caps;
}

/* ---------------------------------------------------------------------------
 * HLX-M4 levers and counters over the publication's SECOND half.
 *
 * Design §6.1's safety argument has two halves — the aligned store and the
 * `SYNC_CORE` event — and the milestone requires that "the test must be able to
 * remove the second and observe the difference". These three objects are that
 * ability, and they are also how a gate proves the event is ISSUED rather than
 * merely coded for: a membarrier that is never reached looks exactly like one
 * that always succeeds if nothing counts it.
 *
 * `repro_hcr_lx_sync_core_suppressed` is a test-only lever. It does NOT fake
 * the capability away — `repro_hcr_lx_pretend_sync_core_unavailable` does that,
 * for the `HLX-OQ-3` refusal arm. The two are separate because they exercise
 * opposite paths: suppression publishes without the event (to measure whether
 * the event matters), while pretending it is unavailable must REFUSE to
 * publish at all. The agent sets neither.
 * ------------------------------------------------------------------------- */

static int repro_hcr_lx_sync_core_suppressed = 0;
static int repro_hcr_lx_pretend_sync_core_unavailable = 0;
static uint64_t repro_hcr_lx_membarrier_issued_count = 0;
static uint64_t repro_hcr_lx_publication_count = 0;

/* The effective answer to "can this host give us a context-synchronizing event
 * on every core running the process?". Routed through one function so the
 * refusal below and the issuance after the store cannot disagree. */
static int repro_hcr_lx_sync_core_available(void) {
  if (repro_hcr_lx_pretend_sync_core_unavailable) {
    return 0;
  }
  return repro_hcr_lx_capability_report()->membarrier_sync_core;
}

/* ---------------------------------------------------------------------------
 * Per-site bookkeeping for re-patching (design §4.5).
 *
 * The window's admissible pre-states are exactly two: an all-NOP window, or a
 * window this provider itself published and still owns. Without this the
 * provider would refuse every reload after the first, because the published
 * window holds `E9 rel32 90 90 90` rather than NOPs — it would work exactly
 * once.
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_LX_MAX_SITES 128

typedef struct repro_hcr_lx_site {
  int used;
  uint64_t entry_address;
  uint64_t sled_address;
  uint64_t sled_end;       /* first byte after the decoded NOP run; retained so
                            * a re-patch can still walk sled boundaries for the
                            * tier-2 IP adjustment (HLX-M4) */
  uint64_t window_address;
  uint64_t original_word;  /* rollback target; always the ORIGINAL, never the
                            * previous generation (design §4.5) */
  uint64_t published_word;
  uint64_t generation;
  /* HLX-M3, design §11.2/§4.5. `original_word_saved` is the flag behind
   * `oldCodeRetained`: the site table is holding this window's pre-patch word
   * and can restore it. `retained_body_count` counts the patch bodies this
   * site has accumulated — one per generation, superseded ones included,
   * because §4.5 retains them rather than freeing them. Together they are the
   * provider's `retainedRegionAddresses`. */
  int original_word_saved;
  uint32_t retained_body_count;
  /* HLX-M7 §10.1: the claim on this window is taken once, at the FIRST
   * publication, and RETAINED across re-patch generations. Re-claiming on
   * generation 2 would be refused by our own live claim, and releasing between
   * generations would open a window in which MCR could take the bytes out from
   * under a site this provider is still publishing into. */
  int claimed;
} repro_hcr_lx_site;

static repro_hcr_lx_site repro_hcr_lx_sites[REPRO_HCR_LX_MAX_SITES];

static repro_hcr_lx_site *repro_hcr_lx_find_site(uint64_t entry_address) {
  int i;
  for (i = 0; i < REPRO_HCR_LX_MAX_SITES; ++i) {
    if (repro_hcr_lx_sites[i].used &&
        repro_hcr_lx_sites[i].entry_address == entry_address) {
      return &repro_hcr_lx_sites[i];
    }
  }
  return NULL;
}

static repro_hcr_lx_site *repro_hcr_lx_claim_site(uint64_t entry_address) {
  int i;
  for (i = 0; i < REPRO_HCR_LX_MAX_SITES; ++i) {
    if (!repro_hcr_lx_sites[i].used) {
      memset(&repro_hcr_lx_sites[i], 0, sizeof(repro_hcr_lx_sites[i]));
      repro_hcr_lx_sites[i].used = 1;
      repro_hcr_lx_sites[i].entry_address = entry_address;
      return &repro_hcr_lx_sites[i];
    }
  }
  return NULL;
}

/* ---------------------------------------------------------------------------
 * Patch-body placement and publication.
 *
 * The Mach `vm_protect` max-protection ceiling fallback the Apple arm of
 * `repro_hcr_agent.c` carries is deliberately NOT translated (design §5.1):
 * raising a Mach region's maximum protection has no Linux analogue — ELF
 * `PT_LOAD` has `p_flags` and no separate maximum — and the `__HCR` segment
 * scheme that supports it has no ELF counterpart either.
 *
 * Single-threaded scope: HLX-M0 proves a Linux patch path exists. It does not
 * exercise the cross-core or in-window-PC hazards of design §4.4 and §6.1, and
 * nothing here may be reported as safe for a multithreaded target until
 * HLX-M4.
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_LX_MAP_FIXED_NOREPLACE 0x100000

static uint64_t repro_hcr_lx_page_start(uint64_t address, size_t page_size) {
  return address & ~((uint64_t)page_size - 1u);
}

/* ---------------------------------------------------------------------------
 * HLX-M9 — PROVIDER-OWNED CODE PAGES AS A `memfd_create` DUAL MAPPING.
 *
 * WHAT THIS REPLACES, AND WHY.
 *
 * Every page the provider owns — a patch body, an island page — used to be
 * `mmap(MAP_ANONYMOUS, PROT_READ|PROT_WRITE)`, written, then
 * `mprotect(PROT_READ|PROT_EXEC)`. That is a W^X violation in the exact shape
 * a hardened kernel forbids: a mapping that has been writable regains
 * `PROT_EXEC`. Under `PR_MDWE_REFUSE_EXEC_GAIN` the second `mprotect` fails
 * with `EACCES` (measured on Linux 6.12.85).
 *
 * The island path is worse than that, and the comment in
 * `repro_hcr_lx_allocate_island` says why: a page that already holds LIVE
 * islands cannot drop `PROT_EXEC` while a new island is written into it, so
 * reuse needs a transient `RW|EXEC` — which the same policies refuse outright.
 * On such a host island pages are simply never reused and the pool exhausts.
 *
 * THE DUAL MAPPING. One `memfd`, mapped twice:
 *
 *   exec view   `MAP_PRIVATE  | PROT_READ | PROT_EXEC`   (where code runs)
 *   writer view `MAP_SHARED   | PROT_READ | PROT_WRITE`  (where code is put)
 *
 * The exec view is created executable and is NEVER writable, so no policy that
 * refuses "exec gain" is engaged. Writes go through the separate shared alias
 * and become visible through the private view, with no protection change on
 * the executing mapping at any point — which is what makes an island page
 * reusable while the islands already on it are live.
 *
 * WHY THE EXEC VIEW IS `MAP_PRIVATE`, AND THIS IS THE ONE THING TO GET RIGHT.
 * `F_SEAL_WRITE` is refused `EBUSY` while ANY `MAP_SHARED` mapping of the
 * memfd exists — including a `PROT_READ|PROT_EXEC` one, because the kernel's
 * writable-mapping count is keyed on `VM_SHARED` and not on `PROT_WRITE`.
 * Measured, all four orderings, with and without MDWE: with a shared exec view
 * the seal fails and a later writable mapping is still granted, i.e. the page
 * is NOT sealed and a gate asserting only "we called F_ADD_SEALS" would be
 * green over it. With a private exec view the seal succeeds and the kernel
 * then refuses a writable mapping `EPERM`.
 *
 * `MAP_PRIVATE` is copy-on-write, so the private view would stop tracking the
 * shared alias if anything ever WROTE through it. Nothing can: it carries no
 * `PROT_WRITE` and a write faults. Measured rather than argued — a page is
 * executed, a later slot is written through the alias, the new slot runs and
 * the earlier one is unchanged.
 *
 * FINALIZATION. When a page will receive no further writes, the writer alias
 * is unmapped and `F_SEAL_WRITE` (with `SHRINK`/`GROW`/`SEAL`) is applied, so
 * no writable alias to executable memory can ever be created again — not by
 * this provider and not by anything else holding the fd. The fd is closed
 * immediately afterwards; the mapping keeps the memfd alive.
 *
 * EVERY SYSCALL HERE IS RAW, AND THAT IS A DECISION, NOT A STYLE.
 * See `repro_hcr_lx_memfd_dual_supported` for the reasoning and for its
 * coupling to HLX-M7 (MCR interposes libc, and a provider fd MCR sees used but
 * never sees created would make the recording inconsistent — so the provider
 * takes the whole fd lifecycle out of MCR's view rather than half of it).
 * ------------------------------------------------------------------------- */

static long repro_hcr_lx_syscall6(long number, long a0, long a1, long a2,
                                  long a3, long a4, long a5) {
  long result;
  register long r10 __asm__("r10") = a3;
  register long r8 __asm__("r8") = a4;
  register long r9 __asm__("r9") = a5;
  __asm__ volatile("syscall"
                   : "=a"(result)
                   : "a"(number), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8),
                     "r"(r9)
                   : "rcx", "r11", "memory");
  return result;
}

static long repro_hcr_lx_raw_mmap(uint64_t hint, size_t length, int protection,
                                  int flags, int fd, long offset) {
  return repro_hcr_lx_syscall6(REPRO_HCR_LX_NR_MMAP, (long)hint, (long)length,
                               (long)protection, (long)flags, (long)fd,
                               offset);
}

static long repro_hcr_lx_raw_munmap(uint64_t address, size_t length) {
  return repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_MUNMAP, (long)address,
                               (long)length, 0);
}

static long repro_hcr_lx_raw_memfd_create(const char *name, unsigned flags) {
  return repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_MEMFD_CREATE, (long)name,
                               (long)flags, 0);
}

static long repro_hcr_lx_raw_add_seals(int fd, int seals) {
  return repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_FCNTL, (long)fd,
                               (long)REPRO_HCR_LX_F_ADD_SEALS, (long)seals);
}

static long repro_hcr_lx_raw_get_seals(int fd) {
  return repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_FCNTL, (long)fd,
                               (long)REPRO_HCR_LX_F_GET_SEALS, 0);
}

/* The provider's own code pages that are not yet sealed. A sealed page needs
 * no bookkeeping — its exec mapping simply persists — so an entry lives only
 * from allocation to finalization, which bounds this table to the in-flight
 * patch bodies plus the island pages with room left. */
#define REPRO_HCR_LX_MAX_CODE_PAGES 96

typedef struct repro_hcr_lx_code_page {
  uint64_t exec_base;  /* 0 when the slot is free */
  uint64_t write_base; /* 0 for a fallback anonymous page */
  size_t length;
  int fd; /* -1 for a fallback anonymous page */
} repro_hcr_lx_code_page;

static repro_hcr_lx_code_page
    repro_hcr_lx_code_pages[REPRO_HCR_LX_MAX_CODE_PAGES];

/* Observations, for gates. Nothing in the provider branches on them. */
static uint64_t repro_hcr_lx_dual_page_count = 0;
static uint64_t repro_hcr_lx_dual_seal_count = 0;
static uint64_t repro_hcr_lx_fallback_page_count = 0;
static long repro_hcr_lx_last_seal_result = 0;
/* 1 when the KERNEL confirmed the last seal by refusing a shared writable
 * mapping of the still-open memfd. `F_ADD_SEALS` returning 0 is this
 * provider's claim about itself; this is the kernel's, and it is the one that
 * catches the ordering mistake — a shared exec view makes `F_ADD_SEALS` fail
 * `EBUSY` and leaves the writable mapping GRANTED. */
static int repro_hcr_lx_last_seal_verified = 0;

/* Test lever: force the anonymous fallback even where the dual mapping works,
 * so a gate can compare the two paths on one host. Never set in production. */
static int repro_hcr_lx_force_anonymous_code_pages = 0;

static repro_hcr_lx_code_page *repro_hcr_lx_find_code_page(uint64_t exec_base) {
  int i;
  for (i = 0; i < REPRO_HCR_LX_MAX_CODE_PAGES; ++i) {
    if (repro_hcr_lx_code_pages[i].exec_base == exec_base &&
        exec_base != 0) {
      return &repro_hcr_lx_code_pages[i];
    }
  }
  return NULL;
}

static repro_hcr_lx_code_page *repro_hcr_lx_free_code_page_slot(void) {
  int i;
  for (i = 0; i < REPRO_HCR_LX_MAX_CODE_PAGES; ++i) {
    if (repro_hcr_lx_code_pages[i].exec_base == 0) {
      return &repro_hcr_lx_code_pages[i];
    }
  }
  return NULL;
}

/*
 * Whether this host can do it at all, probed ONCE through the whole sequence
 * rather than by testing for `memfd_create`'s presence. A kernel with
 * `memfd_create` but without `MFD_ALLOW_SEALING`, or a seccomp filter that
 * permits the create and refuses the `fcntl`, would answer yes to a presence
 * test and fail at the point of no return.
 *
 * THE PROBE VERIFIES THE SEAL WITH THE KERNEL, not with its own return code:
 * after sealing it asks for a writable mapping and requires the kernel to
 * REFUSE it. `F_ADD_SEALS` returning 0 is this provider's claim; the refusal
 * is the kernel's.
 *
 * ---------------------------------------------------------------------------
 * THE HLX-M7 COUPLING, DECIDED HERE BECAUSE IT CANNOT BE DECIDED SEPARATELY.
 *
 * MCR interposes libc, so a `memfd_create` reached through libc is a RECORDED
 * event and a raw syscall is not. Design §5.1 already settled the same
 * question for `mprotect` — raw, because calling the interposed libc entry
 * from inside the patcher re-enters the recording path, and under tier-2
 * quiescence that re-entry happens with every other thread parked.
 *
 * The decision here is RAW, for that reason and for one more that `mprotect`
 * does not have: `memfd_create` produces a FILE DESCRIPTOR, which is
 * process-visible state that outlives the call. A half-raw implementation —
 * raw create, libc `close` — would give MCR a close on a descriptor it never
 * saw opened, which is a recording that cannot be replayed rather than a
 * recording that is merely incomplete. So the rule is the whole lifecycle or
 * none of it: create, `ftruncate`, both `mmap`s, `munmap`, `fcntl` and `close`
 * are all raw, and the fd carries `MFD_CLOEXEC` so it cannot leak into a child
 * the recorder does follow.
 *
 * The patch does NOT thereby become invisible to replay. HLX-M7's
 * `CodePatchEvent` is the designed channel by which provider activity enters
 * the trace, it is emitted for every publication, and it carries the
 * code-version boundary that replay needs. What raw syscalls remove is the
 * provider's private memory management — which is not application behaviour
 * and which a replay must not re-enact.
 * ------------------------------------------------------------------------- */
static int repro_hcr_lx_memfd_dual_probe_done = 0;
static int repro_hcr_lx_memfd_dual_available = 0;

static int repro_hcr_lx_memfd_dual_supported(size_t page_size) {
  long fd;
  long writer;
  long exec;
  long seal_rc;
  long refused;

  if (repro_hcr_lx_memfd_dual_probe_done) {
    return repro_hcr_lx_memfd_dual_available;
  }
  repro_hcr_lx_memfd_dual_probe_done = 1;
  repro_hcr_lx_memfd_dual_available = 0;

  fd = repro_hcr_lx_raw_memfd_create(
      "repro-hcr-probe",
      REPRO_HCR_LX_MFD_CLOEXEC | REPRO_HCR_LX_MFD_ALLOW_SEALING);
  if (fd < 0) {
    return 0;
  }
  if (repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_FTRUNCATE, fd, (long)page_size,
                            0) != 0) {
    (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, fd, 0, 0);
    return 0;
  }
  writer = repro_hcr_lx_raw_mmap(
      0, page_size, REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE,
      REPRO_HCR_LX_MAP_SHARED, (int)fd, 0);
  exec = repro_hcr_lx_raw_mmap(
      0, page_size, REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_EXEC,
      REPRO_HCR_LX_MAP_PRIVATE, (int)fd, 0);
  if (writer < 0 || exec < 0) {
    if (writer >= 0) (void)repro_hcr_lx_raw_munmap((uint64_t)writer, page_size);
    if (exec >= 0) (void)repro_hcr_lx_raw_munmap((uint64_t)exec, page_size);
    (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, fd, 0, 0);
    return 0;
  }
  (void)repro_hcr_lx_raw_munmap((uint64_t)writer, page_size);
  seal_rc = repro_hcr_lx_raw_add_seals((int)fd, REPRO_HCR_LX_FINAL_SEALS);
  /* THE KERNEL'S OWN ANSWER, not this provider's. */
  refused = repro_hcr_lx_raw_mmap(
      0, page_size, REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE,
      REPRO_HCR_LX_MAP_SHARED, (int)fd, 0);
  if (refused >= 0) {
    (void)repro_hcr_lx_raw_munmap((uint64_t)refused, page_size);
  }
  /* THREE independent confirmations, required to agree: this provider's own
   * `F_ADD_SEALS` return, the kernel's record of the seals it holds, and the
   * kernel REFUSING a writable mapping. The first is a claim; the other two
   * are the kernel's, and it is the third that a broken implementation cannot
   * satisfy — a shared exec view makes `F_ADD_SEALS` fail `EBUSY` and leaves
   * the writable mapping granted, which is exactly the trap this ordering
   * avoids. */
  if (seal_rc == 0 && refused < 0 &&
      (repro_hcr_lx_raw_get_seals((int)fd) & REPRO_HCR_LX_F_SEAL_WRITE) != 0) {
    repro_hcr_lx_memfd_dual_available = 1;
  }
  (void)repro_hcr_lx_raw_munmap((uint64_t)exec, page_size);
  (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, fd, 0, 0);
  return repro_hcr_lx_memfd_dual_available;
}

/*
 * Map one provider-owned code page. Returns the EXEC base, which is what every
 * caller already holds and what `dispatch_address` is taken from; the writable
 * alias is reached through `repro_hcr_lx_code_writer`.
 *
 * Falls back to the pre-HLX-M9 anonymous RW page when the dual mapping is
 * unavailable, when the table is full, or when a gate forces it. A fallback
 * page has `write_base == exec_base` and is finalized with `mprotect`, so the
 * two paths differ in mechanism and not in the sequence a caller writes.
 */
static void *repro_hcr_lx_map_code_page(void *hint, size_t length,
                                        int extra_flags) {
  repro_hcr_lx_code_page *slot;
  long fd;
  long exec;
  long writer;
  int exec_flags = REPRO_HCR_LX_MAP_PRIVATE | extra_flags;

  if (repro_hcr_lx_force_anonymous_code_pages ||
      !repro_hcr_lx_memfd_dual_supported(length)) {
    void *anonymous = repro_hcr_lx_map_anonymous(
        hint, length, REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE,
        extra_flags);
    if (anonymous != NULL) {
      repro_hcr_lx_fallback_page_count += 1;
    }
    return anonymous;
  }

  slot = repro_hcr_lx_free_code_page_slot();
  if (slot == NULL) {
    void *anonymous = repro_hcr_lx_map_anonymous(
        hint, length, REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE,
        extra_flags);
    if (anonymous != NULL) {
      repro_hcr_lx_fallback_page_count += 1;
    }
    return anonymous;
  }

  fd = repro_hcr_lx_raw_memfd_create(
      "repro-hcr-code",
      REPRO_HCR_LX_MFD_CLOEXEC | REPRO_HCR_LX_MFD_ALLOW_SEALING);
  if (fd < 0) {
    return NULL;
  }
  if (repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_FTRUNCATE, fd, (long)length, 0) !=
      0) {
    (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, fd, 0, 0);
    return NULL;
  }
  exec = repro_hcr_lx_raw_mmap(
      (uint64_t)(uintptr_t)hint, length,
      REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_EXEC, exec_flags, (int)fd, 0);
  if (exec < 0) {
    (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, fd, 0, 0);
    return NULL;
  }
  writer = repro_hcr_lx_raw_mmap(
      0, length, REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE,
      REPRO_HCR_LX_MAP_SHARED, (int)fd, 0);
  if (writer < 0) {
    (void)repro_hcr_lx_raw_munmap((uint64_t)exec, length);
    (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, fd, 0, 0);
    return NULL;
  }
  slot->exec_base = (uint64_t)exec;
  slot->write_base = (uint64_t)writer;
  slot->length = length;
  slot->fd = (int)fd;
  repro_hcr_lx_dual_page_count += 1;
  return (void *)(uintptr_t)exec;
}

/* Where a caller PUTS code. For a dual-mapped page this is the shared alias;
 * for a fallback page it is the page itself, which is still RW at this point.
 * A caller that wrote through the exec base of a dual-mapped page would fault,
 * which is the correct failure — it is a page that is not writable. */
static uint8_t *repro_hcr_lx_code_writer(void *exec_base) {
  repro_hcr_lx_code_page *page =
      repro_hcr_lx_find_code_page((uint64_t)(uintptr_t)exec_base);
  if (page == NULL || page->write_base == 0) {
    return (uint8_t *)exec_base;
  }
  return (uint8_t *)(uintptr_t)page->write_base;
}

/* Make the page receive no further writes: drop the writable alias and seal
 * the memfd. Returns 0 on success. For a fallback page this is the
 * pre-HLX-M9 `mprotect` to `PROT_READ|PROT_EXEC`, unchanged. */
static int repro_hcr_lx_finalize_code_page(void *exec_base, size_t length) {
  repro_hcr_lx_code_page *page =
      repro_hcr_lx_find_code_page((uint64_t)(uintptr_t)exec_base);
  /* RESET FIRST. These are per-page observations and a stale one is worse than
   * none: leaving the previous page's answer in place made an anonymous
   * fallback page — which has no memfd and no seal — report the SEAL VERIFIED
   * of the dual page finalized before it. Measured, in the gate that reads
   * them. */
  repro_hcr_lx_last_seal_result = 0;
  repro_hcr_lx_last_seal_verified = 0;
  if (page == NULL) {
    return repro_hcr_lx_raw_mprotect((uint64_t)(uintptr_t)exec_base, length,
                                     REPRO_HCR_LX_PROT_READ |
                                         REPRO_HCR_LX_PROT_EXEC) == 0
               ? 0
               : -1;
  }
  if (page->write_base != 0) {
    (void)repro_hcr_lx_raw_munmap(page->write_base, page->length);
    page->write_base = 0;
  }
  repro_hcr_lx_last_seal_result =
      repro_hcr_lx_raw_add_seals(page->fd, REPRO_HCR_LX_FINAL_SEALS);
  /* ASK THE KERNEL, while the fd is still open — this is the last moment it
   * can be asked, and the answer is what distinguishes a seal that took from
   * a seal that was refused. One syscall, on a path that runs once per page. */
  {
    long probe = repro_hcr_lx_raw_mmap(
        0, page->length, REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE,
        REPRO_HCR_LX_MAP_SHARED, page->fd, 0);
    repro_hcr_lx_last_seal_verified = probe < 0 ? 1 : 0;
    if (probe >= 0) {
      (void)repro_hcr_lx_raw_munmap((uint64_t)probe, page->length);
    }
  }
  if (repro_hcr_lx_last_seal_result != 0) {
    /* The page is still correct and still executable — only the guarantee
     * that no writable alias can be created later is missing. Refusing the
     * patch over it would be a worse answer than reporting it, and the
     * exec view was never writable in the first place. */
    (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, page->fd, 0, 0);
    page->exec_base = 0;
    page->fd = -1;
    return 0;
  }
  repro_hcr_lx_dual_seal_count += 1;
  (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, page->fd, 0, 0);
  page->exec_base = 0;
  page->fd = -1;
  return 0;
}

/* Give the page back entirely — the discard path. */
static void repro_hcr_lx_release_code_page(void *exec_base, size_t length) {
  repro_hcr_lx_code_page *page =
      repro_hcr_lx_find_code_page((uint64_t)(uintptr_t)exec_base);
  if (page == NULL) {
    (void)repro_hcr_lx_unmap(exec_base, length);
    return;
  }
  if (page->write_base != 0) {
    (void)repro_hcr_lx_raw_munmap(page->write_base, page->length);
  }
  (void)repro_hcr_lx_raw_munmap(page->exec_base, page->length);
  (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, page->fd, 0, 0);
  page->exec_base = 0;
  page->write_base = 0;
  page->fd = -1;
  page->length = 0;
}

/*
 * The placement probes below place TWO different kinds of page and the
 * distinction is load-bearing: a CODE page is a dual-mapped, never-writable
 * executable page, and a DATA page is an ordinary writable one that happens to
 * need to be near the code.
 *
 * It is load-bearing because it was got wrong first, and the failure was a
 * SIGSEGV rather than a wrong answer. `repro_hcr_lxu_register_eh_frame` places
 * the retained `.eh_frame` copy with the same near-placement search the patch
 * body uses — for the same reason, `DW_EH_PE_pcrel|sdata4` needs the
 * displacement to fit an int32 — and then WRITES the section into it and
 * relocates the FDEs in place. When that search started returning dual-mapped
 * code pages, those writes went to a `PROT_READ|PROT_EXEC` mapping and every
 * gate that registers a real `.eh_frame` crashed. The `.eh_frame` copy is data;
 * it is not executed and must not be executable.
 */
static void *repro_hcr_lx_map_placed_page(void *hint, size_t length,
                                          int extra_flags, int as_code) {
  if (as_code) {
    return repro_hcr_lx_map_code_page(hint, length, extra_flags);
  }
  return repro_hcr_lx_map_anonymous(
      hint, length, REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE,
      extra_flags);
}

static void repro_hcr_lx_release_placed_page(void *page, size_t length,
                                             int as_code) {
  if (as_code) {
    repro_hcr_lx_release_code_page(page, length);
  } else {
    (void)repro_hcr_lx_unmap(page, length);
  }
}

/* True when this exec base is a dual-mapped page that still has its writable
 * alias — i.e. it can be written again with no protection change at all. The
 * island allocator reads it to decide whether reusing a page with LIVE islands
 * on it needs the `RW|EXEC` transient a hardened host refuses. */
static int repro_hcr_lx_code_page_is_dual(uint64_t exec_base) {
  repro_hcr_lx_code_page *page = repro_hcr_lx_find_code_page(exec_base);
  return page != NULL && page->write_base != 0;
}

/*
 * Near-page allocation for the patch body, within +/-2 GiB of the published
 * window so the trampoline stays a 5-byte `E9 rel32`. Outward probing with
 * `MAP_FIXED_NOREPLACE`, per Trampoline-Mechanics §5.1. Older kernels that do
 * not know the flag treat the address as a hint and return a different address,
 * which the `mapped == hint` check rejects, so the probe is safe there too.
 *
 * HLX-M2 adds the 14-byte island for targets that cannot be reached this way;
 * HLX-M0 refuses instead of ever widening the published store.
 */
/*
 * Strategy 2 of Trampoline-Mechanics §5.1: parse `/proc/self/maps` and place the
 * page in a GAP, instead of probing addresses blindly.
 *
 * It is not a duplicate of the outward probe above, and the difference is what
 * makes it worth having. The probe walks addresses — one page at a time for the
 * first 64 steps and then doubling — so once it is doubling it SKIPS most of the
 * space it crosses, and a single free page between two large mappings is
 * invisible to it. An island needs 14 bytes; one page anywhere inside ±2 GiB is
 * enough, and this is the strategy that finds it.
 *
 * Read streaming rather than into a bounded table: a truncated snapshot would
 * report gaps that are not gaps, and `MAP_FIXED_NOREPLACE` would then fail on
 * them — a silent downgrade to "no gap found". The first successful mapping
 * returns immediately, so at most one mutation of the map happens while it is
 * being read.
 *
 * WHEN THIS RUNS, because the answer constrains what it may do. Unlike sled
 * discovery — which opens and maps the target's own ELF file and therefore runs
 * BEFORE `quiesce_begin` — this is reached from inside the publication path,
 * i.e. with every other thread parked under tier 2. So: no `malloc`, no
 * `dl_iterate_phdr` (which takes the loader lock a parked thread may hold), a
 * static buffer, and `openat`/`read`/`close` issued as RAW syscalls rather than
 * through libc. Since HLX-M9 the CODE-page path is raw too — `memfd_create`,
 * `ftruncate`, both `mmap`s, `munmap`, `fcntl` and `close` — so the only libc
 * call left on this path is the `mmap` inside `repro_hcr_lx_map_anonymous`,
 * which now serves the anonymous FALLBACK and the near-DATA page rather than
 * the body page. It is also only reached when the outward probe has already
 * failed, so the common case pays nothing for it.
 */
#define REPRO_HCR_LX_GAP_CHUNK 8192u

static char repro_hcr_lx_gap_chunk[REPRO_HCR_LX_GAP_CHUNK];
static uint64_t repro_hcr_lx_gap_scan_count = 0;
static uint64_t repro_hcr_lx_gap_hit_count = 0;

/* Parse `START-END ...`; returns 1 and fills both on success. */
static int repro_hcr_lx_parse_gap_line(const char *line, size_t length,
                                       uint64_t *start_out,
                                       uint64_t *end_out) {
  uint64_t start = 0;
  uint64_t end = 0;
  size_t i = 0;
  int digits = 0;
  while (i < length) {
    int value = repro_hcr_lx_hex_value(line[i]);
    if (value < 0) break;
    start = (start << 4) | (uint64_t)value;
    i += 1;
    digits += 1;
  }
  if (digits == 0 || i >= length || line[i] != '-') return 0;
  i += 1;
  digits = 0;
  while (i < length) {
    int value = repro_hcr_lx_hex_value(line[i]);
    if (value < 0) break;
    end = (end << 4) | (uint64_t)value;
    i += 1;
    digits += 1;
  }
  if (digits == 0) return 0;
  *start_out = start;
  *end_out = end;
  return 1;
}

static void *repro_hcr_lx_map_patch_page_in_gap(uint64_t window_address,
                                                size_t page_size,
                                                int as_code) {
  /* Stay inside the signed 2 GiB `rel32` limit with room for the instruction's
   * own +5 bias; reachability is re-checked on the result regardless. */
  const uint64_t reach = 0x7f000000ull;
  uint64_t low = window_address > reach ? window_address - reach
                                        : (uint64_t)page_size;
  uint64_t high = window_address + reach;
  uint64_t cursor;
  long fd;
  size_t held = 0;
  void *result = NULL;

  low = (low + (uint64_t)page_size - 1u) & ~((uint64_t)page_size - 1u);
  high &= ~((uint64_t)page_size - 1u);
  if (low == 0) {
    low = (uint64_t)page_size;
  }
  cursor = low;

  repro_hcr_lx_gap_scan_count += 1;
  fd = repro_hcr_lx_syscall3(
      REPRO_HCR_LX_NR_OPENAT, REPRO_HCR_LX_AT_FDCWD,
      (long)(uintptr_t) "/proc/self/maps",
      REPRO_HCR_LX_O_RDONLY | REPRO_HCR_LX_O_CLOEXEC);
  if (fd < 0) {
    return NULL;
  }

  for (;;) {
    long got = repro_hcr_lx_syscall3(
        REPRO_HCR_LX_NR_READ, fd,
        (long)(uintptr_t)(repro_hcr_lx_gap_chunk + held),
        (long)(sizeof(repro_hcr_lx_gap_chunk) - held));
    size_t available;
    size_t consumed = 0;
    size_t j;
    if (got <= 0) {
      break;
    }
    available = held + (size_t)got;
    for (j = 0; j < available && result == NULL; ++j) {
      uint64_t start = 0;
      uint64_t end = 0;
      if (repro_hcr_lx_gap_chunk[j] != '\n') {
        continue;
      }
      if (repro_hcr_lx_parse_gap_line(repro_hcr_lx_gap_chunk + consumed,
                                      j - consumed, &start, &end)) {
        if (end > low && start < high && start > cursor) {
          uint64_t gap_low = cursor > low ? cursor : low;
          uint64_t gap_high = start < high ? start : high;
          if (gap_high > gap_low &&
              gap_high - gap_low >= (uint64_t)page_size) {
            void *mapped = repro_hcr_lx_map_placed_page(
                (void *)(uintptr_t)gap_low, page_size,
                REPRO_HCR_LX_MAP_FIXED_NOREPLACE, as_code);
            if (mapped != NULL) {
              if ((uint64_t)(uintptr_t)mapped == gap_low &&
                  repro_hcr_lx_rel32_reachable(
                      window_address, (uint64_t)(uintptr_t)mapped)) {
                result = mapped;
              } else {
                repro_hcr_lx_release_placed_page(mapped, page_size, as_code);
              }
            }
          }
        }
        if (end > cursor) {
          cursor = end;
        }
      }
      consumed = j + 1;
    }
    if (result != NULL) {
      break;
    }
    held = available - consumed;
    if (held >= sizeof(repro_hcr_lx_gap_chunk)) {
      held = 0; /* a maps line never exceeds the chunk; drop rather than spin */
    } else if (held > 0 && consumed > 0) {
      memmove(repro_hcr_lx_gap_chunk, repro_hcr_lx_gap_chunk + consumed, held);
    }
  }
  (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, fd, 0, 0);

  /* The tail gap, above the last mapping the scan saw and below the reach
   * ceiling. Without this the highest gap in the region is never tried. */
  if (result == NULL && cursor < high && high - cursor >= (uint64_t)page_size) {
    void *mapped = repro_hcr_lx_map_placed_page(
        (void *)(uintptr_t)cursor, page_size,
        REPRO_HCR_LX_MAP_FIXED_NOREPLACE, as_code);
    if (mapped != NULL) {
      if ((uint64_t)(uintptr_t)mapped == cursor &&
          repro_hcr_lx_rel32_reachable(window_address,
                                       (uint64_t)(uintptr_t)mapped)) {
        result = mapped;
      } else {
        repro_hcr_lx_release_placed_page(mapped, page_size, as_code);
      }
    }
  }

  if (result != NULL) {
    repro_hcr_lx_gap_hit_count += 1;
  }
  return result;
}

static void *repro_hcr_lx_map_near_page(uint64_t window_address,
                                        size_t page_size, int as_code) {
  const uint64_t reach = 0x60000000ull; /* stay well inside the 2 GiB limit */
  uint64_t base = repro_hcr_lx_page_start(window_address, page_size);
  uint64_t distance = 1;
  void *fallback;

  while (distance * (uint64_t)page_size < reach) {
    int direction_index;
    for (direction_index = 0; direction_index < 2; ++direction_index) {
      int64_t direction = direction_index == 0 ? 1 : -1;
      int64_t hint_signed =
          (int64_t)base + direction * (int64_t)(distance * (uint64_t)page_size);
      void *mapped;
      if (hint_signed <= 0) {
        continue;
      }
      mapped = repro_hcr_lx_map_placed_page(
          (void *)(uintptr_t)hint_signed, page_size,
          REPRO_HCR_LX_MAP_FIXED_NOREPLACE, as_code);
      if (mapped == NULL) {
        continue;
      }
      if ((uint64_t)(uintptr_t)mapped == (uint64_t)hint_signed &&
          repro_hcr_lx_rel32_reachable(window_address,
                                       (uint64_t)(uintptr_t)mapped)) {
        return mapped;
      }
      repro_hcr_lx_release_placed_page(mapped, page_size, as_code);
    }
    distance = distance < 64 ? distance + 1 : distance * 2;
  }

  /* Strategy 2 (Trampoline-Mechanics §5.1). The probe above doubles its stride
   * after 64 pages and so steps over most of the region; a gap the size of one
   * page — which is all an island needs — is invisible to it. */
  fallback = repro_hcr_lx_map_patch_page_in_gap(window_address, page_size,
                                               as_code);
  if (fallback != NULL) {
    return fallback;
  }

  fallback = repro_hcr_lx_map_placed_page(NULL, page_size, 0, as_code);
  if (fallback == NULL) {
    return NULL;
  }
  if (repro_hcr_lx_rel32_reachable(window_address,
                                   (uint64_t)(uintptr_t)fallback)) {
    return fallback;
  }
  repro_hcr_lx_release_placed_page(fallback, page_size, as_code);
  return NULL;
}

/* The two named entry points. `..._patch_page_near` places EXECUTABLE pages —
 * patch bodies and island pages. `..._near_data_page` places a writable page
 * that merely needs to be within int32 of the code, which is what the retained
 * `.eh_frame` copy is. */
static void *repro_hcr_lx_map_patch_page_near(uint64_t window_address,
                                              size_t page_size) {
  return repro_hcr_lx_map_near_page(window_address, page_size, 1);
}

REPRO_HCR_LX_MAYBE_UNUSED
static void *repro_hcr_lx_map_near_data_page(uint64_t window_address,
                                             size_t page_size) {
  return repro_hcr_lx_map_near_page(window_address, page_size, 0);
}

/* ---------------------------------------------------------------------------
 * HLX-M2 — ISLANDS.
 *
 * THE CONSTRAINT THIS EXISTS TO PRESERVE. The published store is, and stays,
 * ONE naturally aligned 8-byte word holding a 5-byte `E9 rel32`. That is what
 * makes publication atomic (design §4.2): any thread reads either the whole old
 * word or the whole new one. A 14-byte `jmp [rip+0]; .quad target` written into
 * live text would reach any address in the 64-bit space and would NOT be
 * atomic — three stores, or one unaligned one, with a decodable-but-wrong
 * intermediate state. `Trampoline-Mechanics.md` §6's unamended ladder selects
 * exactly that encoding for a far target, which is why §6 is amended by this
 * milestone rather than merely cited by it.
 *
 * So the 14 bytes move OUT of the target's text and into provider-owned memory:
 *
 *      target text (8-byte window)        provider page, within +/-2 GiB
 *      E9 <rel32 to island> 90 90 90  ->  FF 25 00 00 00 00 ; .quad <body>
 *
 * The published store is unchanged in size, shape and atomicity; the island is
 * written and made executable BEFORE the store, in memory no other thread can
 * reach until the store makes it reachable, so it needs no atomicity of its own.
 *
 * An island-reachable body is entered through `jmp [rip+disp32]`, an INDIRECT
 * branch, so on an IBT-enforcing process it must begin with `endbr64`. The
 * publication path below already emits that landing pad on every body that does
 * not carry one — written in HLX-M0 "in advance", and load-bearing from here on.
 *
 * PACKING. Islands are 14 bytes on a 16-byte stride, so one 4 KiB page holds
 * 256 of them and a process patching many far functions pays for one near page,
 * not one per function. A page is reused only for a window it can still reach;
 * reachability is re-checked per allocation rather than assumed from the page's
 * own placement, because two windows 3 GiB apart share no near page.
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_LX_ISLAND_BYTES 14u
#define REPRO_HCR_LX_ISLAND_STRIDE 16u
#define REPRO_HCR_LX_MAX_ISLAND_PAGES 16

/* `FF 25 00 00 00 00` is `jmp *0(%rip)`, i.e. jump to the 64-bit address stored
 * immediately after the instruction. Zero displacement, no register clobbered,
 * no flags touched — which is why it and not the 13-byte `movabs %r11` form is
 * the indirection used here; `%r11` is caller-saved but a tail-called function
 * entered through an island must not have it altered underneath it. */
static void repro_hcr_lx_encode_island(uint64_t target_address,
                                       uint8_t out_bytes[14]) {
  out_bytes[0] = 0xff;
  out_bytes[1] = 0x25;
  out_bytes[2] = 0x00;
  out_bytes[3] = 0x00;
  out_bytes[4] = 0x00;
  out_bytes[5] = 0x00;
  memcpy(out_bytes + 6, &target_address, sizeof(target_address));
}

typedef struct repro_hcr_lx_island_page {
  uint64_t base;
  uint32_t used; /* slots consumed, each REPRO_HCR_LX_ISLAND_STRIDE bytes */
} repro_hcr_lx_island_page;

static repro_hcr_lx_island_page
    repro_hcr_lx_island_pages[REPRO_HCR_LX_MAX_ISLAND_PAGES];
static int repro_hcr_lx_island_page_count = 0;
static uint64_t repro_hcr_lx_island_alloc_count = 0;
static uint64_t repro_hcr_lx_island_page_map_count = 0;
static uint64_t repro_hcr_lx_island_reuse_count = 0;

/*
 * The protection actually requested for the WRITE TRANSIENT on the most recent
 * reused island page, and -1 when no page has been reused yet.
 *
 * This exists because the hazard it guards is a TRANSIENT and is therefore
 * invisible to every post-hoc observation. `repro_hcr_lx_allocate_island`
 * restores `R|X` before it returns, so a check that reads the first island's
 * bytes, or even its page protection, afterwards sees an intact, executable
 * page whether or not `PROT_EXEC` was dropped for the duration of the memcpy —
 * and the bytes of an island already written are not touched by writing the
 * NEXT slot either way. Such a check passes over the defect, which is
 * `codetracer-specs/Testing/Verification-Harness-Traps.md` trap 4a's shape: a
 * property whose subject is emptied by the very restoration that makes the
 * function correct.
 *
 * Recording the transient is what makes the property falsifiable at all
 * without racing a second thread through a live island. Asserted by
 * `t_unit_hcr_linux_x86_64_trampoline_encoding_and_atomicity_preconditions`.
 */
static int repro_hcr_lx_island_reuse_transient_prot = -1;

/*
 * Place a 14-byte island that (a) is within `rel32` reach of `window_address`
 * and (b) jumps to `target_address`. Returns the island's address, or 0 when no
 * such placement exists — which is the exhaustion case, and is a refusal rather
 * than a licence to widen the store.
 */
static uint64_t repro_hcr_lx_allocate_island(uint64_t window_address,
                                             uint64_t target_address) {
  size_t page_size = repro_hcr_lx_page_size();
  uint32_t slots_per_page = (uint32_t)(page_size / REPRO_HCR_LX_ISLAND_STRIDE);
  uint8_t island[REPRO_HCR_LX_ISLAND_BYTES];
  uint64_t slot = 0;
  repro_hcr_lx_island_page *page = NULL;
  int i;
  int fresh_page = 0;

  if (slots_per_page == 0) {
    return 0;
  }

  /*
   * Strategy 1: an island page we already own that still has room AND can
   * still be reached from THIS window.
   *
   * REUSE IS CONDITIONAL ON KEEPING `PROT_EXEC` ACROSS THE WRITE, and that is
   * not a nicety. Every island already on a used page is LIVE — a published
   * `rel32` in target text jumps to it — so dropping `PROT_EXEC` for the
   * duration of the memcpy would fault any thread that called one of those
   * patched functions in the window. It is the same hazard HLX-M4 found for
   * the text transient, one page over. On a host that refuses `RW|EXEC` the
   * page is simply not reused and a fresh one is taken instead; an unused page
   * has no live island on it and is safe to write while non-executable.
   */
  for (i = 0; i < repro_hcr_lx_island_page_count; ++i) {
    repro_hcr_lx_island_page *candidate = &repro_hcr_lx_island_pages[i];
    uint64_t candidate_slot;
    if (candidate->used >= slots_per_page) {
      continue;
    }
    /* HLX-M9: a DUAL-MAPPED page needs no transient at all — the new island
     * is written through the page's shared alias while the exec mapping keeps
     * `PROT_EXEC` untouched, so the live islands on it are never at risk and
     * no `RW|EXEC` transition is requested of the kernel. The `text_rwx`
     * requirement below is the ANONYMOUS-fallback rule, and is why island
     * reuse used to be impossible on a host that refuses `RW|EXEC`. */
    if (candidate->used > 0 &&
        !repro_hcr_lx_code_page_is_dual(candidate->base) &&
        !repro_hcr_lx_capability_report()->text_rwx_transition) {
      continue;
    }
    candidate_slot =
        candidate->base + (uint64_t)candidate->used * REPRO_HCR_LX_ISLAND_STRIDE;
    if (!repro_hcr_lx_rel32_reachable(window_address, candidate_slot)) {
      continue;
    }
    page = candidate;
    slot = candidate_slot;
    repro_hcr_lx_island_reuse_count += 1;
    break;
  }

  /* Strategy 2: a fresh page near the window. `map_patch_page_near` already
   * implements Trampoline-Mechanics §5.1's outward `MAP_FIXED_NOREPLACE` probe
   * and only returns a page it has PROVED is `rel32`-reachable, so exhaustion
   * of the +/-2 GiB region shows up here as a NULL and nowhere else. */
  if (page == NULL) {
    void *mapped;
    if (repro_hcr_lx_island_page_count >= REPRO_HCR_LX_MAX_ISLAND_PAGES) {
      return 0;
    }
    mapped = repro_hcr_lx_map_patch_page_near(window_address, page_size);
    if (mapped == NULL) {
      return 0;
    }
    page = &repro_hcr_lx_island_pages[repro_hcr_lx_island_page_count];
    page->base = (uint64_t)(uintptr_t)mapped;
    page->used = 0;
    repro_hcr_lx_island_page_count += 1;
    repro_hcr_lx_island_page_map_count += 1;
    slot = page->base;
    fresh_page = 1;
  }

  repro_hcr_lx_encode_island(target_address, island);

  /*
   * A fresh page is still RW from the mapping and needs no transition. A reused
   * page is RX and must be made writable — but it must KEEP `PROT_EXEC` while
   * it is, because the islands already on it are live (see the reuse condition
   * above, which is what guarantees `text_rwx_transition` is available here).
   * The slot being written is not reachable from anywhere until the publishing
   * store lands, so the write itself needs no atomicity.
   */
  if (repro_hcr_lx_code_page_is_dual(page->base)) {
    /* HLX-M9 — THE DUAL-MAPPED PATH, and the whole point of it is what is
     * ABSENT here: no `mprotect` at all, in either direction, at any point.
     * The island is written through the page's shared alias at the same
     * offset, and the exec mapping is never touched, so every island already
     * on this page stays executable across the write and no protection change
     * is requested of a kernel that may refuse one. `repro_hcr_lx_island_
     * reuse_transient_prot` is left at whatever it was, because no transient
     * happened; the gates that assert it read it only on the fallback path. */
    uint8_t *writer = repro_hcr_lx_code_writer((void *)(uintptr_t)page->base);
    memcpy(writer + (slot - page->base), island, sizeof(island));
    page->used += 1;
    /* Sealed the moment it can take no more islands. Until then the shared
     * alias must stay, which is the honest cost of a page that is written
     * more than once — recorded rather than glossed. */
    if (page->used >= slots_per_page) {
      (void)repro_hcr_lx_finalize_code_page((void *)(uintptr_t)page->base,
                                            page_size);
    }
    repro_hcr_lx_island_alloc_count += 1;
    return slot;
  }
  if (!fresh_page && page->used > 0) {
    /* The recorded value IS the argument, passed by name below rather than
     * respelled. That coupling is the whole point: a control is only a control
     * if the mechanism under suspicion cannot supply its answer
     * (`codetracer-specs/Testing/Verification-Harness-Traps.md` trap 7a), and
     * the mechanism under suspicion here is precisely the choice of protection
     * bits. Do not separate the two — recording one constant and passing
     * another would leave the assertion green over a transient that dropped
     * `PROT_EXEC`, which is the defect this records. */
    repro_hcr_lx_island_reuse_transient_prot =
        REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE |
        REPRO_HCR_LX_PROT_EXEC;
    if (repro_hcr_lx_raw_mprotect(
            page->base, page_size,
            repro_hcr_lx_island_reuse_transient_prot) != 0) {
      return 0;
    }
  }
  if (!fresh_page && page->used == 0 &&
      repro_hcr_lx_raw_mprotect(page->base, page_size,
                                REPRO_HCR_LX_PROT_READ |
                                    REPRO_HCR_LX_PROT_WRITE) != 0) {
    return 0;
  }
  memcpy((void *)(uintptr_t)slot, island, sizeof(island));
  if (repro_hcr_lx_raw_mprotect(page->base, page_size,
                                REPRO_HCR_LX_PROT_READ |
                                    REPRO_HCR_LX_PROT_EXEC) != 0) {
    /* The island is written but not executable. Refuse rather than publish a
     * jump into a non-executable page — that would fault every caller. */
    return 0;
  }
  page->used += 1;
  repro_hcr_lx_island_alloc_count += 1;
  return slot;
}

/* ---------------------------------------------------------------------------
 * Trampoline selection (HLX-M2), i.e. the algorithm `Trampoline-Mechanics.md`
 * §6 now describes. ONE decision point, so the published encoding and the
 * documented ladder cannot drift:
 *
 *   1. The published encoding is ALWAYS `E9 rel32` inside one aligned 8-byte
 *      store. There is no sled length at which a 13- or 14-byte in-text form
 *      becomes selectable; the sled length question was already settled by
 *      `repro_hcr_lx_plan_sled`, which refuses a sled that admits no aligned
 *      8-byte window.
 *   2. Body within `rel32` reach of the window -> jump straight to it.
 *   3. Otherwise -> a 14-byte island within +/-2 GiB, and the `rel32` points
 *      at the island.
 *   4. No island placeable -> refuse, by name.
 * ------------------------------------------------------------------------- */

enum {
  REPRO_HCR_LX_TRAMPOLINE_REL32_BODY = 0,
  REPRO_HCR_LX_TRAMPOLINE_REL32_ISLAND = 1
};

typedef struct repro_hcr_lx_trampoline_choice {
  int refusal;
  int kind;
  uint64_t jump_target;    /* what the published `rel32` points at */
  uint64_t island_address; /* 0 unless kind == ..._REL32_ISLAND */
  int64_t body_displacement; /* body - (window + 5); evidence, signed */
} repro_hcr_lx_trampoline_choice;

static int repro_hcr_lx_select_trampoline(
    uint64_t window_address, uint64_t body_address,
    repro_hcr_lx_trampoline_choice *out) {
  if (out == NULL) {
    return REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
  }
  memset(out, 0, sizeof(*out));
  out->body_displacement =
      (int64_t)body_address -
      (int64_t)(window_address + REPRO_HCR_LX_JMP_REL32_BYTES);

  if (repro_hcr_lx_rel32_reachable(window_address, body_address)) {
    out->kind = REPRO_HCR_LX_TRAMPOLINE_REL32_BODY;
    out->jump_target = body_address;
    out->refusal = REPRO_HCR_LX_OK;
    return out->refusal;
  }

#if defined(REPRO_HCR_HLX_M2_FALSIFY_ISLAND_DISABLED)
  /*
   * FALSIFIER ARM (HLX-M2). Removes the island indirection and nothing else, so
   * a far body has no publishable encoding left. The far gate must go RED here
   * with `patch-body-out-of-rel32-range` and an unchanged function.
   *
   * What this arm proves is not that the code compiles two ways: it proves the
   * body in the far gate is GENUINELY out of `rel32` reach. If the "force far"
   * lever were a fiction — if the body actually landed within 2 GiB — this arm
   * would publish successfully and the gate would stay green, which is exactly
   * the non-discriminating shape trap 10 describes. The agent never defines it.
   */
  out->refusal = REPRO_HCR_LX_REFUSED_TARGET_OUT_OF_RANGE;
  return out->refusal;
#endif

  out->island_address =
      repro_hcr_lx_allocate_island(window_address, body_address);
  if (out->island_address == 0) {
    out->refusal = REPRO_HCR_LX_REFUSED_ISLAND_UNPLACEABLE;
    return out->refusal;
  }
  out->kind = REPRO_HCR_LX_TRAMPOLINE_REL32_ISLAND;
  out->jump_target = out->island_address;
  out->refusal = REPRO_HCR_LX_OK;
  return out->refusal;
}

/*
 * Test-only lever (HLX-M2). When set, the patch BODY is deliberately mapped
 * outside `rel32` reach of the window, so the island path is the one taken.
 *
 * It does not fake the distance. The page really is more than 2 GiB from the
 * window — `repro_hcr_lx_map_patch_page_far` asserts that with the same
 * `rel32_reachable` predicate the selector uses, and the gate measures the gap
 * itself from the addresses the provider reports. What the lever removes is the
 * near-first PREFERENCE, which in a process with free address space would
 * otherwise make the far case unreachable and the island code dead.
 *
 * The agent never sets it, exactly as it never sets
 * `repro_hcr_lx_sync_core_suppressed`.
 */
static int repro_hcr_lx_force_far_patch_body = 0;

static void *repro_hcr_lx_map_patch_page_far(uint64_t window_address,
                                             size_t page_size) {
  /* Start 4 GiB out — comfortably past the 2 GiB `rel32` reach in both
   * directions — and walk further until a `MAP_FIXED_NOREPLACE` takes. */
  const uint64_t first = 0x100000000ull;
  const uint64_t ceiling = 0x0000700000000000ull;
  const uint64_t step = 0x10000000ull; /* 256 MiB */
  uint64_t offset;

  for (offset = first; offset < first + 64ull * step; offset += step) {
    int direction_index;
    for (direction_index = 0; direction_index < 2; ++direction_index) {
      uint64_t hint;
      void *mapped;
      if (direction_index == 0) {
        if (window_address + offset >= ceiling) {
          continue;
        }
        hint = window_address + offset;
      } else {
        if (offset + page_size >= window_address) {
          continue;
        }
        hint = window_address - offset;
      }
      hint = repro_hcr_lx_page_start(hint, page_size);
      if (hint == 0) {
        continue;
      }
      mapped = repro_hcr_lx_map_code_page(
          (void *)(uintptr_t)hint, page_size,
          REPRO_HCR_LX_MAP_FIXED_NOREPLACE);
      if (mapped == NULL) {
        continue;
      }
      if ((uint64_t)(uintptr_t)mapped == hint &&
          !repro_hcr_lx_rel32_reachable(window_address,
                                        (uint64_t)(uintptr_t)mapped)) {
        return mapped;
      }
      repro_hcr_lx_release_code_page(mapped, page_size);
    }
  }
  return NULL;
}

typedef struct repro_hcr_lx_patch_report {
  int refusal;
  uint64_t sled_address;
  uint64_t sled_end;
  uint32_t sled_length;
  uint64_t window_address;
  uint32_t window_offset;
  uint64_t original_word;
  uint64_t published_word;
  uint64_t dispatch_address;
  uint64_t generation;
  long membarrier_result;
  int text_left_writable;
  /* HLX-M7 §10.1: which patcher held the contested bytes when a claim was
   * refused. Carried so the `skippedFunctions` entry can name the holder
   * instead of saying only that something else got there first. */
  unsigned claim_holder;
  int claim_held;   /* 1 once this provider owns the window's claim */
  /* HLX-M4. `quiesced` records whether this publication was tier 2;
   * `ip_adjustments` is how many parked threads were standing INSIDE the
   * window and had their resume PC nudged, which is the number that proves the
   * §6.2 step 6 mechanism engaged rather than silently no-opped;
   * `resume_target` is where they were nudged to. */
  int quiesced;
  int32_t ip_adjustments;
  uint64_t resume_target;
  /* 1 when the writable transient retained `PROT_EXEC`, so live threads
   * executing elsewhere in the same text page kept running across the store. */
  int transient_kept_exec;
  /* HLX-M2. `trampoline_kind` is which of the two publishable forms was
   * selected; `island_address` is 0 for the direct one. `body_displacement` is
   * the signed `body - (window + 5)` the selector measured, carried so a gate
   * can assert the body really was out of reach rather than take the selector's
   * word for which branch it took. */
  int trampoline_kind;
  uint64_t island_address;
  int64_t body_displacement;
  /* HLX-M3, design §11.2. The transaction evidence for the most recent
   * publication attempt.
   *
   * `old_code_retained` is an OBSERVATION, not the literal the C agent's
   * reporting path printed until this milestone: it is true when the site
   * table holds this window's ORIGINAL aligned word AND at least one
   * provider-owned region is still mapped for it, which is the same shape the
   * Nim runtime computes at `runtime.nim:127`
   * (`retainedRegionAddresses.len > 0`). `retained_region_count` is that
   * length — 1 for the saved original word plus one per superseded patch body
   * retained across generations (§4.5).
   *
   * `previous_word` is the window's pre-state at PREPARE time, which for a
   * re-patch is the previous generation's published word and is NOT the
   * rollback target; `original_word` above always is (§4.5). */
  int old_code_retained;
  int retained_region_count;
  uint64_t previous_word;
  int prepare_complete;
  int commit_complete;
  int rolled_back;
  int published_sites;
  int restored_sites;
} repro_hcr_lx_patch_report;

static repro_hcr_lx_patch_report repro_hcr_lx_last_report;

static const uint8_t repro_hcr_lx_endbr64[4] = {0xf3, 0x0f, 0x1e, 0xfa};

/* ---------------------------------------------------------------------------
 * HLX-M3 — the prepare / commit split, and rollback (design §11.2, §4.5).
 *
 * THE PHASE BOUNDARY IS THE FIRST BYTE WRITTEN TO TARGET TEXT, and here it is
 * a line in this file rather than a convention. Everything
 * `repro_hcr_lx_txn_prepare` does is provider-owned memory, the cross-patcher
 * claim map, and READS of the target: symbols are resolved and disambiguated
 * upstream, build-ids verified upstream, every sled validated, every page and
 * island allocated, every patch body written and protected, every encoding
 * computed, and every site's ORIGINAL aligned word saved. The only write into
 * live text is the single aligned 8-byte store in `repro_hcr_lx_txn_commit`.
 * A prepare failure therefore leaves the target byte-identical BY
 * CONSTRUCTION, not by cleanup — which is what makes IsoNim's "never blank the
 * surface" guarantee hold, because `before_reload` is not invoked until
 * prepare has fully succeeded.
 *
 * WHAT THE PER-FUNCTION GUARANTEE IS, AND WHAT IT IS NOT. Each commit store is
 * one naturally-aligned 8-byte store holding a 5-byte `E9 rel32`, and each is
 * individually reversible from the word prepare saved. That is the whole of
 * the tier-1 guarantee, and it is narrower than it sounds:
 *
 *   - it makes each publication atomic and individually UNDOABLE;
 *   - it does NOT make concurrent execution safe. Measured in HLX-M4 and
 *     reproduced independently, bare tier-1 publication into a twelve-thread
 *     process killed 18 to 21 of 24 processes, with 4.6%-8.6% of parked PCs
 *     standing inside the very eight bytes being published. No aligned store
 *     and no rollback addresses that;
 *   - it does NOT give SET-WIDE atomicity. Under tier 1 a thread may already
 *     have executed function A's new body by the time function B's commit
 *     fails and the set is rolled back. Rollback restores every published
 *     site; it cannot un-execute. Callers that cannot tolerate that must have
 *     quiescence, which is HLX-M4's `repro_hcr_lx_quiesce_begin` and is NOT
 *     claimed by this milestone.
 *
 * ROLLBACK IS NOT "FREE EVERYTHING". Bodies that were never published are
 * provider-private and are unmapped. Bodies that WERE published are retained,
 * because under tier 1 a thread may be executing inside one, and §4.5 and §6.1
 * both forbid freeing code a PC may be standing in. Islands come from a bump
 * allocator and are never reclaimed at all, for the same reason. The claim on
 * a rolled-back window IS released (§4.5: retained across generations,
 * released on rollback or shutdown).
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_LX_MAX_TXN_SITES 16

typedef struct repro_hcr_lx_prepared_site {
  /* the request */
  uint64_t entry_address;
  uint64_t sled_address;
  const uint8_t *patch_bytes;
  size_t patch_len;

  /* prepare outputs — every one of these is computed without writing to the
   * target */
  repro_hcr_lx_sled_plan plan;
  uint64_t window_address;
  uint64_t original_word;   /* §4.5: the rollback target, ALWAYS the original */
  uint64_t previous_word;   /* the window's pre-state at prepare time         */
  uint64_t published_word;
  uint64_t dispatch_address;
  uint64_t island_address;
  int trampoline_kind;
  int64_t body_displacement;
  uint8_t *patch_page;
  size_t patch_page_len;
  uint64_t span_start;
  uint64_t span_end;
  repro_hcr_lx_site *site;
  int fresh_site;
  int claimed_here;
  int prepared;

  /* commit / rollback state */
  int published;
  int restored;
  int body_retained;
  /* Set by the agent AFTER a successful commit, when it has registered a GDB
   * JIT symfile or a dynamic `.eh_frame` section for this site's body.
   * Rollback hands them back to the deregistration hooks below.
   *
   * HLX-M5 made this reachable. Until it landed, both Linux registration
   * functions returned -1, so no site ever recorded an address and the
   * unregistration half of rollback — wired by HLX-M3 — could not run. They
   * are written by `repro_hcr_lx_txn_record_registration` after the commit,
   * and a site that carries no registration still legitimately holds 0. */
  uint64_t jit_entry_address;
  uint64_t eh_frame_payload_address;
  int refusal;
} repro_hcr_lx_prepared_site;

typedef struct repro_hcr_lx_transaction {
  int site_count;
  int prepare_complete;
  int commit_complete;
  int rolled_back;
  int published_count;
  int restored_count;
  int retained_body_count;
  int freed_body_count;
  int released_claim_count;
  int unregister_attempts;
  int refusal;
  int failed_site;   /* index of the site that refused, -1 when none */
  repro_hcr_lx_prepared_site sites[REPRO_HCR_LX_MAX_TXN_SITES];
} repro_hcr_lx_transaction;

/*
 * Deregistration hooks. The debugger/unwinder registration functions live in
 * the agent translation unit (`repro_hcr_agent.c`) and this header is also
 * included by the test probe, which does not link them — so rollback reaches
 * them through pointers the agent installs rather than by name. NULL means
 * "nothing was ever registered through this transaction".
 *
 * HLX-M5 filled them in: the hooks are `repro_hcr_lxu_unregister_jit_symfile`
 * and `repro_hcr_lxu_unregister_eh_frame` from `repro_hcr_linux_unwind.h`, and
 * the per-site fields below stop being zero because registration now succeeds.
 */
static int (*repro_hcr_lx_unregister_jit_hook)(uint64_t) = NULL;
static int (*repro_hcr_lx_unregister_eh_frame_hook)(uint64_t) = NULL;

/*
 * Test-only levers, in the same spirit as `repro_hcr_lx_force_far_patch_body`
 * and `repro_hcr_lx_pretend_sync_core_unavailable`: the agent sets neither.
 *
 * `repro_hcr_lx_fail_patch_page_alloc` makes the body allocator come back
 * empty, which is the `patch-memory-unavailable` prepare failure a process
 * whose address space is exhausted would hit. It does not bypass the refusal
 * logic; it removes the page, and the production code refuses on its own.
 *
 * `repro_hcr_lx_commit_fault_site` names the site index at which the commit's
 * text-protection transient must fail. It is applied AS A SYSCALL RESULT —
 * `-EACCES`, exactly what a kernel that refuses the transition returns — so
 * the code path taken is the production failure path and not a shortcut around
 * it. There is no other way to make `mprotect` fail on the k-th site of a set
 * on demand, and a commit-failure gate that cannot choose k cannot show that N
 * of M published sites were restored.
 */
/*
 * `repro_hcr_lx_restore_fault_site` names the site index at which the
 * POST-STORE `mprotect(PROT_READ|PROT_EXEC)` must fail — the branch that sets
 * `text_left_writable`. Added 2026-09-19 with HLX-M9's wire field, because
 * that branch had never been executed by anything: the commit lever above
 * only reaches the FORWARD leg, whose failure is a clean refusal before any
 * byte is written.
 *
 * It does NOT fake the flag. It SKIPS the restore syscall, so the page really
 * is left RW — the same state the kernel would leave it in, reachable on a
 * healthy host with no way to make `mprotect` refuse on demand. That is what
 * lets a gate corroborate the reported flag against `/proc/self/maps`, which
 * the kernel writes and the agent does not, instead of asserting the agent's
 * own bookkeeping against itself (Verification-Harness-Traps §7a).
 */
static int repro_hcr_lx_fail_patch_page_alloc = 0;
static int repro_hcr_lx_commit_fault_site = -1;
static int repro_hcr_lx_restore_fault_site = -1;

static repro_hcr_lx_transaction repro_hcr_lx_last_txn;

/*
 * HLX-M5 — how a registration reaches the site that rollback will undo.
 *
 * The registration happens in the caller (the agent, or the gate fixture that
 * stands in for it) AFTER the commit, because a symfile and an FDE must name
 * the LIVE patch address and there is no live address until the body is
 * published. The site is found BY that address rather than by index, so a
 * transaction that published several bodies attributes each registration to
 * the right one.
 *
 * Returns 1 when a site took the addresses and 0 when no published site has
 * that dispatch address. The 0 is a caller error, not a benign no-op — a
 * registration nobody recorded is a registration rollback cannot undo — so the
 * gate that drives this asserts the 1 rather than ignoring the result.
 */
static int repro_hcr_lx_txn_record_registration(uint64_t dispatch_address,
                                                uint64_t jit_entry_address,
                                                uint64_t eh_frame_address) {
  repro_hcr_lx_transaction *txn = &repro_hcr_lx_last_txn;
  int i;
  if (dispatch_address == 0) {
    return 0;
  }
  for (i = 0; i < txn->site_count; ++i) {
    repro_hcr_lx_prepared_site *ps = &txn->sites[i];
    if (!ps->published || ps->dispatch_address != dispatch_address) {
      continue;
    }
    if (jit_entry_address != 0) {
      ps->jit_entry_address = jit_entry_address;
    }
    if (eh_frame_address != 0) {
      ps->eh_frame_payload_address = eh_frame_address;
    }
    return 1;
  }
  return 0;
}

static void repro_hcr_lx_txn_reset(repro_hcr_lx_transaction *txn) {
  if (txn == NULL) {
    return;
  }
  memset(txn, 0, sizeof(*txn));
  txn->failed_site = -1;
}

/*
 * Record one function in the set. Pure bookkeeping: nothing is validated, read
 * or allocated until `prepare`.
 */
static int repro_hcr_lx_txn_add(repro_hcr_lx_transaction *txn,
                                uint64_t entry_address, uint64_t sled_address,
                                const uint8_t *patch_bytes, size_t patch_len) {
  repro_hcr_lx_prepared_site *ps;
  if (txn == NULL) {
    return REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
  }
  if (txn->site_count >= REPRO_HCR_LX_MAX_TXN_SITES) {
    return REPRO_HCR_LX_REFUSED_SITE_TABLE_FULL;
  }
  ps = &txn->sites[txn->site_count];
  memset(ps, 0, sizeof(*ps));
  ps->entry_address = entry_address;
  ps->sled_address = sled_address;
  ps->patch_bytes = patch_bytes;
  ps->patch_len = patch_len;
  ps->refusal = REPRO_HCR_LX_OK;
  txn->site_count += 1;
  return REPRO_HCR_LX_OK;
}

/*
 * Undo one prepared site. Only ever called for a site that has NOT been
 * published, so the patch page is still provider-private and unmapping it
 * cannot strand a PC.
 */
static void repro_hcr_lx_txn_discard_prepared(repro_hcr_lx_transaction *txn,
                                              repro_hcr_lx_prepared_site *ps) {
  if (ps->patch_page != NULL) {
    repro_hcr_lx_release_code_page(ps->patch_page, ps->patch_page_len);
    ps->patch_page = NULL;
    txn->freed_body_count += 1;
  }
  if (ps->fresh_site && ps->site != NULL) {
    ps->site->used = 0;
    ps->site = NULL;
  }
  /* §10.1: a window this transaction claimed and did not publish into must be
   * left as unclaimed as it was found, or the next patcher — or the next
   * reload — is refused bytes nobody is using. */
  if (ps->claimed_here) {
    if (ct_claimed_guest_text_release != NULL) {
      ct_claimed_guest_text_release((uintptr_t)ps->window_address);
      txn->released_claim_count += 1;
    }
    /* The report must say the claim is gone, not merely that it was taken:
     * `claim_held` is what the arbitration gate reads to distinguish a
     * released claim from a leaked one. */
    repro_hcr_lx_last_report.claim_held = 0;
  }
  ps->claimed_here = 0;
  ps->prepared = 0;
}

/*
 * Prepare ONE site. Touches no target memory: it reads the window and the
 * sled, and everything it writes is provider-owned.
 *
 * `repro_hcr_lx_last_report` is filled as it goes, so a refusal carries the
 * partial facts (which sled, which window) the caller needs to report the
 * function as skipped rather than as a mystery. For a multi-function set the
 * report therefore describes the site that refused, or the last site prepared.
 */
static int repro_hcr_lx_txn_prepare_site(repro_hcr_lx_transaction *txn,
                                         repro_hcr_lx_prepared_site *ps) {
  size_t page_size = repro_hcr_lx_page_size();
  size_t body_prefix = 0;
  size_t body_len;
  uint8_t jmp_bytes[REPRO_HCR_LX_JMP_REL32_BYTES];
  repro_hcr_lx_trampoline_choice choice;
  int encode_rc;

  memset(&repro_hcr_lx_last_report, 0, sizeof(repro_hcr_lx_last_report));

  if (ps->entry_address == 0 || ps->patch_bytes == NULL || ps->patch_len == 0) {
    ps->refusal = REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
    repro_hcr_lx_last_report.refusal = ps->refusal;
    return ps->refusal;
  }

  ps->site = repro_hcr_lx_find_site(ps->entry_address);
  if (ps->site != NULL) {
    /* Re-patch (design §4.5). The window's admissible pre-states are exactly
     * two: an all-NOP window, or a window this provider itself published and
     * still owns. This is the second; `repro_hcr_lx_plan_sled` below is the
     * first. A window matching NEITHER — because the application or another
     * patcher changed it — is refused `entry-modified-externally` and is never
     * overwritten. Without this branch the provider would work exactly once. */
    uint64_t current_word;
    ps->window_address = ps->site->window_address;
    memcpy(&current_word, (const void *)(uintptr_t)ps->window_address,
           sizeof(current_word));
    if (current_word != ps->site->published_word) {
      ps->refusal = REPRO_HCR_LX_REFUSED_ENTRY_MODIFIED_EXTERNALLY;
      repro_hcr_lx_last_report.refusal = ps->refusal;
      repro_hcr_lx_last_report.window_address = ps->window_address;
      ps->site = NULL;
      return ps->refusal;
    }
    memset(&ps->plan, 0, sizeof(ps->plan));
    ps->plan.sled_address = ps->site->sled_address;
    ps->plan.sled_end = ps->site->sled_end;
    ps->plan.sled_length =
        (uint32_t)(ps->site->sled_end - ps->site->sled_address);
    ps->plan.window_address = ps->window_address;
    ps->plan.window_offset =
        (uint32_t)(ps->window_address - ps->site->sled_address);
    ps->plan.refusal = REPRO_HCR_LX_OK;
    /* §4.5: rollback restores the ORIGINAL, not generation N-1. */
    ps->original_word = ps->site->original_word;
    ps->previous_word = current_word;
  } else {
    if (ps->sled_address == 0) {
      ps->refusal = REPRO_HCR_LX_REFUSED_ABSENT_SLED;
      repro_hcr_lx_last_report.refusal = ps->refusal;
      return ps->refusal;
    }
    if (repro_hcr_lx_plan_sled((const uint8_t *)(uintptr_t)ps->sled_address,
                               REPRO_HCR_LX_MAX_SLED_SCAN, ps->sled_address,
                               &ps->plan) != REPRO_HCR_LX_OK) {
      ps->refusal = ps->plan.refusal;
      repro_hcr_lx_last_report.refusal = ps->plan.refusal;
      repro_hcr_lx_last_report.sled_address = ps->plan.sled_address;
      repro_hcr_lx_last_report.sled_end = ps->plan.sled_end;
      repro_hcr_lx_last_report.sled_length = ps->plan.sled_length;
      return ps->refusal;
    }
    ps->window_address = ps->plan.window_address;
    /* §11.2: read and save the original aligned word BEFORE anything can
     * change it. This is the only thing rollback needs. */
    memcpy(&ps->original_word, (const void *)(uintptr_t)ps->window_address,
           sizeof(ps->original_word));
    ps->previous_word = ps->original_word;
    ps->fresh_site = 1;
  }
  repro_hcr_lx_last_report.sled_address = ps->plan.sled_address;
  repro_hcr_lx_last_report.sled_end = ps->plan.sled_end;
  repro_hcr_lx_last_report.sled_length = ps->plan.sled_length;
  repro_hcr_lx_last_report.window_address = ps->window_address;
  repro_hcr_lx_last_report.window_offset = ps->plan.window_offset;
  repro_hcr_lx_last_report.original_word = ps->original_word;
  repro_hcr_lx_last_report.previous_word = ps->previous_word;

  /* -------------------------------------------------------------------------
   * ARBITRATION (design §10.1). Claim the published window BEFORE anything
   * that could write to it.
   *
   * MCR's patchers claim through the same map, so a `-2` here means the
   * recorder already owns bytes this provider was about to store into. The
   * refusal is NAMED (`claimed-by-recorder`) and carries the holder out, so
   * the agent reports it as a skipped function rather than a mystery.
   *
   * `ct_claimed_guest_text_claim` is weak: when `libct_interpose` is not in the
   * process it is NULL, which means there is no other patcher of this text and
   * therefore no claim to conflict with.
   *
   * The claim is taken only for a FRESH site. A re-patch is publishing into a
   * window this provider already owns; re-claiming would be refused by its own
   * live claim (§4.5).
   * ---------------------------------------------------------------------- */
  if (ps->fresh_site && ct_claimed_guest_text_claim != NULL) {
    unsigned holder = 0;
    int claim_rc = ct_claimed_guest_text_claim(
        (uintptr_t)ps->window_address, (size_t)REPRO_HCR_LX_WINDOW_BYTES,
        REPRO_HCR_CGT_OWNER_REPRO_HCR, &holder);
    if (claim_rc == -2) {
      repro_hcr_lx_last_report.claim_holder = holder;
      ps->refusal = REPRO_HCR_LX_REFUSED_CLAIMED_BY_RECORDER;
      repro_hcr_lx_last_report.refusal = ps->refusal;
      return ps->refusal;
    }
    if (claim_rc != 0) {
      /* -1 is a degenerate range, which cannot happen for an 8-byte window at
       * a non-wrapping address; treat it as an argument error rather than
       * proceeding unclaimed. */
      ps->refusal = REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
      repro_hcr_lx_last_report.refusal = ps->refusal;
      return ps->refusal;
    }
    ps->claimed_here = 1;
    repro_hcr_lx_last_report.claim_held = 1;
  } else if (!ps->fresh_site) {
    repro_hcr_lx_last_report.claim_held = ps->site->claimed;
  }

  /* The patch body is provider-owned memory no other thread can reach until
   * the publishing store makes it reachable. */
  if (ps->patch_len < sizeof(repro_hcr_lx_endbr64) ||
      memcmp(ps->patch_bytes, repro_hcr_lx_endbr64,
             sizeof(repro_hcr_lx_endbr64)) != 0) {
    body_prefix = sizeof(repro_hcr_lx_endbr64);
  }
  body_len = body_prefix + ps->patch_len;
  if (body_len > page_size) {
    repro_hcr_lx_txn_discard_prepared(txn, ps);
    ps->refusal = REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
    repro_hcr_lx_last_report.refusal = ps->refusal;
    return ps->refusal;
  }

  /*
   * HLX-M2: the body no longer HAS to be near. Near is still preferred,
   * because a directly reachable body means one fewer indirection on every
   * call into the patched function; but a body that lands outside `rel32`
   * reach is a supported case, reached through a 14-byte island.
   *
   * Order matters: the near probe runs first so nothing about the existing,
   * measured behaviour of a normal patch changes.
   */
  if (repro_hcr_lx_fail_patch_page_alloc) {
    ps->patch_page = NULL;
  } else if (repro_hcr_lx_force_far_patch_body) {
    ps->patch_page = (uint8_t *)repro_hcr_lx_map_patch_page_far(
        ps->window_address, page_size);
  } else {
    ps->patch_page = (uint8_t *)repro_hcr_lx_map_patch_page_near(
        ps->window_address, page_size);
    if (ps->patch_page == NULL) {
      ps->patch_page = (uint8_t *)repro_hcr_lx_map_code_page(NULL, page_size, 0);
    }
  }
  if (ps->patch_page == NULL) {
    repro_hcr_lx_txn_discard_prepared(txn, ps);
    ps->refusal = REPRO_HCR_LX_REFUSED_NO_PATCH_MEMORY;
    repro_hcr_lx_last_report.refusal = ps->refusal;
    return ps->refusal;
  }
  ps->patch_page_len = page_size;

  /* Design §4.2: an island-reachable body is entered through
   * `jmp [rip+disp32]` and so must begin with `endbr64` on an IBT-enforcing
   * process. Emitting the landing pad unconditionally costs four bytes and
   * makes every body island-ready. */
  /* HLX-M9: the body is put through the page's WRITABLE alias, which for a
   * dual-mapped page is a different address from the one it will execute at.
   * `repro_hcr_lx_code_writer` answers the page itself for the anonymous
   * fallback, so the two mechanisms share this one sequence rather than
   * forking it. Writing through `ps->patch_page` directly would fault on a
   * dual-mapped page — correctly, because that mapping is not writable. */
  {
    uint8_t *writer = repro_hcr_lx_code_writer(ps->patch_page);
    if (body_prefix != 0) {
      memcpy(writer, repro_hcr_lx_endbr64, sizeof(repro_hcr_lx_endbr64));
    }
    memcpy(writer + body_prefix, ps->patch_bytes, ps->patch_len);
  }
  /* A patch body is written ONCE and never again, so this is the case
   * `F_SEAL_WRITE` exists for: the writable alias is dropped and the memfd is
   * sealed, after which no writable alias to this executable page can be
   * created by anything. For the anonymous fallback this is the pre-HLX-M9
   * `mprotect` to PROT_READ|PROT_EXEC, unchanged. */
  if (repro_hcr_lx_finalize_code_page(ps->patch_page, page_size) != 0) {
    repro_hcr_lx_txn_discard_prepared(txn, ps);
    ps->refusal = REPRO_HCR_LX_REFUSED_PATCH_MEMORY_PROTECTION_FAILED;
    repro_hcr_lx_last_report.refusal = ps->refusal;
    return ps->refusal;
  }
  ps->dispatch_address = (uint64_t)(uintptr_t)ps->patch_page;

  /*
   * HLX-M2 — trampoline selection. One call, and it is the ONLY place that
   * decides what the published `rel32` points at. Everything it can return is
   * publishable in one aligned 8-byte store; the 13- and 14-byte in-text forms
   * of `Trampoline-Mechanics.md` §1.2/§1.3 are not reachable from here at any
   * sled length.
   */
  repro_hcr_lx_select_trampoline(ps->window_address, ps->dispatch_address,
                                 &choice);
  ps->trampoline_kind = choice.kind;
  ps->island_address = choice.island_address;
  ps->body_displacement = choice.body_displacement;
  repro_hcr_lx_last_report.trampoline_kind = choice.kind;
  repro_hcr_lx_last_report.island_address = choice.island_address;
  repro_hcr_lx_last_report.body_displacement = choice.body_displacement;
  if (choice.refusal != REPRO_HCR_LX_OK) {
    repro_hcr_lx_txn_discard_prepared(txn, ps);
    ps->refusal = choice.refusal;
    repro_hcr_lx_last_report.refusal = ps->refusal;
    return ps->refusal;
  }

  encode_rc = repro_hcr_lx_encode_jmp_rel32(ps->window_address,
                                            choice.jump_target, jmp_bytes);
  if (encode_rc != REPRO_HCR_LX_OK) {
    repro_hcr_lx_txn_discard_prepared(txn, ps);
    ps->refusal = encode_rc;
    repro_hcr_lx_last_report.refusal = ps->refusal;
    return ps->refusal;
  }
  ps->published_word = repro_hcr_lx_published_word(jmp_bytes);

  if (ps->fresh_site) {
    ps->site = repro_hcr_lx_claim_site(ps->entry_address);
    if (ps->site == NULL) {
      repro_hcr_lx_txn_discard_prepared(txn, ps);
      ps->refusal = REPRO_HCR_LX_REFUSED_SITE_TABLE_FULL;
      repro_hcr_lx_last_report.refusal = ps->refusal;
      return ps->refusal;
    }
    ps->site->sled_address = ps->plan.sled_address;
    ps->site->sled_end = ps->plan.sled_end;
    ps->site->window_address = ps->window_address;
    ps->site->original_word = ps->original_word;
    ps->site->original_word_saved = 1;
  }

  ps->span_start = repro_hcr_lx_page_start(ps->window_address, page_size);
  ps->span_end =
      repro_hcr_lx_page_start(
          ps->window_address + REPRO_HCR_LX_WINDOW_BYTES - 1, page_size) +
      (uint64_t)page_size;

  ps->prepared = 1;
  ps->refusal = REPRO_HCR_LX_OK;
  repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_OK;
  repro_hcr_lx_last_report.dispatch_address = ps->dispatch_address;
  return REPRO_HCR_LX_OK;
}

/*
 * Prepare the whole set. Either every site is prepared, or none is left
 * prepared and every provider-owned artefact taken along the way is released.
 *
 * Nothing in the target changed either way — that is the point of the phase,
 * and it is why the unwind below is simple enough to be obviously correct.
 */
static int repro_hcr_lx_txn_prepare(repro_hcr_lx_transaction *txn) {
  const repro_hcr_lx_capabilities *caps;
  int i;

  if (txn == NULL || txn->site_count == 0) {
    return REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
  }

  caps = repro_hcr_lx_capability_report();
  if (!caps->text_protection_roundtrip) {
    /* Design §5.2: MDWE lets the RW step succeed and fails only the PROT_EXEC
     * restore, which would leave the target's text permanently non-executable.
     * The provider probed this at agent start and refuses here rather than
     * discovering it after the point of no return. */
    memset(&repro_hcr_lx_last_report, 0, sizeof(repro_hcr_lx_last_report));
    txn->refusal = REPRO_HCR_LX_REFUSED_UNSUPPORTED_HOST;
    repro_hcr_lx_last_report.refusal = txn->refusal;
    return txn->refusal;
  }

  /*
   * HLX-OQ-3, resolved in HLX-M4: **always quiesce; refuse if we cannot.**
   *
   *   publish only if SYNC_CORE is available, OR quiescence is held.
   *
   * Why quiescence substitutes. Every thread that could be executing this text
   * has entered the kernel to take the `SIGRTMIN+n` and will return through
   * `IRET` (x86_64) or `ERET` (aarch64), both of which are architecturally
   * context-synchronizing — so the pipeline half of §4.4 is discharged by the
   * handshake itself, for exactly the set of threads that matters.
   *
   * Checked HERE, in prepare, before the claim and before any mapping, so the
   * refusal costs nothing and cannot leave state behind.
   */
  if (!repro_hcr_lx_sync_core_available() && !repro_hcr_lx_quiesce_is_held()) {
    memset(&repro_hcr_lx_last_report, 0, sizeof(repro_hcr_lx_last_report));
    txn->refusal = REPRO_HCR_LX_REFUSED_SYNC_CORE_UNAVAILABLE;
    repro_hcr_lx_last_report.refusal = txn->refusal;
    return txn->refusal;
  }

  for (i = 0; i < txn->site_count; ++i) {
    int rc = repro_hcr_lx_txn_prepare_site(txn, &txn->sites[i]);
    if (rc != REPRO_HCR_LX_OK) {
      int j;
      txn->refusal = rc;
      txn->failed_site = i;
#if defined(REPRO_HCR_HLX_M3_FALSIFY_PARTIAL_SET_COMMIT)
      /*
       * FALSIFIER ARM (HLX-M3). Removes the all-or-nothing property of prepare
       * and NOTHING else: the sites that DID prepare are kept and committed,
       * which is `Patch-Loading-Lifecycle.md` §3.3 item 39's "partially applied
       * patches are permitted" — the behaviour §11.2 supersedes for a
       * transactional set.
       *
       * What it proves is that the prepare-failure gate is measuring the
       * provider and not itself. Under this arm the multi-function arm of
       * `integration_hcr_linux_prepare_failure_leaves_process_byte_identical`
       * MUST go red: the healthy function's window is published even though a
       * later function in the same set refused. The agent never defines it.
       */
      if (i > 0) {
        txn->site_count = i;
        txn->prepare_complete = 1;
        txn->refusal = REPRO_HCR_LX_OK;
        repro_hcr_lx_last_report.prepare_complete = 1;
        return REPRO_HCR_LX_OK;
      }
#endif
      /* Unwind in reverse, for symmetry with commit's rollback order. Nothing
       * here has touched target text, so the order is a discipline rather than
       * a correctness requirement — but a rollback that is ordered in one
       * phase and unordered in the other is how the two drift apart. */
      for (j = i - 1; j >= 0; --j) {
        repro_hcr_lx_txn_discard_prepared(txn, &txn->sites[j]);
      }
      repro_hcr_lx_last_report.prepare_complete = 0;
      return rc;
    }
  }

  txn->prepare_complete = 1;
  txn->refusal = REPRO_HCR_LX_OK;
  repro_hcr_lx_last_report.prepare_complete = 1;
  return REPRO_HCR_LX_OK;
}

/*
 * Publish one prepared site: the transient, the single aligned store, the
 * tier-2 IP adjustment, the protection restore and the `SYNC_CORE` event.
 *
 * `fault_now` is the test lever's decision for THIS site, evaluated by the
 * caller. It is applied as the RESULT of the transient `mprotect`, so the
 * branch taken below is the production failure branch.
 */
static int repro_hcr_lx_txn_publish_site(repro_hcr_lx_transaction *txn,
                                         repro_hcr_lx_prepared_site *ps,
                                         int fault_now,
                                         int restore_fault_now) {
  const repro_hcr_lx_capabilities *caps = repro_hcr_lx_capability_report();
  int transient_protection;
  long protect_rc;

  /*
   * THE TRANSIENT KEEPS `PROT_EXEC` WHEN THE HOST ALLOWS IT, and HLX-M4 found
   * that the hard way. `mprotect(RW)` over a live text page removes the NX
   * clearance for the WHOLE PAGE, not for the eight bytes being written, so
   * every thread whose PC is anywhere in those 4 KiB faults on its next
   * instruction fetch.
   */
  transient_protection = REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE;
  if (caps->text_rwx_transition) {
    transient_protection |= REPRO_HCR_LX_PROT_EXEC;
  }
  repro_hcr_lx_last_report.transient_kept_exec = caps->text_rwx_transition;

  if (fault_now) {
    /* -EACCES: exactly what a kernel refusing the transition returns. The
     * syscall is NOT issued, so the target's protection is untouched and this
     * site is as unpublished as if the kernel had said no. */
    protect_rc = -13;
  } else {
    protect_rc = repro_hcr_lx_raw_mprotect(
        ps->span_start, (size_t)(ps->span_end - ps->span_start),
        transient_protection);
  }
  if (protect_rc != 0) {
    ps->refusal = REPRO_HCR_LX_REFUSED_TEXT_PROTECTION_FAILED;
    repro_hcr_lx_last_report.refusal = ps->refusal;
    return ps->refusal;
  }

  /*
   * PUBLICATION.
   *
   * Safety argument, stated here rather than left implicit as it is on macOS.
   * It has two halves and both are required (design §4.2, §4.4), and a third
   * point neither half covers:
   *
   *   1. `window_address` is 8-byte aligned and this is an ordinary aligned
   *      8-byte store, so it is single-copy atomic on x86_64. Any thread reads
   *      either the whole previous word (all NOPs, or the previous
   *      generation's jump) or the whole new `E9 rel32 90 90 90`. There is no
   *      third byte-level state, and in particular no partially written jump
   *      through an address composed of NOP bytes. HLX-M3 adds the consequence
   *      this milestone needs: because the store is atomic and the word it
   *      replaced was SAVED, the publication is individually REVERSIBLE — one
   *      store undoes it exactly.
   *
   *   2. Atomicity of the bytes is not visibility to a core that has already
   *      fetched the old ones. Intel SDM Vol 3 §8.1.3 / §9.3 ("Handling Self-
   *      and Cross-Modifying Code") requires the *executing* processor to
   *      perform a serializing operation; a coherent instruction cache does
   *      not discharge that, and the `mprotect` TLB shootdown is not a
   *      guaranteed substitute (Linux may skip the remote IPI entirely when
   *      `mm_cpumask` names one CPU). The
   *      `MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE` below forces a
   *      context-synchronizing event on every core running this process.
   *
   *   3. A thread whose PC is INSIDE the window is the hazard neither half
   *      addresses, and it is real: the sled is executable instructions, so an
   *      interrupt can leave a thread at window byte 1..7, and on resume it
   *      executes the tail of this very `E9 rel32` as though it were an
   *      instruction (design §6.1 point 4). Only tier 2 can fix it, by reading
   *      the parked PC out of a `ucontext_t` and nudging it past the window.
   *      REVERSIBILITY DOES NOT HELP HERE EITHER: rolling the store back
   *      cannot un-execute what a thread already decoded. That is why HLX-M3
   *      claims per-function atomicity and explicitly does not claim safety
   *      under concurrent execution.
   */
  *(volatile uint64_t *)(uintptr_t)ps->window_address = ps->published_word;
  __atomic_signal_fence(__ATOMIC_SEQ_CST);
  repro_hcr_lx_publication_count += 1;
  ps->published = 1;
  txn->published_count += 1;

  /*
   * Tier-2 IP adjustment (§6.2 step 6), applied while every thread is still
   * parked. A thread standing at window byte 1..7 has its resume PC moved to
   * the first instruction boundary at or after the window's end, so it falls
   * through the remaining sled into the retained old body instead of decoding
   * our `rel32` as opcodes. Under tier 1 `quiesce_is_held()` is false and this
   * is a no-op — which is the hazard, not an oversight.
   */
  if (repro_hcr_lx_quiesce_is_held()) {
    uint64_t window_end =
        ps->window_address + (uint64_t)REPRO_HCR_LX_WINDOW_BYTES;
    /*
     * Where to nudge to. `Trampoline-Mechanics.md:196` and §6.2 step 6 say
     * "forward to the first real instruction", which preserves §6.1 point 3 —
     * an in-flight entry completes in the RETAINED old body. That is only
     * legal if `window_end` is an instruction boundary of the remaining sled;
     * it is for GCC's single-byte sled and it is not guaranteed in general, so
     * it is CHECKED rather than assumed.
     *
     * The fallback when it cannot be confirmed is `window_address` itself, not
     * "leave the PC alone". Resuming at the window's first byte executes the
     * freshly published `E9 rel32` — a complete, valid instruction at a
     * boundary the provider itself chose — so the thread takes the new body.
     */
    uint64_t resume_target = ps->window_address;
    /*
     * Decide it from the window's ORIGINAL bytes, not from live memory: by the
     * time this runs the store has already landed, so reading the window back
     * would decode our own `E9` and conclude — wrongly, every time — that
     * `window_end` is not a boundary.
     */
    uint8_t original_bytes[REPRO_HCR_LX_WINDOW_BYTES];
    size_t consumed = 0;
    memcpy(original_bytes, &ps->original_word, sizeof(original_bytes));
    while (consumed < REPRO_HCR_LX_WINDOW_BYTES) {
      size_t len = repro_hcr_lx_nop_length(
          original_bytes + consumed, REPRO_HCR_LX_WINDOW_BYTES - consumed);
      if (len == 0) {
        break;
      }
      consumed += len;
    }
    if (consumed == REPRO_HCR_LX_WINDOW_BYTES && window_end < ps->plan.sled_end) {
      resume_target = window_end;
    }
    repro_hcr_lx_last_report.resume_target = resume_target;
    repro_hcr_lx_last_report.ip_adjustments =
        repro_hcr_lx_quiesce_adjust_window(ps->window_address, window_end,
                                           resume_target);
    repro_hcr_lx_last_report.quiesced = 1;
  }

  if (restore_fault_now ||
      repro_hcr_lx_raw_mprotect(ps->span_start,
                                (size_t)(ps->span_end - ps->span_start),
                                REPRO_HCR_LX_PROT_READ |
                                    REPRO_HCR_LX_PROT_EXEC) != 0) {
    /* The trampoline is already live, so reporting total failure here would
     * repeat the defect the Apple arm carried at its post-store `return NULL`.
     * The honest report is success plus a recorded flag; the capability probe
     * at agent start exists so this path is unreachable on a supported host.
     *
     * HLX-M9 2026-09-19: the flag now REACHES A CONSUMER. It rides the
     * `patchApplied` frame as `textLeftWritable` — see
     * `repro_hcr_text_left_writable` in `repro_hcr_agent.c` for why the
     * applied frame and not a refusal. Under `restore_fault_now` the syscall
     * is skipped rather than its result forged, so the page genuinely stays
     * writable and a gate can read that back out of `/proc/self/maps`. */
    repro_hcr_lx_caps.text_left_writable = 1;
    repro_hcr_lx_last_report.text_left_writable = 1;
  }

  /* Half 2 of the safety argument. The counter is not decoration: it is the
   * only way a gate can distinguish "the event was issued and returned 0" from
   * "this branch was never reached", which look identical in a report whose
   * `membarrier_result` field starts life as 0. */
  if (repro_hcr_lx_sync_core_available() &&
      !repro_hcr_lx_sync_core_suppressed) {
    repro_hcr_lx_last_report.membarrier_result = repro_hcr_lx_raw_membarrier(
        REPRO_HCR_LX_MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE, 0);
    repro_hcr_lx_membarrier_issued_count += 1;
  } else {
    /* Reachable only under quiescence (the refusal in prepare is the other
     * case), where the handshake's own kernel entry/exit is the
     * context-synchronizing event, or under the test lever that removes half 2
     * deliberately. */
    repro_hcr_lx_last_report.membarrier_result = -1;
  }

  ps->site->published_word = ps->published_word;
  ps->site->generation += 1;
  /* §4.5: every generation's body is retained, superseded ones included. This
   * count IS the provider's retained-region evidence, and it is what
   * `oldCodeRetained` is computed from instead of being asserted. */
  ps->site->retained_body_count += 1;
  ps->body_retained = 1;
  txn->retained_body_count += 1;
  if (ps->claimed_here) {
    ps->site->claimed = 1;
  }
  repro_hcr_lx_last_report.claim_held = ps->site->claimed;
  repro_hcr_lx_last_report.published_word = ps->published_word;
  repro_hcr_lx_last_report.dispatch_address = ps->dispatch_address;
  repro_hcr_lx_last_report.generation = ps->site->generation;
  repro_hcr_lx_last_report.retained_region_count =
      (ps->site->original_word_saved ? 1 : 0) +
      (int)ps->site->retained_body_count;
  repro_hcr_lx_last_report.old_code_retained =
      repro_hcr_lx_last_report.retained_region_count > 0;
  repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_OK;
  return REPRO_HCR_LX_OK;
}

/*
 * Restore one published site to its ORIGINAL saved word (§4.5: the original,
 * never the previous generation, so a rolled-back site returns to unpatched
 * code rather than to an older patch whose body may since have been superseded).
 *
 * One aligned 8-byte store, same rule as publication. Never widened.
 */
static int repro_hcr_lx_txn_restore_site(repro_hcr_lx_transaction *txn,
                                         repro_hcr_lx_prepared_site *ps) {
  const repro_hcr_lx_capabilities *caps = repro_hcr_lx_capability_report();
  int transient_protection =
      REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE;
  if (caps->text_rwx_transition) {
    transient_protection |= REPRO_HCR_LX_PROT_EXEC;
  }
  if (repro_hcr_lx_raw_mprotect(ps->span_start,
                                (size_t)(ps->span_end - ps->span_start),
                                transient_protection) != 0) {
    /* Nothing else can be done for this site: the window keeps the published
     * word. It is recorded rather than swallowed — a rollback that reports
     * success for a site it could not restore is the failure mode this whole
     * milestone exists to remove. */
    return REPRO_HCR_LX_REFUSED_TEXT_PROTECTION_FAILED;
  }
#if defined(REPRO_HCR_HLX_M3_FALSIFY_ROLLBACK_TO_PREVIOUS_GENERATION)
  /*
   * FALSIFIER ARM (HLX-M3). Restores the PREVIOUS GENERATION's word instead of
   * the original, which is precisely what design §4.5 forbids: "rollback always
   * restores the original saved word, not the previous generation's, so a
   * rolled-back site returns to unpatched code rather than to an older patch".
   *
   * For a first-generation site the two words are equal, so this arm is
   * INVISIBLE until a function has been patched at least twice — which is why
   * the re-patch gate is the one that has to carry it. Under this arm the
   * "rollback after generation 3 restores the ORIGINAL bytes" assertion MUST go
   * red and the victim MUST return generation 2's value. The agent never
   * defines it.
   */
  *(volatile uint64_t *)(uintptr_t)ps->window_address = ps->previous_word;
#else
  *(volatile uint64_t *)(uintptr_t)ps->window_address = ps->original_word;
#endif
  __atomic_signal_fence(__ATOMIC_SEQ_CST);
  if (repro_hcr_lx_raw_mprotect(ps->span_start,
                                (size_t)(ps->span_end - ps->span_start),
                                REPRO_HCR_LX_PROT_READ |
                                    REPRO_HCR_LX_PROT_EXEC) != 0) {
    repro_hcr_lx_caps.text_left_writable = 1;
    repro_hcr_lx_last_report.text_left_writable = 1;
  }
  /* The restore is cross-modifying code exactly as the publication was (§4.4),
   * so it needs the same serializing event. */
  if (repro_hcr_lx_sync_core_available() &&
      !repro_hcr_lx_sync_core_suppressed) {
    (void)repro_hcr_lx_raw_membarrier(
        REPRO_HCR_LX_MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE, 0);
    repro_hcr_lx_membarrier_issued_count += 1;
  }
  ps->restored = 1;
  txn->restored_count += 1;
  return REPRO_HCR_LX_OK;
}

/*
 * Roll the transaction back. Safe to call after a prepare failure (nothing is
 * published, so it degenerates to releasing provider memory and claims), after
 * a partial commit, or after a complete commit that the caller decided to
 * abandon.
 *
 * Order: published sites are restored in REVERSE publication order, then
 * registrations are undone, then claims are released, then unpublished bodies
 * are unmapped. Published bodies and every island are RETAINED — see the
 * header comment.
 */
static int repro_hcr_lx_txn_rollback(repro_hcr_lx_transaction *txn) {
  int i;
  int rc = REPRO_HCR_LX_OK;
  if (txn == NULL) {
    return REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
  }
  for (i = txn->site_count - 1; i >= 0; --i) {
    repro_hcr_lx_prepared_site *ps = &txn->sites[i];
    if (!ps->published) {
      continue;
    }
    if (repro_hcr_lx_txn_restore_site(txn, ps) != REPRO_HCR_LX_OK) {
      rc = REPRO_HCR_LX_REFUSED_TEXT_PROTECTION_FAILED;
    }
  }
  for (i = txn->site_count - 1; i >= 0; --i) {
    repro_hcr_lx_prepared_site *ps = &txn->sites[i];
    if (ps->jit_entry_address != 0) {
      txn->unregister_attempts += 1;
      if (repro_hcr_lx_unregister_jit_hook != NULL) {
        (void)repro_hcr_lx_unregister_jit_hook(ps->jit_entry_address);
      }
      ps->jit_entry_address = 0;
    }
    if (ps->eh_frame_payload_address != 0) {
      txn->unregister_attempts += 1;
      if (repro_hcr_lx_unregister_eh_frame_hook != NULL) {
        (void)repro_hcr_lx_unregister_eh_frame_hook(
            ps->eh_frame_payload_address);
      }
      ps->eh_frame_payload_address = 0;
    }
    if (ps->published) {
      /* The window is back to its original bytes, so the site is unpatched
       * again: retire the slot and release the claim (§4.5 releases the claim
       * on rollback). The patch page is NOT unmapped — a thread may have
       * entered it before the restore landed, and under tier 1 there is no way
       * to prove otherwise. */
      /*
       * The claim belongs to the SITE, not to this transaction: §4.5 takes it
       * once at the first publication and RETAINS it across generations, so by
       * generation N the transaction that is rolling back did not take it and
       * `claimed_here` is 0. Releasing only what this transaction claimed
       * would therefore leak the claim on every re-patch rollback — measured,
       * and it is why the condition is the site's flag and not the
       * transaction's.
       */
      int site_claimed = (ps->site != NULL && ps->site->claimed);
      if (ps->site != NULL) {
        ps->site->used = 0;
        ps->site = NULL;
      }
      if ((ps->claimed_here || site_claimed) &&
          ct_claimed_guest_text_release != NULL) {
        ct_claimed_guest_text_release((uintptr_t)ps->window_address);
        txn->released_claim_count += 1;
      }
      ps->claimed_here = 0;
      ps->patch_page = NULL;   /* retained, deliberately leaked (§4.5/§6.1) */
    } else if (ps->prepared) {
      repro_hcr_lx_txn_discard_prepared(txn, ps);
    }
  }
  txn->rolled_back = 1;
  repro_hcr_lx_last_report.rolled_back = 1;
  repro_hcr_lx_last_report.restored_sites = txn->restored_count;
  return rc;
}

/*
 * Commit: a sequence of single atomic stores, each individually reversible
 * from its saved word. A failure at site k restores sites 0..k-1 in reverse
 * and leaves the target running the code it was running before.
 */
static int repro_hcr_lx_txn_commit(repro_hcr_lx_transaction *txn) {
  int i;
  if (txn == NULL || !txn->prepare_complete) {
    return REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
  }
  for (i = 0; i < txn->site_count; ++i) {
    int fault_now = (repro_hcr_lx_commit_fault_site == i);
    int restore_fault_now = (repro_hcr_lx_restore_fault_site == i);
    int rc = repro_hcr_lx_txn_publish_site(txn, &txn->sites[i], fault_now,
                                           restore_fault_now);
    if (rc != REPRO_HCR_LX_OK) {
      txn->refusal = rc;
      txn->failed_site = i;
#if defined(REPRO_HCR_HLX_M3_FALSIFY_NO_ROLLBACK_ON_COMMIT_FAILURE)
      /*
       * FALSIFIER ARM (HLX-M3). Removes the rollback and nothing else, which is
       * exactly the pre-milestone state design §11.1 describes: "an
       * eight-operation commit sequence with no undo path; a failure
       * mid-sequence ... leaves the target in whatever partial state it
       * reached."
       *
       * Under this arm the commit-failure gate MUST go red: the N sites already
       * published stay published, their functions return the NEW values, and
       * their windows do not match the pre-transaction snapshot. The agent
       * never defines it.
       */
      repro_hcr_lx_last_report.refusal = rc;
      repro_hcr_lx_last_report.commit_complete = 0;
      return rc;
#endif
      (void)repro_hcr_lx_txn_rollback(txn);
      repro_hcr_lx_last_report.refusal = rc;
      repro_hcr_lx_last_report.commit_complete = 0;
      repro_hcr_lx_last_report.published_sites = 0;
      return rc;
    }
  }
  txn->commit_complete = 1;
  repro_hcr_lx_last_report.commit_complete = 1;
  repro_hcr_lx_last_report.published_sites = txn->published_count;
  repro_hcr_lx_last_report.prepare_complete = 1;
  return REPRO_HCR_LX_OK;
}

/*
 * Apply a direct entry patch at `entry_address`, publishing inside the sled
 * that starts at `sled_address`.
 *
 * `sled_address` is a parameter rather than a lookup so that HLX-M1's real
 * symbol/ELF pipeline can supply it, and so the HLX-M0 gates can drive the
 * exact production code path against a sled they constructed from real
 * compiler output. `repro_hcr_apply_direct_patch` in the agent supplies it
 * from the runtime-mapped `__patchable_function_entries` section.
 *
 * Since HLX-M3 this is the one-function case of the transaction above — the
 * same prepare, the same commit, the same rollback — rather than a second
 * implementation of them. Its observable behaviour is unchanged: the same
 * refusals in the same order, the same report fields, and the live body
 * address or NULL.
 *
 * Returns the live patch-body address, or NULL with `repro_hcr_lx_last_report`
 * carrying a named refusal.
 */
/*
 * HLX-M8 split the body of `repro_hcr_lx_apply_direct_patch_at` in two without
 * changing it, because the application ABI needs the boundary NAMED.
 *
 * `Patch-Loading-Lifecycle.md` §3.1 puts four things in a fixed order, and two
 * of them are on opposite sides of this line:
 *
 *   Phase F (16-20) — load and resolve.  For Direct Patch Injection §3.2
 *     replaces it with the in-memory link, which is exactly what
 *     `repro_hcr_lx_txn_prepare` does: allocate the provider-owned body page,
 *     copy the bytes, choose near body or island, plan the branch.  It writes
 *     NOTHING to target text, so a failure here is recoverable — and §3.3
 *     step 38 says the agent must still run the after-reload callbacks.
 *   Phase G (21-27) — trampoline installation.  `repro_hcr_lx_txn_commit`, the
 *     one naturally aligned 8-byte store per site.  This is where new code
 *     becomes live.
 *
 * An application's before-reload callback runs BETWEEN the caller's own
 * pre-flight and Phase F, so the agent needs to be able to stop there.  The
 * composition below is byte-for-byte the previous function, so the probe shim
 * and every HLX-M0/M2/M3/M5 gate that calls it sees no change at all.
 */
static int repro_hcr_lx_prepare_direct_patch_at(uint64_t entry_address,
                                                uint64_t sled_address,
                                                const uint8_t *patch_bytes,
                                                size_t patch_len) {
  repro_hcr_lx_transaction *txn = &repro_hcr_lx_last_txn;

  repro_hcr_lx_txn_reset(txn);
  memset(&repro_hcr_lx_last_report, 0, sizeof(repro_hcr_lx_last_report));
  if (repro_hcr_lx_txn_add(txn, entry_address, sled_address, patch_bytes,
                           patch_len) != REPRO_HCR_LX_OK) {
    repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
    return REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
  }
  return repro_hcr_lx_txn_prepare(txn);
}

/* Phase G.  Returns the live patch-body address, or NULL with
 * `repro_hcr_lx_last_report` carrying a named refusal. */
static void *repro_hcr_lx_commit_direct_patch(void) {
  repro_hcr_lx_transaction *txn = &repro_hcr_lx_last_txn;
  if (repro_hcr_lx_txn_commit(txn) != REPRO_HCR_LX_OK) {
    return NULL;
  }
  return (void *)(uintptr_t)txn->sites[0].dispatch_address;
}

REPRO_HCR_LX_MAYBE_UNUSED static void *repro_hcr_lx_apply_direct_patch_at(
    uint64_t entry_address, uint64_t sled_address, const uint8_t *patch_bytes,
    size_t patch_len) {
  if (repro_hcr_lx_prepare_direct_patch_at(entry_address, sled_address,
                                           patch_bytes,
                                           patch_len) != REPRO_HCR_LX_OK) {
    return NULL;
  }
  return repro_hcr_lx_commit_direct_patch();
}

#endif /* REPRO_HCR_LINUX_X86_64_H */
