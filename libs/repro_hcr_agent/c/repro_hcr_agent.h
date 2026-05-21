#ifndef REPRO_HCR_AGENT_H
#define REPRO_HCR_AGENT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

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

#ifdef __cplusplus
}
#endif

#endif
