/* M73 Phase 2 — dispatch-mechanism 5 (fresh-DLL companion): the late-
 * loaded DLL itself.
 *
 * Statically imports `CreateFileW` via __declspec(dllimport), so its
 * own IAT contains a slot for kernel32!CreateFileW. The slot is
 * populated by the Windows loader when the DLL is LoadLibraryW'd by
 * the main fixture process.
 *
 * Exports `late_create_file_n` which the main fixture calls AFTER
 * LoadLibraryW returns. The CreateFileW call inside the DLL routes
 * either via:
 *   (a) the loader-populated IAT slot — which the M50.5 LdrLoadDll
 *       retroactive-IAT-patch detour was designed to redirect, OR
 *   (b) the kernel32 function body itself — which M73's inline
 *       detour patches once at shim init and which the loader resolves
 *       the IAT slot to at LoadLibraryW time.
 *
 * Either path lands on the shim's trampoline; the depfile records N
 * mrFileOpen records with the unique marker substring.
 *
 * Pre-M73 (IAT-only at the EXE's own IAT, no LdrLoadDll detour, no
 * inline at kernel32): the late-loaded DLL's IAT was never patched,
 * so the call went straight to the unpatched kernel32 entry — the
 * shim's trampoline never fired, the depfile was empty.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

__declspec(dllexport) int late_create_file_n(const wchar_t *marker,
                                             int count) {
  for (int i = 0; i < count; ++i) {
    wchar_t path[1024];
    _snwprintf(path, 1024, L"%s.%d.txt", marker, i);
    path[1023] = L'\0';
    /* Statically-linked CreateFileW — call routes through this DLL's
     * own PE IAT slot, populated at LoadLibraryW time. */
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
      CloseHandle(h);
    }
  }
  return 0;
}

/* DllMain is required for an exe-loadable DLL on Windows. We have no
 * per-load state; just return success. */
BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpReserved) {
  (void)hinstDLL; (void)fdwReason; (void)lpReserved;
  return TRUE;
}
