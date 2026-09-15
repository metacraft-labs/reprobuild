/*
 * HLX-M2 real shared library, `dlopen`ed by `hcr_lx_m2_so_target.c`.
 *
 * This is the demo's shape in miniature. `codetracer-flame-demo`'s FlameField
 * is a GDExtension — a `.so` the engine `dlopen`s — so the function the Home
 * demo's H2 beat patches does not live in the main executable at all. Before
 * this milestone such a function RESOLVED (HLX-M1's symbol pipeline spans
 * shared objects) and then refused `absent-sled`, because sled discovery read
 * `__start___patchable_function_entries`, which names one image: the one the
 * agent was linked into.
 *
 * Built with the real patchable profile from `repro_project_dsl`, so its own
 * `__patchable_function_entries` section is real compiler output.
 *
 * `hcr_lx_m2_so_sled_table` exports THIS OBJECT's own linker-synthesised
 * section bounds. That is the gate's independent witness: the provider is not
 * asked where it found the sled, the library says where its own table is and
 * the harness checks the provider's answer lands inside it — and outside the
 * executable's, which the target reports separately.
 */

#include <stddef.h>
#include <stdint.h>

extern const uintptr_t __start___patchable_function_entries[]
    __attribute__((weak));
extern const uintptr_t __stop___patchable_function_entries[]
    __attribute__((weak));

__attribute__((noinline, used, visibility("default"))) int
hcr_lx_m2_so_entry(void) {
  return 11;
}

/* A volatile function pointer keeps both calls real: the compiler may not fold
 * the second into the first, nor constant-fold either. */
static int (*volatile hcr_lx_m2_so_call_ptr)(void) = hcr_lx_m2_so_entry;

__attribute__((visibility("default"))) int hcr_lx_m2_so_call(void) {
  return hcr_lx_m2_so_call_ptr();
}

__attribute__((visibility("default"))) void *hcr_lx_m2_so_entry_address(void) {
  return (void *)hcr_lx_m2_so_entry;
}

/*
 * This library's OWN `__patchable_function_entries` bounds, as its own linker
 * synthesised them. Reported so the harness can assert the sled the provider
 * chose came from HERE.
 */
__attribute__((visibility("default"))) void hcr_lx_m2_so_sled_table(
    unsigned long long *start, unsigned long long *stop,
    unsigned long long *count) {
  const uintptr_t *first = __start___patchable_function_entries;
  const uintptr_t *last = __stop___patchable_function_entries;
  *start = (unsigned long long)(uintptr_t)first;
  *stop = (unsigned long long)(uintptr_t)last;
  *count = (first != NULL && last != NULL && last > first)
               ? (unsigned long long)(last - first)
               : 0ull;
}
