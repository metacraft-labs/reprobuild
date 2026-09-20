/*
 * HLX-M3 fixture: the prepare / commit split, re-patching, and rollback.
 *
 * Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §4.5, §11.2, §11.3.
 * Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M3.
 *
 * `allowed_mocks: none`. Everything below is real:
 *
 *   * real patchable victims in a real process, compiled by a real GCC with
 *     the real patchable build profile;
 *   * the PRODUCTION transaction — `repro_hcr_lx_txn_prepare` /
 *     `_commit` / `_rollback` in `repro_hcr_linux_x86_64.h` — reached through
 *     the existing no-mock probe shim, which re-exports the same `static`
 *     functions the live agent calls;
 *   * the real cross-patcher claim map from
 *     `codetracer-native-recorder/ct_inline_hook/claimed_guest_text.c`, so
 *     "no claim is leaked" is answered by the map itself;
 *   * real replacement bodies extracted from a real relocatable object;
 *   * real `/proc/self/maps`, so "no patch page is leaked" is answered by the
 *     kernel's own accounting of this process's anonymous executable mappings
 *     rather than by a counter the provider increments.
 *
 * THE ASSERTION THAT MATTERS IS ON BYTES. Every mode snapshots the target's
 * text around each victim's entry immediately before the operation under test
 * and again immediately after, and prints both as hex. The gate compares those
 * strings. A returned status is printed too, but it is never what the
 * byte-identity claim rests on — a provider that reported a refusal and wrote
 * anyway would be green on status and red on bytes, which is the whole point.
 *
 * The snapshot deliberately spans 16 bytes BEFORE the entry as well as 64
 * after: the publication rule is one naturally aligned 8-byte store inside the
 * sled, so a write that landed anywhere else in that span is a defect the
 * window-only comparison would miss.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* ---- the victims -------------------------------------------------------- */

__attribute__((noinline, noipa, used)) int hcr_lx_m3_victim_a(void) {
  return 11;
}

__attribute__((noinline, noipa, used)) int hcr_lx_m3_victim_b(void) {
  return 22;
}

__attribute__((noinline, noipa, used)) int hcr_lx_m3_victim_c(void) {
  return 33;
}

extern int hcr_lx_m3_plain_victim(void);  /* no sled: `absent-sled`   */
extern int hcr_lx_m3_short_victim(void);  /* 4-byte sled: `short-sled` */

/* ---- production provider, re-exported ----------------------------------- */

extern unsigned long long repro_hcr_lx_probe_sled_address_for_entry(
    unsigned long long entry_address);
extern const char *repro_hcr_lx_probe_refusal_name(int code);
extern int repro_hcr_lx_probe_last_refusal(void);
extern unsigned long long repro_hcr_lx_probe_last_window_address(void);
extern unsigned long long repro_hcr_lx_probe_last_original_word(void);
extern unsigned long long repro_hcr_lx_probe_last_published_word(void);
extern unsigned long long repro_hcr_lx_probe_last_generation(void);
extern int repro_hcr_lx_probe_last_old_code_retained(void);
extern int repro_hcr_lx_probe_last_retained_region_count(void);
extern size_t repro_hcr_lx_probe_page_size(void);
extern size_t repro_hcr_lx_probe_nop_length(const unsigned char *bytes,
                                            size_t avail);
extern void repro_hcr_lx_probe_set_pretend_sync_core_unavailable(int value);

extern void repro_hcr_lx_probe_txn_reset(void);
extern int repro_hcr_lx_probe_txn_add(unsigned long long entry_address,
                                      unsigned long long sled_address,
                                      const unsigned char *patch_bytes,
                                      size_t patch_len);
