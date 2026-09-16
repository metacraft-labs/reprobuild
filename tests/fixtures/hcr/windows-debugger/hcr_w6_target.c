#include <intrin.h>
#include <stdio.h>
#include <windows.h>

typedef int(__cdecl *hx_w6_patch_fn)(int);

__declspec(noinline) static int hx_w6_unpatched_control(int value) {
  volatile int control_value = value + 70;
  __debugbreak(); /* HX_W6_CONTROL_SOURCE_LINE */
  return control_value;
}

__declspec(noinline) static int hx_w6_target_caller_two(
    hx_w6_patch_fn patch, int value) {
  volatile int child = patch(value);
  return child + 200;
}

__declspec(noinline) static int hx_w6_target_caller_one(
    hx_w6_patch_fn patch, int value) {
  volatile int child = hx_w6_target_caller_two(patch, value);
  return child + 300;
}

int wmain(int argc, wchar_t **argv) {
  if (!IsDebuggerPresent()) {
    fwprintf(stderr, L"HX-W-6 target requires a real attached debugger\n");
    return 10;
  }

  if (argc == 2 && wcscmp(argv[1], L"--control") == 0) {
    return hx_w6_unpatched_control(1) == 71 ? 0 : 11;
  }

  if (argc != 2) {
    fwprintf(stderr, L"usage: hcr_w6_target PATCH_DLL|--control\n");
    return 12;
  }

  HMODULE module = LoadLibraryW(argv[1]);
  if (module == NULL) {
    fwprintf(stderr, L"LoadLibraryW failed: %lu\n", GetLastError());
    return 13;
  }

  hx_w6_patch_fn patch =
      (hx_w6_patch_fn)(void *)GetProcAddress(module, "hx_w6_patch_entry");
  if (patch == NULL) {
    fwprintf(stderr, L"GetProcAddress failed: %lu\n", GetLastError());
    return 14;
  }

  return hx_w6_target_caller_one(patch, 1) == 1122 ? 0 : 15;
}
