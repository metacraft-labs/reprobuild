/*
 * repro_hcr_mcr_bridge.h — coexistence with MCR (HLX-M7).
 *
 * Two things happen when reprobuild's HCR agent and CodeTracer's
 * `libct_interpose` are loaded into one process, and this header is where both
 * are declared. Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §10.
 *
 * 1. ARBITRATION (§10.1). Both patchers rewrite guest `.text` in place. The
 *    recorder already funnels every write through the cross-patcher claim map
 *    `ct_inline_hook/claimed_guest_text.{c,h}`, whose rule is: *no patcher may
 *    steal a byte another patcher has already claimed; a patcher claims
 *    [start, end) BEFORE it writes, the claim is refused if it intersects a
 *    live claim, and a refusal must route to a transport that does not need
 *    the contested bytes — never to a silent skip.* This provider claims its
 *    published window before the publishing store and releases it if the
 *    publication fails.
 *
 * 2. THE `CodePatchEvent` (§10.3). The recorder is told what changed, so the
 *    recording carries the boundary between two versions of the program's own
 *    code instead of leaving a replayer to run the OLD code's semantics
 *    against the NEW code's events.
 *
 * HOW THE SYMBOLS ARE RESOLVED, AND WHY NOT `dlsym`.
 *
 * All of them are declared WEAK with default visibility. `ct-mcr record`
 * injects `libct_interpose.so` via `LD_PRELOAD`, so when a recording is in
 * progress the dynamic linker binds these references to the recorder's own
 * definitions at load time; when it is not, they resolve to NULL and every
 * call site here is skipped. That gives the provider:
 *
 *   - ONE claim map, not two. This is the load-bearing reason. If the agent
 *     compiled its own copy of `claimed_guest_text.c` into the target there
 *     would be two independent maps in one process — the recorder's and the
 *     provider's — and neither could see the other's claims, which is exactly
 *     the defect the map exists to prevent. Binding the recorder's exported
 *     symbols is what makes participation real.
 *   - no `libdl` link requirement on the arbitrary application this agent is
 *     compiled into (HLX-M0's stated constraint), and no `dlsym` call from
 *     inside a process whose libc entry points the recorder has interposed.
 *
 * A NULL claim map is NOT a silent skip. It means `libct_interpose` is not in
 * this process, so the only patcher of this text is this provider, and there is
 * no other claim a claim could conflict with. The refusal path that matters —
 * a real conflict with a real recorder claim — is reachable exactly when the
 * recorder is present, which is when the symbol is non-NULL.
 */
#ifndef REPRO_HCR_MCR_BRIDGE_H
#define REPRO_HCR_MCR_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#if defined(__linux__)

#define REPRO_HCR_WEAK __attribute__((weak, visibility("default")))

/* ---------------------------------------------------------------------------
 * §10.1 — the cross-patcher claim map, owned by codetracer-native-recorder.
 *
 * `CT_CGT_OWNER_REPRO_HCR` is 7, added to the closed owner set in
 * `ct_inline_hook/claimed_guest_text.h` by HLX-M7. It is spelled out rather
 * than included because this header must compile inside a target that has no
 * checkout of the recorder; the value is part of that header's published ABI
 * and a mismatch would only mislabel a refusal, never corrupt one.
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_CGT_OWNER_REPRO_HCR 7u

/* Returns 0 claimed, -1 degenerate, -2 REFUSED with *holder_out set. */
REPRO_HCR_WEAK int ct_claimed_guest_text_claim(uintptr_t start, size_t len,
                                               unsigned owner,
                                               unsigned *holder_out);
REPRO_HCR_WEAK void ct_claimed_guest_text_release(uintptr_t start);
REPRO_HCR_WEAK int ct_claimed_guest_text_intersects(uintptr_t start, size_t len,
                                                    unsigned *holder_out);

/* ---------------------------------------------------------------------------
 * §10.3 — the CodePatchEvent bridge.
 *
 * The hook `repro_hcr_agent.c:49-50` has always described is
 * `ct_repro_hcr_agent_did_patch(void *entry, void *dispatch_entry, size_t
 * patch_len)`. Three untyped words cannot carry §7.2's six fields, so HLX-M7
 * widens the PAYLOAD by adding a second entry point that takes a versioned
 * note. The old three-argument hook is left exactly as it was — the Apple arm
 * still calls it and HLX-M0's rule that no macOS outcome changes is preserved
 * by construction — and `repro_hcr_agent.h`, the PUBLIC agent ABI, is
 * untouched: neither hook appears in it.
 *
 * `structSize` + `noteVersion` are the compatibility guard. A recorder that
 * meets a note it does not understand refuses it by size rather than reading
 * fields at guessed offsets.
 * ------------------------------------------------------------------------- */

typedef struct ct_repro_hcr_patch_site_v1 {
  uint64_t entryAddress;     /* the patched function's entry                 */
  uint64_t sledAddress;      /* the `__patchable_function_entries` sled       */
  uint64_t windowAddress;    /* the naturally aligned 8-byte published window */
  uint64_t dispatchAddress;  /* where the published jump now goes             */
  uint64_t codeWordBefore;   /* the 8 bytes at windowAddress before the store */
  uint64_t codeWordAfter;    /* the 8 bytes at windowAddress after it         */
  uint32_t windowLength;     /* bytes this site contributes to the hashes     */
  uint32_t generation;       /* how many times THIS site has been published   */
} ct_repro_hcr_patch_site_v1;

typedef struct ct_repro_hcr_patch_note_v1 {
  uint32_t structSize;       /* sizeof(ct_repro_hcr_patch_note_v1)            */
  uint32_t noteVersion;      /* 1                                             */
  uint32_t publicationTier;  /* 1 = no quiescence (approximate geid boundary) */
  uint32_t siteCount;
  const char *patchId;             /* NUL-terminated                          */
  const char *patchedSymbols;      /* NUL-separated names, DOUBLE-NUL ended   */
  const char *supportProfile;      /* the agent's compiled-in profile         */
  const unsigned char *patchBundle;
  uint64_t patchBundleLen;
  const unsigned char *codeHashBefore;   /* 32 bytes, SHA-256                 */
  const unsigned char *codeHashAfter;    /* 32 bytes, SHA-256                 */
  const unsigned char *patchBundleHash;  /* 32 bytes, SHA-256                 */
  const ct_repro_hcr_patch_site_v1 *sites;
} ct_repro_hcr_patch_note_v1;

/* Publication tiers, design §6.1 / §6.2. Recorded in the event because under
 * tier 1 there is no global instant at which the patch takes effect for every
 * thread, so the event's geid is an APPROXIMATE boundary — a genuine semantic
 * weakening that §10.3 requires be recorded rather than hidden. */
#define REPRO_HCR_PUBLICATION_TIER_NO_QUIESCENCE 1u
#define REPRO_HCR_PUBLICATION_TIER_QUIESCED 2u

/* Returns 1 recorded, 0 not recording, negative when the note is unusable. */
REPRO_HCR_WEAK int ct_repro_hcr_agent_did_patch_v2(
    const ct_repro_hcr_patch_note_v1 *note);

#endif /* __linux__ */

#endif /* REPRO_HCR_MCR_BRIDGE_H */
