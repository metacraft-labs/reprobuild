#include <intrin.h>
#include <windows.h>

__declspec(noinline) static int hx_w6_patch_leaf(int value) {
  volatile int patched_value = value + 600;
  __debugbreak(); /* HX_W6_PATCH_SOURCE_LINE */
  return patched_value;
}

__declspec(noinline) static int hx_w6_patch_middle(int value) {
  volatile int child = hx_w6_patch_leaf(value);
  return child + 20;
}

__declspec(dllexport) __declspec(noinline) int hx_w6_patch_entry(int value) {
  volatile int child = hx_w6_patch_middle(value);
#ifdef HX_W6_MISMATCH_BUILD
  return child + 1001;
#else
  return child + 1;
#endif
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
  (void)instance;
  (void)reason;
  (void)reserved;
  return TRUE;
}
