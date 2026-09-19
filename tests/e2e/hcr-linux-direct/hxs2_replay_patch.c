/*
 * HX-S-2 patch-body source for `e2e_hcr_linux_replay_of_patched_recording`.
 *
 * The gate compiles this with a real compiler into a real ELF relocatable
 * object and extracts `hxs2_patch_body`'s bytes from its own
 * `.text.hxs2_patch_body` section. Those bytes — not a hand-assembled literal —
 * are what the coordinator sends over the wire as the direct patch payload,
 * what the agent publishes into the target, and what the recorded
 * `CodePatchEvent` embeds for the replay to apply again.
 *
 * `-fcf-protection` gives the body an `endbr64` landing pad of its own, so the
 * provider does not have to prepend one.
 */

int hxs2_patch_body(void) { return 77; }