extern int repro_hcr_lx_probe_txn_prepare(void);
extern int repro_hcr_lx_probe_txn_commit(void);
extern int repro_hcr_lx_probe_txn_rollback(void);
extern int repro_hcr_lx_probe_txn_site_count(void);
extern int repro_hcr_lx_probe_txn_prepare_complete(void);
extern int repro_hcr_lx_probe_txn_commit_complete(void);
extern int repro_hcr_lx_probe_txn_rolled_back(void);
extern int repro_hcr_lx_probe_txn_published_count(void);
extern int repro_hcr_lx_probe_txn_restored_count(void);
extern int repro_hcr_lx_probe_txn_retained_body_count(void);
extern int repro_hcr_lx_probe_txn_freed_body_count(void);
extern int repro_hcr_lx_probe_txn_released_claim_count(void);
extern int repro_hcr_lx_probe_txn_refusal(void);
extern int repro_hcr_lx_probe_txn_failed_site(void);
extern unsigned long long repro_hcr_lx_probe_txn_window_address(int index);
extern unsigned long long repro_hcr_lx_probe_txn_original_word(int index);
extern unsigned long long repro_hcr_lx_probe_txn_published_word(int index);
extern unsigned long long repro_hcr_lx_probe_txn_dispatch_address(int index);
extern int repro_hcr_lx_probe_txn_site_published(int index);
extern int repro_hcr_lx_probe_txn_site_restored(int index);
extern void repro_hcr_lx_probe_set_fail_patch_page_alloc(int value);
extern void repro_hcr_lx_probe_set_commit_fault_site(int index);
extern int repro_hcr_lx_probe_site_is_live(unsigned long long entry_address);
extern unsigned long long repro_hcr_lx_probe_site_generation(
    unsigned long long entry_address);
extern unsigned int repro_hcr_lx_probe_site_retained_body_count(
    unsigned long long entry_address);

/* ---- the real claim map -------------------------------------------------- */

extern unsigned ct_claimed_guest_text_count(void);

/* ---- observation helpers ------------------------------------------------- */

#define SNAP_BEFORE 16
#define SNAP_AFTER 64
#define SNAP_BYTES (SNAP_BEFORE + SNAP_AFTER)

typedef struct victim {
  const char *name;
  int (*fn)(void);
  int original_value;
  uint8_t before[SNAP_BYTES];
  uint8_t after[SNAP_BYTES];
} victim;

static void snapshot(const victim *v, uint8_t *out) {
  const uint8_t *base = (const uint8_t *)(uintptr_t)v->fn - SNAP_BEFORE;
  memcpy(out, base, SNAP_BYTES);
}

static void print_hex(const uint8_t *bytes, size_t len) {
  size_t i;
  for (i = 0; i < len; ++i) {
    printf("%02x", bytes[i]);
  }
}

/*
 * How many anonymous executable mappings this process owns, read out of
 * `/proc/self/maps`.
 *
 * This is the leak check, and it is deliberately the KERNEL's answer rather
 * than the provider's `freed_body_count`. A provider that incremented its own
 * counter and forgot the `munmap` would agree with itself; the kernel would
 * not.
 *
 * WHAT COUNTS, WIDENED 2026-09-20 (HLX-M9), and the widening is not a
 * relaxation. This used to count ANONYMOUS executable mappings only, on the
 * reasoning that "every file-backed r-xp is a loaded object". That stopped
 * being true when provider-owned code pages became `memfd_create` dual
 * mappings: a patch body is now file-backed by a memfd named
 * `/memfd:repro-hcr-code`, so the anonymous count went to ZERO and this gate
 * went red against a provider that was leaking exactly as much as before.
 *
 * The property under test is "how many bytes of PROVIDER-OWNED executable
 * mapping does this process hold", and the qualifier that expresses it is now
 * two alternatives: an executable mapping with no pathname (the anonymous
 * fallback) OR one whose pathname names this provider's memfd. Matching the
 * NAME rather than merely "any file-backed r-xp" is what keeps the check as
 * narrow as it was — a loaded shared object still does not count.
 *
 * The memfd name is also a real improvement this incidentally records: a
 * retained patch body used to be an anonymous executable page indistinguishable
 * from any JIT's, and is now labelled in `/proc/self/maps`.
 *
 * `nfields >= 6` and not `== 6`, measured: the kernel writes the pathname as
 * `/memfd:repro-hcr-code (deleted)` — the fd is closed as soon as both views
 * exist — and the space makes that TWO tokens. `== 6` matched nothing and the
 * count stayed at the zero this widening exists to fix, which is the kind of
 * near-miss that reads as "no leak" rather than as "no measurement".
 */
#define REPRO_HCR_CODE_MEMFD_NAME "/memfd:repro-hcr-code"

