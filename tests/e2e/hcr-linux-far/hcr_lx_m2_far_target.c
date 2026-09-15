/*
 * HLX-M2 real Linux x86_64 target for FAR TARGETS, ISLANDS, and EXHAUSTION.
 *
 * One program, four modes, because all four must be the same binary: a gate
 * that compared a patched run against a differently-compiled control would be
 * comparing two things at once.
 *
 *   plain    the body lands near; the published `rel32` points straight at it.
 *            This is the POSITIVE CONTROL for `exhaust` — it proves the
 *            function is patchable in this binary, so a refusal in `exhaust`
 *            is caused by the exhausted region and not by an unpatchable
 *            target.
 *   far      the body is deliberately mapped OUTSIDE +/-2 GiB of the
 *            publication window and is reached through a 14-byte island. The
 *            mode also writes a WIDENED store over an untouched decoy's sled
 *            so the harness can show its byte predicates discriminate.
 *   exhaust  every gap in [window-2GiB, window+2GiB] is filled with PROT_NONE
 *            mappings before the patch arrives, so no island can be placed and
 *            the provider must refuse by name and write nothing.
 *
 * The evidence is read by this process out of its own memory. The published
 * bytes are decoded here — the `rel32` is followed to the island, the island's
 * `FF 25 00 00 00 00` is decoded, and the `.quad` behind it is reported — so
 * the harness never has to take the provider's word for where the jump goes.
 * The provider's own report is printed alongside under `agent*` keys so the two
 * can be compared instead of conflated.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "repro_hcr_agent.h"

extern const uintptr_t __start___patchable_function_entries[]
    __attribute__((weak));
extern const uintptr_t __stop___patchable_function_entries[]
    __attribute__((weak));

/* HLX-M2 evidence surface of the production agent (see repro_hcr_agent.c). */
extern void repro_hcr_agent_force_far_patch_body_for_tests(int enabled);
extern int repro_hcr_agent_last_trampoline_kind_for_tests(void);
extern unsigned long long repro_hcr_agent_last_island_address_for_tests(void);
extern long long repro_hcr_agent_last_body_displacement_for_tests(void);
extern unsigned long long repro_hcr_agent_last_window_address_for_tests(void);
extern unsigned long long repro_hcr_agent_last_dispatch_address_for_tests(void);
extern const char *repro_hcr_agent_last_refusal_name_for_tests(void);
extern unsigned long long repro_hcr_agent_island_alloc_count_for_tests(void);
extern unsigned long long repro_hcr_agent_gap_scan_count_for_tests(void);
extern unsigned long long repro_hcr_agent_gap_hit_count_for_tests(void);

#define DUMP_BYTES 32
#define ISLAND_BYTES 14

__attribute__((noinline, used)) int hcr_lx_m2_far_entry(void) { return 11; }

/*
 * An untouched patchable function. The agent never sees it. In `far` mode this
 * program writes a 14-byte `jmp [rip+0]; .quad` over its sled — the encoding
 * `Trampoline-Mechanics.md` §6's unamended ladder would select for a far target
 * — purely so the harness can assert that its byte predicates REJECT that shape
 * while accepting the real one. Without this, "the published bytes are still a
 * 5-byte rel32" is a claim no arm in the gate has ever seen fail.
 */
__attribute__((noinline, used)) int hcr_lx_m2_widen_decoy(void) { return 13; }

static int (*volatile hcr_lx_m2_far_call)(void) = hcr_lx_m2_far_entry;

static void dump_hex(char *out, const unsigned char *bytes, size_t count) {
  static const char digits[] = "0123456789abcdef";
  size_t i;
  for (i = 0; i < count; ++i) {
    out[i * 2] = digits[(bytes[i] >> 4) & 0xf];
    out[i * 2 + 1] = digits[bytes[i] & 0xf];
  }
  out[count * 2] = '\0';
}

static uint64_t sled_address_for(uint64_t entry_address,
                                 unsigned long long *entry_count) {
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
    *entry_count = (unsigned long long)count;
  }
  return best;
}

/* ---------------------------------------------------------------------------
 * `exhaust` mode: fill every gap in +/-2 GiB around the window.
 *
 * Read the whole of `/proc/self/maps` FIRST, then map. Mapping changes the map,
 * and a reader that interleaved the two would walk a table it was mutating.
 *
 * The gap immediately below `[stack]` is never filled: that gap IS the stack's
 * room to grow, and taking it would kill the process for a reason that has
 * nothing to do with the milestone. The counters below are printed so the
 * harness can assert the reservation actually did something — a reservation
 * that filled nothing would make the refusal meaningless and the gate vacuous.
 * ------------------------------------------------------------------------- */

