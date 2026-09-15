/*
 * Windows x86_64 HCR thread quiescence (HX-W-2).
 *
 * This component is intentionally header-local like the Linux provider arms:
 * the C agent includes it into one translation unit, while the integration
 * probe can compile the exact production implementation without exporting a
 * second ABI.  It allocates no memory and invokes no application callback once
 * the first peer thread has been suspended.
 */

#ifndef REPRO_HCR_WINDOWS_QUIESCE_H
#define REPRO_HCR_WINDOWS_QUIESCE_H

#if !defined(_WIN32) || !defined(_M_X64)
#error "repro_hcr_windows_quiesce.h requires Windows x86_64"
#endif

#include <stdint.h>
#include <windows.h>
#include <tlhelp32.h>

#ifndef REPRO_HCR_WQ_MAX_THREADS
#define REPRO_HCR_WQ_MAX_THREADS 512
#endif

#ifndef REPRO_HCR_WQ_MAX_ENUMERATION_ROUNDS
#define REPRO_HCR_WQ_MAX_ENUMERATION_ROUNDS 64
#endif

/* Test-only scheduling hooks are macros so the production translation unit has
 * no function pointer, callback, or branch to invoke while suspension is held. */
#ifndef REPRO_HCR_WQ_AFTER_FIRST_SNAPSHOT
#define REPRO_HCR_WQ_AFTER_FIRST_SNAPSHOT() ((void)0)
#endif

#ifndef REPRO_HCR_WQ_SINGLE_SNAPSHOT_FOR_TEST
#define REPRO_HCR_WQ_SINGLE_SNAPSHOT_FOR_TEST() 0
#endif

typedef enum repro_hcr_wq_status {
  REPRO_HCR_WQ_OK = 0,
  REPRO_HCR_WQ_ALREADY_HELD = 1,
  REPRO_HCR_WQ_ENUMERATION_FAILED = 2,
  REPRO_HCR_WQ_TOO_MANY_THREADS = 3,
  REPRO_HCR_WQ_OPEN_THREAD_FAILED = 4,
  REPRO_HCR_WQ_THREAD_IDENTITY_CHANGED = 5,
  REPRO_HCR_WQ_SUSPEND_FAILED = 6,
  REPRO_HCR_WQ_GET_CONTEXT_FAILED = 7,
  REPRO_HCR_WQ_SET_CONTEXT_FAILED = 8,
  REPRO_HCR_WQ_INVALID_IP = 9,
  REPRO_HCR_WQ_RESUME_FAILED = 10,
  REPRO_HCR_WQ_UNSTABLE_THREAD_SET = 11
} repro_hcr_wq_status;

typedef struct repro_hcr_wq_slot {
  DWORD tid;
  HANDLE handle;
  DWORD previous_suspend_count;
  CONTEXT context;
  uint64_t original_rip;
  int active;
  int context_valid;
  int context_changed;
} repro_hcr_wq_slot;

typedef struct repro_hcr_wq_state {
  repro_hcr_wq_slot slots[REPRO_HCR_WQ_MAX_THREADS];
  DWORD snapshot_a[REPRO_HCR_WQ_MAX_THREADS];
  DWORD snapshot_b[REPRO_HCR_WQ_MAX_THREADS];
  DWORD patcher_tid;
  DWORD process_id;
  DWORD failed_tid;
  DWORD win32_error;
  int held;
  int status;
  int slot_high_water;
  int suspended_count;
  int exited_count;
  int enumeration_rounds;
  int first_snapshot_count;
  int final_snapshot_count;
  int context_count;
  int adjustment_opportunities;
  int adjusted_count;
  uint64_t invalid_rip;
} repro_hcr_wq_state;

static repro_hcr_wq_state repro_hcr_wq;

