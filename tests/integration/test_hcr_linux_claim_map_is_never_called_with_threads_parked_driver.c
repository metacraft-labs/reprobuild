/*
 * Driver for
 * `tests/integration/test_hcr_linux_claim_map_is_never_called_with_threads_parked.sh`.
 *
 * PROPERTY PROTECTED. Between signalling the first thread and releasing the
 * last one (tier-2 quiescence), the patching thread calls nothing that may take
 * a lock a parked thread holds: not the cross-patcher claim map, not libc's
 * `mmap`/`munmap` (interposed when MCR is loaded). Claims, allocation and every
 * rollback step other than re-publishing saved words run with the threads
 * RUNNING. Design §6.2 "Deadlock hazards", §10.1, §11.2: a parked thread
 * holding such a lock cannot release it until the window closes, so taking
 * the lock inside the window deadlocks the publication.
 *
 * WHAT IS REAL. The production agent, `#include`d whole (the established
 * pattern of `test_hx_s4_reported_booleans_track_the_observation.sh`), so the
 * path under test is `repro_hcr_apply_direct_patch` — the agent's own prepare,
 * tier selection, quiescence handshake, commit and rollback — against a real
 * patchable function in this real multithreaded process.
 *
 * MOCKS, each justified:
 *   - `ct_claimed_guest_text_claim` / `_release` are defined HERE. The real
 *     claim map lives in codetracer-native-recorder, which reprobuild's gates
 *     do not link (they build `REPRO_HCR_HLX_M3_NO_CLAIM_MAP`). The bridge
 *     (`repro_hcr_mcr_bridge.h`) binds whatever definition is linked, so these
 *     are reached through the production call sites. They model exactly the
 *     property §6.2 cares about and nothing more: the map is guarded by a lock
 *     another application thread can hold (the recorder's map has no lock
 *     today, §10.1 gap 1, and the lock `HLX-M7` adds is that lock).
 *   - `mmap` / `munmap` are interposed only to COUNT calls made while
 *     quiescence is held; each forwards to the raw system call unchanged.
 *
 * ARMS (argv[1]); each prints one line `RESULT <arm> ...` and exits 0, or
 * prints `FAIL <arm>: <reason>` and exits non-zero:
 *
 *   publish          The worker thread holds the claim-map lock when the
 *                    publication starts, and keeps it for HOLD_MS. A claim
 *                    taken with the worker parked never returns: the watchdog
 *                    fires and names it.
 *   commit-failure   The commit's first replacement page is made to fail
 *                    (`repro_hcr_lx_commit_fault_site`). The worker takes the
 *                    lock right after the claim, so it is parked HOLDING it;
 *                    the rollback's claim release must wait until release.
 *   prepare-failure  The body page allocation is made to fail after the claim
 *                    (`repro_hcr_lx_fail_patch_page_alloc`); same handshake.
 *   quiescence-failure
 *                    The worker blocks the quiescence signal, so quiescence
 *                    cannot be acquired after a SUCCESSFUL prepare; same
 *                    handshake, held longer than the quiescence timeout. The
 *                    prepared claim and body must be discarded once
 *                    `repro_hcr_lx_quiesce_begin` has released the threads
 *                    it parked, and the claim release must still meet the
 *                    worker's lock (it waits for a RUNNING thread).
 */

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include "libs/repro_hcr_agent/c/repro_hcr_agent.c"

#define HOLD_MS 300
/* Longer than the 250 ms default quiescence timeout (design §6.3), so the
 * worker still holds the lock when the refused publication discards. */
#define HOLD_MS_PAST_QUIESCE_TIMEOUT 1500
#define WATCHDOG_S 5
#define HANDOFF_WAIT_MS 1000

__attribute__((noinline, noipa, used)) int hcr_claim_victim(void) { return 7; }

static const char *arm = "?";

/* ---- observations ------------------------------------------------------- */
static volatile int claim_calls = 0;
static volatile int release_calls = 0;
static volatile int claim_calls_parked = 0;
static volatile int release_calls_parked = 0;
static volatile int libc_map_calls_parked = 0;
static volatile int release_contended = 0;
static volatile int claim_contended = 0;

/* ---- the lock behind the claim map ------------------------------------- */
static pthread_mutex_t map_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int handoff_after_claim = 0;
static volatile int worker_go = 0;
static volatile int worker_holds = 0;
static volatile int worker_stop = 0;
static int worker_hold_ms = HOLD_MS;
static int worker_blocks_quiesce_signal = 0;

static uint64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static void nap_us(long us) {
  struct timespec ts = {0, us * 1000L};
  nanosleep(&ts, NULL);
}

