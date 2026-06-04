/* M73 Phase 3 — dispatch-mechanism 5A (fresh-DLL companion, ANSI form):
 * the late-loaded DLL that statically imports CreateFileA.
 *
 * Parallel of fixture_mech5_late_dll.c. The DLL statically imports
 * CreateFileA via __declspec(dllimport), so its own IAT contains a slot
 * for kernel32!CreateFileA. The slot is populated by the Windows loader
 * when the DLL is LoadLibraryW'd by the main fixture process. Because
 * the kernel32 function body has been overwritten with a 5-byte JMP
 * rel32 to the shim trampoline by then (Phase 1 install at shim init),
 * the loader-populated IAT slot points at the trampoline directly. The
 * call lands on snoopCreateFileA which emits mrFileOpen with the ANSI
 * marker substring.
 *
 * Exports `late_create_file_a_n` which the main fixture calls AFTER
 * LoadLibraryW returns; we reuse the existing fixture_mech5_main.c
 * host so this fixture only needs to expose the symbol name the main
 * harness will resolve via GetProcAddress.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

/* Same signature shape as the W form: marker is an ANSI string (char *)
 * end-to-end so the path embeds directly in CreateFileA. The main
 * fixture takes a `const wchar_t *marker` argv slot; this fixture
 * narrows it to ANSI via WideCharToMultiByte before each call. We do
 * this inside the wrapper rather than in the host so the host can
 * remain shared between mech5 (W) and mech5A (A). */
__declspec(dllexport) int late_create_file_a_n(const wchar_t *markerW,
                                               int count) {
  /* Narrow markerW to ANSI once. Use CP_ACP (the current ANSI code
   * page) which is what CreateFileA itself uses to convert the path
   * back to UTF-16 internally; the round-trip is identity for ASCII
   * temp-dir names like the test uses. */
  char marker[1024];
  int written = WideCharToMultiByte(CP_ACP, 0, markerW, -1, marker, 1024,
                                    NULL, NULL);
  if (written <= 0) {
    return 1;
  }
  for (int i = 0; i < count; ++i) {
    char path[1024];
    _snprintf(path, 1024, "%s.%d.txt", marker, i);
    path[1023] = '\0';
    /* Statically-linked CreateFileA — call routes through this DLL's
     * own PE IAT slot, populated at LoadLibraryW time. */
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL,
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
