/*
 * Test-facing shim over `repro_hcr_linux_x86_64.h`.
 *
 * The window planner, the NOP predicate, the `E9 rel32` encoder and the host
 * capability probe are `static` inside the header so the agent translation unit
 * carries no exported surface it does not need. This shim includes that same
 * header — the SAME code the live agent runs, not a reimplementation — and
 * re-exports it so the HLX-M0 unit gate can drive it directly.
 *
 * No mocks: every function below forwards to the production implementation.
 */

/* Must precede every libc header: glibc latches its feature macros on the
 * FIRST one it sees, and `ucontext_t`'s `gregs`/`REG_RIP` — which tier-2
 * quiescence reads a parked thread's PC out of — are behind `__USE_GNU`.
 * `repro_hcr_agent.c` does the same, for the same reason. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#if defined(__linux__) && defined(__x86_64__)

#include <stddef.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

#include "repro_hcr_linux_x86_64.h"
/* HLX-M2: sled discovery moved to the ELF layer so it can reach any loaded
 * object's `__patchable_function_entries`, not only the image the agent was
 * linked into. The shim follows it there so the gates keep driving the SAME
 * lookup the agent runs — there is no main-executable-only variant left to
 * accidentally test instead. */
#include "repro_hcr_linux_elf_symbols.h"

static size_t repro_hcr_lx_page_size(void) {
  long value = sysconf(_SC_PAGESIZE);
  return value > 0 ? (size_t)value : 4096u;
}

static void *repro_hcr_lx_map_anonymous(void *hint, size_t length,
                                        int protection, int extra_flags) {
  int prot = 0;
  void *mapped;
  if ((protection & REPRO_HCR_LX_PROT_READ) != 0) {
    prot |= PROT_READ;
  }
  if ((protection & REPRO_HCR_LX_PROT_WRITE) != 0) {
    prot |= PROT_WRITE;
  }
  if ((protection & REPRO_HCR_LX_PROT_EXEC) != 0) {
    prot |= PROT_EXEC;
  }
  mapped = mmap(hint, length, prot, MAP_PRIVATE | MAP_ANONYMOUS | extra_flags,
                -1, 0);
  return mapped == MAP_FAILED ? NULL : mapped;
}

static int repro_hcr_lx_unmap(void *address, size_t length) {
  return munmap(address, length);
}

size_t repro_hcr_lx_probe_nop_length(const unsigned char *bytes, size_t avail) {
  return repro_hcr_lx_nop_length((const uint8_t *)bytes, avail);
}

int repro_hcr_lx_probe_plan_sled(const unsigned char *bytes, size_t capacity,
                                 unsigned long long sled_address,
                                 unsigned long long *sled_end,
                                 unsigned int *sled_length,
                                 unsigned long long *window_address,
                                 unsigned int *window_offset) {
  repro_hcr_lx_sled_plan plan;
  int rc = repro_hcr_lx_plan_sled((const uint8_t *)bytes, capacity,
                                  (uint64_t)sled_address, &plan);
  if (sled_end != NULL) {
    *sled_end = (unsigned long long)plan.sled_end;
  }
  if (sled_length != NULL) {
    *sled_length = (unsigned int)plan.sled_length;
  }
  if (window_address != NULL) {
    *window_address = (unsigned long long)plan.window_address;
  }
  if (window_offset != NULL) {
    *window_offset = (unsigned int)plan.window_offset;
  }
  return rc;
}

int repro_hcr_lx_probe_encode_jmp_rel32(unsigned long long window_address,
                                        unsigned long long target_address,
                                        unsigned char *out_bytes) {
  return repro_hcr_lx_encode_jmp_rel32((uint64_t)window_address,
                                       (uint64_t)target_address,
                                       (uint8_t *)out_bytes);
}

unsigned long long repro_hcr_lx_probe_published_word(
    const unsigned char *jmp_bytes) {
  return (unsigned long long)repro_hcr_lx_published_word(
      (const uint8_t *)jmp_bytes);
}

const char *repro_hcr_lx_probe_refusal_name(int code) {
  return repro_hcr_lx_refusal_name(code);
}

int repro_hcr_lx_probe_text_protection_roundtrip(void) {
  return repro_hcr_lx_capability_report()->text_protection_roundtrip;
}