int ct_claimed_guest_text_claim(uintptr_t start, size_t len, unsigned owner,
                                unsigned *holder_out) {
  (void)start; (void)len; (void)owner; (void)holder_out;
  if (repro_hcr_lx_quiesce_is_held()) {
    claim_calls_parked += 1;
  }
  if (pthread_mutex_trylock(&map_lock) != 0) {
    claim_contended = 1;
    pthread_mutex_lock(&map_lock);
  }
  claim_calls += 1;
  pthread_mutex_unlock(&map_lock);
  if (handoff_after_claim) {
    /* Let the worker take the lock now, and wait until it has, so it is
     * holding the lock when the provider goes on to quiesce. Bounded: if the
     * worker is parked (the defect) it never will. */
    uint64_t until = now_ms() + HANDOFF_WAIT_MS;
    __atomic_store_n(&worker_go, 1, __ATOMIC_SEQ_CST);
    while (!__atomic_load_n(&worker_holds, __ATOMIC_SEQ_CST) &&
           now_ms() < until) {
      nap_us(100);
    }
  }
  return 0;
}

void ct_claimed_guest_text_release(uintptr_t start) {
  (void)start;
  if (repro_hcr_lx_quiesce_is_held()) {
    release_calls_parked += 1;
  }
  if (pthread_mutex_trylock(&map_lock) != 0) {
    release_contended = 1;
    pthread_mutex_lock(&map_lock);
  }
  release_calls += 1;
  pthread_mutex_unlock(&map_lock);
}

/* ---- libc mapping calls, counted while threads are parked --------------- */
void *mmap(void *addr, size_t length, int prot, int flags, int fd,
           off_t offset) {
  if (repro_hcr_lx_quiesce_is_held()) {
    libc_map_calls_parked += 1;
  }
  long rc = syscall(SYS_mmap, addr, length, prot, flags, fd, offset);
  return rc == -1 ? MAP_FAILED : (void *)rc;
}

int munmap(void *addr, size_t length) {
  if (repro_hcr_lx_quiesce_is_held()) {
    libc_map_calls_parked += 1;
  }
  return (int)syscall(SYS_munmap, addr, length);
}

/* ---- the application thread that holds the lock ------------------------- */
static void *worker_main(void *unused) {
  (void)unused;
  if (worker_blocks_quiesce_signal) {
    /* A real application thread that masks the provider's signal: §6.3's
     * "cannot quiesce" case, reached without any lever in the provider. */
    sigset_t blocked;
    sigemptyset(&blocked);
    sigaddset(&blocked, repro_hcr_lx_quiesce.signo);
    pthread_sigmask(SIG_BLOCK, &blocked, NULL);
  }
  while (!__atomic_load_n(&worker_stop, __ATOMIC_SEQ_CST)) {
    if (!__atomic_load_n(&worker_go, __ATOMIC_SEQ_CST)) {
      nap_us(100);
      continue;
    }
    pthread_mutex_lock(&map_lock);
    __atomic_store_n(&worker_holds, 1, __ATOMIC_SEQ_CST);
    {
      uint64_t until = now_ms() + (uint64_t)worker_hold_ms;
      while (now_ms() < until) {
        nap_us(1000);
      }
    }
    __atomic_store_n(&worker_go, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&worker_holds, 0, __ATOMIC_SEQ_CST);
    pthread_mutex_unlock(&map_lock);
  }
  return NULL;
}

static void on_watchdog(int signo) {
  static const char prefix[] = "FAIL ";
  static const char reason[] =
      ": the publication did not return within the watchdog: the patching "
      "thread is blocked on the claim-map lock, which a PARKED thread holds "
      "(design §6.2 \"Deadlock hazards\")\n";
  (void)signo;
  (void)!write(2, prefix, sizeof(prefix) - 1);
  (void)!write(2, arm, strlen(arm));
  (void)!write(2, reason, sizeof(reason) - 1);
  _exit(3);
}

#define CHECK(cond, ...)                                     \
  do {                                                       \
    if (!(cond)) {                                           \
      fprintf(stderr, "FAIL %s: ", arm);                     \
      fprintf(stderr, __VA_ARGS__);                          \
      fprintf(stderr, "\n");                                 \
      failures += 1;                                         \
    }                                                        \
  } while (0)

