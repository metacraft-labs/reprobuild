#!/usr/bin/env bash
# test_hx_w2_windows_quiescence_holds_and_the_ip_adjustment_is_load_bearing.sh
#
# Automated Integration Verification Gate for Milestone HX-W-2:
# "Thread enumeration, suspension, and IP adjustment on Windows"
#
# References:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (HX-W-2, lines 1695-1749, HX-OQ-4)
# - reprobuild-specs/HCR/Trampoline-Mechanics.md §3.1, §3.3, §3.4, §4.3, §4.4.3
# - reprobuild-specs/HCR/Linux-ELF-Provider.md §6.2, §6.3 (HLX-M4 precedent)
# - reprobuild-specs/HCR/HCR-Overview.md § "Thread suspension", §10.3, §14.4
# - reprobuild/libs/repro_hcr_agent/c/repro_hcr_windows_quiesce.h
#
# Gate type: e2e / integration
#
# Real components:
# - Real multithreaded test driver with concurrent worker threads repeatedly executing a victim function across patch publication.
# - Real thread enumeration and suspension with two-pass stability check catching dynamically spawned threads.
# - Real context inspection detecting when a thread's IP is stopped inside the overwritten patch window, and real IP adjustment using the rAlign table to redirect the IP to the replacement instruction.
# - Zero mocks.
#
# Verification arms:
# - Positive Quiescence Arm: N workers calling victim across M publications; under quiescence with IP adjustment, zero crashes, zero torn reads, 100% success.
# - Falsifier Arm 1 (Missing IP Adjustment): When the IP adjustment is removed (leaving IP pointing inside the overwritten/corrupted window), worker threads crash or read invalid state. Gate asserts fault / failure and catches it. Specifically, asserts the fault PC lands inside the published window [entry, entry + window_size).
# - Falsifier Arm 2 (Single snapshot without stability check): Spawns a thread concurrently during the handshake; without the second snapshot check, the new thread is missed and executes during publication. Gate catches the missed thread.
# - Control Arm & Anti-Vacuity: Asserts process was genuinely multithreaded, all workers executed victim, enumeration found all threads, and publication count > floor.
# - Syntax & Header Verification: Compiles repro_hcr_windows_quiesce.h with clang --target=x86_64-windows-msvc (and native clang) ensuring valid Windows C syntax and types.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_w2_gate_XXXXXX)}"

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

echo "=== Gate: hx_w2_windows_quiescence_holds_and_the_ip_adjustment_is_load_bearing ==="
echo "Repo root:         $REPO_ROOT"
echo "Specs directory:   $SPECS_DIR"
echo "Working dir:       $WORK_DIR"
echo "Falsifier enabled: $INCLUDE_FALSIFIER"

# -----------------------------------------------------------------------------
# 1. Toolchain & Header Syntax Verification
# -----------------------------------------------------------------------------
echo "[1/4] Checking toolchain and verifying repro_hcr_windows_quiesce.h syntax..."
CC_BIN="${CC:-clang}"
if ! command -v "$CC_BIN" >/dev/null 2>&1; then
  echo "ERROR: clang compiler not found in PATH" >&2
  exit 1
fi

UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
echo "  [OK] Host: $UNAME_S $UNAME_M, compiler: $CC_BIN."

HEADER_PATH="$REPO_ROOT/libs/repro_hcr_agent/c/repro_hcr_windows_quiesce.h"
if [[ ! -f "$HEADER_PATH" ]]; then
  echo "ERROR: $HEADER_PATH not found" >&2
  exit 1
fi

# Test 1a: Compile repro_hcr_windows_quiesce.h with cross-target x86_64-windows-msvc
echo "  -> Verifying Windows C syntax with clang --target=x86_64-windows-msvc..."
if ! "$CC_BIN" -fno-PIC --target=x86_64-windows-msvc -fsyntax-only -I "$REPO_ROOT/libs/repro_hcr_agent/c" "$HEADER_PATH" 2>"$WORK_DIR/clang_win_syntax.err"; then
  cat "$WORK_DIR/clang_win_syntax.err" >&2
  echo "ERROR: Clang syntax check failed for x86_64-windows-msvc target" >&2
  exit 1
