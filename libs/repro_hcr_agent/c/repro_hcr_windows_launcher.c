/*
 * HX-W-5 launcher for new Windows x64 targets.
 *
 * Usage:
 *   repro_hcr_windows_launcher.exe --agent <absolute-or-relative-dll> --
 *       <target.exe> [arguments...]
 *
 * The ordering follows the recorder's proven inject_dll launcher: create the
 * target suspended, run LoadLibraryW alone in a remote thread, invoke the HCR
 * bootstrap export in a second remote thread, then resume the primary thread.
 * This v1 deliberately has no attach-to-pid mode.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <tlhelp32.h>
#include <wchar.h>

static wchar_t *repro_hcr_quote_command_line(int argc, wchar_t **argv) {
  size_t capacity = 1;
  size_t used = 0;
  wchar_t *result;
  int index;
  for (index = 0; index < argc; ++index) {
    capacity += wcslen(argv[index]) * 2 + 4;
  }
  result = (wchar_t *)calloc(capacity, sizeof(wchar_t));
  if (result == NULL) {
    return NULL;
  }
  for (index = 0; index < argc; ++index) {
    const wchar_t *cursor = argv[index];
    size_t backslashes = 0;
    if (index != 0) {
      result[used++] = L' ';
    }
    result[used++] = L'"';
    while (*cursor != L'\0') {
      if (*cursor == L'\\') {
        backslashes++;
        cursor++;
        continue;
      }
      if (*cursor == L'"') {
        size_t count;
        for (count = 0; count < backslashes * 2 + 1; ++count) {
          result[used++] = L'\\';
        }
        result[used++] = L'"';
      } else {
        size_t count;
        for (count = 0; count < backslashes; ++count) {
          result[used++] = L'\\';
        }
        result[used++] = *cursor;
      }
      backslashes = 0;
      cursor++;
    }
    while (backslashes-- > 0) {
      result[used++] = L'\\';
      result[used++] = L'\\';
    }
    result[used++] = L'"';
  }
  result[used] = L'\0';
  return result;
}

static int repro_hcr_absolute_file(const wchar_t *input, wchar_t *output,
                                   size_t capacity) {
  DWORD count = GetFullPathNameW(input, (DWORD)capacity, output, NULL);
  DWORD attributes;
  if (count == 0 || count >= capacity) {
    return -1;
  }
  attributes = GetFileAttributesW(output);
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    return -1;
  }
  return 0;
}

static uintptr_t repro_hcr_find_module(DWORD pid, const wchar_t *full_path,
                                       const wchar_t *leaf_name) {
  unsigned attempt;
  for (attempt = 0; attempt < 100; ++attempt) {
    HANDLE snapshot = INVALID_HANDLE_VALUE;
    MODULEENTRY32W entry;
    do {
      snapshot = CreateToolhelp32Snapshot(
          TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    } while (snapshot == INVALID_HANDLE_VALUE &&
             GetLastError() == ERROR_BAD_LENGTH);
    if (snapshot != INVALID_HANDLE_VALUE) {
      ZeroMemory(&entry, sizeof(entry));
      entry.dwSize = sizeof(entry);
      if (Module32FirstW(snapshot, &entry)) {
        do {
          if ((full_path != NULL && _wcsicmp(entry.szExePath, full_path) == 0) ||
              (leaf_name != NULL && _wcsicmp(entry.szModule, leaf_name) == 0)) {
            uintptr_t base = (uintptr_t)entry.modBaseAddr;
            CloseHandle(snapshot);
            return base;
          }
        } while (Module32NextW(snapshot, &entry));
      }
      CloseHandle(snapshot);
    }
    Sleep(50);
  }
  return 0;
}

static int repro_hcr_wait_thread(HANDLE thread, DWORD *exit_code) {
  DWORD wait_result = WaitForSingleObject(thread, 10 * 1000);
  if (wait_result != WAIT_OBJECT_0 || !GetExitCodeThread(thread, exit_code)) {
    return -1;
  }
  return 0;
}

static int repro_hcr_inject(PROCESS_INFORMATION *process,
                            const wchar_t *dll_path) {
  size_t path_bytes = (wcslen(dll_path) + 1) * sizeof(wchar_t);
  void *remote_path = NULL;
  HMODULE local_kernel32;
  FARPROC local_load_library;
  uintptr_t remote_load_library;
  HANDLE loader_thread = NULL;
  DWORD loader_exit = 0;
  uintptr_t remote_dll;
  HMODULE local_dll = NULL;
  FARPROC local_bootstrap;
  uintptr_t remote_bootstrap;
  HANDLE bootstrap_thread = NULL;
  DWORD bootstrap_exit = 1;
  int result = -1;

  local_kernel32 = GetModuleHandleW(L"kernel32.dll");
  local_load_library = local_kernel32 == NULL
                           ? NULL
                           : GetProcAddress(local_kernel32, "LoadLibraryW");
  if (local_load_library == NULL) {
    fwprintf(stderr, L"HCR launcher: could not resolve remote LoadLibraryW\n");
    goto done;
  }
  /* This launcher and its target are both native x64 processes. Windows maps
   * system DLLs at shared addresses within one boot session, including before
   * a CREATE_SUSPENDED target has populated the Tool Help loader list. */
  remote_load_library = (uintptr_t)local_load_library;

  remote_path = VirtualAllocEx(process->hProcess, NULL, path_bytes,
                               MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
  if (remote_path == NULL ||
      !WriteProcessMemory(process->hProcess, remote_path, dll_path, path_bytes,
                          NULL)) {
    fwprintf(stderr, L"HCR launcher: could not write the DLL path (status %lu)\n",
             (unsigned long)GetLastError());
    goto done;
  }
  loader_thread = CreateRemoteThread(
      process->hProcess, NULL, 0,
      (LPTHREAD_START_ROUTINE)remote_load_library, remote_path, 0, NULL);
  if (loader_thread == NULL ||
      repro_hcr_wait_thread(loader_thread, &loader_exit) != 0) {
    fwprintf(stderr, L"HCR launcher: remote LoadLibraryW failed (status %lu)\n",
             (unsigned long)GetLastError());
    goto done;
  }
  remote_dll = repro_hcr_find_module(process->dwProcessId, dll_path, NULL);
  if (remote_dll == 0) {
    fwprintf(stderr,
             L"HCR launcher: LoadLibraryW returned but the DLL is absent from "
             L"the target module list (low32 0x%08lx)\n",
             (unsigned long)loader_exit);
    goto done;
  }

  local_dll = LoadLibraryExW(dll_path, NULL, DONT_RESOLVE_DLL_REFERENCES);
  local_bootstrap = local_dll == NULL
                        ? NULL
                        : GetProcAddress(local_dll,
                                         "ReproHcrWindowsBootstrap");
  if (local_bootstrap == NULL) {
    fwprintf(stderr,
             L"HCR launcher: agent has no ReproHcrWindowsBootstrap export\n");
    goto done;
  }
  remote_bootstrap =
      remote_dll + ((uintptr_t)local_bootstrap - (uintptr_t)local_dll);
  bootstrap_thread = CreateRemoteThread(
      process->hProcess, NULL, 0,
      (LPTHREAD_START_ROUTINE)remote_bootstrap, NULL, 0, NULL);
  if (bootstrap_thread == NULL ||
      repro_hcr_wait_thread(bootstrap_thread, &bootstrap_exit) != 0 ||
      bootstrap_exit != 0) {
    fwprintf(stderr,
             L"HCR launcher: remote agent bootstrap failed (exit %lu, status %lu)\n",
             (unsigned long)bootstrap_exit, (unsigned long)GetLastError());
    goto done;
  }
  result = 0;

done:
  if (bootstrap_thread != NULL) {
    CloseHandle(bootstrap_thread);
  }
  if (local_dll != NULL) {
    FreeLibrary(local_dll);
  }
  if (loader_thread != NULL) {
    CloseHandle(loader_thread);
  }
  if (remote_path != NULL) {
    VirtualFreeEx(process->hProcess, remote_path, 0, MEM_RELEASE);
  }
  return result;
}

