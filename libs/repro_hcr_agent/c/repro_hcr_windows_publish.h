/*
 * Windows x86_64 HCR hotpatch publication boundary (HX-W-1).
 *
 * This component joins the W0 MSVC entry geometry to W2's real quiescence
 * implementation. The caller supplies bytes already derived and validated by
 * the coordinator's PE/PDB path; the provider revalidates those bytes while
 * every peer thread is held before it writes either jump.
 */

#ifndef REPRO_HCR_WINDOWS_PUBLISH_H
#define REPRO_HCR_WINDOWS_PUBLISH_H

#if !defined(_WIN32) || !defined(_M_X64)
#error "repro_hcr_windows_publish.h requires Windows x86_64"
#endif

#include <limits.h>
#include <stdint.h>
#include <string.h>
#include <windows.h>

#include "repro_hcr_windows_quiesce.h"

#define REPRO_HCR_WP_PADDING_BYTES 6u
#define REPRO_HCR_WP_MAX_INSTRUCTION_BYTES 15u

enum repro_hcr_wp_status {
  REPRO_HCR_WP_OK = 0,
  REPRO_HCR_WP_INVALID_ARGUMENT = 1,
  REPRO_HCR_WP_QUIESCENCE_REQUIRED = 2,
  REPRO_HCR_WP_UNSUPPORTED_GEOMETRY = 3,
  REPRO_HCR_WP_DISPATCH_OUT_OF_RANGE = 4,
  REPRO_HCR_WP_LIVE_BYTES_MISMATCH = 5,
  REPRO_HCR_WP_MEMORY_QUERY_FAILED = 6,
  REPRO_HCR_WP_PAGE_BOUNDARY_UNSUPPORTED = 7,
  REPRO_HCR_WP_PROTECT_FAILED = 8,
  REPRO_HCR_WP_FLUSH_FAILED = 9,
  REPRO_HCR_WP_RELEASE_FAILED = 10,
  REPRO_HCR_WP_ROLLBACK_FAILED = 11,
  REPRO_HCR_WP_QUIESCENCE_FAILED = 12,
  REPRO_HCR_WP_CONTEXT_ADJUSTMENT_FAILED = 13
};

struct repro_hcr_windows_publish_request {
  uint8_t *entry;
  const void *dispatch;
  uint32_t first_instruction_length;
  uint8_t expected_padding[REPRO_HCR_WP_PADDING_BYTES];
  uint8_t expected_first_instruction[REPRO_HCR_WP_MAX_INSTRUCTION_BYTES];
  int quiescence_available;
};

struct repro_hcr_windows_publish_report {
  int status;
  int quiescence_status;
  DWORD win32_error;
  int quiescence_available;
  int quiescence_held_at_store;
  int suspended_threads;
  int captured_contexts;
  int cache_flush_succeeded;
  int published;
  int rolled_back;
  uintptr_t entry;
  uintptr_t dispatch;
};

static struct repro_hcr_windows_publish_report repro_hcr_wp_last_report;

static const char *repro_hcr_wp_status_name(int status) {
  switch ((enum repro_hcr_wp_status)status) {
  case REPRO_HCR_WP_OK:
    return "ok";
  case REPRO_HCR_WP_INVALID_ARGUMENT:
    return "invalid-argument";
  case REPRO_HCR_WP_QUIESCENCE_REQUIRED:
    return "quiescence-required";
  case REPRO_HCR_WP_UNSUPPORTED_GEOMETRY:
    return "unsupported-windows-hotpatch-geometry";
  case REPRO_HCR_WP_DISPATCH_OUT_OF_RANGE:
    return "patch-body-out-of-rel32-range";
  case REPRO_HCR_WP_LIVE_BYTES_MISMATCH:
    return "windows-hotpatch-live-bytes-mismatch";
  case REPRO_HCR_WP_MEMORY_QUERY_FAILED:
    return "windows-hotpatch-memory-query-failed";
  case REPRO_HCR_WP_PAGE_BOUNDARY_UNSUPPORTED:
    return "windows-hotpatch-page-boundary-unsupported";
  case REPRO_HCR_WP_PROTECT_FAILED:
    return "windows-hotpatch-protection-failed";
  case REPRO_HCR_WP_FLUSH_FAILED:
    return "windows-hotpatch-cache-flush-failed";
  case REPRO_HCR_WP_RELEASE_FAILED:
    return "windows-hotpatch-resume-failed";
  case REPRO_HCR_WP_ROLLBACK_FAILED:
    return "windows-hotpatch-rollback-failed";
  case REPRO_HCR_WP_QUIESCENCE_FAILED:
    return "windows-hotpatch-quiescence-failed";
  case REPRO_HCR_WP_CONTEXT_ADJUSTMENT_FAILED:
    return "windows-hotpatch-context-adjustment-failed";
  default:
    return "windows-hotpatch-unknown-failure";
  }
}

