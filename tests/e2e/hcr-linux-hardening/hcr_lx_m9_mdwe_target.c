/*
 * HLX-M9 — the target for
 * `integration_hcr_linux_hardened_host_refuses_at_negotiation`.
 *
 * WHAT THIS FIXTURE IS FOR.
 *
 * Design §5.2 and §14: "the agent-start probe performs a complete §5.1 page
 * replacement, and a host on which neither backing completes is reported
 * unsupported at negotiation. This is proven under
 * `PR_SET_MDWE(PR_MDWE_REFUSE_EXEC_GAIN)` in three ways. A real function is
 * published through the `memfd` backing. With that backing disabled, the
 * anonymous fallback is refused before step 5 and the host is refused at
 * negotiation, naming MDWE. In both arms the target's text is still executable
 * afterwards, and no `mprotect` of target text and no `PROT_WRITE|PROT_EXEC`
 * request is ever issued."
 *
 * THE HARDENING IS A REAL KERNEL POLICY, NOT A LEVER. `--mdwe` calls
 * `prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN)` on this process before the
 * agent starts. Nothing in the provider is stubbed and no failure is
 * injected: the kernel then refuses `mprotect(PROT_READ|PROT_EXEC)` on any
 * mapping that has been writable (measured on Linux 6.12.85: `mprotect(RW)`
 * answers 0 and `mprotect(RX)` answers -EACCES). Which backing the provider
 * may use is the gate's other axis, selected by the agent's own
 * `REPRO_HCR_TEST_FORCE_ANONYMOUS_CODE_PAGES` lever, which chooses a real code
 * path and forges no outcome.
 *
 * The same binary serves every arm. One argv flag and one environment
 * variable are the only differences between them.
 *
 * THE LAST CALL IS THE ONE THAT MATTERS. After the session, the target CALLS
 * the victim again. Had anything left its text page non-executable, this call
 * would fault rather than return.
 *
 * WHAT THE PROVIDER DID TO TEXT is read against THIS executable's text range,
 * which the linker gives the fixture (`__executable_start` .. `etext`) and the
 * provider does not supply: every `mprotect` the provider issued is checked
 * for overlap with it.
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

/* GNU ld, gold, lld and mold all define these for an executable: the first
 * byte of the image and the end of its text. */
extern char __executable_start[];
extern char etext[];

/* How many of the provider's logged `mprotect`s overlapped this executable's
 * text. -1 when the log is incomplete, which the gate treats as a failure
 * rather than as zero. */
static long long hcr_m9m_mprotects_on_text(void) {
  uint64_t text_start = (uint64_t)(uintptr_t)__executable_start;
  uint64_t text_end = (uint64_t)(uintptr_t)etext;
  uint64_t count = repro_hcr_agent_mprotect_issued_count();
  uint64_t i;
  long long overlapping = 0;

  for (i = 0; i < count; ++i) {
    uint64_t address;
    uint64_t length;
    if (repro_hcr_agent_mprotect_issued_range(i, &address, &length) != 0) {
      return -1;
    }
    if (address < text_end && address + length > text_start) {
      overlapping += 1;
    }
  }
  return overlapping;
}

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

  /* Poll until the coordinator is done with us. Where the host is supported
   * a patch lands; where it is refused at negotiation the coordinator closes,
   * so this loop simply runs out. Both are expected, and the gate — not this
   * target — decides which one it asked for. */
  for (polls = 0; polls < HCR_M9M_POLL_BUDGET; ++polls) {
    (void)repro_hcr_agent_poll_nonblocking();
    if (repro_hcr_rb_last_dispatch_address() != 0) {
      break;
    }
    usleep(1000);
  }

  /* THE ACCEPTANCE CRITERION. Had anything left this text page
   * non-executable, this call would fault instead of returning. */
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
  /* Which backing completed the agent-start probe: 1 memfd, 2 anonymous,
   * 0 neither. */
  printf("\"textReplacementBacking\":%d,",
         repro_hcr_agent_host_text_replacement_backing());
  printf("\"mprotectIssued\":%llu,",
         (unsigned long long)repro_hcr_agent_mprotect_issued_count());
  printf("\"mprotectsOnText\":%lld,", hcr_m9m_mprotects_on_text());
  printf("\"wxRequestsRefused\":%llu,",
         (unsigned long long)repro_hcr_agent_wx_requests_refused());
  printf("\"textStillExecutable\":true}\n");
  fflush(stdout);
  return 0;
}
