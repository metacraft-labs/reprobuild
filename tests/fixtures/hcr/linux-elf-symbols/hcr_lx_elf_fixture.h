#ifndef HCR_LX_ELF_FIXTURE_H
#define HCR_LX_ELF_FIXTURE_H

#include <stdint.h>

/* Shared object half. `which`: 0 = static, 1 = hidden, 2 = exported. */
int hcr_lx_lib_hidden_helper(void);
int hcr_lx_lib_exported_helper(void);
int hcr_lx_lib_sum(void);
unsigned long long hcr_lx_lib_address_of(int which);

/* Ambiguity fixture: two translation units, one `static` name (design §7.4). */
int hcr_lx_alpha_call(void);
int hcr_lx_beta_call(void);
unsigned long long hcr_lx_alpha_helper_address(void);
unsigned long long hcr_lx_beta_helper_address(void);

#endif /* HCR_LX_ELF_FIXTURE_H */
