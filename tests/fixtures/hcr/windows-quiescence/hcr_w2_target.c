/*
 * HX-W-2 real Windows quiescence and hotpatch-resume-map target.
 *
 * `allowed_mocks: none`. Every worker is a real Win32 thread. The included
 * production component uses real Tool Help snapshots, thread object handles,
 * SuspendThread/GetThreadContext/SetThreadContext/ResumeThread, and the target
 * changes a real linked /FUNCTIONPADMIN entry while its page is non-executable.
 */

#define WIN32_LEAN_AND_MEAN
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

static void hx_w2_after_first_snapshot(void);
static int hx_w2_single_snapshot_for_test(void);

#define REPRO_HCR_WQ_AFTER_FIRST_SNAPSHOT() hx_w2_after_first_snapshot()
#define REPRO_HCR_WQ_SINGLE_SNAPSHOT_FOR_TEST() \
  hx_w2_single_snapshot_for_test()
#include "repro_hcr_windows_quiesce.h"

#define HX_W2_INITIAL_WORKERS 8
#define HX_W2_MAX_WORKERS 16

static volatile LONG hx_w2_stop = 0;
static volatile LONG hx_w2_started = 0;
static volatile LONG64 hx_w2_calls = 0;
static volatile LONG64 hx_w2_bad_values = 0;
static volatile LONG hx_w2_hook_armed = 0;
static volatile LONG hx_w2_hook_fired = 0;
static volatile LONG hx_w2_single_snapshot = 0;
static DWORD hx_w2_late_tid = 0;
static HANDLE hx_w2_worker_handles[HX_W2_MAX_WORKERS];
static int hx_w2_worker_count = 0;
static char hx_w2_fault_path[MAX_PATH];
static uint64_t hx_w2_entry = 0;
static uint64_t hx_w2_padding = 0;
static volatile LONG hx_w2_fault_claimed = 0;

/* A separate PE section is load-bearing: VirtualProtect works at page
 * granularity, so the patcher's own executing code must not share this page. */
#pragma code_seg(push, ".hcrv")
__declspec(dllexport) __declspec(noinline) int hx_w2_victim(int value) {
  return value + 11;
}
#pragma code_seg(pop)

__declspec(noinline) static int hx_w2_replacement(int value) {
  return value + 76;
}

/* The volatile indirection is part of the fixture, not the product. Without
 * it MSVC correctly hoists the side-effect-free direct victim call out of the
 * worker loop, and the worker never reaches the bytes the gate changes. */
static int(__cdecl *volatile hx_w2_victim_call)(int) = hx_w2_victim;

static DWORD WINAPI hx_w2_worker(void *unused) {
  (void)unused;
  InterlockedIncrement(&hx_w2_started);
  while (InterlockedCompareExchange(&hx_w2_stop, 0, 0) == 0) {
    int value = hx_w2_victim_call(1);
    InterlockedIncrement64(&hx_w2_calls);
    if (value != 12 && value != 77) {
      InterlockedIncrement64(&hx_w2_bad_values);
    }
  }
  return 0;
}

static int hx_w2_append_literal(char *out, int at, int capacity,
                                const char *text) {
  while (*text != '\0' && at + 1 < capacity) {
    out[at++] = *text++;
  }
  out[at] = '\0';
  return at;
}

static int hx_w2_append_hex(char *out, int at, int capacity, uint64_t value) {
  static const char digits[] = "0123456789abcdef";
  int shift;
  at = hx_w2_append_literal(out, at, capacity, "0x");
  for (shift = 60; shift >= 0 && at + 1 < capacity; shift -= 4) {
    out[at++] = digits[(value >> shift) & 0xfu];
  }
  out[at] = '\0';
  return at;
}

