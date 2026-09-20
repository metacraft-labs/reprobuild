/* repro_hcr_rb_abi.h -- the thirteen rb_hcr_* entry points.
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

#ifndef REPRO_HCR_RB_ABI_H
#define REPRO_HCR_RB_ABI_H

/* The three seams. Each including translation unit defines these before it
 * includes this header; see the file banner for why there are exactly three. */
static int  rb_hcr_platform_pending_active(void);
static void rb_hcr_platform_apply_pending(void);
static void rb_hcr_platform_padded_lock(void);
static void rb_hcr_platform_padded_unlock(void);
/* Aligned allocation is the fifth seam: POSIX has `posix_memalign`, Windows
 * has `_aligned_malloc`/`_aligned_free`, and a block from one MUST be released
 * by its own partner -- passing an `_aligned_malloc` block to `free` is
 * undefined on Windows, so the pair travels together rather than only the
 * allocator being abstracted. */
static int  rb_hcr_platform_aligned_alloc(void **out, size_t alignment, size_t size);
static void rb_hcr_platform_aligned_free(void *ptr);

bool rb_hcr_wants_reload(void) {
  /* § 13.1: non-blocking. In automatic mode nothing is ever parked, so this
   * answers false and an application that polls it simply never sees a patch
   * it has to drive — which is correct, because the agent already drove it. */
  return rb_hcr_platform_pending_active() != 0;
}

void rb_hcr_apply_reload(void) {
  rb_hcr_apply_calls++;
  if (!rb_hcr_platform_pending_active()) {
    /* § 13.1 says this blocks until the reload completes; with nothing pending
     * there is nothing to complete. The IsoNim stub calls the same case
     * `no-patch-pending` and treats it as a no-op. */
    rb_hcr_trace_reset();
    rb_hcr_trace_add("reject:no-patch-pending");
    return;
  }
  rb_hcr_platform_apply_pending();
}

void rb_hcr_register_managed_type(const char *type_name) {
  size_t i;
  if (type_name == NULL) {
    return;
  }
  for (i = 0; i < rb_hcr_managed_type_count; ++i) {
    if (rb_hcr_managed_types[i] != NULL &&
        strcmp(rb_hcr_managed_types[i], type_name) == 0) {
      return;
    }
  }
  if (rb_hcr_managed_type_count < RB_HCR_MAX_MANAGED_TYPES) {
    rb_hcr_managed_types[rb_hcr_managed_type_count++] = type_name;
  }
}

void rb_hcr_unregister_managed_type(const char *type_name) {
  size_t i;
  size_t j;
  if (type_name == NULL) {
    return;
  }
  for (i = 0; i < rb_hcr_managed_type_count; ++i) {
    if (rb_hcr_managed_types[i] != NULL &&
        strcmp(rb_hcr_managed_types[i], type_name) == 0) {
      for (j = i; j + 1 < rb_hcr_managed_type_count; ++j) {
        rb_hcr_managed_types[j] = rb_hcr_managed_types[j + 1];
      }
      rb_hcr_managed_type_count--;
      return;
    }
  }
}

void rb_hcr_before_reload(RbHcrReloadCallback callback, void *user_data) {
  size_t i;
  if (callback == NULL) {
    return;
  }
  for (i = 0; i < rb_hcr_before_callback_count; ++i) {
    if (rb_hcr_before_callbacks[i].callback == callback &&
        rb_hcr_before_callbacks[i].user_data == user_data) {
      return;
    }
  }
  if (rb_hcr_before_callback_count < RB_HCR_MAX_CALLBACKS) {
    rb_hcr_before_callbacks[rb_hcr_before_callback_count].callback = callback;
    rb_hcr_before_callbacks[rb_hcr_before_callback_count].user_data = user_data;
    rb_hcr_before_callback_count++;
  }
}

void rb_hcr_after_reload(RbHcrReloadCallback callback, void *user_data) {
  size_t i;
  if (callback == NULL) {
    return;
  }
  for (i = 0; i < rb_hcr_after_callback_count; ++i) {
    if (rb_hcr_after_callbacks[i].callback == callback &&
        rb_hcr_after_callbacks[i].user_data == user_data) {
      return;
    }
  }
  if (rb_hcr_after_callback_count < RB_HCR_MAX_CALLBACKS) {
    rb_hcr_after_callbacks[rb_hcr_after_callback_count].callback = callback;
    rb_hcr_after_callbacks[rb_hcr_after_callback_count].user_data = user_data;
    rb_hcr_after_callback_count++;
  }
}

