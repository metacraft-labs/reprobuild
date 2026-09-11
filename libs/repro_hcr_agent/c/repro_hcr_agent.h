#ifndef REPRO_HCR_AGENT_H
#define REPRO_HCR_AGENT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Support profile ids carried on the agent wire.
 *
 * `macos-arm64-direct-hcr-in-codetracer-v1` is the pre-existing Mach-O/arm64
 * profile (M26-M28). `linux-x86_64-elf-direct-hcr-v1` is the ELF/x86_64 profile
 * introduced by HLX-M0; the two are not interchangeable and the coordinator
 * rejects a mismatch during negotiation.
 */
#define REPRO_HCR_AGENT_SUPPORT_PROFILE_MACOS_ARM64 \
  "macos-arm64-direct-hcr-in-codetracer-v1"
#define REPRO_HCR_AGENT_SUPPORT_PROFILE_LINUX_X86_64 \
  "linux-x86_64-elf-direct-hcr-v1"

typedef struct repro_hcr_agent_symbol {
  const char *name;
  void *address;
} repro_hcr_agent_symbol;

int repro_hcr_agent_start_from_env(const char *support_profile,
                                   const repro_hcr_agent_symbol *symbols,
                                   size_t symbol_count);
int repro_hcr_agent_start_polling_from_env(const char *support_profile,
                                           const repro_hcr_agent_symbol *symbols,
                                           size_t symbol_count);
int repro_hcr_agent_poll(void);

/* The compiled-in support profile for this build, or "" when the platform has
 * no direct-patch arm. */
const char *repro_hcr_agent_default_support_profile(void);

/* Host capability probe results (see design §5.2 and §4.4). Both are evaluated
 * at agent start and are stable for the life of the process. */
int repro_hcr_agent_host_supports_direct_patch(void);
int repro_hcr_agent_host_membarrier_sync_core(void);

/* HLX-M4: the real-time signal number the tier-2 quiescence handshake uses
 * (design §6.2 step 1), or 0 when this platform has no quiescence arm. An
 * embedding application needs it so it does not install its own disposition on
 * the same signal, and a gate needs it to prove the handler is installed rather
 * than assumed. */
int repro_hcr_agent_host_quiescence_signal(void);

/* HLX-M4: how the LAST publication this agent made was performed.
 * 1 = tier 1 (no quiescence; only taken when the process had exactly one
 * thread), 2 = tier 2 (every thread parked across the store). Exposed so a gate
 * can prove the agent actually took the tier its thread count demands, rather
 * than trusting that the branch exists. Returns 0 before any publication. */
int repro_hcr_agent_last_publication_tier(void);

/* HLX-M4 §6.2 step 5: how many parked threads had the last patched function on
 * their stack. -1 means NOT DETERMINED — a tier-1 publication has no parked PCs
 * to read, and a symbol with no `st_size` has no extent to test against. It is
 * deliberately distinct from 0. */
int repro_hcr_agent_last_on_stack_threads(void);

#ifdef __cplusplus
}
#endif

#endif
