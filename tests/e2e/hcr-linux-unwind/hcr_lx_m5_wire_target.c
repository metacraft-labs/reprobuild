/*
 * HLX-M5 residue, 2026-09-18 — the target for
 * `e2e_hcr_linux_registration_payloads_travel_over_the_production_wire`.
 *
 * WHAT IS DIFFERENT ABOUT THIS TARGET, and why it had to exist.
 *
 * HLX-M5 landed `__register_frame` and the GDB JIT symfile as real
 * registrations and proved them with three gates — but all three drove the
 * provider IN PROCESS, through argv-driven fixtures that call
 * `repro_hcr_lxu_*` directly. The path production actually uses is the socket:
 * `repro watch --hcr` and `repro hcr coordinate` build a patch request with a
 * non-empty `debugObjectPayload` and `unwindMetadataPayload` and the agent
 * registers both at Phase I. No gate drove that, on any platform.
 *
 * This target is an ORDINARY APPLICATION on that path. It exports one
 * patchable function, starts the polled agent against
 * `REPRO_HCR_AGENT_SOCKET`, waits for exactly one patch, and prints what the
 * registration DID — not what the wire said. The fields that matter are the
 * last two:
 *
 *   fdeFound   `_Unwind_Find_FDE` asked about the LIVE dispatch address the
 *              patch was published at. This is the unwinder's own answer.
 *   jitFirst   `__jit_debug_descriptor.first_entry`, i.e. whether a debugger
 *              attaching now would find a symfile for the patched body.
 *
 * A gate that asserted "the payload arrived and the byte count was non-zero"
 * would pass in a world where both registrations silently did nothing, which
 * is the world HLX-M5 exists to rule out.
 *
 * The victim is `patchable_value`, matching the source the watch fixture
 * compiles, so the SAME function the coordinator inferred a patch for is the
 * one this process exports.
 *
 * No skips. Every failure path exits non-zero with a named reason.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "repro_hcr_agent.h"

#define HCR_M5W_POLL_BUDGET 60000 /* iterations, 1 ms apart -> ~60 s ceiling */

/* Defined in the project fixture's own `src/patchable.c`, compiled into this
 * binary unchanged. Declaring it here rather than copying the body is what
 * makes "the coordinator patched the function this process exports" true by
 * construction. */
int patchable_value(int iteration);

static int (*volatile hcr_m5w_call)(int) = patchable_value;

int main(void) {
  repro_hcr_agent_symbol symbols[1];
  int before_value;
  int after_value;
  int start_rc;
  int polls;
  int applied = 0;

  before_value = hcr_m5w_call(0);

  symbols[0].name = "patchable_value";
  symbols[0].address = (void *)patchable_value;
  start_rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), symbols, 1);
  if (start_rc != 0) {
    fprintf(stderr,
            "hcr_lx_m5_wire_target: repro_hcr_agent_start_polling_from_env "
            "returned %d\n",
            start_rc);
    return 3;
  }

  for (polls = 0; polls < HCR_M5W_POLL_BUDGET; ++polls) {
    (void)repro_hcr_agent_poll_nonblocking();
    if (repro_hcr_rb_last_dispatch_address() != 0) {
      applied = 1;
      break;
    }
    usleep(1000);
  }

  if (!applied) {
    fprintf(stderr,
            "hcr_lx_m5_wire_target: no patch reached Phase G within %d polls; "
            "the coordinator never delivered one over the socket\n",
            HCR_M5W_POLL_BUDGET);
    return 4;
  }

  after_value = hcr_m5w_call(0);

  printf("{\"schemaId\":"
         "\"reprobuild.hcr.hlx-m5.linux-wire-registration-result.v1\",");
  printf("\"before\":%d,\"after\":%d,\"polls\":%d,", before_value, after_value,
         polls);
  printf("\"supportProfile\":\"%s\",",
         repro_hcr_agent_default_support_profile());
  printf("\"debugObjectBytes\":%llu,",
         (unsigned long long)repro_hcr_rb_last_debug_object_bytes());
  printf("\"unwindMetadataBytes\":%llu,",
         (unsigned long long)repro_hcr_rb_last_unwind_metadata_bytes());
  printf("\"jitRegistered\":%s,",
         repro_hcr_rb_last_jit_registered() ? "true" : "false");
  printf("\"ehFrameRegistered\":%s,",
         repro_hcr_rb_last_eh_frame_registered() ? "true" : "false");
  printf("\"jitFirstEntry\":\"0x%llx\",",
         (unsigned long long)repro_hcr_rb_last_jit_first_entry());
  printf("\"jitRegisterHookCalls\":%llu,",
         (unsigned long long)repro_hcr_rb_last_jit_register_hook_calls());
  printf("\"dispatchAddress\":\"0x%llx\",",
         (unsigned long long)repro_hcr_rb_last_dispatch_address());
  printf("\"fdeFound\":%s,",
         repro_hcr_rb_last_fde_found() ? "true" : "false");
  printf("\"unwindRefusal\":\"%s\",", repro_hcr_rb_last_unwind_refusal());
  printf("\"jitRefused\":%s,",
         repro_hcr_rb_last_jit_refused() ? "true" : "false");
  printf("\"registerFrameConvention\":\"%s\",",
         repro_hcr_agent_register_frame_convention());
  printf("\"codeSwapped\":%s}\n",
         repro_hcr_rb_last_code_swapped() ? "true" : "false");
  fflush(stdout);
  return 0;
}