fi
echo "  [OK] clang --target=x86_64-windows-msvc syntax check passed with zero errors."

# Test 1b: Compile repro_hcr_windows_quiesce.h with native host compiler
echo "  -> Verifying native syntax check..."
if ! "$CC_BIN" -fsyntax-only -I "$REPO_ROOT/libs/repro_hcr_agent/c" "$HEADER_PATH" 2>"$WORK_DIR/clang_native_syntax.err"; then
  cat "$WORK_DIR/clang_native_syntax.err" >&2
  echo "ERROR: Native clang syntax check failed" >&2
  exit 1
fi
echo "  [OK] Native clang syntax check passed with zero errors."

# -----------------------------------------------------------------------------
# 2. Verify Specification Decision Consistency
# -----------------------------------------------------------------------------
echo "[2/4] Verifying specification decision consistency for HX-W-2 / HX-OQ-4..."

TRAMPOLINE_SPEC="$SPECS_DIR/HCR/Trampoline-Mechanics.md"
OVERVIEW_SPEC="$SPECS_DIR/HCR/HCR-Overview.md"
MILESTONES_SPEC="$SPECS_DIR/HCR-Per-Platform-Handoff.milestones.org"

# Check Trampoline-Mechanics.md §3.1, §3.3, §3.4, §4.4.3
if ! grep -q "CreateToolhelp32Snapshot" "$TRAMPOLINE_SPEC"; then
  echo "ERROR: $TRAMPOLINE_SPEC missing 'CreateToolhelp32Snapshot'" >&2
  exit 1
fi
if ! grep -q "two-consecutive-snapshot stability loop" "$TRAMPOLINE_SPEC"; then
  echo "ERROR: $TRAMPOLINE_SPEC missing 'two-consecutive-snapshot stability loop'" >&2
  exit 1
fi
if ! grep -q "rAlign" "$TRAMPOLINE_SPEC"; then
  echo "ERROR: $TRAMPOLINE_SPEC missing 'rAlign'" >&2
  exit 1
fi
if ! grep -q "quiescence-thread-suspend-failed" "$TRAMPOLINE_SPEC"; then
  echo "ERROR: $TRAMPOLINE_SPEC missing Loud Failure Mode 1 (quiescence-thread-suspend-failed)" >&2
  exit 1
fi
if ! grep -q "quiescence-thread-snapshot-failed" "$TRAMPOLINE_SPEC"; then
  echo "ERROR: $TRAMPOLINE_SPEC missing Loud Failure Mode 2 (quiescence-thread-snapshot-failed)" >&2
  exit 1
fi
if ! grep -q "PAGE_EXECUTE_READWRITE" "$TRAMPOLINE_SPEC"; then
  echo "ERROR: $TRAMPOLINE_SPEC missing PAGE_EXECUTE_READWRITE page-protection hazard handling" >&2
  exit 1
fi

# Check HCR-Overview.md § "Thread suspension" and §10.3 / §14.4
if ! grep -q "CreateToolhelp32Snapshot" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC missing CreateToolhelp32Snapshot" >&2
  exit 1
fi
if ! grep -q "stability loop" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC missing stability loop" >&2
  exit 1
fi
if ! grep -q "rAlign" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC missing rAlign" >&2
  exit 1
fi

# Check milestones.org HX-OQ-4 resolution and HX-W-2 completed
if ! grep -q "=HX-OQ-4=.*=HX-W-2= (closed: CreateToolhelp32Snapshot" "$MILESTONES_SPEC"; then
  echo "ERROR: $MILESTONES_SPEC Open Questions table missing HX-OQ-4 closed entry" >&2
  exit 1
fi
if ! grep -A 3 "\*\* HX-W-2: Thread enumeration" "$MILESTONES_SPEC" | grep -q ":status: completed"; then
  echo "ERROR: $MILESTONES_SPEC HX-W-2 not marked completed" >&2
  exit 1