static const char *repro_hcr_wq_status_name(int status) {
  switch ((repro_hcr_wq_status)status) {
  case REPRO_HCR_WQ_OK:
    return "ok";
  case REPRO_HCR_WQ_ALREADY_HELD:
    return "quiescence-already-held";
  case REPRO_HCR_WQ_ENUMERATION_FAILED:
    return "quiescence-enumeration-failed";
  case REPRO_HCR_WQ_TOO_MANY_THREADS:
    return "quiescence-too-many-threads";
  case REPRO_HCR_WQ_OPEN_THREAD_FAILED:
    return "quiescence-open-thread-failed";
  case REPRO_HCR_WQ_THREAD_IDENTITY_CHANGED:
    return "quiescence-thread-identity-changed";
  case REPRO_HCR_WQ_SUSPEND_FAILED:
    return "quiescence-suspend-failed";
  case REPRO_HCR_WQ_GET_CONTEXT_FAILED:
    return "quiescence-get-context-failed";
  case REPRO_HCR_WQ_SET_CONTEXT_FAILED:
    return "quiescence-set-context-failed";
  case REPRO_HCR_WQ_INVALID_IP:
    return "quiescence-invalid-ip";
  case REPRO_HCR_WQ_RESUME_FAILED:
    return "quiescence-resume-failed";
  case REPRO_HCR_WQ_UNSTABLE_THREAD_SET:
    return "quiescence-thread-set-unstable";
  default:
    return "quiescence-unknown-failure";
  }
}

static void repro_hcr_wq_sort_tids(DWORD *tids, int count) {
  int i;
  for (i = 1; i < count; ++i) {
    DWORD value = tids[i];
    int j = i;
    while (j > 0 && tids[j - 1] > value) {
      tids[j] = tids[j - 1];
      --j;
    }
    tids[j] = value;
  }
}

static int repro_hcr_wq_sets_agree(const DWORD *a, int a_count,
                                   const DWORD *b, int b_count) {
  int i;
  if (a_count != b_count) {
    return 0;
  }
  for (i = 0; i < a_count; ++i) {
    if (a[i] != b[i]) {
      return 0;
    }
  }
  return 1;
}

/* Tool Help's TH32CS_SNAPTHREAD snapshot is system-wide even when a process id
 * is supplied.  Filtering th32OwnerProcessID is therefore load-bearing. */
static int repro_hcr_wq_snapshot(DWORD *tids, int *count_out) {
  HANDLE snapshot;
  THREADENTRY32 entry;
  int count = 0;
  DWORD error;

  snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    repro_hcr_wq.win32_error = GetLastError();
    return REPRO_HCR_WQ_ENUMERATION_FAILED;
  }

  ZeroMemory(&entry, sizeof(entry));
  entry.dwSize = sizeof(entry);
  if (!Thread32First(snapshot, &entry)) {
    error = GetLastError();
    CloseHandle(snapshot);
    repro_hcr_wq.win32_error = error;
    return REPRO_HCR_WQ_ENUMERATION_FAILED;
  }

  for (;;) {
    if (entry.th32OwnerProcessID == repro_hcr_wq.process_id &&
        entry.th32ThreadID != repro_hcr_wq.patcher_tid) {
      if (count >= REPRO_HCR_WQ_MAX_THREADS) {
        CloseHandle(snapshot);
        return REPRO_HCR_WQ_TOO_MANY_THREADS;
      }
      tids[count++] = entry.th32ThreadID;
    }
    entry.dwSize = sizeof(entry);
    if (!Thread32Next(snapshot, &entry)) {
      error = GetLastError();
      break;
    }
  }
  CloseHandle(snapshot);
  if (error != ERROR_NO_MORE_FILES) {
    repro_hcr_wq.win32_error = error;
    return REPRO_HCR_WQ_ENUMERATION_FAILED;
  }
  repro_hcr_wq_sort_tids(tids, count);
  *count_out = count;
  return REPRO_HCR_WQ_OK;
}

static int repro_hcr_wq_find_slot(DWORD tid) {
  int i;
  for (i = 0; i < repro_hcr_wq.slot_high_water; ++i) {
    if (repro_hcr_wq.slots[i].active && repro_hcr_wq.slots[i].tid == tid) {
      return i;
    }
  }
  return -1;
}