static int repro_hcr_wp_is_executable(DWORD protection) {
  DWORD base = protection & 0xffu;
  return base == PAGE_EXECUTE || base == PAGE_EXECUTE_READ ||
      base == PAGE_EXECUTE_READWRITE || base == PAGE_EXECUTE_WRITECOPY;
}

static int repro_hcr_wp_geometry_valid(
    const struct repro_hcr_windows_publish_request *request) {
  uint32_t index;
  if (request->first_instruction_length < 2u ||
      request->first_instruction_length > REPRO_HCR_WP_MAX_INSTRUCTION_BYTES) {
    return 0;
  }
  for (index = 0; index < REPRO_HCR_WP_PADDING_BYTES; ++index) {
    if (request->expected_padding[index] != 0xccu) {
      return 0;
    }
  }
  if (request->expected_first_instruction[0] == 0xebu &&
      request->expected_first_instruction[1] == 0xf9u) {
    return 0;
  }
  return 1;
}

static int repro_hcr_wp_live_bytes_match(
    const struct repro_hcr_windows_publish_request *request) {
  return memcmp(request->entry - REPRO_HCR_WP_PADDING_BYTES,
                request->expected_padding,
                REPRO_HCR_WP_PADDING_BYTES) == 0 &&
      memcmp(request->entry, request->expected_first_instruction,
             request->first_instruction_length) == 0;
}

static int repro_hcr_wp_restore_original(
    const struct repro_hcr_windows_publish_request *request,
    DWORD original_protection) {
  uint8_t *padding = request->entry - 5u;
  SIZE_T span = 5u + request->first_instruction_length;
  DWORD ignored = 0;
  DWORD writable_old = 0;
  int ok = 1;

  if (!VirtualProtect(padding, span, PAGE_READWRITE, &writable_old)) {
    return 0;
  }
  request->entry[0] = request->expected_first_instruction[0];
  request->entry[1] = request->expected_first_instruction[1];
  MemoryBarrier();
  memcpy(padding, request->expected_padding + 1, 5u);
  if (!VirtualProtect(padding, span, original_protection, &ignored)) {
    ok = 0;
  }
  if (!FlushInstructionCache(GetCurrentProcess(), padding, span)) {
    ok = 0;
  }
  return ok;
}