int wmain(int argc, wchar_t **argv) {
  wchar_t dll_path[32768];
  wchar_t target_path[32768];
  wchar_t *command_line = NULL;
  STARTUPINFOW startup;
  PROCESS_INFORMATION process;
  int result = 1;

  if (argc < 5 || wcscmp(argv[1], L"--agent") != 0 ||
      wcscmp(argv[3], L"--") != 0) {
    fwprintf(stderr,
             L"usage: repro_hcr_windows_launcher.exe --agent <dll> -- "
             L"<target.exe> [arguments...]\n"
             L"This v1 starts a new x64 process; attach-to-pid is not "
             L"supported.\n");
    return 2;
  }
  if (repro_hcr_absolute_file(argv[2], dll_path,
                              sizeof(dll_path) / sizeof(dll_path[0])) != 0) {
    fwprintf(stderr, L"HCR launcher: agent DLL does not exist: %ls\n", argv[2]);
    return 2;
  }
  if (repro_hcr_absolute_file(argv[4], target_path,
                              sizeof(target_path) / sizeof(target_path[0])) != 0) {
    fwprintf(stderr, L"HCR launcher: target does not exist: %ls\n", argv[4]);
    return 2;
  }
  argv[4] = target_path;
  command_line = repro_hcr_quote_command_line(argc - 4, argv + 4);
  if (command_line == NULL) {
    fwprintf(stderr, L"HCR launcher: could not allocate the command line\n");
    return 1;
  }

  ZeroMemory(&startup, sizeof(startup));
  startup.cb = sizeof(startup);
  ZeroMemory(&process, sizeof(process));
  if (!CreateProcessW(target_path, command_line, NULL, NULL, FALSE,
                      CREATE_SUSPENDED, NULL, NULL, &startup, &process)) {
    fwprintf(stderr, L"HCR launcher: CreateProcessW failed (status %lu)\n",
             (unsigned long)GetLastError());
    goto done;
  }
  if (repro_hcr_inject(&process, dll_path) != 0) {
    TerminateProcess(process.hProcess, 1);
    goto done;
  }
  if (ResumeThread(process.hThread) == (DWORD)-1) {
    fwprintf(stderr, L"HCR launcher: ResumeThread failed (status %lu)\n",
             (unsigned long)GetLastError());
    TerminateProcess(process.hProcess, 1);
    goto done;
  }
  wprintf(L"{\"pid\":%lu,\"agent\":\"repro_hcr_agent.dll\"," \
          L"\"attached\":false,\"primaryResumed\":true}\n",
          (unsigned long)process.dwProcessId);
  fflush(stdout);
  result = 0;

done:
  free(command_line);
  if (process.hThread != NULL) {
    CloseHandle(process.hThread);
  }
  if (process.hProcess != NULL) {
    CloseHandle(process.hProcess);
  }
  return result;
}
