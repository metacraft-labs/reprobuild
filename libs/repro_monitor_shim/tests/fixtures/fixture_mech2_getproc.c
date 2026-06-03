/* M73 Phase 2 — dispatch-mechanism 2: LoadLibrary + GetProcAddress.
 *
 * The fixture resolves CreateFileW at runtime through
 * LoadLibraryW("kernel32") + GetProcAddress("CreateFileW") and caches
 * the function pointer in a static. Every call site jumps through the
 * cached pointer:
 *
 *     pCreateFileW(path, ...);
 *
 * No IAT entry for CreateFileW exists in this binary's PE imports
 * (kernel32 is linked, but only the dlopen-style entry points are
 * imported by name). Pre-M73 the monitor shim's IAT-only install
 * missed this mechanism entirely. Post-M73 the inline detour at the
 * kernel32 function body catches it the same as the IAT-routed case.
 *
 * Invocation: fixture_mech2_getproc.exe <marker> <count>
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

typedef HANDLE (WINAPI *CreateFileWPtr)(LPCWSTR, DWORD, DWORD,
                                        LPSECURITY_ATTRIBUTES, DWORD,
                                        DWORD, HANDLE);

int wmain(int argc, wchar_t **argv) {
  if (argc != 3) {
    fwprintf(stderr, L"usage: %s <marker> <count>\n", argv[0]);
    return 2;
  }
  const wchar_t *marker = argv[1];
  int count = _wtoi(argv[2]);
  if (count <= 0) {
    fwprintf(stderr, L"count must be > 0\n");
    return 2;
  }
  /* Resolve kernel32!CreateFileW through GetProcAddress so the call
   * goes through the cached function pointer, NOT this binary's IAT.
   * LoadLibraryW / GetProcAddress themselves may also be hooked by the
   * shim's IAT patches, but that's irrelevant — we use them only to
   * fetch the raw kernel32 entry-point address, then call through it
   * directly. The hook fires (or doesn't) based on whether the shim
   * installed an inline detour at the kernel32 function body. */
  HMODULE hKernel32 = LoadLibraryW(L"kernel32.dll");
  if (hKernel32 == NULL) {
    fwprintf(stderr, L"LoadLibraryW(kernel32) failed (err=%lu)\n",
             (unsigned long)GetLastError());
    return 1;
  }
  CreateFileWPtr pCreateFileW =
      (CreateFileWPtr)(void *)GetProcAddress(hKernel32, "CreateFileW");
  if (pCreateFileW == NULL) {
    fwprintf(stderr, L"GetProcAddress(CreateFileW) failed (err=%lu)\n",
             (unsigned long)GetLastError());
    return 1;
  }
  for (int i = 0; i < count; ++i) {
    wchar_t path[1024];
    _snwprintf(path, 1024, L"%s.%d.txt", marker, i);
    path[1023] = L'\0';
    HANDLE h = pCreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
      CloseHandle(h);
    } else {
      fwprintf(stderr, L"CreateFileW failed for %s (err=%lu)\n",
               path, (unsigned long)GetLastError());
    }
  }
  return 0;
}