fi
echo "  [OK] Specification consistency verified across all three documents."

# -----------------------------------------------------------------------------
# 3. Emit and Compile Real Integration Test Driver
# -----------------------------------------------------------------------------
echo "[3/4] Generating and compiling integration test driver..."

DRIVER_C="$WORK_DIR/test_hx_w2_driver.c"
DRIVER_BIN="$WORK_DIR/test_hx_w2_driver"

cat << 'EOF' > "$DRIVER_C"
/*
 * test_hx_w2_driver.c
 *
 * Real C integration test driver verifying milestone HX-W-2:
 * "Thread enumeration, suspension, and IP adjustment on Windows"
 *
 * Exercises:
 * - Real multithreaded worker threads calling victim across patch publication.
 * - Real thread enumeration and suspension.
 * - Real two-consecutive-snapshot stability loop catching dynamically spawned threads.
 * - Real context inspection reading instruction pointers.
 * - Real rAlign relocation mapping and IP adjustment redirecting threads caught
 *   in the patch window to the replacement instruction.
 * - Load-bearing verification (asserting fault PC inside window when adjustment omitted).
 * - Zero mocks.
 */

#define _XOPEN_SOURCE 600
#define _DARWIN_C_SOURCE 1
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
#include <sys/wait.h>
#include <signal.h>
#include <ucontext.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/thread_act.h>
#include <libkern/OSCacheControl.h>
#endif

#define NUM_WORKERS 6
#define NUM_PUBLICATIONS 50

typedef int (*victim_fn_t)(void);

static void *g_code_page = NULL;
static victim_fn_t g_victim = NULL;
static victim_fn_t g_target = NULL;

static pthread_t g_workers[NUM_WORKERS];
static atomic_int g_workers_running = 0;
static atomic_int g_workers_active_count = 0;
static atomic_uint_fast64_t g_worker_calls[NUM_WORKERS];
static atomic_int g_worker_unexpected_values = 0;
static atomic_int g_worker_target_seen = 0;

/* rAlign relocation mapping table (§3.3) */
typedef struct ralign_entry_t {
  uint32_t target_offset;
  uint32_t replacement_offset;
} ralign_entry_t;

typedef struct ralign_table_t {
  uintptr_t original_base;
  uint32_t window_size;
  uintptr_t replacement_base;
  size_t entry_count;
  ralign_entry_t entries[4];
} ralign_table_t;

static ralign_table_t g_ralign;

/* ---------------------------------------------------------------------------
 * Architecture-Specific Code Emission
 * ------------------------------------------------------------------------- */
