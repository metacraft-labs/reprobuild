/*
 * HLX-M2 real Linux x86_64 target: patch a function INSIDE A `dlopen`ed `.so`.
 *
 * The falsifier, stated as the added deliverable states it: this process loads
 * a real shared library at runtime, that library's function returns 11, the
 * agent applies a real direct entry patch over the real agent socket and wire
 * protocol, and the same call then returns 77.
 *
 * WHY THIS IS THE DEMO'S BLOCKER. `codetracer-flame-demo`'s FlameField is a
 * GDExtension (`flame_field.gdextension`, `entry_symbol = "flame_library_init"`),
 * i.e. a `dlopen`ed `.so`. `Home-Demo-Screencast.milestones.org` H2 patches a
 * particle function on the running flame, and that function is in the library,
 * not in `godot.linuxbsd.template_debug.x86_64.hcr`.
 *
 * WHAT MAKES THE EVIDENCE DISCRIMINATING rather than merely green. The main
 * executable is ALSO built patchable and carries its own, non-empty
 * `__patchable_function_entries`. So there are two tables in this process, and
 * the harness asserts:
 *
 *   - the executable's table is non-empty (the positive twin — without it,
 *     "the sled is not in the executable's table" is satisfied by an empty
 *     table, which is Verification-Harness-Traps.md trap 4a exactly);
 *   - the library's table is non-empty;
 *   - the two ranges are DISJOINT;
 *   - the sled the provider used lies inside the LIBRARY's range.
 *
 * A provider still reading `__start___patchable_function_entries` cannot
 * satisfy the last one, and the `REPRO_HCR_HLX_M2_FALSIFY_MAIN_EXECUTABLE_ONLY_SLED`
 * arm rebuilds exactly that provider to show the gate goes red.
 *
 * Everything the process prints about addresses is read by the process itself
 * from its own memory and its own `dladdr`/`dl_iterate_phdr`, never taken from
 * the agent's report. The agent's own view is printed alongside, under
 * `agent*` keys, so the two can be compared rather than conflated.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include <dlfcn.h>
#include <link.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "repro_hcr_agent.h"

extern const uintptr_t __start___patchable_function_entries[]
    __attribute__((weak));
extern const uintptr_t __stop___patchable_function_entries[]
    __attribute__((weak));

/* HLX-M2 evidence surface of the production agent (see repro_hcr_agent.c). */
extern const char *repro_hcr_agent_last_sled_status_name_for_tests(void);
extern const char *repro_hcr_agent_last_sled_object_path_for_tests(void);
extern int repro_hcr_agent_last_sled_is_main_executable_for_tests(void);
extern unsigned long long
repro_hcr_agent_last_sled_section_start_for_tests(void);
extern unsigned long long repro_hcr_agent_last_sled_entry_count_for_tests(void);
extern unsigned long long repro_hcr_agent_last_sled_load_bias_for_tests(void);
extern const char *repro_hcr_agent_last_refusal_name_for_tests(void);
extern int repro_hcr_agent_last_trampoline_kind_for_tests(void);

#define DUMP_BYTES 32

/*
 * A patchable function in the MAIN EXECUTABLE, so this image has a real,
 * non-empty `__patchable_function_entries` of its own. It is never patched; it
 * exists so that "the sled did not come from the executable's table" is a
 * statement about a table that has something in it.
 */
__attribute__((noinline, used)) int hcr_lx_m2_exe_decoy(void) { return 5; }

static void dump_hex(char *out, const unsigned char *bytes, size_t count) {
  static const char digits[] = "0123456789abcdef";
  size_t i;
  for (i = 0; i < count; ++i) {
    out[i * 2] = digits[(bytes[i] >> 4) & 0xf];
    out[i * 2 + 1] = digits[bytes[i] & 0xf];
  }
  out[count * 2] = '\0';
}

struct owner_probe {
  uint64_t address;
  int found;
  uint64_t bias;
  char name[512];
};

static int owner_callback(struct dl_phdr_info *info, size_t size, void *data) {
  struct owner_probe *probe = (struct owner_probe *)data;
  uint16_t i;
  (void)size;
  for (i = 0; i < info->dlpi_phnum; ++i) {
    const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
    uint64_t low;
    uint64_t high;
    if (ph->p_type != PT_LOAD) {
      continue;
    }
    low = (uint64_t)info->dlpi_addr + (uint64_t)ph->p_vaddr;
    high = low + (uint64_t)ph->p_memsz;
    if (probe->address < low || probe->address >= high) {
      continue;
    }
    probe->found = 1;
    probe->bias = (uint64_t)info->dlpi_addr;
    snprintf(probe->name, sizeof(probe->name), "%s",
             (info->dlpi_name == NULL || info->dlpi_name[0] == '\0')
                 ? "(main executable)"
                 : info->dlpi_name);
    return 1;
  }
  return 0;
}

