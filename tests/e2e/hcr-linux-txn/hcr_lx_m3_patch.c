/*
 * The replacement bodies for the HLX-M3 gates, compiled to a REAL relocatable
 * object by the gate and extracted from their own `.text.<symbol>` sections.
 * The same discipline HLX-M0, HLX-M2 and HLX-M4 use, and for the same reason:
 * a hand-assembled literal proves nothing about what a compiler emits.
 *
 * Three bodies because the re-patch gate needs three DISTINGUISHABLE
 * generations: with two, "generation 3 rolled back to generation 2" and
 * "generation 3 rolled back to the original" are not always separable by the
 * value alone.
 */

int hcr_lx_m3_patch_body_a(void) { return 77; }

int hcr_lx_m3_patch_body_b(void) { return 99; }

int hcr_lx_m3_patch_body_c(void) { return 123; }
