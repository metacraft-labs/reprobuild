/*
 * HLX-M9 — the target for
 * `integration_hcr_linux_provider_code_pages_are_sealed_dual_mappings`.
 *
 * WHAT IT MEASURES, AND WHY EACH OBSERVATION IS THERE.
 *
 * The provider's own code pages (patch bodies, island pages) are a
 * `memfd_create` dual mapping: the exec view is `MAP_PRIVATE|PROT_READ|
 * PROT_EXEC` and is never writable, the writer view is a separate
 * `MAP_SHARED|PROT_READ|PROT_WRITE` alias, and a page that will take no more
 * writes gets `F_SEAL_WRITE`. This target applies a REAL patch through the
 * production provider and then reports, from the KERNEL rather than from the
 * provider's own bookkeeping:
 *
 *   dispatchPerms     the permissions of the mapping the patch body executes
 *                     from, read out of /proc/self/maps. Must be `r-xp` — a
 *                     `w` would mean the provider left a writable executable
 *                     mapping, which is what the dual mapping exists to avoid.
 *   dispatchBacking   the pathname of that mapping. `/memfd:repro-hcr-code`
 *                     when the dual mapping is in use, empty when the
 *                     anonymous fallback is.
 *   writableAliasBytes  how many bytes of WRITABLE mapping this process holds
 *                     that alias the patch body's memfd. Must be 0 after the
 *                     patch: the writer view is unmapped before sealing.
 *
 * `--anonymous` forces the pre-HLX-M9 anonymous path on the same binary, which
 * is the control: it must still patch, and it must report a mapping with no
 * name.
 *
 * `--mdwe` applies `prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN)` BEFORE the
 * page is allocated. That is the arm that separates the two mechanisms: the
 * anonymous path's `mprotect(PROT_READ|PROT_EXEC)` is refused by the kernel and
 * the page allocation fails, while the dual mapping never asks for an exec gain
 * and succeeds. Both are reported rather than asserted here; the gate decides.
 *
 * No skips. Every failure path exits non-zero with a named reason.
 */

#define _GNU_SOURCE

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <fcntl.h>
#include <sys/prctl.h>

#include "repro_hcr_agent.h"

#ifndef PR_SET_MDWE
#define PR_SET_MDWE 65
#endif
#ifndef PR_MDWE_REFUSE_EXEC_GAIN
#define PR_MDWE_REFUSE_EXEC_GAIN 1
#endif

#define HCR_M9F_POLL_BUDGET 6000

int patchable_value(int iteration);

static int (*volatile hcr_m9f_call)(int) = patchable_value;

/* One line of /proc/self/maps, tokenised. Fields are
 * `addr perms offset dev inode [pathname [(deleted)]]`. */
typedef struct maps_line {
  unsigned long long lo, hi;
  char perms[8];
  char path[256];
} maps_line;

static int maps_for_address(unsigned long long address, maps_line *out) {
  FILE *f = fopen("/proc/self/maps", "r");
  char line[1024];
  int found = 0;
  if (f == NULL) {
    return -1;
  }
  while (fgets(line, sizeof(line), f) != NULL) {
    unsigned long long lo = 0, hi = 0;
    char perms[8] = {0};
    char path[256] = {0};
    if (sscanf(line, "%llx-%llx %7s %*s %*s %*s %255[^\n]", &lo, &hi, perms,
               path) < 3) {
      continue;
    }
    if (address >= lo && address < hi) {
      out->lo = lo;
      out->hi = hi;
      snprintf(out->perms, sizeof(out->perms), "%s", perms);
      /* Trim leading spaces the `%[^\n]` conversion keeps. */
      {
        char *p = path;
        while (*p == ' ' || *p == '\t') p++;
        snprintf(out->path, sizeof(out->path), "%s", p);
      }
      found = 1;
      break;
    }
  }
  fclose(f);
  return found;
}

/* Bytes of WRITABLE mapping in this process whose pathname names the
 * provider's code memfd. The seal makes a new one impossible; this catches an
 * OLD one the provider forgot to unmap, which the seal would then have been
 * refused for anyway — so a non-zero value here and a sealed page cannot both
 * be true, and asserting both is what makes the pair meaningful. */
