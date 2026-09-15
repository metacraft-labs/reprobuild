/*
 * HX-W-1 real multithreaded Windows provider-publication target.
 *
 * `allowed_mocks: none`. The included production publisher uses W2's real
 * Tool Help and thread-context path, VirtualProtect, real linked hotpatch
 * bytes, and FlushInstructionCache. The unavailable arm changes only the
 * provider capability input and must leave those linked bytes untouched.
 */

#define WIN32_LEAN_AND_MEAN
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

static int hx_w1_single_snapshot_for_test(void) {
  return 0;
}

#define REPRO_HCR_WQ_SINGLE_SNAPSHOT_FOR_TEST() \
  hx_w1_single_snapshot_for_test()
#include "repro_hcr_windows_publish.h"

#define HX_W1_WORKERS 8

static volatile LONG hx_w1_stop = 0;
static volatile LONG hx_w1_started = 0;
static volatile LONG64 hx_w1_calls = 0;
static volatile LONG64 hx_w1_original_values = 0;
static volatile LONG64 hx_w1_patched_values = 0;

#pragma code_seg(push, ".hcrv")
__declspec(dllexport) __declspec(noinline) int hx_w1_victim(int value) {
  return value + 11;
}
#pragma code_seg(pop)

__declspec(noinline) static int hx_w1_replacement(int value) {
  return value + 76;
}

static int(__cdecl *volatile hx_w1_call)(int) = hx_w1_victim;

static DWORD WINAPI hx_w1_worker(void *unused) {
  (void)unused;
  InterlockedIncrement(&hx_w1_started);
  while (InterlockedCompareExchange(&hx_w1_stop, 0, 0) == 0) {
    int value = hx_w1_call(1);
    InterlockedIncrement64(&hx_w1_calls);
    if (value == 12) {
      InterlockedIncrement64(&hx_w1_original_values);
    } else if (value == 77) {
      InterlockedIncrement64(&hx_w1_patched_values);
    } else {
      return 99;
    }
  }
  return 0;
}

static int hx_w1_hex_nibble(char value) {
  if (value >= '0' && value <= '9') {
    return value - '0';
  }
  if (value >= 'a' && value <= 'f') {
    return value - 'a' + 10;
  }
  if (value >= 'A' && value <= 'F') {
    return value - 'A' + 10;
  }
  return -1;
}

static int hx_w1_parse_hex(const char *text, uint8_t *out, size_t count) {
  size_t index;
  if (strlen(text) != count * 2u) {
    return 0;
  }
  for (index = 0; index < count; ++index) {
    int high = hx_w1_hex_nibble(text[index * 2u]);
    int low = hx_w1_hex_nibble(text[index * 2u + 1u]);
    if (high < 0 || low < 0) {
      return 0;
    }
    out[index] = (uint8_t)((high << 4) | low);
  }
  return 1;
}

static int hx_w1_wait_for(volatile LONG64 *value, LONG64 minimum,
                          DWORD timeout_ms) {
  ULONGLONG deadline = GetTickCount64() + timeout_ms;
  while (InterlockedCompareExchange64(value, 0, 0) < minimum) {
    if (GetTickCount64() >= deadline) {
      return 0;
    }
    SwitchToThread();
  }
  return 1;
}

static int hx_w1_wait_for_long(volatile LONG *value, LONG minimum,
                               DWORD timeout_ms) {
  ULONGLONG deadline = GetTickCount64() + timeout_ms;
  while (InterlockedCompareExchange(value, 0, 0) < minimum) {
    if (GetTickCount64() >= deadline) {
      return 0;
    }
    SwitchToThread();
  }
  return 1;
}

