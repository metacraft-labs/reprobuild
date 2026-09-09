/*
 * Rebuilt second generation of `hcr_lx_elf_lib.c`, for the HLX-M1 build-id
 * gate (design §7.3).
 *
 * Same public surface, DIFFERENT layout: `hcr_lx_lib_static_helper` is defined
 * LAST here rather than first, so its `st_value` moves. That displacement is
 * the whole point — it is what makes an address read from the rebuilt file,
 * while the first generation is still mapped, point at the wrong function
 * rather than harmlessly at the right one.
 *
 * The build-id necessarily differs too, which is what the provider actually
 * checks; the moved `st_value` is what the gate uses to show the check
 * prevented a real error and not a hypothetical one.
 *
 * Note on why reordering rather than padding: a first attempt added two
 * `noinline` `static` padding functions ahead of the helper, and GCC removed
 * both. `noinline` stops inlining but not constant propagation, so the calls
 * folded to a constant, the functions became unreferenced statics, and dead
 * code elimination deleted them — leaving generation two byte-identical in
 * layout to generation one and the gate unable to observe anything. Reordering
 * the definitions cannot be optimised away.
 */

#include "hcr_lx_elf_fixture.h"

__attribute__((noinline, visibility("hidden"))) int hcr_lx_lib_hidden_helper(
    void) {
  return 41;
}

__attribute__((noinline)) int hcr_lx_lib_exported_helper(void) { return 42; }

/* Moved to the end, so its `st_value` differs from generation one's. */
__attribute__((noinline)) static int hcr_lx_lib_static_helper(void) {
  return 40;
}

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
