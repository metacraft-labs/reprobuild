/*
 * Main-executable half of the HLX-M1 ELF symbol-resolution fixture.
 *
 * Runs the PRODUCTION resolver (`repro_hcr_linux_elf_symbols.h`, included
 * directly — not a reimplementation) inside a real process, against that
 * process's own real loaded objects, and prints a JSON report the gate
 * asserts on.
 *
 * The observable is deliberately not the resolver's own opinion of itself: for
 * every symbol the report carries BOTH the address the resolver computed and
 * the address this process reports for the same function via `&fn`. A resolver
 * that returned a confident wrong answer fails, which is the whole point —
 * design §7.2's `dlpi_addr + st_value` is the single most common source of
 * "patched the wrong address".
 *
 * The three visibility classes are present in both the executable and the
 * shared library, because only the exported ones are reachable by `dlsym` and
 * the gate has to show that the other four are reached anyway (design §7.1).
 *
 * IFUNC is here too, with its resolver and its implementation as separately
 * addressable functions, so the gate can show that the refused `st_value` is
 * the resolver's address and NOT the implementation's.
 */

#if !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "hcr_lx_elf_fixture.h"
#include "repro_hcr_linux_elf_symbols.h"

/* --- the three visibility classes in the main executable ---------------- */

__attribute__((noinline)) static int hcr_lx_exe_static_helper(void) {
  return 10;
}

__attribute__((noinline, visibility("hidden"))) int hcr_lx_exe_hidden_helper(
    void) {
  return 11;
}

__attribute__((noinline)) int hcr_lx_exe_exported_helper(void) { return 12; }

/* A DATA symbol, so the resolver can be asked for a name that exists and is
 * not a function. "not found" and "found, but it is a variable" are different
 * answers and must not collapse into one. */
int hcr_lx_exe_data_slot = 99;

/* --- IFUNC, whose st_value is a resolver and not the implementation ------ */

__attribute__((noinline)) static int hcr_lx_ifunc_impl(void) { return 13; }

static void *hcr_lx_ifunc_resolver(void) { return (void *)hcr_lx_ifunc_impl; }

int hcr_lx_exe_ifunc_helper(void)
    __attribute__((ifunc("hcr_lx_ifunc_resolver")));

/* ------------------------------------------------------------------------ */

static volatile int hcr_lx_sink;

/* This executable's own path, so a query can be confined to the MAIN
 * EXECUTABLE. Confined that way, the shared library's exported function is an
 * UNDEFINED import here — which is a third distinct answer again. */
static char hcr_lx_self_path[4096];

static const char *hcr_lx_self(void) {
  ssize_t written =
      readlink("/proc/self/exe", hcr_lx_self_path, sizeof(hcr_lx_self_path) - 1);
  if (written <= 0) {
    return "";
  }
  hcr_lx_self_path[written] = '\0';
  return hcr_lx_self_path;
}

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

/*
 * Resolve one name and print the record. `truth` is the address this process
 * reports for the function, or 0 when the case is a refusal case and there is
 * no single true address to compare against.
 */
static void report(const char *label, const char *symbol,
                   const char *object_suffix, const char *source_file,
                   int require_build_id, unsigned long long truth,
                   int first) {
  repro_hcr_elf_query query;
  repro_hcr_elf_resolution resolution;
  int rc;

  memset(&query, 0, sizeof(query));
  query.symbol_name = symbol;
  query.object_suffix =
      (object_suffix != NULL && object_suffix[0] != '\0') ? object_suffix : NULL;
  query.source_file =
      (source_file != NULL && source_file[0] != '\0') ? source_file : NULL;
  query.section_index = -1;
  query.require_build_id = require_build_id;

  rc = repro_hcr_elf_resolve(&query, &resolution);

  if (!first) {
    printf(",\n");
  }
  printf("    {\"label\":");
  emit_json_string(label);
  printf(",\"symbol\":");
  emit_json_string(symbol);
  printf(",\"refusal\":%d,\"refusalName\":", rc);
  emit_json_string(repro_hcr_elf_refusal_name(rc));
  printf(",\"resolvedAddress\":%llu,\"truthAddress\":%llu",
         (unsigned long long)resolution.runtime_address, truth);
  printf(",\"matchCount\":%d,\"objectsSeen\":%d,\"objectsParsed\":%d",
         resolution.match_count, resolution.objects_seen,
         resolution.objects_parsed);
  printf(",\"objectsRefused\":%d,\"objectsSkipped\":%d,\"symbolsScanned\":%llu",
         resolution.objects_refused, resolution.objects_skipped,
         (unsigned long long)resolution.symbols_scanned);
  if (resolution.candidate_count > 0) {
    printf(",\"loadBias\":%llu,\"linkValue\":%llu,\"symbolSize\":%llu",
           (unsigned long long)resolution.candidates[0].load_bias,
           (unsigned long long)resolution.candidates[0].link_value,
           (unsigned long long)resolution.candidates[0].size);
    printf(",\"fromDynsym\":%d,\"sourceFile\":",
           (int)resolution.candidates[0].from_dynsym);
    emit_json_string(resolution.candidates[0].source_file);
    printf(",\"objectPath\":");
    emit_json_string(resolution.candidates[0].object_path);
    printf(",\"sectionName\":");
    emit_json_string(resolution.candidates[0].section_name);
    printf(",\"version\":");
    emit_json_string(resolution.candidates[0].version);
    printf(",\"defaultVersion\":%d",
           (int)resolution.candidates[0].default_version);
  } else {
    printf(",\"loadBias\":0,\"linkValue\":0,\"symbolSize\":0,\"fromDynsym\":-1");
    printf(",\"sourceFile\":\"\",\"objectPath\":\"\",\"sectionName\":\"\"");
    printf(",\"version\":\"\",\"defaultVersion\":-1");
  }
  printf(",\"detail\":");
  emit_json_string(resolution.detail);
  printf("}");
}