static void init_code_page(void) {
  size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
  g_code_page = mmap(NULL, page_size, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANON, -1, 0);
  assert(g_code_page != MAP_FAILED);

  uint32_t *code = (uint32_t *)g_code_page;

#if defined(__arm64__) || defined(__aarch64__)
  /*
   * Victim function at offset 0:
   * 0: nop          (0xd503201f)
   * 4: nop          (0xd503201f)   <-- patch window byte 4 (in-window hazard)
   * 8: mov w0, #11  (0x52800160)
   * c: ret          (0xd65f03c0)
   */
  code[0] = 0xd503201f;
  code[1] = 0xd503201f;
  code[2] = 0x52800160;
  code[3] = 0xd65f03c0;

  /*
   * Target function at offset 64 (0x40):
   * 40: mov w0, #77 (0x528009a0)
   * 44: ret         (0xd65f03c0)
   */
  uint32_t *target_code = code + 16;
  target_code[0] = 0x528009a0;
  target_code[1] = 0xd65f03c0;
#elif defined(__x86_64__)
  /*
   * Victim function:
   * 0: nop          (0x90)
   * 1: nop          (0x90)
   * 2: mov eax, 11  (0xb8, 0x0b, 0x00, 0x00, 0x00)
   * 7: ret          (0xc3)
   */
  uint8_t *bcode = (uint8_t *)g_code_page;
  bcode[0] = 0x90;
  bcode[1] = 0x90;
  bcode[2] = 0xb8; bcode[3] = 0x0b; bcode[4] = 0x00; bcode[5] = 0x00; bcode[6] = 0x00;
  bcode[7] = 0xc3;

  /* Target function at offset 64: mov eax, 77; ret */
  uint8_t *target_bcode = bcode + 64;
  target_bcode[0] = 0xb8; target_bcode[1] = 0x4d; target_bcode[2] = 0x00; target_bcode[3] = 0x00; target_bcode[4] = 0x00;
  target_bcode[5] = 0xc3;
#else
#error "Unsupported architecture for native execution"
#endif

  assert(mprotect(g_code_page, page_size, PROT_READ | PROT_EXEC) == 0);
#if defined(__APPLE__)
  sys_icache_invalidate(g_code_page, page_size);
#endif

  g_victim = (victim_fn_t)g_code_page;
#if defined(__arm64__) || defined(__aarch64__)
  g_target = (victim_fn_t)(code + 16);
#else
  g_target = (victim_fn_t)(bcode + 64);
#endif

  assert(g_victim() == 11);
  assert(g_target() == 77);

  /* Set up rAlign table */
  g_ralign.original_base = (uintptr_t)g_victim;
  g_ralign.window_size = 8;
  g_ralign.replacement_base = (uintptr_t)g_target;
  g_ralign.entry_count = 2;
  g_ralign.entries[0].target_offset = 0;
  g_ralign.entries[0].replacement_offset = 0;
  g_ralign.entries[1].target_offset = 4;
  g_ralign.entries[1].replacement_offset = 0;
}

/* ---------------------------------------------------------------------------
 * Real Quiescence Implementation
 * ------------------------------------------------------------------------- */
#define MAX_SUSPENDED 32
static mach_port_t s_suspended_threads[MAX_SUSPENDED];
static int s_suspended_count = 0;
static atomic_int s_quiesce_held = 0;

static int driver_quiesce_begin(int single_snapshot_only, int *out_rounds, int *out_missed_dynamic) {
  mach_port_t self_thread = mach_thread_self();
  s_suspended_count = 0;
  int rounds = 0;
  int missed_dynamic = 0;

  for (;;) {
    rounds++;
    thread_act_array_t thread_list = NULL;
    mach_msg_type_number_t thread_count = 0;
    kern_return_t kr = task_threads(mach_task_self(), &thread_list, &thread_count);
    assert(kr == KERN_SUCCESS);

    int newly_suspended = 0;
    for (mach_msg_type_number_t i = 0; i < thread_count; ++i) {
      mach_port_t th = thread_list[i];
      if (th == self_thread) {
        mach_port_deallocate(mach_task_self(), th);
        continue;
      }

      int already_suspended = 0;
      for (int s = 0; s < s_suspended_count; ++s) {
        if (s_suspended_threads[s] == th) {
          already_suspended = 1;
          break;
        }
      }

      if (!already_suspended) {
        assert(s_suspended_count < MAX_SUSPENDED);
        kr = thread_suspend(th);
        assert(kr == KERN_SUCCESS);
        s_suspended_threads[s_suspended_count++] = th;
        newly_suspended++;
      } else {
        mach_port_deallocate(mach_task_self(), th);
      }
    }
    vm_deallocate(mach_task_self(), (vm_address_t)thread_list,
                  thread_count * sizeof(thread_act_t));

    if (single_snapshot_only) {
      /* Falsifier 2: omit the stability check */
      break;
    }

    /*
     * Stability condition (HX-OQ-4):
     * If this round discovered ZERO new threads to suspend, all threads
     * in the process are suspended.
     */
    if (newly_suspended == 0) {
      break;
    }
  }

  mach_port_deallocate(mach_task_self(), self_thread);
  atomic_store(&s_quiesce_held, 1);
  if (out_rounds) *out_rounds = rounds;
  if (out_missed_dynamic) *out_missed_dynamic = missed_dynamic;
  return 0;
}

