/*
 * HWG-M1 real direct-patch target. No mocks are used. The launcher injects
 * the production DLL and this process repeatedly records the production code's
 * return value, providing a behavioral observation independent of protocol.
 */
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
    if (_wfopen_s(&observations, argv[1], sequence == 0 ? L"wb" : L"ab") != 0 ||
        observations == NULL) {
      return 3;
    }
    fprintf(observations, "%u,%d\n", sequence, value);
    fclose(observations);
    ++sequence;
    Sleep(10);
  }
  return 0;
}