static LONG CALLBACK hx_w2_fault_handler(EXCEPTION_POINTERS *exception) {
  char record[384];
  int at = 0;
  DWORD written = 0;
  HANDLE file;
  uint64_t address =
      (uint64_t)(uintptr_t)exception->ExceptionRecord->ExceptionAddress;
  uint64_t code = (uint64_t)exception->ExceptionRecord->ExceptionCode;

  if (InterlockedCompareExchange(&hx_w2_fault_claimed, 1, 0) != 0) {
    /* Several workers can resume into restored padding together. Only the
     * first owns the evidence file; later handlers wait for its process-wide
     * termination instead of truncating the record with CREATE_ALWAYS. */
    Sleep(INFINITE);
  }

  at = hx_w2_append_literal(record, at, sizeof(record), "{\"faultCode\":\"");
  at = hx_w2_append_hex(record, at, sizeof(record), code);
  at = hx_w2_append_literal(record, at, sizeof(record),
                            "\",\"faultAddress\":\"");
  at = hx_w2_append_hex(record, at, sizeof(record), address);
  at = hx_w2_append_literal(record, at, sizeof(record),
                            "\",\"paddingStart\":\"");
  at = hx_w2_append_hex(record, at, sizeof(record), hx_w2_padding);
  at = hx_w2_append_literal(record, at, sizeof(record), "\",\"entry\":\"");
  at = hx_w2_append_hex(record, at, sizeof(record), hx_w2_entry);
  at = hx_w2_append_literal(record, at, sizeof(record), "\"}\r\n");

  file = CreateFileA(hx_w2_fault_path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                     CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (file != INVALID_HANDLE_VALUE) {
    (void)WriteFile(file, record, (DWORD)at, &written, NULL);
    (void)FlushFileBuffers(file);
    CloseHandle(file);
  }
  TerminateProcess(GetCurrentProcess(), 93);
  return EXCEPTION_CONTINUE_SEARCH;
}

static int hx_w2_single_snapshot_for_test(void) {
  return InterlockedCompareExchange(&hx_w2_single_snapshot, 0, 0) != 0;
}

static void hx_w2_after_first_snapshot(void) {
  HANDLE thread;
  DWORD tid = 0;
  if (InterlockedCompareExchange(&hx_w2_hook_armed, 0, 0) == 0 ||
      InterlockedCompareExchange(&hx_w2_hook_fired, 1, 0) != 0) {
    return;
  }
  /* This is deliberately a real thread created AFTER snapshot one. The
   * production hook expands to a no-op; this compile-time gate hook makes the
   * enumeration race deterministic without replacing any Windows API. */
  thread = CreateThread(NULL, 0, hx_w2_worker, NULL, 0, &tid);
  if (thread == NULL) {
    return;
  }
  hx_w2_late_tid = tid;
  hx_w2_worker_handles[hx_w2_worker_count++] = thread;
}

typedef struct hx_w2_totals {
  uint64_t publications;
  uint64_t rollbacks;
  uint64_t enumeration_rounds;
  uint64_t contexts;
  uint64_t opportunities;
  uint64_t adjustments;
  int late_thread_held;
  int page_isolated;
  int protection_round_trips;
  int cache_flushes;
} hx_w2_totals;

static int hx_w2_write_byte(volatile unsigned char *address,
                            unsigned char value) {
  *address = value;
  return 1;
}

static int hx_w2_transition(int publish, int suppress_adjustment,
                            unsigned char original_padding[5],
                            unsigned char original_entry[3],
                            hx_w2_totals *totals) {
  unsigned char *entry = (unsigned char *)(uintptr_t)hx_w2_entry;
  unsigned char *padding = entry - 5;
  uint64_t previous_dispatch = publish ? 0u : (uint64_t)(uintptr_t)hx_w2_replacement;
  DWORD old_protection = 0;
  DWORD ignored = 0;
  int32_t displacement;
  int status;
  int i;

  status = repro_hcr_wq_begin();
  if (status != REPRO_HCR_WQ_OK) {
    return 10 + status;
  }
  if (hx_w2_late_tid != 0 && repro_hcr_wq_contains_tid(hx_w2_late_tid)) {
    totals->late_thread_held = 1;
  }
  status = repro_hcr_wq_validate_and_adjust_hotpatch_site(
      hx_w2_entry, 3, previous_dispatch, suppress_adjustment);
  if (status != REPRO_HCR_WQ_OK) {
    if (repro_hcr_wq.held) {
      (void)repro_hcr_wq_release();
    }
    return 30 + status;
  }

  totals->enumeration_rounds += (uint64_t)repro_hcr_wq.enumeration_rounds;
  totals->contexts += (uint64_t)repro_hcr_wq.context_count;
  totals->opportunities +=
      (uint64_t)repro_hcr_wq.adjustment_opportunities;
  totals->adjustments += (uint64_t)repro_hcr_wq.adjusted_count;

  if (!VirtualProtect(padding, 8, PAGE_READWRITE, &old_protection)) {
    (void)repro_hcr_wq_release();
    return 50;
  }
  totals->protection_round_trips += 1;

  if (publish) {
    /* The gate publishes the legal but adversarial `jmp entry-5`: workers
     * remain on the exact boundary rollback must map. Both the control and
     * falsifier use these same bytes; suppressing SetThreadContext is their
     * only difference. The resume-map destination is the retained replacement
     * body, so adjusted in-flight calls still complete normally. */
    int64_t delta = (int64_t)(uintptr_t)padding -
                    (int64_t)(uintptr_t)(padding + 5);
    if (delta < INT32_MIN || delta > INT32_MAX) {
      (void)VirtualProtect(padding, 8, old_protection, &ignored);
      (void)repro_hcr_wq_release();
      return 51;
    }
    displacement = (int32_t)delta;
    hx_w2_write_byte(padding + 0, 0xe9);
    for (i = 0; i < 4; ++i) {
      hx_w2_write_byte(padding + 1 + i,
                       ((unsigned char *)&displacement)[i]);
    }
    MemoryBarrier();
    hx_w2_write_byte(entry + 0, 0xeb);
    hx_w2_write_byte(entry + 1, 0xf9);
    totals->publications += 1;
  } else {
    /* Rollback order is entry first, then padding. A thread parked at
     * entry-5 has already been mapped to the retained previous dispatch. */
    for (i = 0; i < 3; ++i) {
      hx_w2_write_byte(entry + i, original_entry[i]);
    }
    MemoryBarrier();
    for (i = 0; i < 5; ++i) {
      hx_w2_write_byte(padding + i, original_padding[i]);
    }
    totals->rollbacks += 1;
  }

  if (!VirtualProtect(padding, 8, old_protection, &ignored)) {
    (void)repro_hcr_wq_release();
    return 52;
  }
  if (!FlushInstructionCache(GetCurrentProcess(), padding, 8)) {
    (void)repro_hcr_wq_release();
    return 53;
  }
  totals->cache_flushes += 1;
  status = repro_hcr_wq_release();
  if (status != REPRO_HCR_WQ_OK) {
    return 60 + status;
  }
  return 0;
}

static void hx_w2_stop_workers(void) {
  int i;
  InterlockedExchange(&hx_w2_stop, 1);
  if (hx_w2_worker_count > 0) {
    (void)WaitForMultipleObjects((DWORD)hx_w2_worker_count,
                                 hx_w2_worker_handles, TRUE, 10000);
  }
  for (i = 0; i < hx_w2_worker_count; ++i) {
    CloseHandle(hx_w2_worker_handles[i]);
  }
}

int main(int argc, char **argv) {
  const char *mode;
  int iterations;
  int suppress_adjustment;
  unsigned char original_padding[5];
  unsigned char original_entry[3];
  SYSTEM_INFO system_info;
  uintptr_t page_mask;
  uintptr_t victim_page;
  uintptr_t patcher_page;
  hx_w2_totals totals;
  int i;
  int status = 0;

  if (argc != 4) {
    fprintf(stderr, "usage: hcr_w2_target MODE ITERATIONS FAULT_RECORD\n");
    return 2;
  }
  mode = argv[1];
  iterations = atoi(argv[2]);
  if (iterations < 1) {
    return 3;
  }
  strncpy_s(hx_w2_fault_path, sizeof(hx_w2_fault_path), argv[3], _TRUNCATE);
  (void)AddVectoredExceptionHandler(1, hx_w2_fault_handler);
  ZeroMemory(&totals, sizeof(totals));

  hx_w2_entry = (uint64_t)(uintptr_t)hx_w2_victim;
  hx_w2_padding = hx_w2_entry - 5u;
  for (i = 0; i < 5; ++i) {
    original_padding[i] = ((unsigned char *)(uintptr_t)hx_w2_padding)[i];
  }
  for (i = 0; i < 3; ++i) {
    original_entry[i] = ((unsigned char *)(uintptr_t)hx_w2_entry)[i];
  }
  if (original_entry[0] != 0x8d || original_entry[1] != 0x41 ||
      original_entry[2] != 0x0b) {
    fprintf(stderr, "unexpected linked victim entry: %02x%02x%02x\n",
            original_entry[0], original_entry[1], original_entry[2]);
    return 4;
  }
  for (i = 0; i < 5; ++i) {
    if (original_padding[i] != 0xcc) {
      fprintf(stderr, "linked victim lacks /FUNCTIONPADMIN padding\n");
      return 5;
    }
  }

  GetSystemInfo(&system_info);
  page_mask = (uintptr_t)system_info.dwPageSize - 1u;
  victim_page = ((uintptr_t)hx_w2_victim) & ~page_mask;
  patcher_page = ((uintptr_t)hx_w2_transition) & ~page_mask;
  totals.page_isolated = victim_page != patcher_page;
  if (!totals.page_isolated) {
    fprintf(stderr, "victim and patcher share an executable page\n");
    return 6;
  }

  for (i = 0; i < HX_W2_INITIAL_WORKERS; ++i) {
    DWORD tid;
    HANDLE thread = CreateThread(NULL, 0, hx_w2_worker, NULL, 0, &tid);
    if (thread == NULL) {
      return 7;
    }
    hx_w2_worker_handles[hx_w2_worker_count++] = thread;
  }
  while (InterlockedCompareExchange(&hx_w2_started, 0, 0) <
         HX_W2_INITIAL_WORKERS) {
    SwitchToThread();
  }
  InterlockedExchange(&hx_w2_hook_armed, 1);

  if (strcmp(mode, "single-snapshot") == 0) {
    InterlockedExchange(&hx_w2_single_snapshot, 1);
    status = repro_hcr_wq_begin();
    if (status != REPRO_HCR_WQ_OK) {
      hx_w2_stop_workers();
      return 8;
    }
    totals.late_thread_held =
        hx_w2_late_tid != 0 && repro_hcr_wq_contains_tid(hx_w2_late_tid);
    totals.enumeration_rounds = (uint64_t)repro_hcr_wq.enumeration_rounds;
    totals.contexts = (uint64_t)repro_hcr_wq.context_count;
    (void)repro_hcr_wq_release();
    hx_w2_stop_workers();
    printf("{\"schemaId\":\"reprobuild.hcr.hx-w2.target.v1\","
           "\"mode\":\"single-snapshot\",\"lateTid\":%lu,"
           "\"lateThreadHeld\":%s,\"knownWorkers\":%d,"
           "\"enumerationRounds\":%llu,\"contexts\":%llu}\n",
           (unsigned long)hx_w2_late_tid,
           totals.late_thread_held ? "true" : "false", hx_w2_worker_count,
           (unsigned long long)totals.enumeration_rounds,
           (unsigned long long)totals.contexts);
    return totals.late_thread_held ? 9 : 0;
  }

  suppress_adjustment = strcmp(mode, "no-adjust") == 0;
  if (!suppress_adjustment && strcmp(mode, "control") != 0) {
    hx_w2_stop_workers();
    return 10;
  }
  for (i = 0; i < iterations; ++i) {
    status = hx_w2_transition(1, suppress_adjustment, original_padding,
                              original_entry, &totals);
    if (status != 0) {
      break;
    }
    /* Let every hot worker reach the published entry-5 loop before the
     * rollback snapshot. This runs with no thread suspended. */
    Sleep(1);
    status = hx_w2_transition(0, suppress_adjustment, original_padding,
                              original_entry, &totals);
    if (status != 0) {
      break;
    }
  }
  hx_w2_stop_workers();
  printf("{\"schemaId\":\"reprobuild.hcr.hx-w2.target.v1\","
         "\"mode\":\"%s\",\"status\":%d,\"iterations\":%d,"
         "\"knownWorkers\":%d,\"startedWorkers\":%ld,"
         "\"calls\":%lld,\"badValues\":%lld,"
         "\"publications\":%llu,\"rollbacks\":%llu,"
         "\"enumerationRounds\":%llu,\"contexts\":%llu,"
         "\"adjustmentOpportunities\":%llu,\"adjustments\":%llu,"
         "\"lateTid\":%lu,\"lateThreadHeld\":%s,"
         "\"pageIsolated\":%s,\"protectionRoundTrips\":%d,"
         "\"cacheFlushes\":%d}\n",
         mode, status, iterations, hx_w2_worker_count,
         (long)InterlockedCompareExchange(&hx_w2_started, 0, 0),
         (long long)InterlockedCompareExchange64(&hx_w2_calls, 0, 0),
         (long long)InterlockedCompareExchange64(&hx_w2_bad_values, 0, 0),
         (unsigned long long)totals.publications,
         (unsigned long long)totals.rollbacks,
         (unsigned long long)totals.enumeration_rounds,
         (unsigned long long)totals.contexts,
         (unsigned long long)totals.opportunities,
         (unsigned long long)totals.adjustments,
         (unsigned long)hx_w2_late_tid,
         totals.late_thread_held ? "true" : "false",
         totals.page_isolated ? "true" : "false",
         totals.protection_round_trips, totals.cache_flushes);
  return status;
}
