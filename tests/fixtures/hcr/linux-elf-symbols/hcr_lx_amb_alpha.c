/*
 * First of two translation units that each define a `static` function called
 * `hcr_lx_ambiguous_helper` — design §7.4's collision, built for real rather
 * than described.
 *
 * The address accessor is what lets the gate say which definition it MEANT,
 * without the gate itself having to compute an address.
 */

#include "hcr_lx_elf_fixture.h"

__attribute__((noinline)) static int hcr_lx_ambiguous_helper(void) {
  return 101;
}

int hcr_lx_alpha_call(void) { return hcr_lx_ambiguous_helper(); }

unsigned long long hcr_lx_alpha_helper_address(void) {
  return (unsigned long long)(uintptr_t)&hcr_lx_ambiguous_helper;
}
