#include <stdint.h>

#ifndef HX_W3_DELTA
#define HX_W3_DELTA 0
#endif

volatile int32_t hx_w3_counter;
volatile uint8_t hx_w3_bytes[16];
volatile int32_t *hx_w3_pointer = &hx_w3_counter;

__declspec(noinline) int hx_w3_rel32_4(int value) {
  hx_w3_counter = 0x12345678;
  return value + hx_w3_counter + HX_W3_DELTA;
}

__declspec(noinline) uint8_t hx_w3_implicit_addend(void) {
  return hx_w3_bytes[7];
}

__declspec(noinline) uintptr_t hx_w3_addr64(void) {
  return (uintptr_t)&hx_w3_counter;
}
