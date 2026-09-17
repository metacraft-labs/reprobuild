/*
 * A victim whose prepare-phase refusal comes from the COMPILER, not a lever.
 *
 * The gate compiles this translation unit WITHOUT
 * `-fpatchable-function-entry`, so `hcr_lx_m3_plain_victim` has no entry in
 * `__patchable_function_entries` at all and the runtime sled lookup answers 0.
 * That is `absent-sled`, and it is the commonest real refusal there is: one
 * object in a target that was not built with the patchable profile.
 *
 * `noipa` for the reason every fixture in this campaign gives: at -O2 GCC's
 * interprocedural constant propagation replaces a call to a function returning
 * a literal with the literal, and the entry is then never executed.
 */

__attribute__((noinline, noipa, used)) int hcr_lx_m3_plain_victim(void) {
  return 44;
}
