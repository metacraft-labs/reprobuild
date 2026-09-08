/*
 * HLX-M0 real Linux x86_64 target process.
 *
 * The falsifier the milestone specifies, in its most direct form: this process
 * calls a patchable function that returns 11, the agent applies a real direct
 * entry patch over the real agent socket and wire protocol, and the same call
 * then returns 77. There is no scaffold that can pass by returning an empty
 * result — the observable is this process's own return value.
 *
 * It is deliberately compiled with the real patchable build profile
 * (`-falign-functions=16 -fpatchable-function-entry=16,0 -fcf-protection=full`)
 * so the entry layout under CET is the one the design measured, and it links
 * the production C agent (`libs/repro_hcr_agent/c/repro_hcr_agent.c`) rather
 * than a stand-in.
 *
 * The evidence it prints is deliberately independent of the agent's own
 * bookkeeping: the sled address is read from `__patchable_function_entries` by
 * this program, and the entry bytes are dumped before and after so the harness
 * can assert that `endbr64` survived and that exactly one aligned 8-byte window
 * changed.
 */

#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "repro_hcr_agent.h"

extern const uintptr_t __start___patchable_function_entries[]
    __attribute__((weak));
extern const uintptr_t __stop___patchable_function_entries[]
    __attribute__((weak));

#define HCR_LX_M0_DUMP_BYTES 32

__attribute__((noinline, used)) int hcr_lx_m0_entry(void) { return 11; }

/* A volatile function pointer keeps the two calls real: the compiler may not
 * fold the second into the first, nor constant-fold either. */
static int (*volatile hcr_lx_m0_call)(void) = hcr_lx_m0_entry;

static void dump_hex(char *out, const unsigned char *bytes, size_t count) {
  static const char digits[] = "0123456789abcdef";
  size_t i;
  for (i = 0; i < count; ++i) {
    out[i * 2] = digits[(bytes[i] >> 4) & 0xf];
    out[i * 2 + 1] = digits[bytes[i] & 0xf];
  }
  out[count * 2] = '\0';
}

static uint64_t sled_address_for(uint64_t entry_address, size_t *entry_count) {
  uint64_t best = 0;
  size_t count = 0;
  size_t i;
  if (__start___patchable_function_entries != NULL &&
      __stop___patchable_function_entries != NULL &&
      __stop___patchable_function_entries >
          __start___patchable_function_entries) {
    count = (size_t)(__stop___patchable_function_entries -
                     __start___patchable_function_entries);
    for (i = 0; i < count; ++i) {
      uint64_t value = (uint64_t)__start___patchable_function_entries[i];
      if (value < entry_address || value - entry_address > 8u) {
        continue;
      }
      if (best == 0 || value < best) {
        best = value;
      }
    }
  }
  if (entry_count != NULL) {
    *entry_count = count;
  }
  return best;
}

int main(void) {
  repro_hcr_agent_symbol symbols[1];
  unsigned char before_bytes[HCR_LX_M0_DUMP_BYTES];
  unsigned char after_bytes[HCR_LX_M0_DUMP_BYTES];
  char before_hex[HCR_LX_M0_DUMP_BYTES * 2 + 1];
  char after_hex[HCR_LX_M0_DUMP_BYTES * 2 + 1];
  size_t patchable_entry_count = 0;
  uint64_t entry_address = (uint64_t)(uintptr_t)hcr_lx_m0_entry;
  uint64_t sled_address = sled_address_for(entry_address,
                                           &patchable_entry_count);
  int before;
  int after;
  int start_rc;
  int poll_rc;

  memcpy(before_bytes, (const void *)(uintptr_t)entry_address,
         sizeof(before_bytes));
  before = hcr_lx_m0_call();

  symbols[0].name = "hcr_lx_m0_entry";
  symbols[0].address = (void *)hcr_lx_m0_entry;
  start_rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), symbols, 1);
  poll_rc = repro_hcr_agent_poll();

  memcpy(after_bytes, (const void *)(uintptr_t)entry_address,
         sizeof(after_bytes));
  after = hcr_lx_m0_call();

  dump_hex(before_hex, before_bytes, sizeof(before_bytes));
  dump_hex(after_hex, after_bytes, sizeof(after_bytes));

  printf(
      "{\"schemaId\":\"reprobuild.hcr.hlx-m0.linux-x86_64-target-result.v1\","
      "\"before\":%d,\"after\":%d,"
      "\"supportProfile\":\"%s\","
      "\"hostSupportsDirectPatch\":%s,"
      "\"membarrierSyncCore\":%s,"
      "\"startRc\":%d,\"pollRc\":%d,"
      "\"entryAddress\":\"0x%llx\","
      "\"sledAddress\":\"0x%llx\","
      "\"sledOffsetFromEntry\":%lld,"
      "\"patchableEntryCount\":%zu,"
      "\"entryBytesBeforeHex\":\"%s\","
      "\"entryBytesAfterHex\":\"%s\"}\n",
      before, after, repro_hcr_agent_default_support_profile(),
      repro_hcr_agent_host_supports_direct_patch() ? "true" : "false",
      repro_hcr_agent_host_membarrier_sync_core() ? "true" : "false", start_rc,
      poll_rc, (unsigned long long)entry_address,
      (unsigned long long)sled_address,
      sled_address == 0 ? -1LL
                        : (long long)(sled_address - entry_address),
      patchable_entry_count, before_hex, after_hex);
  fflush(stdout);
  return 0;
}
