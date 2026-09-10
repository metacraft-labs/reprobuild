/*
 * HLX-M1 build-id verification fixture (design §7.3).
 *
 * Reproduces the exact situation §7.3 exists for, and which a hot-reload
 * workflow reaches every single time: a process is running, its shared library
 * is REBUILT on disk, and the provider is then asked to resolve a symbol. The
 * on-disk file no longer describes the bytes in memory, so every address read
 * from it is wrong — and wrong in the worst way, because it is plausible.
 *
 * The fixture reports, for the same symbol, three things per phase:
 *
 *   1. what the resolver answers WITH the check on (the production setting);
 *   2. what it would have answered with the check off; and
 *   3. what the address actually is, from the running process's own `&fn`.
 *
 * (2) is what makes this gate non-vacuous. It is not enough to observe a
 * refusal — the refusal has to be shown to have PREVENTED something. After the
 * rebuild, (2) differs from (3), and that difference is the silent memory
 * corruption the check stops. `requireBuildId = 0` exists for that measurement
 * only; the agent always passes 1.
 *
 * The rebuild is driven by a command the gate supplies in REBUILD_CMD, so the
 * gate owns the compiler invocation and the fixture owns only the observation.
 */

#if !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hcr_lx_elf_fixture.h"
#include "repro_hcr_linux_elf_symbols.h"

static void emit_json_string(const char *value) {
  putchar('"');
  for (; value != NULL && *value != '\0'; ++value) {
    unsigned char c = (unsigned char)*value;
    if (c == '"' || c == '\\') {
      putchar('\\');
      putchar((int)c);
    } else if (c < 0x20) {
      printf("\\u%04x", (unsigned)c);
    } else {
      putchar((int)c);
    }
  }
  putchar('"');
}

static void resolve_and_print_in(const char *key, const char *symbol,
                                 const char *object_suffix,
                                 int require_build_id) {
  repro_hcr_elf_query query;
  repro_hcr_elf_resolution resolution;
  int rc;

  memset(&query, 0, sizeof(query));
  query.symbol_name = symbol;
  query.object_suffix = object_suffix;
  query.section_index = -1;
  query.require_build_id = require_build_id;

  rc = repro_hcr_elf_resolve(&query, &resolution);

  printf("      ");
  emit_json_string(key);
  printf(": {\"refusal\":%d,\"refusalName\":", rc);
  emit_json_string(repro_hcr_elf_refusal_name(rc));
  printf(",\"resolvedAddress\":%llu,\"linkValue\":%llu,\"objectsRefused\":%d",
         (unsigned long long)resolution.runtime_address,
         (unsigned long long)(resolution.candidate_count > 0
                                  ? resolution.candidates[0].link_value
                                  : 0),
         resolution.objects_refused);
  printf(",\"detail\":");
  emit_json_string(resolution.detail);
  printf("}");
}

static void resolve_and_print(const char *key, const char *symbol,
                              int require_build_id) {
  resolve_and_print_in(key, symbol, "libhcrlxelffixture.so", require_build_id);
}

/*
 * A function of this executable's OWN, so the last phase can ask about the main
 * executable rather than the shared library. Design §7.2 step 2 resolves that
 * object through `/proc/self/exe`, which is a different code path from a named
 * `dlpi_name`, and it has its own refusal.
 */
__attribute__((noinline)) int hcr_lx_probe_own_function(int value) {
  return value + 5;
}