/*
 * The same record, produced through `repro_hcr_elf_resolve_in_file` instead of
 * `dl_iterate_phdr`, so a gate can point the PRODUCTION parser at a file this
 * process has not loaded — in particular a deliberately corrupted copy of one.
 *
 * Added by review 2026-09-10 for the malformed-table arm. The property it
 * exists to assert is negative and specific: a reader that cannot OPEN a
 * symbol table must not report that the symbol is not IN it.
 */
static void report_in_file(const char *label, const char *object_path,
                           const char *symbol, int first) {
  repro_hcr_elf_query query;
  repro_hcr_elf_resolution resolution;
  int rc;

  memset(&query, 0, sizeof(query));
  query.symbol_name = symbol;
  query.section_index = -1;
  query.require_build_id = 0;

  rc = repro_hcr_elf_resolve_in_file(object_path, 0, &query, &resolution);

  if (!first) {
    printf(",\n");
  }
  printf("    {\"label\":");
  emit_json_string(label);
  printf(",\"symbol\":");
  emit_json_string(symbol);
  printf(",\"refusal\":%d,\"refusalName\":", rc);
  emit_json_string(repro_hcr_elf_refusal_name(rc));
  printf(",\"resolvedAddress\":%llu,\"truthAddress\":0",
         (unsigned long long)resolution.runtime_address);
  printf(",\"matchCount\":%d,\"objectsSeen\":%d,\"objectsParsed\":%d",
         resolution.match_count, resolution.objects_seen,
         resolution.objects_parsed);
  printf(",\"objectsRefused\":%d,\"objectsSkipped\":%d,\"symbolsScanned\":%llu",
         resolution.objects_refused, resolution.objects_skipped,
         (unsigned long long)resolution.symbols_scanned);
  if (resolution.candidate_count > 0) {
    printf(",\"loadBias\":%llu,\"linkValue\":%llu,\"symbolSize\":%llu",
           (unsigned long long)resolution.candidates[0].load_bias,
           (unsigned long long)resolution.candidates[0].link_value,
           (unsigned long long)resolution.candidates[0].size);
    printf(",\"fromDynsym\":%d,\"sourceFile\":",
           (int)resolution.candidates[0].from_dynsym);
    emit_json_string(resolution.candidates[0].source_file);
    printf(",\"objectPath\":");
    emit_json_string(resolution.candidates[0].object_path);
    printf(",\"sectionName\":");
    emit_json_string(resolution.candidates[0].section_name);
    printf(",\"version\":");
    emit_json_string(resolution.candidates[0].version);
    printf(",\"defaultVersion\":%d",
           (int)resolution.candidates[0].default_version);
  } else {
    printf(",\"loadBias\":0,\"linkValue\":0,\"symbolSize\":0,\"fromDynsym\":-1");
    printf(",\"sourceFile\":\"\",\"objectPath\":\"\",\"sectionName\":\"\"");
    printf(",\"version\":\"\",\"defaultVersion\":-1");
  }
  printf(",\"detail\":");
  emit_json_string(resolution.detail);
  printf("}");
}