static long long anon_exec_bytes(void) {
  int fd = open("/proc/self/maps", O_RDONLY);
  static char buffer[512 * 1024];
  ssize_t total = 0;
  ssize_t n;
  long long total_bytes = 0;
  size_t i = 0;
  size_t line_start = 0;

  if (fd < 0) {
    /* Not a silent zero: a zero would read as "nothing leaked". */
    return -1;
  }
  while ((n = read(fd, buffer + total, sizeof(buffer) - 1 - (size_t)total)) > 0) {
    total += n;
    if ((size_t)total >= sizeof(buffer) - 1) {
      break;
    }
  }
  close(fd);
  if (total <= 0) {
    return -1;
  }
  buffer[total] = '\0';

  for (i = 0; i <= (size_t)total; ++i) {
    if (buffer[i] != '\n' && buffer[i] != '\0') {
      continue;
    }
    {
      size_t len = i - line_start;
      char line[1024];
      if (len > 0 && len < sizeof(line)) {
        /* `addr perms offset dev inode [pathname]`. Anonymous means there is
         * no sixth field; executable means `x` in the permissions. Tokenised
         * rather than matched with `strstr`, because a PATHNAME containing
         * " r-xp " would otherwise be counted. */
        char *fields[8];
        int nfields = 0;
        char *save = NULL;
        char *token;
        memcpy(line, buffer + line_start, len);
        line[len] = '\0';
        token = strtok_r(line, " \t", &save);
        while (token != NULL && nfields < 8) {
          fields[nfields++] = token;
          token = strtok_r(NULL, " \t", &save);
        }
        if (strlen(fields[1]) >= 4 && fields[1][2] == 'x' &&
            (nfields == 5 ||
             (nfields >= 6 &&
              strncmp(fields[5], REPRO_HCR_CODE_MEMFD_NAME,
                      strlen(REPRO_HCR_CODE_MEMFD_NAME)) == 0))) {
          /* BYTES, not lines. The kernel merges adjacent anonymous mappings
           * with identical protection into ONE `/proc/self/maps` line, so a
           * line count cannot tell two retained patch pages from three. The
           * span can, and a leaked page is exactly one page of difference. */
          char *dash = strchr(fields[0], '-');
          if (dash != NULL) {
            unsigned long long lo, hi;
            *dash = '\0';
            lo = strtoull(fields[0], NULL, 16);
            hi = strtoull(dash + 1, NULL, 16);
            if (hi > lo) {
              total_bytes += (long long)(hi - lo);
            }
          }
        }
      }
    }
    line_start = i + 1;
  }
  return total_bytes;
}

