/*
 * HLX-M4 adversarial fixture: publication under concurrent execution.
 *
 * Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §4.2, §4.4, §6.1, §6.2.
 * Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M4.
 *
 * WHAT THIS IS FOR, stated bluntly because the campaign already has the weaker
 * version of it. The Godot demo patched a function that five kernel threads
 * were executing and saw no torn value across 150 observations. That cannot
 * distinguish "safe" from "did not lose the race once". This fixture exists to
 * lose the race on purpose, as often as possible, and to make losing it
 * OBSERVABLE:
 *
 *   1. MANY publications, not one. Thousands of re-patches (§4.5) against a
 *      function a dozen threads are calling in a tight loop.
 *   2. A SIGNAL STORM. The in-window hazard of §6.1 point 4 needs a thread to
 *      be interrupted with its PC inside the sled and then RESUME, re-fetching
 *      bytes that changed underneath it. A hot loop with no interrupts mostly
 *      runs straight through the sled out of an already-filled fetch buffer, so
 *      chaos threads `tgkill` the workers continuously to manufacture exactly
 *      that interrupt/resume pattern. Design §6.1 asks for this in as many
 *      words: "HLX-M4 must settle this by measurement under a signal-storm
 *      stress test".
 *   3. A DETECTABLE FAILURE. Every call's return value is classified. Anything
 *      that is not the old 11 or one of the two published values is recorded
 *      with its value and its worker. A fault is caught and reported with the
 *      faulting address and PC, and exits 70 — a code nothing else in this
 *      program produces, so the harness asserts it exactly rather than
 *      accepting "non-zero".
 *   4. A POSITIVE CONTROL. The `torn` mode publishes the SAME word
 *      non-atomically, byte by byte. If that arm does not fail, the detector
 *      above is hollow and no result from the other arms means anything. It is
 *      the twin that proves the instrument can fire.
 *
 * Modes:
 *   sample         no patching; quiesce repeatedly and measure how often a
 *                  worker's PC is inside the publication window. This is the
 *                  empirical probability the whole statistical claim rests on.
 *   tier1          production publication, no quiescence.
 *   tier1-nosync   as tier1 with the SYNC_CORE membarrier suppressed — the
 *                  "remove the second half and observe the difference" arm the
 *                  milestone's first deliverable requires.
 *   tier2          quiesce, publish, adjust in-window PCs, release.
 *   tier2-noadjust quiesce and publish but DECLINE to adjust in-window PCs.
 *                  Expected to die: it is the deterministic demonstration that
 *                  §6.1 point 4 is a real hazard and that the adjustment is
 *                  what prevents it.
 *   torn           non-atomic byte-by-byte publication. The positive control.
 *
 * Everything below drives the PRODUCTION provider through
 * `repro_hcr_linux_x86_64_probe.c`, which re-exports the same `static`
 * functions the live agent calls. Nothing here reimplements the publication.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

#include "hcr_lx_m4_victim.h"

/* ---- the production provider, re-exported ------------------------------- */

extern unsigned long long repro_hcr_lx_probe_sled_address_for_entry(
    unsigned long long entry_address);
extern unsigned long long repro_hcr_lx_probe_apply_direct_patch_at(
    unsigned long long entry_address, unsigned long long sled_address,
    const unsigned char *patch_bytes, size_t patch_len);
extern int repro_hcr_lx_probe_last_refusal(void);
extern const char *repro_hcr_lx_probe_refusal_name(int code);
extern unsigned long long repro_hcr_lx_probe_last_window_address(void);
extern unsigned int repro_hcr_lx_probe_last_sled_length(void);
extern unsigned long long repro_hcr_lx_probe_last_published_word(void);
extern unsigned long long repro_hcr_lx_probe_last_original_word(void);
extern unsigned long long repro_hcr_lx_probe_last_generation(void);
extern long repro_hcr_lx_probe_last_membarrier_result(void);
extern int repro_hcr_lx_probe_membarrier_sync_core(void);
extern int repro_hcr_lx_probe_text_rwx_transition(void);
extern int repro_hcr_lx_probe_last_transient_kept_exec(void);
extern unsigned long long repro_hcr_lx_probe_membarrier_issued_count(void);
extern unsigned long long repro_hcr_lx_probe_publication_count(void);
extern void repro_hcr_lx_probe_set_sync_core_suppressed(int value);
extern void repro_hcr_lx_probe_set_quiesce_suppress_adjust(int value);
extern void repro_hcr_lx_probe_set_nested_scan_enabled(int value);
extern int repro_hcr_lx_probe_quiesce_handler_stage(void);
extern int repro_hcr_lx_probe_quiesce_readable_ranges(void);
extern int repro_hcr_lx_probe_quiesce_trampoline_verified(void);
extern int repro_hcr_lx_probe_quiesce_trampoline_mismatch(void);
extern unsigned long long repro_hcr_lx_probe_quiesce_nested_adjust_count(void);
extern unsigned long long repro_hcr_lx_probe_quiesce_nested_frames_seen(void);
extern long repro_hcr_lx_probe_raw_mprotect(unsigned long long address,
                                            size_t length, int protection);