#define MAPS_BUFFER_BYTES (1024u * 256u)

struct reservation {
  unsigned long long gaps_filled;
  unsigned long long bytes_reserved;
  unsigned long long gaps_skipped_for_stack;
  unsigned long long map_failures;
  unsigned long long region_low;
  unsigned long long region_high;
};

static int fill_gap(uint64_t low, uint64_t high, struct reservation *out) {
  void *mapped;
  size_t length;
  if (high <= low) {
    return 0;
  }
  length = (size_t)(high - low);
  mapped = mmap((void *)(uintptr_t)low, length, PROT_NONE,
                MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE |
                    MAP_NORESERVE,
                -1, 0);
  if (mapped == MAP_FAILED) {
    out->map_failures += 1;
    return 0;
  }
  if ((uint64_t)(uintptr_t)mapped != low) {
    /* An old kernel treated MAP_FIXED_NOREPLACE as a hint. Undo it rather than
     * leave a mapping somewhere we did not intend. */
    munmap(mapped, length);
    out->map_failures += 1;
    return 0;
  }
  out->gaps_filled += 1;
  out->bytes_reserved += (unsigned long long)length;
  return 1;
}

static void reserve_region(uint64_t window_address, struct reservation *out) {
  static char buffer[MAPS_BUFFER_BYTES];
  FILE *maps;
  size_t used = 0;
  size_t n;
  char *line;
  char *save = NULL;
  uint64_t low;
  uint64_t high;
  uint64_t cursor;
  /* The reach the provider's own near-page probe uses is 0x60000000; the rel32
   * limit is 2 GiB. Reserve the full +/-2 GiB so nothing inside the limit is
   * left for an island. */
  const uint64_t reach = 0x80000000ull;

  long page = sysconf(_SC_PAGESIZE);
  uint64_t page_size = page > 0 ? (uint64_t)page : 4096ull;

  memset(out, 0, sizeof(*out));
  low = window_address > reach ? window_address - reach : 0x10000ull;
  high = window_address + reach;
  /* `MAP_FIXED_NOREPLACE` requires a page-aligned address, and the region's two
   * outer bounds are the only ones not already page-aligned — every other
   * boundary comes from `/proc/self/maps`, which reports pages. An unaligned
   * bound fails with EINVAL, which would be counted as a map failure and leave
   * that half of the region FREE, so the provider would find an island there
   * and the gate would report a state it never reached. */
  low &= ~(page_size - 1u);
  high = (high + page_size - 1u) & ~(page_size - 1u);
  out->region_low = (unsigned long long)low;
  out->region_high = (unsigned long long)high;

  /* Give malloc room to grow BEFORE the heap's gap disappears: the agent's
   * patch path allocates, and a blocked `brk` that also cannot fall back would
   * turn this gate into a memory failure wearing a refusal's label. */
  {
    void *scratch = malloc(8u * 1024u * 1024u);
    if (scratch != NULL) {
      memset(scratch, 0, 4096);
      free(scratch);
    }
  }

  maps = fopen("/proc/self/maps", "r");
  if (maps == NULL) {
    return;
  }
  while (used + 1 < sizeof(buffer)) {
    n = fread(buffer + used, 1, sizeof(buffer) - used - 1, maps);
    if (n == 0) {
      break;
    }
    used += n;
  }
  fclose(maps);
  buffer[used] = '\0';

  cursor = low;
  for (line = strtok_r(buffer, "\n", &save); line != NULL;
       line = strtok_r(NULL, "\n", &save)) {
    unsigned long long start = 0;
    unsigned long long end = 0;
    const char *is_stack = strstr(line, "[stack]");
    if (sscanf(line, "%llx-%llx", &start, &end) != 2) {
      continue;
    }
    if ((uint64_t)end <= low) {
      continue;
    }
    if ((uint64_t)start >= high) {
      break;
    }
    if ((uint64_t)start > cursor) {
      uint64_t gap_high = (uint64_t)start < high ? (uint64_t)start : high;
      if (is_stack != NULL) {
        out->gaps_skipped_for_stack += 1;
      } else {
        fill_gap(cursor, gap_high, out);
      }
    }
    if ((uint64_t)end > cursor) {
      cursor = (uint64_t)end;
    }
  }
  if (cursor < high) {
    fill_gap(cursor, high, out);
  }
}