static int repro_hcr_wq_new_slot(void) {
  int i;
  for (i = 0; i < repro_hcr_wq.slot_high_water; ++i) {
    if (!repro_hcr_wq.slots[i].active) {
      return i;
    }
  }
  if (repro_hcr_wq.slot_high_water >= REPRO_HCR_WQ_MAX_THREADS) {
    return -1;
  }
  return repro_hcr_wq.slot_high_water++;
}

/* Resume exactly the increment owned by this attempt. A pre-existing suspend
 * count is deliberately preserved. All handles are closed even if one resume
 * fails, and the first live failure is retained. */
static int repro_hcr_wq_release_owned(void) {
  int i;
  int failure = REPRO_HCR_WQ_OK;
  DWORD failure_tid = 0;
  DWORD failure_error = 0;
  for (i = repro_hcr_wq.slot_high_water - 1; i >= 0; --i) {
    repro_hcr_wq_slot *slot = &repro_hcr_wq.slots[i];
    if (!slot->active) {
      continue;
    }
    if (ResumeThread(slot->handle) == (DWORD)-1) {
      DWORD error = GetLastError();
      if (WaitForSingleObject(slot->handle, 0) != WAIT_OBJECT_0 &&
          failure == REPRO_HCR_WQ_OK) {
        failure = REPRO_HCR_WQ_RESUME_FAILED;
        failure_tid = slot->tid;
        failure_error = error;
      }
    }
    CloseHandle(slot->handle);
    slot->handle = NULL;
    slot->active = 0;
  }
  repro_hcr_wq.held = 0;
  if (failure != REPRO_HCR_WQ_OK) {
    repro_hcr_wq.status = failure;
    repro_hcr_wq.failed_tid = failure_tid;
    repro_hcr_wq.win32_error = failure_error;
  }
  return failure;
}

static int repro_hcr_wq_fail(int status, DWORD tid, DWORD error) {
  int release_status;
  repro_hcr_wq.status = status;
  repro_hcr_wq.failed_tid = tid;
  repro_hcr_wq.win32_error = error;
  release_status = repro_hcr_wq_release_owned();
  if (release_status != REPRO_HCR_WQ_OK) {
    return release_status;
  }
  /* release_owned intentionally retains the caller's status on success. */
  repro_hcr_wq.status = status;
  repro_hcr_wq.failed_tid = tid;
  repro_hcr_wq.win32_error = error;
  return status;
}

static int repro_hcr_wq_suspend_new_tid(DWORD tid) {
  HANDLE handle;
  DWORD previous;
  DWORD error;
  DWORD owner;
  int slot_index;
  repro_hcr_wq_slot *slot;

  handle = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT |
                          THREAD_SET_CONTEXT | THREAD_QUERY_INFORMATION,
                      FALSE, tid);
  if (handle == NULL) {
    return repro_hcr_wq_fail(REPRO_HCR_WQ_OPEN_THREAD_FAILED, tid,
                             GetLastError());
  }
  owner = GetProcessIdOfThread(handle);
  if (owner != repro_hcr_wq.process_id) {
    error = GetLastError();
    CloseHandle(handle);
    return repro_hcr_wq_fail(REPRO_HCR_WQ_THREAD_IDENTITY_CHANGED, tid,
                             error);
  }
  previous = SuspendThread(handle);
  if (previous == (DWORD)-1) {
    error = GetLastError();
    if (WaitForSingleObject(handle, 0) == WAIT_OBJECT_0) {
      /* Exit is independently proven by the signaled thread object; the
       * SuspendThread error itself is never interpreted as proof of exit. */
      repro_hcr_wq.exited_count += 1;
      CloseHandle(handle);
      return REPRO_HCR_WQ_OK;
    }
    CloseHandle(handle);
    return repro_hcr_wq_fail(REPRO_HCR_WQ_SUSPEND_FAILED, tid, error);
  }

  slot_index = repro_hcr_wq_new_slot();
  if (slot_index < 0) {
    (void)ResumeThread(handle);
    CloseHandle(handle);
    return repro_hcr_wq_fail(REPRO_HCR_WQ_TOO_MANY_THREADS, tid, 0);
  }
  slot = &repro_hcr_wq.slots[slot_index];
  ZeroMemory(slot, sizeof(*slot));
  slot->tid = tid;
  slot->handle = handle;
  slot->previous_suspend_count = previous;
  slot->active = 1;
  repro_hcr_wq.suspended_count += 1;
  return REPRO_HCR_WQ_OK;
}

