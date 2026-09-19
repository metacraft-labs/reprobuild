/*
 * Tier-2 thread quiescence for the Linux ELF HCR provider (HLX-M4).
 *
 * Implements `reprobuild-specs/HCR/Linux-ELF-Provider.md` §6.2 and §6.3:
 * a `SIGRTMIN+n` handshake that parks every thread in the thread group, reads
 * each parked thread's userspace PC out of the `ucontext_t` the kernel hands the
 * handler, lets the patcher publish while nothing is running, adjusts the resume
 * PC of any thread caught inside a window being written, and releases.
 *
 * WHY THIS FILE EXISTS AT ALL, stated once so it is not re-litigated:
 *
 *   - `ptrace` cannot be used. Linux forbids a thread from tracing another
 *     thread in its own thread group, and this agent is in-process by design.
 *   - `tgkill(SIGSTOP)` — which `HCR/HCR-Overview.md:219` and `:500` still name
 *     — is wrong twice over. `SIGSTOP` cannot be caught, so it yields no PC,
 *     which is the entire point of quiescence; and stop signals are
 *     process-directed in effect, so signalling any one tid stops the patching
 *     thread too and nothing is left running to issue `SIGCONT`.
 *   - `/proc/self/task/<tid>/stat` cannot substitute for the handler. Measured
 *     during design review: `kstkeip` is gated and is a KERNEL pc for a sleeping
 *     task, and `0` for a running one. In-process, the `ucontext_t` handed to a
 *     signal handler is the only reliable source of another thread's userspace
 *     PC. Do not resurrect the `/proc` approach.
 *
 * ASYNC-SIGNAL SAFETY AND THE ALLOCATION RULE (§6.2, "Deadlock hazards").
 * A thread may be parked while holding the loader lock or a malloc arena lock.
 * The patcher therefore allocates NOTHING between the first `tgkill` and the
 * release, and the handler calls no libc function that could take either lock.
 * Concretely, everything on the parked path is a raw syscall or a plain memory
 * access:
 *
 *   - thread enumeration is raw `openat`/`getdents64`/`close` over a STATIC
 *     buffer, never `opendir`/`readdir`, which malloc;
 *   - parking is the raw `futex` syscall, never `sem_wait` or a pthread
 *     condition variable, neither of which is async-signal-safe;
 *   - the slot a handler writes into is found by a linear scan of a static
 *     array, so no allocation and no lock is needed to locate it.
 *
 * NOT STANDALONE. This header is included from `repro_hcr_linux_x86_64.h`,
 * which owns the refusal vocabulary and the raw-syscall helpers it reuses. It
 * has no include guard problems of its own but it will not compile on its own.
 */

#ifndef REPRO_HCR_LINUX_QUIESCE_H
#define REPRO_HCR_LINUX_QUIESCE_H

#if defined(__linux__) && defined(__x86_64__)

#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <ucontext.h>

/* ---------------------------------------------------------------------------
 * Raw syscalls the parked path needs, beyond the three-argument helper
 * `repro_hcr_linux_x86_64.h` already defines.
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_LX_NR_CLOSE 3
#define REPRO_HCR_LX_NR_GETPID 39
#define REPRO_HCR_LX_NR_SCHED_YIELD 24
#define REPRO_HCR_LX_NR_FUTEX 202
#define REPRO_HCR_LX_NR_GETDENTS64 217
#define REPRO_HCR_LX_NR_GETTID 186
#define REPRO_HCR_LX_NR_TGKILL 234
#define REPRO_HCR_LX_NR_OPENAT 257
#define REPRO_HCR_LX_NR_CLOCK_GETTIME 228

#define REPRO_HCR_LX_AT_FDCWD (-100)
#define REPRO_HCR_LX_O_RDONLY 0
#define REPRO_HCR_LX_O_DIRECTORY 0200000
#define REPRO_HCR_LX_O_CLOEXEC 02000000

#define REPRO_HCR_LX_FUTEX_WAIT 0
#define REPRO_HCR_LX_FUTEX_WAKE 1
#define REPRO_HCR_LX_FUTEX_PRIVATE_FLAG 128

#define REPRO_HCR_LX_CLOCK_MONOTONIC 1

/* Provided by the including translation unit, exactly as
 * `repro_hcr_linux_x86_64.h` declares it. Forward-declared here because the
 * nested-frame scan below needs the page size and this header is included
 * before that declaration. */
static size_t repro_hcr_lx_page_size(void);

static long repro_hcr_lx_syscall0(long number) {
  long result;
  __asm__ volatile("syscall"
                   : "=a"(result)
                   : "a"(number)
                   : "rcx", "r11", "memory");
  return result;
}

static long repro_hcr_lx_syscall4(long number, long a0, long a1, long a2,
                                  long a3) {
  long result;
  register long r10 __asm__("r10") = a3;
  __asm__ volatile("syscall"
                   : "=a"(result)
                   : "a"(number), "D"(a0), "S"(a1), "d"(a2), "r"(r10)
                   : "rcx", "r11", "memory");
  return result;
}

static long repro_hcr_lx_raw_gettid(void) {
  return repro_hcr_lx_syscall0(REPRO_HCR_LX_NR_GETTID);
}

static long repro_hcr_lx_raw_getpid(void) {
  return repro_hcr_lx_syscall0(REPRO_HCR_LX_NR_GETPID);
}

static long repro_hcr_lx_raw_sched_yield(void) {
  return repro_hcr_lx_syscall0(REPRO_HCR_LX_NR_SCHED_YIELD);
}

static long repro_hcr_lx_raw_tgkill(long tgid, long tid, long signo) {
  return repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_TGKILL, tgid, tid, signo);
}

static long repro_hcr_lx_raw_futex_wait(volatile int32_t *word,
                                        int32_t expected) {
  return repro_hcr_lx_syscall4(
      REPRO_HCR_LX_NR_FUTEX, (long)(uintptr_t)word,
      (long)(REPRO_HCR_LX_FUTEX_WAIT | REPRO_HCR_LX_FUTEX_PRIVATE_FLAG),
      (long)expected, 0);
}

static long repro_hcr_lx_raw_futex_wake(volatile int32_t *word, int32_t count) {
  return repro_hcr_lx_syscall3(
      REPRO_HCR_LX_NR_FUTEX, (long)(uintptr_t)word,
      (long)(REPRO_HCR_LX_FUTEX_WAKE | REPRO_HCR_LX_FUTEX_PRIVATE_FLAG),
      (long)count);
}