void rb_hcr_remove_before_reload(RbHcrReloadCallback callback, void *user_data) {
  size_t i;
  size_t j;
  if (callback == NULL) {
    return;
  }
  for (i = 0; i < rb_hcr_before_callback_count; ++i) {
    if (rb_hcr_before_callbacks[i].callback == callback &&
        rb_hcr_before_callbacks[i].user_data == user_data) {
      for (j = i; j + 1 < rb_hcr_before_callback_count; ++j) {
        rb_hcr_before_callbacks[j] = rb_hcr_before_callbacks[j + 1];
      }
      rb_hcr_before_callback_count--;
      return;
    }
  }
}

void rb_hcr_remove_after_reload(RbHcrReloadCallback callback, void *user_data) {
  size_t i;
  size_t j;
  if (callback == NULL) {
    return;
  }
  for (i = 0; i < rb_hcr_after_callback_count; ++i) {
    if (rb_hcr_after_callbacks[i].callback == callback &&
        rb_hcr_after_callbacks[i].user_data == user_data) {
      for (j = i; j + 1 < rb_hcr_after_callback_count; ++j) {
        rb_hcr_after_callbacks[j] = rb_hcr_after_callbacks[j + 1];
      }
      rb_hcr_after_callback_count--;
      return;
    }
  }
}

bool rb_hcr_file_changed(const char *file_path) {
  size_t i;
  if (file_path == NULL) {
    return false;
  }
  for (i = 0; i < rb_hcr_applied.file_count; ++i) {
    if (rb_hcr_applied.files[i] != NULL &&
        strcmp(rb_hcr_applied.files[i], file_path) == 0) {
      return true;
    }
  }
  return false;
}

bool rb_hcr_type_changed(const char *type_name) {
  size_t i;
  if (type_name == NULL) {
    return false;
  }
  for (i = 0; i < rb_hcr_applied.type_count; ++i) {
    if (rb_hcr_applied.types[i] != NULL &&
        strcmp(rb_hcr_applied.types[i], type_name) == 0) {
      return true;
    }
  }
  return false;
}

/* =========================================================================
 * 13.5 Padded Allocation
 *
 * See the block comment above the declarations in repro_hcr_agent.h for what
 * this does and does not implement, and for the two contract details § 13.5
 * leaves open.
 *
 * WHY A REGISTRY AND NOT A HEADER IN FRONT OF THE POINTER. § 13.5 requires
 * `rb_hcr_padded_capacity` to return 0 "if ptr was not allocated with
 * rb_hcr_padded_alloc". A magic word stored just below the returned pointer
 * could not answer that: reading below an arbitrary foreign pointer is
 * undefined and, for a pointer into a fresh mapping, can fault. A pointer set
 * the allocator owns makes the query TOTAL — every pointer in the world gets
 * an answer, and only the ones this allocator handed out get a non-zero one.
 * The same set is what lets `rb_hcr_padded_free` refuse to call `free` on a
 * pointer it did not allocate.
 *
 * Chained buckets rather than a fixed array, because a fixed ceiling on an
 * ALLOCATOR is a different kind of limit from a fixed ceiling on a callback
 * registry: the application controls how many objects it creates.
 * ========================================================================= */

#define RB_HCR_PADDED_BUCKETS 1024u
#define RB_HCR_PADDED_DEFAULT_ALIGNMENT (2u * sizeof(void *))

typedef struct rb_hcr_padded_record {
  struct rb_hcr_padded_record *next;
  void *pointer;
  size_t capacity;
} rb_hcr_padded_record;

static rb_hcr_padded_record *rb_hcr_padded_buckets[RB_HCR_PADDED_BUCKETS];
static size_t rb_hcr_padded_live = 0;