int repro_hcr_lx_probe_membarrier_sync_core(void) {
  return repro_hcr_lx_capability_report()->membarrier_sync_core;
}

long long repro_hcr_lx_probe_membarrier_query_mask(void) {
  return (long long)repro_hcr_lx_capability_report()->membarrier_query_mask;
}

long long repro_hcr_lx_probe_protection_probe_rw_result(void) {
  return (long long)repro_hcr_lx_capability_report()->protection_probe_rw_result;
}

long long repro_hcr_lx_probe_protection_probe_rx_result(void) {
  return (long long)repro_hcr_lx_capability_report()->protection_probe_rx_result;
}

unsigned long long repro_hcr_lx_probe_sled_address_for_entry(
    unsigned long long entry_address) {
  return (unsigned long long)repro_hcr_elf_sled_address_for_entry(
      (uint64_t)entry_address);
}

/* HLX-M2 — the sled lookup's own report, so a gate can assert WHICH object the
 * sled came from and, on a refusal, which of the five distinguishable causes it
 * was. A bare address answers neither question. */
int repro_hcr_lx_probe_sled_status(void) {
  return repro_hcr_elf_last_sled_lookup.status;
}

const char *repro_hcr_lx_probe_sled_status_name(int status) {
  return repro_hcr_elf_sled_status_name(status);
}

const char *repro_hcr_lx_probe_sled_object_path(void) {
  return repro_hcr_elf_last_sled_lookup.object_path;
}

const char *repro_hcr_lx_probe_sled_detail(void) {
  return repro_hcr_elf_last_sled_lookup.detail;
}

int repro_hcr_lx_probe_sled_is_main_executable(void) {
  return repro_hcr_elf_last_sled_lookup.is_main_executable;
}

unsigned long long repro_hcr_lx_probe_sled_load_bias(void) {
  return (unsigned long long)repro_hcr_elf_last_sled_lookup.load_bias;
}

unsigned long long repro_hcr_lx_probe_sled_section_start(void) {
  return (unsigned long long)repro_hcr_elf_last_sled_lookup.section_start;
}

unsigned long long repro_hcr_lx_probe_sled_entry_count(void) {
  return (unsigned long long)repro_hcr_elf_last_sled_lookup.entry_count;
}

int repro_hcr_lx_probe_sled_objects_seen(void) {
  return repro_hcr_elf_last_sled_lookup.objects_seen;
}

/* ---------------------------------------------------------------------------
 * HLX-M2 — islands and trampoline selection. Every one forwards to the
 * production implementation.
 * ------------------------------------------------------------------------- */

void repro_hcr_lx_probe_encode_island(unsigned long long target_address,
                                      unsigned char *out_bytes) {
  repro_hcr_lx_encode_island((uint64_t)target_address, (uint8_t *)out_bytes);
}

int repro_hcr_lx_probe_island_bytes(void) {
  return (int)REPRO_HCR_LX_ISLAND_BYTES;
}

int repro_hcr_lx_probe_select_trampoline(unsigned long long window_address,
                                         unsigned long long body_address,
                                         int *kind,
                                         unsigned long long *jump_target,
                                         unsigned long long *island_address,
                                         long long *body_displacement) {
  repro_hcr_lx_trampoline_choice choice;
  int rc = repro_hcr_lx_select_trampoline((uint64_t)window_address,
                                          (uint64_t)body_address, &choice);
  if (kind != NULL) {
    *kind = choice.kind;
  }
  if (jump_target != NULL) {
    *jump_target = (unsigned long long)choice.jump_target;
  }
  if (island_address != NULL) {
    *island_address = (unsigned long long)choice.island_address;
  }
  if (body_displacement != NULL) {
    *body_displacement = (long long)choice.body_displacement;
  }
  return rc;
}

int repro_hcr_lx_probe_last_trampoline_kind(void) {
  return repro_hcr_lx_last_report.trampoline_kind;
}

unsigned long long repro_hcr_lx_probe_last_island_address(void) {
  return (unsigned long long)repro_hcr_lx_last_report.island_address;
}

long long repro_hcr_lx_probe_last_body_displacement(void) {
  return (long long)repro_hcr_lx_last_report.body_displacement;
}

unsigned long long repro_hcr_lx_probe_island_alloc_count(void) {
  return (unsigned long long)repro_hcr_lx_island_alloc_count;
}

