#ifndef REPRO_HCR_WINDOWS_UNWIND_CFG_H
#define REPRO_HCR_WINDOWS_UNWIND_CFG_H

#if !defined(_WIN32) || (!defined(_M_X64) && !defined(__x86_64__))
#error "repro_hcr_windows_unwind_cfg.h requires Windows x86_64"
#endif

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <stdint.h>
#include <string.h>

enum repro_hcr_windows_registration_status {
  REPRO_HCR_WINDOWS_REGISTRATION_OK = 0,
  REPRO_HCR_WINDOWS_REGISTRATION_INVALID_ARGUMENT = 1,
  REPRO_HCR_WINDOWS_REGISTRATION_TABLE_OUT_OF_RANGE = 2,
  REPRO_HCR_WINDOWS_REGISTRATION_TABLE_UNSORTED = 3,
  REPRO_HCR_WINDOWS_REGISTRATION_FUNCTION_RANGE_INVALID = 4,
  REPRO_HCR_WINDOWS_REGISTRATION_UNWIND_INFO_INVALID = 5,
  REPRO_HCR_WINDOWS_REGISTRATION_RTL_ADD_FAILED = 6,
  REPRO_HCR_WINDOWS_REGISTRATION_NOT_REGISTERED = 7,
  REPRO_HCR_WINDOWS_REGISTRATION_RTL_DELETE_FAILED = 8,
  REPRO_HCR_WINDOWS_REGISTRATION_CFG_QUERY_FAILED = 9,
  REPRO_HCR_WINDOWS_REGISTRATION_CFG_TARGET_INVALID = 10,
  REPRO_HCR_WINDOWS_REGISTRATION_CFG_UPDATE_FAILED = 11
};

struct repro_hcr_windows_unwind_registration {
  PRUNTIME_FUNCTION table;
  DWORD entry_count;
  DWORD64 region_base;
  int registered;
};

struct repro_hcr_windows_patch_registration {
  struct repro_hcr_windows_unwind_registration unwind;
  void *region;
  size_t region_size;
  uint32_t *entry_offsets;
  uint32_t entry_count;
  int cfg_enabled;
  int prepared;
};

static int repro_hcr_windows_registration_range_ok(
    size_t region_size, uint64_t offset, uint64_t length) {
  return offset <= region_size && length <= region_size - (size_t)offset;
}

static enum repro_hcr_windows_registration_status
repro_hcr_windows_validate_unwind_info(
    const uint8_t *region, size_t region_size, DWORD unwind_rva) {
  const uint8_t *info;
  size_t slots;
  size_t bytes;
  uint8_t flags;
  if (!repro_hcr_windows_registration_range_ok(region_size, unwind_rva, 4)) {
    return REPRO_HCR_WINDOWS_REGISTRATION_UNWIND_INFO_INVALID;
  }
  info = region + unwind_rva;
  if ((info[0] & 7u) != 1u) {
    return REPRO_HCR_WINDOWS_REGISTRATION_UNWIND_INFO_INVALID;
  }
  flags = (uint8_t)(info[0] >> 3);
  slots = ((size_t)info[2] + 1u) & ~(size_t)1u;
  bytes = 4u + slots * 2u;
  if ((flags & 4u) != 0) {
    bytes += 12u;
  } else if ((flags & 3u) != 0) {
    bytes += 4u;
  }
  if (!repro_hcr_windows_registration_range_ok(region_size, unwind_rva, bytes)) {
    return REPRO_HCR_WINDOWS_REGISTRATION_UNWIND_INFO_INVALID;
  }
  return REPRO_HCR_WINDOWS_REGISTRATION_OK;
}

