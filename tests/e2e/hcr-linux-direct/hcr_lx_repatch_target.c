/*
 * Real Linux x86_64 target for
 * `e2e_hcr_linux_repatch_code_patch_event_reports_the_replaced_word`.
 *
 * Property under test (reprobuild-pm `spec/HCR/Linux-ELF-Provider.md` §10.3,
 * '"Before" is the word the publishing store replaced'; issue
 * `issues/2026-11-15-hcr-code-patch-event-reports-generation-0-as-the-word-a-re-patch-replaced.md`):
 * the code-patch note the agent hands the recorder carries, as its before-word
 * and before-hash, the bytes found at `windowAddress` immediately before THIS
 * event's store. For a re-patch that is generation N's jump, so at one site
 * each event's before-word equals the previous event's after-word.
 *
 * The process links the production C agent and is patched TWICE, on one open
 * session, over the real agent socket. It captures both notes by defining the
 * recorder entry point `ct_repro_hcr_agent_did_patch_v2` itself. The agent's
 * bridge header declares that symbol weak and calls it when it is bound; this
 * definition (weak too, because the header's declaration precedes it, but the
 * only definition in the link) is what the agent's reference binds to, exactly
 * as `libct_interpose`'s would under `ct-mcr record`. The gate asserts the hook
 * fired twice, so a binding that silently failed would be a loud failure.
 *
 * Evidence independent of the agent's bookkeeping: the entry bytes are dumped
 * BEFORE the first poll (the pristine window), and inside each hook call the
 * window is read straight out of live text (the word the store just wrote).
 * The harness compares the note's claims against those observations rather
 * than against anything the agent recorded about itself.
 */

#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <time.h>

#include "repro_hcr_agent.h"
#include "repro_hcr_mcr_bridge.h"

#define HCR_LX_REPATCH_DUMP_BYTES 32
#define HCR_LX_REPATCH_MAX_NOTES 4
/* An upper bound on the wait for the second patch, so a coordinator that never
 * sends it ends the run with a captured-note count the gate rejects, instead of
 * hanging the suite. */
#define HCR_LX_REPATCH_WAIT_SECONDS 60

__attribute__((noinline, used)) int hcr_lx_repatch_entry(void) { return 11; }

/* A volatile function pointer keeps every call real: the compiler may neither
 * fold one call into another nor constant-fold the result. */
static int (*volatile hcr_lx_repatch_call)(void) = hcr_lx_repatch_entry;

typedef struct captured_note {
  uint32_t struct_size;
  uint32_t note_version;
  uint32_t site_count;
  uint64_t entry_address;
  uint64_t window_address;
  uint64_t code_word_before;
  uint64_t code_word_after;
  uint32_t window_length;
  uint32_t generation;
  unsigned char code_hash_before[32];
  unsigned char code_hash_after[32];
  int has_hashes;
  /* Observations, not copies of the note. */
  uint64_t observed_window_word; /* read from live text inside the hook */
  int observed_return;           /* the function's result inside the hook */
} captured_note;

static captured_note captured[HCR_LX_REPATCH_MAX_NOTES];
static int hook_calls = 0;

int ct_repro_hcr_agent_did_patch_v2(const ct_repro_hcr_patch_note_v1 *note) {
  captured_note *slot;
  int index = hook_calls++;
  if (note == NULL || index >= HCR_LX_REPATCH_MAX_NOTES) {
    return 1;
  }
  slot = &captured[index];
  slot->struct_size = note->structSize;
  slot->note_version = note->noteVersion;
  slot->site_count = note->siteCount;
  if (note->sites != NULL && note->siteCount >= 1u) {
    const ct_repro_hcr_patch_site_v1 *site = &note->sites[0];
    slot->entry_address = site->entryAddress;
    slot->window_address = site->windowAddress;
    slot->code_word_before = site->codeWordBefore;
    slot->code_word_after = site->codeWordAfter;
    slot->window_length = site->windowLength;
    slot->generation = site->generation;
    if (site->windowAddress != 0) {
      memcpy(&slot->observed_window_word,
             (const void *)(uintptr_t)site->windowAddress,
             sizeof(slot->observed_window_word));
    }
  }
  if (note->codeHashBefore != NULL && note->codeHashAfter != NULL) {
    memcpy(slot->code_hash_before, note->codeHashBefore, 32);
    memcpy(slot->code_hash_after, note->codeHashAfter, 32);
    slot->has_hashes = 1;
  }
  /* The hook runs after the publishing store, so this is the generation the
   * note describes. */
  slot->observed_return = hcr_lx_repatch_call();
  return 1;
}

