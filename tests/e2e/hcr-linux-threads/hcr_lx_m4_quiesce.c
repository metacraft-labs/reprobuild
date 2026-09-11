/*
 * HLX-M4 tier-2 fixture: the quiescence handshake, its timeout, on-stack
 * detection, and set-wide atomicity.
 *
 * Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §6.2, §6.3.
 *
 * Modes, one per verification entry, each printing a JSON result:
 *
 *   handshake   Threads of three kinds run concurrently — spinning in compute,
 *               blocked in a RESTARTABLE `read(2)` on a pipe, and cycling
 *               through `nanosleep`. Quiescence is taken and released
 *               repeatedly. Proves every thread parks, every parked PC is
 *               captured, everyone is released, and the blocked readers see no
 *               `EINTR` (design §6.2 step 1: `SA_RESTART` is load-bearing).
 *
 *   timeout     One thread blocks the quiescence signal with `pthread_sigmask`
 *               and spins, which is §6.3's defined failure. Proves the wait is
 *               bounded, the parked threads are released anyway, the target's
 *               text is BYTE-IDENTICAL afterwards, and the unresponsive tid is
 *               named.
 *
 *   onstack     A thread is parked INSIDE the function being patched, holding a
 *               live frame in the old body. Proves the frame is detected, the
 *               in-flight call still returns the OLD value, and the next call
 *               returns the new one.
 *
 *   setwide     Two functions patched under ONE quiescence, with a checker
 *               thread reading both together. Tier-2's set-wide guarantee is
 *               that no reader ever sees one patched and the other not.
 *
 *   setwide-split  The SAME two functions patched under TWO separate
 *               quiescences — the control. If this does not produce mixed
 *               observations then the `setwide` arm proves nothing, because a
 *               checker that can never see a mixture is a checker that has
 *               stopped discriminating.
 *
 * `allowed_mocks: none`. Every thread is a real pthread, every park is a real
 * signal and a real futex, and every publication goes through the production
 * `repro_hcr_lx_apply_direct_patch_at`.
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

/* Two patchable victims. `noipa` for the reason given in the threads fixture:
 * without it GCC propagates the constant and the entry sled is never executed. */
__attribute__((noinline, noipa, used)) int hcr_lx_m4_q_victim_a(void) {
  return 11;
}

__attribute__((noinline, noipa, used)) int hcr_lx_m4_q_victim_b(void) {
  return 22;
}

static volatile int g_onstack_hold = 1;
static volatile int g_onstack_entered = 0;

__attribute__((noinline, noipa, used)) static void hcr_lx_m4_q_spin_inside(void) {
  g_onstack_entered = 1;
  while (g_onstack_hold) {
    sched_yield();
  }
}

/* Patchable, and it DELIBERATELY has a callee that parks: while
 * `hcr_lx_m4_q_spin_inside` is running, this function has a live frame, which
 * is exactly the state §6.2 step 5's on-stack detection has to find. */
__attribute__((noinline, noipa, used)) int hcr_lx_m4_q_victim_onstack(void) {
  hcr_lx_m4_q_spin_inside();
  return 33;
}

/* ---- production provider, re-exported ----------------------------------- */

extern unsigned long long repro_hcr_lx_probe_sled_address_for_entry(
    unsigned long long entry_address);
extern unsigned long long repro_hcr_lx_probe_apply_direct_patch_at(
    unsigned long long entry_address, unsigned long long sled_address,
    const unsigned char *patch_bytes, size_t patch_len);
extern int repro_hcr_lx_probe_last_refusal(void);
extern const char *repro_hcr_lx_probe_refusal_name(int code);
extern unsigned long long repro_hcr_lx_probe_last_window_address(void);
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
extern int repro_hcr_lx_probe_quiesce_slot_frame_count(int index);
extern unsigned long long repro_hcr_lx_probe_quiesce_slot_frame(int index,
                                                                int frame);