static uint64_t repro_hcr_lx_monotonic_ns(void) {
  struct {
    long tv_sec;
    long tv_nsec;
  } ts;
  ts.tv_sec = 0;
  ts.tv_nsec = 0;
  (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOCK_GETTIME,
                              REPRO_HCR_LX_CLOCK_MONOTONIC,
                              (long)(uintptr_t)&ts, 0);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* ---------------------------------------------------------------------------
 * State.
 *
 * Every byte below is statically allocated, for the reason in the header
 * comment: the patcher must not call the allocator while any thread is parked,
 * and the handler must not either.
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_LX_MAX_QUIESCE_THREADS 512
#define REPRO_HCR_LX_MAX_QUIESCE_FRAMES 24
/* How many signal-blocked threads are NAMED in the refusal. The count is
 * reported in full regardless; this only bounds the static name table. */
#define REPRO_HCR_LX_MAX_BLOCKED_THREADS 64
#define REPRO_HCR_LX_COMM_MAX 16 /* TASK_COMM_LEN, including the NUL */
#define REPRO_HCR_LX_TASK_DIR_BUFFER 65536
#define REPRO_HCR_LX_DEFAULT_QUIESCE_TIMEOUT_NS 250000000ull /* §6.3: 250 ms */

enum {
  REPRO_HCR_LX_QUIESCE_OK = 0,
  REPRO_HCR_LX_QUIESCE_NOT_INSTALLED = 1,
  REPRO_HCR_LX_QUIESCE_TIMEOUT = 2,
  REPRO_HCR_LX_QUIESCE_ENUMERATION_FAILED = 3,
  REPRO_HCR_LX_QUIESCE_TOO_MANY_THREADS = 4,
  REPRO_HCR_LX_QUIESCE_ALREADY_HELD = 5,
  REPRO_HCR_LX_QUIESCE_SIGNAL_FAILED = 6,
  REPRO_HCR_LX_QUIESCE_MAPS_UNAVAILABLE = 7,
  /*
   * A thread in this thread group was created with the quiescence signal
   * BLOCKED, so it can never take the handshake and can never park. Distinct
   * from `TIMEOUT` because the two have opposite remedies: a timeout invites
   * "raise the deadline", and no deadline can help a thread the kernel will
   * never deliver the signal to. See
   * `repro_hcr_lx_census_unresponsive_signal_masks`.
   */
  REPRO_HCR_LX_QUIESCE_SIGNAL_BLOCKED = 8
};

static const char *repro_hcr_lx_quiesce_status_name(int code) {
  switch (code) {
    case REPRO_HCR_LX_QUIESCE_OK:
      return "ok";
    case REPRO_HCR_LX_QUIESCE_NOT_INSTALLED:
      return "quiescence-handler-not-installed";
    case REPRO_HCR_LX_QUIESCE_TIMEOUT:
      return "quiescence-timeout";
    case REPRO_HCR_LX_QUIESCE_ENUMERATION_FAILED:
      return "quiescence-thread-enumeration-failed";
    case REPRO_HCR_LX_QUIESCE_TOO_MANY_THREADS:
      return "quiescence-too-many-threads";
    case REPRO_HCR_LX_QUIESCE_ALREADY_HELD:
      return "quiescence-already-held";
    case REPRO_HCR_LX_QUIESCE_SIGNAL_FAILED:
      return "quiescence-signal-delivery-failed";
    case REPRO_HCR_LX_QUIESCE_MAPS_UNAVAILABLE:
      return "quiescence-maps-snapshot-unavailable";
    case REPRO_HCR_LX_QUIESCE_SIGNAL_BLOCKED:
      return "quiescence-signal-blocked";
    default:
      return "quiescence-unknown";
  }
}

#define REPRO_HCR_LX_MAX_NESTED_SIGNAL_FRAMES 4

typedef struct repro_hcr_lx_parked_thread {
  volatile int32_t tid;
  volatile int32_t parked;      /* 1 once the handler is about to futex-wait */
  volatile int32_t resumed;     /* 1 once the handler has left the wait */
  volatile int32_t adjusted;    /* 1 when the patcher rewrote the resume PC */
  volatile uint64_t pc;         /* userspace PC from uc_mcontext, tier-2's point */
  volatile uint64_t sp;
  volatile uint64_t resume_pc;  /* 0 = resume where you were */
  volatile uint32_t frame_count;
  /*
   * HLX-M4, 2026-09-19 — 1 when the frame-pointer chain ENDED, 0 when the walk
   * merely STOPPED.
   *
   * Without this the two are the same observation: a thread whose `rbp` holds
   * arbitrary data (any `-fomit-frame-pointer` frame, which is `-O2`'s default)
   * produces `frame_count == 0` exactly as a thread whose chain legitimately
   * terminated at its entry frame does. `threads_on_stack_in` then answers a
   * DETERMINATE zero over a walk that saw nothing, which is the reverse of what
   * this file's own walk comment instructs callers to do.
   */
  volatile uint32_t frames_complete;
  volatile uint64_t frames[REPRO_HCR_LX_MAX_QUIESCE_FRAMES];
  /*
   * OUTER signal frames, and this field is here because HLX-M4 MEASURED that
   * without it tier-2 does not work on a target that uses signals.
   *
   * `pc` above is the PC of the context our handler interrupted. When the
   * quiescence signal arrives while the thread is already inside one of the
   * APPLICATION's own signal handlers, that context is the handler, and the
   * thread's real resume point — the one that may be sitting inside the
   * publication window — is one `sigreturn` further down. Adjusting only `pc`
   * leaves it untouched, the thread `sigreturn`s into the freshly written
   * `rel32`, and the process dies with `SIGILL`.
   *
   * Measured on this host before this field existed: 12 worker threads, one
   * publication per process, an empty `SIGURG` handler being delivered
   * continuously — 8 of 12 processes died at window+3 UNDER FULL TIER-2
   * QUIESCENCE. With no signal storm the same configuration died 0 of 12. The
   * signal storm was the whole difference.
   */
  volatile uint32_t nested_count;
  volatile uint64_t nested_pc[REPRO_HCR_LX_MAX_NESTED_SIGNAL_FRAMES];
  volatile uint64_t nested_pc_slot[REPRO_HCR_LX_MAX_NESTED_SIGNAL_FRAMES];
} repro_hcr_lx_parked_thread;

typedef struct repro_hcr_lx_quiesce_state {
  int installed;
  int signo;
  int held;                       /* 1 between a successful begin and release */
  int32_t patcher_tid;
  int32_t slot_count;
  volatile int32_t release_word;  /* futex word; 0 = park, 1 = run */
  volatile int32_t parked_count;
  volatile int32_t resumed_count;
  volatile int32_t stray_signals; /* handler ran with no slot: thread appeared
                                   * after enumeration */
  int32_t signalled_count;
  int32_t enumeration_rounds;
  int32_t unresponsive_count;
  int32_t unresponsive_tids[REPRO_HCR_LX_MAX_QUIESCE_THREADS];
  uint64_t last_begin_ns;
  uint64_t last_park_ns;          /* wall time from first tgkill to all parked */
  uint64_t last_release_ns;
  uint64_t adjust_count;          /* lifetime count of IP adjustments made */
  uint64_t nested_adjust_count;   /* of those, ones in an OUTER signal frame */
  uint64_t nested_frames_seen;    /* outer signal frames located while parking */
  uint64_t begin_count;
  uint64_t timeout_count;
  int32_t last_status;
  int32_t readable_ranges;        /* mappings in the snapshot the scan uses */
  /*
   * Threads whose `tgkill` failed with something OTHER than `ESRCH`, and the
   * first such tid. Added by HLX-M4's review: the delivery loop used to mark
   * EVERY failed delivery as "thread already gone", which made a live,
   * running, UNSIGNALLED thread indistinguishable from an exited one and let
   * `begin` return OK with the hazard fully live. See the loop for the detail.
   */
  int32_t signal_failed_count;
  int32_t signal_failed_tid;
  int32_t signal_failed_errno;    /* positive errno of the first such failure */
  int32_t exited_count;           /* deliveries that really did get ESRCH */
  /*
   * The signal-mask census taken AFTER the deadline expires, over the threads
   * that did not park (see `repro_hcr_lx_census_unresponsive_signal_masks`,
   * whose comment explains why it must not run before the wait).
   * `sigmask_read_ok` is the anti-vacuity counter: a census that read nothing
   * would report zero blocked threads, which is byte-for-byte what a healthy
   * process reports.
   */
  int32_t sigmask_read_ok;
  int32_t sigmask_read_failed;
  int32_t blocked_count;
  int32_t blocked_tids[REPRO_HCR_LX_MAX_BLOCKED_THREADS];
  uint64_t blocked_masks[REPRO_HCR_LX_MAX_BLOCKED_THREADS];
  char blocked_names[REPRO_HCR_LX_MAX_BLOCKED_THREADS]
                    [REPRO_HCR_LX_COMM_MAX];
  repro_hcr_lx_parked_thread slots[REPRO_HCR_LX_MAX_QUIESCE_THREADS];
} repro_hcr_lx_quiesce_state;

static repro_hcr_lx_quiesce_state repro_hcr_lx_quiesce;

/*
 * Test-only lever, and it exists because a quiescence path that silently
 * no-ops would pass every safety test for free (HLX-M4's stated dominant
 * failure mode). Setting this to 1 makes `repro_hcr_lx_quiesce_adjust_window`
 * compute and COUNT the adjustments it would make and then decline to apply
 * them, so the gate can demonstrate that the adjustment is what prevents the
 * in-window resume from executing the tail of a freshly published `E9 rel32`.
 * The agent never sets it.
 */
static int repro_hcr_lx_quiesce_suppress_adjust = 0;

/* ---------------------------------------------------------------------------
 * Slot lookup. Linear scan, no allocation, no lock — callable from a handler.
 * ------------------------------------------------------------------------- */

static repro_hcr_lx_parked_thread *repro_hcr_lx_quiesce_slot_for(int32_t tid) {
  int32_t i;
  int32_t count = repro_hcr_lx_quiesce.slot_count;
  for (i = 0; i < count; ++i) {
    if (repro_hcr_lx_quiesce.slots[i].tid == tid) {
      return &repro_hcr_lx_quiesce.slots[i];
    }
  }
  return NULL;
}

/* ---------------------------------------------------------------------------
 * Frame-pointer stack walk, for on-stack detection (§6.2 step 5).
 *
 * Deliberately NOT `_Unwind_Backtrace`: libgcc's unwinder takes a global lock
 * and can allocate on its first FDE lookup, which is exactly the deadlock the
 * allocation rule above exists to prevent — a thread parked inside `malloc`
 * plus a handler that calls `malloc` is the classic self-deadlock. A frame
 * pointer walk is pure aligned memory reads and is async-signal-safe.
 *
 * The cost, recorded rather than hidden: it only sees frames compiled with a
 * frame pointer. A target built `-fomit-frame-pointer` (the default at `-O2`)
 * yields the innermost PC and usually nothing else, so `skippedFunctions`
 * derived from it is a LOWER BOUND on what is on-stack, never an upper one.
 * DECIDED 2026-09-19 (HLX-M4): the frame-pointer lower bound IS the shipped
 * answer on Linux x86_64, and the DWARF walk this comment used to defer to
 * HLX-M5 is REFUSED rather than deferred again. The reason is the paragraph
 * above, not a scheduling one: `_Unwind_Backtrace` is not async-signal-safe,
 * this walk runs in a signal handler with every other thread parked, and
 * HLX-M4's third deliverable forbids allocating anywhere between the signal
 * and the release. HLX-M5 landed `.eh_frame` REGISTRATION, which makes an
 * unwinder able to DESCRIBE a patch body; it does not make this handler able
 * to CALL one. What changes instead is the REPORT: the bound now says it is a
 * bound. See `frames_complete` on the slot and the `-1` arm of
 * `repro_hcr_lx_quiesce_threads_on_stack_in`.
 *
 * `out_complete` receives 1 only when the chain ENDED — a null frame pointer
 * or a null return address, i.e. the two ways a well-formed chain terminates.
 * Every other exit (misalignment, the ascending/span bound, capacity) is the
 * walk giving up, and the caller must not read the resulting count as an
 * answer about the program.
 *
 * Bounds discipline: the chain must be strictly ascending, 8-aligned, start at
 * or above the interrupted SP, and stay inside 8 MiB of it. A wild `rbp` in a
 * frame-pointer-less frame therefore terminates the walk instead of faulting.
 */
static uint32_t repro_hcr_lx_quiesce_walk_frames(uint64_t frame_pointer,
                                                 uint64_t stack_pointer,
                                                 volatile uint64_t *out,
                                                 uint32_t capacity,
                                                 volatile uint32_t *out_complete) {
  const uint64_t span = 8ull * 1024ull * 1024ull;
  uint64_t fp = frame_pointer;
  uint64_t previous = stack_pointer;
  uint32_t produced = 0;
  *out_complete = 0;
  while (produced < capacity) {
    uint64_t next_fp;
    uint64_t return_address;
    if (fp == 0) {
      /* The chain ENDED: a thread entry frame's saved `rbp` is zero. */
      *out_complete = 1;
      break;
    }
    if ((fp & 7u) != 0) {
      break;
    }
    if (fp < previous || fp - stack_pointer > span) {
      break;
    }
    memcpy(&next_fp, (const void *)(uintptr_t)fp, sizeof(next_fp));
    memcpy(&return_address, (const void *)(uintptr_t)(fp + 8),
           sizeof(return_address));
    if (return_address == 0) {
      /* Also an end, not a give-up: no caller to return to. */
      *out_complete = 1;
      break;
    }
    out[produced] = return_address;
    produced += 1;
    previous = fp;
    fp = next_fp;
  }
  return produced;
}

/* ---------------------------------------------------------------------------
 * The handler. Everything it does is async-signal-safe.
 * ------------------------------------------------------------------------- */

/*
 * Find the OUTER signal frames a parked thread is sitting on.
 *
 * Layout, and it is checked rather than trusted (see `trampoline_verified`):
 * the kernel builds `struct rt_sigframe { char *pretcode; ucontext_t uc;
 * siginfo_t info; ... }` on the thread's stack and hands the handler `&uc` as
 * its third argument. So `pretcode` — the address of glibc's `__restore_rt`
 * trampoline — is the 8 bytes immediately BELOW the `ucontext_t` we were given,
 * and the same value appears at the base of every outer frame.
 *
 * Scanning for it from the interrupted stack pointer therefore locates each
 * outer frame, and `slot + 8` is that frame's `ucontext_t`. The one field we
 * want is `uc_mcontext.gregs[REG_RIP]`: the PC that `sigreturn` will restore.
 *
 * SOUNDNESS OF THE SCAN, stated because a stack scan for a magic value is the
 * kind of thing that is usually wrong. A false positive can only do harm if the
 * word 8 bytes past a stale trampoline pointer happens to be a plausible
 * `ucontext_t` AND the `REG_RIP` slot inside it happens to hold an address
 * inside the eight bytes this publication is about to write. The caller acts on
 * a hit only under that last condition, so a false positive that matters must
 * guess one specific 8-byte range out of the address space. A false NEGATIVE is
 * the safe direction and is what the pre-HLX-M4 code did unconditionally.
 */
static int repro_hcr_lx_nested_scan_enabled = 1;
static uint64_t repro_hcr_lx_sigreturn_trampoline = 0;
static int repro_hcr_lx_trampoline_verified = 0;
static int repro_hcr_lx_trampoline_mismatch = 0;

#define REPRO_HCR_LX_NR_READ 0
#define REPRO_HCR_LX_NESTED_SCAN_BYTES 32768u
#define REPRO_HCR_LX_MAX_READABLE_RANGES 8192
#define REPRO_HCR_LX_MAPS_CHUNK 65536

/*
 * WHICH ADDRESSES CAN THIS PROCESS READ?
 *
 * A stack scan inside a signal handler cannot recover from a fault, so it must
 * never read an address it has not established is readable. Three probes were
 * tried and TWO OF THEM WERE VACUOUS — recorded here in full because each one
 * looked correct and each one produced a green-looking handler that killed the
 * process:
 *
 *  1. No probe at all, fixed 64 KiB scan: 16/16 runs died with rc 139 and an
 *     empty stderr. A thread that has used almost none of its stack sits a few
 *     kilobytes below the stack's TOP, so the scan walked off it immediately.
 *  2. `msync(MS_ASYNC)`: 16/16, unchanged. `msync` answers "is this MAPPED",
 *     and glibc puts a `PROT_NONE` guard page beside every thread stack. A
 *     guard page is mapped and unreadable.
 *  3. `write(devnull_fd, p, 1)`: 16/16, unchanged, and this is the instructive
 *     one. Linux's `/dev/null` write handler RETURNS THE COUNT WITHOUT EVER
 *     COPYING FROM USER, so it cannot report `EFAULT` — the probe answered
 *     "readable" for every address in the address space, including unmapped
 *     ones. A probe that can only return success is trap 4 wearing a syscall:
 *     it passed every check and had stopped asking the question.
 *
 * What works is to stop probing and to KNOW. `/proc/self/maps` is read ONCE per
 * quiescence, in `begin`, BEFORE the first `tgkill` — so it is on the side of
 * the allocation boundary where a read is allowed — and parsed into a static
 * table of readable ranges. The handler then bounds its scan by the range that
 * contains the interrupted stack pointer, which is both sound and exact: it
 * cannot leave the thread's own stack mapping.
 */

typedef struct repro_hcr_lx_readable_range {
  uint64_t start;
  uint64_t end;
} repro_hcr_lx_readable_range;

static repro_hcr_lx_readable_range
    repro_hcr_lx_readable_ranges[REPRO_HCR_LX_MAX_READABLE_RANGES];
static int32_t repro_hcr_lx_readable_range_count = 0;
static int32_t repro_hcr_lx_maps_truncated = 0;
static char repro_hcr_lx_maps_chunk[REPRO_HCR_LX_MAPS_CHUNK];

static int repro_hcr_lx_hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/* Parses one `START-END PERMS ...` line. Returns 1 when it recorded a readable
 * range, 0 otherwise. */
static int repro_hcr_lx_parse_maps_line(const char *line, size_t length) {
  uint64_t start = 0;
  uint64_t end = 0;
  size_t i = 0;
  int digits = 0;
  while (i < length) {
    int value = repro_hcr_lx_hex_value(line[i]);
    if (value < 0) break;
    start = (start << 4) | (uint64_t)value;
    i += 1;
    digits += 1;
  }
  if (digits == 0 || i >= length || line[i] != '-') return 0;
  i += 1;
  digits = 0;
  while (i < length) {
    int value = repro_hcr_lx_hex_value(line[i]);
    if (value < 0) break;
    end = (end << 4) | (uint64_t)value;
    i += 1;
    digits += 1;
  }
  if (digits == 0 || i + 1 >= length || line[i] != ' ') return 0;
  if (line[i + 1] != 'r') return 0; /* not readable — the case that matters */
  if (repro_hcr_lx_readable_range_count >= REPRO_HCR_LX_MAX_READABLE_RANGES) {
    repro_hcr_lx_maps_truncated = 1;
    return 0;
  }
  repro_hcr_lx_readable_ranges[repro_hcr_lx_readable_range_count].start = start;
  repro_hcr_lx_readable_ranges[repro_hcr_lx_readable_range_count].end = end;
  repro_hcr_lx_readable_range_count += 1;
  return 1;
}

static int repro_hcr_lx_snapshot_readable_ranges(void) {
  long fd = repro_hcr_lx_syscall3(
      REPRO_HCR_LX_NR_OPENAT, REPRO_HCR_LX_AT_FDCWD,
      (long)(uintptr_t) "/proc/self/maps",
      REPRO_HCR_LX_O_RDONLY | REPRO_HCR_LX_O_CLOEXEC);
  size_t held = 0;
  repro_hcr_lx_readable_range_count = 0;
  repro_hcr_lx_maps_truncated = 0;
  if (fd < 0) {
    return 0;
  }
  for (;;) {
    long got = repro_hcr_lx_syscall3(
        REPRO_HCR_LX_NR_READ, fd,
        (long)(uintptr_t)(repro_hcr_lx_maps_chunk + held),
        (long)(sizeof(repro_hcr_lx_maps_chunk) - held));
    size_t available;
    size_t consumed = 0;
    size_t j;
    if (got <= 0) {
      break;
    }
    available = held + (size_t)got;
    for (j = 0; j < available; ++j) {
      if (repro_hcr_lx_maps_chunk[j] == '\n') {
        (void)repro_hcr_lx_parse_maps_line(repro_hcr_lx_maps_chunk + consumed,
                                           j - consumed);
        consumed = j + 1;
      }
    }
    held = available - consumed;
    if (held >= sizeof(repro_hcr_lx_maps_chunk)) {
      /* A single line longer than the chunk cannot happen for maps output;
       * dropping it rather than looping forever is the safe failure. */
      held = 0;
    } else if (held > 0 && consumed > 0) {
      memmove(repro_hcr_lx_maps_chunk, repro_hcr_lx_maps_chunk + consumed,
              held);
    }
  }
  (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, fd, 0, 0);
  return repro_hcr_lx_readable_range_count;
}

/* End of the readable range containing `address`, or 0 when it is in none. */
static uint64_t repro_hcr_lx_readable_end_of(uint64_t address) {
  int32_t i;
  for (i = 0; i < repro_hcr_lx_readable_range_count; ++i) {
    if (address >= repro_hcr_lx_readable_ranges[i].start &&
        address < repro_hcr_lx_readable_ranges[i].end) {
      return repro_hcr_lx_readable_ranges[i].end;
    }
  }
  return 0;
}


/*
 * Where the quiescence handler was when it last ran.
 *
 * This is not scaffolding left behind. A handler runs with the process's
 * signals blocked and cannot report anything about itself if it faults, and
 * during HLX-M4 three successive wrong stack-probe designs each produced the
 * same symptom — the process dying with no output — that this one byte
 * distinguished in a single run. It costs a store per stage and it is the only
 * evidence available from inside a handler that dies.
 *
 * 1 = reading the interrupted PC, 2 = frame-pointer walk, 3 = nested signal
 * frame scan, 4 = parked, 5 = resumed.
 */
static volatile int repro_hcr_lx_quiesce_handler_stage = 0;

static uint32_t repro_hcr_lx_collect_nested_frames(
    uint64_t scan_from, volatile uint64_t *out_pc,
    volatile uint64_t *out_slot, uint32_t capacity) {
  uint64_t cursor = (scan_from + 7u) & ~(uint64_t)7u;
  uint64_t readable_end;
  uint64_t limit;
  uint32_t produced = 0;
  if (!repro_hcr_lx_nested_scan_enabled ||
      !repro_hcr_lx_trampoline_verified) {
    return 0;
  }
  readable_end = repro_hcr_lx_readable_end_of(cursor);
  if (readable_end == 0) {
    return 0;
  }
  limit = cursor + REPRO_HCR_LX_NESTED_SCAN_BYTES;
  if (limit > readable_end) {
    limit = readable_end;
  }
  while (cursor + 8 <= limit && produced < capacity) {
    uint64_t word;
    memcpy(&word, (const void *)(uintptr_t)cursor, sizeof(word));
    if (word == repro_hcr_lx_sigreturn_trampoline) {
      const ucontext_t *outer = (const ucontext_t *)(uintptr_t)(cursor + 8);
      uint64_t rip_slot =
          (uint64_t)(uintptr_t)&outer->uc_mcontext.gregs[REG_RIP];
      /* The slot is read here and WRITTEN later by the patcher, so it has to
       * be inside the same readable range, not merely inside the scan bound. */
      if (rip_slot + 8 <= readable_end) {
        uint64_t rip;
        memcpy(&rip, (const void *)(uintptr_t)rip_slot, sizeof(rip));
        out_pc[produced] = rip;
        out_slot[produced] = rip_slot;
        produced += 1;
      }
    }
    cursor += 8;
  }
  return produced;
}

static void repro_hcr_lx_quiesce_handler(int signo, siginfo_t *info,
                                         void *ucontext) {
  ucontext_t *uc = (ucontext_t *)ucontext;
  int32_t tid = (int32_t)repro_hcr_lx_raw_gettid();
  repro_hcr_lx_parked_thread *slot;
  (void)signo;
  (void)info;

  if (!repro_hcr_lx_trampoline_verified &&
      !repro_hcr_lx_trampoline_mismatch) {
    /* Learn the trampoline address from OUR OWN frame, and cross-check the two
     * independent ways of naming it. `__builtin_return_address(0)` in a signal
     * handler is the sigreturn trampoline; so is the word immediately below the
     * `ucontext_t` the kernel handed us, if the documented `rt_sigframe` layout
     * holds. Requiring them to agree turns an assumption about a kernel ABI
     * into a checked precondition — and a mismatch DISABLES the nested scan
     * loudly (`trampoline_mismatch`) instead of scanning on a wrong value. */
    uint64_t from_layout;
    uint64_t from_builtin =
        (uint64_t)(uintptr_t)__builtin_return_address(0);
    memcpy(&from_layout, (const void *)(uintptr_t)((uintptr_t)uc - 8),
           sizeof(from_layout));
    if (from_builtin != 0 && from_builtin == from_layout) {
      repro_hcr_lx_sigreturn_trampoline = from_builtin;
      repro_hcr_lx_trampoline_verified = 1;
    } else {
      repro_hcr_lx_trampoline_mismatch = 1;
    }
  }

  slot = repro_hcr_lx_quiesce_slot_for(tid);
  if (slot == NULL) {
    /* A thread created after the enumeration that produced the slot table. The
     * begin loop re-enumerates until two consecutive rounds agree precisely so
     * this is transient; counting it is what makes it visible rather than
     * silent. Returning immediately is correct: this thread is not accounted
     * for in `parked_count`, so the patcher will not think it is parked. */
    __atomic_fetch_add(&repro_hcr_lx_quiesce.stray_signals, 1,
                       __ATOMIC_ACQ_REL);
    return;
  }

  repro_hcr_lx_quiesce_handler_stage = 1;
  slot->pc = (uint64_t)uc->uc_mcontext.gregs[REG_RIP];
  slot->sp = (uint64_t)uc->uc_mcontext.gregs[REG_RSP];
  slot->resume_pc = 0;
  slot->adjusted = 0;
  slot->resumed = 0;
  repro_hcr_lx_quiesce_handler_stage = 2;
  slot->frame_count = repro_hcr_lx_quiesce_walk_frames(
      (uint64_t)uc->uc_mcontext.gregs[REG_RBP],
      (uint64_t)uc->uc_mcontext.gregs[REG_RSP], slot->frames,
      REPRO_HCR_LX_MAX_QUIESCE_FRAMES, &slot->frames_complete);
  repro_hcr_lx_quiesce_handler_stage = 3;
  slot->nested_count = repro_hcr_lx_collect_nested_frames(
      (uint64_t)uc->uc_mcontext.gregs[REG_RSP], slot->nested_pc,
      slot->nested_pc_slot, REPRO_HCR_LX_MAX_NESTED_SIGNAL_FRAMES);
  __atomic_fetch_add(&repro_hcr_lx_quiesce.nested_frames_seen,
                     (uint64_t)slot->nested_count, __ATOMIC_ACQ_REL);

  repro_hcr_lx_quiesce_handler_stage = 4;
  __atomic_store_n(&slot->parked, 1, __ATOMIC_RELEASE);
  __atomic_fetch_add(&repro_hcr_lx_quiesce.parked_count, 1, __ATOMIC_ACQ_REL);

  while (__atomic_load_n(&repro_hcr_lx_quiesce.release_word, __ATOMIC_ACQUIRE)
         == 0) {
    (void)repro_hcr_lx_raw_futex_wait(&repro_hcr_lx_quiesce.release_word, 0);
  }

  /*
   * IP adjustment (§6.2 step 6; `Trampoline-Mechanics.md:196`; the Linux
   * realization of Detours' `rAlign`, using this `ucontext_t` where Detours
   * uses `SetThreadContext`).
   *
   * This assignment is the whole reason tier 2 can publish into a window a
   * thread is standing in. Without it the thread resumes at window byte 1..7
   * and executes the TAIL of a freshly written `E9 rel32` as though it were an
   * instruction — design §6.1 point 4, the hazard that keeps tier 1 from
   * shipping.
   */
  if (slot->resume_pc != 0) {
    uc->uc_mcontext.gregs[REG_RIP] = (greg_t)slot->resume_pc;
  }

  repro_hcr_lx_quiesce_handler_stage = 5;
  __atomic_store_n(&slot->resumed, 1, __ATOMIC_RELEASE);
  __atomic_fetch_add(&repro_hcr_lx_quiesce.resumed_count, 1, __ATOMIC_ACQ_REL);
}

/* ---------------------------------------------------------------------------
 * Installation.
 * ------------------------------------------------------------------------- */

static int repro_hcr_lx_quiesce_install(int signo) {
  struct sigaction action;
  if (repro_hcr_lx_quiesce.installed) {
    return REPRO_HCR_LX_QUIESCE_OK;
  }
  if (signo <= 0) {
    signo = SIGRTMIN + 3;
  }
  memset(&action, 0, sizeof(action));
  action.sa_sigaction = repro_hcr_lx_quiesce_handler;
  /* `SA_RESTART` is load-bearing, not decoration: §6.2 step 1. A thread blocked
   * in a restartable syscall must resume transparently, or quiescence becomes a
   * visible `EINTR` storm in the application. */
  action.sa_flags = SA_SIGINFO | SA_RESTART;
  /*
   * Block everything EXCEPT the synchronous fault signals.
   *
   * Blocking `SIGSEGV`/`SIGBUS`/`SIGILL`/`SIGFPE` is never right in any
   * handler, and here it is actively harmful: a synchronous fault raised while
   * its own signal is blocked is forced to `SIG_DFL` by the kernel, so the
   * process dies with no handler run, no diagnostic, and an exit status that
   * says nothing about where it happened. Measured during HLX-M4: a stack scan
   * in this handler that read one page too far produced exactly that — rc 139
   * with an empty stderr — and the defect was invisible until this mask was
   * corrected. Leaving them deliverable costs nothing (the handler must not
   * fault) and turns a silent kill into a located one.
   */
  sigfillset(&action.sa_mask);
  sigdelset(&action.sa_mask, SIGSEGV);
  sigdelset(&action.sa_mask, SIGBUS);
  sigdelset(&action.sa_mask, SIGILL);
  sigdelset(&action.sa_mask, SIGFPE);
  if (sigaction(signo, &action, NULL) != 0) {
    return REPRO_HCR_LX_QUIESCE_NOT_INSTALLED;
  }
  repro_hcr_lx_quiesce.signo = signo;
  repro_hcr_lx_quiesce.installed = 1;
  return REPRO_HCR_LX_QUIESCE_OK;
}

/* ---------------------------------------------------------------------------
 * Thread enumeration: raw `openat`/`getdents64`, static buffer, no allocation.
 * ------------------------------------------------------------------------- */

struct repro_hcr_lx_dirent64 {
  uint64_t d_ino;
  int64_t d_off;
  unsigned short d_reclen;
  unsigned char d_type;
  char d_name[];
};

static char repro_hcr_lx_task_buffer[REPRO_HCR_LX_TASK_DIR_BUFFER];

static int32_t repro_hcr_lx_parse_tid(const char *name) {
  int32_t value = 0;
  const char *p = name;
  if (*p < '0' || *p > '9') {
    return -1;
  }
  while (*p != '\0') {
    if (*p < '0' || *p > '9') {
      return -1;
    }
    value = value * 10 + (int32_t)(*p - '0');
    p += 1;
  }
  return value;
}

/* Fills `out` with the current thread group's tids. Returns the count, or a
 * negative value on failure. Never allocates. */
static int32_t repro_hcr_lx_enumerate_tids(int32_t *out, int32_t capacity) {
  long fd = repro_hcr_lx_syscall3(
      REPRO_HCR_LX_NR_OPENAT, REPRO_HCR_LX_AT_FDCWD,
      (long)(uintptr_t) "/proc/self/task",
      REPRO_HCR_LX_O_RDONLY | REPRO_HCR_LX_O_DIRECTORY |
          REPRO_HCR_LX_O_CLOEXEC);
  int32_t count = 0;
  if (fd < 0) {
    return -1;
  }
  for (;;) {
    long got = repro_hcr_lx_syscall3(
        REPRO_HCR_LX_NR_GETDENTS64, fd,
        (long)(uintptr_t)repro_hcr_lx_task_buffer,
        (long)sizeof(repro_hcr_lx_task_buffer));
    long offset = 0;
    if (got < 0) {
      (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, fd, 0, 0);
      return -1;
    }
    if (got == 0) {
      break;
    }
    while (offset < got) {
      struct repro_hcr_lx_dirent64 *entry =
          (struct repro_hcr_lx_dirent64 *)(repro_hcr_lx_task_buffer + offset);
      int32_t tid = repro_hcr_lx_parse_tid(entry->d_name);
      if (tid > 0) {
        if (count >= capacity) {
          (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, fd, 0, 0);
          return -2;
        }
        out[count] = tid;
        count += 1;
      }
      offset += (long)entry->d_reclen;
    }
  }
  (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, fd, 0, 0);
  return count;
}

static int repro_hcr_lx_tid_sets_agree(const int32_t *a, int32_t a_count,
                                       const int32_t *b, int32_t b_count) {
  int32_t i;
  int32_t j;
  if (a_count != b_count) {
    return 0;
  }
  for (i = 0; i < a_count; ++i) {
    int found = 0;
    for (j = 0; j < b_count; ++j) {
      if (a[i] == b[j]) {
        found = 1;
        break;
      }
    }
    if (!found) {
      return 0;
    }
  }
  return 1;
}

/* ---------------------------------------------------------------------------
 * THE SIGNAL-MASK CENSUS, and why a timeout was the wrong report.
 *
 * Quiescence is a `SIGRTMIN+3` handshake. A thread whose blocked-signal mask
 * contains that signal cannot run the handler, so it can never set `parked`,
 * so `begin` waits out its full deadline and reports `quiescence-timeout` —
 * naming tids, but describing the wrong thing. "Timeout" invites the one
 * remedy that cannot work: a longer deadline. Such a thread is not slow. It is
 * unreachable, and it will be unreachable for every future attempt too.
 *
 * MEASURED, and this is why it is worth a distinct status rather than a
 * comment. A Godot process rendering through Mesa carries threads created by
 * Mesa's `u_thread_create`, which is `sigfillset` minus `SIGSYS`:
 *
 *   tid 1234  llvmpipe-0       SigBlk=fffffffe3ffbfaff
 *   tid 1235  <driver thread>  SigBlk=fffffffe3ffbfaff
 *   tid 1236  godot.l:disk$0   SigBlk=fffffffe3ffbfaff
 *
 * Bit 36 of that mask is set, and bit 36 is signal 37 = `SIGRTMIN+3` on glibc.
 * The same process's 24 Godot `WorkerThread`s carry `SigBlk=0` and park in
 * single-digit milliseconds.
 *
 * WHY THE CENSUS RUNS AFTER THE DEADLINE AND NOT BEFORE IT. The first version
 * of this ran as a PRE-FLIGHT check, refused before signalling anything, and
 * was WRONG — measured, by
 * `e2e_hcr_linux_concurrent_patch_no_torn_instruction`, which lost 9 of 192
 * publications to it. `SigBlk` is not a property of a thread; it is a property
 * of a thread AT AN INSTANT, and two ordinary things set it transiently:
 * a thread executing any signal handler blocks that handler's `sa_mask`, and a
 * thread still inside THIS file's own quiescence handler from a previous
 * publication blocks everything (the handler's mask is `sigfillset` minus the
 * synchronous faults). Both clear on their own, both would have parked, and a
 * pre-flight refusal turned each into a failed patch.
 *
 * After the deadline the distinction is free. A thread that has had the signal
 * pending for the whole deadline and STILL has it masked is the structural
 * case; a transiently-masked thread took the signal and parked long before.
 * And the failure direction is safe: a mislabelled refusal is still a refusal,
 * whereas a pre-flight false positive was a refusal that should never have
 * happened. NOTHING THAT USED TO SUCCEED CAN FAIL BECAUSE OF THIS CODE — it
 * runs only on a path that had already decided to refuse.
 *
 * WHAT IT DOES NOT DO, stated because the tempting next step is unsound. It
 * does not let the publication proceed while those threads run. To skip a
 * thread you must establish that at the instant of the store its PC is not
 * inside the 8-byte publication window, and the only in-process instrument
 * that yields another thread's userspace PC is the `ucontext_t` handed to a
 * signal handler — which is exactly what a signal-blocked thread denies you.
 * `/proc/<tid>/stat`'s `kstkeip` was measured to answer 0 for a running task,
 * the frame-pointer walk in this file is a LOWER bound by construction, and
 * "that thread's code cannot reach this function" is a whole-program
 * reachability claim about a process that `dlopen`s drivers at runtime. Tier 1
 * — publishing with threads unparked — is already falsified by
 * `e2e_hcr_linux_concurrent_patch_no_torn_instruction`, which runs the tier-1
 * arm every time it runs: across observed runs 19 to 21 of its 24 processes
 * crash, with 6.6% to 7.4% of the 2,800 sampled parked PCs inside the
 * publication window. Those are per-run samples of a race, so the gate's own
 * JSON is the authority and no single pair of digits is quoted as THE figure;
 * what does not vary is that the arm never survives. So the honest outcome is
 * the same refusal with the right name on it.
 *
 * A FAILED READ IS NOT A CLEAN ONE, and it is reported rather than swallowed:
 * `sigmask_read_ok` / `sigmask_read_failed` travel into the diagnostic, so a
 * census that read nothing says "masks read for 0 thread(s)" instead of
 * quietly reporting that nothing was blocked.
 * ------------------------------------------------------------------------- */

/*
 * Test-only lever. The census renames the refusal that HLX-M4's timeout
 * fixture provokes, because the only way user space can manufacture an
 * unparkable thread on demand is `pthread_sigmask` — the very thing the census
 * recognises. Turning it off restores the pre-census reporting EXACTLY, so the
 * bounded-abort path goes on being tested by the gate written for it.
 *
 * It cannot make anything unsafe. It runs only inside the timeout branch,
 * after the release, and changes nothing but the NAME of a refusal that has
 * already been decided. The agent never sets it.
 */
static int repro_hcr_lx_quiesce_sigmask_census_enabled = 1;

static char repro_hcr_lx_status_buffer[8192];
static char repro_hcr_lx_status_path[64];

static void repro_hcr_lx_status_path_for(int32_t tid) {
  static const char prefix[] = "/proc/self/task/";
  static const char suffix[] = "/status";
  char digits[16];
  int nd = 0;
  size_t at = 0;
  uint32_t v = (uint32_t)tid;
  size_t i;
  for (i = 0; i < sizeof(prefix) - 1; ++i) {
    repro_hcr_lx_status_path[at++] = prefix[i];
  }
  if (v == 0) {
    digits[nd++] = '0';
  }
  while (v != 0 && nd < (int)sizeof(digits)) {
    digits[nd++] = (char)('0' + (v % 10u));
    v /= 10u;
  }
  while (nd > 0) {
    repro_hcr_lx_status_path[at++] = digits[--nd];
  }
  for (i = 0; i < sizeof(suffix); ++i) { /* includes the NUL */
    repro_hcr_lx_status_path[at++] = suffix[i];
  }
}

/* `SigBlk:` and `Name:` out of one `/proc/self/task/<tid>/status`. Returns 1
 * only when the mask line was found; `out_name` is best-effort and is left as
 * an empty string when the process has no readable `Name:`. */
static int repro_hcr_lx_read_thread_status(int32_t tid, uint64_t *out_mask,
                                           char *out_name) {
  long fd;
  size_t held = 0;
  int found_mask = 0;
  size_t i;
  out_name[0] = '\0';
  *out_mask = 0;
  repro_hcr_lx_status_path_for(tid);
  fd = repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_OPENAT, REPRO_HCR_LX_AT_FDCWD,
                             (long)(uintptr_t)repro_hcr_lx_status_path,
                             REPRO_HCR_LX_O_RDONLY | REPRO_HCR_LX_O_CLOEXEC);
  if (fd < 0) {
    return 0;
  }
  for (;;) {
    long got = repro_hcr_lx_syscall3(
        REPRO_HCR_LX_NR_READ, fd,
        (long)(uintptr_t)(repro_hcr_lx_status_buffer + held),
        (long)(sizeof(repro_hcr_lx_status_buffer) - 1 - held));
    if (got <= 0) {
      break;
    }
    held += (size_t)got;
    if (held >= sizeof(repro_hcr_lx_status_buffer) - 1) {
      break;
    }
  }
  (void)repro_hcr_lx_syscall3(REPRO_HCR_LX_NR_CLOSE, fd, 0, 0);
  repro_hcr_lx_status_buffer[held] = '\0';

  /* Line-oriented scan. `SigBlk:` is a 16-digit hex mask; `Name:` is the
   * thread's `comm`, which is what makes "three threads did not respond"
   * actionable instead of three integers. */
  i = 0;
  while (i < held) {
    size_t start = i;
    size_t j;
    while (i < held && repro_hcr_lx_status_buffer[i] != '\n') {
      i += 1;
    }
    j = start;
    if (held - start >= 7 &&
        memcmp(repro_hcr_lx_status_buffer + start, "SigBlk:", 7) == 0) {
      uint64_t mask = 0;
      int digits = 0;
      j = start + 7;
      while (j < i && (repro_hcr_lx_status_buffer[j] == ' ' ||
                       repro_hcr_lx_status_buffer[j] == '\t')) {
        j += 1;
      }
      while (j < i) {
        int value = repro_hcr_lx_hex_value(repro_hcr_lx_status_buffer[j]);
        if (value < 0) {
          break;
        }
        mask = (mask << 4) | (uint64_t)value;
        digits += 1;
        j += 1;
      }
      if (digits > 0) {
        *out_mask = mask;
        found_mask = 1;
      }
    } else if (held - start >= 5 &&
               memcmp(repro_hcr_lx_status_buffer + start, "Name:", 5) == 0) {
      size_t written = 0;
      j = start + 5;
      while (j < i && (repro_hcr_lx_status_buffer[j] == ' ' ||
                       repro_hcr_lx_status_buffer[j] == '\t')) {
        j += 1;
      }
      while (j < i && written + 1 < (size_t)REPRO_HCR_LX_COMM_MAX) {
        out_name[written++] = repro_hcr_lx_status_buffer[j++];
      }
      out_name[written] = '\0';
    }
    i += 1;
  }
  return found_mask;
}