static void dump_hex(char *out, const unsigned char *bytes, size_t count) {
  static const char digits[] = "0123456789abcdef";
  size_t i;
  for (i = 0; i < count; ++i) {
    out[i * 2] = digits[(bytes[i] >> 4) & 0xf];
    out[i * 2 + 1] = digits[bytes[i] & 0xf];
  }
  out[count * 2] = '\0';
}

static void sleep_one_millisecond(void) {
  struct timespec ts;
  ts.tv_sec = 0;
  ts.tv_nsec = 1000000L;
  (void)nanosleep(&ts, NULL);
}

int main(void) {
  repro_hcr_agent_symbol symbols[1];
  unsigned char before_bytes[HCR_LX_REPATCH_DUMP_BYTES];
  char before_hex[HCR_LX_REPATCH_DUMP_BYTES * 2 + 1];
  char hash_before_hex[65];
  char hash_after_hex[65];
  uint64_t entry_address = (uint64_t)(uintptr_t)hcr_lx_repatch_entry;
  time_t deadline;
  int before;
  int after;
  int start_rc;
  int poll_rc;
  int i;
  int captured_count;

  memcpy(before_bytes, (const void *)(uintptr_t)entry_address,
         sizeof(before_bytes));
  before = hcr_lx_repatch_call();

  symbols[0].name = "hcr_lx_repatch_entry";
  symbols[0].address = (void *)hcr_lx_repatch_entry;
  start_rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), symbols, 1);
  /* The first poll handshakes and blocks for the first frame; later polls
   * drain without blocking, so the loop sleeps between them. */
  poll_rc = repro_hcr_agent_poll();
  deadline = time(NULL) + HCR_LX_REPATCH_WAIT_SECONDS;
  while (hook_calls < 2 && repro_hcr_agent_poll_session_open() &&
         time(NULL) < deadline) {
    sleep_one_millisecond();
    (void)repro_hcr_agent_poll();
  }
  after = hcr_lx_repatch_call();

  dump_hex(before_hex, before_bytes, sizeof(before_bytes));
  captured_count =
      hook_calls < HCR_LX_REPATCH_MAX_NOTES ? hook_calls
                                            : HCR_LX_REPATCH_MAX_NOTES;

  printf("{\"schemaId\":\"reprobuild.hcr.linux-repatch-note-result.v1\","
         "\"before\":%d,\"after\":%d,\"startRc\":%d,\"pollRc\":%d,"
         "\"hookCalls\":%d,\"entryAddress\":\"0x%llx\","
         "\"entryBytesBeforeHex\":\"%s\",\"notes\":[",
         before, after, start_rc, poll_rc, hook_calls,
         (unsigned long long)entry_address, before_hex);
  for (i = 0; i < captured_count; ++i) {
    const captured_note *n = &captured[i];
    dump_hex(hash_before_hex, n->code_hash_before, 32);
    dump_hex(hash_after_hex, n->code_hash_after, 32);
    /* 64-bit words are printed as hex strings: JSON numbers above 2^53 are
     * not exact in every parser. */
    printf("%s{\"structSize\":%u,\"noteVersion\":%u,\"siteCount\":%u,"
           "\"entryAddress\":\"0x%llx\",\"windowAddress\":\"0x%llx\","
           "\"codeWordBefore\":\"0x%016llx\",\"codeWordAfter\":\"0x%016llx\","
           "\"windowLength\":%u,\"generation\":%u,\"hasHashes\":%s,"
           "\"codeHashBefore\":\"%s\",\"codeHashAfter\":\"%s\","
           "\"observedWindowWord\":\"0x%016llx\",\"observedReturn\":%d}",
           i == 0 ? "" : ",", n->struct_size, n->note_version, n->site_count,
           (unsigned long long)n->entry_address,
           (unsigned long long)n->window_address,
           (unsigned long long)n->code_word_before,
           (unsigned long long)n->code_word_after, n->window_length,
           n->generation, n->has_hashes ? "true" : "false", hash_before_hex,
           hash_after_hex, (unsigned long long)n->observed_window_word,
           n->observed_return);
  }
  printf("],\"expectedStructSize\":%u}\n",
         (unsigned)sizeof(ct_repro_hcr_patch_note_v1));
  fflush(stdout);
  return 0;
}
