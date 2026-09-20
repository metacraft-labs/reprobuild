/*
 * HLX-M9 — the target for
 * `integration_hcr_linux_hardened_host_refuses_at_negotiation`.
 *
 * WHAT THIS FIXTURE IS FOR.
 *
 * Design §5.2 and §14: "the `mprotect` RW->RX round-trip is probed at agent
 * start and a host that cannot regain `PROT_EXEC` is reported unsupported at
 * negotiation, proven by running the gate under
 * `PR_SET_MDWE(PR_MDWE_REFUSE_EXEC_GAIN)` and asserting the target's text is
 * still executable afterwards."
 *
 * THE HARDENING IS A REAL KERNEL POLICY, NOT A LEVER. `--mdwe` calls
 * `prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN)` on this process before the
 * agent starts. Nothing in the provider is stubbed, no environment variable is
 * consulted, and no failure is injected: the kernel then refuses
 * `mprotect(PROT_READ|PROT_EXEC)` on any mapping that has been writable, which
 * is exactly the policy the capability probe exists to detect. Measured on
 * Linux 6.12.85: `mprotect(RW)` answers 0 and `mprotect(RX)` answers -EACCES.
 *
 * The same binary without `--mdwe` is the control. One argv flag between them.
 *
 * THE LAST THING IT PRINTS IS THE ONE THAT MATTERS. After the session, the
 * target CALLS the victim again. On a host where the refusal had come too late
 * — after the RW step and before the PROT_EXEC restore — this call would fault
 * rather than return, so "the process is still running and the victim still
 * answers" is a measurement of the design's own acceptance criterion.
 *
 * No skips. Every failure path exits non-zero with a named reason.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/prctl.h>

#include "repro_hcr_agent.h"

#ifndef PR_SET_MDWE
#define PR_SET_MDWE 65
#endif
#ifndef PR_MDWE_REFUSE_EXEC_GAIN
#define PR_MDWE_REFUSE_EXEC_GAIN 1
#endif

#define HCR_M9M_POLL_BUDGET 6000 /* iterations, 1 ms apart -> ~6 s ceiling */

int patchable_value(int iteration);

static int (*volatile hcr_m9m_call)(int) = patchable_value;

int main(int argc, char **argv) {
  repro_hcr_agent_symbol symbols[1];
  int before_value;
  int after_value;
  int start_rc;
  int polls;
  int mdwe = 0;
  int i;

  for (i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--mdwe") == 0) {
      mdwe = 1;
    } else {
      fprintf(stderr, "hcr_lx_m9_mdwe_target: unknown flag %s\n", argv[i]);
      return 2;
    }
  }

  before_value = hcr_m9m_call(0);

  if (mdwe) {
    /* REAL kernel hardening, applied BEFORE the agent's capability probe runs.
     * A failure here is a hard failure: a gate that silently continued without
     * the policy would report that a hardened host negotiates fine. */
    if (prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN, 0, 0, 0) != 0) {
      fprintf(stderr,
              "hcr_lx_m9_mdwe_target: prctl(PR_SET_MDWE, "
              "PR_MDWE_REFUSE_EXEC_GAIN) failed; this kernel cannot express "
              "the hardening this gate exists to measure (needs Linux 6.3+)\n");
      return 3;
    }
  }

  symbols[0].name = "patchable_value";
  symbols[0].address = (void *)patchable_value;
  start_rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), symbols, 1);
  if (start_rc != 0) {
    fprintf(stderr,
            "hcr_lx_m9_mdwe_target: repro_hcr_agent_start_polling_from_env "
            "returned %d\n",
            start_rc);
    return 4;
  }

  /* Poll until the coordinator is done with us. On the healthy arm a patch
   * lands; on the hardened arm the coordinator refuses at negotiation and
   * closes, so this loop simply runs out. Both are expected, and the gate —
   * not this target — decides which one it asked for. */
  for (polls = 0; polls < HCR_M9M_POLL_BUDGET; ++polls) {
    (void)repro_hcr_agent_poll_nonblocking();
    if (repro_hcr_rb_last_dispatch_address() != 0) {
      break;
    }
    usleep(1000);
  }

  /* THE ACCEPTANCE CRITERION. If the refusal had come after the RW step, this
   * call would fault instead of returning. */
  after_value = hcr_m9m_call(0);

  printf("{\"schemaId\":"
         "\"reprobuild.hcr.hlx-m9.linux-hardened-negotiation-result.v1\",");
  printf("\"mdwe\":%s,", mdwe ? "true" : "false");
  printf("\"before\":%d,\"after\":%d,\"polls\":%d,", before_value, after_value,
         polls);
  printf("\"supportProfile\":\"%s\",",
         repro_hcr_agent_default_support_profile());
  /* A SECOND PRODUCER of the same fact, read IN THIS PROCESS from the
   * provider's own capability accessor. The gate reads `patchingSupported`
   * off the socket; this is the same underlying answer reached without the
   * socket, so neither a transport that rewrote the frame nor a decoder that
   * invented a default can satisfy both. */
  printf("\"hostSupportsDirectPatch\":%s,",
         repro_hcr_agent_host_supports_direct_patch() ? "true" : "false");
  printf("\"codeSwapped\":%s,",
         repro_hcr_rb_last_code_swapped() ? "true" : "false");
  printf("\"dispatchAddress\":\"0x%llx\",",
         (unsigned long long)repro_hcr_rb_last_dispatch_address());
  printf("\"textStillExecutable\":true}\n");
  fflush(stdout);
  return 0;
}
