/*
 * HLX-M8 residue, 2026-09-18 — the THREADED synchronized-mode target.
 *
 * Every other HLX-M8 target drives the agent with
 * `repro_hcr_agent_start_polling_from_env` and services it by calling
 * `repro_hcr_agent_poll_nonblocking()` from `main`. That is one of the two
 * shapes `Patch-Loading-Lifecycle.md` §3.4 allows, and it is the one where the
 * agent and the application are the SAME thread, so "the coordinator waits for
 * the application" is not really a claim about anything.
 *
 * This target is the other shape, and it is the one the milestone's residue
 * names as ungated: the agent runs on its OWN detached thread
 * (`repro_hcr_agent_start_from_env`), synchronized mode is on, and the patch is
 * parked by a thread that is not the one that will apply it. Three things are
 * only true in this shape:
 *
 *   1. `rb_hcr_pending` is written by the agent thread and consumed by the
 *      application thread. The handoff is cross-thread.
 *   2. The coordinator is BLOCKED on the wire for as long as the application
 *      takes to call `rb_hcr_apply_reload()` — §3.4 step 41, "Phase E blocks
 *      until rb_hcr_apply_reload() is called". This target parks deliberately,
 *      for a delay it prints, so the gate can measure that the coordinator's
 *      round trip is at least that long. A gate that only checked the patch
 *      arrived would pass in a world where the agent applied it immediately.
 *   3. OTHER THREADS ARE RUNNING across the publication. Worker threads call
 *      the victim in a loop and record whether they observed the old body, the
 *      new body, or both. "Both" is what proves the swap happened underneath
 *      live threads rather than in a quiesced process with nothing to park.
 *
 * ARMS. One binary, one argv flag apart:
 *   (default)    synchronized: wants_reload becomes true, the application
 *                applies after `--park-ms`, the coordinator waits.
 *   --automatic  synchronized mode OFF: the agent thread runs the whole
 *                lifecycle itself, `rb_hcr_wants_reload()` never answers true,
 *                and the coordinator's round trip does NOT include the park
 *                delay. Same binary, same threads, opposite outcome.
 *
 * No skips. Every failure path exits non-zero with a named reason; there is no
 * way for this program to print a result object it did not earn.
 */

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "repro_hcr_agent.h"

#define HCR_M8T_DUMP_BYTES 32
#define HCR_M8T_WORKERS 4
#define HCR_M8T_WAIT_BUDGET_MS 20000

static const char *kProbeChangedFile = "hcr_lx_m8_views.nim";

__attribute__((noinline, used)) int hcr_lx_m8_victim(void) { return 11; }

static int (*volatile hcr_lx_m8_call)(void) = hcr_lx_m8_victim;

/* Workers stop when this flips. `volatile` rather than an atomic because the
 * only thing it carries is a one-way stop signal, and the loads below are the
 * evidence rather than the synchronisation. */
static volatile int hcr_m8t_stop = 0;

typedef struct {
  unsigned long calls;
  int saw_old;
  int saw_new;
  int saw_other;
  int last_value;
} hcr_m8t_worker;

static hcr_m8t_worker hcr_m8t_workers[HCR_M8T_WORKERS];

static void *hcr_m8t_worker_main(void *arg) {
  hcr_m8t_worker *self = (hcr_m8t_worker *)arg;
  while (!hcr_m8t_stop) {
    int value = hcr_lx_m8_call();
    self->calls++;
    self->last_value = value;
    if (value == 11) {
      self->saw_old = 1;
    } else if (value == 77) {
      self->saw_new = 1;
    } else {
      self->saw_other = 1;
    }
    /* A short sleep, not a tight spin. HLX-M4's publication parks threads with
     * a signal and REFUSES a site whose body a parked thread is executing; a
     * worker spinning with no pause spends a measurable fraction of its time
     * inside a two-instruction victim and would make this gate's outcome a
     * coin flip on thread scheduling rather than a statement about the
     * lifecycle. The threads are still genuinely running and still genuinely
     * calling the patched function across the swap, which is the claim. */
    usleep(200);
  }
  return NULL;
}

static uint64_t hcr_m8t_now_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
    return 0;
  }
  return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)(ts.tv_nsec / 1000000ll);
}

typedef struct {
  int fired;
  int victim_value;
  int worker_calls_at_entry;
} hcr_m8t_observation;

static hcr_m8t_observation hcr_m8t_before_observed;
static hcr_m8t_observation hcr_m8t_after_observed;
static pthread_t hcr_m8t_before_thread;
static pthread_t hcr_m8t_after_thread;

