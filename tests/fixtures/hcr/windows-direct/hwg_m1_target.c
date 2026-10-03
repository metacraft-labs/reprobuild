/*
 * HWG-M1 real direct-patch target. No mocks are used. The launcher injects
 * the production DLL and this process repeatedly records the production code's
 * return value, providing a behavioral observation independent of protocol.
 */
#include <share.h>
#include <stdio.h>
#include <windows.h>

__declspec(noinline) __declspec(dllexport) int hwg_m1_victim(int value) {
  return value + 11;
}

int wmain(int argc, wchar_t **argv) {
  unsigned sequence = 0;
  if (argc != 3) {
    fwprintf(stderr,
             L"usage: hwg_m1_target.exe <observations> <stop-file>\n");
    return 2;
  }
  while (GetFileAttributesW(argv[2]) == INVALID_FILE_ATTRIBUTES &&
         sequence < 4000) {
    FILE *observations = NULL;
    int value = hwg_m1_victim(7);
    /* The gate reads this stream while the target runs. _wfopen_s denies
     * sharing, so a reader racing fprintf/fclose fails with PermissionError.
     * Permit readers while retaining the single-writer contract. */
    observations = _wfsopen(argv[1], sequence == 0 ? L"wb" : L"ab", _SH_DENYWR);
    if (observations == NULL) {
      return 3;
    }
    fprintf(observations, "%u,%d\n", sequence, value);
    fclose(observations);
    ++sequence;
    Sleep(10);
  }
  return 0;
}
