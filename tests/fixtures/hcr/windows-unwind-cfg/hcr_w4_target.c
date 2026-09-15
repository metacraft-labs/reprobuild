#define _WIN32_WINNT 0x0A00
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../../../libs/repro_hcr_agent/c/repro_hcr_windows_unwind_cfg.h"

#define HX_W4_EXCEPTION ((DWORD)EXCEPTION_BREAKPOINT)

typedef int (__cdecl *hx_w4_patch_fn)(void (__cdecl *)(void), int);

static void *hx_w4_frames[64];
static USHORT hx_w4_frame_count;

static __declspec(noinline) void hx_w4_capture(void) {
  hx_w4_frame_count = CaptureStackBackTrace(
      0, (DWORD)(sizeof(hx_w4_frames) / sizeof(hx_w4_frames[0])),
      hx_w4_frames, NULL);
}

static __declspec(noinline) void hx_w4_control_frame(void) {
  volatile uint64_t stack_space[8];
  stack_space[0] = 0x1234;
  hx_w4_capture();
  __debugbreak();
  stack_space[1] = stack_space[0];
}

static int hx_w4_frame_in_region(uintptr_t base, size_t size) {
  USHORT index;
  for (index = 0; index < hx_w4_frame_count; ++index) {
    uintptr_t address = (uintptr_t)hx_w4_frames[index];
    if (address >= base && address < base + size) {
      return 1;
    }
  }
  return 0;
}

static int hx_w4_read_file(const char *path, uint8_t **bytes, size_t *size) {
  FILE *stream = NULL;
  long length;
  if (fopen_s(&stream, path, "rb") != 0 || stream == NULL) {
    return 0;
  }
  if (fseek(stream, 0, SEEK_END) != 0 || (length = ftell(stream)) <= 0 ||
      fseek(stream, 0, SEEK_SET) != 0) {
    fclose(stream);
    return 0;
  }
  *bytes = (uint8_t *)malloc((size_t)length);
  if (*bytes == NULL || fread(*bytes, 1, (size_t)length, stream) !=
      (size_t)length) {
    free(*bytes);
    *bytes = NULL;
    fclose(stream);
    return 0;
  }
  fclose(stream);
  *size = (size_t)length;
  return 1;
}

static void hx_w4_json_failure(const char *stage, unsigned long status) {
  printf("{\"ok\":false,\"stage\":\"%s\",\"status\":%lu,"
         "\"win32\":%lu}\n", stage, status, GetLastError());
  fflush(stdout);
}