/* Suspend in waves until two equal snapshots contain no thread without a held
 * object handle. A target-created thread racing the first snapshot appears in
 * the next wave; after a complete wave, every target peer capable of creating
 * another thread is itself suspended. */
static int repro_hcr_wq_begin(void) {
  DWORD *current;
  DWORD *previous;
  int current_count = 0;
  int previous_count = -1;
  int round;
  int i;
  int new_threads;
  int status;

  if (repro_hcr_wq.held) {
    return REPRO_HCR_WQ_ALREADY_HELD;
  }
  ZeroMemory(&repro_hcr_wq, sizeof(repro_hcr_wq));
  repro_hcr_wq.patcher_tid = GetCurrentThreadId();
  repro_hcr_wq.process_id = GetCurrentProcessId();
  current = repro_hcr_wq.snapshot_a;
  previous = repro_hcr_wq.snapshot_b;

  for (round = 1; round <= REPRO_HCR_WQ_MAX_ENUMERATION_ROUNDS; ++round) {
    status = repro_hcr_wq_snapshot(current, &current_count);
    if (status != REPRO_HCR_WQ_OK) {
      return repro_hcr_wq_fail(status, 0, repro_hcr_wq.win32_error);
    }
    repro_hcr_wq.enumeration_rounds = round;
    if (round == 1) {
      repro_hcr_wq.first_snapshot_count = current_count;
      /* Runs before the first suspension. The production expansion is a
       * literal no-op; the gate uses it to create one real racing thread. */
      REPRO_HCR_WQ_AFTER_FIRST_SNAPSHOT();
    }

    new_threads = 0;
    for (i = 0; i < current_count; ++i) {
      int slot_index = repro_hcr_wq_find_slot(current[i]);
      if (slot_index >= 0 &&
          WaitForSingleObject(repro_hcr_wq.slots[slot_index].handle, 0) ==
              WAIT_OBJECT_0) {
        /* A numeric tid may be reused after termination. Retaining the old
         * handle lets us distinguish the old object from a new snapshot row. */
        CloseHandle(repro_hcr_wq.slots[slot_index].handle);
        repro_hcr_wq.slots[slot_index].handle = NULL;
        repro_hcr_wq.slots[slot_index].active = 0;
        repro_hcr_wq.exited_count += 1;
        slot_index = -1;
      }
      if (slot_index < 0) {
        status = repro_hcr_wq_suspend_new_tid(current[i]);
        if (status != REPRO_HCR_WQ_OK) {
          return status;
        }
        new_threads += 1;
      }
    }

    if (REPRO_HCR_WQ_SINGLE_SNAPSHOT_FOR_TEST() && round == 1) {
      break;
    }
    if (new_threads == 0 && previous_count >= 0 &&
        repro_hcr_wq_sets_agree(current, current_count, previous,
                                previous_count)) {
      break;
    }
    previous_count = current_count;
    for (i = 0; i < current_count; ++i) {
      previous[i] = current[i];
    }
    {
      DWORD *swap = current;
      current = previous;
      previous = swap;
    }
    SwitchToThread();
  }

  if (round > REPRO_HCR_WQ_MAX_ENUMERATION_ROUNDS) {
    return repro_hcr_wq_fail(REPRO_HCR_WQ_UNSTABLE_THREAD_SET, 0, 0);
  }
  repro_hcr_wq.final_snapshot_count = current_count;

  for (i = 0; i < repro_hcr_wq.slot_high_water; ++i) {
    repro_hcr_wq_slot *slot = &repro_hcr_wq.slots[i];
    if (!slot->active) {
      continue;
    }
    if (WaitForSingleObject(slot->handle, 0) == WAIT_OBJECT_0) {
      repro_hcr_wq.exited_count += 1;
      continue;
    }
    ZeroMemory(&slot->context, sizeof(slot->context));
    slot->context.ContextFlags = CONTEXT_CONTROL;
    if (!GetThreadContext(slot->handle, &slot->context)) {
      return repro_hcr_wq_fail(REPRO_HCR_WQ_GET_CONTEXT_FAILED, slot->tid,
                               GetLastError());
    }
    slot->original_rip = (uint64_t)slot->context.Rip;
    slot->context_valid = 1;
    repro_hcr_wq.context_count += 1;
  }

  repro_hcr_wq.held = 1;
  repro_hcr_wq.status = REPRO_HCR_WQ_OK;
  return REPRO_HCR_WQ_OK;
}