static int hex_nibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static uint8_t *bytes_from_hex(const char *hex, size_t *out_len) {
  size_t len = strlen(hex);
  uint8_t *out;
  size_t i;
  if (len == 0 || (len % 2) != 0) {
    return NULL;
  }
  out = (uint8_t *)malloc(len / 2);
  if (out == NULL) {
    return NULL;
  }
  for (i = 0; i < len / 2; ++i) {
    int hi = hex_nibble(hex[2 * i]);
    int lo = hex_nibble(hex[2 * i + 1]);
    if (hi < 0 || lo < 0) {
      free(out);
      return NULL;
    }
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  *out_len = len / 2;
  return out;
}

/* ---- fixture state ------------------------------------------------------- */

static victim victims[5];
static int victim_count = 0;

static void register_victim(const char *name, int (*fn)(void), int value) {
  victims[victim_count].name = name;
  victims[victim_count].fn = fn;
  victims[victim_count].original_value = value;
  victim_count += 1;
}

static void snapshot_all_before(void) {
  int i;
  for (i = 0; i < victim_count; ++i) {
    snapshot(&victims[i], victims[i].before);
  }
}

static void snapshot_all_after(void) {
  int i;
  for (i = 0; i < victim_count; ++i) {
    snapshot(&victims[i], victims[i].after);
  }
}

static void print_victims(void) {
  int i;
  printf("\"victims\":[");
  for (i = 0; i < victim_count; ++i) {
    if (i > 0) {
      printf(",");
    }
    printf("{\"name\":\"%s\",\"entry\":\"0x%llx\",\"originalValue\":%d,"
           "\"value\":%d,\"before\":\"",
           victims[i].name,
           (unsigned long long)(uintptr_t)victims[i].fn,
           victims[i].original_value,
           victims[i].fn());
    print_hex(victims[i].before, SNAP_BYTES);
    printf("\",\"after\":\"");
    print_hex(victims[i].after, SNAP_BYTES);
    printf("\"}");
  }
  printf("]");
}

static void print_txn(void) {
  int i;
  printf(",\"txn\":{\"prepareComplete\":%d,\"commitComplete\":%d,"
         "\"rolledBack\":%d,\"publishedCount\":%d,\"restoredCount\":%d,"
         "\"retainedBodyCount\":%d,\"freedBodyCount\":%d,"
         "\"releasedClaimCount\":%d,\"refusal\":\"%s\",\"failedSite\":%d,"
         "\"sites\":[",
         repro_hcr_lx_probe_txn_prepare_complete(),
         repro_hcr_lx_probe_txn_commit_complete(),
         repro_hcr_lx_probe_txn_rolled_back(),
         repro_hcr_lx_probe_txn_published_count(),
         repro_hcr_lx_probe_txn_restored_count(),
         repro_hcr_lx_probe_txn_retained_body_count(),
         repro_hcr_lx_probe_txn_freed_body_count(),
         repro_hcr_lx_probe_txn_released_claim_count(),
         repro_hcr_lx_probe_refusal_name(repro_hcr_lx_probe_txn_refusal()),
         repro_hcr_lx_probe_txn_failed_site());
  for (i = 0; i < repro_hcr_lx_probe_txn_site_count(); ++i) {
    unsigned long long window = repro_hcr_lx_probe_txn_window_address(i);
    if (i > 0) {
      printf(",");
    }
    printf("{\"index\":%d,\"window\":\"0x%llx\",\"originalWord\":\"0x%llx\","
           "\"publishedWord\":\"0x%llx\",\"dispatch\":\"0x%llx\","
           "\"published\":%d,\"restored\":%d}",
           i, window,
           (unsigned long long)repro_hcr_lx_probe_txn_original_word(i),
           (unsigned long long)repro_hcr_lx_probe_txn_published_word(i),
           (unsigned long long)repro_hcr_lx_probe_txn_dispatch_address(i),
           repro_hcr_lx_probe_txn_site_published(i),
           repro_hcr_lx_probe_txn_site_restored(i));
  }
  printf("]}");
}

/* ---------------------------------------------------------------------------
 * Modes.
 * ------------------------------------------------------------------------- */

typedef struct patch_body {
  uint8_t *bytes;
  size_t len;
} patch_body;

static patch_body body_a;
static patch_body body_b;
static patch_body body_c;

static unsigned long long sled_of(int (*fn)(void)) {
  return repro_hcr_lx_probe_sled_address_for_entry(
      (unsigned long long)(uintptr_t)fn);
}

/*
 * Every prepare-failure arm has the same shape, so it is written once: take
 * the baseline snapshot, run prepare, take the after snapshot, print. The arm
 * differs only in which sites it adds and which lever (if any) it arms.
 */
static int run_prepare_arm(const char *mode) {
  size_t page_size = repro_hcr_lx_probe_page_size();
  int prepare_rc;
  int commit_rc = -1;
  /* Reported so the `non-nop-sled` arm can be shown to have pointed at bytes
   * that really are not NOPs, rather than be believed. */
  unsigned long long non_nop_address = 0;
  size_t non_nop_length = 0;
  int claims_before;
  int claims_after;
  long long maps_before;
  long long maps_after;

  repro_hcr_lx_probe_txn_reset();

  if (strcmp(mode, "prep-absent-sled") == 0) {
    /* A function from a translation unit compiled without
     * `-fpatchable-function-entry`. The lookup answers 0 and the provider
     * refuses; nothing about this is simulated. */
    repro_hcr_lx_probe_txn_add(
        (unsigned long long)(uintptr_t)hcr_lx_m3_plain_victim,
        sled_of(hcr_lx_m3_plain_victim), body_a.bytes, body_a.len);
  } else if (strcmp(mode, "prep-short-sled") == 0) {
    repro_hcr_lx_probe_txn_add(
        (unsigned long long)(uintptr_t)hcr_lx_m3_short_victim,
        sled_of(hcr_lx_m3_short_victim), body_a.bytes, body_a.len);
  } else if (strcmp(mode, "prep-non-nop-sled") == 0) {
    /*
     * A sled address pointing at REAL INSTRUCTIONS inside a victim's body.
     *
     * The address is FOUND, not guessed: the fixture walks forward from the
     * entry using the provider's OWN NOP decoder until it reaches a byte that
     * does not begin a NOP, and reports that address. Guessing an offset is
     * how the first draft of this arm silently passed — `entry + 32` landed in
     * the sixteen-byte alignment padding between two functions, which really
     * IS a NOP run, so the provider published there and the arm measured a
     * successful patch while claiming to measure a refusal.
     */
    const uint8_t *p = (const uint8_t *)(uintptr_t)hcr_lx_m3_victim_c;
    size_t offset = 0;
    while (offset < 64 &&
           repro_hcr_lx_probe_nop_length(p + offset, 64 - offset) != 0) {
      offset += repro_hcr_lx_probe_nop_length(p + offset, 64 - offset);
    }
    non_nop_address = (unsigned long long)(uintptr_t)(p + offset);
    non_nop_length = repro_hcr_lx_probe_nop_length(p + offset, 64 - offset);
    repro_hcr_lx_probe_txn_add(
        (unsigned long long)(uintptr_t)hcr_lx_m3_victim_c, non_nop_address,
        body_a.bytes, body_a.len);
  } else if (strcmp(mode, "prep-no-patch-memory") == 0) {
    repro_hcr_lx_probe_set_fail_patch_page_alloc(1);
    repro_hcr_lx_probe_txn_add(
        (unsigned long long)(uintptr_t)hcr_lx_m3_victim_a,
        sled_of(hcr_lx_m3_victim_a), body_a.bytes, body_a.len);
  } else if (strcmp(mode, "prep-oversized-body") == 0) {
    /* A body larger than a page has no publishable placement. Real bytes,
     * real refusal, no lever. */
    static uint8_t *oversized;
    oversized = (uint8_t *)malloc(page_size + 64);
    memset(oversized, 0x90, page_size + 64);
    repro_hcr_lx_probe_txn_add(
        (unsigned long long)(uintptr_t)hcr_lx_m3_victim_a,
        sled_of(hcr_lx_m3_victim_a), oversized, page_size + 64);
  } else if (strcmp(mode, "prep-sync-core-unavailable") == 0) {
    repro_hcr_lx_probe_set_pretend_sync_core_unavailable(1);
    repro_hcr_lx_probe_txn_add(
        (unsigned long long)(uintptr_t)hcr_lx_m3_victim_a,
        sled_of(hcr_lx_m3_victim_a), body_a.bytes, body_a.len);
  } else if (strcmp(mode, "prep-multi-site") == 0) {
    /* THE HEADLINE ARM. Site 0 is perfectly patchable; site 1 is not. The
     * prepare/commit split says site 0 must not be published, because prepare
     * did not fully succeed. Before HLX-M3 the provider had no set at all —
     * it applied one function at a time — so this is the arm the milestone is
     * actually about. */
    repro_hcr_lx_probe_txn_add(
        (unsigned long long)(uintptr_t)hcr_lx_m3_victim_a,
        sled_of(hcr_lx_m3_victim_a), body_a.bytes, body_a.len);
    repro_hcr_lx_probe_txn_add(
        (unsigned long long)(uintptr_t)hcr_lx_m3_plain_victim,
        sled_of(hcr_lx_m3_plain_victim), body_b.bytes, body_b.len);
  } else if (strcmp(mode, "prep-positive-control") == 0) {
    /* THE INSTRUMENT CONTROL. Same snapshot code, same comparison, a patch
     * that SUCCEEDS. If the before/after comparison were vacuous — the wrong
     * address, an empty string, a snapshot taken twice at the same moment —
     * this arm would also report "byte-identical" and the gate would be green
     * on a broken instrument. It is here so the other arms' green means
     * something. */
    repro_hcr_lx_probe_txn_add(
        (unsigned long long)(uintptr_t)hcr_lx_m3_victim_a,
        sled_of(hcr_lx_m3_victim_a), body_a.bytes, body_a.len);
  } else {
    fprintf(stderr, "unknown prepare arm: %s\n", mode);
    return 2;
  }

  claims_before = (int)ct_claimed_guest_text_count();
  maps_before = anon_exec_bytes();
  snapshot_all_before();
  prepare_rc = repro_hcr_lx_probe_txn_prepare();
  if (prepare_rc == 0) {
    commit_rc = repro_hcr_lx_probe_txn_commit();
  }
  snapshot_all_after();
  claims_after = (int)ct_claimed_guest_text_count();
  maps_after = anon_exec_bytes();

  printf("{\"mode\":\"%s\",\"prepareRc\":%d,\"prepareRefusal\":\"%s\","
         "\"commitRc\":%d,\"claimsBefore\":%d,\"claimsAfter\":%d,"
         "\"anonExecBefore\":%lld,\"anonExecAfter\":%lld,"
         "\"nonNopAddress\":\"0x%llx\",\"nonNopLength\":%d,",
         mode, prepare_rc, repro_hcr_lx_probe_refusal_name(prepare_rc),
         commit_rc, claims_before, claims_after, maps_before, maps_after,
         non_nop_address, (int)non_nop_length);
  print_victims();
  print_txn();
  printf("}\n");
  return 0;
}

/*
 * Re-patching (design §4.5). Three generations of the same function, the
 * superseded bodies executed directly to prove they were retained, then a
 * rollback that must land on the ORIGINAL word rather than on generation 2.
 */
static int run_repeat(void) {
  unsigned long long entry = (unsigned long long)(uintptr_t)hcr_lx_m3_victim_a;
  unsigned long long sled = sled_of(hcr_lx_m3_victim_a);
  unsigned long long window;
  uint8_t pristine[SNAP_BYTES];
  uint8_t after_gen[3][SNAP_BYTES];
  unsigned long long dispatch[3];
  unsigned long long word[3];
  int value[3];
  int retained_value[3];
  int rc;
  int g;
  patch_body *bodies[3];

  bodies[0] = &body_a;
  bodies[1] = &body_b;
  bodies[2] = &body_c;

  snapshot(&victims[0], pristine);

  for (g = 0; g < 3; ++g) {
    repro_hcr_lx_probe_txn_reset();
    repro_hcr_lx_probe_txn_add(entry, sled, bodies[g]->bytes, bodies[g]->len);
    rc = repro_hcr_lx_probe_txn_prepare();
    if (rc == 0) {
      rc = repro_hcr_lx_probe_txn_commit();
    }
    if (rc != 0) {
      printf("{\"mode\":\"repeat\",\"generation\":%d,\"refusal\":\"%s\"}\n",
             g + 1, repro_hcr_lx_probe_refusal_name(rc));
      return 1;
    }
    dispatch[g] = repro_hcr_lx_probe_txn_dispatch_address(0);
    word[g] = repro_hcr_lx_probe_txn_published_word(0);
    value[g] = hcr_lx_m3_victim_a();
    snapshot(&victims[0], after_gen[g]);
  }
  window = repro_hcr_lx_probe_last_window_address();

  /* §4.5: superseded bodies and islands are RETAINED, never freed. The proof
   * is not a counter — it is calling each generation's body at the address the
   * provider reported and observing the value it still returns. A freed page
   * would fault; a reused one would answer something else. */
  for (g = 0; g < 3; ++g) {
    int (*body)(void) = (int (*)(void))(uintptr_t)dispatch[g];
    retained_value[g] = body();
  }

  /* Rollback of the generation-3 transaction. §4.5 says this restores the
   * ORIGINAL saved word, not generation 2's. */
  rc = repro_hcr_lx_probe_txn_rollback();

  printf("{\"mode\":\"repeat\",\"rollbackRc\":%d,\"window\":\"0x%llx\","
         "\"generations\":[", rc, window);
  for (g = 0; g < 3; ++g) {
    printf("%s{\"generation\":%d,\"value\":%d,\"dispatch\":\"0x%llx\","
           "\"publishedWord\":\"0x%llx\",\"retainedBodyValue\":%d,\"text\":\"",
           g == 0 ? "" : ",", g + 1, value[g], dispatch[g], word[g],
           retained_value[g]);
    print_hex(after_gen[g], SNAP_BYTES);
    printf("\"}");
  }
  printf("],\"pristineText\":\"");
  print_hex(pristine, SNAP_BYTES);
  printf("\",\"rolledBackText\":\"");
  {
    uint8_t rolled[SNAP_BYTES];
    snapshot(&victims[0], rolled);
    print_hex(rolled, SNAP_BYTES);
  }
  printf("\",\"valueAfterRollback\":%d,\"siteLiveAfterRollback\":%d,"
         "\"claimsAfterRollback\":%u,\"oldCodeRetained\":%d,"
         "\"retainedRegionCount\":%d}\n",
         hcr_lx_m3_victim_a(),
         repro_hcr_lx_probe_site_is_live(entry),
         ct_claimed_guest_text_count(),
         repro_hcr_lx_probe_last_old_code_retained(),
         repro_hcr_lx_probe_last_retained_region_count());
  return 0;
}

/*
 * §4.5's refusal: a window whose bytes were altered behind the provider's back
 * matches neither admissible pre-state and must be REFUSED, never overwritten.
 *
 * The external modification is a real store of a real, executable word — the
 * victim's own ORIGINAL all-NOP word, put back by something that is not this
 * provider. That is the honest shape of "another patcher reverted it": the
 * process keeps running, and the provider must notice.
 */
static int run_repeat_external(void) {
  unsigned long long entry = (unsigned long long)(uintptr_t)hcr_lx_m3_victim_a;
  unsigned long long sled = sled_of(hcr_lx_m3_victim_a);
  unsigned long long window;
  unsigned long long original_word;
  uint8_t before[SNAP_BYTES];
  uint8_t after[SNAP_BYTES];
  size_t page_size = repro_hcr_lx_probe_page_size();
  int rc;

  repro_hcr_lx_probe_txn_reset();
  repro_hcr_lx_probe_txn_add(entry, sled, body_a.bytes, body_a.len);
  rc = repro_hcr_lx_probe_txn_prepare();
  if (rc == 0) {
    rc = repro_hcr_lx_probe_txn_commit();
  }
  if (rc != 0) {
    printf("{\"mode\":\"repeat-external\",\"setupRefusal\":\"%s\"}\n",
           repro_hcr_lx_probe_refusal_name(rc));
    return 1;
  }
  window = repro_hcr_lx_probe_last_window_address();
  original_word = repro_hcr_lx_probe_last_original_word();

  /* The modification behind the provider's back. Done with libc `mprotect`
   * and an ordinary store, i.e. by something that is not the provider. */
  {
    unsigned long long page = window & ~((unsigned long long)page_size - 1u);
    if (mprotect((void *)(uintptr_t)page, page_size,
                 PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
      fprintf(stderr, "external modification could not make text writable\n");
      return 2;
    }
    *(volatile uint64_t *)(uintptr_t)window = original_word;
    if (mprotect((void *)(uintptr_t)page, page_size,
                 PROT_READ | PROT_EXEC) != 0) {
      fprintf(stderr, "external modification could not restore protection\n");
      return 2;
    }
  }

  snapshot(&victims[0], before);
  repro_hcr_lx_probe_txn_reset();
  repro_hcr_lx_probe_txn_add(entry, sled, body_b.bytes, body_b.len);
  rc = repro_hcr_lx_probe_txn_prepare();
  if (rc == 0) {
    rc = repro_hcr_lx_probe_txn_commit();
  }
  snapshot(&victims[0], after);

  printf("{\"mode\":\"repeat-external\",\"rc\":%d,\"refusal\":\"%s\","
         "\"window\":\"0x%llx\",\"value\":%d,\"before\":\"",
         rc, repro_hcr_lx_probe_refusal_name(rc), window,
         hcr_lx_m3_victim_a());
  print_hex(before, SNAP_BYTES);
  printf("\",\"after\":\"");
  print_hex(after, SNAP_BYTES);
  printf("\"}\n");
  return 0;
}

/*
 * Commit failure partway through a multi-function set. `fault` names the site
 * index whose text-protection transient is refused, so N = `fault` sites are
 * published before the failure and all N must come back.
 */
static int run_commit(int fault) {
  unsigned long long entries[3];
  unsigned long long sleds[3];
  patch_body *bodies[3];
  uint8_t before[3][SNAP_BYTES];
  uint8_t after[3][SNAP_BYTES];
  int claims_before, claims_after;
  long long maps_before, maps_after;
  int prepare_rc, commit_rc;
  int i;

  entries[0] = (unsigned long long)(uintptr_t)hcr_lx_m3_victim_a;
  entries[1] = (unsigned long long)(uintptr_t)hcr_lx_m3_victim_b;
  entries[2] = (unsigned long long)(uintptr_t)hcr_lx_m3_victim_c;
  sleds[0] = sled_of(hcr_lx_m3_victim_a);
  sleds[1] = sled_of(hcr_lx_m3_victim_b);
  sleds[2] = sled_of(hcr_lx_m3_victim_c);
  bodies[0] = &body_a;
  bodies[1] = &body_b;
  bodies[2] = &body_c;

  repro_hcr_lx_probe_txn_reset();
  for (i = 0; i < 3; ++i) {
    repro_hcr_lx_probe_txn_add(entries[i], sleds[i], bodies[i]->bytes,
                               bodies[i]->len);
  }
  repro_hcr_lx_probe_set_commit_fault_site(fault);

  claims_before = (int)ct_claimed_guest_text_count();
  maps_before = anon_exec_bytes();
  for (i = 0; i < 3; ++i) {
    snapshot(&victims[i], before[i]);
  }
  prepare_rc = repro_hcr_lx_probe_txn_prepare();
  commit_rc = prepare_rc == 0 ? repro_hcr_lx_probe_txn_commit() : -1;
  for (i = 0; i < 3; ++i) {
    snapshot(&victims[i], after[i]);
  }
  claims_after = (int)ct_claimed_guest_text_count();
  maps_after = anon_exec_bytes();

  printf("{\"mode\":\"commit\",\"fault\":%d,\"prepareRc\":%d,\"commitRc\":%d,"
         "\"commitRefusal\":\"%s\",\"claimsBefore\":%d,\"claimsAfter\":%d,"
         "\"anonExecBefore\":%lld,\"anonExecAfter\":%lld,\"functions\":[",
         fault, prepare_rc, commit_rc,
         repro_hcr_lx_probe_refusal_name(commit_rc), claims_before,
         claims_after, maps_before, maps_after);
  for (i = 0; i < 3; ++i) {
    printf("%s{\"name\":\"%s\",\"entry\":\"0x%llx\",\"originalValue\":%d,"
           "\"value\":%d,"
           "\"siteLive\":%d,\"published\":%d,\"restored\":%d,\"before\":\"",
           i == 0 ? "" : ",", victims[i].name, entries[i],
           victims[i].original_value,
           victims[i].fn(), repro_hcr_lx_probe_site_is_live(entries[i]),
           repro_hcr_lx_probe_txn_site_published(i),
           repro_hcr_lx_probe_txn_site_restored(i));
    print_hex(before[i], SNAP_BYTES);
    printf("\",\"after\":\"");
    print_hex(after[i], SNAP_BYTES);
    printf("\"}");
  }
  printf("]");
  print_txn();
  printf("}\n");
  return 0;
}

int main(int argc, char **argv) {
  const char *mode;
  if (argc < 5) {
    fprintf(stderr,
            "usage: %s <mode> <bodyAHex> <bodyBHex> <bodyCHex> [fault]\n",
            argv[0]);
    return 2;
  }
  mode = argv[1];
  body_a.bytes = bytes_from_hex(argv[2], &body_a.len);
  body_b.bytes = bytes_from_hex(argv[3], &body_b.len);
  body_c.bytes = bytes_from_hex(argv[4], &body_c.len);
  if (body_a.bytes == NULL || body_b.bytes == NULL || body_c.bytes == NULL) {
    fprintf(stderr, "patch bodies are not valid hex\n");
    return 2;
  }

  register_victim("victim_a", hcr_lx_m3_victim_a, 11);
  register_victim("victim_b", hcr_lx_m3_victim_b, 22);
  register_victim("victim_c", hcr_lx_m3_victim_c, 33);
  register_victim("plain_victim", hcr_lx_m3_plain_victim, 44);
  register_victim("short_victim", hcr_lx_m3_short_victim, 55);

  if (strncmp(mode, "prep-", 5) == 0) {
    return run_prepare_arm(mode);
  }
  if (strcmp(mode, "repeat") == 0) {
    return run_repeat();
  }
  if (strcmp(mode, "repeat-external") == 0) {
    return run_repeat_external();
  }
  if (strcmp(mode, "commit") == 0) {
    int fault = argc >= 6 ? atoi(argv[5]) : -1;
    return run_commit(fault);
  }
  fprintf(stderr, "unknown mode: %s\n", mode);
  return 2;
}
