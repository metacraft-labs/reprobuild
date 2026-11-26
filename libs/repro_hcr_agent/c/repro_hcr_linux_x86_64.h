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

/*
 * W^X, ENFORCED HERE RATHER THAN PROMISED AT EACH CALL SITE. The provider never
 * asks for a mapping that is writable and executable at once: code is written
 * through a separate writable view (the HLX-M9 `memfd` alias) or into a page
 * that is not yet executable, and live target text is replaced by remapping a
 * finished executable page over it (`repro_hcr_lx_replace_text_word`). A
 * request for `PROT_WRITE|PROT_EXEC` is therefore a provider defect, and it is
 * refused without issuing the syscall and counted, so a gate can assert the
 * count stays 0 instead of trusting every caller. The same rule holds for
 * `repro_hcr_lx_raw_mmap`.
 *
 * Why it matters beyond hardening: an in-process recorder refuses code made
 * writable while it stays executable (codetracer-specs
 * `MCR-Linux-Instruction0.md` §3.4 E5), so a single `RW|EXEC` request ends
 * the recording of the process the provider lives in.
 */
#define REPRO_HCR_LX_EACCES 13
static uint64_t repro_hcr_lx_wx_requests_refused = 0;

static int repro_hcr_lx_protection_is_wx(int protection) {
  return (protection & (REPRO_HCR_LX_PROT_WRITE | REPRO_HCR_LX_PROT_EXEC)) ==
         (REPRO_HCR_LX_PROT_WRITE | REPRO_HCR_LX_PROT_EXEC);
}

/* Every `mprotect` the provider ISSUES, so a gate can assert that none of
 * them touched target text (design §14: target text is replaced, never
 * re-protected). The first REPRO_HCR_LX_MPROTECT_LOG_CAP ranges are kept; the
 * count goes on past that, so a reader can tell a complete log from a
 * truncated one. Observations only: nothing in the provider branches on
 * them. */
#define REPRO_HCR_LX_MPROTECT_LOG_CAP 64
static uint64_t repro_hcr_lx_mprotect_issued_count = 0;
static uint64_t repro_hcr_lx_mprotect_log_address[REPRO_HCR_LX_MPROTECT_LOG_CAP];
static uint64_t repro_hcr_lx_mprotect_log_length[REPRO_HCR_LX_MPROTECT_LOG_CAP];

