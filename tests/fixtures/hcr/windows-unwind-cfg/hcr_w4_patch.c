#include <stdint.h>

typedef void (__cdecl *hx_w4_callback)(void);

__declspec(noinline) int hx_w4_patch(hx_w4_callback callback, int value) {
  volatile uint64_t frame[8];
  frame[0] = (uint64_t)(value + 31);
  frame[7] = frame[0] ^ 0x55aa55aaU;
  callback();
  return (int)(frame[0] + frame[7]);
}

__declspec(noinline) int hx_w4_patch_second(hx_w4_callback callback, int value) {
  volatile uint64_t frame[4];
  frame[0] = (uint64_t)(value + 47);
  frame[3] = frame[0] ^ 0xaa55aa55U;
  callback();
  return (int)(frame[0] + frame[3]);
}