extern size_t repro_hcr_lx_probe_page_size(void);
extern int repro_hcr_lx_probe_last_quiesced(void);
extern int repro_hcr_lx_probe_last_ip_adjustments(void);
extern unsigned long long repro_hcr_lx_probe_last_resume_target(void);

extern int repro_hcr_lx_probe_quiesce_install(int signo);
extern int repro_hcr_lx_probe_quiesce_begin(unsigned long long timeout_ns);
extern int repro_hcr_lx_probe_quiesce_release(void);
extern const char *repro_hcr_lx_probe_quiesce_status_name(int code);
extern int repro_hcr_lx_probe_quiesce_slot_count(void);
extern int repro_hcr_lx_probe_quiesce_parked_count(void);
extern int repro_hcr_lx_probe_quiesce_resumed_count(void);
extern int repro_hcr_lx_probe_quiesce_signalled_count(void);
extern int repro_hcr_lx_probe_quiesce_stray_signals(void);
extern int repro_hcr_lx_probe_quiesce_slot_tid(int index);
extern unsigned long long repro_hcr_lx_probe_quiesce_slot_pc(int index);
extern int repro_hcr_lx_probe_quiesce_slot_parked(int index);
extern unsigned long long repro_hcr_lx_probe_quiesce_park_ns(void);
extern unsigned long long repro_hcr_lx_probe_quiesce_release_ns(void);
extern unsigned long long repro_hcr_lx_probe_quiesce_adjust_count(void);
extern int repro_hcr_lx_probe_quiesce_signo(void);

#define REPRO_HCR_LX_PROT_READ 0x1
#define REPRO_HCR_LX_PROT_WRITE 0x2
#define REPRO_HCR_LX_PROT_EXEC 0x4

/* ---- shared state ------------------------------------------------------- */

#define MAX_WORKERS 64
#define MAX_ANOMALY_KINDS 8

typedef struct worker_state {
  int index;
  int tid;
  volatile uint64_t calls;
  volatile uint64_t saw_old;
  volatile uint64_t saw_a;
  volatile uint64_t saw_b;
  volatile uint64_t anomalies;
  volatile int anomaly_values[MAX_ANOMALY_KINDS];
  volatile int anomaly_kinds;
  volatile uint64_t signals_taken;
} worker_state;

static worker_state g_workers[MAX_WORKERS];
static volatile int g_stop = 0;
static volatile int g_worker_count = 0;
static volatile uint64_t g_chaos_signals = 0;
static int g_chaos_signo = SIGURG;

/* Crash reporting. The fault handler must be async-signal-safe, so it formats
 * by hand and writes to fd 2 directly. Exit code 70 is used by nothing else in
 * this program, so the harness can assert it rather than accepting any
 * non-zero code. */
static void write_hex(char *out, unsigned long long value) {
  static const char digits[] = "0123456789abcdef";
  int i;
  out[0] = '0';
  out[1] = 'x';
  for (i = 0; i < 16; ++i) {
    out[2 + i] = digits[(value >> ((15 - i) * 4)) & 0xf];
  }
  out[18] = '\0';
}