/*
 * Censuses the tids already recorded in `unresponsive_tids` — the threads that
 * did not park before the deadline. Returns the number that still block
 * `signo`, which is the number that could never have parked at all.
 */
static int32_t repro_hcr_lx_census_unresponsive_signal_masks(int signo) {
  int32_t i;
  uint64_t signal_bit;
  repro_hcr_lx_quiesce.sigmask_read_ok = 0;
  repro_hcr_lx_quiesce.sigmask_read_failed = 0;
  repro_hcr_lx_quiesce.blocked_count = 0;
  if (signo <= 0 || signo > 64) {
    return 0;
  }
  signal_bit = 1ull << (signo - 1);
  for (i = 0; i < repro_hcr_lx_quiesce.unresponsive_count &&
              i < REPRO_HCR_LX_MAX_QUIESCE_THREADS;
       ++i) {
    uint64_t mask = 0;
    char name[REPRO_HCR_LX_COMM_MAX];
    if (!repro_hcr_lx_read_thread_status(
            repro_hcr_lx_quiesce.unresponsive_tids[i], &mask, name)) {
      repro_hcr_lx_quiesce.sigmask_read_failed += 1;
      continue;
    }
    repro_hcr_lx_quiesce.sigmask_read_ok += 1;
    if ((mask & signal_bit) == 0) {
      continue;
    }
    if (repro_hcr_lx_quiesce.blocked_count < REPRO_HCR_LX_MAX_BLOCKED_THREADS) {
      int32_t at = repro_hcr_lx_quiesce.blocked_count;
      size_t c;
      repro_hcr_lx_quiesce.blocked_tids[at] =
          repro_hcr_lx_quiesce.unresponsive_tids[i];
      repro_hcr_lx_quiesce.blocked_masks[at] = mask;
      /*
       * SANITISED, and this is not defensiveness for its own sake. `comm` is
       * 15 arbitrary bytes chosen by whoever created the thread, and this
       * string ends up inside a JSON string field on the coordinator wire. A
       * thread named with a double quote or a backslash produced a message the
       * coordinator could not parse at all — measured: the first Mesa refusal
       * this code reported killed the driver with
       * `JsonParsingError: } expected`, because the names were being quoted
       * into the diagnostic. Anything outside a conservative set becomes '_'.
       */
      for (c = 0; c < (size_t)REPRO_HCR_LX_COMM_MAX; ++c) {
        char ch = name[c];
        if (ch == '\0') {
          repro_hcr_lx_quiesce.blocked_names[at][c] = '\0';
          break;
        }
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
              (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' ||
              ch == '-' || ch == '+' || ch == ':' || ch == '$' ||
              ch == ' ')) {
          ch = '_';
        }
        repro_hcr_lx_quiesce.blocked_names[at][c] = ch;
      }
      repro_hcr_lx_quiesce.blocked_names[at][REPRO_HCR_LX_COMM_MAX - 1] = '\0';
    }
    repro_hcr_lx_quiesce.blocked_count += 1;
  }
  return repro_hcr_lx_quiesce.blocked_count;
}

