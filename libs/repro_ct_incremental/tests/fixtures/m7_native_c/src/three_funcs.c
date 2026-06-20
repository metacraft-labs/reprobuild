/*
 * M7 native fixture for the Trace-Based-Incremental-Testing campaign.
 *
 * A tiny C program with four functions exercised by the native shallow-hash
 * (compiled-instruction-byte) path:
 *
 *   - used_a   : called by the "test path" (main). Edited by the
 *                editing_a_native_function_changes_its_instruction_hash test.
 *   - used_b   : called by the test path. A LEAF (no calls / relative
 *                branches), so its compiled bytes are position-independent and
 *                stay byte-identical even when editing used_a shifts addresses —
 *                this is what
 *                editing_one_native_function_leaves_anothers_hash_stable proves.
 *   - unused_c : defined but NOT on the test path (the "function the test did
 *                not execute"); also a leaf for byte-stability.
 *   - main     : the entry point; calls used_a and used_b.
 *
 * Built WITH symbols at test time (cc -O0 -g) into a temp dir so rebuild
 * determinism of the per-function instruction bytes is testable. The binary is
 * intentionally NOT committed.
 *
 * Functions are marked `__attribute__((noinline))` so each retains a distinct
 * symbol with its own machine code (so nativeFunctionTable can locate each
 * independently), and `used_b`/`unused_c` are kept as pure leaves so their
 * bytes do not encode any sibling's address.
 */

__attribute__((noinline)) int used_a(void) {
  return 1;
}

__attribute__((noinline)) int used_b(int x) {
  return x * 2 + 7;
}

__attribute__((noinline)) int unused_c(void) {
  return 99;
}

int main(void) {
  return used_a() + used_b(3);
}
