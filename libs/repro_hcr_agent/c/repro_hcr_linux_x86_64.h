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
  REPRO_HCR_LX_REFUSED_QUIESCENCE_FAILED = 16
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
 * `__patchable_function_entries` lookup.
 *
 * Measured (GCC 15.2 and Clang 21.1.8, x86_64): the section is emitted
 * `SHF_ALLOC|SHF_WRITE|SHF_LINK_ORDER` ("WAL"), so it is mapped at runtime and
 * relocated by the dynamic loader; each 8-byte entry then holds the runtime
 * address of the FIRST NOP — i.e. already past `endbr64`. The linker
 * synthesises `__start_`/`__stop_` symbols because the section name is a valid
 * C identifier, which is how the agent reaches it without parsing section
 * headers. Both symbols are weak so a target built without
 * `-fpatchable-function-entry` links and refuses cleanly instead of failing to
 * link.
 *
 * HLX-M1 replaces this with the full ELF pipeline (multiple objects, shared
 * libraries, `dl_iterate_phdr`). HLX-M0 covers the main executable's own
 * section only.
 * ------------------------------------------------------------------------- */

extern const uintptr_t __start___patchable_function_entries[]
    __attribute__((weak));
extern const uintptr_t __stop___patchable_function_entries[]
    __attribute__((weak));

#define REPRO_HCR_LX_MAX_LANDING_PAD_BYTES 8u

static uint64_t repro_hcr_lx_sled_address_for_entry(uint64_t entry_address) {
  const uintptr_t *start = __start___patchable_function_entries;
  const uintptr_t *stop = __stop___patchable_function_entries;
  uint64_t best = 0;
  size_t count;
  size_t i;

  if (start == NULL || stop == NULL || stop <= start) {
    return 0;
  }
  count = (size_t)(stop - start);
  for (i = 0; i < count; ++i) {
    uint64_t value = (uint64_t)start[i];
    if (value < entry_address) {
      continue;
    }
    if (value - entry_address > REPRO_HCR_LX_MAX_LANDING_PAD_BYTES) {
      continue;
    }
    if (best == 0 || value < best) {
      best = value;
    }
  }
  return best;
}

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
} repro_hcr_lx_capabilities;

static repro_hcr_lx_capabilities repro_hcr_lx_caps;

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
    return;
  }
  repro_hcr_lx_caps.probed = 1;

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
static void *repro_hcr_lx_map_patch_page_near(uint64_t window_address,
                                              size_t page_size) {
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
      mapped = repro_hcr_lx_map_anonymous(
          (void *)(uintptr_t)hint_signed, page_size,
          REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE,
          REPRO_HCR_LX_MAP_FIXED_NOREPLACE);
      if (mapped == NULL) {
        continue;
      }
      if ((uint64_t)(uintptr_t)mapped == (uint64_t)hint_signed &&
          repro_hcr_lx_rel32_reachable(window_address,
                                       (uint64_t)(uintptr_t)mapped)) {
        return mapped;
      }
      repro_hcr_lx_unmap(mapped, page_size);
    }
    distance = distance < 64 ? distance + 1 : distance * 2;
  }

  fallback = repro_hcr_lx_map_anonymous(
      NULL, page_size, REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE, 0);
  if (fallback == NULL) {
    return NULL;
  }
  if (repro_hcr_lx_rel32_reachable(window_address,
                                   (uint64_t)(uintptr_t)fallback)) {
    return fallback;
  }
  repro_hcr_lx_unmap(fallback, page_size);
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
} repro_hcr_lx_patch_report;

static repro_hcr_lx_patch_report repro_hcr_lx_last_report;

static const uint8_t repro_hcr_lx_endbr64[4] = {0xf3, 0x0f, 0x1e, 0xfa};

/*
 * Apply a direct entry patch at `entry_address`, publishing inside the sled
 * that starts at `sled_address`.
 *
 * `sled_address` is a parameter rather than a lookup so that HLX-M1's real
 * symbol/ELF pipeline can supply it, and so the HLX-M0 gates can drive the
 * exact production code path against a sled they constructed from real
 * compiler output. `repro_hcr_apply_direct_patch` in the agent supplies it from
 * the runtime-mapped `__patchable_function_entries` section.
 *
 * Returns the live patch-body address, or NULL with `repro_hcr_lx_last_report`
 * carrying a named refusal.
 */