/* ---------------------------------------------------------------------------
 * The widened-store demonstration (see `hcr_lx_m2_widen_decoy`).
 * ------------------------------------------------------------------------- */

static int write_widened_store(uint64_t window_address, uint64_t target) {
  long page = sysconf(_SC_PAGESIZE);
  size_t page_size = page > 0 ? (size_t)page : 4096u;
  uint64_t span_start = window_address & ~((uint64_t)page_size - 1u);
  uint64_t span_end =
      ((window_address + ISLAND_BYTES - 1) & ~((uint64_t)page_size - 1u)) +
      (uint64_t)page_size;
  uint8_t bytes[ISLAND_BYTES];
  bytes[0] = 0xff;
  bytes[1] = 0x25;
  bytes[2] = 0x00;
  bytes[3] = 0x00;
  bytes[4] = 0x00;
  bytes[5] = 0x00;
  memcpy(bytes + 6, &target, sizeof(target));
  if (mprotect((void *)(uintptr_t)span_start, (size_t)(span_end - span_start),
               PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
    return 0;
  }
  memcpy((void *)(uintptr_t)window_address, bytes, sizeof(bytes));
  if (mprotect((void *)(uintptr_t)span_start, (size_t)(span_end - span_start),
               PROT_READ | PROT_EXEC) != 0) {
    return 0;
  }
  return 1;
}

int main(int argc, char **argv) {
  const char *mode = argc > 1 ? argv[1] : "plain";
  repro_hcr_agent_symbol symbols[1];
  unsigned char before_bytes[DUMP_BYTES];
  unsigned char after_bytes[DUMP_BYTES];
  unsigned char island_bytes[ISLAND_BYTES];
  unsigned char decoy_before[DUMP_BYTES];
  unsigned char decoy_after[DUMP_BYTES];
  char before_hex[DUMP_BYTES * 2 + 1];
  char after_hex[DUMP_BYTES * 2 + 1];
  char island_hex[ISLAND_BYTES * 2 + 1];
  char decoy_before_hex[DUMP_BYTES * 2 + 1];
  char decoy_after_hex[DUMP_BYTES * 2 + 1];
  struct reservation reservation;
  unsigned long long patchable_entry_count = 0;
  uint64_t entry_address = (uint64_t)(uintptr_t)hcr_lx_m2_far_entry;
  uint64_t decoy_entry = (uint64_t)(uintptr_t)hcr_lx_m2_widen_decoy;
  uint64_t sled_address = sled_address_for(entry_address,
                                           &patchable_entry_count);
  uint64_t predicted_window;
  uint64_t rel32_destination = 0;
  uint64_t island_target = 0;
  int island_readable = 0;
  int widen_written = 0;
  int before;
  int after;
  int start_rc;
  int poll_rc;

  memset(&reservation, 0, sizeof(reservation));
  memset(island_bytes, 0, sizeof(island_bytes));
  memset(decoy_before, 0, sizeof(decoy_before));
  memset(decoy_after, 0, sizeof(decoy_after));

  /* The window this provider will choose, computed the same way it does:
   * the lowest 8-aligned boundary at or after the sled. The `exhaust` mode
   * needs it BEFORE the patch to know which +/-2 GiB region to fill. */
  predicted_window = (sled_address + 7u) & ~(uint64_t)7u;

  memcpy(before_bytes, (const void *)(uintptr_t)entry_address,
         sizeof(before_bytes));
  memcpy(decoy_before, (const void *)(uintptr_t)decoy_entry,
         sizeof(decoy_before));
  before = hcr_lx_m2_far_call();

  symbols[0].name = "hcr_lx_m2_far_entry";
  symbols[0].address = (void *)hcr_lx_m2_far_entry;
  start_rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), symbols, 1);

  if (strcmp(mode, "far") == 0) {
    repro_hcr_agent_force_far_patch_body_for_tests(1);
  } else if (strcmp(mode, "exhaust") == 0) {
    reserve_region(predicted_window, &reservation);
  }

  poll_rc = repro_hcr_agent_poll();

  memcpy(after_bytes, (const void *)(uintptr_t)entry_address,
         sizeof(after_bytes));
  after = hcr_lx_m2_far_call();

  /*
   * Decode the published jump OURSELVES. `window` is taken from the provider's
   * report only to locate the bytes; everything the harness asserts about where
   * the jump goes is decoded from the bytes themselves.
   */
  {
    uint64_t window = repro_hcr_agent_last_window_address_for_tests();
    if (window != 0 && after_bytes[0] != 0 &&
        window >= entry_address &&
        window + 8 <= entry_address + DUMP_BYTES) {
      const unsigned char *w = after_bytes + (window - entry_address);
      if (w[0] == 0xe9) {
        int32_t displacement;
        memcpy(&displacement, w + 1, sizeof(displacement));
        rel32_destination = window + 5u + (uint64_t)(int64_t)displacement;
        memcpy(island_bytes, (const void *)(uintptr_t)rel32_destination,
               sizeof(island_bytes));
        island_readable = 1;
        if (island_bytes[0] == 0xff && island_bytes[1] == 0x25) {
          memcpy(&island_target, island_bytes + 6, sizeof(island_target));
        }
      }
    }
  }

  if (strcmp(mode, "far") == 0) {
    unsigned long long decoy_entry_count = 0;
    uint64_t decoy_sled = sled_address_for(decoy_entry, &decoy_entry_count);
    uint64_t decoy_window = (decoy_sled + 7u) & ~(uint64_t)7u;
    if (decoy_sled != 0) {
      widen_written = write_widened_store(
          decoy_window, repro_hcr_agent_last_dispatch_address_for_tests());
    }
    memcpy(decoy_after, (const void *)(uintptr_t)decoy_entry,
           sizeof(decoy_after));
  }

  dump_hex(before_hex, before_bytes, sizeof(before_bytes));
  dump_hex(after_hex, after_bytes, sizeof(after_bytes));
  dump_hex(island_hex, island_bytes, sizeof(island_bytes));
  dump_hex(decoy_before_hex, decoy_before, sizeof(decoy_before));
  dump_hex(decoy_after_hex, decoy_after, sizeof(decoy_after));

  printf(
      "{\"schemaId\":\"reprobuild.hcr.hlx-m2.far-target-result.v1\","
      "\"mode\":\"%s\",\"before\":%d,\"after\":%d,"
      "\"startRc\":%d,\"pollRc\":%d,"
      "\"entryAddress\":\"0x%llx\",\"sledAddress\":\"0x%llx\","
      "\"predictedWindow\":\"0x%llx\","
      "\"patchableEntryCount\":%llu,"
      "\"agentWindowAddress\":\"0x%llx\","
      "\"agentDispatchAddress\":\"0x%llx\","
      "\"agentIslandAddress\":\"0x%llx\","
      "\"agentTrampolineKind\":%d,"
      "\"agentBodyDisplacement\":%lld,"
      "\"agentRefusal\":\"%s\","
      "\"agentIslandAllocCount\":%llu,"
      "\"agentGapScanCount\":%llu,\"agentGapHitCount\":%llu,"
      "\"rel32Destination\":\"0x%llx\","
      "\"islandReadable\":%s,\"islandBytesHex\":\"%s\","
      "\"islandTarget\":\"0x%llx\","
      "\"reservationGapsFilled\":%llu,"
      "\"reservationBytes\":%llu,"
      "\"reservationStackGapsSkipped\":%llu,"
      "\"reservationMapFailures\":%llu,"
      "\"reservationLow\":\"0x%llx\",\"reservationHigh\":\"0x%llx\","
      "\"widenWritten\":%s,"
      "\"decoyBytesBeforeHex\":\"%s\",\"decoyBytesAfterHex\":\"%s\","
      "\"entryBytesBeforeHex\":\"%s\",\"entryBytesAfterHex\":\"%s\"}\n",
      mode, before, after, start_rc, poll_rc,
      (unsigned long long)entry_address, (unsigned long long)sled_address,
      (unsigned long long)predicted_window, patchable_entry_count,
      repro_hcr_agent_last_window_address_for_tests(),
      repro_hcr_agent_last_dispatch_address_for_tests(),
      repro_hcr_agent_last_island_address_for_tests(),
      repro_hcr_agent_last_trampoline_kind_for_tests(),
      repro_hcr_agent_last_body_displacement_for_tests(),
      repro_hcr_agent_last_refusal_name_for_tests(),
      repro_hcr_agent_island_alloc_count_for_tests(),
      repro_hcr_agent_gap_scan_count_for_tests(),
      repro_hcr_agent_gap_hit_count_for_tests(),
      (unsigned long long)rel32_destination,
      island_readable ? "true" : "false", island_hex,
      (unsigned long long)island_target, reservation.gaps_filled,
      reservation.bytes_reserved, reservation.gaps_skipped_for_stack,
      reservation.map_failures, reservation.region_low,
      reservation.region_high, widen_written ? "true" : "false",
      decoy_before_hex, decoy_after_hex, before_hex, after_hex);
  fflush(stdout);
  return 0;
}
