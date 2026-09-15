#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../../../libs/repro_hcr_agent/c/repro_hcr_windows_pe_symbols.h"

typedef uintptr_t (__cdecl *ground_truth_fn)(void);
typedef int (__cdecl *call_private_fn)(int);

static __declspec(noinline) int hx_w3_exe_private(int value) {
  return value + 19;
}

static int parse_guid(const char *text, uint8_t result[16]) {
  unsigned int index;
  if (text == NULL || strlen(text) != 32) {
    return 0;
  }
  for (index = 0; index < 16; ++index) {
    unsigned int value;
    if (sscanf_s(text + index * 2, "%2x", &value) != 1) {
      return 0;
    }
    result[index] = (uint8_t)value;
  }
  return 1;
}

static void print_failure(const char *stage,
                          enum repro_hcr_windows_pe_status status) {
  printf("{\"ok\":false,\"stage\":\"%s\",\"status\":%u}\n",
         stage, (unsigned int)status);
}

int main(int argc, char **argv) {
  struct repro_hcr_windows_pdb_identity exe_identity;
  struct repro_hcr_windows_pdb_identity dll_identity;
  struct repro_hcr_windows_retained_module exe_module;
  struct repro_hcr_windows_retained_module dll_module;
  enum repro_hcr_windows_pe_status status;
  uintptr_t resolved_exe = 0;
  uintptr_t resolved_dll = 0;
  uintptr_t expected_dll;
  uint64_t exe_rva;
  uint64_t dll_rva;
  HMODULE dll;
  HMODULE duplicate_dll = NULL;
  ground_truth_fn ground_truth;
  call_private_fn call_private;
  int mutate;

  if (argc != 8) {
    fprintf(stderr,
      "usage: target EXE_GUID EXE_AGE EXE_RVA DLL_GUID DLL_AGE DLL_RVA MUTATE\n");
    return 64;
  }
  memset(&exe_identity, 0, sizeof(exe_identity));
  memset(&dll_identity, 0, sizeof(dll_identity));
  if (!parse_guid(argv[1], exe_identity.guid) ||
      !parse_guid(argv[4], dll_identity.guid)) {
    fprintf(stderr, "invalid GUID bytes\n");
    return 65;
  }
  exe_identity.age = (uint32_t)_strtoui64(argv[2], NULL, 10);
  exe_rva = _strtoui64(argv[3], NULL, 16);
  dll_identity.age = (uint32_t)_strtoui64(argv[5], NULL, 10);
  dll_rva = _strtoui64(argv[6], NULL, 16);
  mutate = atoi(argv[7]);
  if (mutate == 1) {
    dll_identity.guid[0] ^= 0x80;
  }

  dll = LoadLibraryW(L"hcr_w3_fixture.dll");
  if (dll == NULL) {
    print_failure("load-dll", REPRO_HCR_WINDOWS_PE_MODULE_ABSENT);
    return 66;
  }
  if (mutate == 2) {
    duplicate_dll = LoadLibraryW(L"hcr_w3_fixture_copy.dll");
    if (duplicate_dll == NULL || duplicate_dll == dll) {
      print_failure("load-duplicate-dll", REPRO_HCR_WINDOWS_PE_MODULE_ABSENT);
      return 74;
    }
  }
  ground_truth = (ground_truth_fn)GetProcAddress(dll, "hx_w3_dll_ground_truth");
  call_private = (call_private_fn)GetProcAddress(dll, "hx_w3_dll_call_private");
  if (ground_truth == NULL || call_private == NULL || call_private(7) != 30 ||
      hx_w3_exe_private(7) != 26) {
    print_failure("fixture-ground-truth", REPRO_HCR_WINDOWS_PE_INVALID_IMAGE);
    return 67;
  }
  expected_dll = ground_truth();

  status = repro_hcr_windows_pe_retain_module(&exe_identity, &exe_module);
  if (status != REPRO_HCR_WINDOWS_PE_OK) {
    print_failure("retain-exe", status);
    return mutate ? 0 : 68;
  }
  status = repro_hcr_windows_pe_resolve_rva(&exe_module, exe_rva, &resolved_exe);
  if (status != REPRO_HCR_WINDOWS_PE_OK) {
    print_failure("resolve-exe", status);
    return 69;
  }
  status = repro_hcr_windows_pe_retain_module(&dll_identity, &dll_module);
  if (status != REPRO_HCR_WINDOWS_PE_OK) {
    repro_hcr_windows_pe_release_module(&exe_module);
    print_failure("retain-dll", status);
    return mutate != 0 ? 0 : 70;
  }
  status = repro_hcr_windows_pe_resolve_rva(&dll_module, dll_rva, &resolved_dll);
  if (status != REPRO_HCR_WINDOWS_PE_OK) {
    print_failure("resolve-dll", status);
    return 71;
  }
  if (resolved_exe != (uintptr_t)&hx_w3_exe_private ||
      resolved_dll != expected_dll || exe_module.base == dll_module.base) {
    printf("{\"ok\":false,\"stage\":\"address-compare\","
           "\"exe_resolved\":\"0x%" PRIxPTR "\","
           "\"exe_expected\":\"0x%" PRIxPTR "\","
           "\"dll_resolved\":\"0x%" PRIxPTR "\","
           "\"dll_expected\":\"0x%" PRIxPTR "\"}\n",
           resolved_exe, (uintptr_t)&hx_w3_exe_private,
           resolved_dll, expected_dll);
    return 72;
  }
  printf("{\"ok\":true,\"exe_base\":\"0x%" PRIxPTR "\","
         "\"exe_address\":\"0x%" PRIxPTR "\","
         "\"dll_base\":\"0x%" PRIxPTR "\","
         "\"dll_address\":\"0x%" PRIxPTR "\"}\n",
         exe_module.base, resolved_exe, dll_module.base, resolved_dll);
  if (repro_hcr_windows_pe_release_module(&dll_module) !=
          REPRO_HCR_WINDOWS_PE_OK ||
      repro_hcr_windows_pe_release_module(&exe_module) !=
          REPRO_HCR_WINDOWS_PE_OK) {
    return 73;
  }
  FreeLibrary(dll);
  if (duplicate_dll != NULL) {
    FreeLibrary(duplicate_dll);
  }
  return 0;
}
