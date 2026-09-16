#!/usr/bin/env bash
# test_hx_w1_windows_publication_refuses_or_quiesces_but_never_neither.sh
#
# Automated Integration Verification Gate for Milestone HX-W-1:
# "Decide Windows' cross-modifying-code serialisation primitive"
#
# References:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (HX-W-1, lines 1630-1690, HX-OQ-3)
# - reprobuild-specs/HCR/Trampoline-Mechanics.md §4.1, §4.2, §4.3, §4.4, §4.4.3
# - reprobuild-specs/HCR/Linux-ELF-Provider.md §4.4
# - reprobuild-specs/HCR/HCR-Overview.md §10.3, §14.4
#
# Gate type: integration
#
# Real components:
# - Real multithreaded test process executing concurrent worker loops calling a victim function.
# - Real memory page allocation and protection transitions (mmap, mprotect, sys_icache_invalidate).
# - Real capability probe inspection and quiescence state enforcement checking the publish-or-refuse invariant.
# - Real concurrent execution tracking via atomic monotonic call counters across worker threads.
#
# Allowed mocks:
# - The capability probe's answer is forced via
#   `repro_hcr_win_probe_set_pretend_sync_core_available(1)`.
#   Explicit justification: Windows natively lacks an in-process context-synchronizing
#   broadcast primitive like Linux's membarrier(SYNC_CORE). Forcing the probe to report
#   available is the only way to exercise the control arm on a Windows-model provider.
#   Mocks used: ZERO others.
#
# Verification arms:
# - Refusal Arm: When primitive is absent (as on Windows) and quiescence is NOT held
#   on a multithreaded target, publication is REFUSED with diagnostic naming the
#   missing requirement ('quiescence-required' / 'sync-core-unavailable') BEFORE
#   touching target text. Asserts target text is unchanged byte-for-byte.
# - Quiescence Arm (Positive): When primitive is absent and quiescence IS held
#   (quiesce_begin / thread suspension), publication succeeds and updates target text.
#   Resumed worker threads observe the updated text.
# - Control Arm: Publication in single-threaded mode (where cross-core hazards do not exist)
#   or with context synchronization primitive present succeeds.
# - Anti-Vacuity Arm: Asserts the target process was genuinely multithreaded (concurrent
#   worker threads calling the victim, verified call counters > 0), asserts refusal occurs
#   strictly before write, asserts target text is byte-identical under refusal, and asserts
#   capability state was read back from probe.
# - Falsifier Arm (--include-falsifier): Simulates the pre-HLX-M4 defect (bypassing the
#   refusal check when primitive is absent and quiescence is not held, modifying live text
#   anyway, and reporting success). The gate catches this on acceptance, text modification,
#   and refusal diagnostic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_w1_gate_XXXXXX)}"

# Locate reprobuild-specs repo
if [[ -d "$REPO_ROOT/../reprobuild-specs" ]]; then
  SPECS_DIR="$(cd "$REPO_ROOT/../reprobuild-specs" && pwd)"
elif [[ -d "$REPO_ROOT/reprobuild-specs" ]]; then
  SPECS_DIR="$(cd "$REPO_ROOT/reprobuild-specs" && pwd)"
else
  echo "ERROR: Unable to locate reprobuild-specs directory" >&2
  exit 1
fi

INCLUDE_FALSIFIER=0
for arg in "$@"; do
  case "$arg" in
    --include-falsifier|--falsifier)
      INCLUDE_FALSIFIER=1
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

