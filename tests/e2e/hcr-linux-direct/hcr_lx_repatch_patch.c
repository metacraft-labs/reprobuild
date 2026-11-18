/*
 * Patch-body sources for
 * `e2e_hcr_linux_repatch_code_patch_event_reports_the_replaced_word`.
 *
 * Two bodies, one per generation, so the two publications are distinguishable
 * by the function's own return value as well as by their bytes. The gate
 * compiles this with a real compiler into a real ELF relocatable object
 * (`-ffunction-sections`) and extracts each body from its own
 * `.text.<name>` section, exactly as the HLX-M0 gate does for its one body.
 */

int hcr_lx_repatch_body_gen1(void) { return 77; }

int hcr_lx_repatch_body_gen2(void) { return 99; }