static void fault_handler(int signo, siginfo_t *info, void *ucontext) {
  char line[256];
  char hex_pc[20];
  char hex_addr[20];
  ucontext_t *uc = (ucontext_t *)ucontext;
  size_t n = 0;
  const char *prefix = "HCR-M4-CRASH signal=";
  write_hex(hex_pc, (unsigned long long)uc->uc_mcontext.gregs[REG_RIP]);
  write_hex(hex_addr, (unsigned long long)(uintptr_t)info->si_addr);
  while (*prefix != '\0' && n < sizeof(line) - 1) {
    line[n++] = *prefix++;
  }
  line[n++] = (char)('0' + (signo / 10) % 10);
  line[n++] = (char)('0' + signo % 10);
  {
    const char *tag = " stage=";
    const char *p = tag;
    while (*p != '\0') line[n++] = *p++;
    line[n++] = (char)('0' + repro_hcr_lx_probe_quiesce_handler_stage() % 10);
    tag = " pc=";
    p = tag;
    while (*p != '\0') line[n++] = *p++;
    p = hex_pc;
    while (*p != '\0') line[n++] = *p++;
    tag = " addr=";
    p = tag;
    while (*p != '\0') line[n++] = *p++;
    p = hex_addr;
    while (*p != '\0') line[n++] = *p++;
    line[n++] = '\n';
  }
  (void)!write(2, line, n);
  _exit(70);
}

static void chaos_signal_handler(int signo) {
  (void)signo;
  /* Deliberately empty. The point is not what the handler does, it is that the
   * thread entered the kernel and will return through `IRET` with a flushed
   * front end — which is the only way to manufacture the re-fetch that §6.1
   * point 4 turns into an executed `rel32` tail. */
}

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void *worker_main(void *raw) {
  worker_state *w = (worker_state *)raw;
  w->tid = (int)syscall(SYS_gettid);
  while (!g_stop) {
    int i;
    for (i = 0; i < 512; ++i) {
      int value = hcr_lx_m4_victim();
      w->calls += 1;
      if (value == HCR_LX_M4_OLD_VALUE) {
        w->saw_old += 1;
      } else if (value == HCR_LX_M4_NEW_VALUE_A) {
        w->saw_a += 1;
      } else if (value == HCR_LX_M4_NEW_VALUE_B) {
        w->saw_b += 1;
      } else {
        int k;
        int known = 0;
        w->anomalies += 1;
        for (k = 0; k < w->anomaly_kinds; ++k) {
          if (w->anomaly_values[k] == value) {
            known = 1;
            break;
          }
        }
        if (!known && w->anomaly_kinds < MAX_ANOMALY_KINDS) {
          w->anomaly_values[w->anomaly_kinds] = value;
          w->anomaly_kinds += 1;
        }
      }
    }
  }
  return NULL;
}

static void *chaos_main(void *raw) {
  long pid = (long)getpid();
  (void)raw;
  while (!g_stop) {
    int i;
    for (i = 0; i < g_worker_count; ++i) {
      int tid = g_workers[i].tid;
      if (tid != 0 && syscall(SYS_tgkill, pid, tid, g_chaos_signo) == 0) {
        g_chaos_signals += 1;
      }
    }
  }
  return NULL;
}

/* ---- hex helpers -------------------------------------------------------- */

static int hex_nibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static size_t parse_hex(const char *text, unsigned char *out, size_t capacity) {
  size_t length = strlen(text);
  size_t i;
  if ((length % 2) != 0 || length / 2 > capacity) {
    return 0;
  }
  for (i = 0; i < length / 2; ++i) {
    int hi = hex_nibble(text[i * 2]);
    int lo = hex_nibble(text[i * 2 + 1]);
    if (hi < 0 || lo < 0) {
      return 0;
    }
    out[i] = (unsigned char)((hi << 4) | lo);
  }
  return length / 2;
}

/* ---- the non-atomic control -------------------------------------------- */

/*
 * Publish the SAME eight bytes the provider would publish, one byte at a time,
 * lowest first, with a yield between each. Byte 0 becomes `0xE9` while bytes
 * 1..4 are still `0x90`, so for the duration of the tear the window holds
 * `jmp` with a displacement of 0x90909090 — a wild branch, which is what makes
 * the tear OBSERVABLE rather than merely present.
 *
 * This is in the fixture, not in the provider: production code must have no
 * path that publishes non-atomically, however well guarded. The control writes
 * the target's own text directly, exactly as the provider would, and therefore
 * exercises the same detector.
 */
