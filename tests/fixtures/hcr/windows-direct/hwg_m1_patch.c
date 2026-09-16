/*
 * HWG-M1 real MSVC COFF patch body. The volatile stack local forces compiler-
 * owned x64 unwind metadata while keeping the selected function relocation-
 * free, which is the first supported Windows direct-patch surface.
 */
#ifndef HWG_M1_BIAS
#define HWG_M1_BIAS 70
#endif

__declspec(noinline) int hwg_m1_replacement(int value) {
  volatile int frame[16];
  frame[0] = HWG_M1_BIAS;
  frame[15] = value;
  return frame[15] + frame[0];
}