int main(int argc, char **argv) {
  void *handle;
  int (*so_call)(void);
  void *(*so_entry_address)(void);
  void (*so_sled_table)(unsigned long long *, unsigned long long *,
                        unsigned long long *);
  unsigned long long lib_table_start = 0;
  unsigned long long lib_table_stop = 0;
  unsigned long long lib_table_count = 0;
  unsigned long long exe_table_start =
      (unsigned long long)(uintptr_t)__start___patchable_function_entries;
  unsigned long long exe_table_stop =
      (unsigned long long)(uintptr_t)__stop___patchable_function_entries;
  unsigned long long exe_table_count =
      (__start___patchable_function_entries != NULL &&
       __stop___patchable_function_entries != NULL &&
       __stop___patchable_function_entries >
           __start___patchable_function_entries)
          ? (unsigned long long)(__stop___patchable_function_entries -
                                 __start___patchable_function_entries)
          : 0ull;
  unsigned char before_bytes[DUMP_BYTES];
  unsigned char after_bytes[DUMP_BYTES];
  char before_hex[DUMP_BYTES * 2 + 1];
  char after_hex[DUMP_BYTES * 2 + 1];
  uint64_t entry_address;
  struct owner_probe probe;
  Dl_info dl_info;
  int dladdr_ok;
  int before;
  int after;
  int start_rc;
  int poll_rc;
  repro_hcr_agent_symbol symbols[1];

  if (argc < 2) {
    fprintf(stderr, "usage: %s <library path>\n", argv[0]);
    return 2;
  }

  handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (handle == NULL) {
    fprintf(stderr, "dlopen failed: %s\n", dlerror());
    return 3;
  }
  so_call = (int (*)(void))dlsym(handle, "hcr_lx_m2_so_call");
  so_entry_address = (void *(*)(void))dlsym(handle, "hcr_lx_m2_so_entry_address");
  so_sled_table = (void (*)(unsigned long long *, unsigned long long *,
                            unsigned long long *))
      dlsym(handle, "hcr_lx_m2_so_sled_table");
  if (so_call == NULL || so_entry_address == NULL || so_sled_table == NULL) {
    fprintf(stderr, "dlsym failed: %s\n", dlerror());
    return 4;
  }
  so_sled_table(&lib_table_start, &lib_table_stop, &lib_table_count);

  entry_address = (uint64_t)(uintptr_t)so_entry_address();
  memset(&probe, 0, sizeof(probe));
  probe.address = entry_address;
  dl_iterate_phdr(owner_callback, &probe);

  memset(&dl_info, 0, sizeof(dl_info));
  dladdr_ok = dladdr((void *)(uintptr_t)entry_address, &dl_info) != 0;

  memcpy(before_bytes, (const void *)(uintptr_t)entry_address,
         sizeof(before_bytes));
  before = so_call();

  /*
   * The symbol is deliberately NOT registered with the agent. The point of the
   * milestone is that the ELF pipeline finds it in the library on its own, so
   * handing the agent an address here would test the registration table instead
   * of the resolver. `symbols` carries the executable's decoy only, which is
   * never asked for and proves the registered table is not what answered.
   */
  symbols[0].name = "hcr_lx_m2_exe_decoy";
  symbols[0].address = (void *)hcr_lx_m2_exe_decoy;
  start_rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), symbols, 1);
  poll_rc = repro_hcr_agent_poll();

  memcpy(after_bytes, (const void *)(uintptr_t)entry_address,
         sizeof(after_bytes));
  after = so_call();

  dump_hex(before_hex, before_bytes, sizeof(before_bytes));
  dump_hex(after_hex, after_bytes, sizeof(after_bytes));

  printf(
      "{\"schemaId\":\"reprobuild.hcr.hlx-m2.shared-library-target-result.v1\","
      "\"before\":%d,\"after\":%d,"
      "\"startRc\":%d,\"pollRc\":%d,"
      "\"libraryPath\":\"%s\","
      "\"entryAddress\":\"0x%llx\","
      "\"ownerFound\":%s,\"ownerName\":\"%s\",\"ownerBias\":\"0x%llx\","
      "\"dladdrOk\":%s,\"dladdrObject\":\"%s\","
      "\"exeTableStart\":\"0x%llx\",\"exeTableStop\":\"0x%llx\","
      "\"exeTableCount\":%llu,"
      "\"libTableStart\":\"0x%llx\",\"libTableStop\":\"0x%llx\","
      "\"libTableCount\":%llu,"
      "\"exeDecoyAddress\":\"0x%llx\","
      "\"agentSledStatus\":\"%s\",\"agentSledObject\":\"%s\","
      "\"agentSledIsMainExecutable\":%s,"
      "\"agentSledSectionStart\":\"0x%llx\","
      "\"agentSledEntryCount\":%llu,"
      "\"agentSledLoadBias\":\"0x%llx\","
      "\"agentRefusal\":\"%s\",\"agentTrampolineKind\":%d,"
      "\"entryBytesBeforeHex\":\"%s\","
      "\"entryBytesAfterHex\":\"%s\"}\n",
      before, after, start_rc, poll_rc, argv[1],
      (unsigned long long)entry_address, probe.found ? "true" : "false",
      probe.name, (unsigned long long)probe.bias,
      dladdr_ok ? "true" : "false",
      (dladdr_ok && dl_info.dli_fname != NULL) ? dl_info.dli_fname : "",
      exe_table_start, exe_table_stop, exe_table_count, lib_table_start,
      lib_table_stop, lib_table_count,
      (unsigned long long)(uintptr_t)hcr_lx_m2_exe_decoy,
      repro_hcr_agent_last_sled_status_name_for_tests(),
      repro_hcr_agent_last_sled_object_path_for_tests(),
      repro_hcr_agent_last_sled_is_main_executable_for_tests() ? "true"
                                                              : "false",
      repro_hcr_agent_last_sled_section_start_for_tests(),
      repro_hcr_agent_last_sled_entry_count_for_tests(),
      repro_hcr_agent_last_sled_load_bias_for_tests(),
      repro_hcr_agent_last_refusal_name_for_tests(),
      repro_hcr_agent_last_trampoline_kind_for_tests(), before_hex, after_hex);
  fflush(stdout);
  return 0;
}
