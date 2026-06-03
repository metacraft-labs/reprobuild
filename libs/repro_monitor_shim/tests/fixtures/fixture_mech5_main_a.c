/* M73 Phase 3 — dispatch-mechanism 5A (host EXE): LoadLibraryW a fresh
 * DLL post-shim-init and invoke its exported ANSI wrapper that calls
 * CreateFileA through its own IAT.
 *
 * Parallel of fixture_mech5_main.c. Identical except we resolve and
 * invoke `late_create_file_a_n` from fixture_mech5_late_dll_a.dll. The
 * call lands inside the DLL on CreateFileA whose IAT slot was populated
 * at LoadLibraryW time pointing at the shim's inline-detoured kernel32
 * entry — i.e. the shim's snoopCreateFileA trampoline.
 *
 * We keep a separate main here (rather than parameterising symbol-name
 * + variant) to mirror the existing fixture_mech5_main.c shape so the
 * orchestrator can grep for either file by name during debugging.
 *
 * Invocation: fixture_mech5_main_a.exe <dll-path> <marker> <count>
 *
 * `marker` is passed as a wchar_t * here (wmain) and the DLL's
 * `late_create_file_a_n` wrapper narrows it to ANSI internally before
 * each CreateFileA call.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

typedef int (*LateCreateFileANPtr)(const wchar_t *markerW, int count);

int wmain(int argc, wchar_t **argv) {
  if (argc != 4) {
    fwprintf(stderr,
             L"usage: %s <dll-path> <marker> <count>\n", argv[0]);
    return 2;
  }
  const wchar_t *dllPath = argv[1];
  const wchar_t *marker = argv[2];
  int count = _wtoi(argv[3]);
  if (count <= 0) {
    fwprintf(stderr, L"count must be > 0\n");
    return 2;
  }
  HMODULE hDll = LoadLibraryW(dllPath);
  if (hDll == NULL) {
    fwprintf(stderr,
             L"LoadLibraryW(%s) failed (err=%lu)\n", dllPath,
             (unsigned long)GetLastError());
    return 1;
  }
  /* GetProcAddress's name argument is LPCSTR unconditionally. The
   * symbol we want is the ANSI-variant wrapper from
   * fixture_mech5_late_dll_a.c. */
  LateCreateFileANPtr pLateCreateA =
      (LateCreateFileANPtr)(void *)GetProcAddress(hDll,
                                                  "late_create_file_a_n");
  if (pLateCreateA == NULL) {
    fwprintf(stderr,
             L"GetProcAddress(late_create_file_a_n) failed (err=%lu)\n",
             (unsigned long)GetLastError());
    return 1;
  }
  pLateCreateA(marker, count);
  return 0;
}
