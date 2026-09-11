/*
 * The two replacement bodies, compiled to a real relocatable object by the
 * gate. Their bytes are extracted from `.text.<symbol>` and handed to the
 * fixture as hex — the same discipline HLX-M0's gate uses, and for the same
 * reason: a hand-assembled literal proves nothing about what a compiler emits.
 *
 * Two bodies rather than one because the experiment RE-PATCHES thousands of
 * times (design §4.5). Alternating between them means a worker that observes a
 * value can be attributed to a specific generation, and it means the re-patch
 * branch of the provider is the one under load rather than the first-patch
 * branch.
 */

int hcr_lx_m4_patch_body_a(void) { return 77; }

int hcr_lx_m4_patch_body_b(void) { return 99; }