static enum repro_hcr_windows_registration_status
repro_hcr_windows_register_unwind(
    void *region,
    size_t region_size,
    uint32_t table_offset,
    uint32_t entry_count,
    struct repro_hcr_windows_unwind_registration *registration) {
  PRUNTIME_FUNCTION table;
  uint32_t index;
  if (region == NULL || region_size == 0 || entry_count == 0 ||
      registration == NULL) {
    return REPRO_HCR_WINDOWS_REGISTRATION_INVALID_ARGUMENT;
  }
  memset(registration, 0, sizeof(*registration));
  if ((table_offset & 3u) != 0 ||
      !repro_hcr_windows_registration_range_ok(
          region_size, table_offset,
          (uint64_t)entry_count * sizeof(RUNTIME_FUNCTION))) {
    return REPRO_HCR_WINDOWS_REGISTRATION_TABLE_OUT_OF_RANGE;
  }
  table = (PRUNTIME_FUNCTION)((uint8_t *)region + table_offset);
  for (index = 0; index < entry_count; ++index) {
    enum repro_hcr_windows_registration_status status;
    if (table[index].BeginAddress >= table[index].EndAddress ||
        table[index].EndAddress > region_size) {
      return REPRO_HCR_WINDOWS_REGISTRATION_FUNCTION_RANGE_INVALID;
    }
    if (index > 0 &&
        (table[index - 1].BeginAddress >= table[index].BeginAddress ||
         table[index - 1].EndAddress > table[index].BeginAddress)) {
      return REPRO_HCR_WINDOWS_REGISTRATION_TABLE_UNSORTED;
    }
    status = repro_hcr_windows_validate_unwind_info(
        (const uint8_t *)region, region_size, table[index].UnwindData);
    if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
      return status;
    }
  }
  if (!RtlAddFunctionTable(table, entry_count, (DWORD64)(uintptr_t)region)) {
    return REPRO_HCR_WINDOWS_REGISTRATION_RTL_ADD_FAILED;
  }
  registration->table = table;
  registration->entry_count = entry_count;
  registration->region_base = (DWORD64)(uintptr_t)region;
  registration->registered = 1;
  return REPRO_HCR_WINDOWS_REGISTRATION_OK;
}

static enum repro_hcr_windows_registration_status
repro_hcr_windows_unregister_unwind(
    struct repro_hcr_windows_unwind_registration *registration) {
  if (registration == NULL || !registration->registered ||
      registration->table == NULL) {
    return REPRO_HCR_WINDOWS_REGISTRATION_NOT_REGISTERED;
  }
  if (!RtlDeleteFunctionTable(registration->table)) {
    return REPRO_HCR_WINDOWS_REGISTRATION_RTL_DELETE_FAILED;
  }
  memset(registration, 0, sizeof(*registration));
  return REPRO_HCR_WINDOWS_REGISTRATION_OK;
}

static enum repro_hcr_windows_registration_status
repro_hcr_windows_cfg_enabled(int *enabled) {
  PROCESS_MITIGATION_CONTROL_FLOW_GUARD_POLICY policy;
  if (enabled == NULL) {
    return REPRO_HCR_WINDOWS_REGISTRATION_INVALID_ARGUMENT;
  }
  memset(&policy, 0, sizeof(policy));
  if (!GetProcessMitigationPolicy(
          GetCurrentProcess(), ProcessControlFlowGuardPolicy,
          &policy, sizeof(policy))) {
    return REPRO_HCR_WINDOWS_REGISTRATION_CFG_QUERY_FAILED;
  }
  *enabled = policy.EnableControlFlowGuard ? 1 : 0;
  return REPRO_HCR_WINDOWS_REGISTRATION_OK;
}

static enum repro_hcr_windows_registration_status
repro_hcr_windows_set_cfg_targets(
    void *region,
    size_t region_size,
    const uint32_t *offsets,
    uint32_t count,
    int valid,
    int *cfg_enabled) {
  CFG_CALL_TARGET_INFO *targets;
  enum repro_hcr_windows_registration_status status;
  uint32_t index;
  int enabled = 0;
  if (region == NULL || region_size == 0 || offsets == NULL || count == 0) {
    return REPRO_HCR_WINDOWS_REGISTRATION_INVALID_ARGUMENT;
  }
  status = repro_hcr_windows_cfg_enabled(&enabled);
  if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
    return status;
  }
  if (cfg_enabled != NULL) {
    *cfg_enabled = enabled;
  }
  if (!enabled) {
    return REPRO_HCR_WINDOWS_REGISTRATION_OK;
  }
  targets = (CFG_CALL_TARGET_INFO *)HeapAlloc(
      GetProcessHeap(), HEAP_ZERO_MEMORY,
      (size_t)count * sizeof(CFG_CALL_TARGET_INFO));
  if (targets == NULL) {
    return REPRO_HCR_WINDOWS_REGISTRATION_CFG_UPDATE_FAILED;
  }
  for (index = 0; index < count; ++index) {
    if ((offsets[index] & 15u) != 0 || offsets[index] >= region_size ||
        (index > 0 && offsets[index - 1] >= offsets[index])) {
      HeapFree(GetProcessHeap(), 0, targets);
      return REPRO_HCR_WINDOWS_REGISTRATION_CFG_TARGET_INVALID;
    }
    targets[index].Offset = offsets[index];
    targets[index].Flags = valid ? CFG_CALL_TARGET_VALID : 0;
  }
  if (!SetProcessValidCallTargets(
          GetCurrentProcess(), region, region_size, count, targets)) {
    HeapFree(GetProcessHeap(), 0, targets);
    return REPRO_HCR_WINDOWS_REGISTRATION_CFG_UPDATE_FAILED;
  }
  HeapFree(GetProcessHeap(), 0, targets);
  return REPRO_HCR_WINDOWS_REGISTRATION_OK;
}