static int repro_hcr_windows_publish_hotpatch(
    const struct repro_hcr_windows_publish_request *request) {
  uint8_t *padding;
  SIZE_T span;
  int64_t displacement64;
  int32_t displacement;
  int quiescence_status;
  MEMORY_BASIC_INFORMATION first_region;
  MEMORY_BASIC_INFORMATION last_region;
  SYSTEM_INFO system_info;
  uintptr_t first_page;
  uintptr_t last_page;
  DWORD original_protection = 0;
  DWORD ignored = 0;
  int status = REPRO_HCR_WP_OK;

  ZeroMemory(&repro_hcr_wp_last_report, sizeof(repro_hcr_wp_last_report));
  if (request == NULL || request->entry == NULL || request->dispatch == NULL) {
    repro_hcr_wp_last_report.status = REPRO_HCR_WP_INVALID_ARGUMENT;
    return REPRO_HCR_WP_INVALID_ARGUMENT;
  }
  repro_hcr_wp_last_report.entry = (uintptr_t)request->entry;
  repro_hcr_wp_last_report.dispatch = (uintptr_t)request->dispatch;
  repro_hcr_wp_last_report.quiescence_available =
      request->quiescence_available ? 1 : 0;

  if (!repro_hcr_wp_geometry_valid(request)) {
    repro_hcr_wp_last_report.status = REPRO_HCR_WP_UNSUPPORTED_GEOMETRY;
    return REPRO_HCR_WP_UNSUPPORTED_GEOMETRY;
  }
  displacement64 = (int64_t)(uintptr_t)request->dispatch -
      (int64_t)(uintptr_t)request->entry;
  if (displacement64 < INT32_MIN || displacement64 > INT32_MAX) {
    repro_hcr_wp_last_report.status = REPRO_HCR_WP_DISPATCH_OUT_OF_RANGE;
    return REPRO_HCR_WP_DISPATCH_OUT_OF_RANGE;
  }
  if (!repro_hcr_wp_live_bytes_match(request)) {
    repro_hcr_wp_last_report.status = REPRO_HCR_WP_LIVE_BYTES_MISMATCH;
    return REPRO_HCR_WP_LIVE_BYTES_MISMATCH;
  }
  if (!request->quiescence_available) {
    repro_hcr_wp_last_report.status = REPRO_HCR_WP_QUIESCENCE_REQUIRED;
    return REPRO_HCR_WP_QUIESCENCE_REQUIRED;
  }

  padding = request->entry - 5u;
  span = 5u + request->first_instruction_length;
  if (VirtualQuery(padding, &first_region, sizeof(first_region)) == 0 ||
      VirtualQuery(padding + span - 1u, &last_region, sizeof(last_region)) == 0 ||
      first_region.State != MEM_COMMIT || last_region.State != MEM_COMMIT ||
      !repro_hcr_wp_is_executable(first_region.Protect) ||
      !repro_hcr_wp_is_executable(last_region.Protect)) {
    repro_hcr_wp_last_report.win32_error = GetLastError();
    repro_hcr_wp_last_report.status = REPRO_HCR_WP_MEMORY_QUERY_FAILED;
    return REPRO_HCR_WP_MEMORY_QUERY_FAILED;
  }
  GetSystemInfo(&system_info);
  first_page = (uintptr_t)padding &
      ~((uintptr_t)system_info.dwPageSize - 1u);
  last_page = (uintptr_t)(padding + span - 1u) &
      ~((uintptr_t)system_info.dwPageSize - 1u);
  if (first_page != last_page || first_region.Protect != last_region.Protect) {
    repro_hcr_wp_last_report.status = REPRO_HCR_WP_PAGE_BOUNDARY_UNSUPPORTED;
    return REPRO_HCR_WP_PAGE_BOUNDARY_UNSUPPORTED;
  }

  quiescence_status = repro_hcr_wq_begin();
  repro_hcr_wp_last_report.quiescence_status = quiescence_status;
  repro_hcr_wp_last_report.suspended_threads = repro_hcr_wq.suspended_count;
  repro_hcr_wp_last_report.captured_contexts = repro_hcr_wq.context_count;
  if (quiescence_status != REPRO_HCR_WQ_OK) {
    repro_hcr_wp_last_report.win32_error = repro_hcr_wq.win32_error;
    repro_hcr_wp_last_report.status = REPRO_HCR_WP_QUIESCENCE_FAILED;
    return REPRO_HCR_WP_QUIESCENCE_FAILED;
  }
  if (!repro_hcr_wp_live_bytes_match(request)) {
    status = REPRO_HCR_WP_LIVE_BYTES_MISMATCH;
    goto release_without_write;
  }
  quiescence_status = repro_hcr_wq_validate_and_adjust_hotpatch_site(
      (uint64_t)(uintptr_t)request->entry,
      request->first_instruction_length, 0u, 0);
  repro_hcr_wp_last_report.quiescence_status = quiescence_status;
  if (quiescence_status != REPRO_HCR_WQ_OK) {
    repro_hcr_wp_last_report.win32_error = repro_hcr_wq.win32_error;
    repro_hcr_wp_last_report.status =
        REPRO_HCR_WP_CONTEXT_ADJUSTMENT_FAILED;
    return REPRO_HCR_WP_CONTEXT_ADJUSTMENT_FAILED;
  }
  if (!VirtualProtect(padding, span, PAGE_READWRITE, &original_protection)) {
    repro_hcr_wp_last_report.win32_error = GetLastError();
    status = REPRO_HCR_WP_PROTECT_FAILED;
    goto release_without_write;
  }

  displacement = (int32_t)displacement64;
  padding[0] = 0xe9u;
  memcpy(padding + 1, &displacement, sizeof(displacement));
  MemoryBarrier();
  repro_hcr_wp_last_report.quiescence_held_at_store = repro_hcr_wq.held;
  request->entry[0] = 0xebu;
  request->entry[1] = 0xf9u;

  if (!VirtualProtect(padding, span, original_protection, &ignored)) {
    repro_hcr_wp_last_report.win32_error = GetLastError();
    status = REPRO_HCR_WP_PROTECT_FAILED;
    goto rollback;
  }
  if (!FlushInstructionCache(GetCurrentProcess(), padding, span)) {
    repro_hcr_wp_last_report.win32_error = GetLastError();
    status = REPRO_HCR_WP_FLUSH_FAILED;
    goto rollback;
  }
  repro_hcr_wp_last_report.cache_flush_succeeded = 1;
  repro_hcr_wp_last_report.published = 1;
  quiescence_status = repro_hcr_wq_release();
  repro_hcr_wp_last_report.quiescence_status = quiescence_status;
  if (quiescence_status != REPRO_HCR_WQ_OK) {
    repro_hcr_wp_last_report.win32_error = repro_hcr_wq.win32_error;
    repro_hcr_wp_last_report.status = REPRO_HCR_WP_RELEASE_FAILED;
    return REPRO_HCR_WP_RELEASE_FAILED;
  }
  repro_hcr_wp_last_report.status = REPRO_HCR_WP_OK;
  return REPRO_HCR_WP_OK;

rollback:
  if (!repro_hcr_wp_restore_original(request, original_protection)) {
    status = REPRO_HCR_WP_ROLLBACK_FAILED;
  } else {
    repro_hcr_wp_last_report.rolled_back = 1;
  }

release_without_write:
  if (repro_hcr_wq.held && repro_hcr_wq_release() != REPRO_HCR_WQ_OK &&
      status != REPRO_HCR_WP_ROLLBACK_FAILED) {
    repro_hcr_wp_last_report.win32_error = repro_hcr_wq.win32_error;
    status = REPRO_HCR_WP_RELEASE_FAILED;
  }
  repro_hcr_wp_last_report.status = status;
  return status;
}

#endif /* REPRO_HCR_WINDOWS_PUBLISH_H */