int main(int argc, char **argv) {
  const char *mode;
  uint8_t *file_bytes = NULL;
  size_t file_size = 0;
  uint32_t table_offset;
  uint32_t table_count;
  uint32_t selected_entry;
  uint32_t entry_offsets[32];
  size_t allocation_size;
  SYSTEM_INFO system_info;
  uint8_t *region;
  DWORD old_protection;
  int cfg_enabled = 0;
  enum repro_hcr_windows_registration_status status;
  struct repro_hcr_windows_unwind_registration unwind;
  struct repro_hcr_windows_patch_registration prepared;
  DWORD64 lookup_base = 0;
  PRUNTIME_FUNCTION lookup_before;
  PRUNTIME_FUNCTION lookup_after;
  volatile hx_w4_patch_fn patch;
  void *prepared_address = NULL;
  int caught = 0;
  int control_caught = 0;
  uint32_t index;

  if (argc < 7) {
    fprintf(stderr,
      "usage: target MODE LAYOUT TABLE_OFFSET TABLE_COUNT SELECTED_ENTRY ENTRY...\n");
    return 64;
  }
  mode = argv[1];
  table_offset = (uint32_t)_strtoui64(argv[3], NULL, 10);
  table_count = (uint32_t)_strtoui64(argv[4], NULL, 10);
  selected_entry = (uint32_t)_strtoui64(argv[5], NULL, 10);
  if (table_count == 0 || table_count > 32 || argc != 6 + (int)table_count) {
    return 65;
  }
  for (index = 0; index < table_count; ++index) {
    entry_offsets[index] = (uint32_t)_strtoui64(argv[6 + index], NULL, 10);
  }
  if (!hx_w4_read_file(argv[2], &file_bytes, &file_size)) {
    return 66;
  }
  GetSystemInfo(&system_info);
  allocation_size = (file_size + system_info.dwPageSize - 1) &
      ~((size_t)system_info.dwPageSize - 1);
  region = (uint8_t *)VirtualAlloc(
      NULL, allocation_size, MEM_RESERVE | MEM_COMMIT,
      PAGE_EXECUTE_READ | PAGE_TARGETS_INVALID);
  if (region == NULL ||
      !VirtualProtect(region, allocation_size, PAGE_READWRITE, &old_protection)) {
    hx_w4_json_failure("allocate-region", GetLastError());
    return 67;
  }
  memcpy(region, file_bytes, file_size);
  free(file_bytes);
  if (strcmp(mode, "unsorted") == 0) {
    RUNTIME_FUNCTION temporary;
    PRUNTIME_FUNCTION table = (PRUNTIME_FUNCTION)(region + table_offset);
    if (table_count < 2) {
      return 68;
    }
    temporary = table[0];
    table[0] = table[1];
    table[1] = temporary;
  }
  if (!VirtualProtect(
          region, allocation_size,
          PAGE_EXECUTE_READ | PAGE_TARGETS_NO_UPDATE, &old_protection) ||
      !FlushInstructionCache(GetCurrentProcess(), region, allocation_size)) {
    hx_w4_json_failure("finalize-region", GetLastError());
    return 69;
  }

  status = repro_hcr_windows_cfg_enabled(&cfg_enabled);
  if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
    hx_w4_json_failure("query-cfg", status);
    return 70;
  }
  if (!cfg_enabled) {
    hx_w4_json_failure("cfg-not-enabled", 0);
    return 71;
  }
  if (strcmp(mode, "unsorted") == 0) {
    status = repro_hcr_windows_register_unwind(
        region, file_size, table_offset, table_count, &unwind);
    printf("{\"ok\":%s,\"stage\":\"unsorted\",\"status\":%u}\n",
      status == REPRO_HCR_WINDOWS_REGISTRATION_TABLE_UNSORTED ? "true" : "false",
      (unsigned int)status);
    return status == REPRO_HCR_WINDOWS_REGISTRATION_TABLE_UNSORTED ? 0 : 72;
  }

  memset(&prepared, 0, sizeof(prepared));
  if (strcmp(mode, "positive") == 0) {
    status = repro_hcr_windows_prepared_entry(
        &prepared, selected_entry, &prepared_address);
    if (status != REPRO_HCR_WINDOWS_REGISTRATION_NOT_REGISTERED) {
      hx_w4_json_failure("entry-before-prepare", status);
      return 85;
    }
    status = repro_hcr_windows_prepare_patch_region(
        region, allocation_size, file_size, table_offset, table_count,
        entry_offsets, table_count, &prepared);
    if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
      hx_w4_json_failure("prepare-region", status);
      return 86;
    }
    unwind = prepared.unwind;
    cfg_enabled = prepared.cfg_enabled;
  } else if (strcmp(mode, "no-unwind") != 0) {
    status = repro_hcr_windows_register_unwind(
        region, file_size, table_offset, table_count, &unwind);
    if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
      hx_w4_json_failure("register-unwind", status);
      return 73;
    }
  } else {
    memset(&unwind, 0, sizeof(unwind));
  }
  if (strcmp(mode, "positive") != 0 && strcmp(mode, "no-cfg") != 0) {
    status = repro_hcr_windows_set_cfg_targets(
        region, allocation_size, entry_offsets, table_count, 1, &cfg_enabled);
    if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK || !cfg_enabled) {
      hx_w4_json_failure("register-cfg", status);
      return 74;
    }
  }

  lookup_before = RtlLookupFunctionEntry(
      (DWORD64)(uintptr_t)(region + selected_entry + 1), &lookup_base, NULL);
  if (strcmp(mode, "no-unwind") != 0 &&
      (lookup_before == NULL || lookup_base != (DWORD64)(uintptr_t)region)) {
    hx_w4_json_failure("lookup-before", 0);
    return 75;
  }

  hx_w4_frame_count = 0;
  if (strcmp(mode, "positive") == 0) {
    status = repro_hcr_windows_prepared_entry(
        &prepared, selected_entry, &prepared_address);
    if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
      hx_w4_json_failure("entry-after-prepare", status);
      return 87;
    }
    patch = (hx_w4_patch_fn)prepared_address;
  } else {
    patch = (hx_w4_patch_fn)(region + selected_entry);
  }
  __try {
    (void)patch(hx_w4_capture, 7);
  } __except(GetExceptionCode() == HX_W4_EXCEPTION
                 ? EXCEPTION_EXECUTE_HANDLER
                 : EXCEPTION_CONTINUE_SEARCH) {
    caught = 1;
  }
  if (!caught || !hx_w4_frame_in_region((uintptr_t)region, file_size)) {
    hx_w4_json_failure("patched-unwind", 0);
    return 76;
  }
  if (strcmp(mode, "no-unwind") == 0) {
    printf("{\"ok\":false,\"stage\":\"unwind-registration-suppressed\","
           "\"handler_survived_unreliable_unwind\":true,"
           "\"lookup_was_absent\":%s}\n",
           lookup_before == NULL ? "true" : "false");
    return 82;
  }

  hx_w4_frame_count = 0;
  __try {
    hx_w4_control_frame();
  } __except(GetExceptionCode() == HX_W4_EXCEPTION
                 ? EXCEPTION_EXECUTE_HANDLER
                 : EXCEPTION_CONTINUE_SEARCH) {
    control_caught = 1;
  }
  if (!control_caught) {
    hx_w4_json_failure("control-unwind", 0);
    return 77;
  }

  if (strcmp(mode, "positive") != 0) {
    status = repro_hcr_windows_set_cfg_targets(
        region, allocation_size, entry_offsets, table_count, 0, &cfg_enabled);
    if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
      hx_w4_json_failure("invalidate-cfg", status);
      return 78;
    }
  }
  if (strcmp(mode, "keep-unwind") == 0) {
    lookup_base = 0;
    lookup_after = RtlLookupFunctionEntry(
        (DWORD64)(uintptr_t)(region + selected_entry + 1), &lookup_base, NULL);
    printf("{\"ok\":false,\"stage\":\"unwind-unregistration-suppressed\","
           "\"stale_entry_observed\":%s}\n",
           lookup_after != NULL ? "true" : "false");
    return lookup_after != NULL ? 83 : 84;
  }
  status = strcmp(mode, "positive") == 0
      ? repro_hcr_windows_rollback_patch_region(&prepared)
      : repro_hcr_windows_unregister_unwind(&unwind);
  if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
    hx_w4_json_failure("unregister-unwind", status);
    return 79;
  }
  lookup_base = 0;
  lookup_after = RtlLookupFunctionEntry(
      (DWORD64)(uintptr_t)(region + selected_entry + 1), &lookup_base, NULL);
  if (lookup_after != NULL) {
    hx_w4_json_failure("stale-unwind-entry", 0);
    return 80;
  }
  printf("{\"ok\":true,\"cfg_enabled\":true,"
         "\"patched_handler_reached\":true,"
         "\"patched_frame_observed\":true,"
         "\"control_handler_reached\":true,"
         "\"function_count\":%u,\"frame_count\":%u,"
         "\"lookup_removed\":true}\n",
         table_count, (unsigned int)hx_w4_frame_count);
  if (!VirtualFree(region, 0, MEM_RELEASE)) {
    return 81;
  }
  return 0;
}
