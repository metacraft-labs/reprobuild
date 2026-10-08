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
    /* The gate polls this file every 25ms while we reopen it ~100 times a
     * second. A reader holding it for the instant we reopen is routine and
     * transient, so retry: treating it as fatal kills the observation stream
     * on a race with the very gate that is watching it, and the gate then
     * reports a count it never reached with no way to tell why. Exit 3 is
     * kept for an open that stays broken, which is a real failure. */
    {
      const wchar_t *mode = sequence == 0 ? L"wb" : L"ab";
      unsigned open_attempt = 0;
      while (_wfopen_s(&observations, argv[1], mode) != 0 ||
             observations == NULL) {
        observations = NULL;
        if (++open_attempt >= 100) {
          return 3;
        }
        Sleep(10);
      }
    }
    fprintf(observations, "%u,%d\n", sequence, value);
    fclose(observations);
    ++sequence;
    Sleep(10);
  }
  return 0;
}