/* ---------------------------------------------------------------------------
 * begin / release.
 * ------------------------------------------------------------------------- */

static int32_t repro_hcr_lx_quiesce_scratch_a[REPRO_HCR_LX_MAX_QUIESCE_THREADS];
static int32_t repro_hcr_lx_quiesce_scratch_b[REPRO_HCR_LX_MAX_QUIESCE_THREADS];

/*
 * Park every thread but this one, or time out having written nothing.
 *
 * §6.3's safety-by-construction property: this runs during PREPARE, which
 * touches no target text, so an aborted quiescence cannot leave a partial
 * patch. There is no cleanup path to get wrong because there is nothing to
 * clean up.
 */
static int repro_hcr_lx_quiesce_begin(uint64_t timeout_ns) {
  int32_t *current = repro_hcr_lx_quiesce_scratch_a;
  int32_t *previous = repro_hcr_lx_quiesce_scratch_b;
  int32_t current_count;
  int32_t previous_count = -1;
  int32_t rounds = 0;
  int32_t i;
  int32_t expected;
  uint64_t deadline;
  uint64_t started;
  long tgid;

  if (!repro_hcr_lx_quiesce.installed) {
    repro_hcr_lx_quiesce.last_status = REPRO_HCR_LX_QUIESCE_NOT_INSTALLED;
    return REPRO_HCR_LX_QUIESCE_NOT_INSTALLED;
  }
  if (repro_hcr_lx_quiesce.held) {
    repro_hcr_lx_quiesce.last_status = REPRO_HCR_LX_QUIESCE_ALREADY_HELD;
    return REPRO_HCR_LX_QUIESCE_ALREADY_HELD;
  }
  if (timeout_ns == 0) {
    timeout_ns = REPRO_HCR_LX_DEFAULT_QUIESCE_TIMEOUT_NS;
  }

  tgid = repro_hcr_lx_raw_getpid();
  repro_hcr_lx_quiesce.patcher_tid = (int32_t)repro_hcr_lx_raw_gettid();
  repro_hcr_lx_quiesce.parked_count = 0;
  repro_hcr_lx_quiesce.resumed_count = 0;
  repro_hcr_lx_quiesce.stray_signals = 0;
  repro_hcr_lx_quiesce.signalled_count = 0;
  repro_hcr_lx_quiesce.unresponsive_count = 0;
  repro_hcr_lx_quiesce.release_word = 0;
  repro_hcr_lx_quiesce.begin_count += 1;
  __atomic_thread_fence(__ATOMIC_SEQ_CST);

  /*
   * Step 2 (§6.2): enumerate until two consecutive readings agree. The set can
   * change under us, and a thread that appears between the enumeration and the
   * signal would otherwise run free through the publication.
   *
   * ALLOCATION BOUNDARY. Everything above and inside this loop that allocates
   * must do so BEFORE the first `tgkill` below. It does not: the enumeration is
   * raw syscalls over a static buffer, and the slot table is static.
   */
  for (;;) {
    current_count = repro_hcr_lx_enumerate_tids(
        current, REPRO_HCR_LX_MAX_QUIESCE_THREADS);
    if (current_count == -2) {
      repro_hcr_lx_quiesce.last_status = REPRO_HCR_LX_QUIESCE_TOO_MANY_THREADS;
      return REPRO_HCR_LX_QUIESCE_TOO_MANY_THREADS;
    }
    if (current_count < 0) {
      repro_hcr_lx_quiesce.last_status =
          REPRO_HCR_LX_QUIESCE_ENUMERATION_FAILED;
      return REPRO_HCR_LX_QUIESCE_ENUMERATION_FAILED;
    }
    rounds += 1;
    if (previous_count >= 0 &&
        repro_hcr_lx_tid_sets_agree(current, current_count, previous,
                                    previous_count)) {
      break;
    }
    if (rounds > 64) {
      repro_hcr_lx_quiesce.last_status =
          REPRO_HCR_LX_QUIESCE_ENUMERATION_FAILED;
      return REPRO_HCR_LX_QUIESCE_ENUMERATION_FAILED;
    }
    {
      int32_t *swap = previous;
      previous = current;
      current = swap;
      previous_count = current_count;
    }
    (void)repro_hcr_lx_raw_sched_yield();
  }
  repro_hcr_lx_quiesce.enumeration_rounds = rounds;

  /* The readable-range snapshot the handler's stack scan is bounded by. Taken
   * HERE — after enumeration, BEFORE the first `tgkill` — because reading
   * `/proc/self/maps` is exactly the kind of work §6.2's allocation rule
   * forbids once a thread is parked. */
  repro_hcr_lx_quiesce.readable_ranges =
      repro_hcr_lx_snapshot_readable_ranges();
  /*
   * A FAILED SNAPSHOT IS NOT A CLEAN ONE, and this check is here because its
   * absence was a silent self-pass of the exact shape this campaign keeps
   * finding.
   *
   * `repro_hcr_lx_snapshot_readable_ranges` returns 0 when `/proc/self/maps`
   * could not be opened or read. Every live process has readable mappings, so
   * 0 can only mean the observation failed. With 0 ranges
   * `repro_hcr_lx_readable_end_of` answers 0 for every address, so
   * `repro_hcr_lx_collect_nested_frames` bails for every thread and
   * `nested_count` is 0 everywhere — which is byte-for-byte the same state as
   * "no thread was inside an application signal handler". That is the state
   * this very file measured as killing 8 of 12 processes at window+3. The
   * quiescence would still have reported OK, the publication would still have
   * reported `publicationTier: 2`, and `ip_adjustments` would still have read
   * 0, which is also its commonest healthy value.
   *
   * Nothing has been signalled yet, so refusing here costs nothing and needs
   * no release.
   */
  if (repro_hcr_lx_quiesce.readable_ranges <= 0) {
    repro_hcr_lx_quiesce.held = 0;
    repro_hcr_lx_quiesce.last_status = REPRO_HCR_LX_QUIESCE_MAPS_UNAVAILABLE;
    return REPRO_HCR_LX_QUIESCE_MAPS_UNAVAILABLE;
  }

  /* Publish the slot table BEFORE any signal is delivered, or a handler that
   * runs promptly finds no slot and counts itself a stray. */
  expected = 0;
  for (i = 0; i < current_count; ++i) {
    if (current[i] == repro_hcr_lx_quiesce.patcher_tid) {
      continue;
    }
    memset((void *)&repro_hcr_lx_quiesce.slots[expected], 0,
           sizeof(repro_hcr_lx_quiesce.slots[expected]));
    repro_hcr_lx_quiesce.slots[expected].tid = current[i];
    expected += 1;
  }
  __atomic_store_n(&repro_hcr_lx_quiesce.slot_count, expected,
                   __ATOMIC_RELEASE);

  repro_hcr_lx_quiesce.sigmask_read_ok = 0;
  repro_hcr_lx_quiesce.sigmask_read_failed = 0;
  repro_hcr_lx_quiesce.blocked_count = 0;

  started = repro_hcr_lx_monotonic_ns();
  repro_hcr_lx_quiesce.last_begin_ns = started;
  deadline = started + timeout_ns;

  /* Step 3: signal. From here to the release, no allocation. */
  repro_hcr_lx_quiesce.signal_failed_count = 0;
  repro_hcr_lx_quiesce.signal_failed_tid = -1;
  repro_hcr_lx_quiesce.signal_failed_errno = 0;
  repro_hcr_lx_quiesce.exited_count = 0;
  for (i = 0; i < expected; ++i) {
    long rc = repro_hcr_lx_raw_tgkill(
        tgid, (long)repro_hcr_lx_quiesce.slots[i].tid,
        (long)repro_hcr_lx_quiesce.signo);
    if (rc == 0) {
      repro_hcr_lx_quiesce.signalled_count += 1;
      continue;
    }
    /*
     * ONLY `ESRCH` MEANS "THE THREAD IS GONE". Everything else means we failed
     * to signal a thread that is still running, and the two must never be
     * conflated.
     *
     * This loop used to mark every failed delivery `parked = -1` on the
     * strength of the ESRCH reasoning alone, without ever inspecting the
     * errno, and the wait below accepts `parked + dead >= expected`. So any
     * other failure produced quiescence-reported-OK over a live, running,
     * unsignalled thread: `EAGAIN` when the RT signal queue is full
     * (`RLIMIT_SIGPENDING` — precisely what this milestone's own signal-storm
     * workload provokes), `EPERM`, or `EINVAL` from a bad `signo`. In the
     * degenerate case every delivery fails, `dead == expected`, and `begin`
     * returns OK having parked NOTHING while reporting tier 2 — and
     * `quiesce_is_held()` is also what licenses the `sync-core-unavailable`
     * bypass, so the whole tier-2 safety argument rested on it.
     *
     * `REPRO_HCR_LX_QUIESCE_SIGNAL_FAILED` already existed with exactly the
     * right name and was assigned by no code path in the file. It is reached
     * now.
     */
    if (rc == -3 /* -ESRCH */) {
      repro_hcr_lx_quiesce.slots[i].parked = -1;
      repro_hcr_lx_quiesce.exited_count += 1;
      continue;
    }
    if (repro_hcr_lx_quiesce.signal_failed_count == 0) {
      repro_hcr_lx_quiesce.signal_failed_tid =
          repro_hcr_lx_quiesce.slots[i].tid;
      repro_hcr_lx_quiesce.signal_failed_errno = (int32_t)(rc < 0 ? -rc : rc);
    }
    repro_hcr_lx_quiesce.signal_failed_count += 1;
  }

  /*
   * A single undelivered signal invalidates the whole handshake, so bail
   * before the wait rather than waiting out a timeout we already know the
   * cause of. Threads that DID park must still be released, and we must wait
   * for them to actually leave the futex — the same property §6.3 requires of
   * the timeout path, and for the same reason.
   */
  if (repro_hcr_lx_quiesce.signal_failed_count > 0) {
    int32_t still_parked = 0;
    uint64_t release_deadline;
    repro_hcr_lx_quiesce.unresponsive_count = 0;
    for (i = 0; i < expected; ++i) {
      if (repro_hcr_lx_quiesce.slots[i].parked == 1) {
        still_parked += 1;
      }
    }
    /* Name the tids we could not reach, exactly as the timeout path names the
     * ones that did not park: §6.3 requires a diagnostic that identifies the
     * thread, and "signal delivery failed" alone does not. */
    for (i = 0; i < expected && repro_hcr_lx_quiesce.unresponsive_count <
                                   REPRO_HCR_LX_MAX_QUIESCE_THREADS;
         ++i) {
      if (repro_hcr_lx_quiesce.slots[i].parked == 0) {
        repro_hcr_lx_quiesce
            .unresponsive_tids[repro_hcr_lx_quiesce.unresponsive_count] =
            repro_hcr_lx_quiesce.slots[i].tid;
        repro_hcr_lx_quiesce.unresponsive_count += 1;
      }
    }
    __atomic_store_n(&repro_hcr_lx_quiesce.release_word, 1, __ATOMIC_RELEASE);
    (void)repro_hcr_lx_raw_futex_wake(&repro_hcr_lx_quiesce.release_word,
                                      0x7fffffff);
    release_deadline = repro_hcr_lx_monotonic_ns() + timeout_ns;
    while (__atomic_load_n(&repro_hcr_lx_quiesce.resumed_count,
                           __ATOMIC_ACQUIRE) < still_parked) {
      if (repro_hcr_lx_monotonic_ns() >= release_deadline) {
        break;
      }
      (void)repro_hcr_lx_raw_futex_wake(&repro_hcr_lx_quiesce.release_word,
                                        0x7fffffff);
      (void)repro_hcr_lx_raw_sched_yield();
    }
    repro_hcr_lx_quiesce.held = 0;
    repro_hcr_lx_quiesce.last_park_ns =
        repro_hcr_lx_monotonic_ns() - started;
    repro_hcr_lx_quiesce.last_status = REPRO_HCR_LX_QUIESCE_SIGNAL_FAILED;
    return REPRO_HCR_LX_QUIESCE_SIGNAL_FAILED;
  }

  /* Step 4/5: wait for every live slot to park, or time out. */
  for (;;) {
    int32_t parked = 0;
    int32_t dead = 0;
    for (i = 0; i < expected; ++i) {
      if (repro_hcr_lx_quiesce.slots[i].parked == 1) {
        parked += 1;
      } else if (repro_hcr_lx_quiesce.slots[i].parked == -1) {
        dead += 1;
      }
    }
    if (parked + dead >= expected) {
      repro_hcr_lx_quiesce.last_park_ns =
          repro_hcr_lx_monotonic_ns() - started;
      repro_hcr_lx_quiesce.held = 1;
      repro_hcr_lx_quiesce.last_status = REPRO_HCR_LX_QUIESCE_OK;
      return REPRO_HCR_LX_QUIESCE_OK;
    }
    if (repro_hcr_lx_monotonic_ns() >= deadline) {
      /* §6.3: name the unresponsive tids, release everyone who did park, and
       * write nothing. The caller has not touched target text yet, so there is
       * nothing to undo. */
      repro_hcr_lx_quiesce.unresponsive_count = 0;
      for (i = 0; i < expected; ++i) {
        if (repro_hcr_lx_quiesce.slots[i].parked == 0) {
          repro_hcr_lx_quiesce
              .unresponsive_tids[repro_hcr_lx_quiesce.unresponsive_count] =
              repro_hcr_lx_quiesce.slots[i].tid;
          repro_hcr_lx_quiesce.unresponsive_count += 1;
        }
      }
      repro_hcr_lx_quiesce.last_park_ns =
          repro_hcr_lx_monotonic_ns() - started;
      repro_hcr_lx_quiesce.timeout_count += 1;
      /*
       * Release the threads that DID park before reporting failure, and WAIT
       * for them to actually leave the futex. §6.3 says the provider "releases
       * all parked threads"; storing the word and returning would satisfy a
       * reader of the code and not the property, because the caller could then
       * re-quiesce against slots still flagged parked from this attempt.
       * Bounded by the same kind of deadline as the park wait, so a thread that
       * never wakes cannot turn a timeout into a hang.
       */
      {
        int32_t still_parked = 0;
        uint64_t release_deadline;
        for (i = 0; i < expected; ++i) {
          if (repro_hcr_lx_quiesce.slots[i].parked == 1) {
            still_parked += 1;
          }
        }
        __atomic_store_n(&repro_hcr_lx_quiesce.release_word, 1,
                         __ATOMIC_RELEASE);
        (void)repro_hcr_lx_raw_futex_wake(&repro_hcr_lx_quiesce.release_word,
                                          0x7fffffff);
        release_deadline = repro_hcr_lx_monotonic_ns() + timeout_ns;
        while (__atomic_load_n(&repro_hcr_lx_quiesce.resumed_count,
                               __ATOMIC_ACQUIRE) < still_parked) {
          if (repro_hcr_lx_monotonic_ns() >= release_deadline) {
            break;
          }
          (void)repro_hcr_lx_raw_futex_wake(
              &repro_hcr_lx_quiesce.release_word, 0x7fffffff);
          (void)repro_hcr_lx_raw_sched_yield();
        }
      }
      repro_hcr_lx_quiesce.held = 0;
      /*
       * Everyone who parked is out of the futex and out of the handler, so
       * reading `/proc` is allowed again — and the answer is now meaningful,
       * because a thread that had the signal pending for the whole deadline
       * and STILL masks it is structurally unreachable rather than slow. See
       * the census's own comment for why this cannot run before the wait.
       */
      if (repro_hcr_lx_quiesce_sigmask_census_enabled &&
          repro_hcr_lx_census_unresponsive_signal_masks(
              repro_hcr_lx_quiesce.signo) > 0) {
        repro_hcr_lx_quiesce.last_status =
            REPRO_HCR_LX_QUIESCE_SIGNAL_BLOCKED;
        return REPRO_HCR_LX_QUIESCE_SIGNAL_BLOCKED;
      }
      repro_hcr_lx_quiesce.last_status = REPRO_HCR_LX_QUIESCE_TIMEOUT;
      return REPRO_HCR_LX_QUIESCE_TIMEOUT;
    }
    (void)repro_hcr_lx_raw_sched_yield();
  }
}

