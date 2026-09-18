/*
 * HLX-M8 real Linux x86_64 target process for the rb_hcr_* application ABI.
 *
 * This is an APPLICATION, not a harness: it uses only the surface an embedding
 * program has — the ten `rb_hcr_*` functions of HCR-Overview §13, plus the
 * agent's start/poll entry points. It registers real `{.cdecl.}`-shaped C
 * callbacks, opts into synchronized mode (Patch-Loading-Lifecycle.md §3.4),
 * drives `rb_hcr_apply_reload()` from its own thread the way a frame loop
 * would, and prints what it OBSERVED — never what the agent claims.
 *
 * The observation that matters, and the reason the callbacks do more than
 * increment a counter: each one calls the victim function and dumps the
 * victim's entry bytes. Under the normative phase order
 * (`Patch-Loading-Lifecycle.md` §3.1) the before-reload callback runs at
 * Phase E, where nothing is loaded and no prologue is overwritten, so it MUST
 * see the old body and the old bytes; the after-reload callback runs at
 * Phase H, after Phase G's publishing store, so it MUST see the new ones. A
 * gate that only counted callbacks would pass under either ordering — that is
 * precisely the defect that made the first version of IsoNim's stub agent
 * wrong, and it is what this evidence exists to make impossible.
 *
 * No skips. A missing patch, a timeout or an unresolvable victim exits
 * non-zero with a named reason; nothing here can report success by returning
 * early.
 *
 * argv: any number of `--managed=<TypeName>` flags, applied before the agent
 * starts. That single flag is the whole difference between the accepted and
 * the rejected arm of the managed-type gate.
 */

#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "repro_hcr_agent.h"

#define HCR_M8_DUMP_BYTES 32
#define HCR_M8_POLL_BUDGET 20000 /* iterations; 1 ms apart -> ~20 s ceiling */

/* The file paths the coordinator puts in `changedFiles`, and one it never
 * does. `rb_hcr_file_changed` must answer true for the first and false for the
 * second — and false for BOTH when the reload was not applied. */
static const char *kProbeChangedFile = "hcr_lx_m8_views.nim";
static const char *kProbeAbsentFile = "hcr_lx_m8_never_in_any_patch.nim";
static const char *kProbeManagedType = "HcrM8State";

__attribute__((noinline, used)) int hcr_lx_m8_victim(void) { return 11; }

/* A volatile function pointer keeps every call real: the compiler may neither
 * fold two calls into one nor constant-fold either of them. */
static int (*volatile hcr_lx_m8_call)(void) = hcr_lx_m8_victim;

typedef struct {
  int fired;
  int victim_value;
  char entry_hex[HCR_M8_DUMP_BYTES * 2 + 1];
  uint32_t changed_files_count;
  uint32_t changed_types_count;
  char first_file[128];
  char first_type[128];
  uint32_t first_type_old_size;
  uint32_t first_type_new_size;
  int file_changed_probe;
  int file_changed_absent;
  int type_changed_probe;
} hcr_m8_observation;

static hcr_m8_observation hcr_m8_before_observed;
static hcr_m8_observation hcr_m8_after_observed;
static void *hcr_m8_before_user_data_seen = NULL;
static void *hcr_m8_after_user_data_seen = NULL;

static void dump_hex(char *out, const unsigned char *bytes, size_t count) {
  static const char digits[] = "0123456789abcdef";
  size_t i;
  for (i = 0; i < count; ++i) {
    out[i * 2] = digits[(bytes[i] >> 4) & 0xf];
    out[i * 2 + 1] = digits[bytes[i] & 0xf];
  }
  out[count * 2] = '\0';
}

/* The provider's named refusals embed the object path and sometimes quote the
 * symbol, so they cannot be pasted into a JSON document raw. Escaping here
 * rather than sanitising the message keeps the gate asserting on the REAL
 * diagnostic text. */
static void print_json_escaped(const char *value) {
  const unsigned char *p = (const unsigned char *)value;
  for (; *p != '\0'; ++p) {
    switch (*p) {
    case '"': fputs("\\\"", stdout); break;
    case '\\': fputs("\\\\", stdout); break;
    case '\n': fputs("\\n", stdout); break;
    case '\r': fputs("\\r", stdout); break;
    case '\t': fputs("\\t", stdout); break;
    default:
      if (*p < 0x20) {
        printf("\\u%04x", (unsigned)*p);
      } else {
        fputc((int)*p, stdout);
      }
    }
  }
}

static void print_json_field(const char *name, const char *value) {
  printf("\"%s\":\"", name);
  print_json_escaped(value);
  printf("\",");
}