unsigned long long repro_hcr_lx_probe_island_page_map_count(void) {
  return (unsigned long long)repro_hcr_lx_island_page_map_count;
}

unsigned long long repro_hcr_lx_probe_island_reuse_count(void) {
  return (unsigned long long)repro_hcr_lx_island_reuse_count;
}

/* The protection asked for on the reuse write transient, -1 if no page has been
 * reused. The reuse hazard is only observable here: `allocate_island` restores
 * `R|X` before returning, so nothing read afterwards can distinguish a
 * transient that kept `PROT_EXEC` from one that dropped it. */
int repro_hcr_lx_probe_island_reuse_transient_prot(void) {
  return repro_hcr_lx_island_reuse_transient_prot;
}

int repro_hcr_lx_probe_prot_exec(void) { return REPRO_HCR_LX_PROT_EXEC; }

unsigned long long repro_hcr_lx_probe_gap_scan_count(void) {
  return (unsigned long long)repro_hcr_lx_gap_scan_count;
}

unsigned long long repro_hcr_lx_probe_gap_hit_count(void) {
  return (unsigned long long)repro_hcr_lx_gap_hit_count;
}

int repro_hcr_lx_probe_island_page_count(void) {
  return repro_hcr_lx_island_page_count;
}

void repro_hcr_lx_probe_set_force_far_patch_body(int value) {
  repro_hcr_lx_force_far_patch_body = value;
}

/* Forget every island page. Tests only, and for the same reason
 * `repro_hcr_lx_probe_reset_sites` exists: the island table is process-global
 * and a gate that unmaps its pages between cases would otherwise hand case N+1
 * a slot in a page that no longer exists. The agent never calls it. */
void repro_hcr_lx_probe_reset_islands(void) {
  int i;
  for (i = 0; i < REPRO_HCR_LX_MAX_ISLAND_PAGES; ++i) {
    repro_hcr_lx_island_pages[i].base = 0;
    repro_hcr_lx_island_pages[i].used = 0;
  }
  repro_hcr_lx_island_page_count = 0;
  repro_hcr_lx_island_reuse_transient_prot = -1;
}

int repro_hcr_lx_probe_membarrier_sync_core_cmd(void) {
  return REPRO_HCR_LX_MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE;
}

int repro_hcr_lx_probe_membarrier_register_cmd(void) {
  return REPRO_HCR_LX_MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED_SYNC_CORE;
}

/* Keeps the site-table helpers referenced so the shared header compiles without
 * unused-function diagnostics in this translation unit. */
int repro_hcr_lx_probe_site_table_roundtrip(unsigned long long entry_address) {
  repro_hcr_lx_site *site = repro_hcr_lx_claim_site((uint64_t)entry_address);
  int ok;
  if (site == NULL) {
    return 0;
  }
  ok = repro_hcr_lx_find_site((uint64_t)entry_address) == site;
  site->used = 0;
  return ok;
}

int repro_hcr_lx_probe_rel32_reachable(unsigned long long window_address,
                                       unsigned long long target_address) {
  return repro_hcr_lx_rel32_reachable((uint64_t)window_address,
                                      (uint64_t)target_address);
}

long repro_hcr_lx_probe_raw_mprotect(unsigned long long address, size_t length,
                                     int protection) {
  return repro_hcr_lx_raw_mprotect((uint64_t)address, length, protection);
}

/* Drives the exact production publication path (`repro_hcr_lx_apply_direct_patch_at`)
 * against a sled the caller supplies, which is what HLX-M1's ELF resolver will
 * also do. Nothing here is a stand-in for the agent's code. */
unsigned long long repro_hcr_lx_probe_apply_direct_patch_at(
    unsigned long long entry_address, unsigned long long sled_address,
    const unsigned char *patch_bytes, size_t patch_len) {
  void *page = repro_hcr_lx_apply_direct_patch_at(
      (uint64_t)entry_address, (uint64_t)sled_address,
      (const uint8_t *)patch_bytes, patch_len);
  return (unsigned long long)(uintptr_t)page;
}

int repro_hcr_lx_probe_last_refusal(void) {
  return repro_hcr_lx_last_report.refusal;
}

unsigned long long repro_hcr_lx_probe_last_window_address(void) {
  return (unsigned long long)repro_hcr_lx_last_report.window_address;
}

