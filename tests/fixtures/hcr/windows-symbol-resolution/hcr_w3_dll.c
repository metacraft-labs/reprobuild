#include <stdint.h>

static __declspec(noinline) int hx_w3_dll_private(int value) {
  return value + 23;
}

__declspec(dllexport) uintptr_t hx_w3_dll_ground_truth(void) {
  return (uintptr_t)&hx_w3_dll_private;
}

__declspec(dllexport) int hx_w3_dll_call_private(int value) {
  return hx_w3_dll_private(value);
}