static void observe(hcr_m8_observation *out, const RbHcrReloadInfo *info) {
  unsigned char bytes[HCR_M8_DUMP_BYTES];
  out->fired += 1;
  /* The victim is CALLED, not inspected: "which body is live" is a question
   * about execution, and the bytes below are the independent second witness
   * rather than the only one. */
  out->victim_value = hcr_lx_m8_call();
  memcpy(bytes, (const void *)(uintptr_t)hcr_lx_m8_victim, sizeof(bytes));
  dump_hex(out->entry_hex, bytes, sizeof(bytes));
  if (info != NULL) {
    out->changed_files_count = info->changed_files_count;
    out->changed_types_count = info->changed_types_count;
    if (info->changed_files_count > 0 && info->changed_files != NULL &&
        info->changed_files[0] != NULL) {
      snprintf(out->first_file, sizeof(out->first_file), "%s",
               info->changed_files[0]);
    }
    if (info->changed_types_count > 0 && info->changed_types != NULL &&
        info->changed_types[0].type_name != NULL) {
      snprintf(out->first_type, sizeof(out->first_type), "%s",
               info->changed_types[0].type_name);
      out->first_type_old_size = info->changed_types[0].old_size;
      out->first_type_new_size = info->changed_types[0].new_size;
    }
  }
  /* §13.6's own usage example calls these INSIDE a before-reload callback, so
   * the introspection window has to be open by Phase E. */
  out->file_changed_probe = rb_hcr_file_changed(kProbeChangedFile) ? 1 : 0;
  out->file_changed_absent = rb_hcr_file_changed(kProbeAbsentFile) ? 1 : 0;
  out->type_changed_probe = rb_hcr_type_changed(kProbeManagedType) ? 1 : 0;
}

static void hcr_m8_before_reload(const RbHcrReloadInfo *info, void *user_data) {
  hcr_m8_before_user_data_seen = user_data;
  observe(&hcr_m8_before_observed, info);
}

static void hcr_m8_after_reload(const RbHcrReloadInfo *info, void *user_data) {
  hcr_m8_after_user_data_seen = user_data;
  observe(&hcr_m8_after_observed, info);
}

static void print_observation(const char *name,
                              const hcr_m8_observation *observed) {
  printf("\"%s\":{\"fired\":%d,\"victim\":%d,\"entryHex\":\"%s\","
         "\"changedFilesCount\":%u,\"changedTypesCount\":%u,"
         "\"firstFile\":\"%s\",\"firstType\":\"%s\","
         "\"firstTypeOldSize\":%u,\"firstTypeNewSize\":%u,"
         "\"fileChangedProbe\":%s,\"fileChangedAbsent\":%s,"
         "\"typeChangedProbe\":%s}",
         name, observed->fired, observed->victim_value, observed->entry_hex,
         (unsigned)observed->changed_files_count,
         (unsigned)observed->changed_types_count, observed->first_file,
         observed->first_type, (unsigned)observed->first_type_old_size,
         (unsigned)observed->first_type_new_size,
         observed->file_changed_probe ? "true" : "false",
         observed->file_changed_absent ? "true" : "false",
         observed->type_changed_probe ? "true" : "false");
}

