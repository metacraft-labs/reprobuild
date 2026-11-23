/* Real mmap/mprotect/munmap boundaries against the production stack walkers.
 * allowed_mocks: none. A maps snapshot is taken before permissions change,
 * deliberately making the check/use race deterministic rather than timing it.
 */
#define _GNU_SOURCE 1
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include "repro_hcr_linux_x86_64_probe.c"

static int stop_worker = 0;
static void *worker(void *unused) {
  (void)unused;
  while (!__atomic_load_n(&stop_worker, __ATOMIC_ACQUIRE)) {
    __asm__ volatile("pause");
  }
  return NULL;
}

static void deny_stack_reads(int error) {
  struct sock_filter rules[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 310 /* process_vm_readv */, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (unsigned)error),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)
  };
  struct sock_fprog program = {sizeof(rules) / sizeof(rules[0]), rules};
  assert(prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0);
  assert(prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) == 0);
}

/* ---- modes 10 and 11: a thread interrupted inside the sigreturn trampoline.
 *
 * The HLX-M4 gate lost 1 tier-2 run in 72 at window+3 under host load: the
 * quiescence signal reached a worker after its application handler had
 * returned into `__restore_rt` but before the `rt_sigreturn` ran. Its outer
 * frame's saved PC was inside the window, and the scan that finds outer
 * frames by their `pretcode` word starts at the stack pointer, one word above
 * the `pretcode` the handler's `ret` had just popped. Nothing adjusted it.
 *
 * In the gate that interleaving needs an interrupt between two particular
 * instructions. Here it is built deterministically with real signals: the
 * thread keeps the quiescence signal blocked, the outer handler single-steps
 * itself (EFLAGS.TF) through its `ret` into the trampoline, and the SIGTRAP
 * handler, on reaching the chosen trampoline instruction, clears TF and
 * unblocks the quiescence signal in the mask its own `sigreturn` restores, so
 * the already-pending signal is delivered exactly there. Mode 10 stops at the
 * trampoline's first instruction, mode 11 at the next one (the `syscall`). */
static int tramp_quiesce_signo;
static int tramp_stop_index;
static volatile int tramp_ready;
static volatile int tramp_done;
static volatile int tramp_hit;
static volatile int tramp_index;
static volatile int tramp_steps;
static volatile uint64_t tramp_address;
static volatile uint64_t tramp_hit_pc;
static volatile uint64_t outer_rip;
static volatile uint64_t outer_rip_slot;

static void tramp_outer_handler(int signo, siginfo_t *info, void *raw) {
  ucontext_t *uc = (ucontext_t *)raw;
  (void)signo;
  (void)info;
  outer_rip = (uint64_t)uc->uc_mcontext.gregs[REG_RIP];
  outer_rip_slot = (uint64_t)(uintptr_t)&uc->uc_mcontext.gregs[REG_RIP];
  /* Set TF clear of the red zone: every instruction from here on traps. */
  __asm__ volatile("sub $128, %%rsp\n\t"
                   "pushfq\n\t"
                   "orq $0x100, (%%rsp)\n\t"
                   "popfq\n\t"
                   "add $128, %%rsp"
                   ::: "memory", "cc");
}

static void tramp_trap_handler(int signo, siginfo_t *info, void *raw) {
  ucontext_t *uc = (ucontext_t *)raw;
  uint64_t rip = (uint64_t)uc->uc_mcontext.gregs[REG_RIP];
  /* The sigreturn trampoline every handler in this process returns through. */
  uint64_t trampoline = (uint64_t)(uintptr_t)__builtin_return_address(0);
  (void)signo;
  (void)info;
  tramp_steps += 1;
  if (tramp_steps > 100000) {
    uc->uc_mcontext.gregs[REG_EFL] &= ~(greg_t)0x100;
    tramp_hit = -1;
    return;
  }
  if (rip - trampoline < 16) {
    if (tramp_index == tramp_stop_index) {
      uc->uc_mcontext.gregs[REG_EFL] &= ~(greg_t)0x100;
      sigdelset(&uc->uc_sigmask, tramp_quiesce_signo);
      tramp_address = trampoline;
      tramp_hit_pc = rip;
      tramp_hit = 1;
    }
    tramp_index += 1;
  }
}