extern int repro_hcr_lx_probe_quiesce_threads_on_stack_in(
    unsigned long long low, unsigned long long high);
extern int repro_hcr_lx_probe_quiesce_unresponsive_count(void);
extern int repro_hcr_lx_probe_quiesce_unresponsive_tid(int index);
extern unsigned long long repro_hcr_lx_probe_quiesce_park_ns(void);
extern unsigned long long repro_hcr_lx_probe_quiesce_release_ns(void);
extern int repro_hcr_lx_probe_quiesce_signo(void);
extern int repro_hcr_lx_probe_quiesce_enumeration_rounds(void);
extern unsigned long long repro_hcr_lx_probe_membarrier_issued_count(void);

#define MAX_THREADS 32

typedef struct thread_state {
  int tid;
  int kind; /* 0 spin, 1 blocked read, 2 nanosleep, 3 signal-blocked spinner */
  volatile uint64_t iterations;
  volatile uint64_t eintr_count;      /* restartable `read`: MUST stay 0 */
  volatile uint64_t eintr_sleep_count; /* `nanosleep`: expected to be > 0 */
  volatile int ready;
} thread_state;

static thread_state g_threads[MAX_THREADS];
static volatile int g_stop = 0;
static int g_pipe_fds[MAX_THREADS][2];

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void *spin_main(void *raw) {
  thread_state *t = (thread_state *)raw;
  t->tid = (int)syscall(SYS_gettid);
  t->ready = 1;
  while (!g_stop) {
    t->iterations += 1;
  }
  return NULL;
}

/* Blocked in a RESTARTABLE syscall for the whole run. `SA_RESTART` on the
 * quiescence handler is what must make this transparent; an `EINTR` here is a
 * behaviour change the provider would be imposing on the application. */
static void *blocked_read_main(void *raw) {
  thread_state *t = (thread_state *)raw;
  char byte;
  t->tid = (int)syscall(SYS_gettid);
  t->ready = 1;
  for (;;) {
    ssize_t got = read(g_pipe_fds[0][0], &byte, 1);
    if (got < 0 && errno == EINTR) {
      t->eintr_count += 1;
      continue;
    }
    if (got <= 0) {
      break;
    }
    t->iterations += 1;
    if (byte == 'q') {
      break;
    }
  }
  return NULL;
}

static void *sleeper_main(void *raw) {
  thread_state *t = (thread_state *)raw;
  t->tid = (int)syscall(SYS_gettid);
  t->ready = 1;
  while (!g_stop) {
    struct timespec req;
    req.tv_sec = 0;
    req.tv_nsec = 500000;
    if (nanosleep(&req, NULL) != 0 && errno == EINTR) {
      /* NOT a defect and NOT covered by `SA_RESTART`: `nanosleep` is
       * documented to return `EINTR` on interruption because it has a
       * remaining-time out-parameter to update, so the kernel never restarts
       * it. Design §6.2 says this cost "is a behaviour change the provider
       * must document rather than hide" — counting it separately is how this
       * fixture surfaces it instead of averaging it away into the `read`
       * population, where a single count would have looked like an
       * `SA_RESTART` failure. */
      t->eintr_sleep_count += 1;
    }
    t->iterations += 1;
  }
  return NULL;
}

/* The §6.3 failure case: a thread that blocks the quiescence signal and never
 * parks. Blocking the signal is the ONLY way to produce it deliberately; a
 * thread in uninterruptible `D` state cannot be manufactured from user space. */
static void *deaf_spinner_main(void *raw) {
  thread_state *t = (thread_state *)raw;
  sigset_t mask;
  sigemptyset(&mask);
  sigaddset(&mask, repro_hcr_lx_probe_quiesce_signo());
  pthread_sigmask(SIG_BLOCK, &mask, NULL);
  t->tid = (int)syscall(SYS_gettid);
  t->ready = 1;
  while (!g_stop) {
    t->iterations += 1;
  }
  return NULL;
}