static void *repro_hcr_lx_apply_direct_patch_at(uint64_t entry_address,
                                                uint64_t sled_address,
                                                const uint8_t *patch_bytes,
                                                size_t patch_len) {
  const repro_hcr_lx_capabilities *caps;
  size_t page_size;
  repro_hcr_lx_sled_plan plan;
  repro_hcr_lx_site *site;
  int fresh_site = 0;
  uint64_t original_word = 0;
  uint64_t window_address;
  uint8_t *patch_page;
  size_t body_prefix = 0;
  size_t body_len;
  uint64_t dispatch_address;
  uint8_t jmp_bytes[REPRO_HCR_LX_JMP_REL32_BYTES];
  uint64_t published_word;
  uint64_t span_start;
  uint64_t span_end;
  int encode_rc;
  int claimed_here;
  int transient_protection;

  memset(&repro_hcr_lx_last_report, 0, sizeof(repro_hcr_lx_last_report));

  if (entry_address == 0 || patch_bytes == NULL || patch_len == 0) {
    repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
    return NULL;
  }

  caps = repro_hcr_lx_capability_report();
  if (!caps->text_protection_roundtrip) {
    /* Design §5.2: MDWE lets the RW step succeed and fails only the PROT_EXEC
     * restore, which would leave the target's text permanently non-executable.
     * The provider probed this at agent start and refuses here rather than
     * discovering it after the point of no return. */
    repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_REFUSED_UNSUPPORTED_HOST;
    return NULL;
  }

  /*
   * HLX-OQ-3, resolved in HLX-M4: **always quiesce; refuse if we cannot.**
   *
   * The two candidates the design left open were (a) refuse to patch without
   * quiescence and (b) always quiesce, "where the signal delivery is itself a
   * context-synchronizing event on every thread". (b) is adopted, with (a) as
   * its floor, and the two compose into one rule checked here:
   *
   *   publish only if SYNC_CORE is available, OR quiescence is held.
   *
   * Why quiescence substitutes. Every thread that could be executing this text
   * has entered the kernel to take the `SIGRTMIN+n` and will return through
   * `IRET` (x86_64) or `ERET` (aarch64), both of which are architecturally
   * context-synchronizing — so the pipeline half of §4.4 is discharged by the
   * handshake itself, for exactly the set of threads that matters. A thread
   * created after the handshake cannot have prefetched the old bytes.
   *
   * Why the floor is a refusal and not "publish anyway". Before this milestone
   * the code recorded `membarrier_result = -1` and stored regardless, which is
   * the case Intel SDM §8.1.3/§9.3 leaves undefined, reported as success. The
   * refusal is named and reaches the coordinator; it is never a silent no-op.
   *
   * Checked HERE, before the claim and before any mapping, so the refusal costs
   * nothing and cannot leave state behind.
   */
  if (!repro_hcr_lx_sync_core_available() && !repro_hcr_lx_quiesce_is_held()) {
    repro_hcr_lx_last_report.refusal =
        REPRO_HCR_LX_REFUSED_SYNC_CORE_UNAVAILABLE;
    return NULL;
  }

  page_size = repro_hcr_lx_page_size();

  site = repro_hcr_lx_find_site(entry_address);
  if (site != NULL) {
    /* Re-patch (design §4.5): the admissible pre-state is the word this
     * provider itself published, not an all-NOP window. Without this branch the
     * provider would refuse every reload after the first and would work exactly
     * once. */
    uint64_t current_word;
    window_address = site->window_address;
    memcpy(&current_word, (const void *)(uintptr_t)window_address,
           sizeof(current_word));
    if (current_word != site->published_word) {
      repro_hcr_lx_last_report.refusal =
          REPRO_HCR_LX_REFUSED_ENTRY_MODIFIED_EXTERNALLY;
      repro_hcr_lx_last_report.window_address = window_address;
      return NULL;
    }
    memset(&plan, 0, sizeof(plan));
    plan.sled_address = site->sled_address;
    plan.sled_end = site->sled_end;
    plan.sled_length = (uint32_t)(site->sled_end - site->sled_address);
    plan.window_address = window_address;
    plan.window_offset = (uint32_t)(window_address - site->sled_address);
    plan.refusal = REPRO_HCR_LX_OK;
    original_word = site->original_word;
  } else {
    if (sled_address == 0) {
      repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_REFUSED_ABSENT_SLED;
      return NULL;
    }
    if (repro_hcr_lx_plan_sled((const uint8_t *)(uintptr_t)sled_address,
                               REPRO_HCR_LX_MAX_SLED_SCAN, sled_address,
                               &plan) != REPRO_HCR_LX_OK) {
      repro_hcr_lx_last_report.refusal = plan.refusal;
      repro_hcr_lx_last_report.sled_address = plan.sled_address;
      repro_hcr_lx_last_report.sled_end = plan.sled_end;
      repro_hcr_lx_last_report.sled_length = plan.sled_length;
      return NULL;
    }
    window_address = plan.window_address;
    memcpy(&original_word, (const void *)(uintptr_t)window_address,
           sizeof(original_word));
    fresh_site = 1;
  }
  repro_hcr_lx_last_report.sled_address = plan.sled_address;
  repro_hcr_lx_last_report.sled_end = plan.sled_end;
  repro_hcr_lx_last_report.sled_length = plan.sled_length;
  repro_hcr_lx_last_report.window_address = window_address;
  repro_hcr_lx_last_report.window_offset = plan.window_offset;
  repro_hcr_lx_last_report.original_word = original_word;

  /* -------------------------------------------------------------------------
   * ARBITRATION (design §10.1). Claim the published window BEFORE anything
   * that could write to it.
   *
   * MCR's patchers claim through the same map, so a `-2` here means the
   * recorder already owns bytes this provider was about to store into — the
   * one situation in which publishing anyway reproduces task #422 in reverse.
   * The refusal is NAMED (`claimed-by-recorder`) and carries the holder out, so
   * the agent reports it as a skipped function rather than a mystery.
   *
   * `ct_claimed_guest_text_claim` is weak: when `libct_interpose` is not in the
   * process it is NULL, which means there is no other patcher of this text and
   * therefore no claim to conflict with. That is not the "silent skip" the
   * map's rule forbids — the rule is about refusing to write over bytes ANOTHER
   * PATCHER holds, and with no other patcher present there are none.
   *
   * The claim is taken only for a FRESH site. A re-patch is publishing into a
   * window this provider already owns; re-claiming would be refused by its own
   * live claim (§4.5).
   * ---------------------------------------------------------------------- */
  claimed_here = 0;
  if (fresh_site && ct_claimed_guest_text_claim != NULL) {
    unsigned holder = 0;
    int claim_rc = ct_claimed_guest_text_claim(
        (uintptr_t)window_address, (size_t)REPRO_HCR_LX_WINDOW_BYTES,
        REPRO_HCR_CGT_OWNER_REPRO_HCR, &holder);
    if (claim_rc == -2) {
      repro_hcr_lx_last_report.claim_holder = holder;
      repro_hcr_lx_last_report.refusal =
          REPRO_HCR_LX_REFUSED_CLAIMED_BY_RECORDER;
      return NULL;
    }
    if (claim_rc != 0) {
      /* -1 is a degenerate range, which cannot happen for an 8-byte window at
       * a non-wrapping address; treat it as an argument error rather than
       * proceeding unclaimed. */
      repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
      return NULL;
    }
    claimed_here = 1;
    repro_hcr_lx_last_report.claim_held = 1;
  } else if (!fresh_site) {
    repro_hcr_lx_last_report.claim_held = site->claimed;
  }

  /* The patch body is provider-owned memory no other thread can reach until the
   * publishing store makes it reachable. */
  if (patch_len < sizeof(repro_hcr_lx_endbr64) ||
      memcmp(patch_bytes, repro_hcr_lx_endbr64,
             sizeof(repro_hcr_lx_endbr64)) != 0) {
    body_prefix = sizeof(repro_hcr_lx_endbr64);
  }
  body_len = body_prefix + patch_len;
  if (body_len > page_size) {
  /* HLX-M7 §10.1: HCR releases its claim on rollback. Everything from here to
   * the publishing store is reversible without touching target text, so a
   * failure must leave the window as unclaimed as it found it — otherwise the
   * next patcher (or the next reload) is refused bytes nobody is using. */
  if (claimed_here && ct_claimed_guest_text_release != NULL) {
    ct_claimed_guest_text_release((uintptr_t)window_address);
    claimed_here = 0;
    repro_hcr_lx_last_report.claim_held = 0;
  }
    repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
    return NULL;
  }

  patch_page =
      (uint8_t *)repro_hcr_lx_map_patch_page_near(window_address, page_size);
  if (patch_page == NULL) {
  /* HLX-M7 §10.1: HCR releases its claim on rollback. Everything from here to
   * the publishing store is reversible without touching target text, so a
   * failure must leave the window as unclaimed as it found it — otherwise the
   * next patcher (or the next reload) is refused bytes nobody is using. */
  if (claimed_here && ct_claimed_guest_text_release != NULL) {
    ct_claimed_guest_text_release((uintptr_t)window_address);
    claimed_here = 0;
    repro_hcr_lx_last_report.claim_held = 0;
  }
    repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_REFUSED_NO_PATCH_MEMORY;
    return NULL;
  }
  /* Design §4.2: an island-reachable body is entered through `jmp [rip+disp32]`
   * and so must begin with `endbr64` on an IBT-enforcing process. HLX-M0 has no
   * islands yet, but emitting the landing pad unconditionally costs four bytes
   * and makes every body HLX-M2-ready. */
  if (body_prefix != 0) {
    memcpy(patch_page, repro_hcr_lx_endbr64, sizeof(repro_hcr_lx_endbr64));
  }
  memcpy(patch_page + body_prefix, patch_bytes, patch_len);
  if (repro_hcr_lx_raw_mprotect((uint64_t)(uintptr_t)patch_page, page_size,
                                REPRO_HCR_LX_PROT_READ |
                                    REPRO_HCR_LX_PROT_EXEC) != 0) {
    repro_hcr_lx_unmap(patch_page, page_size);
  /* HLX-M7 §10.1: HCR releases its claim on rollback. Everything from here to
   * the publishing store is reversible without touching target text, so a
   * failure must leave the window as unclaimed as it found it — otherwise the
   * next patcher (or the next reload) is refused bytes nobody is using. */
  if (claimed_here && ct_claimed_guest_text_release != NULL) {
    ct_claimed_guest_text_release((uintptr_t)window_address);
    claimed_here = 0;
    repro_hcr_lx_last_report.claim_held = 0;
  }
    repro_hcr_lx_last_report.refusal =
        REPRO_HCR_LX_REFUSED_PATCH_MEMORY_PROTECTION_FAILED;
    return NULL;
  }
  dispatch_address = (uint64_t)(uintptr_t)patch_page;

  encode_rc =
      repro_hcr_lx_encode_jmp_rel32(window_address, dispatch_address, jmp_bytes);
  if (encode_rc != REPRO_HCR_LX_OK) {
    repro_hcr_lx_unmap(patch_page, page_size);
  /* HLX-M7 §10.1: HCR releases its claim on rollback. Everything from here to
   * the publishing store is reversible without touching target text, so a
   * failure must leave the window as unclaimed as it found it — otherwise the
   * next patcher (or the next reload) is refused bytes nobody is using. */
  if (claimed_here && ct_claimed_guest_text_release != NULL) {
    ct_claimed_guest_text_release((uintptr_t)window_address);
    claimed_here = 0;
    repro_hcr_lx_last_report.claim_held = 0;
  }
    repro_hcr_lx_last_report.refusal = encode_rc;
    return NULL;
  }
  published_word = repro_hcr_lx_published_word(jmp_bytes);

  if (fresh_site) {
    site = repro_hcr_lx_claim_site(entry_address);
    if (site == NULL) {
      repro_hcr_lx_unmap(patch_page, page_size);
  /* HLX-M7 §10.1: HCR releases its claim on rollback. Everything from here to
   * the publishing store is reversible without touching target text, so a
   * failure must leave the window as unclaimed as it found it — otherwise the
   * next patcher (or the next reload) is refused bytes nobody is using. */
  if (claimed_here && ct_claimed_guest_text_release != NULL) {
    ct_claimed_guest_text_release((uintptr_t)window_address);
    claimed_here = 0;
    repro_hcr_lx_last_report.claim_held = 0;
  }
      repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_REFUSED_SITE_TABLE_FULL;
      return NULL;
    }
    site->sled_address = plan.sled_address;
    site->sled_end = plan.sled_end;
    site->window_address = window_address;
    site->original_word = original_word;
  }

  span_start = repro_hcr_lx_page_start(window_address, page_size);
  span_end = repro_hcr_lx_page_start(
                 window_address + REPRO_HCR_LX_WINDOW_BYTES - 1, page_size) +
             (uint64_t)page_size;

  /*
   * Everything above this line is reversible without touching target memory.
   * Below it, exactly one store lands in live text.
   *
   * THE TRANSIENT KEEPS `PROT_EXEC` WHEN THE HOST ALLOWS IT, and HLX-M4 found
   * that the hard way. `mprotect(RW)` over a live text page removes the NX
   * clearance for the WHOLE PAGE, not for the eight bytes being written, so
   * every thread whose PC is anywhere in those 4 KiB faults on its next
   * instruction fetch. Against a hot multithreaded target that is a far more
   * likely killer than the in-window hazard §6.1 point 4 describes, and it is
   * invisible to a single-threaded gate. Retaining `PROT_EXEC` across the store
   * removes it entirely.
   *
   * `text_left_writable` is not the relevant risk here: the restore below puts
   * the page back to RX, and the window is 8-byte aligned so the store itself
   * is unaffected by the protection bits beyond being permitted at all.
   */
  transient_protection = REPRO_HCR_LX_PROT_READ | REPRO_HCR_LX_PROT_WRITE;
  if (caps->text_rwx_transition) {
    transient_protection |= REPRO_HCR_LX_PROT_EXEC;
  }
  repro_hcr_lx_last_report.transient_kept_exec = caps->text_rwx_transition;
  if (repro_hcr_lx_raw_mprotect(span_start, (size_t)(span_end - span_start),
                                transient_protection) != 0) {
    repro_hcr_lx_unmap(patch_page, page_size);
    if (fresh_site) {
      site->used = 0;
    }
  /* HLX-M7 §10.1: HCR releases its claim on rollback. Everything from here to
   * the publishing store is reversible without touching target text, so a
   * failure must leave the window as unclaimed as it found it — otherwise the
   * next patcher (or the next reload) is refused bytes nobody is using. */
  if (claimed_here && ct_claimed_guest_text_release != NULL) {
    ct_claimed_guest_text_release((uintptr_t)window_address);
    claimed_here = 0;
    repro_hcr_lx_last_report.claim_held = 0;
  }
    repro_hcr_lx_last_report.refusal =
        REPRO_HCR_LX_REFUSED_TEXT_PROTECTION_FAILED;
    return NULL;
  }

  /*
   * PUBLICATION.
   *
   * Safety argument, stated here rather than left implicit as it is on macOS.
   * It has two halves and both are required (design §4.2, §4.4):
   *
   *   1. `window_address` is 8-byte aligned and this is an ordinary aligned
   *      8-byte store, so it is single-copy atomic on x86_64. Any thread reads
   *      either the whole previous word (all NOPs, or the previous generation's
   *      jump) or the whole new `E9 rel32 90 90 90`. There is no third
   *      byte-level state, and in particular no partially written jump through
   *      an address composed of NOP bytes.
   *
   *   2. Atomicity of the bytes is not visibility to a core that has already
   *      fetched the old ones. Intel SDM Vol 3 §8.1.3 / §9.3 ("Handling Self-
   *      and Cross-Modifying Code") requires the *executing* processor to
   *      perform a serializing operation; a coherent instruction cache does not
   *      discharge that, and the `mprotect` TLB shootdown is not a guaranteed
   *      substitute (Linux may skip the remote IPI entirely when `mm_cpumask`
   *      names one CPU). The `MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE` below
   *      forces a context-synchronizing event on every core running this
   *      process.
   *
   *   3. A thread whose PC is INSIDE the window is the hazard neither half
   *      addresses, and it is real: the sled is executable instructions, so an
   *      interrupt can leave a thread at window byte 1..7, and on resume it
   *      executes the tail of this very `E9 rel32` as though it were an
   *      instruction (design §6.1 point 4). Half 1 does not help — the bytes
   *      are unambiguous and still wrong for that resume point — and neither
   *      does half 2. Only tier 2 can fix it, by reading the parked PC out of
   *      a `ucontext_t` and nudging it past the window, which is what the
   *      `repro_hcr_lx_quiesce_adjust_window` call below does. Tier 1 has no
   *      such capability, which is why HLX-M4 resolves `HLX-OQ-2` by requiring
   *      tier 2 for any target with more than one thread.
   *
   * HLX-M0 was single threaded, so halves 2 and 3 could not be exercised there;
   * HLX-M4 owns them, owns the `HLX-OQ-3` fallback checked above, and owns the
   * measurement behind the tier rule.
   */
  *(volatile uint64_t *)(uintptr_t)window_address = published_word;
  __atomic_signal_fence(__ATOMIC_SEQ_CST);
  repro_hcr_lx_publication_count += 1;

  /*
   * Tier-2 IP adjustment (§6.2 step 6), applied while every thread is still
   * parked. A thread standing at window byte 1..7 has its resume PC moved to
   * the first instruction boundary at or after the window's end, so it falls
   * through the remaining sled into the retained old body instead of decoding
   * our `rel32` as opcodes. Under tier 1 `quiesce_is_held()` is false and this
   * is a no-op — which is the hazard, not an oversight.
   */
  if (repro_hcr_lx_quiesce_is_held()) {
    uint64_t window_end = window_address + (uint64_t)REPRO_HCR_LX_WINDOW_BYTES;
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
     * That is a different semantic (this entry gets the new version) and it is
     * always safe; leaving the PC alone is the one option that is not.
     */
    uint64_t resume_target = window_address;
    /*
     * Decide it from the window's ORIGINAL bytes, not from live memory: by the
     * time this runs the store has already landed, so reading the window back
     * would decode our own `E9` and conclude — wrongly, every time — that
     * `window_end` is not a boundary. `original_word` is the saved pre-state
     * (§11.2), and because the window always STARTS at a boundary, its eight
     * original bytes decoding into whole NOP instructions is exactly the
     * condition for `window_end` to be one too.
     */
    uint8_t original_bytes[REPRO_HCR_LX_WINDOW_BYTES];
    size_t consumed = 0;
    memcpy(original_bytes, &original_word, sizeof(original_bytes));
    while (consumed < REPRO_HCR_LX_WINDOW_BYTES) {
      size_t len = repro_hcr_lx_nop_length(
          original_bytes + consumed, REPRO_HCR_LX_WINDOW_BYTES - consumed);
      if (len == 0) {
        break;
      }
      consumed += len;
    }
    if (consumed == REPRO_HCR_LX_WINDOW_BYTES &&
        window_end < plan.sled_end) {
      resume_target = window_end;
    }
    repro_hcr_lx_last_report.resume_target = resume_target;
    repro_hcr_lx_last_report.ip_adjustments =
        repro_hcr_lx_quiesce_adjust_window(window_address, window_end,
                                           resume_target);
    repro_hcr_lx_last_report.quiesced = 1;
  }

  if (repro_hcr_lx_raw_mprotect(span_start, (size_t)(span_end - span_start),
                                REPRO_HCR_LX_PROT_READ |
                                    REPRO_HCR_LX_PROT_EXEC) != 0) {
    /* The trampoline is already live, so reporting total failure here would
     * repeat the defect the Apple arm has at its post-store `return NULL`. The
     * honest report is success plus a recorded flag; the capability probe at
     * agent start exists so this path is unreachable on a supported host. */
    repro_hcr_lx_caps.text_left_writable = 1;
    repro_hcr_lx_last_report.text_left_writable = 1;
  }

  /* Half 2 of the safety argument. The counter is not decoration: it is the
   * only way a gate can distinguish "the event was issued and returned 0" from
   * "this branch was never reached", which look identical in a report whose
   * `membarrier_result` field starts life as 0. */
  if (repro_hcr_lx_sync_core_available() && !repro_hcr_lx_sync_core_suppressed) {
    repro_hcr_lx_last_report.membarrier_result = repro_hcr_lx_raw_membarrier(
        REPRO_HCR_LX_MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE, 0);
    repro_hcr_lx_membarrier_issued_count += 1;
  } else {
    /* Reachable only under quiescence (the refusal above is the other case),
     * where the handshake's own kernel entry/exit is the context-synchronizing
     * event, or under the test lever that removes half 2 deliberately. */
    repro_hcr_lx_last_report.membarrier_result = -1;
  }

  site->published_word = published_word;
  site->generation += 1;
  if (claimed_here) {
    site->claimed = 1;
  }
  repro_hcr_lx_last_report.claim_held = site->claimed;
  repro_hcr_lx_last_report.published_word = published_word;
  repro_hcr_lx_last_report.dispatch_address = dispatch_address;
  repro_hcr_lx_last_report.generation = site->generation;
  repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_OK;
  return patch_page;
}

#endif /* REPRO_HCR_LINUX_X86_64_H */