static void *tramp_thread(void *unused) {
  sigset_t block;
  sigset_t pending;
  (void)unused;
  sigemptyset(&block);
  sigaddset(&block, tramp_quiesce_signo);
  assert(pthread_sigmask(SIG_BLOCK, &block, NULL) == 0);
  __atomic_store_n(&tramp_ready, 1, __ATOMIC_RELEASE);
  for (;;) {
    assert(sigpending(&pending) == 0);
    if (sigismember(&pending, tramp_quiesce_signo)) break;
    sched_yield();
  }
  /* The outer frame: its saved PC is the instruction after this syscall. */
  syscall(SYS_tgkill, (long)getpid(), (long)syscall(SYS_gettid), (long)SIGUSR1);
  __atomic_store_n(&tramp_done, 1, __ATOMIC_RELEASE);
  return NULL;
}

static void run_trampoline_mode(int stop_index) {
  struct sigaction outer, trap;
  pthread_t thread;
  repro_hcr_lx_parked_thread *slot;
  uint32_t n;
  int found = 0;
  int status;
  /* The top of `main` fakes a verified trampoline for the scan-only modes;
   * this mode needs the real one, learned by the real handler. */
  repro_hcr_lx_sigreturn_trampoline = 0;
  repro_hcr_lx_trampoline_verified = 0;
  tramp_stop_index = stop_index;
  tramp_quiesce_signo = SIGRTMIN + 4;
  assert(repro_hcr_lx_quiesce_install(tramp_quiesce_signo) == 0);
  memset(&outer, 0, sizeof(outer));
  outer.sa_sigaction = tramp_outer_handler;
  outer.sa_flags = SA_SIGINFO;
  sigemptyset(&outer.sa_mask);
  assert(sigaction(SIGUSR1, &outer, NULL) == 0);
  memset(&trap, 0, sizeof(trap));
  trap.sa_sigaction = tramp_trap_handler;
  trap.sa_flags = SA_SIGINFO;
  sigemptyset(&trap.sa_mask);
  sigaddset(&trap.sa_mask, tramp_quiesce_signo);
  assert(sigaction(SIGTRAP, &trap, NULL) == 0);
  assert(pthread_create(&thread, NULL, tramp_thread, NULL) == 0);
  while (!__atomic_load_n(&tramp_ready, __ATOMIC_ACQUIRE)) sched_yield();

  status = repro_hcr_lx_quiesce_begin(2000000000ull);
  assert(status == 0);
  assert(tramp_hit == 1);
  assert(repro_hcr_lx_trampoline_verified == 1);
  assert(!repro_hcr_lx_trampoline_shape_unknown);
  assert(repro_hcr_lx_sigreturn_trampoline == tramp_address);
  assert(repro_hcr_lx_quiesce.slot_count == 1);
  slot = &repro_hcr_lx_quiesce.slots[0];
  assert(slot->parked == 1);
  /* Positive control: the thread really was parked INSIDE the trampoline, at
   * the instruction this mode chose, not in the outer handler or after it. */
  assert(slot->pc == tramp_hit_pc);
  assert(stop_index == 0 ? slot->pc == tramp_address : slot->pc > tramp_address);
  assert(slot->pc - tramp_address < repro_hcr_lx_trampoline_span);
  /* THE INVARIANT: the frame being returned from is reported, with the PC
   * its `rt_sigreturn` will restore and the address of that saved PC. */
  for (n = 0; n < slot->nested_count; ++n) {
    if (slot->nested_pc[n] == outer_rip &&
        slot->nested_pc_slot[n] == outer_rip_slot) {
      found += 1;
    }
  }
  if (found != 1) {
    fprintf(stderr, "outer frame not reported: nested_count=%u pc=0x%llx "
            "outer_rip=0x%llx\n", slot->nested_count,
            (unsigned long long)slot->pc, (unsigned long long)outer_rip);
  }
  assert(found == 1);
  assert(repro_hcr_lx_quiesce.trampoline_frames_seen == 1);
  /* And step 6 adjusts it: a window around the outer PC counts exactly one
   * adjustment, in an OUTER frame. The resume target is the PC itself, so the
   * thread still returns where it was. */
  assert(repro_hcr_lx_quiesce_adjust_window(outer_rip - 1, outer_rip + 7,
                                            outer_rip) == 1);
  assert(repro_hcr_lx_quiesce.nested_adjust_count == 1);
  assert(repro_hcr_lx_quiesce_release() == 0);
  assert(pthread_join(thread, NULL) == 0);
  assert(tramp_done == 1);
}