typedef struct onstack_state {
  volatile int value;
  volatile int done;
} onstack_state;

static onstack_state g_onstack;

static void *onstack_main(void *raw) {
  (void)raw;
  g_onstack.value = hcr_lx_m4_q_victim_onstack();
  g_onstack.done = 1;
  return NULL;
}

/* ---- set-wide checker ---------------------------------------------------- */

static volatile uint64_t g_setwide_both_old = 0;
static volatile uint64_t g_setwide_both_new = 0;
static volatile uint64_t g_setwide_mixed = 0;
static volatile uint64_t g_setwide_other = 0;

static volatile uint64_t g_setwide_discarded = 0;

/*
 * Reads A, then B, then A AGAIN.
 *
 * A two-call observer cannot test set-wide atomicity on its own: the observer
 * itself can be quiesced BETWEEN the two reads, see the old A and the new B,
 * and report a mixture that no instant of the process ever exhibited. Measured
 * before the third read existed: the `setwide` arm reported exactly 1 mixture
 * in 55 million samples, and that 1 was this artefact rather than a violation.
 *
 * Requiring A to be unchanged across the whole observation removes it. A sample
 * with `a1 != a2` spans a publication and is DISCARDED and counted; a sample
 * with `a1 == a2` and a disagreeing B is a genuine mixture, because the only
 * way to produce it is for B to have been published without A — which is
 * precisely what set-wide atomicity forbids and what `setwide-split` does on
 * purpose.
 */
static void *setwide_checker_main(void *raw) {
  (void)raw;
  while (!g_stop) {
    int a1 = hcr_lx_m4_q_victim_a();
    int b = hcr_lx_m4_q_victim_b();
    int a2 = hcr_lx_m4_q_victim_a();
    if (a1 != a2) {
      g_setwide_discarded += 1;
      continue;
    }
    if (a1 == 11 && b == 22) {
      g_setwide_both_old += 1;
    } else if (a1 == 77 && b == 99) {
      g_setwide_both_new += 1;
    } else if ((a1 == 11 && b == 99) || (a1 == 77 && b == 22)) {
      g_setwide_mixed += 1;
    } else {
      g_setwide_other += 1;
    }
  }
  return NULL;
}

/* ---- hex ---------------------------------------------------------------- */

static int hex_nibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static size_t parse_hex(const char *text, unsigned char *out, size_t capacity) {
  size_t length = strlen(text);
  size_t i;
  if (length == 0 || (length % 2) != 0 || length / 2 > capacity) {
    return 0;
  }
  for (i = 0; i < length / 2; ++i) {
    int hi = hex_nibble(text[i * 2]);
    int lo = hex_nibble(text[i * 2 + 1]);
    if (hi < 0 || lo < 0) return 0;
    out[i] = (unsigned char)((hi << 4) | lo);
  }
  return length / 2;
}

static unsigned long long read_window(unsigned long long entry) {
  unsigned long long word = 0;
  unsigned long long sled = repro_hcr_lx_probe_sled_address_for_entry(entry);
  unsigned long long window = (sled + 7ull) & ~7ull;
  memcpy(&word, (const void *)(uintptr_t)window, sizeof(word));
  return word;
}

