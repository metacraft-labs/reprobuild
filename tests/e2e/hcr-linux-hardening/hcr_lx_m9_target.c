/*
 * HLX-M9 real Linux x86_64 target process — "a text page left writable must
 * reach an observer that is not a test probe".
 *
 * This process is the HLX-M0 target plus ONE thing: after the patch has been
 * applied, it reads its OWN `/proc/self/maps` and reports the permission
 * string of the mapping containing the patched entry address.
 *
 * That line is the whole point of the fixture. The agent's `textLeftWritable`
 * wire field is the agent's own bookkeeping; the permission string is the
 * KERNEL's, obtained through a file the agent never writes. A gate that
 * asserted only the wire field would be asserting the agent against itself
 * (Verification-Harness-Traps §7a: name the PRODUCER of every value a control
 * asserts). Here the two producers are different, and the gate requires them
 * to agree in BOTH arms — which is a stronger statement than either alone,
 * because the failure mode being ruled out is precisely "the flag says one
 * thing and the process is in the other state".
 *
 * Built with the real patchable profile and linking the production C agent.
 * No scaffold here can pass by returning an empty result: `after` is this
 * program's own return value and `entryPerms` is four bytes out of procfs.
 */

#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "repro_hcr_agent.h"

__attribute__((noinline, used)) int hcr_lx_m9_entry(void) { return 11; }

static int (*volatile hcr_lx_m9_call)(void) = hcr_lx_m9_entry;

/*
 * The permission field of the `/proc/self/maps` line whose range contains
 * `address`, e.g. `r-xp` or `rwxp`.
 *
 * Returns "unmapped" when no line contains the address and "unreadable" when
 * procfs could not be opened. Those are two DIFFERENT answers on purpose: a
 * single "unknown" would let a gate's assertion about the permission string be
 * satisfied by a failure to look (Verification-Harness-Traps §5 — a failure
 * sentinel that collides with a legitimate value). Neither spelling is `r-xp`
 * or `rwxp`, so both fail every assertion this gate makes.
 */
static void entry_perms(uint64_t address, char *out, size_t out_len) {
  FILE *maps;
  char line[512];
  snprintf(out, out_len, "%s", "unmapped");
  maps = fopen("/proc/self/maps", "r");
  if (maps == NULL) {
    snprintf(out, out_len, "%s", "unreadable");
    return;
  }
  while (fgets(line, (int)sizeof(line), maps) != NULL) {
    unsigned long long low = 0;
    unsigned long long high = 0;
    char perms[8];
    if (sscanf(line, "%llx-%llx %7s", &low, &high, perms) != 3) {
      continue;
    }
    if (address >= low && address < high) {
      snprintf(out, out_len, "%s", perms);
      break;
    }
  }
  fclose(maps);
}

int main(void) {
  repro_hcr_agent_symbol symbols[1];
  uint64_t entry_address = (uint64_t)(uintptr_t)hcr_lx_m9_entry;
  char perms_before[16];
  char perms_after[16];
  int before;
  int after;
  int start_rc;
  int poll_rc;

  entry_perms(entry_address, perms_before, sizeof(perms_before));
  before = hcr_lx_m9_call();

  symbols[0].name = "hcr_lx_m9_entry";
  symbols[0].address = (void *)hcr_lx_m9_entry;
  start_rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), symbols, 1);
  poll_rc = repro_hcr_agent_poll();

  entry_perms(entry_address, perms_after, sizeof(perms_after));
  /*
   * Only call into the page if it is still executable. Under the fault lever
   * the restore syscall is SKIPPED, so the page keeps whatever the transient
   * left it as — RWX on a host that permits the RW|EXEC transition, and RW on
   * one that does not. On the second kind of host this call would fault on
   * instruction fetch, and a gate reading a SIGSEGV would attribute it to the
   * patch rather than to the lever. -1 is reported instead, and the gate
   * refuses it by name: this fixture has no arm in which -1 is acceptable.
   */
  after = (strchr(perms_after, 'x') != NULL) ? hcr_lx_m9_call() : -1;

  printf(
      "{\"schemaId\":\"reprobuild.hcr.hlx-m9.text-left-writable-target.v1\","
      "\"before\":%d,\"after\":%d,"
      "\"startRc\":%d,\"pollRc\":%d,"
      "\"entryAddress\":\"0x%llx\","
      "\"entryPermsBefore\":\"%s\","
      "\"entryPermsAfter\":\"%s\","
      "\"faultLeverSet\":%s}\n",
      before, after, start_rc, poll_rc, (unsigned long long)entry_address,
      perms_before, perms_after,
      getenv("REPRO_HCR_TEST_FAIL_TEXT_RESTORE") != NULL ? "true" : "false");
  fflush(stdout);
  return 0;
}