static int repro_hcr_lx_quiesce_release(void) {
  uint64_t started;
  int32_t i;
  int32_t live = 0;
  if (!repro_hcr_lx_quiesce.held) {
    return REPRO_HCR_LX_QUIESCE_NOT_INSTALLED;
  }
  started = repro_hcr_lx_monotonic_ns();
  for (i = 0; i < repro_hcr_lx_quiesce.slot_count; ++i) {
    if (repro_hcr_lx_quiesce.slots[i].parked == 1) {
      live += 1;
    }
  }
  __atomic_store_n(&repro_hcr_lx_quiesce.release_word, 1, __ATOMIC_RELEASE);
  (void)repro_hcr_lx_raw_futex_wake(&repro_hcr_lx_quiesce.release_word,
                                    0x7fffffff);
  /* Wait for every parked handler to actually leave the wait, so a caller that
   * immediately re-quiesces does not find stale `parked` flags. */
  for (;;) {
    if (__atomic_load_n(&repro_hcr_lx_quiesce.resumed_count, __ATOMIC_ACQUIRE)
        >= live) {
      break;
    }
    (void)repro_hcr_lx_raw_futex_wake(&repro_hcr_lx_quiesce.release_word,
                                      0x7fffffff);
    (void)repro_hcr_lx_raw_sched_yield();
  }
  repro_hcr_lx_quiesce.last_release_ns = repro_hcr_lx_monotonic_ns() - started;
  repro_hcr_lx_quiesce.held = 0;
  return REPRO_HCR_LX_QUIESCE_OK;
}