int main(int argc, char **argv) {
  repro_hcr_agent_symbol symbols[1];
  unsigned char before_bytes[HCR_M8_DUMP_BYTES];
  unsigned char after_bytes[HCR_M8_DUMP_BYTES];
  char before_hex[HCR_M8_DUMP_BYTES * 2 + 1];
  char after_hex[HCR_M8_DUMP_BYTES * 2 + 1];
  uint64_t entry_address = (uint64_t)(uintptr_t)hcr_lx_m8_victim;
  int before_value;
  int after_value;
  int start_rc;
  int wants_before_apply = 0;
  int wants_after_apply = 1;
  int polls = 0;
  int timed_out = 1;
  int i;

  /* Managed-type registration, before anything else can happen. The agent
   * stores the POINTER (§13.2 and the shipped registry), so these must be
   * string literals or otherwise outlive the process's reloads — argv storage
   * qualifies, and using it rather than a copy is deliberate: it exercises the
   * same aliasing an embedding application will have. */
  for (i = 1; i < argc; ++i) {
    if (strncmp(argv[i], "--managed=", 10) == 0) {
      rb_hcr_register_managed_type(argv[i] + 10);
    }
  }

  /* §3.4: synchronized mode. Every phase, including both callback sets, then
   * runs on THIS thread inside rb_hcr_apply_reload(). */
  repro_hcr_agent_set_synchronized_mode(1);

  rb_hcr_before_reload(hcr_m8_before_reload, (void *)0x8100);
  rb_hcr_after_reload(hcr_m8_after_reload, (void *)0x8200);
  /* Registration is idempotent on (callback, user_data): the repeats below
   * must not produce a second dispatch, which the `fired` counters prove. */
  rb_hcr_before_reload(hcr_m8_before_reload, (void *)0x8100);
  rb_hcr_after_reload(hcr_m8_after_reload, (void *)0x8200);
  /* Registered and then removed: a callback that is not registered at Phase E
   * must not fire, and this is the only way to tell "removal works" from
   * "nothing ever fires". */
  rb_hcr_before_reload(hcr_m8_before_reload, (void *)0x8300);
  rb_hcr_remove_before_reload(hcr_m8_before_reload, (void *)0x8300);

  memcpy(before_bytes, (const void *)(uintptr_t)entry_address,
         sizeof(before_bytes));
  before_value = hcr_lx_m8_call();

  symbols[0].name = "hcr_lx_m8_victim";
  symbols[0].address = (void *)hcr_lx_m8_victim;
  start_rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), symbols, 1);

  for (polls = 0; polls < HCR_M8_POLL_BUDGET; ++polls) {
    (void)repro_hcr_agent_poll_nonblocking();
    if (rb_hcr_wants_reload()) {
      wants_before_apply = 1;
      rb_hcr_apply_reload();
      wants_after_apply = rb_hcr_wants_reload() ? 1 : 0;
      timed_out = 0;
      break;
    }
    usleep(1000);
  }

  if (timed_out) {
    /* A LOUD failure. The alternative — printing a result object with zero
     * callbacks and exiting 0 — is the silent self-pass this campaign keeps
     * finding, and it would read as "the gate ran and nothing fired". */
    fprintf(stderr,
            "hcr_lx_m8_target: no patch became pending within %d polls; "
            "the agent never parked a request\n",
            HCR_M8_POLL_BUDGET);
    return 3;
  }

  memcpy(after_bytes, (const void *)(uintptr_t)entry_address,
         sizeof(after_bytes));
  after_value = hcr_lx_m8_call();

  dump_hex(before_hex, before_bytes, sizeof(before_bytes));
  dump_hex(after_hex, after_bytes, sizeof(after_bytes));

  printf("{\"schemaId\":"
         "\"reprobuild.hcr.hlx-m8.linux-rb-hcr-target-result.v1\",");
  printf("\"before\":%d,\"after\":%d,", before_value, after_value);
  printf("\"startRc\":%d,\"polls\":%d,", start_rc, polls);
  printf("\"supportProfile\":\"%s\",",
         repro_hcr_agent_default_support_profile());
  printf("\"synchronizedMode\":%s,",
         repro_hcr_agent_synchronized_mode() ? "true" : "false");
  printf("\"wantsReloadBeforeApply\":%s,",
         wants_before_apply ? "true" : "false");
  printf("\"wantsReloadAfterApply\":%s,", wants_after_apply ? "true" : "false");
  printf("\"applyReloadCalls\":%lu,", repro_hcr_rb_apply_reload_calls());
  print_json_field("lifecycleTrace", repro_hcr_rb_lifecycle_trace());
  printf("\"agentBeforeFired\":%d,\"agentAfterFired\":%d,",
         repro_hcr_rb_last_before_callbacks_fired(),
         repro_hcr_rb_last_after_callbacks_fired());
  printf("\"codeSwapped\":%s,",
         repro_hcr_rb_last_code_swapped() ? "true" : "false");
  print_json_field("rejection", repro_hcr_rb_last_rejection());
  print_json_field("unmanagedTypes", repro_hcr_rb_last_unmanaged_types());
  printf("\"beforeUserData\":\"0x%llx\",\"afterUserData\":\"0x%llx\",",
         (unsigned long long)(uintptr_t)hcr_m8_before_user_data_seen,
         (unsigned long long)(uintptr_t)hcr_m8_after_user_data_seen);
  printf("\"fileChangedProbeAtEnd\":%s,",
         rb_hcr_file_changed(kProbeChangedFile) ? "true" : "false");
  printf("\"fileChangedAbsentAtEnd\":%s,",
         rb_hcr_file_changed(kProbeAbsentFile) ? "true" : "false");
  printf("\"typeChangedProbeAtEnd\":%s,",
         rb_hcr_type_changed(kProbeManagedType) ? "true" : "false");
  printf("\"entryAddress\":\"0x%llx\",",
         (unsigned long long)entry_address);
  printf("\"entryBytesBeforeHex\":\"%s\",", before_hex);
  printf("\"entryBytesAfterHex\":\"%s\",", after_hex);
  print_observation("observedInBefore", &hcr_m8_before_observed);
  printf(",");
  print_observation("observedInAfter", &hcr_m8_after_observed);
  printf("}\n");
  fflush(stdout);
  return 0;
}
