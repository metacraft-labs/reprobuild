/*
 * HLX-M9 patch-body source.
 *
 * Identical in role to `hcr_lx_m0_patch.c`: the gate compiles this with a real
 * compiler into a real ELF relocatable object and extracts
 * `hcr_lx_m9_patch_body`'s bytes from its own section. Those bytes are what
 * the coordinator sends over the wire.
 *
 * It is a SEPARATE file rather than a reuse of the HLX-M0 body because this
 * gate's two arms differ only in one environment variable, and sharing a
 * fixture across milestones is how a change made for one of them silently
 * moves what the other measures.
 */

int hcr_lx_m9_patch_body(void) { return 77; }