/*
 * §6.2 step 6. For every parked thread whose PC lies strictly inside the
 * 8-byte window `[window_start, window_end)`, set its resume PC to
 * `resume_target`.
 *
 * Returns the number of threads adjusted. A thread parked exactly AT
 * `window_start` needs no adjustment: it will execute the published `E9` from
 * its first byte, which is a complete and valid instruction.
 */
static int32_t repro_hcr_lx_quiesce_adjust_window(uint64_t window_start,
                                                  uint64_t window_end,
                                                  uint64_t resume_target) {
  int32_t adjusted = 0;
  int32_t i;
  if (!repro_hcr_lx_quiesce.held) {
    return 0;
  }
  for (i = 0; i < repro_hcr_lx_quiesce.slot_count; ++i) {
    repro_hcr_lx_parked_thread *slot = &repro_hcr_lx_quiesce.slots[i];
    uint64_t pc;
    uint32_t n;
    if (slot->parked != 1) {
      continue;
    }
    pc = slot->pc;
    if (pc > window_start && pc < window_end) {
      adjusted += 1;
      if (!repro_hcr_lx_quiesce_suppress_adjust) {
        slot->resume_pc = resume_target;
        slot->adjusted = 1;
      }
    }
    /*
     * The same test against every OUTER signal frame. Writing straight into
     * the parked thread's own stack is safe precisely because it IS parked —
     * nothing will read that `ucontext_t` until this thread `sigreturn`s, and
     * it cannot do that until the release word is stored.
     *
     * This is the half that makes tier 2 work on a target that uses signals.
     * Measured: without it, 8 of 12 fully-quiesced publications died at
     * window+3 when an application handler was being delivered concurrently.
     */
    for (n = 0; n < slot->nested_count; ++n) {
      uint64_t nested = slot->nested_pc[n];
      if (nested <= window_start || nested >= window_end) {
        continue;
      }
      adjusted += 1;
      repro_hcr_lx_quiesce.nested_adjust_count += 1;
      if (repro_hcr_lx_quiesce_suppress_adjust) {
        continue;
      }
      {
        uint64_t target = resume_target;
        memcpy((void *)(uintptr_t)slot->nested_pc_slot[n], &target,
               sizeof(target));
      }
      slot->adjusted = 1;
    }
  }
  repro_hcr_lx_quiesce.adjust_count += (uint64_t)adjusted;
  return adjusted;
}