unsigned int repro_hcr_lx_probe_last_window_offset(void) {
  return (unsigned int)repro_hcr_lx_last_report.window_offset;
}

unsigned int repro_hcr_lx_probe_last_sled_length(void) {
  return (unsigned int)repro_hcr_lx_last_report.sled_length;
}

unsigned long long repro_hcr_lx_probe_last_original_word(void) {
  return (unsigned long long)repro_hcr_lx_last_report.original_word;
}

unsigned long long repro_hcr_lx_probe_last_published_word(void) {
  return (unsigned long long)repro_hcr_lx_last_report.published_word;
}

unsigned long long repro_hcr_lx_probe_last_generation(void) {
  return (unsigned long long)repro_hcr_lx_last_report.generation;
}

long repro_hcr_lx_probe_last_membarrier_result(void) {
  return repro_hcr_lx_last_report.membarrier_result;
}

int repro_hcr_lx_probe_last_text_left_writable(void) {
  return repro_hcr_lx_last_report.text_left_writable;
}

/* HLX-M7 §10.1 — the cross-patcher claim outcome for the last publication. */
unsigned int repro_hcr_lx_probe_last_claim_holder(void) {
  return (unsigned int)repro_hcr_lx_last_report.claim_holder;
}

int repro_hcr_lx_probe_last_claim_held(void) {
  return repro_hcr_lx_last_report.claim_held;
}

/*
 * Forget every site.
 *
 * The site table is process-global and lives for the life of the provider, by
 * design (§4.5: a re-patch's admissible pre-state is the word the provider
 * itself published). A gate that publishes into freshly mapped memory needs a
 * clean table between cases, or case N+1 takes the re-patch branch against a
 * site whose window address has since been unmapped and remapped for something
 * else. Tests only; the agent never calls it.
 */
void repro_hcr_lx_probe_reset_sites(void) {
  int i;
  for (i = 0; i < REPRO_HCR_LX_MAX_SITES; ++i) {
    repro_hcr_lx_sites[i].used = 0;
    repro_hcr_lx_sites[i].claimed = 0;
  }
}

/* ---------------------------------------------------------------------------
 * HLX-M4 surface: the publication's second half, and tier-2 quiescence.
 * Every one of these forwards to the production implementation.
 * ------------------------------------------------------------------------- */

int repro_hcr_lx_probe_text_rwx_transition(void) {
  return repro_hcr_lx_capability_report()->text_rwx_transition;
}

long long repro_hcr_lx_probe_protection_probe_rwx_result(void) {
  return (long long)repro_hcr_lx_capability_report()->protection_probe_rwx_result;
}

int repro_hcr_lx_probe_last_transient_kept_exec(void) {
  return repro_hcr_lx_last_report.transient_kept_exec;
}

int repro_hcr_lx_probe_last_quiesced(void) {
  return repro_hcr_lx_last_report.quiesced;
}

int repro_hcr_lx_probe_last_ip_adjustments(void) {
  return (int)repro_hcr_lx_last_report.ip_adjustments;
}

unsigned long long repro_hcr_lx_probe_last_resume_target(void) {
  return (unsigned long long)repro_hcr_lx_last_report.resume_target;
}

unsigned long long repro_hcr_lx_probe_membarrier_issued_count(void) {
  return (unsigned long long)repro_hcr_lx_membarrier_issued_count;
}

unsigned long long repro_hcr_lx_probe_publication_count(void) {
  return (unsigned long long)repro_hcr_lx_publication_count;
}

void repro_hcr_lx_probe_set_sync_core_suppressed(int value) {
  repro_hcr_lx_sync_core_suppressed = value;
}

void repro_hcr_lx_probe_set_pretend_sync_core_unavailable(int value) {
  repro_hcr_lx_pretend_sync_core_unavailable = value;
}

void repro_hcr_lx_probe_set_quiesce_suppress_adjust(int value) {
  repro_hcr_lx_quiesce_suppress_adjust = value;
}

/* The post-deadline signal-mask census. Off restores the pre-census reporting
 * exactly, which is what keeps HLX-M4's bounded-timeout arm testing the path
 * it was written for; see the lever's own comment in the quiescence header. */