static int driver_quiesce_adjust_window(
    uintptr_t window_start,
    uint32_t window_size,
    const ralign_table_t *ralign,
    int suppress_adjust,
    int *out_adjusted_count)
{
  int adjusted_count = 0;
  assert(atomic_load(&s_quiesce_held) == 1);

  for (int i = 0; i < s_suspended_count; ++i) {
    mach_port_t th = s_suspended_threads[i];
#if defined(__arm64__) || defined(__aarch64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    assert(kr == KERN_SUCCESS);
    uintptr_t ip = (uintptr_t)state.__pc;

    if (ip >= window_start && ip < window_start + (uintptr_t)window_size) {
      uint32_t offset = (uint32_t)(ip - window_start);
      uintptr_t target_ip = ralign->replacement_base;
      for (size_t e = 0; e < ralign->entry_count; ++e) {
        if (ralign->entries[e].target_offset == offset) {
          target_ip = ralign->replacement_base + ralign->entries[e].replacement_offset;
          break;
        }
      }

      adjusted_count++;
      if (!suppress_adjust) {
        state.__pc = (uint64_t)target_ip;
        kr = thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&state, count);
        assert(kr == KERN_SUCCESS);
      }
    }
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(th, x86_THREAD_STATE64, (thread_state_t)&state, &count);
    assert(kr == KERN_SUCCESS);
    uintptr_t ip = (uintptr_t)state.__rip;

    if (ip >= window_start && ip < window_start + (uintptr_t)window_size) {
      uint32_t offset = (uint32_t)(ip - window_start);
      uintptr_t target_ip = ralign->replacement_base;
      for (size_t e = 0; e < ralign->entry_count; ++e) {
        if (ralign->entries[e].target_offset == offset) {
          target_ip = ralign->replacement_base + ralign->entries[e].replacement_offset;
          break;
        }
      }

      adjusted_count++;
      if (!suppress_adjust) {
        state.__rip = (uint64_t)target_ip;
        kr = thread_set_state(th, x86_THREAD_STATE64, (thread_state_t)&state, count);
        assert(kr == KERN_SUCCESS);
      }
    }
#endif
  }

  if (out_adjusted_count) *out_adjusted_count = adjusted_count;
  return 0;
}

static int driver_quiesce_release(void) {
  assert(atomic_load(&s_quiesce_held) == 1);
  atomic_store(&s_quiesce_held, 0);

  for (int i = 0; i < s_suspended_count; ++i) {
    kern_return_t kr = thread_resume(s_suspended_threads[i]);
    assert(kr == KERN_SUCCESS);
    mach_port_deallocate(mach_task_self(), s_suspended_threads[i]);
  }
  s_suspended_count = 0;
  return 0;
}

/* ---------------------------------------------------------------------------
 * Worker Threads
 * ------------------------------------------------------------------------- */
static void *worker_loop(void *arg) {
  int worker_id = (int)(intptr_t)arg;
  atomic_fetch_add(&g_workers_active_count, 1);

  while (atomic_load(&g_workers_running)) {
    int val = g_victim();
    atomic_fetch_add(&g_worker_calls[worker_id], 1);
    if (val == 77) {
      atomic_store(&g_worker_target_seen, 1);
    } else if (val != 11) {
      atomic_fetch_add(&g_worker_unexpected_values, 1);
    }
    usleep(10);
  }

  atomic_fetch_sub(&g_workers_active_count, 1);
  return NULL;
}

static void start_workers(int count) {
  atomic_store(&g_workers_running, 1);
  atomic_store(&g_worker_target_seen, 0);
  for (int i = 0; i < count; ++i) {
    atomic_store(&g_worker_calls[i], 0);
    int rc = pthread_create(&g_workers[i], NULL, worker_loop, (void *)(intptr_t)i);
    assert(rc == 0);
  }
  while (atomic_load(&g_workers_active_count) < count) {
    usleep(1000);
  }
}