static enum repro_hcr_windows_registration_status
repro_hcr_windows_prepare_patch_region(
    void *region,
    size_t region_size,
    size_t unwind_payload_size,
    uint32_t table_offset,
    uint32_t table_count,
    const uint32_t *entry_offsets,
    uint32_t entry_count,
    struct repro_hcr_windows_patch_registration *registration) {
  enum repro_hcr_windows_registration_status status;
  if (registration == NULL || entry_offsets == NULL || entry_count == 0) {
    return REPRO_HCR_WINDOWS_REGISTRATION_INVALID_ARGUMENT;
  }
  memset(registration, 0, sizeof(*registration));
  registration->entry_offsets = (uint32_t *)HeapAlloc(
      GetProcessHeap(), 0, (size_t)entry_count * sizeof(uint32_t));
  if (registration->entry_offsets == NULL) {
    return REPRO_HCR_WINDOWS_REGISTRATION_CFG_UPDATE_FAILED;
  }
  memcpy(registration->entry_offsets, entry_offsets,
         (size_t)entry_count * sizeof(uint32_t));
  registration->entry_count = entry_count;
  registration->region = region;
  registration->region_size = region_size;
  status = repro_hcr_windows_register_unwind(
      region, unwind_payload_size, table_offset, table_count,
      &registration->unwind);
  if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
    HeapFree(GetProcessHeap(), 0, registration->entry_offsets);
    memset(registration, 0, sizeof(*registration));
    return status;
  }
  status = repro_hcr_windows_set_cfg_targets(
      region, region_size, registration->entry_offsets,
      registration->entry_count, 1, &registration->cfg_enabled);
  if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
    (void)repro_hcr_windows_unregister_unwind(&registration->unwind);
    HeapFree(GetProcessHeap(), 0, registration->entry_offsets);
    memset(registration, 0, sizeof(*registration));
    return status;
  }
  registration->prepared = 1;
  return REPRO_HCR_WINDOWS_REGISTRATION_OK;
}

static enum repro_hcr_windows_registration_status
repro_hcr_windows_prepared_entry(
    const struct repro_hcr_windows_patch_registration *registration,
    uint32_t offset,
    void **address) {
  uint32_t index;
  if (registration == NULL || address == NULL || !registration->prepared) {
    return REPRO_HCR_WINDOWS_REGISTRATION_NOT_REGISTERED;
  }
  for (index = 0; index < registration->entry_count; ++index) {
    if (registration->entry_offsets[index] == offset) {
      *address = (uint8_t *)registration->region + offset;
      return REPRO_HCR_WINDOWS_REGISTRATION_OK;
    }
  }
  return REPRO_HCR_WINDOWS_REGISTRATION_CFG_TARGET_INVALID;
}

static enum repro_hcr_windows_registration_status
repro_hcr_windows_rollback_patch_region(
    struct repro_hcr_windows_patch_registration *registration) {
  enum repro_hcr_windows_registration_status status;
  if (registration == NULL || !registration->prepared) {
    return REPRO_HCR_WINDOWS_REGISTRATION_NOT_REGISTERED;
  }
  status = repro_hcr_windows_set_cfg_targets(
      registration->region, registration->region_size,
      registration->entry_offsets, registration->entry_count, 0,
      &registration->cfg_enabled);
  if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
    return status;
  }
  status = repro_hcr_windows_unregister_unwind(&registration->unwind);
  if (status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
    return status;
  }
  HeapFree(GetProcessHeap(), 0, registration->entry_offsets);
  memset(registration, 0, sizeof(*registration));
  return REPRO_HCR_WINDOWS_REGISTRATION_OK;
}

#endif