int main(int argc, char **argv) {
  const char *mode = argc > 1 ? argv[1] : "handshake";
  const char *hex_a = argc > 2 ? argv[2] : "";
  const char *hex_b = argc > 3 ? argv[3] : "";
  int rounds = argc > 4 ? atoi(argv[4]) : 16;
  unsigned char body_a[64];
  unsigned char body_b[64];
  size_t body_a_len = parse_hex(hex_a, body_a, sizeof(body_a));
  size_t body_b_len = parse_hex(hex_b, body_b, sizeof(body_b));
  pthread_t handles[MAX_THREADS];
  int thread_count = 0;
  int i;
  int status = 0;
  int parked_total = 0;
  int pcs_nonzero = 0;
  int resumed_total = 0;
  int rounds_ok = 0;
  int slot_count_last = 0;
  uint64_t eintr_total = 0;
  uint64_t eintr_sleep_total = 0;
  uint64_t park_ns_max = 0;
  uint64_t release_ns_max = 0;
  unsigned long long window_before = 0;
  unsigned long long window_after = 0;
  int unresponsive = 0;
  int unresponsive_tid = -1;
  int deaf_tid = -1;
  int onstack_detected = 0;
  int onstack_inflight_value = -1;
  int onstack_next_value = -1;
  int publications = 0;
  int last_refusal = 0;

  if (body_a_len == 0 || body_b_len == 0) {
    fprintf(stderr, "HCR-M4-FATAL: patch bodies must be supplied as hex\n");
    return 64;
  }
  if (repro_hcr_lx_probe_quiesce_install(0) != 0) {
    fprintf(stderr, "HCR-M4-FATAL: quiescence handler did not install\n");
    return 65;
  }
  if (repro_hcr_lx_probe_sled_address_for_entry(
          (unsigned long long)(uintptr_t)&hcr_lx_m4_q_victim_a) == 0) {
    fprintf(stderr, "HCR-M4-FATAL: victim has no patchable sled\n");
    return 66;
  }

  for (i = 0; i < MAX_THREADS; ++i) {
    g_pipe_fds[i][0] = -1;
    g_pipe_fds[i][1] = -1;
  }

  if (strcmp(mode, "handshake") == 0) {
    if (pipe(g_pipe_fds[0]) != 0) {
      fprintf(stderr, "HCR-M4-FATAL: pipe failed\n");
      return 67;
    }
    for (i = 0; i < 4; ++i) {
      g_threads[thread_count].kind = 0;
      pthread_create(&handles[thread_count], NULL, spin_main,
                     &g_threads[thread_count]);
      thread_count += 1;
    }
    for (i = 0; i < 3; ++i) {
      g_threads[thread_count].kind = 1;
      pthread_create(&handles[thread_count], NULL, blocked_read_main,
                     &g_threads[thread_count]);
      thread_count += 1;
    }
    for (i = 0; i < 2; ++i) {
      g_threads[thread_count].kind = 2;
      pthread_create(&handles[thread_count], NULL, sleeper_main,
                     &g_threads[thread_count]);
      thread_count += 1;
    }
  } else if (strcmp(mode, "timeout") == 0) {
    for (i = 0; i < 3; ++i) {
      g_threads[thread_count].kind = 0;
      pthread_create(&handles[thread_count], NULL, spin_main,
                     &g_threads[thread_count]);
      thread_count += 1;
    }
    g_threads[thread_count].kind = 3;
    pthread_create(&handles[thread_count], NULL, deaf_spinner_main,
                   &g_threads[thread_count]);
    thread_count += 1;
  } else if (strcmp(mode, "onstack") == 0) {
    for (i = 0; i < 2; ++i) {
      g_threads[thread_count].kind = 0;
      pthread_create(&handles[thread_count], NULL, spin_main,
                     &g_threads[thread_count]);
      thread_count += 1;
    }
    pthread_create(&handles[thread_count], NULL, onstack_main, NULL);
    thread_count += 1;
  } else if (strcmp(mode, "setwide") == 0 ||
             strcmp(mode, "setwide-split") == 0) {
    for (i = 0; i < 4; ++i) {
      pthread_create(&handles[thread_count], NULL, setwide_checker_main, NULL);
      thread_count += 1;
    }
  } else {
    fprintf(stderr, "HCR-M4-FATAL: unknown mode %s\n", mode);
    return 68;
  }

  /* Do not measure a partly-started process. */
  if (strcmp(mode, "onstack") == 0) {
    while (!g_onstack_entered) {
      usleep(1000);
    }
  }
  if (strcmp(mode, "setwide") != 0 && strcmp(mode, "setwide-split") != 0 &&
      strcmp(mode, "onstack") != 0) {
    for (;;) {
      int ready = 0;
      for (i = 0; i < thread_count; ++i) {
        if (g_threads[i].ready) ready += 1;
      }
      if (ready == thread_count) break;
      usleep(1000);
    }
  } else {
    usleep(50000);
  }
  for (i = 0; i < thread_count; ++i) {
    if (g_threads[i].kind == 3) {
      deaf_tid = g_threads[i].tid;
    }
  }

  window_before = read_window((unsigned long long)(uintptr_t)&hcr_lx_m4_q_victim_a);

  if (strcmp(mode, "timeout") == 0) {
    /* §6.3: a bounded wait, then release, write nothing, and name the tid. */
    uint64_t started = now_ns();
    status = repro_hcr_lx_probe_quiesce_begin(120000000ull); /* 120 ms */
    park_ns_max = now_ns() - started;
    resumed_total = repro_hcr_lx_probe_quiesce_resumed_count();
    unresponsive = repro_hcr_lx_probe_quiesce_unresponsive_count();
    if (unresponsive > 0) {
      unresponsive_tid = repro_hcr_lx_probe_quiesce_unresponsive_tid(0);
    }
    slot_count_last = repro_hcr_lx_probe_quiesce_slot_count();
    for (i = 0; i < slot_count_last; ++i) {
      if (repro_hcr_lx_probe_quiesce_slot_parked(i) == 1) parked_total += 1;
    }
    /* No publication is attempted: the whole point is that the caller does not
     * reach the target's text. */
    window_after =
        read_window((unsigned long long)(uintptr_t)&hcr_lx_m4_q_victim_a);
  } else if (strcmp(mode, "onstack") == 0) {
    unsigned long long entry =
        (unsigned long long)(uintptr_t)&hcr_lx_m4_q_victim_onstack;
    unsigned long long sled =
        repro_hcr_lx_probe_sled_address_for_entry(entry);
    status = repro_hcr_lx_probe_quiesce_begin(250000000ull);
    if (status == 0) {
      rounds_ok += 1;
      slot_count_last = repro_hcr_lx_probe_quiesce_slot_count();
      for (i = 0; i < slot_count_last; ++i) {
        if (repro_hcr_lx_probe_quiesce_slot_parked(i) == 1) parked_total += 1;
      }
      /* The range is the victim plus its sled; the callee it is blocked in
       * lies outside it, so a hit means a genuine caller frame. */
      onstack_detected = repro_hcr_lx_probe_quiesce_threads_on_stack_in(
          entry, entry + 128);
      if (repro_hcr_lx_probe_apply_direct_patch_at(entry, sled, body_a,
                                                   body_a_len) != 0) {
        publications += 1;
      } else {
        last_refusal = repro_hcr_lx_probe_last_refusal();
      }
      repro_hcr_lx_probe_quiesce_release();
      resumed_total = repro_hcr_lx_probe_quiesce_resumed_count();
      for (i = 0; i < slot_count_last; ++i) {
        if (repro_hcr_lx_probe_quiesce_slot_pc(i) != 0) {
          pcs_nonzero += 1;
        }
      }
    }
    /* Let the in-flight frame finish. It entered the OLD body before the
     * publication, so §6.1 point 3 says it must return the OLD value. */
    g_onstack_hold = 0;
    while (!g_onstack.done) {
      usleep(1000);
    }
    onstack_inflight_value = g_onstack.value;
    onstack_next_value = hcr_lx_m4_q_victim_onstack();
    window_after = read_window(entry);
  } else if (strcmp(mode, "setwide") == 0) {
    unsigned long long entry_a =
        (unsigned long long)(uintptr_t)&hcr_lx_m4_q_victim_a;
    unsigned long long entry_b =
        (unsigned long long)(uintptr_t)&hcr_lx_m4_q_victim_b;
    for (i = 0; i < rounds; ++i) {
      status = repro_hcr_lx_probe_quiesce_begin(250000000ull);
      if (status != 0) break;
      rounds_ok += 1;
      /* BOTH publications inside ONE quiescence: that is the definition of
       * set-wide atomicity, and it is the thing tier 1 cannot offer (§6.1's
       * closing paragraph — per-function, never set-wide). */
      if (repro_hcr_lx_probe_apply_direct_patch_at(
              entry_a, repro_hcr_lx_probe_sled_address_for_entry(entry_a),
              body_a, body_a_len) != 0) {
        publications += 1;
      }
      if (repro_hcr_lx_probe_apply_direct_patch_at(
              entry_b, repro_hcr_lx_probe_sled_address_for_entry(entry_b),
              body_b, body_b_len) != 0) {
        publications += 1;
      }
      repro_hcr_lx_probe_quiesce_release();
      usleep(2000);
    }
    window_after = read_window(entry_a);
  } else if (strcmp(mode, "setwide-split") == 0) {
    unsigned long long entry_a =
        (unsigned long long)(uintptr_t)&hcr_lx_m4_q_victim_a;
    unsigned long long entry_b =
        (unsigned long long)(uintptr_t)&hcr_lx_m4_q_victim_b;
    for (i = 0; i < rounds; ++i) {
      /* The control: the same two functions, published in two SEPARATE
       * quiescences with the process running in between. A checker that never
       * reports a mixture here is not discriminating and the `setwide` arm
       * above would be vacuous. */
      status = repro_hcr_lx_probe_quiesce_begin(250000000ull);
      if (status != 0) break;
      rounds_ok += 1;
      if (repro_hcr_lx_probe_apply_direct_patch_at(
              entry_a, repro_hcr_lx_probe_sled_address_for_entry(entry_a),
              body_a, body_a_len) != 0) {
        publications += 1;
      }
      repro_hcr_lx_probe_quiesce_release();
      usleep(2000);
      status = repro_hcr_lx_probe_quiesce_begin(250000000ull);
      if (status != 0) break;
      if (repro_hcr_lx_probe_apply_direct_patch_at(
              entry_b, repro_hcr_lx_probe_sled_address_for_entry(entry_b),
              body_b, body_b_len) != 0) {
        publications += 1;
      }
      repro_hcr_lx_probe_quiesce_release();
      usleep(2000);
      break; /* one split transition is all the control needs */
    }
    window_after = read_window(entry_a);
  } else {
    unsigned long long entry_a =
        (unsigned long long)(uintptr_t)&hcr_lx_m4_q_victim_a;
    for (i = 0; i < rounds; ++i) {
      int slots;
      int s;
      status = repro_hcr_lx_probe_quiesce_begin(250000000ull);
      if (status != 0) {
        break;
      }
      rounds_ok += 1;
      slots = repro_hcr_lx_probe_quiesce_slot_count();
      slot_count_last = slots;
      for (s = 0; s < slots; ++s) {
        if (repro_hcr_lx_probe_quiesce_slot_parked(s) != 1) {
          continue;
        }
        parked_total += 1;
        if (repro_hcr_lx_probe_quiesce_slot_pc(s) != 0) {
          pcs_nonzero += 1;
        }
      }
      if (repro_hcr_lx_probe_quiesce_park_ns() > park_ns_max) {
        park_ns_max = repro_hcr_lx_probe_quiesce_park_ns();
      }
      repro_hcr_lx_probe_quiesce_release();
      if (repro_hcr_lx_probe_quiesce_release_ns() > release_ns_max) {
        release_ns_max = repro_hcr_lx_probe_quiesce_release_ns();
      }
      resumed_total += repro_hcr_lx_probe_quiesce_resumed_count();
      usleep(1000);
    }
    window_after = read_window(entry_a);
  }

  g_stop = 1;
  if (g_pipe_fds[0][1] >= 0) {
    /* Unblock the readers by giving them the byte they are waiting for. */
    for (i = 0; i < 8; ++i) {
      (void)!write(g_pipe_fds[0][1], "q", 1);
    }
  }
  g_onstack_hold = 0;
  for (i = 0; i < thread_count; ++i) {
    pthread_join(handles[i], NULL);
  }
  for (i = 0; i < thread_count; ++i) {
    eintr_total += g_threads[i].eintr_count;
    eintr_sleep_total += g_threads[i].eintr_sleep_count;
  }

  printf("{\n");
  printf("  \"schemaId\": \"reprobuild.hcr.hlx-m4.linux-quiesce-result.v1\",\n");
  printf("  \"mode\": \"%s\",\n", mode);
  printf("  \"threadsCreated\": %d,\n", thread_count);
  printf("  \"rounds\": %d,\n", rounds);
  printf("  \"roundsOk\": %d,\n", rounds_ok);
  printf("  \"lastStatus\": %d,\n", status);
  printf("  \"lastStatusName\": \"%s\",\n",
         repro_hcr_lx_probe_quiesce_status_name(status));
  printf("  \"slotCount\": %d,\n", slot_count_last);
  printf("  \"parkedObservations\": %d,\n", parked_total);
  printf("  \"parkedPcsNonZero\": %d,\n", pcs_nonzero);
  printf("  \"resumedObservations\": %d,\n", resumed_total);
  printf("  \"signalledCount\": %d,\n",
         repro_hcr_lx_probe_quiesce_signalled_count());
  printf("  \"straySignals\": %d,\n",
         repro_hcr_lx_probe_quiesce_stray_signals());
  printf("  \"enumerationRounds\": %d,\n",
         repro_hcr_lx_probe_quiesce_enumeration_rounds());
  printf("  \"eintrRestartable\": %llu,\n", (unsigned long long)eintr_total);
  printf("  \"eintrNanosleep\": %llu,\n",
         (unsigned long long)eintr_sleep_total);
  printf("  \"parkNsMax\": %llu,\n", (unsigned long long)park_ns_max);
  printf("  \"releaseNsMax\": %llu,\n", (unsigned long long)release_ns_max);
  printf("  \"unresponsiveCount\": %d,\n", unresponsive);
  printf("  \"unresponsiveTid\": %d,\n", unresponsive_tid);
  printf("  \"deafTid\": %d,\n", deaf_tid);
  printf("  \"windowBefore\": \"0x%llx\",\n", window_before);
  printf("  \"windowAfter\": \"0x%llx\",\n", window_after);
  printf("  \"onStackDetected\": %d,\n", onstack_detected);
  printf("  \"onStackInFlightValue\": %d,\n", onstack_inflight_value);
  printf("  \"onStackNextValue\": %d,\n", onstack_next_value);
  printf("  \"publications\": %d,\n", publications);
  printf("  \"lastRefusal\": \"%s\",\n",
         repro_hcr_lx_probe_refusal_name(last_refusal));
  printf("  \"setWideBothOld\": %llu,\n",
         (unsigned long long)g_setwide_both_old);
  printf("  \"setWideBothNew\": %llu,\n",
         (unsigned long long)g_setwide_both_new);
  printf("  \"setWideMixed\": %llu,\n", (unsigned long long)g_setwide_mixed);
  printf("  \"setWideOther\": %llu,\n", (unsigned long long)g_setwide_other);
  printf("  \"setWideDiscarded\": %llu,\n",
         (unsigned long long)g_setwide_discarded);
  printf("  \"quiesceSignal\": %d,\n", repro_hcr_lx_probe_quiesce_signo());
  printf("  \"membarrierIssuedCount\": %llu\n",
         repro_hcr_lx_probe_membarrier_issued_count());
  printf("}\n");
  fflush(stdout);
  return 0;
}
