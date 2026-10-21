/* Real mmap/mprotect/munmap boundaries against the production stack walkers.
 * allowed_mocks: none. A maps snapshot is taken before permissions change,
 * deliberately making the check/use race deterministic rather than timing it.
 */
#define _GNU_SOURCE 1
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
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
  if (mode == 9) {
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
