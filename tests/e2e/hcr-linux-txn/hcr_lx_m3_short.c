/*
 * A victim with a REAL sled that is REALLY too short.
 *
 * The gate compiles this translation unit with
 * `-fpatchable-function-entry=4,0`, so `hcr_lx_m3_short_victim` does appear in
 * `__patchable_function_entries` — the lookup succeeds — and the sled it names
 * is four bytes, which cannot hold an 8-byte naturally aligned publication
 * window. The refusal is therefore about the SLED rather than about its
 * absence, and it is produced by a compiler flag rather than by a lever.
 *
 * This is what a target built with a smaller patchable prefix than this
 * provider needs looks like, and design §4.3 requires it be refused rather
 * than served by stealing the instructions after the sled.
 */

__attribute__((noinline, noipa, used)) int hcr_lx_m3_short_victim(void) {
  return 55;
}
