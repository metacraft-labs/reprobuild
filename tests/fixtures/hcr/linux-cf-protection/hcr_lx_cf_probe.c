/*
 * HLX-M0 sled-layout probe fixture.
 *
 * Compiled by `t_integration_hcr_linux_cf_protection_sled_layout.nim` with real
 * GCC and real Clang, with and without `-fcf-protection`, and LINKED — the
 * `__patchable_function_entries` section is `SHF_ALLOC|SHF_WRITE|SHF_LINK_ORDER`,
 * so its entries only hold runtime addresses after the dynamic loader has
 * relocated them. Reading it from the object file would measure the wrong
 * thing.
 *
 * It prints, as JSON, what the design's §4.2 measurement claims: the entry
 * address, the address the patchable-entries section records for that function,
 * and the raw bytes at the entry. The harness feeds those bytes to the
 * production window planner.
 */

#include <stdio.h>
#include <stdint.h>
#include <stddef.h>

extern const uintptr_t __start___patchable_function_entries[]
    __attribute__((weak));
extern const uintptr_t __stop___patchable_function_entries[]
    __attribute__((weak));

#define HCR_LX_CF_DUMP_BYTES 48

__attribute__((noinline, used)) int hcr_lx_cf_victim(int a) { return a + 11; }
__attribute__((noinline, used)) int hcr_lx_cf_second(int a) { return a * 3; }

static void dump_hex(char *out, const unsigned char *bytes, size_t count) {
  static const char digits[] = "0123456789abcdef";
  size_t i;
  for (i = 0; i < count; ++i) {
    out[i * 2] = digits[(bytes[i] >> 4) & 0xf];
    out[i * 2 + 1] = digits[bytes[i] & 0xf];
  }
  out[count * 2] = '\0';
}

static uint64_t sled_for(uint64_t entry_address, size_t *total) {
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
  if (total != NULL) {
    *total = count;
  }
  return best;
}

int main(void) {
  unsigned char bytes[HCR_LX_CF_DUMP_BYTES];
  char hex[HCR_LX_CF_DUMP_BYTES * 2 + 1];
  size_t total = 0;
  uint64_t entry = (uint64_t)(uintptr_t)hcr_lx_cf_victim;
  uint64_t second = (uint64_t)(uintptr_t)hcr_lx_cf_second;
  uint64_t sled = sled_for(entry, &total);
  size_t k;
  for (k = 0; k < sizeof(bytes); ++k) {
    bytes[k] = ((const unsigned char *)(uintptr_t)entry)[k];
  }
  dump_hex(hex, bytes, sizeof(bytes));
  printf("{\"schemaId\":\"reprobuild.hcr.hlx-m0.cf-protection-probe.v1\","
         "\"entryAddress\":\"0x%llx\",\"secondAddress\":\"0x%llx\","
         "\"sledAddress\":\"0x%llx\",\"sledOffsetFromEntry\":%lld,"
         "\"patchableEntryCount\":%zu,\"entryBytesHex\":\"%s\","
         "\"victimResult\":%d}\n",
         (unsigned long long)entry, (unsigned long long)second,
         (unsigned long long)sled,
         sled == 0 ? -1LL : (long long)(sled - entry), total, hex,
         hcr_lx_cf_victim(1));
  return 0;
}
