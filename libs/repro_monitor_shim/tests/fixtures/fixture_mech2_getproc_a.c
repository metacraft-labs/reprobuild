/* M73 Phase 3 — dispatch-mechanism 2A: LoadLibrary + GetProcAddress
 * runtime-resolved CreateFileA.
 *
 * Parallel of fixture_mech2_getproc.c but targeting the ANSI variant.
 * The fixture resolves CreateFileA at runtime through
 * LoadLibraryW("kernel32") + GetProcAddress("CreateFileA") and caches
 * the function pointer in a static. Every call site jumps through the
 * cached pointer:
 *
 *     pCreateFileA(path, ...);
 *
 * No IAT entry for CreateFileA exists in this binary's PE imports; the
 * only entry for the call lands at the kernel32 function body via the
 * cached pointer. Pre-M73 the monitor shim's IAT-only install missed
 * this mechanism entirely; post-M73 the inline detour at the kernel32
 * function body catches it the same as the IAT-routed case.
 *
 * Note: We use LoadLibraryW (not LoadLibraryA) to load kernel32 because
 * the wide-char form is the canonical way and the choice of LoadLibrary
 * variant is orthogonal to which CreateFile variant we then resolve.
 *
 * Invocation: fixture_mech2_getproc_a.exe <marker> <count>
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

/* CreateFileA function-pointer typedef: identical to CreateFileW's signature
 * except lpFileName is LPCSTR (ANSI) rather than LPCWSTR (UTF-16). */
typedef HANDLE (WINAPI *CreateFileAPtr)(LPCSTR, DWORD, DWORD,
                                        LPSECURITY_ATTRIBUTES, DWORD,
                                        DWORD, HANDLE);

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <marker> <count>\n", argv[0]);
    return 2;
  }
  const char *marker = argv[1];
  int count = atoi(argv[2]);
  if (count <= 0) {
    fprintf(stderr, "count must be > 0\n");
    return 2;
  }
  HMODULE hKernel32 = LoadLibraryW(L"kernel32.dll");
  if (hKernel32 == NULL) {
    fprintf(stderr, "LoadLibraryW(kernel32) failed (err=%lu)\n",
            (unsigned long)GetLastError());
    return 1;
  }
  /* GetProcAddress takes an LPCSTR for its name argument unconditionally
   * (there's no GetProcAddressW). Resolving "CreateFileA" yields the
   * raw kernel32 entry-point address for the ANSI form. */
  CreateFileAPtr pCreateFileA =
      (CreateFileAPtr)(void *)GetProcAddress(hKernel32, "CreateFileA");
  if (pCreateFileA == NULL) {
    fprintf(stderr, "GetProcAddress(CreateFileA) failed (err=%lu)\n",
            (unsigned long)GetLastError());
    return 1;
  }
  for (int i = 0; i < count; ++i) {
    char path[1024];
    _snprintf(path, 1024, "%s.%d.txt", marker, i);
    path[1023] = '\0';
    HANDLE h = pCreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
      CloseHandle(h);
    } else {
      fprintf(stderr, "CreateFileA failed for %s (err=%lu)\n",
              path, (unsigned long)GetLastError());
    }
  }
  return 0;
}
