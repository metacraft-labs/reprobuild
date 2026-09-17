/*
 * HLX-M8 patch bodies, compiled as a REAL relocatable object so the gates
 * extract real compiler output rather than hand-assembled literals — the same
 * discipline as HLX-M0's and HLX-M3's fixtures.
 *
 * Two bodies, and the second one is the point:
 *
 *   hcr_lx_m8_patch_body   — an ordinary replacement returning 77. Self-
 *                            contained, no relocations, so it can be dropped
 *                            into a provider-owned page as-is.
 *   hcr_lx_m8_patch_oversize
 *                          — a body deliberately larger than one page. The
 *                            provider's in-memory link refuses it, and that
 *                            refusal is what makes `Patch-Loading-Lifecycle.md`
 *                            §3.3 step 38 reachable: a Phase F failure that
 *                            happens AFTER before-reload has already fired.
 *                            This is a real compiler outcome driven by a real
 *                            oversized function, not a test lever.
 */

int hcr_lx_m8_patch_body(void) { return 77; }

/*
 * The oversize body. `repro_hcr_lx_txn_prepare_site` refuses when
 * `endbr64 prefix + patch_len > page_size`, so this has to exceed 4096 bytes
 * of machine code on its own. A long chain of volatile accumulations is the
 * cheapest way to get there without the optimiser folding it away, and it
 * stays a valid function — the refusal must come from the provider's size
 * rule, not from the bytes being nonsense.
 */
#define HCR_M8_STEP(n) acc += (int)(sink * (n)) ^ (acc << 1);
#define HCR_M8_STEP8(n)                                                        \
  HCR_M8_STEP(n + 0) HCR_M8_STEP(n + 1) HCR_M8_STEP(n + 2) HCR_M8_STEP(n + 3)  \
  HCR_M8_STEP(n + 4) HCR_M8_STEP(n + 5) HCR_M8_STEP(n + 6) HCR_M8_STEP(n + 7)
#define HCR_M8_STEP64(n)                                                       \
  HCR_M8_STEP8(n + 0) HCR_M8_STEP8(n + 8) HCR_M8_STEP8(n + 16)                 \
  HCR_M8_STEP8(n + 24) HCR_M8_STEP8(n + 32) HCR_M8_STEP8(n + 40)               \
  HCR_M8_STEP8(n + 48) HCR_M8_STEP8(n + 56)
#define HCR_M8_STEP512(n)                                                      \
  HCR_M8_STEP64(n + 0) HCR_M8_STEP64(n + 64) HCR_M8_STEP64(n + 128)            \
  HCR_M8_STEP64(n + 192) HCR_M8_STEP64(n + 256) HCR_M8_STEP64(n + 320)         \
  HCR_M8_STEP64(n + 384) HCR_M8_STEP64(n + 448)

int hcr_lx_m8_patch_oversize(void) {
  volatile int sink = 3;
  int acc = 77;
  HCR_M8_STEP512(0)
  HCR_M8_STEP512(512)
  HCR_M8_STEP512(1024)
  HCR_M8_STEP512(1536)
  return acc == 0 ? 77 : acc;
}