int main(int argc, char **argv) {
  int arg;

  /*
   * `--in-file LABEL PATH SYMBOL [LABEL PATH SYMBOL ...]` — the file-resolve
   * mode. Kept as a separate mode rather than folded into the default run so
   * the live `dl_iterate_phdr` arms above are not perturbed by it.
   */
  if (argc >= 2 && strcmp(argv[1], "--in-file") == 0) {
    int first = 1;
    printf("{\n");
    printf("  \"schemaId\": "
           "\"reprobuild.hcr.hlx-m1.elf-symbol-resolution.v1\",\n");
    printf("  \"sink\": 0,\n");
    printf("  \"ifuncResolverAddress\": 0,\n");
    printf("  \"ifuncImplementationAddress\": 0,\n");
    printf("  \"records\": [\n");
    for (arg = 2; arg + 2 < argc; arg += 3) {
      report_in_file(argv[arg], argv[arg + 1], argv[arg + 2], first);
      first = 0;
    }
    printf("\n  ]\n}\n");
    return 0;
  }

  /* Keep every fixture function referenced so nothing is optimised away and
   * the addresses printed below are the addresses that are really there. */
  /*
   * `hcr_lx_lib_exported_helper` is called DIRECTLY here, not merely reached
   * through `hcr_lx_lib_sum`. A call from this translation unit is what puts
   * it in the executable's own `.symtab` as an UNDEFINED import, which is the
   * state the "exe-import" record below is about. Reaching it only from inside
   * the library would leave it absent from the executable entirely, and the
   * record would report "not found" instead.
   */
  hcr_lx_sink = hcr_lx_exe_static_helper() + hcr_lx_exe_hidden_helper() +
                hcr_lx_exe_exported_helper() + hcr_lx_exe_ifunc_helper() +
                hcr_lx_lib_exported_helper() + hcr_lx_lib_sum() +
                hcr_lx_exe_data_slot;

  printf("{\n");
  printf("  \"schemaId\": \"reprobuild.hcr.hlx-m1.elf-symbol-resolution.v1\",\n");
  printf("  \"sink\": %d,\n", hcr_lx_sink);
  printf("  \"ifuncResolverAddress\": %llu,\n",
         (unsigned long long)(uintptr_t)&hcr_lx_ifunc_resolver);
  printf("  \"ifuncImplementationAddress\": %llu,\n",
         (unsigned long long)(uintptr_t)&hcr_lx_ifunc_impl);
  printf("  \"records\": [\n");

  report("exe-static", "hcr_lx_exe_static_helper", NULL, NULL, 1,
         (unsigned long long)(uintptr_t)&hcr_lx_exe_static_helper, 1);
  report("exe-hidden", "hcr_lx_exe_hidden_helper", NULL, NULL, 1,
         (unsigned long long)(uintptr_t)&hcr_lx_exe_hidden_helper, 0);
  report("exe-exported", "hcr_lx_exe_exported_helper", NULL, NULL, 1,
         (unsigned long long)(uintptr_t)&hcr_lx_exe_exported_helper, 0);
  report("lib-static", "hcr_lx_lib_static_helper", NULL, NULL, 1,
         hcr_lx_lib_address_of(0), 0);
  report("lib-hidden", "hcr_lx_lib_hidden_helper", NULL, NULL, 1,
         hcr_lx_lib_address_of(1), 0);
  report("lib-exported", "hcr_lx_lib_exported_helper", NULL, NULL, 1,
         hcr_lx_lib_address_of(2), 0);
  /* IFUNC: refused. `truth` carries the IMPLEMENTATION's address so the gate
   * can assert the refused st_value is the resolver's and not this one. */
  report("exe-ifunc", "hcr_lx_exe_ifunc_helper", NULL, NULL, 1,
         (unsigned long long)(uintptr_t)&hcr_lx_ifunc_impl, 0);
  report("absent", "hcr_lx_no_such_function_anywhere", NULL, NULL, 1, 0, 0);
  /* Exists, but is data. */
  report("exe-variable", "hcr_lx_exe_data_slot", NULL, NULL, 1, 0, 0);
  /* Exists in this process, but is an UNDEFINED import when the search is
   * confined to the main executable. */
  report("exe-import", "hcr_lx_lib_exported_helper", hcr_lx_self(), NULL, 1, 0,
         0);

  /*
   * Symbol versioning (design §7.2 step 4). Each extra argument is the BASE
   * name of a symbol the gate has found to exist in libc under BOTH a default
   * (`@@`) and a non-default (`@`) version. `.dynsym` carries no version in
   * the name at all — it is out of band in `.gnu.version`, resolved through
   * `.gnu.version_d` / `.gnu.version_r` — so this exercises the path a bare
   * `.symtab` suffix strip does not reach. The gate supplies the names rather
   * than the fixture hard-coding them, because which symbols glibc versions
   * changes between releases.
   */
  for (arg = 1; arg < argc; ++arg) {
    char label[128];
    snprintf(label, sizeof(label), "versioned-%s", argv[arg]);
    report(label, argv[arg], "libc.so.6", NULL, 0, 0, 0);
  }

  printf("\n  ]\n}\n");
  return 0;
}