static void torn_publish(unsigned long long window_address,
                         unsigned long long word) {
  size_t page_size = repro_hcr_lx_probe_page_size();
  unsigned long long page = window_address & ~(unsigned long long)(page_size - 1);
  volatile unsigned char *bytes = (volatile unsigned char *)(uintptr_t)window_address;
  int i;
  if (repro_hcr_lx_probe_raw_mprotect(page, page_size,
                                      REPRO_HCR_LX_PROT_READ |
                                          REPRO_HCR_LX_PROT_WRITE |
                                          REPRO_HCR_LX_PROT_EXEC) != 0) {
    return;
  }
  for (i = 0; i < 8; ++i) {
    bytes[i] = (unsigned char)((word >> (i * 8)) & 0xff);
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
    sched_yield();
  }
  (void)repro_hcr_lx_probe_raw_mprotect(page, page_size,
                                        REPRO_HCR_LX_PROT_READ |
                                            REPRO_HCR_LX_PROT_EXEC);
}

/* ---- main --------------------------------------------------------------- */

int main(int argc, char **argv) {
  const char *mode = argc > 1 ? argv[1] : "tier1";
  const char *hex_a = argc > 2 ? argv[2] : "";
  const char *hex_b = argc > 3 ? argv[3] : "";
  int worker_count = argc > 4 ? atoi(argv[4]) : 12;
  int publications = argc > 5 ? atoi(argv[5]) : 2000;
  int chaos_count = argc > 6 ? atoi(argv[6]) : 2;

  unsigned char body_a[64];
  unsigned char body_b[64];
  size_t body_a_len;
  size_t body_b_len;
  pthread_t workers[MAX_WORKERS];
  pthread_t chaos[8];
  struct sigaction fault_action;
  struct sigaction chaos_action;
  unsigned long long entry_address;
  unsigned long long sled_address;
  unsigned long long window_address = 0;
  unsigned long long published_word_a = 0;
  unsigned long long published_word_b = 0;
  uint64_t started;
  uint64_t elapsed_ns;
  int i;
  int applied = 0;
  int refused = 0;
  int last_refusal = 0;
  int quiesce_rounds = 0;
  int quiesce_failures = 0;
  uint64_t in_window_parks = 0;
  uint64_t in_sled_parks = 0;
  uint64_t total_parks = 0;
  uint64_t sample_rounds = 0;
  unsigned int sled_length = 0;
  uint64_t total_calls = 0;
  uint64_t total_anomalies = 0;
  uint64_t total_old = 0;
  uint64_t total_a = 0;
  uint64_t total_b = 0;
  int distinct_tids = 0;
  int tid_seen[MAX_WORKERS];

  if (worker_count < 1) worker_count = 1;
  if (worker_count > MAX_WORKERS) worker_count = MAX_WORKERS;
  if (chaos_count < 0) chaos_count = 0;
  if (chaos_count > 8) chaos_count = 8;

  body_a_len = parse_hex(hex_a, body_a, sizeof(body_a));
  body_b_len = parse_hex(hex_b, body_b, sizeof(body_b));
  if (body_a_len == 0 || body_b_len == 0) {
    fprintf(stderr, "HCR-M4-FATAL: patch bodies must be supplied as hex\n");
    return 64;
  }

  memset(&fault_action, 0, sizeof(fault_action));
  fault_action.sa_sigaction = fault_handler;
  fault_action.sa_flags = SA_SIGINFO | SA_NODEFER;
  sigemptyset(&fault_action.sa_mask);
  sigaction(SIGSEGV, &fault_action, NULL);
  sigaction(SIGILL, &fault_action, NULL);
  sigaction(SIGBUS, &fault_action, NULL);
  sigaction(SIGFPE, &fault_action, NULL);
  sigaction(SIGTRAP, &fault_action, NULL);

  memset(&chaos_action, 0, sizeof(chaos_action));
  chaos_action.sa_handler = chaos_signal_handler;
  chaos_action.sa_flags = SA_RESTART;
  sigemptyset(&chaos_action.sa_mask);
  sigaction(g_chaos_signo, &chaos_action, NULL);

  if (repro_hcr_lx_probe_quiesce_install(0) != 0) {
    fprintf(stderr, "HCR-M4-FATAL: quiescence handler did not install\n");
    return 65;
  }

  entry_address = (unsigned long long)(uintptr_t)&hcr_lx_m4_victim;
  sled_address = repro_hcr_lx_probe_sled_address_for_entry(entry_address);
  if (sled_address == 0) {
    fprintf(stderr,
            "HCR-M4-FATAL: no __patchable_function_entries sled for the victim\n");
    return 66;
  }

  if (strcmp(mode, "tier1-nosync") == 0) {
    repro_hcr_lx_probe_set_sync_core_suppressed(1);
  }
  if (strcmp(mode, "tier2-noadjust") == 0) {
    repro_hcr_lx_probe_set_quiesce_suppress_adjust(1);
  }
  if (getenv("HCR_M4_DISABLE_NESTED_SCAN") != NULL) {
    repro_hcr_lx_probe_set_nested_scan_enabled(0);
  }

  /* Start the workers, then the chaos threads. Workers first so the chaos
   * threads have real tids to signal. */
  g_worker_count = worker_count;
  for (i = 0; i < worker_count; ++i) {
    g_workers[i].index = i;
    if (pthread_create(&workers[i], NULL, worker_main, &g_workers[i]) != 0) {
      fprintf(stderr, "HCR-M4-FATAL: pthread_create failed\n");
      return 67;
    }
  }
  /* Wait until every worker has published its tid and is calling, so the
   * measurement is never taken against a partly-started process. */
  for (;;) {
    int ready = 0;
    for (i = 0; i < worker_count; ++i) {
      if (g_workers[i].tid != 0 && g_workers[i].calls > 0) {
        ready += 1;
      }
    }
    if (ready == worker_count) {
      break;
    }
    usleep(1000);
  }
  /*
   * Announce the publication window on stderr BEFORE anything can fault.
   *
   * The milestone's headline claim is not "the process died" — it is "the
   * process died with its PC INSIDE THE EIGHT BYTES WE PUBLISHED", which is
   * what makes it design §6.1 point 4 rather than an unrelated bug. That claim
   * lived only in prose because the JSON that carries `windowAddress` is
   * printed at exit and a crashing run never reaches it. Emitting it here lets
   * the harness assert the faulting PC's offset from the window, so the arm
   * that MUST crash has to crash for the right reason.
   */
  {
    char line[64];
    char hex_window[20];
    const char *tag = "HCR-M4-WINDOW ";
    size_t n = 0;
    write_hex(hex_window, (sled_address + 7ull) & ~7ull);
    while (*tag != '\0') line[n++] = *tag++;
    {
      const char *p = hex_window;
      while (*p != '\0') line[n++] = *p++;
    }
    line[n++] = '\n';
    (void)!write(2, line, n);
  }

  for (i = 0; i < chaos_count; ++i) {
    pthread_create(&chaos[i], NULL, chaos_main, NULL);
  }

  started = now_ns();

  if (strcmp(mode, "sample") == 0) {
    /*
     * No patching. Quiesce repeatedly and ask the one question the whole
     * statistical claim depends on: how often is a hot worker's PC actually
     * inside the eight bytes a publication would overwrite?
     *
     * The window address comes from the provider's own planner via a single
     * real publication would-be — but publishing would change the code under
     * measurement, so it is derived instead from the sled the provider read,
     * using the same rule: the lowest 8-aligned boundary whose window fits.
     */
    window_address = (sled_address + 7ull) & ~7ull;
    for (sample_rounds = 0; sample_rounds < (uint64_t)publications;
         ++sample_rounds) {
      int status = repro_hcr_lx_probe_quiesce_begin(250000000ull);
      if (status != 0) {
        quiesce_failures += 1;
        continue;
      }
      quiesce_rounds += 1;
      {
        int slots = repro_hcr_lx_probe_quiesce_slot_count();
        int s;
        for (s = 0; s < slots; ++s) {
          unsigned long long pc;
          if (repro_hcr_lx_probe_quiesce_slot_parked(s) != 1) {
            continue;
          }
          total_parks += 1;
          pc = repro_hcr_lx_probe_quiesce_slot_pc(s);
          if (pc >= window_address && pc < window_address + 8) {
            in_window_parks += 1;
          }
          if (pc >= sled_address && pc < sled_address + 16) {
            in_sled_parks += 1;
          }
        }
      }
      repro_hcr_lx_probe_quiesce_release();
    }
  } else {
    for (i = 0; i < publications; ++i) {
      const unsigned char *body = (i % 2) == 0 ? body_a : body_b;
      size_t body_len = (i % 2) == 0 ? body_a_len : body_b_len;
      int quiesced_here = 0;

      if (strcmp(mode, "tier2") == 0 || strcmp(mode, "tier2-noadjust") == 0) {
        int status = repro_hcr_lx_probe_quiesce_begin(250000000ull);
        if (status != 0) {
          quiesce_failures += 1;
          continue;
        }
        quiesce_rounds += 1;
        quiesced_here = 1;
        {
          int slots = repro_hcr_lx_probe_quiesce_slot_count();
          int s;
          for (s = 0; s < slots; ++s) {
            unsigned long long pc;
            if (repro_hcr_lx_probe_quiesce_slot_parked(s) != 1) {
              continue;
            }
            total_parks += 1;
            pc = repro_hcr_lx_probe_quiesce_slot_pc(s);
            if (window_address != 0 && pc >= window_address &&
                pc < window_address + 8) {
              in_window_parks += 1;
            }
            if (pc >= sled_address && pc < sled_address + 16) {
              in_sled_parks += 1;
            }
          }
        }
      }

      if (strcmp(mode, "torn") == 0 && window_address != 0) {
        torn_publish(window_address,
                     (i % 2) == 0 ? published_word_a : published_word_b);
        applied += 1;
      } else {
        unsigned long long page = repro_hcr_lx_probe_apply_direct_patch_at(
            entry_address, sled_address, body, body_len);
        if (page == 0) {
          refused += 1;
          last_refusal = repro_hcr_lx_probe_last_refusal();
        } else {
          applied += 1;
          if (window_address == 0) {
            /* Emitted on the FIRST publication, to stderr, because the arms
             * that matter most die before stdout is written and a crash PC is
             * only interpretable against the window it landed in. */
            fprintf(stderr,
                    "HCR-M4-WINDOW entry=0x%llx sled=0x%llx window=0x%llx\n",
                    entry_address, sled_address,
                    repro_hcr_lx_probe_last_window_address());
            fflush(stderr);
          }
          window_address = repro_hcr_lx_probe_last_window_address();
          sled_length = repro_hcr_lx_probe_last_sled_length();
          if ((i % 2) == 0) {
            published_word_a = repro_hcr_lx_probe_last_published_word();
          } else {
            published_word_b = repro_hcr_lx_probe_last_published_word();
          }
        }
      }

      if (quiesced_here) {
        repro_hcr_lx_probe_quiesce_release();
      }
    }
  }

  elapsed_ns = now_ns() - started;

  /* Let the workers run a little longer so a thread that resumed into damaged
   * bytes has time to reach them. A crash the harness never waits for is a
   * crash the harness reports as a pass. */
  usleep(200000);

  g_stop = 1;
  for (i = 0; i < worker_count; ++i) {
    pthread_join(workers[i], NULL);
  }
  for (i = 0; i < chaos_count; ++i) {
    pthread_join(chaos[i], NULL);
  }

  memset(tid_seen, 0, sizeof(tid_seen));
  for (i = 0; i < worker_count; ++i) {
    int j;
    int known = 0;
    total_calls += g_workers[i].calls;
    total_anomalies += g_workers[i].anomalies;
    total_old += g_workers[i].saw_old;
    total_a += g_workers[i].saw_a;
    total_b += g_workers[i].saw_b;
    for (j = 0; j < distinct_tids; ++j) {
      if (tid_seen[j] == g_workers[i].tid) {
        known = 1;
      }
    }
    if (!known) {
      tid_seen[distinct_tids++] = g_workers[i].tid;
    }
  }

  printf("{\n");
  printf("  \"schemaId\": \"reprobuild.hcr.hlx-m4.linux-threads-result.v1\",\n");
  printf("  \"mode\": \"%s\",\n", mode);
  printf("  \"workerCount\": %d,\n", worker_count);
  printf("  \"chaosThreads\": %d,\n", chaos_count);
  printf("  \"chaosSignal\": %d,\n", g_chaos_signo);
  printf("  \"chaosSignalsDelivered\": %llu,\n",
         (unsigned long long)g_chaos_signals);
  printf("  \"requestedPublications\": %d,\n", publications);
  printf("  \"publicationsApplied\": %d,\n", applied);
  printf("  \"publicationsRefused\": %d,\n", refused);
  printf("  \"lastRefusal\": \"%s\",\n",
         repro_hcr_lx_probe_refusal_name(last_refusal));
  printf("  \"elapsedNs\": %llu,\n", (unsigned long long)elapsed_ns);
  printf("  \"entryAddress\": \"0x%llx\",\n", entry_address);
  printf("  \"sledAddress\": \"0x%llx\",\n", sled_address);
  printf("  \"sledLength\": %u,\n", sled_length);
  printf("  \"windowAddress\": \"0x%llx\",\n", window_address);
  printf("  \"publishedWordA\": \"0x%llx\",\n", published_word_a);
  printf("  \"publishedWordB\": \"0x%llx\",\n", published_word_b);
  printf("  \"totalCalls\": %llu,\n", (unsigned long long)total_calls);
  printf("  \"observedOld\": %llu,\n", (unsigned long long)total_old);
  printf("  \"observedA\": %llu,\n", (unsigned long long)total_a);
  printf("  \"observedB\": %llu,\n", (unsigned long long)total_b);
  printf("  \"anomalies\": %llu,\n", (unsigned long long)total_anomalies);
  printf("  \"anomalyValues\": [");
  {
    int printed = 0;
    for (i = 0; i < worker_count; ++i) {
      int k;
      for (k = 0; k < g_workers[i].anomaly_kinds; ++k) {
        printf("%s%d", printed ? ", " : "", g_workers[i].anomaly_values[k]);
        printed += 1;
      }
    }
  }
  printf("],\n");
  printf("  \"distinctWorkerTids\": %d,\n", distinct_tids);
  printf("  \"quiesceRounds\": %d,\n", quiesce_rounds);
  printf("  \"quiesceFailures\": %d,\n", quiesce_failures);
  printf("  \"quiesceSignal\": %d,\n", repro_hcr_lx_probe_quiesce_signo());
  printf("  \"quiesceLastParkNs\": %llu,\n",
         repro_hcr_lx_probe_quiesce_park_ns());
  printf("  \"quiesceLastReleaseNs\": %llu,\n",
         repro_hcr_lx_probe_quiesce_release_ns());
  printf("  \"quiesceStraySignals\": %d,\n",
         repro_hcr_lx_probe_quiesce_stray_signals());
  printf("  \"quiesceAdjustCount\": %llu,\n",
         repro_hcr_lx_probe_quiesce_adjust_count());
  printf("  \"quiesceNestedAdjustCount\": %llu,\n",
         repro_hcr_lx_probe_quiesce_nested_adjust_count());
  printf("  \"quiesceNestedFramesSeen\": %llu,\n",
         repro_hcr_lx_probe_quiesce_nested_frames_seen());
  printf("  \"quiesceReadableRanges\": %d,\n",
         repro_hcr_lx_probe_quiesce_readable_ranges());
  printf("  \"quiesceTrampolineVerified\": %s,\n",
         repro_hcr_lx_probe_quiesce_trampoline_verified() ? "true" : "false");
  printf("  \"quiesceTrampolineMismatch\": %s,\n",
         repro_hcr_lx_probe_quiesce_trampoline_mismatch() ? "true" : "false");
  printf("  \"lastIpAdjustments\": %d,\n",
         repro_hcr_lx_probe_last_ip_adjustments());
  printf("  \"lastResumeTarget\": \"0x%llx\",\n",
         repro_hcr_lx_probe_last_resume_target());
  printf("  \"lastQuiesced\": %s,\n",
         repro_hcr_lx_probe_last_quiesced() ? "true" : "false");
  printf("  \"parkedObservations\": %llu,\n", (unsigned long long)total_parks);
  printf("  \"parkedPcInWindow\": %llu,\n", (unsigned long long)in_window_parks);
  printf("  \"parkedPcInSled\": %llu,\n", (unsigned long long)in_sled_parks);
  printf("  \"sampleRounds\": %llu,\n", (unsigned long long)sample_rounds);
  printf("  \"membarrierSyncCore\": %s,\n",
         repro_hcr_lx_probe_membarrier_sync_core() ? "true" : "false");
  printf("  \"membarrierIssuedCount\": %llu,\n",
         repro_hcr_lx_probe_membarrier_issued_count());
  printf("  \"providerPublicationCount\": %llu,\n",
         repro_hcr_lx_probe_publication_count());
  printf("  \"lastMembarrierResult\": %ld,\n",
         repro_hcr_lx_probe_last_membarrier_result());
  printf("  \"textRwxTransition\": %s,\n",
         repro_hcr_lx_probe_text_rwx_transition() ? "true" : "false");
  printf("  \"lastTransientKeptExec\": %s,\n",
         repro_hcr_lx_probe_last_transient_kept_exec() ? "true" : "false");
  printf("  \"lastGeneration\": %llu\n",
         repro_hcr_lx_probe_last_generation());
  printf("}\n");
  fflush(stdout);
  return 0;
}
