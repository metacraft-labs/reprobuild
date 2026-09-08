/*
 * HLX-M0 patch-body source.
 *
 * The gate compiles this with a real compiler into a real ELF relocatable
 * object and extracts `hcr_lx_m0_patch_body`'s bytes from its own
 * `.text.hcr_lx_m0_patch_body` section. Those bytes — not a hand-assembled
 * literal — are what the coordinator sends over the wire as the direct patch
 * payload.
 *
 * `-fcf-protection` gives the body an `endbr64` landing pad of its own, so the
 * provider does not have to prepend one; the gate asserts both facts.
 */

int hcr_lx_m0_patch_body(void) { return 77; }
