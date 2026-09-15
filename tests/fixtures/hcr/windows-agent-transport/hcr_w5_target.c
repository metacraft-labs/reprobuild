/*
 * HX-W-5 real target. No mocks: it reads its own Tool Help module list after
 * the launcher resumes the primary thread and reports whether the canonical
 * agent DLL is genuinely mapped. A stop-file keeps lifetime under the gate's
 * control without adding a synthetic IPC path beside the named pipe under test.
 */
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include <tlhelp32.h>

static int canonical_agent_is_loaded(void) {
  HANDLE snapshot = CreateToolhelp32Snapshot(
      TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, GetCurrentProcessId());
  MODULEENTRY32W module;
  int found = 0;
  if (snapshot == INVALID_HANDLE_VALUE) {
    return -1;
  }
  ZeroMemory(&module, sizeof(module));
  module.dwSize = sizeof(module);
  if (Module32FirstW(snapshot, &module)) {
    do {
      if (_wcsicmp(module.szModule, L"repro_hcr_agent.dll") == 0) {
        found = 1;
        break;
      }
    } while (Module32NextW(snapshot, &module));
  }
  CloseHandle(snapshot);
  return found;
}

int wmain(int argc, wchar_t **argv) {
  FILE *report = NULL;
  int loaded;
  unsigned waited = 0;
  if (argc != 3) {
    fwprintf(stderr, L"usage: hcr_w5_target.exe <report> <stop-file>\n");
    return 2;
  }
  loaded = canonical_agent_is_loaded();
  if (_wfopen_s(&report, argv[1], L"wb") != 0 || report == NULL) {
    return 3;
  }
  fprintf(report,
          "{\"pid\":%lu,\"mainStarted\":true," \
          "\"canonicalAgentLoaded\":%s,\"moduleEnumerationOk\":%s}\n",
          (unsigned long)GetCurrentProcessId(), loaded == 1 ? "true" : "false",
          loaded >= 0 ? "true" : "false");
  fclose(report);
  while (GetFileAttributesW(argv[2]) == INVALID_FILE_ATTRIBUTES &&
         waited < 30000) {
    Sleep(25);
    waited += 25;
  }
  return 0;
}