static long long writable_provider_alias_bytes(void) {
  FILE *f = fopen("/proc/self/maps", "r");
  char line[1024];
  long long total = 0;
  if (f == NULL) {
    return -1;
  }
  while (fgets(line, sizeof(line), f) != NULL) {
    unsigned long long lo = 0, hi = 0;
    char perms[8] = {0};
    char path[256] = {0};
    if (sscanf(line, "%llx-%llx %7s %*s %*s %*s %255[^\n]", &lo, &hi, perms,
               path) < 4) {
      continue;
    }
    if (strstr(path, "/memfd:repro-hcr-code") == NULL) {
      continue;
    }
    if (strlen(perms) >= 2 && perms[1] == 'w' && hi > lo) {
      total += (long long)(hi - lo);
    }
  }
  fclose(f);
  return total;
}

int main(int argc, char **argv) {
  repro_hcr_agent_symbol symbols[1];
  int before_value, after_value, start_rc, polls, i;
  int mdwe = 0, anonymous = 0, applied = 0;
  maps_line dispatch;
  unsigned long long dispatch_address;

  memset(&dispatch, 0, sizeof(dispatch));

  for (i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--mdwe") == 0) {
      mdwe = 1;
    } else if (strcmp(argv[i], "--anonymous") == 0) {
      anonymous = 1;
    } else {
      fprintf(stderr, "hcr_lx_m9_memfd_target: unknown flag %s\n", argv[i]);
      return 2;
    }
  }

  before_value = hcr_m9f_call(0);

  if (anonymous) {
    /* The pre-HLX-M9 mechanism, on the same binary. Set through the
     * environment rather than an exported setter, matching every other lever
     * in this provider, and read by the agent at publication time. */
    setenv("REPRO_HCR_TEST_FORCE_ANONYMOUS_CODE_PAGES", "1", 1);
  }
  if (mdwe) {
    if (prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN, 0, 0, 0) != 0) {
      fprintf(stderr,
              "hcr_lx_m9_memfd_target: prctl(PR_SET_MDWE) failed; this kernel "
              "cannot express the hardening this fixture needs (Linux 6.3+)\n");
      return 3;
    }
  }

  symbols[0].name = "patchable_value";
  symbols[0].address = (void *)patchable_value;
  start_rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), symbols, 1);
  if (start_rc != 0) {
    fprintf(stderr, "hcr_lx_m9_memfd_target: agent start returned %d\n",
            start_rc);
    return 4;
  }

  for (polls = 0; polls < HCR_M9F_POLL_BUDGET; ++polls) {
    (void)repro_hcr_agent_poll_nonblocking();
    if (repro_hcr_rb_last_dispatch_address() != 0) {
      applied = 1;
      break;
    }
    usleep(1000);
  }

  after_value = hcr_m9f_call(0);
  dispatch_address = (unsigned long long)repro_hcr_rb_last_dispatch_address();
  if (dispatch_address != 0) {
    (void)maps_for_address(dispatch_address, &dispatch);
  }

  printf("{\"schemaId\":"
         "\"reprobuild.hcr.hlx-m9.provider-code-page-result.v1\",");
  printf("\"mdwe\":%s,\"anonymous\":%s,\"applied\":%s,",
         mdwe ? "true" : "false", anonymous ? "true" : "false",
         applied ? "true" : "false");
  printf("\"before\":%d,\"after\":%d,", before_value, after_value);
  printf("\"dispatchAddress\":\"0x%llx\",", dispatch_address);
  printf("\"dispatchPerms\":\"%s\",", dispatch.perms);
  printf("\"dispatchBacking\":\"%s\",", dispatch.path);
  printf("\"writableAliasBytes\":%lld,", writable_provider_alias_bytes());
  printf("\"dualPages\":%llu,",
         (unsigned long long)repro_hcr_agent_dual_code_page_count());
  printf("\"sealedPages\":%llu,",
         (unsigned long long)repro_hcr_agent_sealed_code_page_count());
  printf("\"fallbackPages\":%llu,",
         (unsigned long long)repro_hcr_agent_fallback_code_page_count());
  printf("\"codeSwapped\":%s}\n",
         repro_hcr_rb_last_code_swapped() ? "true" : "false");
  fflush(stdout);
  return 0;
}