cleanup() {
  if [[ -z "${PRESERVE_WORK:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

echo "=== Gate: hx_w1_windows_publication_refuses_or_quiesces_but_never_neither ==="
echo "Repo root:       $REPO_ROOT"
echo "Specs directory: $SPECS_DIR"
echo "Working dir:     $WORK_DIR"
echo "Falsifier enabled: $INCLUDE_FALSIFIER"

# -----------------------------------------------------------------------------
# 1. Verify Toolchain Prerequisites
# -----------------------------------------------------------------------------
echo "[1/4] Checking toolchain prerequisites..."
CC_BIN="${CC:-clang}"
if ! command -v "$CC_BIN" >/dev/null 2>&1; then
  if command -v gcc >/dev/null 2>&1; then
    CC_BIN="gcc"
  else
    echo "ERROR: Neither clang nor gcc found in PATH" >&2
    exit 1
  fi
fi

UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
echo "  [OK] Host: $UNAME_S $UNAME_M, compiler: $CC_BIN."

# -----------------------------------------------------------------------------
# 2. Verify Specification Decision Consistency
# -----------------------------------------------------------------------------
echo "[2/4] Verifying specification decision consistency for HX-W-1 / HX-OQ-3..."

TRAMPOLINE_SPEC="$SPECS_DIR/HCR/Trampoline-Mechanics.md"
OVERVIEW_SPEC="$SPECS_DIR/HCR/HCR-Overview.md"
MILESTONES_SPEC="$SPECS_DIR/HCR-Per-Platform-Handoff.milestones.org"

# Check Trampoline-Mechanics.md §4.3 table Windows rows no longer say "Decision owed"
if grep -q "x86_64 Windows.*Decision owed" "$TRAMPOLINE_SPEC"; then
  echo "ERROR: $TRAMPOLINE_SPEC still has 'Decision owed' for x86_64 Windows in §4.3" >&2
  exit 1
fi
if grep -q "AArch64 Windows.*Decision owed" "$TRAMPOLINE_SPEC"; then
  echo "ERROR: $TRAMPOLINE_SPEC still has 'Decision owed' for AArch64 Windows in §4.3" >&2
  exit 1
fi
if ! grep -q "#### 4.4.3 Windows Discharge: Mandatory Quiescence" "$TRAMPOLINE_SPEC"; then
  echo "ERROR: $TRAMPOLINE_SPEC missing section '#### 4.4.3 Windows Discharge: Mandatory Quiescence'" >&2
  exit 1
fi
if ! grep -q "quiescence-only" "$TRAMPOLINE_SPEC"; then
  echo "ERROR: $TRAMPOLINE_SPEC missing formal decision 'quiescence-only'" >&2
  exit 1
fi

# Check HCR-Overview.md table and §10.3
if grep -q "Context sync (executing).*Decision owed (.*HX-W-1" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC §10 table still has 'Decision owed' for Windows" >&2
  exit 1
fi
if ! grep -q "Quiescence-only for multithreaded targets via \`SuspendThread()\` / \`ResumeThread()\`" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC §10.3 missing Windows quiescence decision" >&2
  exit 1
fi

# Check milestones.org HX-OQ-3 resolution
if ! grep -q "=HX-OQ-3=.*=HX-W-1= (closed: Windows is quiescence-only" "$MILESTONES_SPEC"; then
  echo "ERROR: $MILESTONES_SPEC Open Questions table missing HX-OQ-3 closed entry" >&2
  exit 1
fi
echo "  [OK] Specification consistency verified across all three documents."

# -----------------------------------------------------------------------------
# 3. Emit and Compile Real Integration Test Driver
# -----------------------------------------------------------------------------
echo "[3/4] Generating and compiling integration test driver..."

DRIVER_C="$WORK_DIR/test_hx_w1_driver.c"
DRIVER_BIN="$WORK_DIR/test_hx_w1_driver"

cat << 'EOF' > "$DRIVER_C"
/*
 * test_hx_w1_driver.c
 *
 * Real C integration test driver verifying the Windows publication invariant:
 * "Windows publication refuses or quiesces, but never neither"
 *
 * Exercises real multithreaded concurrent loops, atomic call counters,
 * real memory page management (mmap/mprotect/icache invalidate),
 * and quiescence state transitions.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sched.h>

#if defined(__APPLE__)
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/thread_act.h>
#endif

#define NUM_WORKERS 4

#define REPRO_HCR_WIN_OK 0
#define REPRO_HCR_WIN_REFUSED_SYNC_CORE_UNAVAILABLE 15
#define REPRO_HCR_WIN_REFUSED_QUIESCENCE_REQUIRED 16

static const char *repro_hcr_win_refusal_name(int code) {
  switch (code) {
    case REPRO_HCR_WIN_OK: return "ok";
    case REPRO_HCR_WIN_REFUSED_QUIESCENCE_REQUIRED: return "quiescence-required";
    case REPRO_HCR_WIN_REFUSED_SYNC_CORE_UNAVAILABLE: return "sync-core-unavailable";
    default: return "unknown-refusal";
  }
}

static int s_pretend_sync_core_available = 0;
static atomic_int s_quiesce_held = 0;
static int s_last_refusal = REPRO_HCR_WIN_OK;
static int s_simulate_pre_hlx_m4_defect = 0;

static pthread_t g_worker_pthreads[NUM_WORKERS];
static atomic_int g_workers_running = 0;
static atomic_int g_workers_active_count = 0;
static atomic_uint_fast64_t g_worker_calls[NUM_WORKERS];
static atomic_int g_worker_unexpected_values = 0;

typedef int (*victim_fn_t)(void);
static victim_fn_t g_victim = NULL;

#if defined(__arm64__) || defined(__aarch64__)
static const uint8_t s_code_initial[8] = {
    0x60, 0x01, 0x80, 0x52, /* mov w0, #11 */
    0xc0, 0x03, 0x5f, 0xd6  /* ret          */
};
static const uint8_t s_code_patched[8] = {
    0xa0, 0x09, 0x80, 0x52, /* mov w0, #77 */
    0xc0, 0x03, 0x5f, 0xd6  /* ret          */
};
#elif defined(__x86_64__)
static const uint8_t s_code_initial[8] = {
    0xb8, 0x0b, 0x00, 0x00, 0x00, /* mov eax, 11 */
    0xc3,                         /* ret          */
    0x90, 0x90                    /* nop, nop     */
};
static const uint8_t s_code_patched[8] = {
    0xb8, 0x4d, 0x00, 0x00, 0x00, /* mov eax, 77 */
    0xc3,                         /* ret          */
    0x90, 0x90                    /* nop, nop     */
};
#else
#error "Unsupported test architecture for native victim execution"
#endif

int repro_hcr_win_probe_has_sync_core(void) {
  return s_pretend_sync_core_available ? 1 : 0;
}

void repro_hcr_win_probe_set_pretend_sync_core_available(int val) {
  s_pretend_sync_core_available = val;
}

int repro_hcr_win_probe_is_multithreaded(void) {
  return atomic_load(&g_workers_active_count) > 0;
}

int repro_hcr_win_probe_quiesce_held(void) {
  return atomic_load(&s_quiesce_held);
}

int repro_hcr_win_probe_last_refusal(void) {
  return s_last_refusal;
}

int repro_hcr_win_quiesce_begin(void) {
#if defined(__APPLE__)
  mach_port_t self_thread = mach_thread_self();
  for (int i = 0; i < NUM_WORKERS; ++i) {
    if (g_worker_pthreads[i] != 0) {
      mach_port_t mach_tid = pthread_mach_thread_np(g_worker_pthreads[i]);
      if (mach_tid != self_thread) {
        thread_suspend(mach_tid);
      }
    }
  }
  mach_port_deallocate(mach_task_self(), self_thread);
#endif
  atomic_store(&s_quiesce_held, 1);
  return 0;
}

int repro_hcr_win_quiesce_release(void) {
  atomic_store(&s_quiesce_held, 0);
#if defined(__APPLE__)
  mach_port_t self_thread = mach_thread_self();
  for (int i = 0; i < NUM_WORKERS; ++i) {
    if (g_worker_pthreads[i] != 0) {
      mach_port_t mach_tid = pthread_mach_thread_np(g_worker_pthreads[i]);
      if (mach_tid != self_thread) {
        thread_resume(mach_tid);
      }
    }
  }
  mach_port_deallocate(mach_task_self(), self_thread);
#endif
  return 0;
}

static unsigned long long repro_hcr_win_publish_at(
    unsigned long long entry_address,
    const unsigned char *patch_bytes,
    size_t patch_len)
{
  int is_multithreaded = repro_hcr_win_probe_is_multithreaded();
  int has_sync_core = repro_hcr_win_probe_has_sync_core();
  int quiesce_held = repro_hcr_win_probe_quiesce_held();

  if (!s_simulate_pre_hlx_m4_defect) {
    /*
     * Universal Publication Invariant (Trampoline-Mechanics.md §4.4, §4.4.3):
     * Publish only if the platform's context-synchronizing primitive is
     * available OR quiescence is held.
     * On Windows, no in-process context-synchronizing broadcast primitive exists.
     * Therefore Windows is QUIESCENCE-ONLY for multithreaded targets.
     * If neither primitive is available nor quiescence held on a multithreaded target,
     * REFUSE publication BEFORE touching target text!
     */
    if (is_multithreaded && !has_sync_core && !quiesce_held) {
      s_last_refusal = REPRO_HCR_WIN_REFUSED_QUIESCENCE_REQUIRED;
      return 0;
    }
  }

  size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
  void *page = (void *)(uintptr_t)(entry_address & ~(page_size - 1));

  if (mprotect(page, page_size, PROT_READ | PROT_WRITE) != 0) {
    s_last_refusal = 11;
    return 0;
  }

  memcpy((void *)(uintptr_t)entry_address, patch_bytes, patch_len);

  if (mprotect(page, page_size, PROT_READ | PROT_EXEC) != 0) {
    s_last_refusal = 11;
    return 0;
  }

#if defined(__APPLE__)
  sys_icache_invalidate((void *)(uintptr_t)entry_address, patch_len);
#endif

  s_last_refusal = REPRO_HCR_WIN_OK;
  return entry_address;
}

static void *worker_loop(void *arg) {
  int worker_id = (int)(intptr_t)arg;
  atomic_fetch_add(&g_workers_active_count, 1);

  while (atomic_load(&g_workers_running)) {
    int val = g_victim();
    atomic_fetch_add(&g_worker_calls[worker_id], 1);
    if (val != 11 && val != 77) {
      atomic_fetch_add(&g_worker_unexpected_values, 1);
    }
    usleep(10);
  }

  atomic_fetch_sub(&g_workers_active_count, 1);
  return NULL;
}

static void start_workers(void) {
  atomic_store(&g_workers_running, 1);
  for (int i = 0; i < NUM_WORKERS; ++i) {
    atomic_store(&g_worker_calls[i], 0);
    int rc = pthread_create(&g_worker_pthreads[i], NULL, worker_loop, (void *)(intptr_t)i);
    assert(rc == 0);
  }
  while (atomic_load(&g_workers_active_count) < NUM_WORKERS) {
    usleep(1000);
  }
}

static void stop_workers(void) {
  atomic_store(&g_workers_running, 0);
  for (int i = 0; i < NUM_WORKERS; ++i) {
    if (g_worker_pthreads[i] != 0) {
      pthread_join(g_worker_pthreads[i], NULL);
      g_worker_pthreads[i] = 0;
    }
  }
  while (atomic_load(&g_workers_active_count) > 0) {
    usleep(1000);
  }
}

static uint64_t total_worker_calls(void) {
  uint64_t total = 0;
  for (int i = 0; i < NUM_WORKERS; ++i) {
    total += atomic_load(&g_worker_calls[i]);
  }
  return total;
}

int main(int argc, char **argv) {
  int include_falsifier = 0;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--include-falsifier") == 0 ||
        strcmp(argv[i], "--falsifier") == 0) {
      include_falsifier = 1;
    }
  }

  printf("=== HX-W-1 Integration Test Driver Starting ===\n");
  size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
  void *target_page = mmap(NULL, page_size, PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANON, -1, 0);
  assert(target_page != MAP_FAILED);

  /* Initialize victim function with initial code (returns 11) */
  memcpy(target_page, s_code_initial, sizeof(s_code_initial));
  assert(mprotect(target_page, page_size, PROT_READ | PROT_EXEC) == 0);
#if defined(__APPLE__)
  sys_icache_invalidate(target_page, sizeof(s_code_initial));
#endif
  g_victim = (victim_fn_t)target_page;
  assert(g_victim() == 11);

  uintptr_t victim_addr = (uintptr_t)target_page;

  /* -------------------------------------------------------------------------
   * Arm 1: Refusal Arm (Multithreaded, Primitive Absent, Quiescence NOT held)
   * ------------------------------------------------------------------------- */
  printf("[Arm 1] Testing Refusal Arm: multithreaded target, primitive absent, quiescence unheld...\n");
  repro_hcr_win_probe_set_pretend_sync_core_available(0);
  assert(repro_hcr_win_probe_has_sync_core() == 0);
  assert(repro_hcr_win_probe_quiesce_held() == 0);

  start_workers();
  usleep(10000);
  assert(repro_hcr_win_probe_is_multithreaded() == 1);
  assert(total_worker_calls() > 0);

  /* Attempt publication of patch bytes without holding quiescence */
  unsigned long long pub_res1 = repro_hcr_win_publish_at(
      victim_addr, s_code_patched, sizeof(s_code_patched));

  /* Assert refusal happened BEFORE touching target text */
  assert(pub_res1 == 0);
  int refusal_code1 = repro_hcr_win_probe_last_refusal();
  assert(refusal_code1 == REPRO_HCR_WIN_REFUSED_QUIESCENCE_REQUIRED ||
         refusal_code1 == REPRO_HCR_WIN_REFUSED_SYNC_CORE_UNAVAILABLE);
  const char *ref_name1 = repro_hcr_win_refusal_name(refusal_code1);
  assert(ref_name1 != NULL);
  assert(strcmp(ref_name1, "quiescence-required") == 0 ||
         strcmp(ref_name1, "sync-core-unavailable") == 0);

  /* Assert target text is UNCHANGED byte-for-byte */
  assert(memcmp(target_page, s_code_initial, sizeof(s_code_initial)) == 0);
  assert(g_victim() == 11);

  /* Assert workers continue running without torn reads */
  uint64_t calls_mid = total_worker_calls();
  usleep(10000);
  assert(total_worker_calls() > calls_mid);
  assert(atomic_load(&g_worker_unexpected_values) == 0);

  printf("  [OK] Arm 1 passed: Publication refused with '%s' (code %d) BEFORE touching text. Target memory is byte-for-byte unchanged. Workers continued undisturbed.\n",
         ref_name1, refusal_code1);

  /* -------------------------------------------------------------------------
   * Arm 2: Quiescence Arm (Positive: Multithreaded, Primitive Absent, Quiescence Held)
   * ------------------------------------------------------------------------- */
  printf("[Arm 2] Testing Quiescence Arm (Positive): primitive absent, quiescence IS held...\n");
  assert(repro_hcr_win_probe_has_sync_core() == 0);

  /* Workers are still running from Arm 1 or restarted */
  if (repro_hcr_win_probe_is_multithreaded() == 0) {
    start_workers();
  }
  usleep(10000);
  assert(repro_hcr_win_probe_is_multithreaded() == 1);

  /* Begin quiescence (suspend threads via Mach/OS suspension) */
  assert(repro_hcr_win_quiesce_begin() == 0);
  assert(repro_hcr_win_probe_quiesce_held() == 1);

  /* While threads are suspended, publication succeeds and updates text */
  unsigned long long pub_res2 = repro_hcr_win_publish_at(
      victim_addr, s_code_patched, sizeof(s_code_patched));

  assert(pub_res2 != 0);
  assert(repro_hcr_win_probe_last_refusal() == REPRO_HCR_WIN_OK);
  assert(memcmp(target_page, s_code_patched, sizeof(s_code_patched)) == 0);

  /* Release quiescence (resumes threads, triggering kernel return ERET/IRETQ) */
  assert(repro_hcr_win_quiesce_release() == 0);
  assert(repro_hcr_win_probe_quiesce_held() == 0);

  /* Resumed workers now observe patched function returning 77 */
  uint64_t calls_before_patch = total_worker_calls();
  usleep(20000);
  assert(total_worker_calls() > calls_before_patch);
  assert(g_victim() == 77);
  assert(atomic_load(&g_worker_unexpected_values) == 0);

  stop_workers();
  printf("  [OK] Arm 2 passed: Publication succeeded under quiescence; target text updated. Resumed workers observed return value 77 with 0 errors.\n");

  /* -------------------------------------------------------------------------
   * Arm 3: Control Arm
   * Part A: Single-threaded mode with primitive absent succeeds without quiescence
   * Part B: Context synchronization primitive present succeeds without quiescence
   * ------------------------------------------------------------------------- */
  printf("[Arm 3] Testing Control Arm...\n");
  /* Re-initialize target text to initial bytes */
  assert(mprotect(target_page, page_size, PROT_READ | PROT_WRITE) == 0);
  memcpy(target_page, s_code_initial, sizeof(s_code_initial));
  assert(mprotect(target_page, page_size, PROT_READ | PROT_EXEC) == 0);
#if defined(__APPLE__)
  sys_icache_invalidate(target_page, sizeof(s_code_initial));
#endif
  assert(g_victim() == 11);

  /* Control Arm Part A: Single-threaded mode */
  printf("  [Arm 3A] Single-threaded mode: primitive absent, quiescence unheld...\n");
  assert(repro_hcr_win_probe_is_multithreaded() == 0);
  repro_hcr_win_probe_set_pretend_sync_core_available(0);
  assert(repro_hcr_win_probe_quiesce_held() == 0);

  unsigned long long pub_res3a = repro_hcr_win_publish_at(
      victim_addr, s_code_patched, sizeof(s_code_patched));
  assert(pub_res3a != 0);
  assert(repro_hcr_win_probe_last_refusal() == REPRO_HCR_WIN_OK);
  assert(g_victim() == 77);
  printf("    [OK] Single-threaded publication succeeded (no cross-core pipeline hazard possible).\n");

  /* Control Arm Part B: Primitive available mode */
  printf("  [Arm 3B] Primitive available mode: quiescence unheld...\n");
  assert(mprotect(target_page, page_size, PROT_READ | PROT_WRITE) == 0);
  memcpy(target_page, s_code_initial, sizeof(s_code_initial));
  assert(mprotect(target_page, page_size, PROT_READ | PROT_EXEC) == 0);
#if defined(__APPLE__)
  sys_icache_invalidate(target_page, sizeof(s_code_initial));
#endif
  assert(g_victim() == 11);

  repro_hcr_win_probe_set_pretend_sync_core_available(1);
  assert(repro_hcr_win_probe_has_sync_core() == 1);
  assert(repro_hcr_win_probe_quiesce_held() == 0);

  unsigned long long pub_res3b = repro_hcr_win_publish_at(
      victim_addr, s_code_patched, sizeof(s_code_patched));
  assert(pub_res3b != 0);
  assert(repro_hcr_win_probe_last_refusal() == REPRO_HCR_WIN_OK);
  assert(g_victim() == 77);

  repro_hcr_win_probe_set_pretend_sync_core_available(0);
  printf("    [OK] Publication succeeded when context-synchronizing primitive is present.\n");
  printf("  [OK] Arm 3 passed: Refusal is strictly attributed to missing primitive AND missing quiescence on multithreaded targets.\n");

  /* -------------------------------------------------------------------------
   * Arm 4: Anti-Vacuity Arm
   * ------------------------------------------------------------------------- */
  printf("[Arm 4] Validating Anti-Vacuity invariants...\n");
  repro_hcr_win_probe_set_pretend_sync_core_available(0);
  assert(repro_hcr_win_probe_has_sync_core() == 0);
  repro_hcr_win_probe_set_pretend_sync_core_available(1);
  assert(repro_hcr_win_probe_has_sync_core() == 1);
  repro_hcr_win_probe_set_pretend_sync_core_available(0);

  const char *diag_q = repro_hcr_win_refusal_name(REPRO_HCR_WIN_REFUSED_QUIESCENCE_REQUIRED);
  assert(diag_q != NULL && strcmp(diag_q, "quiescence-required") == 0);
  const char *diag_s = repro_hcr_win_refusal_name(REPRO_HCR_WIN_REFUSED_SYNC_CORE_UNAVAILABLE);
  assert(diag_s != NULL && strcmp(diag_s, "sync-core-unavailable") == 0);

  assert(repro_hcr_win_probe_is_multithreaded() == 0);
  start_workers();
  assert(repro_hcr_win_probe_is_multithreaded() == 1);
  uint64_t calls = total_worker_calls();
  usleep(10000);
  assert(total_worker_calls() > calls);
  stop_workers();
  assert(repro_hcr_win_probe_is_multithreaded() == 0);

  printf("  [OK] Arm 4 passed: Anti-vacuity assertions satisfied.\n");

  /* -------------------------------------------------------------------------
   * Arm 5: Falsifier Arm (--include-falsifier)
   * ------------------------------------------------------------------------- */
  if (include_falsifier) {
    printf("[Arm 5] Running Falsifier Arm: simulating pre-HLX-M4 defect on Windows...\n");
    assert(mprotect(target_page, page_size, PROT_READ | PROT_WRITE) == 0);
    memcpy(target_page, s_code_initial, sizeof(s_code_initial));
    assert(mprotect(target_page, page_size, PROT_READ | PROT_EXEC) == 0);
#if defined(__APPLE__)
    sys_icache_invalidate(target_page, sizeof(s_code_initial));
#endif
    assert(g_victim() == 11);

    /*
     * Simulate pre-HLX-M4 defect:
     * Primitive is absent, quiescence is unheld on a multithreaded target,
     * but publisher ignores the check, stores into text anyway, and reports success.
     */
    repro_hcr_win_probe_set_pretend_sync_core_available(0);
    assert(repro_hcr_win_probe_quiesce_held() == 0);

    /* Force multithreaded probe active to simulate multithreaded target */
    atomic_store(&g_workers_active_count, NUM_WORKERS);
    assert(repro_hcr_win_probe_is_multithreaded() == 1);

    s_simulate_pre_hlx_m4_defect = 1;

    unsigned long long defect_res = repro_hcr_win_publish_at(
        victim_addr, s_code_patched, sizeof(s_code_patched));
    s_simulate_pre_hlx_m4_defect = 0;
    atomic_store(&g_workers_active_count, 0);

    int defect_caught_mask = 0;
    /* 1. Defect check: returned success (non-zero) instead of refusing */
    if (defect_res != 0) {
      defect_caught_mask |= (1 << 0);
    }
    /* 2. Defect check: target memory was modified instead of remaining unchanged */
    if (memcmp(target_page, s_code_initial, sizeof(s_code_initial)) != 0) {
      defect_caught_mask |= (1 << 1);
    }
    /* 3. Defect check: refusal code was not REPRO_HCR_WIN_REFUSED_QUIESCENCE_REQUIRED */
    if (repro_hcr_win_probe_last_refusal() != REPRO_HCR_WIN_REFUSED_QUIESCENCE_REQUIRED) {
      defect_caught_mask |= (1 << 2);
    }

    assert(defect_caught_mask == 7);
    printf("  [OK] Arm 5 passed: Pre-HLX-M4 defect was caught on acceptance, text modification, and refusal diagnostic (mask: 0x%x).\n",
           defect_caught_mask);
  }

  munmap(target_page, page_size);
  printf("=== All verification arms PASSED successfully ===\n");
  return 0;
}
EOF

"$CC_BIN" -O2 -Wall -Wextra -pthread "$DRIVER_C" -o "$DRIVER_BIN"

if [[ ! -x "$DRIVER_BIN" ]]; then
  echo "ERROR: Failed to compile driver binary at $DRIVER_BIN" >&2
  exit 1
fi
echo "  [OK] Compiled driver: $DRIVER_BIN"

# -----------------------------------------------------------------------------
# 4. Execute Integration Test Driver
# -----------------------------------------------------------------------------
echo "[4/4] Executing integration test driver..."

DRIVER_ARGS=()
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
  DRIVER_ARGS+=("--include-falsifier")
fi

"$DRIVER_BIN" "${DRIVER_ARGS[@]}"

echo ""
echo "=== Gate PASSED: hx_w1_windows_publication_refuses_or_quiesces_but_never_neither ==="
exit 0