int main(int argc, char **argv) {
  size_t page = repro_hcr_lx_page_size();
  unsigned char *memory = mmap(NULL, page * 3, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  volatile uint64_t pcs[4] = {0}, slots[4] = {0};
  volatile uint32_t complete = 99;
  uint32_t count;
  int mode = argc > 1 ? atoi(argv[1]) : 0;
  assert(memory != MAP_FAILED);
  repro_hcr_lx_sigreturn_trampoline = 0x12345678;
  repro_hcr_lx_trampoline_verified = 1;
  assert(repro_hcr_lx_snapshot_readable_ranges() > 0);
  assert(repro_hcr_lx_readable_end_of((uint64_t)(uintptr_t)memory) >=
         (uint64_t)(uintptr_t)(memory + page * 3));
  if (mode == 10 || mode == 11) {
    run_trampoline_mode(mode - 10);
  } else if (mode == 9) {
    raise(SIGSEGV); /* Verify the harness preserves the original child fate. */
    return 2;
  } else if (mode == 7 || mode == 8) {
    pthread_t thread;
    int status;
    assert(repro_hcr_lx_quiesce_install(SIGRTMIN + 4) == 0);
    deny_stack_reads(mode == 7 ? 1 /* EPERM */ : 38 /* ENOSYS */);
    assert(pthread_create(&thread, NULL, worker, NULL) == 0);
    status = repro_hcr_lx_quiesce_begin(250000000ull);
    assert(status == 9);
    assert(strcmp(repro_hcr_lx_quiesce_status_name(status),
                  "quiescence-stack-read-unavailable") == 0);
    assert(!repro_hcr_lx_quiesce_is_held());
    assert(repro_hcr_lx_quiesce.slot_count == 1);
    assert(repro_hcr_lx_quiesce.parked_count == 1);
    assert(repro_hcr_lx_quiesce.resumed_count == 1);
    assert(repro_hcr_lx_publication_count == 0);
    __atomic_store_n(&stop_worker, 1, __ATOMIC_RELEASE);
    assert(pthread_join(thread, NULL) == 0);
  } else if (mode == 1 || mode == 2) {
    /* The stale snapshot spans the now unreadable second page. */
    if (mode == 1) assert(mprotect(memory + page, page, PROT_NONE) == 0);
    else assert(munmap(memory + page, page) == 0);
    count = repro_hcr_lx_collect_nested_frames(
        (uint64_t)(uintptr_t)(memory + page - 64), pcs, slots, 4);
    assert(count == 0);
  } else if (mode == 3 || mode == 4) {
    uint64_t fp = (uint64_t)(uintptr_t)(memory + page);
    assert(mprotect(memory + page, page, PROT_NONE) == 0);
    if (mode == 4) fp -= 8; /* saved rbp readable, saved RIP inaccessible */
    count = repro_hcr_lx_quiesce_walk_frames(
        fp, (uint64_t)(uintptr_t)memory, pcs, 4, &complete);
    assert(count == 0 && complete == 0);
  } else {
    uint64_t *base = (uint64_t *)(memory + 64);
    ucontext_t *outer = (ucontext_t *)(base + 1);
    *base = repro_hcr_lx_sigreturn_trampoline;
    outer->uc_mcontext.gregs[REG_RIP] = 0x87654321;
    if (mode == 5) {
      count = repro_hcr_lx_collect_nested_frames(
          (uint64_t)(uintptr_t)base, pcs, slots, 4);
      assert(count == 1 && pcs[0] == 0x87654321);
      assert(slots[0] == (uint64_t)(uintptr_t)&outer->uc_mcontext.gregs[REG_RIP]);
    } else if (mode == 6) {
      uint64_t *frame = (uint64_t *)(memory + page - 16);
      frame[0] = 0;
      frame[1] = 0x87654321;
      count = repro_hcr_lx_quiesce_walk_frames(
          (uint64_t)(uintptr_t)frame, (uint64_t)(uintptr_t)memory,
          pcs, 4, &complete);
      assert(count == 1 && pcs[0] == 0x87654321 && complete == 1);
    } else return 2;
  }
  puts("stack-access-ok");
  return 0;
}