/*
 * Number of parked threads with at least one frame (PC or a walked return
 * address) inside `[low, high)`. This is §6.2 step 5's on-stack detection, and
 * it is a LOWER bound — see the frame-walk comment.
 *
 * Returns -1 for NOT DETERMINED, and that arm is the HLX-M4 repair of
 * 2026-09-19. A lower bound of zero is not the statement "nothing is on
 * stack"; it is the statement "this walk found nothing", and on a target
 * compiled without frame pointers those are different facts with the same
 * numeral. The rule, stated so it is checkable rather than felt:
 *
 *   - A POSITIVE answer is always determinate. Finding a frame inside the
 *     window is a fact about the program no walk length can retract.
 *   - A ZERO is determinate only if EVERY parked thread's chain ENDED. One
 *     thread whose walk merely stopped is enough to make the zero unknown,
 *     because that thread is exactly where the missed frame would be.
 *
 * `repro_hcr_lx_quiesce_incomplete_walks` is published beside this so the
 * caller can report WHY an answer is indeterminate rather than only that it
 * is; a bare -1 would be the "two causes, one diagnostic" shape
 * (Verification-Harness-Traps §20) between "no threads were parked" and "the
 * walks were blind".
 */
static int32_t repro_hcr_lx_quiesce_incomplete_walks = 0;