/* Windows v1's one-row rAlign equivalent.
 *
 * Once the two-hop entry is live, entry-5 is a real instruction boundary. A
 * thread parked there must resume at the previous dispatch before rollback
 * restores the padding to non-code. Strict interiors are never guessed at. */
static int repro_hcr_wq_validate_and_adjust_hotpatch_site(
    uint64_t entry, uint32_t original_first_instruction_length,
    uint64_t previous_dispatch, int suppress_adjustment_for_test) {
  uint64_t padding = entry - 5u;
  uint64_t original_end = entry + original_first_instruction_length;
  int i;
  int changed = 0;

  if (!repro_hcr_wq.held) {
    return REPRO_HCR_WQ_INVALID_IP;
  }
  if (original_first_instruction_length < 2u) {
    return repro_hcr_wq_fail(REPRO_HCR_WQ_INVALID_IP, 0, 0);
  }

  /* Validate the whole set before changing any context. */
  for (i = 0; i < repro_hcr_wq.slot_high_water; ++i) {
    repro_hcr_wq_slot *slot = &repro_hcr_wq.slots[i];
    uint64_t rip;
    if (!slot->active || !slot->context_valid) {
      continue;
    }
    rip = slot->original_rip;
    if ((rip > padding && rip < entry) ||
        (rip > entry && rip < original_end) ||
        (rip == padding && previous_dispatch == 0u)) {
      repro_hcr_wq.invalid_rip = rip;
      return repro_hcr_wq_fail(REPRO_HCR_WQ_INVALID_IP, slot->tid, 0);
    }
    if (rip == padding) {
      repro_hcr_wq.adjustment_opportunities += 1;
    }
  }

  if (suppress_adjustment_for_test) {
    return REPRO_HCR_WQ_OK;
  }
  for (i = 0; i < repro_hcr_wq.slot_high_water; ++i) {
    repro_hcr_wq_slot *slot = &repro_hcr_wq.slots[i];
    if (!slot->active || !slot->context_valid ||
        slot->original_rip != padding) {
      continue;
    }
    slot->context.Rip = (DWORD64)previous_dispatch;
    if (!SetThreadContext(slot->handle, &slot->context)) {
      DWORD error = GetLastError();
      int j;
      /* No target byte has changed yet. Restore earlier context edits before
       * releasing, preserving the prepare-phase abort property. */
      for (j = 0; j < i; ++j) {
        repro_hcr_wq_slot *prior = &repro_hcr_wq.slots[j];
        if (prior->context_changed) {
          prior->context.Rip = (DWORD64)prior->original_rip;
          (void)SetThreadContext(prior->handle, &prior->context);
          prior->context_changed = 0;
        }
      }
      return repro_hcr_wq_fail(REPRO_HCR_WQ_SET_CONTEXT_FAILED, slot->tid,
                               error);
    }
    slot->context_changed = 1;
    changed += 1;
  }
  repro_hcr_wq.adjusted_count = changed;
  return REPRO_HCR_WQ_OK;
}

static int repro_hcr_wq_contains_tid(DWORD tid) {
  return repro_hcr_wq_find_slot(tid) >= 0;
}

static int repro_hcr_wq_release(void) {
  if (!repro_hcr_wq.held) {
    return REPRO_HCR_WQ_ALREADY_HELD;
  }
  repro_hcr_wq.status = repro_hcr_wq_release_owned();
  return repro_hcr_wq.status;
}

#endif /* REPRO_HCR_WINDOWS_QUIESCE_H */
