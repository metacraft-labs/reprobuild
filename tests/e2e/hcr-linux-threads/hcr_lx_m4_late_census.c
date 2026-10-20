/* No mocks: a real signal enters the production handler. The wrapper holds
 * sigreturn after it completes, making the kernel's implicit self-block
 * observable deterministically while the timeout census reads /proc. Another
 * arm pauses before the production handler, covering the first-store gap. A real
 * pthread_sigmask arm is the positive control for genuine blocking. */
#define _GNU_SOURCE 1
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/syscall.h>
#include "repro_hcr_linux_x86_64.h"

static size_t repro_hcr_lx_page_size(void) {
  long value = sysconf(_SC_PAGESIZE);
  return value > 0 ? (size_t)value : 4096u;
}

static int ready, leave_handler, done, before_entry;
static int32_t worker_tid;
static void held_handler(int signo, siginfo_t *info, void *context) {
  if (before_entry) {
    __atomic_store_n(&ready, 1, __ATOMIC_RELEASE);
    while (!__atomic_load_n(&leave_handler, __ATOMIC_ACQUIRE))
      repro_hcr_lx_raw_sched_yield();
  }
  repro_hcr_lx_quiesce_handler(signo, info, context);
  __atomic_store_n(&ready, 1, __ATOMIC_RELEASE);
  while (!__atomic_load_n(&leave_handler, __ATOMIC_ACQUIRE))
    repro_hcr_lx_raw_sched_yield();
}
static void *worker(void *arg) {
  sigset_t mask;
  sigemptyset(&mask);
  sigaddset(&mask, repro_hcr_lx_quiesce.signo);
  pthread_sigmask(arg ? SIG_BLOCK : SIG_UNBLOCK, &mask, NULL);
  worker_tid = (int32_t)repro_hcr_lx_raw_gettid();
  __atomic_store_n(&ready, 1, __ATOMIC_RELEASE);
  while (!__atomic_load_n(&done, __ATOMIC_ACQUIRE)) sched_yield();
  return NULL;
}
int main(void) {
  int arm;
  for (arm = 0; arm < 3; ++arm) {
    pthread_t thread;
    struct sigaction action;
    memset(&repro_hcr_lx_quiesce, 0, sizeof(repro_hcr_lx_quiesce));
    repro_hcr_lx_quiesce.signo = SIGRTMIN + 3;
    ready = leave_handler = done = 0;
    before_entry = arm == 2;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = held_handler;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    if (sigaction(repro_hcr_lx_quiesce.signo, &action, NULL) != 0) return 10;
    if (pthread_create(&thread, NULL, worker, arm == 1 ? &arm : NULL) != 0) return 11;
    while (!__atomic_load_n(&ready, __ATOMIC_ACQUIRE)) sched_yield();
    repro_hcr_lx_quiesce.slots[0].tid = worker_tid;
    repro_hcr_lx_quiesce.slot_count = 1;
    /* The deadline captured this tid before its signal arrived. Release is
     * already published, so a late handler must not wait for the patcher. */
    repro_hcr_lx_quiesce.unresponsive_tids[0] = worker_tid;
    repro_hcr_lx_quiesce.unresponsive_count = 1;
    repro_hcr_lx_quiesce.release_word = 1;
    repro_hcr_lx_nested_scan_enabled = 0;
    if (arm != 1) {
      __atomic_store_n(&ready, 0, __ATOMIC_RELEASE);
    }
    if (syscall(SYS_tgkill, getpid(), worker_tid,
                repro_hcr_lx_quiesce.signo) != 0) return 12;
    if (arm != 1) {
      while (!__atomic_load_n(&ready, __ATOMIC_ACQUIRE)) sched_yield();
    }
    if (arm == 0) {
      /* Keep a second signal pending while the first handler is self-blocked.
       * This arm then requires entry evidence, independently of SigPnd. */
      if (syscall(SYS_tgkill, getpid(), worker_tid,
                  repro_hcr_lx_quiesce.signo) != 0) return 16;
    }
    int count = repro_hcr_lx_census_unresponsive_signal_masks(
        repro_hcr_lx_quiesce.signo);
    printf("%s: blocked=%d read=%d\n",
           arm == 1 ? "blocked" : arm == 2 ? "before-entry" : "late", count,
           repro_hcr_lx_quiesce.sigmask_read_ok);
    if (arm == 1) {
      /* Drive the real timeout/refinement path as well as its census. Seed
       * prior entry evidence: begin must reset it for the new attempt. Only
       * this worker exists, and it is genuinely deaf to the handshake. */
      if (repro_hcr_lx_quiesce_install(SIGRTMIN + 3) != REPRO_HCR_LX_QUIESCE_OK)
        return 13;
      repro_hcr_lx_quiesce.slots[0].tid =
          (int32_t)repro_hcr_lx_raw_gettid();
      if (raise(SIGRTMIN + 3) != 0) return 15;
      int status = repro_hcr_lx_quiesce_begin(1000000ull);
      if (status != REPRO_HCR_LX_QUIESCE_SIGNAL_BLOCKED ||
          repro_hcr_lx_quiesce.unresponsive_count != 1 ||
          repro_hcr_lx_quiesce.sigmask_read_ok != 1 ||
          repro_hcr_lx_quiesce.blocked_count != 1)
        return 14;
      puts("begin: signal-blocked reset=1 read=1");
    }
    __atomic_store_n(&leave_handler, 1, __ATOMIC_RELEASE);
    __atomic_store_n(&done, 1, __ATOMIC_RELEASE);
    pthread_join(thread, NULL);
    if (count != (arm == 1) || repro_hcr_lx_quiesce.sigmask_read_ok != 1) return 1;
  }
  return 0;
}
