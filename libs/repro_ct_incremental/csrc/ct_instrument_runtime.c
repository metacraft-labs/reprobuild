/*
 * ct_instrument_runtime.c — the M14 deliverable of the
 * Trace-Based-Incremental-Testing campaign (Phase 4).
 *
 * A tiny C call-recorder runtime that implements GCC/Clang's
 * `-finstrument-functions` ABI so that any native target compiled with that
 * flag and linked against this object records the SET of functions it actually
 * entered at runtime. That executed-function set is the native runtime
 * dependency-discovery source on hosts WITHOUT Intel PT / RR / the MCR emulator
 * (notably arm64-macOS). See the spec:
 *   * codetracer-specs Nim-Parallel-Test-Framework.md §16.7 — the executed
 *     function set drives incremental test selection.
 *   * MCR-Calltrace-Design §22d shadow stack — the compile-time-instrumentation
 *     alternative this implements.
 *
 * # The `-finstrument-functions` ABI
 *
 * When a translation unit is compiled with `-finstrument-functions`, the
 * compiler emits, at the entry and exit of every (non-excluded) function, a
 * call to:
 *
 *   void __cyg_profile_func_enter(void *this_fn, void *call_site);
 *   void __cyg_profile_func_exit (void *this_fn, void *call_site);
 *
 * `this_fn` is the ADDRESS of the function being entered/exited; `call_site` is
 * the return address into the caller. The compiler does NOT pass the function
 * NAME, so we resolve `this_fn` → name ourselves.
 * References:
 *   https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html
 *
 * # Robust name resolution via dladdr (NOT raw-PC → static-symbol mapping)
 *
 * Modern executables are PIE / ASLR-relocated: the address `this_fn` observed
 * at runtime is the STATIC symbol address PLUS the load slide. Mapping a runtime
 * PC back to a static symbol table address is therefore fragile (you'd have to
 * recover the slide). Instead we call `dladdr(this_fn, &info)` which the dynamic
 * loader answers using the ACTUAL in-memory image, returning `dli_sname` — the
 * nearest symbol name — directly and slide-correctly on both Mach-O (macOS) and
 * ELF (Linux). This is robust to PIE/ASLR by construction.
 *   References:
 *   https://man7.org/linux/man-pages/man3/dladdr.3.html
 *
 * On Mach-O the C ABI prefixes symbol names with a leading underscore
 * (`_used_a`); `dladdr` returns that mangled form. We DO NOT strip it here — the
 * output file carries exactly what `dladdr` reports, and the Nim reader
 * (native_instrument.nim) strips the leading underscore so the names match the
 * C identifiers the rest of the engine (native_hash.nim's symbol table) keys on.
 *
 * # Output file format (DOCUMENTED)
 *
 * The path of the output file is read once, at first ENTER, from the environment
 * variable `CT_INSTRUMENT_OUT`. The file is a plain-text, line-oriented log:
 *
 *   * ONE function name per line, terminated by a single '\n'.
 *   * A name is written AT MOST ONCE for the lifetime of the process (the
 *     recorder de-duplicates), so the file is the de-duplicated executed-set,
 *     order = first-entry order. Reading the SET back is a line read + dedup.
 *   * If `CT_INSTRUMENT_OUT` is unset/empty, the recorder is INERT (records
 *     nothing) — so an instrumented binary run outside a capture is harmless.
 *
 * The Nim reader treats a missing/empty file as an Err (fail-safe re-run).
 *
 * # Hot-path properties
 *
 *   * Thread-safe: a single pthread mutex guards the dedup set and the file. The
 *     hooks may fire concurrently from multiple threads.
 *   * Allocation-light: the dedup set is a fixed-capacity open-addressed hash
 *     table of interned name pointers; no malloc on the steady-state hot path
 *     once a name has been seen. New names are interned with a single strdup the
 *     first time only (bounded by the program's function count).
 *   * The instrumentation hooks and every helper they call are marked
 *     `__attribute__((no_instrument_function))` so the recorder does not
 *     instrument ITSELF (which would recurse infinitely).
 *
 * # Bounded
 *
 * The dedup table has a fixed capacity (CT_INSTRUMENT_MAX_FUNCS). If a program
 * has more distinct functions than that, further DISTINCT names are still
 * written to the file (so the executed set stays COMPLETE — never a false skip)
 * but are no longer deduplicated in memory; the reader dedups on its side, so
 * correctness holds. In practice test binaries have far fewer functions.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Fixed dedup-table capacity. Power of two for cheap masking. Generous for any
 * realistic test binary; see the "Bounded" note above for over-capacity
 * behaviour (still complete, just less in-memory dedup). */
#ifndef CT_INSTRUMENT_MAX_FUNCS
#define CT_INSTRUMENT_MAX_FUNCS 4096u
#endif

/* The interned-name dedup set: open-addressed, linear-probed. Each slot holds a
 * strdup'd copy of a name we have already written, or NULL. Guarded by the
 * mutex below. */
