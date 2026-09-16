#include <stdio.h>

#include "repro_hcr_dispatch_table.h"

__declspec(dllimport) int __cdecl hax_m2_windows_original(void);

static int __cdecl hax_m2_windows_replacement(void) {
  return 42;
}

static int require(int condition, const char *message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message);
    return 0;
  }
  return 1;
}

int main(void) {
  union {
    int (__cdecl *function)(void);
    void *pointer;
  } replacement;
  uint64_t first_tx;
  uint64_t second_tx;
  void *old_target = NULL;

  replacement.function = hax_m2_windows_replacement;

  if (!require(hax_m2_windows_original() == 7, "import control returned wrong value")) {
    return 1;
  }
  first_tx = repro_hcr_dispatch_begin_transaction();
  if (!require(first_tx != 0, "transaction id is zero") ||
      !require(repro_hcr_patch_pe_iat_tx(
                   first_tx, "hax_m2_dispatch_target.exe",
                   "hax_m2_windows_original", replacement.pointer,
                   &old_target) == 0,
               "real PE IAT publication failed") ||
      !require(old_target != NULL, "publication did not report the prior target") ||
      !require(hax_m2_windows_original() == 42,
               "import did not reach the replacement") ||
      !require(repro_hcr_dispatch_rollback_log_count() == 1,
               "rollback log did not retain the publication") ||
      !require(repro_hcr_dispatch_rollback_transaction(first_tx) == 1,
               "transaction rollback did not restore one entry") ||
      !require(hax_m2_windows_original() == 7,
               "rollback did not restore the imported function")) {
    return 1;
  }

  second_tx = repro_hcr_dispatch_begin_transaction();
  if (!require(repro_hcr_patch_pe_iat_tx(
                   second_tx, "hax_m2_dispatch_target.exe",
                   "hax_m2_windows_original", replacement.pointer,
                   NULL) == 0,
               "second PE IAT publication failed") ||
      !require(repro_hcr_dispatch_commit_transaction(second_tx) == 0,
               "transaction commit failed") ||
      !require(repro_hcr_dispatch_rollback_log_count() == 0,
               "commit retained a rollback entry") ||
      !require(hax_m2_windows_original() == 42,
               "commit did not retain the replacement")) {
    return 1;
  }

  puts("PASS: real PE IAT publication, rollback, and commit");
  return 0;
}
