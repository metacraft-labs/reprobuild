/* repro_hcr_rb_abi_state.h -- registry state and trace.
 *
 * ONE implementation of the application-facing `rb_hcr_*` ABI (HCR-Overview
 * § 13), shared by every platform arm.
 *
 * WHAT WAS WRONG, AND WHY IT COULD NOT BE SEEN. The thirteen functions are
 * declared unconditionally by `repro_hcr_agent.h`, and were DEFINED only in
 * the POSIX translation unit. `repro_hcr_agent_windows.c` defined none, so a
 * Windows application that linked the agent failed at LINK time with undefined
 * symbols -- reproduced on a Linux host 2026-09-20 with clang targeting
 * x86_64-w64-windows-gnu: five distinct `rb_hcr_*` symbols, no executable.
 * A linker error names a symbol, not a reason, so no diagnostic the agent
 * could write ever reached the developer.
 *
 * WHY SHARED RATHER THAN COPIED. Almost all of this is state manipulation with
 * no operating system in it: registration, removal, managed-type
 * de-duplication, the applied-reload window, the trace, the padded allocator's
 * bookkeeping. A second copy of state machinery drifts from the first
 * silently, which this workspace records as a recurring defect class. Only
 * THREE things genuinely need a platform, and each is a named seam the
 * including translation unit defines BEFORE including this file:
 *
 *   rb_hcr_platform_pending_active()  -- is a reload parked for the app?
 *   rb_hcr_platform_apply_pending()   -- apply it (or refuse, by name)
 *   rb_hcr_platform_padded_lock/unlock() -- the allocator's mutual exclusion
 *
 * The POSIX arm fills them with the real lifecycle and a pthread mutex. An arm
 * whose lifecycle is not wired fills the middle one with a NAMED REFUSAL,
 * which is what turns a link error into a diagnostic.
 *
 * Included once per translation unit. Not public, not installed.
 */

#ifndef REPRO_HCR_RB_ABI_STATE_H
#define REPRO_HCR_RB_ABI_STATE_H

#define RB_HCR_MAX_CALLBACKS 64
#define RB_HCR_MAX_MANAGED_TYPES 128
#define RB_HCR_MAX_CHANGED_FILES 64
#define RB_HCR_MAX_CHANGED_TYPES 64
#define RB_HCR_TRACE_CAPACITY 512
#define RB_HCR_DIAGNOSTIC_CAPACITY 1024

typedef struct {
  RbHcrReloadCallback callback;
  void *user_data;
} rb_hcr_callback_entry;

typedef struct {
  char *name;
  uint32_t old_size;
  uint32_t new_size;
} rb_hcr_type_change_record;

static rb_hcr_callback_entry rb_hcr_before_callbacks[RB_HCR_MAX_CALLBACKS];
static size_t rb_hcr_before_callback_count = 0;

static rb_hcr_callback_entry rb_hcr_after_callbacks[RB_HCR_MAX_CALLBACKS];
static size_t rb_hcr_after_callback_count = 0;

/* § 13.2: "the canonical type name as it appears in debug info". The registry
 * stores the caller's `const char*` and does NOT copy it — matching the shipped
 * baseline this replaced, and matching what the IsoNim stub records as pinned.
 * Matching is exact strcmp; there is no glob (stub OPEN-2). */
static const char *rb_hcr_managed_types[RB_HCR_MAX_MANAGED_TYPES];
static size_t rb_hcr_managed_type_count = 0;

/* The introspection window: what the most recent APPLIED reload listed.
 * Owned copies, because the wire buffer they were parsed out of is freed when
 * the frame is. */
typedef struct {
  char *files[RB_HCR_MAX_CHANGED_FILES];
  size_t file_count;
  char *types[RB_HCR_MAX_CHANGED_TYPES];
  size_t type_count;
} rb_hcr_applied_window;

static rb_hcr_applied_window rb_hcr_applied;
static rb_hcr_applied_window rb_hcr_applied_saved;

/* Evidence surface. Every field below is a read of state the production
 * lifecycle already recorded; nothing here is written by a test. The lifecycle
 * trace is the same vocabulary the IsoNim stub emits, so the two repos'
 * gates assert the same words. */
static char rb_hcr_trace[RB_HCR_TRACE_CAPACITY];
static size_t rb_hcr_trace_len = 0;
static int rb_hcr_last_before_fired = 0;
static int rb_hcr_last_after_fired = 0;
static int rb_hcr_last_code_swapped = 0;
static char rb_hcr_last_rejection[RB_HCR_DIAGNOSTIC_CAPACITY];
static char rb_hcr_last_unmanaged[RB_HCR_DIAGNOSTIC_CAPACITY];
static unsigned long rb_hcr_apply_calls = 0;

static void rb_hcr_trace_reset(void) {
  rb_hcr_trace[0] = '\0';
  rb_hcr_trace_len = 0;
}

static void rb_hcr_trace_add(const char *phase) {
  size_t need = strlen(phase);
  if (rb_hcr_trace_len + need + 2 >= sizeof(rb_hcr_trace)) {
    return;
  }
  if (rb_hcr_trace_len > 0) {
    rb_hcr_trace[rb_hcr_trace_len++] = ',';
  }
  memcpy(rb_hcr_trace + rb_hcr_trace_len, phase, need);
  rb_hcr_trace_len += need;
  rb_hcr_trace[rb_hcr_trace_len] = '\0';
}

#endif /* REPRO_HCR_RB_ABI_STATE_H */