static char *ct_seen[CT_INSTRUMENT_MAX_FUNCS];
static unsigned ct_seen_count;

static pthread_mutex_t ct_lock = PTHREAD_MUTEX_INITIALIZER;

/* The output stream. Opened lazily on first ENTER from CT_INSTRUMENT_OUT.
 *   ct_state: 0 = not yet initialised, 1 = active (out != NULL), 2 = inert
 *             (env unset or open failed; record nothing). */
static FILE *ct_out;
static int ct_state;

/* FNV-1a over a NUL-terminated string. Cheap, good enough for dedup keys.
 * Reference: http://www.isthe.com/chongo/tech/comp/fnv/ */
static unsigned long ct_hash_name(const char *s)
    __attribute__((no_instrument_function));
static unsigned long ct_hash_name(const char *s) {
  unsigned long h = 1469598103934665603UL; /* FNV offset basis */
  for (; *s; ++s) {
    h ^= (unsigned char)*s;
    h *= 1099511628211UL; /* FNV prime */
  }
  return h;
}

/* Return 1 if `name` was already recorded; otherwise intern it and return 0.
 * MUST be called with ct_lock held. Allocation happens only on the FIRST sight
 * of a name (strdup); steady-state repeats are allocation-free. */
static int ct_seen_or_insert(const char *name)
    __attribute__((no_instrument_function));
static int ct_seen_or_insert(const char *name) {
  if (ct_seen_count >= CT_INSTRUMENT_MAX_FUNCS) {
    /* Table full: report "not seen" so the name is still WRITTEN (completeness),
     * but we can no longer track it in memory. The reader dedups, so the SET is
     * still correct. */
    return 0;
  }
  unsigned mask = CT_INSTRUMENT_MAX_FUNCS - 1u;
  unsigned idx = (unsigned)(ct_hash_name(name) & mask);
  for (unsigned probe = 0; probe < CT_INSTRUMENT_MAX_FUNCS; ++probe) {
    char *slot = ct_seen[idx];
    if (slot == NULL) {
      char *copy = strdup(name);
      if (copy == NULL) {
        /* Out of memory for the intern: treat as "not seen" so the name is
         * still written. The reader dedups regardless. */
        return 0;
      }
      ct_seen[idx] = copy;
      ct_seen_count++;
      return 0;
    }
    if (strcmp(slot, name) == 0) {
      return 1; /* already recorded */
    }
    idx = (idx + 1u) & mask;
  }
  /* Full ring with no match (shouldn't happen given the count guard above). */
  return 0;
}

/* Lazily open the output file from CT_INSTRUMENT_OUT. MUST be called with
 * ct_lock held. Sets ct_state to active (1) or inert (2). */
static void ct_init_locked(void) __attribute__((no_instrument_function));
static void ct_init_locked(void) {
  if (ct_state != 0) {
    return;
  }
  const char *path = getenv("CT_INSTRUMENT_OUT");
  if (path == NULL || path[0] == '\0') {
    ct_state = 2; /* inert: nothing to record into */
    return;
  }
  FILE *f = fopen(path, "w");
  if (f == NULL) {
    ct_state = 2; /* inert: cannot open — record nothing (reader Errs on empty) */
    return;
  }
  ct_out = f;
  ct_state = 1;
}

/* The ENTER hook: resolve `this_fn` to a name and record it once. */
void __cyg_profile_func_enter(void *this_fn, void *call_site)
    __attribute__((no_instrument_function));
void __cyg_profile_func_enter(void *this_fn, void *call_site) {
  (void)call_site;

  Dl_info info;
  /* dladdr resolves the runtime address against the ACTUAL loaded image, so it
   * is slide/PIE/ASLR correct. dli_sname may be NULL for an address with no
   * matching symbol (e.g. a stripped static helper) — we skip those: a name we
   * cannot resolve is not a trackable dependency, and dropping it can only cause
   * a conservative re-run upstream, never a false skip. */
  if (dladdr(this_fn, &info) == 0 || info.dli_sname == NULL ||
      info.dli_sname[0] == '\0') {
    return;
  }
  const char *name = info.dli_sname;

  pthread_mutex_lock(&ct_lock);
  ct_init_locked();
  if (ct_state == 1) {
    if (!ct_seen_or_insert(name)) {
      fputs(name, ct_out);
      fputc('\n', ct_out);
      /* Flush so a crashing/exiting program still leaves a complete log. The
       * write volume is bounded by the number of DISTINCT functions, so this is
       * cheap. */
      fflush(ct_out);
    }
  }
  pthread_mutex_unlock(&ct_lock);
}

/* The EXIT hook: the executed-SET needs only entries, so exit is a no-op. It
 * must still exist (the compiler emits a call to it) and must not be
 * instrumented. */
void __cyg_profile_func_exit(void *this_fn, void *call_site)
    __attribute__((no_instrument_function));
void __cyg_profile_func_exit(void *this_fn, void *call_site) {
  (void)this_fn;
  (void)call_site;
}
