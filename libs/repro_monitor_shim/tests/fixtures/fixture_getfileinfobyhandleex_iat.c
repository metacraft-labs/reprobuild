/* M73 Phase 5 — IAT-routed GetFileInformationByHandleEx fixture.
 *
 * GetFileInformationByHandleEx is not in Nim's winlean, so we use a C
 * fixture with __declspec(dllimport) (mechanism 1) to exercise the
 * Phase 5 inline detour at kernel32!GetFileInformationByHandleEx. The
 * inline detour catches the call regardless of dispatch mechanism;
 * mechanism 1 is the easiest to exercise without a Nim binding.
 *
 * Invocation: fixture_getfileinfobyhandleex_iat.exe <marker> <count>
 *
 * For each i in [0, count):
 *   - CreateFileW(<marker>.<i>.txt, OPEN_ALWAYS) to get a handle whose
 *     path the shim records via rememberHandlePath.
 *   - GetFileInformationByHandleEx(h, FileBasicInfo, &info, sizeof(info))
 *     — fires the snoop, which resolves the path via pathForHandle and
 *     emits an mrPathProbe record with detail
 *     "GetFileInformationByHandleEx".
 *   - CloseHandle(h).
 *
 * The depfile MUST contain exactly N mrPathProbe records whose path
 * contains the marker substring AND whose detail is
 * "GetFileInformationByHandleEx".
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
    _snwprintf(path, 1024, L"%s.%d.txt", marker, i);
    path[1023] = L'\0';
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
      fwprintf(stderr, L"CreateFileW failed for %s\n", path);
      continue;
    }
    FILE_BASIC_INFO info;
    /* GetFileInformationByHandleEx — fires the Phase 5 hook. */
    if (!GetFileInformationByHandleEx(h, FileBasicInfo, &info, sizeof(info))) {
      fwprintf(stderr, L"GetFileInformationByHandleEx failed for %s\n", path);
    }
    CloseHandle(h);
  }
  return 0;
}