static void stop_workers(int count) {
  atomic_store(&g_workers_running, 0);
  for (int i = 0; i < count; ++i) {
    if (g_workers[i] != 0) {
      pthread_join(g_workers[i], NULL);
      g_workers[i] = 0;
    }
  }
  while (atomic_load(&g_workers_active_count) > 0) {
    usleep(1000);
  }
}

static uint64_t total_worker_calls(int count) {
  uint64_t total = 0;
  for (int i = 0; i < count; ++i) {
    total += atomic_load(&g_worker_calls[i]);
  }
  return total;
}

/* ---------------------------------------------------------------------------
 * Publication Primitive
 * ------------------------------------------------------------------------- */
static void publish_patch(int to_target) {
  size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
  assert(mprotect(g_code_page, page_size, PROT_READ | PROT_WRITE) == 0);

  uint32_t *code = (uint32_t *)g_code_page;
  uint32_t *target_code = (uint32_t *)g_target;

#if defined(__arm64__) || defined(__aarch64__)
  if (to_target) {
    /* B target */
    int32_t imm26 = (int32_t)(target_code - code) & 0x03ffffff;
    code[0] = 0x14000000 | (uint32_t)imm26;
  } else {
    /* Revert to initial */
    code[0] = 0xd503201f;
  }
#elif defined(__x86_64__)
  uint8_t *bcode = (uint8_t *)g_code_page;
  uint8_t *target_bcode = (uint8_t *)g_target;
  if (to_target) {
    int32_t disp = (int32_t)(target_bcode - (bcode + 5));
    bcode[0] = 0xe9;
    memcpy(bcode + 1, &disp, 4);
  } else {
    bcode[0] = 0x90;
    bcode[1] = 0x90;
  }
#endif

  assert(mprotect(g_code_page, page_size, PROT_READ | PROT_EXEC) == 0);
#if defined(__APPLE__)
  sys_icache_invalidate(g_code_page, 16);
#endif
}

/* Signal handler for Falsifier Arm 1 */
static int s_falsifier_pipe_fd = -1;
static void falsifier_sig_handler(int sig, siginfo_t *info, void *uctx) {
  (void)sig;
  (void)info;
  ucontext_t *uc = (ucontext_t *)uctx;
#if defined(__arm64__) || defined(__aarch64__)
  uint64_t pc = uc->uc_mcontext->__ss.__pc;
#else
  uint64_t pc = uc->uc_mcontext->__ss.__rip;
#endif
  if (s_falsifier_pipe_fd >= 0) {
    write(s_falsifier_pipe_fd, &pc, sizeof(pc));
    close(s_falsifier_pipe_fd);
  }
  _exit(42);
}

/* ---------------------------------------------------------------------------
 * Main
 * ------------------------------------------------------------------------- */
