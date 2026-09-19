/*
 * HX-S-2 / HLX-M7 — the target of `e2e_hcr_linux_replay_of_patched_recording`.
 *
 * WHAT THIS PROGRAM IS FOR
 * ---------------------------------------------------------------------------
 * It is recorded under `ct-mcr record` while a real HCR coordinator replaces
 * one of its functions over the real agent wire, and then REPLAYED. The point
 * of the replay is that the recorded patch bundle is applied AGAIN, in the
 * replay process, by this program's own in-process HCR agent — not memcpy'd
 * out of the trace — and that the events on either side of the recorded
 * boundary reproduce the code body that produced them.
 *
 * So the program's output is deliberately TWO separate unbuffered `write(2)`
 * calls around the patch point, not one buffered `printf` at the end:
 *
 *     pre=<hxs2_compute()>     written BEFORE the agent is polled
 *     post=<hxs2_compute()>    written AFTER it
 *
 * `hxs2_compute` returns 11; the patch body returns 77. In a correct recording
 * the two lines differ, and that difference is the only observable that can
 * tell "the replay applied the bundle at the boundary" apart from "the replay
 * ran the original code and reported success" — which is the exact defect the
 * `evCodePatch` refusal exists to prevent. A gate whose pre- and post-boundary
 * observables were equal could not distinguish the two and would pass either
 * way, so the harness asserts they differ in the RECORDING before it replays
 * anything.
 *
 * THE FALSIFIER KNOB, AND WHY IT IS IN THE TARGET
 * ---------------------------------------------------------------------------
 * `HXS2_APPLY_LATE=1` moves `repro_hcr_agent_poll()` to AFTER the post-boundary
 * write. Nothing else changes: same binary, same patch, same coordinator, same
 * recorded trace. It is set only on a falsifier replay, never while recording,
 * and it is the WHEN arm the milestone requires — the bundle is applied, but
 * one boundary too late, so the post-boundary write executes the ORIGINAL body
 * and must not be allowed to pass.
 *
 * It lives in the target because the application point is the PROGRAM's, not
 * the replay worker's: on Linux the bundle is applied when the program's own
 * agent processes the coordinator's patch frame. A knob in the replay worker
 * could only move when events are HANDED OVER, which on a single-threaded
 * trace changes nothing — and a falsifier that cannot fail is worse than none.
 *
 * `allowed_mocks: none`. The agent compiled in here is the production
 * `libs/repro_hcr_agent/c/repro_hcr_agent.c`; the patch bytes come from a real
 * relocatable object built by a real compiler; the wire is the real agent
 * socket protocol driven by the production `HcrCoordinatorClient`.
 */

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "repro_hcr_agent.h"

__attribute__((noinline, used)) int hxs2_compute(void) { return 11; }

/* A volatile function pointer keeps both calls real: the compiler may neither
 * fold the second into the first nor constant-fold either. */
static int (*volatile hxs2_call)(void) = hxs2_compute;

static void emit(const char *label, int value) {
  char buf[64];
  size_t n = 0;
  int digits[8];
  int count = 0;
  int v = value;
  while (label[n] != 0 && n < sizeof(buf) - 16) {
    buf[n] = label[n];
    n++;
  }
  if (v == 0) {
    digits[count++] = 0;
  }
  if (v < 0) {
    buf[n++] = '-';
    v = -v;
  }
  while (v > 0 && count < 8) {
    digits[count++] = v % 10;
    v /= 10;
  }
  while (count > 0) {
    buf[n++] = (char)('0' + digits[--count]);
  }
  buf[n++] = '\n';
  /* Unbuffered and one call per observable, so each side of the boundary is
   * its own recorded `evOsWrite` with its own geid. A buffered `printf` would
   * flush both values in a single post-boundary write and the pre-boundary
   * observable would not exist as an event at all. */
  (void)!write(1, buf, n);
}

int main(void) {
  repro_hcr_agent_symbol symbols[1];
  const char *late = getenv("HXS2_APPLY_LATE");
  const char *twice = getenv("HXS2_POLL_TWICE");
  int apply_late = (late != NULL && late[0] == '1');
  /* HXS2_POLL_TWICE=1 makes the program accept a SECOND coordinator patch on
   * the same session, so the harness can record a trace that genuinely carries
   * TWO code-version boundaries. That trace exists for one purpose: to show
   * that the narrowed refusal still refuses a shape the implemented replay
   * path does not cover, by name. It is set only while recording that trace. */
  int poll_twice = (twice != NULL && twice[0] == '1');
  int start_rc;
  int poll_rc = -1;

  emit("pre=", hxs2_call());

  symbols[0].name = "hxs2_compute";
  symbols[0].address = (void *)hxs2_compute;
  start_rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), symbols, 1);

  if (!apply_late) {
    poll_rc = repro_hcr_agent_poll();
    if (poll_twice) {
      /* The first poll blocks for the first coordinator frame; every later one
       * drains what is already readable and returns. So a bare second poll
       * races the coordinator and usually returns having handled nothing,
       * after which this process exits and the coordinator sees EOF. Spin,
       * bounded, until the second frame has actually been handled -- and if it
       * never is, fall through with the count unchanged so the harness sees a
       * trace with one boundary and fails on THAT, rather than hanging. */
      int spins = 0;
      while (repro_hcr_agent_poll_messages_handled() < 2 &&
             repro_hcr_agent_poll_session_open() && spins < 20000) {
        poll_rc = repro_hcr_agent_poll();
        usleep(500);
        spins++;
      }
      emit("second=", hxs2_call());
    }
  }

  emit("post=", hxs2_call());

  if (apply_late) {
    poll_rc = repro_hcr_agent_poll();
    emit("late=", hxs2_call());
  }

  emit("startRc=", start_rc);
  emit("pollRc=", poll_rc);
  return 0;
}
