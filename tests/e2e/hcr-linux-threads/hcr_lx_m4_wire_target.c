/*
 * HLX-M4 over-the-wire target: a MULTITHREADED process patched by the real
 * agent through the real Unix-socket protocol.
 *
 * WHY THIS EXISTS SEPARATELY FROM THE IN-PROCESS FIXTURE. The in-process arms
 * drive `repro_hcr_lx_apply_direct_patch_at` directly, which is the right way
 * to run thousands of publications but says nothing about whether the AGENT
 * chooses tier 2 when it should. HLX-M0's wire gate cannot answer that either:
 * its target uses the polling agent on its only thread, so it is genuinely
 * single-threaded and correctly stays on tier 1.
 *
 * So without this file the production tier-2 branch in
 * `repro_hcr_apply_direct_patch` would be reachable only in theory — the exact
 * "the mechanism exists but nothing calls it" shape this milestone is required
 * to rule out. Here the process has a dozen worker threads hammering the victim
 * when the patch arrives, and the target REPORTS the tier the agent chose.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "repro_hcr_agent.h"

#define WORKERS 12

__attribute__((noinline, noipa, used)) int hcr_lx_m4_wire_victim(void) {
  return 11;
}

typedef struct worker {
  int tid;
  volatile uint64_t calls;
  volatile uint64_t saw_old;
  volatile uint64_t saw_new;
  volatile uint64_t anomalies;
  volatile int first_anomaly;
} worker;

static worker g_workers[WORKERS];
static volatile int g_stop = 0;

static void *worker_main(void *raw) {
  worker *w = (worker *)raw;
  w->tid = (int)syscall(SYS_gettid);
  while (!g_stop) {
    int i;
    for (i = 0; i < 256; ++i) {
      int value = hcr_lx_m4_wire_victim();
      w->calls += 1;
      if (value == 11) {
        w->saw_old += 1;
      } else if (value == 77) {
        w->saw_new += 1;
      } else {
        if (w->anomalies == 0) w->first_anomaly = value;
        w->anomalies += 1;
      }
    }
  }
  return NULL;
}

int main(void) {
  pthread_t handles[WORKERS];
  int i;
  int start_rc;
  int poll_rc;
  int before;
  int after;
  uint64_t calls = 0;
  uint64_t anomalies = 0;
  int first_anomaly = 0;
  int distinct = 0;
  int seen[WORKERS];

  before = hcr_lx_m4_wire_victim();

  for (i = 0; i < WORKERS; ++i) {
    pthread_create(&handles[i], NULL, worker_main, &g_workers[i]);
  }
  for (;;) {
    int ready = 0;
    for (i = 0; i < WORKERS; ++i) {
      if (g_workers[i].tid != 0 && g_workers[i].calls > 0) ready += 1;
    }
    if (ready == WORKERS) break;
    usleep(1000);
  }

  /* NO registered symbol table, deliberately. A registered entry carries an
   * address and nothing else, so the ELF resolver is never consulted and the
   * function's `st_size` is never learned — which leaves §6.2 step 5's on-stack
   * detection with no extent to test against and reporting "not determined".
   * Resolving through the real HLX-M1 ELF pipeline is what makes that half of
   * tier 2 reachable, and it is also what a real target does. */
  start_rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), NULL, 0);
  poll_rc = repro_hcr_agent_poll();

  /* Give threads that resumed into damaged bytes time to reach them before the
   * process is allowed to report success. */
  usleep(200000);
  g_stop = 1;
  for (i = 0; i < WORKERS; ++i) {
    pthread_join(handles[i], NULL);
  }
  after = hcr_lx_m4_wire_victim();

  memset(seen, 0, sizeof(seen));
  for (i = 0; i < WORKERS; ++i) {
    int j;
    int known = 0;
    calls += g_workers[i].calls;
    if (g_workers[i].anomalies > 0 && anomalies == 0) {
      first_anomaly = g_workers[i].first_anomaly;
    }
    anomalies += g_workers[i].anomalies;
    for (j = 0; j < distinct; ++j) {
      if (seen[j] == g_workers[i].tid) known = 1;
    }
    if (!known) seen[distinct++] = g_workers[i].tid;
  }

  printf("{\"schemaId\":\"reprobuild.hcr.hlx-m4.wire-target-result.v1\",");
  printf("\"before\":%d,\"after\":%d,", before, after);
  printf("\"startRc\":%d,\"pollRc\":%d,", start_rc, poll_rc);
  printf("\"workerCount\":%d,\"distinctWorkerTids\":%d,", WORKERS, distinct);
  printf("\"totalCalls\":%llu,", (unsigned long long)calls);
  printf("\"anomalies\":%llu,\"firstAnomaly\":%d,",
         (unsigned long long)anomalies, first_anomaly);
  printf("\"publicationTier\":%d,", repro_hcr_agent_last_publication_tier());
  printf("\"onStackThreads\":%d,", repro_hcr_agent_last_on_stack_threads());
  printf("\"quiescenceSignal\":%d,",
         repro_hcr_agent_host_quiescence_signal());
  printf("\"membarrierSyncCore\":%s,",
         repro_hcr_agent_host_membarrier_sync_core() ? "true" : "false");
  printf("\"hostSupportsDirectPatch\":%s}\n",
         repro_hcr_agent_host_supports_direct_patch() ? "true" : "false");
  fflush(stdout);
  return 0;
}