static int32_t repro_hcr_lx_quiesce_threads_on_stack_in(uint64_t low,
                                                        uint64_t high) {
  int32_t hits = 0;
  int32_t incomplete = 0;
  int32_t i;
  uint32_t f;
  for (i = 0; i < repro_hcr_lx_quiesce.slot_count; ++i) {
    repro_hcr_lx_parked_thread *slot = &repro_hcr_lx_quiesce.slots[i];
    int found = 0;
    if (slot->parked != 1) {
      continue;
    }
    if (slot->frames_complete != 1) {
      incomplete += 1;
    }
    if (slot->pc >= low && slot->pc < high) {
      found = 1;
    }
    for (f = 0; !found && f < slot->frame_count; ++f) {
      if (slot->frames[f] >= low && slot->frames[f] < high) {
        found = 1;
      }
    }
    if (found) {
      hits += 1;
    }
  }
  repro_hcr_lx_quiesce_incomplete_walks = incomplete;
  if (hits == 0 && incomplete > 0) {
    return -1;
  }
  return hits;
}

static int repro_hcr_lx_quiesce_is_held(void) {
  return repro_hcr_lx_quiesce.held;
}

#endif /* __linux__ && __x86_64__ */

#endif /* REPRO_HCR_LINUX_QUIESCE_H */
