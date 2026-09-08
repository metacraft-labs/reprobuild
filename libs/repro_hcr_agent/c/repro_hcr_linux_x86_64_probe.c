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

#if defined(__linux__) && defined(__x86_64__)

#include <stddef.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

#include "repro_hcr_linux_x86_64.h"

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
  return (unsigned long long)repro_hcr_lx_sled_address_for_entry(
      (uint64_t)entry_address);
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

void *repro_hcr_lx_probe_map(size_t length, int protection) {
  return repro_hcr_lx_map_anonymous(NULL, length, protection, 0);
}

int repro_hcr_lx_probe_unmap(void *address, size_t length) {
  return repro_hcr_lx_unmap(address, length);
}

size_t repro_hcr_lx_probe_page_size(void) { return repro_hcr_lx_page_size(); }

#endif /* __linux__ && __x86_64__ */