void repro_hcr_lx_probe_set_quiesce_sigmask_census(int value) {
  repro_hcr_lx_quiesce_sigmask_census_enabled = value;
}

int repro_hcr_lx_probe_quiesce_sigmask_read_ok(void) {
  return (int)repro_hcr_lx_quiesce.sigmask_read_ok;
}

int repro_hcr_lx_probe_quiesce_sigmask_read_failed(void) {
  return (int)repro_hcr_lx_quiesce.sigmask_read_failed;
}

int repro_hcr_lx_probe_quiesce_blocked_count(void) {
  return (int)repro_hcr_lx_quiesce.blocked_count;
}

int repro_hcr_lx_probe_quiesce_blocked_tid(int index) {
  if (index < 0 || index >= repro_hcr_lx_quiesce.blocked_count ||
      index >= REPRO_HCR_LX_MAX_BLOCKED_THREADS) {
    return -1;
  }
  return (int)repro_hcr_lx_quiesce.blocked_tids[index];
}

unsigned long long repro_hcr_lx_probe_quiesce_blocked_mask(int index) {
  if (index < 0 || index >= repro_hcr_lx_quiesce.blocked_count ||
      index >= REPRO_HCR_LX_MAX_BLOCKED_THREADS) {
    return 0;
  }
  return (unsigned long long)repro_hcr_lx_quiesce.blocked_masks[index];
}

const char *repro_hcr_lx_probe_quiesce_blocked_name(int index) {
  if (index < 0 || index >= repro_hcr_lx_quiesce.blocked_count ||
      index >= REPRO_HCR_LX_MAX_BLOCKED_THREADS) {
    return "";
  }
  return repro_hcr_lx_quiesce.blocked_names[index];
}

int repro_hcr_lx_probe_quiesce_install(int signo) {
  return repro_hcr_lx_quiesce_install(signo);
}

int repro_hcr_lx_probe_quiesce_begin(unsigned long long timeout_ns) {
  return repro_hcr_lx_quiesce_begin((uint64_t)timeout_ns);
}

int repro_hcr_lx_probe_quiesce_release(void) {
  return repro_hcr_lx_quiesce_release();
}

int repro_hcr_lx_probe_quiesce_is_held(void) {
  return repro_hcr_lx_quiesce_is_held();
}

const char *repro_hcr_lx_probe_quiesce_status_name(int code) {
  return repro_hcr_lx_quiesce_status_name(code);
}

int repro_hcr_lx_probe_quiesce_slot_count(void) {
  return (int)repro_hcr_lx_quiesce.slot_count;
}

int repro_hcr_lx_probe_quiesce_parked_count(void) {
  return (int)repro_hcr_lx_quiesce.parked_count;
}

int repro_hcr_lx_probe_quiesce_resumed_count(void) {
  return (int)repro_hcr_lx_quiesce.resumed_count;
}

int repro_hcr_lx_probe_quiesce_signalled_count(void) {
  return (int)repro_hcr_lx_quiesce.signalled_count;
}

int repro_hcr_lx_probe_quiesce_stray_signals(void) {
  return (int)repro_hcr_lx_quiesce.stray_signals;
}

int repro_hcr_lx_probe_quiesce_enumeration_rounds(void) {
  return (int)repro_hcr_lx_quiesce.enumeration_rounds;
}

int repro_hcr_lx_probe_quiesce_unresponsive_count(void) {
  return (int)repro_hcr_lx_quiesce.unresponsive_count;
}

int repro_hcr_lx_probe_quiesce_unresponsive_tid(int index) {
  if (index < 0 || index >= repro_hcr_lx_quiesce.unresponsive_count) {
    return -1;
  }
  return (int)repro_hcr_lx_quiesce.unresponsive_tids[index];
}

int repro_hcr_lx_probe_quiesce_slot_tid(int index) {
  if (index < 0 || index >= repro_hcr_lx_quiesce.slot_count) {
    return -1;
  }
  return (int)repro_hcr_lx_quiesce.slots[index].tid;
}

unsigned long long repro_hcr_lx_probe_quiesce_slot_pc(int index) {
  if (index < 0 || index >= repro_hcr_lx_quiesce.slot_count) {
    return 0;
  }
  return (unsigned long long)repro_hcr_lx_quiesce.slots[index].pc;
}

