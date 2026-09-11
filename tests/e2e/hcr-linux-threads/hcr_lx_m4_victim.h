/*
 * The victim function, isolated in its own header so every fixture in this
 * directory patches the SAME shape.
 *
 * `noipa` matters and `noinline` alone is not enough: at `-O2` GCC's
 * interprocedural constant propagation will happily replace a call to a
 * function that returns a literal with the literal itself, at which point the
 * worker loop never executes the entry sled and the whole experiment measures
 * nothing. `noipa` disables IPA for this function entirely, so every call is a
 * real `call` through the entry — which is what the publication is about.
 */

#ifndef HCR_LX_M4_VICTIM_H
#define HCR_LX_M4_VICTIM_H

#define HCR_LX_M4_OLD_VALUE 11
#define HCR_LX_M4_NEW_VALUE_A 77
#define HCR_LX_M4_NEW_VALUE_B 99

__attribute__((noinline, noipa, used)) int hcr_lx_m4_victim(void) {
  return HCR_LX_M4_OLD_VALUE;
}

#endif