int main(int argc, char **argv) {
  static const uint8_t body[] = {0xb8, 0x2a, 0x00, 0x00, 0x00, 0xc3};
  pthread_t worker;
  void *dispatch;
  int failures = 0;
  int victim_after;

  if (argc != 2) {
    fprintf(stderr,
            "usage: %s publish|commit-failure|prepare-failure|"
            "quiescence-failure\n",
            argv[0]);
    return 2;
  }
  arm = argv[1];
  if (strcmp(arm, "publish") != 0 && strcmp(arm, "commit-failure") != 0 &&
      strcmp(arm, "prepare-failure") != 0 &&
      strcmp(arm, "quiescence-failure") != 0) {
    fprintf(stderr, "unknown arm %s\n", arm);
    return 2;
  }

  (void)repro_hcr_lx_capability_report();
  if (repro_hcr_lx_quiesce_install(0) != 0 || !repro_hcr_lx_quiesce.installed) {
    fprintf(stderr, "FAIL %s: setup: the quiescence handler did not install\n",
            arm);
    return 4;
  }
  if (hcr_claim_victim() != 7) {
    fprintf(stderr, "FAIL %s: setup: victim is not pristine\n", arm);
    return 4;
  }
  if (strcmp(arm, "quiescence-failure") == 0) {
    worker_blocks_quiesce_signal = 1;
    worker_hold_ms = HOLD_MS_PAST_QUIESCE_TIMEOUT;
  }
  if (pthread_create(&worker, NULL, worker_main, NULL) != 0) {
    fprintf(stderr, "FAIL %s: setup: pthread_create\n", arm);
    return 4;
  }

  if (strcmp(arm, "publish") == 0) {
    __atomic_store_n(&worker_go, 1, __ATOMIC_SEQ_CST);
    while (!__atomic_load_n(&worker_holds, __ATOMIC_SEQ_CST)) {
      nap_us(100);
    }
  } else {
    handoff_after_claim = 1;
    if (strcmp(arm, "commit-failure") == 0) {
      repro_hcr_lx_commit_fault_site = 0;
    } else if (strcmp(arm, "prepare-failure") == 0) {
      repro_hcr_lx_fail_patch_page_alloc = 1;
    }
  }

  signal(SIGALRM, on_watchdog);
  alarm(WATCHDOG_S);
  dispatch = repro_hcr_apply_direct_patch((void *)hcr_claim_victim, body,
                                          sizeof(body));
  alarm(0);
  victim_after = hcr_claim_victim();

  __atomic_store_n(&worker_stop, 1, __ATOMIC_SEQ_CST);
  pthread_join(worker, NULL);

  /* The adversarial premise must have held, or nothing below means anything:
   * the worker was holding the lock while the provider worked. */
  if (strcmp(arm, "publish") == 0) {
    CHECK(claim_contended, "premise: the claim never met the worker's lock");
    CHECK(dispatch != NULL, "publication refused: %s",
          repro_hcr_lx_refusal_name(repro_hcr_lx_last_report.refusal));
    CHECK(victim_after == 42, "victim returns %d after publication, want 42",
          victim_after);
    CHECK(claim_calls == 1 && release_calls == 0,
          "claim/release calls %d/%d, want 1/0", claim_calls, release_calls);
  } else {
    CHECK(release_contended,
          "premise: the claim release never met the worker's lock");
    CHECK(dispatch == NULL, "the forced failure did not refuse");
    CHECK(victim_after == 7, "victim returns %d after the refusal, want 7",
          victim_after);
    CHECK(claim_calls == 1 && release_calls == 1,
          "claim/release calls %d/%d, want 1/1 (a claim leaked or was never "
          "taken)",
          claim_calls, release_calls);
  }
  if (strcmp(arm, "quiescence-failure") == 0) {
    CHECK(repro_hcr_lx_last_report.refusal ==
              REPRO_HCR_LX_REFUSED_QUIESCENCE_FAILED,
          "refusal %s, want quiescence-failed",
          repro_hcr_lx_refusal_name(repro_hcr_lx_last_report.refusal));
    CHECK(repro_hcr_lx_last_txn.freed_body_count == 1,
          "%d prepared body page(s) freed, want 1 (the body leaked)",
          repro_hcr_lx_last_txn.freed_body_count);
  }
  CHECK(repro_hcr_lx_last_publication_tier == REPRO_HCR_PUBLICATION_TIER_QUIESCED ||
            strcmp(arm, "prepare-failure") == 0 ||
            strcmp(arm, "quiescence-failure") == 0,
        "publication tier %u, want 2 (the process has two threads)",
        repro_hcr_lx_last_publication_tier);
  CHECK(claim_calls_parked == 0,
        "%d claim-map claim call(s) made with every other thread parked",
        claim_calls_parked);
  CHECK(release_calls_parked == 0,
        "%d claim-map release call(s) made with every other thread parked",
        release_calls_parked);
  CHECK(libc_map_calls_parked == 0,
        "%d libc mmap/munmap call(s) made with every other thread parked",
        libc_map_calls_parked);

  printf("RESULT %s dispatch=%s victim=%d claims=%d releases=%d "
         "claim_contended=%d release_contended=%d parked_claims=%d "
         "parked_releases=%d parked_libc_maps=%d tier=%u refusal=%s\n",
         arm, dispatch != NULL ? "live" : "null", victim_after, claim_calls,
         release_calls, claim_contended, release_contended, claim_calls_parked,
         release_calls_parked, libc_map_calls_parked,
         repro_hcr_lx_last_publication_tier,
         repro_hcr_lx_refusal_name(repro_hcr_lx_last_report.refusal));
  return failures == 0 ? 0 : 1;
}