static void phase(const char *name, const char *symbol, int last) {
  printf("    {\n      \"phase\": ");
  emit_json_string(name);
  /*
   * All three addresses, because the interesting question after a rebuild is
   * not merely "is the stale answer wrong" but "WHOSE function does it point
   * at". Generation two moves `static_helper` to where generation one put
   * `exported_helper`, so an unverified resolve returns the live address of a
   * DIFFERENT function — and a patch published there would overwrite that
   * one's entry while reporting success for the symbol that was asked for.
   */
  printf(",\n      \"truthAddress\": %llu", hcr_lx_lib_address_of(0));
  printf(",\n      \"truthHiddenAddress\": %llu", hcr_lx_lib_address_of(1));
  printf(",\n      \"truthExportedAddress\": %llu,\n",
         hcr_lx_lib_address_of(2));
  resolve_and_print("checked", symbol, 1);
  printf(",\n");
  resolve_and_print("unchecked", symbol, 0);
  printf("\n    }%s\n", last ? "" : ",");
}

int main(void) {
  const char *rebuild = getenv("REBUILD_CMD");
  int rebuild_status;

  /* Keep the library's functions referenced so the mapping is real. */
  if (hcr_lx_lib_sum() == 0) {
    return 4;
  }

  printf("{\n");
  printf("  \"schemaId\": \"reprobuild.hcr.hlx-m1.build-id-verification.v1\",\n");
  printf("  \"phases\": [\n");

  phase("before-rebuild", "hcr_lx_lib_static_helper", 0);

  if (rebuild == NULL || rebuild[0] == '\0') {
    /* A missing prerequisite must be LOUD. Emitting a report that silently
     * lacked the after-rebuild phase would let this fixture "pass" without
     * ever having tested anything. */
    fprintf(stderr, "REBUILD_CMD is not set; the build-id fixture cannot run\n");
    return 3;
  }
  rebuild_status = system(rebuild);
  if (rebuild_status != 0) {
    fprintf(stderr, "REBUILD_CMD failed with status %d\n", rebuild_status);
    return 3;
  }

  phase("after-rebuild", "hcr_lx_lib_static_helper", 0);

  /*
   * The OTHER way a rebuild reaches the provider (design §7.3).
   *
   * The main executable has no `dlpi_name`, so its path comes from
   * `readlink("/proc/self/exe")`. When the file behind the running image has
   * been replaced the kernel appends " (deleted)" to that link — which is
   * itself proof the on-disk file is not the mapped image, before any build-id
   * has even been read. That is `elf-object-image-replaced`, and it is a
   * distinct refusal from `elf-build-id-mismatch` because the failure is
   * detected at a different point and means a different thing.
   *
   * REPLACE_SELF_CMD moves a different file over this executable's own path.
   * The running process keeps its inode, so it continues normally.
   */
  {
    const char *replace_self = getenv("REPLACE_SELF_CMD");
    int replace_status;
    if (replace_self == NULL || replace_self[0] == '\0') {
      fprintf(stderr, "REPLACE_SELF_CMD is not set; the image-replacement "
                      "phase cannot run\n");
      return 3;
    }
    printf("    {\n      \"phase\": \"self-image-intact\",\n");
    printf("      \"truthAddress\": %llu,\n",
           (unsigned long long)(uintptr_t)&hcr_lx_probe_own_function);
    resolve_and_print_in("checked", "hcr_lx_probe_own_function",
                         "build-id-probe", 1);
    printf(",\n");
    resolve_and_print_in("unchecked", "hcr_lx_probe_own_function",
                         "build-id-probe", 0);
    printf("\n    },\n");

    replace_status = system(replace_self);
    if (replace_status != 0) {
      fprintf(stderr, "REPLACE_SELF_CMD failed with status %d\n",
              replace_status);
      return 3;
    }

    printf("    {\n      \"phase\": \"self-image-replaced\",\n");
    printf("      \"truthAddress\": %llu,\n",
           (unsigned long long)(uintptr_t)&hcr_lx_probe_own_function);
    resolve_and_print_in("checked", "hcr_lx_probe_own_function",
                         "build-id-probe", 1);
    printf(",\n");
    resolve_and_print_in("unchecked", "hcr_lx_probe_own_function",
                         "build-id-probe", 0);
    printf("\n    }\n");
  }

  printf("  ]\n}\n");
  return 0;
}