/* Returns 0 on success, or the negated errno the kernel reported. */
static long repro_hcr_lx_raw_mprotect(uint64_t address, size_t length,
                                      int protection) {
  if (repro_hcr_lx_protection_is_wx(protection)) {
    repro_hcr_lx_wx_requests_refused += 1;
    return -REPRO_HCR_LX_EACCES;
  }
  if (repro_hcr_lx_mprotect_issued_count < REPRO_HCR_LX_MPROTECT_LOG_CAP) {
    repro_hcr_lx_mprotect_log_address[repro_hcr_lx_mprotect_issued_count] =
        address;
    repro_hcr_lx_mprotect_log_length[repro_hcr_lx_mprotect_issued_count] =
        (uint64_t)length;
  }
  repro_hcr_lx_mprotect_issued_count += 1;
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
 * WHAT IS PROBED IS THE PUBLICATION ITSELF. Since 2026-10-05 target text is
 * replaced, never written in place (design §5.1): a copy of the span is built
 * in a provider code page (the `memfd` dual mapping, or the anonymous
 * fallback), finalized, and moved over the live span with
 * `mremap(MREMAP_FIXED)`. So the probe runs exactly that replacement, through
 * the production `repro_hcr_lx_replace_text_word`, on a scratch
 * `PROT_READ|PROT_EXEC` mapping the provider owns, and then CALLS the replaced
 * page. The `memfd` backing is tried first and the anonymous fallback second;
 * a host on which neither completes is refused at negotiation, never
 * discovered mid-commit.
 *
 * The `mprotect` RW->RX round trip this probe used to measure is NOT probed
 * any more. It is not the publication, so a host that refuses it — MDWE does,
 * and MDWE leaves the `memfd` backing alone — is not thereby unable to
 * publish. Measuring it would refuse exactly the hardened hosts the `memfd`
 * backing exists to serve.
 * ------------------------------------------------------------------------- */

/* What one backing's probe replacement answered. 0 and the negated errnos are
 * the replacement's own answer (`repro_hcr_lx_replace_text_word`); the small
 * positive values say why there is no such answer. */
#define REPRO_HCR_LX_REPLACEMENT_COMPLETED 0
#define REPRO_HCR_LX_REPLACEMENT_NOT_ATTEMPTED 1  /* an earlier backing completed */
#define REPRO_HCR_LX_REPLACEMENT_BACKING_UNAVAILABLE 2 /* no sealable memfd dual mapping */
#define REPRO_HCR_LX_REPLACEMENT_BACKING_DISABLED 3 /* the test lever forced the fallback */
#define REPRO_HCR_LX_REPLACEMENT_SCRATCH_UNAVAILABLE 4 /* no scratch mapping */
#define REPRO_HCR_LX_REPLACEMENT_WRONG_ANSWER 5 /* the page ran and returned the wrong value */

/* Which backing completed the probe replacement. */
#define REPRO_HCR_LX_BACKING_NONE 0
#define REPRO_HCR_LX_BACKING_MEMFD 1
#define REPRO_HCR_LX_BACKING_ANONYMOUS 2

typedef struct repro_hcr_lx_capabilities {
  int probed;
  /* 1 when a complete §5.1 page replacement was performed on the scratch
   * mapping and the replaced page ran. This, and nothing else, is what
   * "this host can be patched" means on Linux. */
  int text_replacement_supported;
  int text_replacement_backing;          /* REPRO_HCR_LX_BACKING_* */
  long text_replacement_memfd_result;     /* REPRO_HCR_LX_REPLACEMENT_* or -errno */
  long text_replacement_anonymous_result; /* REPRO_HCR_LX_REPLACEMENT_* or -errno */
  /* The §5.1 step at which each backing's replacement stopped
   * (REPRO_HCR_LX_REPLACE_STEP_*), so a refusal says whether it came before
   * the move (step 5) — the property design §14 requires of the anonymous
   * fallback under MDWE — rather than leaving it to be inferred from an
   * errno that the move could equally answer. 0 when it completed or was
   * not attempted. */
  int text_replacement_memfd_step;
  int text_replacement_anonymous_step;
  int membarrier_sync_core;        /* 1 when SYNC_CORE is registered and usable */
  long membarrier_query_mask;
  long membarrier_register_result;
  /* There is deliberately no `RW|EXEC` capability any more. HLX-M4 probed for
   * one and used it as the publication's transient, because dropping
   * `PROT_EXEC` from the page the target is executing faults every thread
   * whose PC is anywhere in it. The provider now never maps code writable and
   * executable at once; live text is replaced by remapping a finished copy
   * over it, which keeps the page executable without ever making it writable
   * (`repro_hcr_lx_replace_text_word`). */
  int text_left_writable;          /* never set on Linux now: text is replaced, not written (kept for the wire field) */
  /* HLX-M9. `PR_GET_MDWE` for this process: the flags, or a negated errno.
   * Read so a capability-time refusal can NAME the blocking policy instead of
   * describing its symptom. A host that refuses the replacement WITHOUT MDWE
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
/* Defined after the replacement it drives (below). */
static void repro_hcr_lx_probe_text_replacement(void);
/* Provided by the including translation unit: apply the test levers that
 * select a code path the agent-start probe must take too (the agent reads its
 * `REPRO_HCR_TEST_*` environment; the probe shim sets its levers directly and
 * supplies an empty body). Called once, before the first probe. */
static void repro_hcr_lx_apply_probe_levers(void);

static void repro_hcr_lx_probe_capabilities(void) {
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

  repro_hcr_lx_apply_probe_levers();
  repro_hcr_lx_probe_text_replacement();
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
  uint64_t original_word;  /* the window's pre-patch word, saved at the FIRST
                            * publication. It is the rollback target only for
                            * a transaction that published this site for the
                            * first time; a re-patch rolls back to the word
                            * published before it (`previous_word`, §11.2) */
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
  if (repro_hcr_lx_protection_is_wx(protection)) {
    repro_hcr_lx_wx_requests_refused += 1;
    return -REPRO_HCR_LX_EACCES;
  }
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
  /* The probe maps an executable memfd page: a recorder that watches
   * executable memory must already know this process reports its code. */
  repro_hcr_mcr_declare_reporter();

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
/* `memfd_name` labels the page in `/proc/PID/maps` (`/memfd:<name>`). Patch
 * bodies and islands are "repro-hcr-code"; a replaced page of target text is
 * "repro-hcr-text" (`repro_hcr_lx_replace_text_word`), so the two are told
 * apart by anyone reading the maps — a gate counting retained bodies, or an
 * operator asking why a text page no longer names its ELF file. */
#define REPRO_HCR_LX_CODE_MEMFD_NAME "repro-hcr-code"
#define REPRO_HCR_LX_TEXT_MEMFD_NAME "repro-hcr-text"

static void *repro_hcr_lx_map_named_code_page(void *hint, size_t length,
                                              int extra_flags,
                                              const char *memfd_name) {
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
      memfd_name, REPRO_HCR_LX_MFD_CLOEXEC | REPRO_HCR_LX_MFD_ALLOW_SEALING);
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

static void *repro_hcr_lx_map_code_page(void *hint, size_t length,
                                        int extra_flags) {
  return repro_hcr_lx_map_named_code_page(hint, length, extra_flags,
                                          REPRO_HCR_LX_CODE_MEMFD_NAME);
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
 * pre-HLX-M9 `mprotect` to `PROT_READ|PROT_EXEC`, unchanged, and a refusal
 * returns the kernel's negated errno. */
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
    /* The kernel's own answer (0 or a negated errno), so a refusal here —
     * MDWE's `EACCES` — reaches the caller as measured, not as a constant. */
    long rc = repro_hcr_lx_raw_mprotect((uint64_t)(uintptr_t)exec_base,
                                        length,
                                        REPRO_HCR_LX_PROT_READ |
                                            REPRO_HCR_LX_PROT_EXEC);
    return (int)rc;
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
 * WHEN THIS RUNS, because the answer constrains what it may do. It runs in
 * the transaction prepare, which since 2026-11-18 completes BEFORE
 * `quiesce_begin` (design §6.2 "Deadlock hazards", §11.2), so every thread is
 * running. It used to be reached with every other thread parked under tier 2,
 * which is why it keeps its conservative shape: no `malloc`, no
 * `dl_iterate_phdr`, a static buffer, and `openat`/`read`/`close` issued as RAW
 * syscalls. Since HLX-M9 the CODE-page path is raw too — `memfd_create`,
 * `ftruncate`, both `mmap`s, `munmap`, `fcntl` and `close`. The anonymous
 * FALLBACK and the near-DATA page go through `repro_hcr_lx_map_anonymous`,
 * which is libc outside the window and a raw system call inside it.
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
   * ONLY A DUAL-MAPPED PAGE IS REUSED once it holds an island. Every island
   * already on a used page is LIVE — a published `rel32` in target text jumps
   * to it — so the page must stay executable while the next island is
   * written, and the provider never makes a page writable and executable at
   * once (see `repro_hcr_lx_raw_mprotect`). A dual-mapped page satisfies both:
   * the island is written through its separate writable alias. An anonymous
   * fallback page cannot, so once it holds an island it is not written again
   * and a fresh page is taken instead; an unused page has no live island on it
   * and is safe to write while non-executable.
   */
  for (i = 0; i < repro_hcr_lx_island_page_count; ++i) {
    repro_hcr_lx_island_page *candidate = &repro_hcr_lx_island_pages[i];
    uint64_t candidate_slot;
    if (candidate->used >= slots_per_page) {
      continue;
    }
    if (candidate->used > 0 &&
        !repro_hcr_lx_code_page_is_dual(candidate->base)) {
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
   * page is dual-mapped (the reuse condition above admits no other kind once a
   * page holds an island) and is written through its alias. The slot being
   * written is not reachable from anywhere until the publishing store lands,
   * so the write itself needs no atomicity.
   */
  if (repro_hcr_lx_code_page_is_dual(page->base)) {
    /* HLX-M9 — THE DUAL-MAPPED PATH, and the whole point of it is what is
     * ABSENT here: no `mprotect` at all, in either direction, at any point.
     * The island is written through the page's shared alias at the same
     * offset, and the exec mapping is never touched, so every island already
     * on this page stays executable across the write and no protection change
     * is requested of a kernel that may refuse one. */
    uint8_t *writer = repro_hcr_lx_code_writer((void *)(uintptr_t)page->base);
    memcpy(writer + (slot - page->base), island, sizeof(island));
    repro_hcr_mcr_report_code((const void *)(uintptr_t)slot, sizeof(island));
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
  /* 1 when the publication reached the live page by replacing it
   * (`repro_hcr_lx_replace_text_word`), so the page stayed executable and was
   * never writable. */
  int text_replaced;
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
   * `previous_word` is the window's pre-state at PREPARE time — the original
   * word for a first publication, the previous generation's published word
   * for a re-patch — and it is the ROLLBACK TARGET: a rolled-back transaction
   * leaves the process on the version it was running before (§11.2), never
   * on a mixture with generation 0. `original_word` above is the pre-patch
   * word, which equals `previous_word` only for a first publication. */
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
 * computed, and every site's pre-transaction aligned word saved (the rollback
 * target, `previous_word`; for a first publication also the original word
 * the site table keeps). The only write into
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
 * ROLLBACK RESTORES THE PREVIOUS VERSION, NOT GENERATION 0. Each published
 * site gets back the word that was in its window BEFORE this transaction
 * (`previous_word`): the all-NOP window for a site this transaction published
 * first, generation N's jump for a site it was re-patching to N+1. §11.2's
 * "a patch either applies to every function in the set or to none" and "a
 * failed patch never leaves the target running partially-new code" are what
 * decide it: restoring the ORIGINAL at the published sites while the
 * untouched ones keep generation N would leave a mixture no build produced,
 * reported to the IDE as "the previous version" (`hcr/patchFailed`).
 * Restoring the original is not part of rollback at all.
 *
 * ROLLBACK IS NOT "FREE EVERYTHING". Bodies that were never published are
 * provider-private and are unmapped. Bodies that WERE published are retained,
 * because under tier 1 a thread may be executing inside one, and §4.5 and §6.1
 * both forbid freeing code a PC may be standing in. Islands come from a bump
 * allocator and are never reclaimed at all, for the same reason. That is also
 * what makes restoring generation N's jump sound: its body and island were
 * retained when N+1 superseded them. The claim on a window is released only
 * when the rollback leaves it UNPATCHED — a site this transaction published
 * first. A re-patched site is still patched at generation N, so it keeps the
 * claim it has held since its first publication (§4.5: retained across
 * generations).
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
  uint64_t original_word;   /* the window's pre-patch word (first publication) */
  uint64_t previous_word;   /* the window's pre-state at prepare time: the
                             * ROLLBACK TARGET (§11.2) — equal to
                             * `original_word` for a first publication,
                             * generation N's word for a re-patch          */
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
  /* 1 once rollback has moved a re-patched site's table entry back to
   * generation N. Rollback may run more than once on the same transaction
   * (after a failed commit, then again by a caller abandoning it), and the
   * generation must be decremented exactly once. */
  int site_reverted;
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
  /* A commit failed under tier 2, its published sites were restored with the
   * threads still parked, and the rest of the rollback (unregistration, claim
   * release, unmapping) is owed once the caller has released them (§11.2). */
  int cleanup_pending;
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
 * replacement page must fail to become executable. It is applied AS A STEP
 * RESULT — `-EACCES`, exactly what a kernel that refuses the transition
 * returns — so the code path taken is the production failure path and not a
 * shortcut around it. There is no other way to make that step fail on the k-th
 * site of a set on demand, and a commit-failure gate that cannot choose k
 * cannot show that N of M published sites were restored.
 */
/*
 * `repro_hcr_lx_restore_fault_site` is the lever HLX-M9 added to reach the
 * branch that set `text_left_writable` — a post-store `mprotect(PROT_READ|
 * PROT_EXEC)` that failed and left target text writable. That state no longer
 * exists: target text is never made writable (`repro_hcr_lx_replace_text_
 * word`). The lever is kept because a real agent reaches it from the
 * environment (`REPRO_HCR_TEST_FAIL_TEXT_RESTORE`), and it now makes the
 * replacement page's step to executable fail for that site, which must be a
 * clean refusal that leaves the target's text exactly as it was — the
 * property its gate now asserts against `/proc/self/maps`.
 */
static int repro_hcr_lx_fail_patch_page_alloc = 0;
static int repro_hcr_lx_commit_fault_site = -1;

/*
 * Design §6.2 "Deadlock hazards" and §11.2: the transaction prepare runs with
 * every thread RUNNING and ends by acquiring quiescence, because it claims the
 * window (§10.1) and allocates, and a thread parked holding the claim map's
 * lock or the allocator's would deadlock it. So prepare cannot ask "is
 * quiescence held?" for the SYNC_CORE substitution below; the caller that will
 * take quiescence once prepare returns says so here, and commit re-checks the
 * real thing before it writes a byte.
 */
static int repro_hcr_lx_quiesce_planned = 0;
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
    repro_hcr_mcr_release((uintptr_t)ps->window_address);
    txn->released_claim_count += 1;
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
    /* `previous_word` is generation N's word, and it is what a rollback of
     * this transaction restores (§11.2: the process goes back to the version
     * it was running, never to generation 0). `original_word` is carried for
     * the tier-2 boundary decode in publish, which needs the window's
     * pre-patch instruction bytes. */
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
     * change it. For a first publication it is also the pre-transaction word,
     * so it is the only thing rollback needs. */
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
   * `repro_hcr_mcr_claim` binds the recorder's claim map, or reaches it through
   * the recorder call when the recorder is in no link map; with no recorder in
   * the process there is no other patcher of this text and therefore no claim
   * to conflict with.
   *
   * The claim is taken only for a FRESH site. A re-patch is publishing into a
   * window this provider already owns; re-claiming would be refused by its own
   * live claim (§4.5).
   * ---------------------------------------------------------------------- */
  if (ps->fresh_site) {
    unsigned holder = 0;
    int claim_rc = repro_hcr_mcr_claim(
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
    /* A recorder that watches executable memory sees nothing of a write
     * through the alias; the body is reported while it is still unreachable. */
    repro_hcr_mcr_report_code(ps->patch_page, body_prefix + ps->patch_len);
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
  if (!caps->text_replacement_supported) {
    /* Design §5.2: neither backing of the §5.1 page replacement completed on
     * the agent-start probe. The agent already refused this host at
     * negotiation; this is the backstop for a caller that patches anyway. */
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
  if (!repro_hcr_lx_sync_core_available() && !repro_hcr_lx_quiesce_is_held() &&
      !repro_hcr_lx_quiesce_planned) {
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
 * W^X PUBLICATION ON LIVE TEXT: replace the page, never write it in place.
 *
 * The 8-byte window lives on a page the target is executing. Writing it in
 * place needs that page writable, and both ways of getting there are wrong:
 * `RW|EXEC` maps code writable and executable at once, which this provider
 * never does (and which an in-process recorder refuses, `MCR-Linux-
 * Instruction0.md` §3.4 E5); plain `RW` removes `PROT_EXEC` from the whole
 * page for the duration, which faults every thread whose PC is anywhere in
 * those 4 KiB — HLX-M4 measured exactly that.
 *
 * So the page is REPLACED:
 *
 *   1. a provider code page of the same length is taken (the HLX-M9 `memfd`
 *      dual mapping, or the anonymous fallback, by the same rule as patch
 *      bodies), and the live page's current bytes are copied into it through
 *      its writable view;
 *   2. the new word is written into the copy at the window's offset — an
 *      ordinary aligned 8-byte store into memory nothing executes yet;
 *   3. the copy is finalized: the writable alias dropped and the memfd
 *      sealed, or the anonymous page moved from `RW` to `RX`. Never both
 *      writable and executable;
 *   4. `mremap(MREMAP_FIXED)` moves the finished executable page over the
 *      live one. The kernel performs the unmap of the old page and the move of
 *      the new one under one hold of the address-space lock, so a thread
 *      fetching from that page sees either every old byte or every new byte —
 *      and the page is executable throughout, on both sides of the swap.
 *
 * The bytes outside the window are copied unchanged, so the only instruction
 * difference a thread can observe is the window's eight bytes, which is
 * exactly what the aligned in-place store used to guarantee; design §6.1
 * point 4 (a PC already INSIDE the window) is unchanged and is still what
 * tier-2 quiescence addresses. Nothing else in the process writes target
 * text concurrently: the provider serializes publications, and under tier 2
 * every other thread is parked.
 *
 * What changes about the page: it is a sealed memfd labelled
 * `/memfd:repro-hcr-text` (or, on the anonymous fallback, an anonymous page)
 * from now on, not a view of the ELF file. Everything the provider and the
 * unwinders it registers with read from the text — symbol and sled lookup
 * through `dl_iterate_phdr`, the bytes themselves — is unaffected;
 * `/proc/PID/maps` stops naming the file for that one page.
 *
 * `fail_exec_step` is the test lever: the copy is never made executable, so
 * the publication is refused and the live page is untouched. Returns 0, or the
 * negated errno of the step that failed; on failure the target is unchanged.
 */
#define REPRO_HCR_LX_NR_MREMAP 25
#define REPRO_HCR_LX_MREMAP_MAYMOVE 1
#define REPRO_HCR_LX_MREMAP_FIXED 2

/* Observations, for gates. Nothing in the provider branches on them. */
static uint64_t repro_hcr_lx_text_replace_count = 0;
static long repro_hcr_lx_last_text_replace_result = 0;
/* The step (numbered as in design §5.1) at which the last replacement stopped,
 * or 0 when it completed. */
#define REPRO_HCR_LX_REPLACE_STEP_COMPLETED 0
#define REPRO_HCR_LX_REPLACE_STEP_COPY_PAGE 2
#define REPRO_HCR_LX_REPLACE_STEP_FINALIZE 4
#define REPRO_HCR_LX_REPLACE_STEP_MOVE 5
static int repro_hcr_lx_last_text_replace_step = 0;

static long repro_hcr_lx_replace_text_word(uint64_t span_start,
                                           size_t span_length,
                                           uint64_t window_address,
                                           uint64_t word, int fail_exec_step) {
  void *exec_base;
  uint8_t *writer;
  long rc;
  int finalize_rc;

  exec_base = repro_hcr_lx_map_named_code_page(NULL, span_length, 0,
                                               REPRO_HCR_LX_TEXT_MEMFD_NAME);
  if (exec_base == NULL) {
    repro_hcr_lx_last_text_replace_step = REPRO_HCR_LX_REPLACE_STEP_COPY_PAGE;
    repro_hcr_lx_last_text_replace_result = -12; /* ENOMEM */
    return repro_hcr_lx_last_text_replace_result;
  }
  writer = repro_hcr_lx_code_writer(exec_base);
  memcpy(writer, (const void *)(uintptr_t)span_start, span_length);
  *(volatile uint64_t *)(uintptr_t)(writer + (window_address - span_start)) =
      word;
  if (fail_exec_step) {
    repro_hcr_lx_release_code_page(exec_base, span_length);
    repro_hcr_lx_last_text_replace_step = REPRO_HCR_LX_REPLACE_STEP_FINALIZE;
    repro_hcr_lx_last_text_replace_result = -REPRO_HCR_LX_EACCES;
    return repro_hcr_lx_last_text_replace_result;
  }
  finalize_rc = repro_hcr_lx_finalize_code_page(exec_base, span_length);
  if (finalize_rc != 0) {
    /* Under `PR_MDWE_REFUSE_EXEC_GAIN` the anonymous fallback cannot become
     * executable. The live page was never touched. `finalize_rc` is the
     * kernel's negated errno (MDWE answers `-EACCES`). */
    repro_hcr_lx_release_code_page(exec_base, span_length);
    repro_hcr_lx_last_text_replace_step = REPRO_HCR_LX_REPLACE_STEP_FINALIZE;
    repro_hcr_lx_last_text_replace_result = (long)finalize_rc;
    return repro_hcr_lx_last_text_replace_result;
  }
  rc = repro_hcr_lx_syscall6(
      REPRO_HCR_LX_NR_MREMAP, (long)(uintptr_t)exec_base, (long)span_length,
      (long)span_length,
      REPRO_HCR_LX_MREMAP_MAYMOVE | REPRO_HCR_LX_MREMAP_FIXED,
      (long)span_start, 0);
  if (rc < 0) {
    /* Finalization already released the page's bookkeeping, so this is a
     * plain unmap of a page nothing references. */
    (void)repro_hcr_lx_raw_munmap((uint64_t)(uintptr_t)exec_base, span_length);
    repro_hcr_lx_last_text_replace_step = REPRO_HCR_LX_REPLACE_STEP_MOVE;
    repro_hcr_lx_last_text_replace_result = rc;
    return rc;
  }
  repro_hcr_lx_text_replace_count += 1;
  repro_hcr_lx_last_text_replace_step = REPRO_HCR_LX_REPLACE_STEP_COMPLETED;
  repro_hcr_lx_last_text_replace_result = 0;
  return 0;
}

/*
 * The agent-start probe of the publication (design §5.2), one backing at a
 * time. Runs `repro_hcr_lx_replace_text_word` — the production replacement,
 * not a model of it — over a scratch `PROT_READ|PROT_EXEC` page the provider
 * owns, then CALLS the replaced page. The page is reported complete only when
 * it answers the value the replacement wrote: a copy that was moved into
 * place but never became executable, or a move that did not land, cannot be
 * reported as success.
 *
 * The scratch page starts executable and is never made writable, so it has
 * the shape of target text, and a policy that refuses something about the
 * replacement refuses it here first, at agent start.
 */
static long repro_hcr_lx_probe_replacement_with(int force_anonymous,
                                                int *stopped_at_step) {
  /* `mov eax, 0x5eed; ret; nop; nop`: the window word the replacement
   * writes. A value no fixture in this tree uses. */
  static const uint8_t word_bytes[8] = {0xB8, 0xED, 0x5E, 0x00,
                                        0x00, 0xC3, 0x90, 0x90};
  size_t page_size = repro_hcr_lx_page_size();
  int previous_lever = repro_hcr_lx_force_anonymous_code_pages;
  uint64_t word;
  void *scratch;
  long rc;
  int answered;

  scratch = repro_hcr_lx_map_anonymous(
      NULL, page_size, REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_EXEC, 0);
  if (scratch == NULL) {
    return REPRO_HCR_LX_REPLACEMENT_SCRATCH_UNAVAILABLE;
  }
  memcpy(&word, word_bytes, sizeof(word));
  repro_hcr_lx_force_anonymous_code_pages = force_anonymous;
  rc = repro_hcr_lx_replace_text_word((uint64_t)(uintptr_t)scratch, page_size,
                                      (uint64_t)(uintptr_t)scratch, word, 0);
  repro_hcr_lx_force_anonymous_code_pages = previous_lever;
  *stopped_at_step = rc != 0 ? repro_hcr_lx_last_text_replace_step
                             : REPRO_HCR_LX_REPLACE_STEP_COMPLETED;
  if (rc != 0) {
    /* A refused replacement leaves the scratch page as it was. */
    (void)repro_hcr_lx_unmap(scratch, page_size);
    return rc;
  }
  /* New instructions on an executable page: a recorder watching this process
   * is told before they run, as for every other code the provider makes. */
  repro_hcr_mcr_report_code(scratch, sizeof(word));
  answered = ((int (*)(void))scratch)();
  (void)repro_hcr_lx_unmap(scratch, page_size);
  return answered == 0x5eed ? REPRO_HCR_LX_REPLACEMENT_COMPLETED
                            : REPRO_HCR_LX_REPLACEMENT_WRONG_ANSWER;
}

static void repro_hcr_lx_probe_text_replacement(void) {
  repro_hcr_lx_capabilities *caps = &repro_hcr_lx_caps;
  /* The probe is not a publication. Every observation a gate reads about
   * publications and code pages is put back afterwards, so a gate that counts
   * replacements or pages counts the target's and not the probe's. */
  uint64_t saved_replace_count = repro_hcr_lx_text_replace_count;
  long saved_replace_result = repro_hcr_lx_last_text_replace_result;
  int saved_replace_step = repro_hcr_lx_last_text_replace_step;
  uint64_t saved_dual = repro_hcr_lx_dual_page_count;
  uint64_t saved_sealed = repro_hcr_lx_dual_seal_count;
  uint64_t saved_fallback = repro_hcr_lx_fallback_page_count;
  long saved_seal_result = repro_hcr_lx_last_seal_result;
  int saved_seal_verified = repro_hcr_lx_last_seal_verified;
  uint64_t saved_mprotect_count = repro_hcr_lx_mprotect_issued_count;

  caps->text_replacement_supported = 0;
  caps->text_replacement_backing = REPRO_HCR_LX_BACKING_NONE;
  caps->text_replacement_anonymous_result =
      REPRO_HCR_LX_REPLACEMENT_NOT_ATTEMPTED;
  caps->text_replacement_memfd_step = 0;
  caps->text_replacement_anonymous_step = 0;

  /* 1. The `memfd` backing. */
  if (repro_hcr_lx_force_anonymous_code_pages) {
    caps->text_replacement_memfd_result =
        REPRO_HCR_LX_REPLACEMENT_BACKING_DISABLED;
  } else if (!repro_hcr_lx_memfd_dual_supported(repro_hcr_lx_page_size())) {
    caps->text_replacement_memfd_result =
        REPRO_HCR_LX_REPLACEMENT_BACKING_UNAVAILABLE;
  } else {
    caps->text_replacement_memfd_result =
        repro_hcr_lx_probe_replacement_with(
            0, &caps->text_replacement_memfd_step);
    if (caps->text_replacement_memfd_result != 0) {
      /* The dual mapping can be built but the replacement through it does
       * not complete. Production must not then choose it for target text
       * (`repro_hcr_lx_map_named_code_page` picks the backing by this flag),
       * so the anonymous fallback becomes the backing for every page. */
      repro_hcr_lx_memfd_dual_available = 0;
    }
  }
  if (caps->text_replacement_memfd_result == 0) {
    caps->text_replacement_supported = 1;
    caps->text_replacement_backing = REPRO_HCR_LX_BACKING_MEMFD;
  } else {
    /* 2. The anonymous fallback. */
    caps->text_replacement_anonymous_result =
        repro_hcr_lx_probe_replacement_with(
            1, &caps->text_replacement_anonymous_step);
    if (caps->text_replacement_anonymous_result == 0) {
      caps->text_replacement_supported = 1;
      caps->text_replacement_backing = REPRO_HCR_LX_BACKING_ANONYMOUS;
    }
  }

  repro_hcr_lx_text_replace_count = saved_replace_count;
  repro_hcr_lx_last_text_replace_result = saved_replace_result;
  repro_hcr_lx_last_text_replace_step = saved_replace_step;
  repro_hcr_lx_dual_page_count = saved_dual;
  repro_hcr_lx_dual_seal_count = saved_sealed;
  repro_hcr_lx_fallback_page_count = saved_fallback;
  repro_hcr_lx_last_seal_result = saved_seal_result;
  repro_hcr_lx_last_seal_verified = saved_seal_verified;
  /* The anonymous attempt's `mprotect` was of the provider's own copy, never
   * of target text; the log of mprotects a gate reads is about the latter. */
  repro_hcr_lx_mprotect_issued_count = saved_mprotect_count;
}


/*
 * Publish one prepared site: the page replacement that carries the new window
 * word, the tier-2 IP adjustment and the `SYNC_CORE` event.
 *
 * `fault_now` and `restore_fault_now` are the test levers' decisions for THIS
 * site, evaluated by the caller. Both make the replacement page's step to
 * executable fail, so the branch taken below is the production failure branch
 * and nothing in the target changes.
 */
static int repro_hcr_lx_txn_publish_site(repro_hcr_lx_transaction *txn,
                                         repro_hcr_lx_prepared_site *ps,
                                         int fault_now,
                                         int restore_fault_now) {
  long protect_rc;

  protect_rc = repro_hcr_lx_replace_text_word(
      ps->span_start, (size_t)(ps->span_end - ps->span_start),
      ps->window_address, ps->published_word,
      fault_now || restore_fault_now);
  if (protect_rc != 0) {
    ps->refusal = REPRO_HCR_LX_REFUSED_TEXT_PROTECTION_FAILED;
    repro_hcr_lx_last_report.refusal = ps->refusal;
    return ps->refusal;
  }
  repro_hcr_lx_last_report.text_replaced = 1;

  /*
   * PUBLICATION.
   *
   * Safety argument, stated here rather than left implicit as it is on macOS.
   * It has two halves and both are required (design §4.2, §4.4), and a third
   * point neither half covers:
   *
   *   1. The new word reaches the live page by REPLACING the page (see
   *      `repro_hcr_lx_replace_text_word`, above), and the swap is atomic
   *      with respect to instruction fetch: any thread reads either the whole
   *      previous word (all NOPs, or the previous generation's jump) or the
   *      whole new `E9 rel32 90 90 90`. There is no third byte-level state,
   *      and in particular no partially written jump through an address
   *      composed of NOP bytes. HLX-M3 adds the consequence this milestone
   *      needs: because the swap is atomic and the word it replaced was SAVED,
   *      the publication is individually REVERSIBLE — one more replacement
   *      undoes it exactly.
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
 * Restore one published site to the word that was published in its window
 * BEFORE this transaction (`previous_word`, §11.2): unpatched code for a site
 * this transaction published first, generation N's jump for a site it was
 * re-patching. Generation N's body and island are retained (never freed), so
 * that jump lands on live code.
 *
 * One aligned 8-byte store, same rule as publication. Never widened.
 */
static int repro_hcr_lx_txn_restore_site(repro_hcr_lx_transaction *txn,
                                         repro_hcr_lx_prepared_site *ps) {
  uint64_t word;
#if defined(REPRO_HCR_HLX_M3_FALSIFY_ROLLBACK_TO_ORIGINAL_WORD)
  /*
   * FALSIFIER ARM (HLX-M3). Restores the site's ORIGINAL word instead of the
   * word published before the transaction, and changes nothing else — the
   * site-table bookkeeping below still believes generation N is live. This is
   * the behaviour recorded in `reprobuild-pm/issues/2026-11-12-transaction-
   * rollback-restores-generation-0-silently-reverting-earlier-committed-
   * patches.md`: a failed reload N+1 drops patch N at every site it had
   * published.
   *
   * For a first-generation site the two words are equal, so this arm is
   * INVISIBLE until a function has been patched at least twice — which is why
   * the re-patch gates carry it. Under this arm the "rollback of generation 3
   * restores generation 2" assertion of
   * `integration_hcr_linux_repeated_patch_of_same_function` and the N = 2 arm
   * of `integration_hcr_linux_commit_failure_after_repatch_keeps_previous_
   * generation` MUST go red. The agent never defines it.
   */
  word = ps->original_word;
#else
  word = ps->previous_word;
#endif
  /* The same page replacement as publication, carrying the saved word. */
  if (repro_hcr_lx_replace_text_word(
          ps->span_start, (size_t)(ps->span_end - ps->span_start),
          ps->window_address, word, 0) != 0) {
    /* Nothing else can be done for this site: the window keeps the published
     * word. It is recorded rather than swallowed — a rollback that reports
     * success for a site it could not restore is the failure mode this whole
     * milestone exists to remove. */
    return REPRO_HCR_LX_REFUSED_TEXT_PROTECTION_FAILED;
  }
  __atomic_signal_fence(__ATOMIC_SEQ_CST);
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
 * Order: published sites are restored in REVERSE publication order, each to
 * the word published before this transaction, then registrations are undone,
 * then the claims of sites the rollback leaves UNPATCHED are released, then
 * unpublished bodies are unmapped. A re-patched site stays live at generation
 * N with its claim held. Published bodies and every island are RETAINED — see
 * the header comment.
 */
/*
 * The half of a rollback that touches target text: re-publish the saved word
 * of every published site, in reverse. Raw system calls only (§5.1), so under
 * tier 2 it is the one rollback step that runs with the threads parked.
 */
static int repro_hcr_lx_txn_restore_published(repro_hcr_lx_transaction *txn) {
  int i;
  int rc = REPRO_HCR_LX_OK;
  for (i = txn->site_count - 1; i >= 0; --i) {
    repro_hcr_lx_prepared_site *ps = &txn->sites[i];
    /* A site an earlier rollback of this transaction already restored holds
     * its pre-transaction word; storing it again would only re-count it. A
     * site whose earlier restore FAILED is retried. */
    if (!ps->published || ps->restored) {
      continue;
    }
    if (repro_hcr_lx_txn_restore_site(txn, ps) != REPRO_HCR_LX_OK) {
      rc = REPRO_HCR_LX_REFUSED_TEXT_PROTECTION_FAILED;
    }
  }
  return rc;
}

/*
 * The other half: unregister JIT symfiles and `.eh_frame` sections (the
 * unwinder's global lock), release claims (the claim map, which may take a
 * recorder lock), and unmap unpublished bodies. Design §11.2 runs this only
 * after the threads are released (§6.2 step 7): a thread parked holding any of
 * those locks would deadlock it. It never writes target text, so a site whose
 * restore failed keeps its published word, its slot and its claim.
 */
static void repro_hcr_lx_txn_release_rolled_back(
    repro_hcr_lx_transaction *txn) {
  int i;
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
    if (ps->published && ps->restored && ps->fresh_site) {
      /* This transaction published the site FIRST, so the window is back to
       * its original bytes and the site is unpatched again: retire the slot
       * and release the claim this transaction took. The patch page is NOT
       * unmapped — a thread may have entered it before the restore landed,
       * and under tier 1 there is no way to prove otherwise. */
      if (ps->site != NULL) {
        ps->site->used = 0;
        ps->site = NULL;
      }
      if (ps->claimed_here) {
        repro_hcr_mcr_release((uintptr_t)ps->window_address);
        txn->released_claim_count += 1;
      }
      ps->claimed_here = 0;
      ps->patch_page = NULL;   /* retained, deliberately leaked (§4.5/§6.1) */
    } else if (ps->published && ps->restored) {
      /*
       * A RE-PATCH rolled back: the window holds generation N's word again,
       * so the site is still patched, at generation N. Undo exactly what
       * `repro_hcr_lx_txn_publish_site` did to the site table and nothing
       * more:
       *
       *   - `published_word` goes back to generation N's word, so the next
       *     re-patch finds the admissible pre-state "the word this provider
       *     published" rather than refusing `entry-modified-externally`;
       *   - `generation` goes back to N;
       *   - the slot stays `used` and the claim stays HELD. It was taken at
       *     the site's first publication and is retained across generations
       *     (§4.5); this transaction did not take it (`claimed_here` is 0)
       *     and a site that is still patched must not give it up.
       *
       * `retained_body_count` is deliberately NOT decremented. The rolled-back
       * generation-N+1 body stays mapped for the same reason every superseded
       * body does — a PC may be standing in it — so it is still a retained
       * region, and `retained_region_count`/`oldCodeRetained` (which are
       * computed from this count) must keep counting it. The count is "bodies
       * this site holds", not "generations live".
       */
      if (ps->site != NULL && !ps->site_reverted) {
        ps->site->published_word = ps->previous_word;
        if (ps->site->generation > 0) {
          ps->site->generation -= 1;
        }
        ps->site_reverted = 1;
      }
      ps->patch_page = NULL;   /* retained, deliberately leaked (§4.5/§6.1) */
    } else if (ps->published) {
      /*
       * The restore itself FAILED (`repro_hcr_lx_txn_restore_site` reported
       * it, and the rollback returns the failure). The window still holds
       * this transaction's word, so the site table keeps describing exactly
       * that — live, at the generation the commit recorded, claim held.
       * Retiring the slot or releasing the claim here would let another
       * patcher take bytes this provider's jump still occupies, and would
       * make the next reload of this function plan over a live jump.
       */
      ps->patch_page = NULL;   /* retained, deliberately leaked (§4.5/§6.1) */
    } else if (ps->prepared) {
      repro_hcr_lx_txn_discard_prepared(txn, ps);
    }
    /* The report names one window (the last site prepared or published) and
     * the commit wrote that window's generation and claim into it. Make it
     * describe the state the rollback LEFT, so a reader of the report and a
     * reader of the site table agree: generation N and the claim still held
     * for a re-patch, generation 0 and no claim for a retired site. */
    if (ps->published &&
        ps->window_address == repro_hcr_lx_last_report.window_address) {
      repro_hcr_lx_last_report.generation =
          ps->site != NULL ? ps->site->generation : 0;
      repro_hcr_lx_last_report.claim_held =
          ps->site != NULL ? ps->site->claimed : 0;
    }
  }
  txn->rolled_back = 1;
  txn->cleanup_pending = 0;
  repro_hcr_lx_last_report.rolled_back = 1;
  repro_hcr_lx_last_report.restored_sites = txn->restored_count;
}

static int repro_hcr_lx_txn_rollback(repro_hcr_lx_transaction *txn) {
  int rc;
  if (txn == NULL) {
    return REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
  }
  rc = repro_hcr_lx_txn_restore_published(txn);
  repro_hcr_lx_txn_release_rolled_back(txn);
  return rc;
}

/*
 * Commit: a sequence of single atomic stores, each individually reversible
 * from its saved word. A failure at site k restores sites 0..k-1 in reverse
 * and leaves the target running the code it was running before.
 */
/*
 * `defer_cleanup` is set by a caller that holds tier-2 quiescence. On a
 * failure the commit then restores the published sites and stops: the caller
 * releases the threads and calls `repro_hcr_lx_txn_rollback`, which skips the
 * sites already restored and does the rest (§11.2). With `defer_cleanup` 0 the
 * whole rollback runs here, as it always has for tier 1 and for the gates.
 */
static int repro_hcr_lx_txn_commit_ex(repro_hcr_lx_transaction *txn,
                                      int defer_cleanup) {
  int i;
  if (txn == NULL || !txn->prepare_complete) {
    return REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
  }
  /* Prepare accepted a missing SYNC_CORE on the promise of quiescence
   * (`repro_hcr_lx_quiesce_planned`). Hold the caller to it before the first
   * write; nothing is published yet, so this refusal changes no text. */
  if (!repro_hcr_lx_sync_core_available() && !repro_hcr_lx_quiesce_is_held()) {
    txn->refusal = REPRO_HCR_LX_REFUSED_SYNC_CORE_UNAVAILABLE;
    txn->failed_site = 0;
    txn->cleanup_pending = defer_cleanup;
    if (!defer_cleanup) {
      (void)repro_hcr_lx_txn_rollback(txn);
    }
    repro_hcr_lx_last_report.refusal = txn->refusal;
    repro_hcr_lx_last_report.commit_complete = 0;
    return txn->refusal;
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
      if (defer_cleanup) {
        (void)repro_hcr_lx_txn_restore_published(txn);
        txn->cleanup_pending = 1;
      } else {
        (void)repro_hcr_lx_txn_rollback(txn);
      }
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

REPRO_HCR_LX_MAYBE_UNUSED static int repro_hcr_lx_txn_commit(repro_hcr_lx_transaction *txn) {
  return repro_hcr_lx_txn_commit_ex(txn, 0);
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
static void *repro_hcr_lx_commit_direct_patch_ex(int defer_cleanup) {
  repro_hcr_lx_transaction *txn = &repro_hcr_lx_last_txn;
  if (repro_hcr_lx_txn_commit_ex(txn, defer_cleanup) != REPRO_HCR_LX_OK) {
    return NULL;
  }
  return (void *)(uintptr_t)txn->sites[0].dispatch_address;
}

static void *repro_hcr_lx_commit_direct_patch(void) {
  return repro_hcr_lx_commit_direct_patch_ex(0);
}

/*
 * The tier-2 caller's half of §11.2, called AFTER `repro_hcr_lx_quiesce_
 * release`: finish a rollback whose text half `repro_hcr_lx_commit_direct_
 * patch_ex(1)` already did, or discard a transaction that prepared and then
 * could not acquire quiescence. A no-op when nothing is owed — in particular
 * after a successful commit, and under the HLX-M3 no-rollback falsifier, whose
 * commit returns before it marks anything pending.
 */
REPRO_HCR_LX_MAYBE_UNUSED static void repro_hcr_lx_finish_direct_patch_cleanup(void) {
  repro_hcr_lx_transaction *txn = &repro_hcr_lx_last_txn;
  if (txn->cleanup_pending) {
    repro_hcr_lx_txn_release_rolled_back(txn);
  }
}

REPRO_HCR_LX_MAYBE_UNUSED static void repro_hcr_lx_discard_direct_patch(void) {
  repro_hcr_lx_transaction *txn = &repro_hcr_lx_last_txn;
  if (txn->prepare_complete && !txn->commit_complete && !txn->rolled_back) {
    (void)repro_hcr_lx_txn_rollback(txn);
  }
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
