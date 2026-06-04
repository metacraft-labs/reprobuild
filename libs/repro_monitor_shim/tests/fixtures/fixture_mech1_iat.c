/* M73 Phase 2 — dispatch-mechanism 1: __declspec(dllimport) CreateFileW
 *
 * The C compiler resolves CreateFileW through the kernel32 import library
 * at link time. Every call site emits an indirect jump through this
 * binary's PE Import Address Table slot:
 *
 *     call qword ptr [__imp_CreateFileW]
 *
 * That is the classic "IAT-routed" dispatch mechanism. The monitor shim's
 * inline-detour install path catches this case at the kernel32 function
 * body, NOT at the IAT slot — but the legacy IAT-patcher path catches it
 * too, so historically this mechanism has always been monitored. It is
 * included in the dispatch-mechanism coverage matrix as the baseline.
 *
 * Invocation: fixture_mech1_iat.exe <marker> <count>
 *
 * Creates <marker>.<i>.txt for i in [0, count) via CreateFileW with
 * GENERIC_READ + OPEN_ALWAYS so each call shows up in the depfile as a
 * mrFileOpen record with the unique marker substring in its path. The
 * file's contents are irrelevant; we close the handle immediately.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
  for (int i = 0; i < count; ++i) {
    wchar_t path[1024];
    /* swprintf_s is the safe form available in mingw-w64. */
    _snwprintf(path, 1024, L"%s.%d.txt", marker, i);
    path[1023] = L'\0';
    /* CreateFileW via the __declspec(dllimport) IAT slot — the standard
     * kernel32 calling convention for statically-linked C / C++. */
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
      CloseHandle(h);
    } else {
      /* OPEN_ALWAYS on a fresh path SHOULD succeed; emit the error to
       * stderr but keep iterating so the test can still count how many
       * calls reached the shim. The depfile's mrFileOpen record is
       * emitted post-call regardless of the return value. */
      fwprintf(stderr, L"CreateFileW failed for %s (err=%lu)\n",
               path, (unsigned long)GetLastError());
    }
  }
  return 0;
}
