/*
 * Shared-library half of the HLX-M1 ELF symbol-resolution fixture.
 *
 * Real shared object, linked into the probe normally (no `dlopen`, no `dlsym`
 * — design §14 requires the positive path to be free of both). It contributes
 * the three visibility classes a resolver has to tell apart, in an object
 * whose `dlpi_addr` is a NON-ZERO load bias, which is the case the main
 * executable cannot exercise when it is built `-no-pie`.
 *
 * Each function also has an address-reporting accessor, so the gate compares
 * the resolver's answer against the address THIS PROCESS reports for the same
 * function rather than against anything the gate itself computed.
 */

#include "hcr_lx_elf_fixture.h"

/* `static`: not in `.dynsym` at all, so `dlsym` cannot see it. */
__attribute__((noinline)) static int hcr_lx_lib_static_helper(void) {
  return 40;
}

/* hidden visibility: in `.symtab`, excluded from `.dynsym`. */
__attribute__((noinline, visibility("hidden"))) int hcr_lx_lib_hidden_helper(
    void) {
  return 41;
}

/* ordinary exported: the only one of the three `dlsym` could resolve. */
__attribute__((noinline)) int hcr_lx_lib_exported_helper(void) { return 42; }

int hcr_lx_lib_sum(void) {
  return hcr_lx_lib_static_helper() + hcr_lx_lib_hidden_helper() +
         hcr_lx_lib_exported_helper();
}

unsigned long long hcr_lx_lib_address_of(int which) {
  switch (which) {
    case 0:
      return (unsigned long long)(uintptr_t)&hcr_lx_lib_static_helper;
    case 1:
      return (unsigned long long)(uintptr_t)&hcr_lx_lib_hidden_helper;
    case 2:
      return (unsigned long long)(uintptr_t)&hcr_lx_lib_exported_helper;
    default:
      return 0;
  }
}