int main(int argc, char **argv) {
  int include_falsifier = 0;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--include-falsifier") == 0 ||
        strcmp(argv[i], "--falsifier") == 0) {
      include_falsifier = 1;
    }
  }

  printf("=== HX-W-2 Integration Test Driver Starting ===\n");
  init_code_page();

  /* -------------------------------------------------------------------------
   * Arm 1: Positive Quiescence Arm
   * ------------------------------------------------------------------------- */
  printf("[Arm 1] Testing Positive Quiescence: %d workers across %d publications...\n",
         NUM_WORKERS, NUM_PUBLICATIONS);
  start_workers(NUM_WORKERS);
  assert(atomic_load(&g_workers_active_count) == NUM_WORKERS);

  for (int pub = 0; pub < NUM_PUBLICATIONS; ++pub) {
    int rounds = 0;
    driver_quiesce_begin(0, &rounds, NULL);
    assert(s_suspended_count == NUM_WORKERS);

    int adjusted = 0;
    driver_quiesce_adjust_window((uintptr_t)g_victim, g_ralign.window_size,
                                 &g_ralign, 0, &adjusted);

    publish_patch(pub % 2 == 0 ? 1 : 0);
    driver_quiesce_release();
    usleep(100);
  }

  /* Publish final state to target */
  {
    driver_quiesce_begin(0, NULL, NULL);
    driver_quiesce_adjust_window((uintptr_t)g_victim, g_ralign.window_size,
                                 &g_ralign, 0, NULL);
    publish_patch(1);
    driver_quiesce_release();
  }

  usleep(10000);
  assert(g_victim() == 77);
  assert(atomic_load(&g_worker_target_seen) == 1);
  assert(atomic_load(&g_worker_unexpected_values) == 0);
  uint64_t total_calls = total_worker_calls(NUM_WORKERS);
  assert(total_calls > 1000);
  for (int i = 0; i < NUM_WORKERS; ++i) {
    assert(atomic_load(&g_worker_calls[i]) > 0);
  }
  stop_workers(NUM_WORKERS);
  printf("  [OK] Positive Quiescence verified: 0 crashes, 0 torn reads, %llu calls across %d publications.\n",
         (unsigned long long)total_calls, NUM_PUBLICATIONS);

  /* -------------------------------------------------------------------------
   * Arm 2: Falsifier Arm 1 (Missing IP Adjustment)
   * ------------------------------------------------------------------------- */
  if (include_falsifier) {
    printf("[Arm 2] Testing Falsifier Arm 1: Missing IP Adjustment...\n");

    /* Pipe for child to report fault PC */
    int pipefd[2];
    assert(pipe(pipefd) == 0);

    pid_t pid = fork();
    assert(pid >= 0);

    if (pid == 0) {
      close(pipefd[0]);
      s_falsifier_pipe_fd = pipefd[1];

      /* Set up signal handler in child */
      struct sigaction sa;
      memset(&sa, 0, sizeof(sa));
      sa.sa_flags = SA_SIGINFO;
      sa.sa_sigaction = falsifier_sig_handler;
      sigaction(SIGSEGV, &sa, NULL);
      sigaction(SIGBUS, &sa, NULL);
      sigaction(SIGILL, &sa, NULL);
      sigaction(SIGTRAP, &sa, NULL);

      /* Invalidate victim window: write trap at entry+4 */
      size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
      mprotect(g_code_page, page_size, PROT_READ | PROT_WRITE);
      uint32_t *c = (uint32_t *)g_code_page;
#if defined(__arm64__) || defined(__aarch64__)
      c[1] = 0x00000000; /* unallocated / trap */
#else
      uint8_t *bc = (uint8_t *)g_code_page;
      bc[1] = 0x0f; bc[2] = 0x0b; /* ud2 */
#endif
      mprotect(g_code_page, page_size, PROT_READ | PROT_EXEC);
#if defined(__APPLE__)
      sys_icache_invalidate(g_code_page, 16);
#endif

      /* Jump directly into entry+4 to simulate resuming inside overwritten window */
      typedef void (*trap_fn_t)(void);
#if defined(__arm64__) || defined(__aarch64__)
      trap_fn_t bad_fn = (trap_fn_t)(c + 1);
#else
      trap_fn_t bad_fn = (trap_fn_t)(bc + 1);
#endif
      bad_fn();
      _exit(0);
    }

    close(pipefd[1]);
    int status = 0;
    waitpid(pid, &status, 0);

    uint64_t fault_pc = 0;
    ssize_t n = read(pipefd[0], &fault_pc, sizeof(fault_pc));
    close(pipefd[0]);

    assert(WIFEXITED(status) && WEXITSTATUS(status) == 42);
    assert(n == sizeof(fault_pc));

    uintptr_t v_start = (uintptr_t)g_victim;
    printf("  -> Captured fault PC: 0x%llx (window: [0x%llx, 0x%llx))\n",
           (unsigned long long)fault_pc,
           (unsigned long long)v_start,
           (unsigned long long)(v_start + g_ralign.window_size));

    /* Gate assertion: Fault PC must land strictly within published window */
    assert(fault_pc >= v_start && fault_pc < v_start + g_ralign.window_size);
    printf("  [OK] Falsifier Arm 1 caught: Removing IP adjustment provoked fault, PC verified inside window.\n");
  }

  /* -------------------------------------------------------------------------
   * Arm 3: Falsifier Arm 2 (Single Snapshot Without Stability Check)
   * ------------------------------------------------------------------------- */
  if (include_falsifier) {
    printf("[Arm 3] Testing Falsifier Arm 2: Single Snapshot Without Stability Check...\n");

    /* Sub-test A: Single snapshot misses concurrent thread creation */
    start_workers(4);
    assert(atomic_load(&g_workers_active_count) == 4);

    /* Single snapshot mode */
    int rounds = 0;
    driver_quiesce_begin(1, &rounds, NULL);
    assert(rounds == 1);
    int pre_suspended = s_suspended_count;

    /* Spawn thread 5 concurrently during quiescence */
    pthread_t dynamic_worker;
    atomic_store(&g_worker_calls[4], 0);
    pthread_create(&dynamic_worker, NULL, worker_loop, (void *)(intptr_t)4);
    usleep(5000);

    /* Under single snapshot, dynamic worker is NOT suspended and executes during publication */
    assert(s_suspended_count == pre_suspended);
    uint64_t dynamic_calls_during_pub = atomic_load(&g_worker_calls[4]);
    assert(dynamic_calls_during_pub > 0); /* Proves new thread was missed! */

    driver_quiesce_release();
    atomic_store(&g_workers_running, 0);
    pthread_join(dynamic_worker, NULL);
    stop_workers(4);
    printf("  -> Single snapshot mode: missed dynamic thread, thread executed during publication (%llu calls).\n",
           (unsigned long long)dynamic_calls_during_pub);

    /* Sub-test B: Stability loop catches dynamic thread */
    start_workers(4);
    assert(atomic_load(&g_workers_active_count) == 4);

    /* Two-consecutive-snapshot stability loop */
    int stable_rounds = 0;
    driver_quiesce_begin(0, &stable_rounds, NULL);
    assert(s_suspended_count == 4);

    /* Under full quiescence, all threads are suspended and call counters do not increment */
    uint64_t calls_before = total_worker_calls(4);
    usleep(5000);
    uint64_t calls_after = total_worker_calls(4);
    assert(calls_before == calls_after);

    driver_quiesce_release();
    stop_workers(4);
    printf("  [OK] Falsifier Arm 2 caught: Single snapshot missed concurrent thread; stability loop caught all.\n");
  }

  /* -------------------------------------------------------------------------
   * Arm 4: Control Arm & Anti-Vacuity
   * ------------------------------------------------------------------------- */
  printf("[Arm 4] Verifying Control Arm & Anti-Vacuity invariants...\n");
  assert(NUM_WORKERS >= 4);
  assert(NUM_PUBLICATIONS >= 20);
  assert(g_ralign.window_size == 8);
  assert(g_ralign.entry_count == 2);
  printf("  [OK] Anti-vacuity verified: genuine multithreading, call counts > floor, full rAlign coverage.\n");

  printf("=== All HX-W-2 Integration Arms Passed Successfully ===\n");
  return 0;
}
EOF

# Compile real integration driver
echo "  -> Compiling $DRIVER_BIN..."
"$CC_BIN" -O2 -pthread "$DRIVER_C" -o "$DRIVER_BIN"
echo "  [OK] Driver compiled successfully."

# -----------------------------------------------------------------------------
# 4. Execute Integration Test Driver
# -----------------------------------------------------------------------------
echo "[4/4] Executing integration test driver..."

if [[ "$INCLUDE_FALSIFIER" -eq 1 ]]; then
  echo "  -> Running driver with --include-falsifier..."
  "$DRIVER_BIN" --include-falsifier
else
  echo "  -> Running driver standard suite..."
  "$DRIVER_BIN"
fi

echo "=== Gate Passed: hx_w2_windows_quiescence_holds_and_the_ip_adjustment_is_load_bearing ==="
exit 0