int repro_hcr_lx_probe_quiesce_slot_parked(int index) {
  if (index < 0 || index >= repro_hcr_lx_quiesce.slot_count) {
    return -2;
  }
  return (int)repro_hcr_lx_quiesce.slots[index].parked;
}

int repro_hcr_lx_probe_quiesce_slot_frame_count(int index) {
  if (index < 0 || index >= repro_hcr_lx_quiesce.slot_count) {
    return -1;
  }
  return (int)repro_hcr_lx_quiesce.slots[index].frame_count;
}

unsigned long long repro_hcr_lx_probe_quiesce_slot_frame(int index,
                                                         int frame) {
  if (index < 0 || index >= repro_hcr_lx_quiesce.slot_count) {
    return 0;
  }
  if (frame < 0 ||
      frame >= (int)repro_hcr_lx_quiesce.slots[index].frame_count) {
    return 0;
  }
  return (unsigned long long)repro_hcr_lx_quiesce.slots[index].frames[frame];
}

int repro_hcr_lx_probe_quiesce_threads_on_stack_in(unsigned long long low,
                                                   unsigned long long high) {
  return (int)repro_hcr_lx_quiesce_threads_on_stack_in((uint64_t)low,
                                                       (uint64_t)high);
}

unsigned long long repro_hcr_lx_probe_quiesce_park_ns(void) {
  return (unsigned long long)repro_hcr_lx_quiesce.last_park_ns;
}

unsigned long long repro_hcr_lx_probe_quiesce_release_ns(void) {
  return (unsigned long long)repro_hcr_lx_quiesce.last_release_ns;
}

unsigned long long repro_hcr_lx_probe_quiesce_nested_adjust_count(void) {
  return (unsigned long long)repro_hcr_lx_quiesce.nested_adjust_count;
}

unsigned long long repro_hcr_lx_probe_quiesce_nested_frames_seen(void) {
  return (unsigned long long)repro_hcr_lx_quiesce.nested_frames_seen;
}

int repro_hcr_lx_probe_quiesce_handler_stage(void) {
  return repro_hcr_lx_quiesce_handler_stage;
}

void repro_hcr_lx_probe_set_nested_scan_enabled(int value) {
  repro_hcr_lx_nested_scan_enabled = value;
}

int repro_hcr_lx_probe_quiesce_readable_ranges(void) {
  return (int)repro_hcr_lx_quiesce.readable_ranges;
}

int repro_hcr_lx_probe_quiesce_trampoline_verified(void) {
  return repro_hcr_lx_trampoline_verified;
}

int repro_hcr_lx_probe_quiesce_trampoline_mismatch(void) {
  return repro_hcr_lx_trampoline_mismatch;
}

int repro_hcr_lx_probe_quiesce_slot_nested_count(int index) {
  if (index < 0 || index >= repro_hcr_lx_quiesce.slot_count) {
    return -1;
  }
  return (int)repro_hcr_lx_quiesce.slots[index].nested_count;
}

unsigned long long repro_hcr_lx_probe_quiesce_slot_nested_pc(int index,
                                                             int frame) {
  if (index < 0 || index >= repro_hcr_lx_quiesce.slot_count) {
    return 0;
  }
  if (frame < 0 ||
      frame >= (int)repro_hcr_lx_quiesce.slots[index].nested_count) {
    return 0;
  }
  return (unsigned long long)repro_hcr_lx_quiesce.slots[index].nested_pc[frame];
}

unsigned long long repro_hcr_lx_probe_quiesce_adjust_count(void) {
  return (unsigned long long)repro_hcr_lx_quiesce.adjust_count;
}

unsigned long long repro_hcr_lx_probe_quiesce_timeout_count(void) {
  return (unsigned long long)repro_hcr_lx_quiesce.timeout_count;
}

int repro_hcr_lx_probe_quiesce_signo(void) {
  return repro_hcr_lx_quiesce.signo;
}

void *repro_hcr_lx_probe_map(size_t length, int protection) {
  return repro_hcr_lx_map_anonymous(NULL, length, protection, 0);
}

int repro_hcr_lx_probe_unmap(void *address, size_t length) {
  return repro_hcr_lx_unmap(address, length);
}

size_t repro_hcr_lx_probe_page_size(void) { return repro_hcr_lx_page_size(); }

#endif /* __linux__ && __x86_64__ */