static unsigned long hcr_m8t_total_worker_calls(void) {
  unsigned long total = 0;
  int i;
  for (i = 0; i < HCR_M8T_WORKERS; ++i) {
    total += hcr_m8t_workers[i].calls;
  }
  return total;
}

static void hcr_m8t_observe(hcr_m8t_observation *out) {
  out->fired += 1;
  out->victim_value = hcr_lx_m8_call();
  out->worker_calls_at_entry = (int)(hcr_m8t_total_worker_calls() & 0x7fffffff);
}

static void hcr_m8t_before(const RbHcrReloadInfo *info, void *user_data) {
  (void)info;
  (void)user_data;
  hcr_m8t_before_thread = pthread_self();
  hcr_m8t_observe(&hcr_m8t_before_observed);
}

static void hcr_m8t_after(const RbHcrReloadInfo *info, void *user_data) {
  (void)info;
  (void)user_data;
  hcr_m8t_after_thread = pthread_self();
  hcr_m8t_observe(&hcr_m8t_after_observed);
}

int main(int argc, char **argv) {
  repro_hcr_agent_symbol symbols[1];
  pthread_t workers[HCR_M8T_WORKERS];
  int automatic = 0;
  long park_ms = 400;
  int i;
  int start_rc;
  int wants_seen = 0;
  uint64_t wait_started;
  uint64_t wants_observed_at = 0;
  uint64_t applied_at = 0;
  int worker_saw_old = 0;
  int worker_saw_new = 0;
  int worker_saw_other = 0;
  unsigned long worker_calls_total;
  pthread_t main_thread = pthread_self();

  for (i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--automatic") == 0) {
      automatic = 1;
    } else if (strncmp(argv[i], "--park-ms=", 10) == 0) {
      park_ms = strtol(argv[i] + 10, NULL, 10);
    } else {
      fprintf(stderr, "hcr_lx_m8_threaded_target: unknown flag %s\n", argv[i]);
      return 2;
    }
  }

  rb_hcr_before_reload(hcr_m8t_before, (void *)0x9100);
  rb_hcr_after_reload(hcr_m8t_after, (void *)0x9200);

  /* §3.4. The DEFAULT is automatic; this is set explicitly on both arms so the
   * difference between them is one call and not one omission. */
  repro_hcr_agent_set_synchronized_mode(automatic ? 0 : 1);

  for (i = 0; i < HCR_M8T_WORKERS; ++i) {
    if (pthread_create(&workers[i], NULL, hcr_m8t_worker_main,
                       &hcr_m8t_workers[i]) != 0) {
      fprintf(stderr, "hcr_lx_m8_threaded_target: pthread_create failed: %s\n",
              strerror(errno));
      return 3;
    }
  }
  /* Let every worker get at least one call in before the agent can possibly
   * park a patch, so "saw_old" is a measurement and not a race. */
  usleep(20000);
  for (i = 0; i < HCR_M8T_WORKERS; ++i) {
    if (hcr_m8t_workers[i].calls == 0) {
      fprintf(stderr,
              "hcr_lx_m8_threaded_target: worker %d never ran; the "
              "concurrency this target exists to exercise is not present\n",
              i);
      return 4;
    }
  }

  symbols[0].name = "hcr_lx_m8_victim";
  symbols[0].address = (void *)hcr_lx_m8_victim;
  /* THE THREADED AGENT. This is the entry point no HLX-M8 gate used. */
  start_rc = repro_hcr_agent_start_from_env(
      repro_hcr_agent_default_support_profile(), symbols, 1);
  if (start_rc != 0) {
    fprintf(stderr,
            "hcr_lx_m8_threaded_target: repro_hcr_agent_start_from_env "
            "returned %d\n",
            start_rc);
    return 5;
  }

  wait_started = hcr_m8t_now_ms();
  if (automatic) {
    /* Nothing will ever be parked. Wait for the agent thread to have run the
     * lifecycle itself, observed through the trace the lifecycle writes. */
    while (hcr_m8t_now_ms() - wait_started < (uint64_t)HCR_M8T_WAIT_BUDGET_MS) {
      if (repro_hcr_rb_last_after_callbacks_fired() > 0) {
        break;
      }
      if (rb_hcr_wants_reload()) {
        wants_seen = 1;
        break;
      }
      usleep(1000);
    }
    applied_at = hcr_m8t_now_ms();
    if (repro_hcr_rb_last_after_callbacks_fired() == 0) {
      fprintf(stderr,
              "hcr_lx_m8_threaded_target: automatic arm saw no lifecycle "
              "within %d ms\n",
              HCR_M8T_WAIT_BUDGET_MS);
      return 6;
    }
  } else {
    while (hcr_m8t_now_ms() - wait_started < (uint64_t)HCR_M8T_WAIT_BUDGET_MS) {
      if (rb_hcr_wants_reload()) {
        wants_seen = 1;
        break;
      }
      usleep(1000);
    }
    if (!wants_seen) {
      fprintf(stderr,
              "hcr_lx_m8_threaded_target: no patch was parked within %d ms; "
              "the threaded agent never handed one to the application\n",
              HCR_M8T_WAIT_BUDGET_MS);
      return 7;
    }
    wants_observed_at = hcr_m8t_now_ms();
    /* THE PARK. The coordinator is blocked on the wire for all of this, and
     * the gate measures it from the other side. */
    if (park_ms > 0) {
      usleep((useconds_t)(park_ms * 1000));
    }
    rb_hcr_apply_reload();
    applied_at = hcr_m8t_now_ms();
  }

  /* Give the workers a moment past the swap so "saw_new" is not decided by
   * whichever worker happened to be scheduled first. */
  usleep(50000);
  hcr_m8t_stop = 1;
  for (i = 0; i < HCR_M8T_WORKERS; ++i) {
    (void)pthread_join(workers[i], NULL);
  }

  worker_calls_total = hcr_m8t_total_worker_calls();
  for (i = 0; i < HCR_M8T_WORKERS; ++i) {
    worker_saw_old += hcr_m8t_workers[i].saw_old ? 1 : 0;
    worker_saw_new += hcr_m8t_workers[i].saw_new ? 1 : 0;
    worker_saw_other += hcr_m8t_workers[i].saw_other ? 1 : 0;
  }

  printf("{\"schemaId\":"
         "\"reprobuild.hcr.hlx-m8.linux-threaded-sync-target-result.v1\",");
  printf("\"automatic\":%s,", automatic ? "true" : "false");
  printf("\"parkMs\":%ld,", park_ms);
  printf("\"synchronizedMode\":%s,",
         repro_hcr_agent_synchronized_mode() ? "true" : "false");
  printf("\"wantsReloadObserved\":%s,", wants_seen ? "true" : "false");
  printf("\"wantsReloadAfterApply\":%s,",
         rb_hcr_wants_reload() ? "true" : "false");
  printf("\"applyReloadCalls\":%lu,", repro_hcr_rb_apply_reload_calls());
  printf("\"observedParkMs\":%llu,",
         (unsigned long long)(wants_observed_at == 0
                                  ? 0ull
                                  : applied_at - wants_observed_at));
  printf("\"lifecycleTrace\":\"%s\",", repro_hcr_rb_lifecycle_trace());
  printf("\"agentBeforeFired\":%d,\"agentAfterFired\":%d,",
         repro_hcr_rb_last_before_callbacks_fired(),
         repro_hcr_rb_last_after_callbacks_fired());
  printf("\"codeSwapped\":%s,",
         repro_hcr_rb_last_code_swapped() ? "true" : "false");
  printf("\"fileChangedAtEnd\":%s,",
         rb_hcr_file_changed(kProbeChangedFile) ? "true" : "false");
  printf("\"victimAtEnd\":%d,", hcr_lx_m8_call());
  printf("\"workerCount\":%d,", HCR_M8T_WORKERS);
  printf("\"workerCalls\":%lu,", worker_calls_total);
  printf("\"workersThatSawOld\":%d,", worker_saw_old);
  printf("\"workersThatSawNew\":%d,", worker_saw_new);
  printf("\"workersThatSawOther\":%d,", worker_saw_other);
  /* WHICH THREAD RAN THE CALLBACKS. In synchronized mode both must run on the
   * thread that called `rb_hcr_apply_reload()` — this one. In automatic mode
   * both run on the agent's detached thread, which is the hazard §3.4 exists
   * to let an application avoid, and the two arms disagree here by
   * construction. */
  printf("\"beforeRanOnMainThread\":%s,",
         pthread_equal(hcr_m8t_before_thread, main_thread) ? "true" : "false");
  printf("\"afterRanOnMainThread\":%s,",
         pthread_equal(hcr_m8t_after_thread, main_thread) ? "true" : "false");
  printf("\"beforeVictim\":%d,\"afterVictim\":%d,",
         hcr_m8t_before_observed.victim_value,
         hcr_m8t_after_observed.victim_value);
  printf("\"beforeFired\":%d,\"afterFired\":%d}\n",
         hcr_m8t_before_observed.fired, hcr_m8t_after_observed.fired);
  fflush(stdout);
  return 0;
}