int main(int argc, char **argv) {
  const char *mode;
  uint32_t first_length;
  struct repro_hcr_windows_publish_request request;
  uint8_t before[REPRO_HCR_WP_PADDING_BYTES +
                 REPRO_HCR_WP_MAX_INSTRUCTION_BYTES];
  uint8_t after[REPRO_HCR_WP_PADDING_BYTES +
                REPRO_HCR_WP_MAX_INSTRUCTION_BYTES];
  HANDLE workers[HX_W1_WORKERS];
  LONG64 calls_before;
  int status;
  int index;
  int expected_status;

  if (argc != 5) {
    fprintf(stderr,
            "usage: hcr_w1_target MODE FIRST_LEN PADDING_HEX INSTRUCTION_HEX\n");
    return 64;
  }
  mode = argv[1];
  first_length = (uint32_t)strtoul(argv[2], NULL, 10);
  if (first_length < 2u ||
      first_length > REPRO_HCR_WP_MAX_INSTRUCTION_BYTES) {
    return 65;
  }
  ZeroMemory(&request, sizeof(request));
  request.entry = (uint8_t *)(uintptr_t)hx_w1_victim;
  request.dispatch = (const void *)(uintptr_t)hx_w1_replacement;
  request.first_instruction_length = first_length;
  if (!hx_w1_parse_hex(argv[3], request.expected_padding,
                       REPRO_HCR_WP_PADDING_BYTES) ||
      !hx_w1_parse_hex(argv[4], request.expected_first_instruction,
                       first_length)) {
    return 66;
  }
  request.quiescence_available = strcmp(mode, "positive") == 0;
  expected_status = request.quiescence_available
      ? REPRO_HCR_WP_OK
      : REPRO_HCR_WP_QUIESCENCE_REQUIRED;
  memcpy(before, request.entry - REPRO_HCR_WP_PADDING_BYTES,
         REPRO_HCR_WP_PADDING_BYTES + first_length);

  ZeroMemory(workers, sizeof(workers));
  for (index = 0; index < HX_W1_WORKERS; ++index) {
    workers[index] = CreateThread(NULL, 0, hx_w1_worker, NULL, 0, NULL);
    if (workers[index] == NULL) {
      return 67;
    }
  }
  if (!hx_w1_wait_for_long(&hx_w1_started, HX_W1_WORKERS, 10000) ||
      !hx_w1_wait_for((volatile LONG64 *)&hx_w1_calls, 10000, 10000)) {
    fprintf(stderr, "warmup failed: started=%ld calls=%lld original=%lld "
                    "patched=%lld\n",
            (long)InterlockedCompareExchange(&hx_w1_started, 0, 0),
            (long long)InterlockedCompareExchange64(&hx_w1_calls, 0, 0),
            (long long)InterlockedCompareExchange64(&hx_w1_original_values, 0, 0),
            (long long)InterlockedCompareExchange64(&hx_w1_patched_values, 0, 0));
    return 68;
  }
  calls_before = InterlockedCompareExchange64(&hx_w1_calls, 0, 0);

  status = repro_hcr_windows_publish_hotpatch(&request);
  memcpy(after, request.entry - REPRO_HCR_WP_PADDING_BYTES,
         REPRO_HCR_WP_PADDING_BYTES + first_length);
  if (status != expected_status) {
    return 69;
  }
  if (request.quiescence_available) {
    if (!hx_w1_wait_for((volatile LONG64 *)&hx_w1_patched_values, 1000, 10000)) {
      return 70;
    }
  } else if (memcmp(before, after,
                    REPRO_HCR_WP_PADDING_BYTES + first_length) != 0) {
    return 71;
  }

  InterlockedExchange(&hx_w1_stop, 1);
  if (WaitForMultipleObjects(HX_W1_WORKERS, workers, TRUE, 10000) !=
      WAIT_OBJECT_0) {
    return 72;
  }
  for (index = 0; index < HX_W1_WORKERS; ++index) {
    DWORD worker_status = 0;
    if (!GetExitCodeThread(workers[index], &worker_status) ||
        worker_status != 0) {
      return 73;
    }
    CloseHandle(workers[index]);
  }

  printf("{\"schemaId\":\"reprobuild.hcr.hx-w1.target.v1\"," 
         "\"mode\":\"%s\",\"status\":%d,\"statusName\":\"%s\"," 
         "\"quiescenceAvailable\":%s,\"quiescenceHeldAtStore\":%s," 
         "\"suspendedThreads\":%d,\"capturedContexts\":%d," 
         "\"cacheFlushSucceeded\":%s,\"published\":%s," 
         "\"rolledBack\":%s,\"workers\":%d,\"callsBefore\":%lld," 
         "\"callsAfter\":%lld,\"originalValues\":%lld," 
         "\"patchedValues\":%lld,\"bytesChanged\":%s}\n",
         mode, status, repro_hcr_wp_status_name(status),
         repro_hcr_wp_last_report.quiescence_available ? "true" : "false",
         repro_hcr_wp_last_report.quiescence_held_at_store ? "true" : "false",
         repro_hcr_wp_last_report.suspended_threads,
         repro_hcr_wp_last_report.captured_contexts,
         repro_hcr_wp_last_report.cache_flush_succeeded ? "true" : "false",
         repro_hcr_wp_last_report.published ? "true" : "false",
         repro_hcr_wp_last_report.rolled_back ? "true" : "false",
         HX_W1_WORKERS, (long long)calls_before,
         (long long)InterlockedCompareExchange64(&hx_w1_calls, 0, 0),
         (long long)InterlockedCompareExchange64(&hx_w1_original_values, 0, 0),
         (long long)InterlockedCompareExchange64(&hx_w1_patched_values, 0, 0),
         memcmp(before, after,
                REPRO_HCR_WP_PADDING_BYTES + first_length) != 0
             ? "true" : "false");
  return 0;
}