static size_t rb_hcr_padded_bucket_of(const void *pointer) {
  /* Allocations are at least `2 * sizeof(void *)` apart, so the low bits carry
   * no information; shifting them out is what keeps the buckets from
   * degenerating into one chain. */
  uintptr_t value = (uintptr_t)pointer;
  return (size_t)((value >> 4) % (uintptr_t)RB_HCR_PADDED_BUCKETS);
}

static int rb_hcr_padded_alignment_ok(size_t alignment) {
  return alignment != 0 && (alignment & (alignment - 1u)) == 0;
}

void *rb_hcr_padded_alloc(size_t current_size, size_t padding,
                          size_t alignment) {
  size_t total;
  size_t effective;
  void *block = NULL;
  rb_hcr_padded_record *record;
  size_t bucket;

  if (padding > SIZE_MAX - current_size) {
    return NULL;
  }
  total = current_size + padding;
  if (total == 0) {
    /* § 13.5 reserves capacity 0 for "not a padded allocation". */
    return NULL;
  }

  effective = (alignment == 0) ? RB_HCR_PADDED_DEFAULT_ALIGNMENT : alignment;
  if (!rb_hcr_padded_alignment_ok(effective)) {
    return NULL;
  }
  /* posix_memalign requires a multiple of sizeof(void *). Rounding UP never
   * violates the caller's request, which is a MINIMUM alignment. */
  if (effective < sizeof(void *)) {
    effective = sizeof(void *);
  }

  record = (rb_hcr_padded_record *)calloc(1, sizeof(*record));
  if (record == NULL) {
    return NULL;
  }
  if (rb_hcr_platform_aligned_alloc(&block, effective, total) != 0 || block == NULL) {
    free(record);
    return NULL;
  }
  /* § 13.5: "The padding bytes are zero-initialized." The usable region is
   * NOT zeroed — that is malloc's contract and § 13.5 does not extend it. */
  if (padding > 0) {
    memset((char *)block + current_size, 0, padding);
  }

  record->pointer = block;
  record->capacity = total;
  bucket = rb_hcr_padded_bucket_of(block);
  rb_hcr_platform_padded_lock();
  record->next = rb_hcr_padded_buckets[bucket];
  rb_hcr_padded_buckets[bucket] = record;
  rb_hcr_padded_live++;
  rb_hcr_platform_padded_unlock();
  return block;
}

size_t rb_hcr_padded_capacity(const void *ptr) {
  size_t bucket;
  rb_hcr_padded_record *cursor;
  size_t answer = 0;

  if (ptr == NULL) {
    return 0;
  }
  bucket = rb_hcr_padded_bucket_of(ptr);
  rb_hcr_platform_padded_lock();
  for (cursor = rb_hcr_padded_buckets[bucket]; cursor != NULL;
       cursor = cursor->next) {
    if (cursor->pointer == ptr) {
      answer = cursor->capacity;
      break;
    }
  }
  rb_hcr_platform_padded_unlock();
  return answer;
}

void rb_hcr_padded_free(void *ptr) {
  size_t bucket;
  rb_hcr_padded_record *cursor;
  rb_hcr_padded_record *previous = NULL;
  rb_hcr_padded_record *detached = NULL;

  if (ptr == NULL) {
    return;
  }
  bucket = rb_hcr_padded_bucket_of(ptr);
  rb_hcr_platform_padded_lock();
  for (cursor = rb_hcr_padded_buckets[bucket]; cursor != NULL;
       cursor = cursor->next) {
    if (cursor->pointer == ptr) {
      if (previous == NULL) {
        rb_hcr_padded_buckets[bucket] = cursor->next;
      } else {
        previous->next = cursor->next;
      }
      detached = cursor;
      rb_hcr_padded_live--;
      break;
    }
    previous = cursor;
  }
  rb_hcr_platform_padded_unlock();

  /* A pointer this allocator did not hand out is IGNORED rather than passed to
   * `free`. § 13.5 says this function frees "memory allocated with
   * rb_hcr_padded_alloc"; calling `free` on anything else would turn a caller
   * mistake into heap corruption, and the query function already answers 0 for
   * exactly these pointers. */
  if (detached == NULL) {
    return;
  }
  rb_hcr_platform_aligned_free(detached->pointer);
  free(detached);
}

#endif /* REPRO_HCR_RB_ABI_H */
