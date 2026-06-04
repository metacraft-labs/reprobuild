/* M73 Phase 2 — dispatch-mechanism 5 (host EXE): LoadLibraryW a fresh
 * DLL post-shim-init and invoke its exported wrapper that calls
 * CreateFileW through its own IAT.
 *
 * The shim is injected at process start by repro-fs-snoop (Windows
 * inject path: CreateProcess(CREATE_SUSPENDED) +
 * CreateRemoteThread(LoadLibraryW)). By the time wmain() runs, the
 * shim's inline detours at the kernel32 function bodies are already
 * installed.
 *
 * We then LoadLibraryW the fresh fixture DLL. The Windows loader
 * resolves the DLL's IAT entries by walking kernel32's export table —
 * but the kernel32 entry-point addresses have been overwritten with
 * a 5-byte JMP rel32 to the shim trampoline, so the loader-populated
 * IAT slots already point at "the trampoline returns to kernel32 via
 * the saved relocation-fixed prologue" via that JMP. Every call from
 * INSIDE the DLL therefore lands on the shim's snoop callback the
 * same as IAT-routed calls from the main EXE.
 *
 * The depfile records N mrFileOpen records with the unique marker
 * substring in the path.
 *
 * Invocation: fixture_mech5_main.exe <dll-path> <marker> <count>
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

typedef int (*LateCreateFileNPtr)(const wchar_t *marker, int count);

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
  /* CRITICAL: LoadLibraryW happens HERE, AFTER the shim's
   * repro_monitor_shim_init has run (via the inject-time
   * CreateRemoteThread). The DLL's IAT is freshly resolved at this
   * point — there's no opportunity for a one-shot-at-injection IAT
   * patcher to have touched it.
   *
   * Pre-M73 the shim was IAT-only at injection time, so a DLL loaded
   * later than that one shot had unpatched IATs unless an LdrLoadDll
   * detour intervened. The reprobuild shim has no LdrLoadDll detour,
   * so this mechanism would have failed silently. Post-M73 the inline
   * detour at kernel32's function body means the loader resolves the
   * IAT slot to "the patched kernel32 entry" — which IS the
   * trampoline. The call lands. */
  HMODULE hDll = LoadLibraryW(dllPath);
  if (hDll == NULL) {
    fwprintf(stderr,
             L"LoadLibraryW(%s) failed (err=%lu)\n", dllPath,
             (unsigned long)GetLastError());
    return 1;
  }
  LateCreateFileNPtr pLateCreate =
      (LateCreateFileNPtr)(void *)GetProcAddress(hDll,
                                                 "late_create_file_n");
  if (pLateCreate == NULL) {
    fwprintf(stderr,
             L"GetProcAddress(late_create_file_n) failed (err=%lu)\n",
             (unsigned long)GetLastError());
    return 1;
  }
  pLateCreate(marker, count);
  return 0;
}
