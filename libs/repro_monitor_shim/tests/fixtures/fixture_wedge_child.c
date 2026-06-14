/* fixture_wedge_child.c — adversarial fixture for the framework's
 * waitDeadlineMs safety knob.
 *
 * Operation:
 *   - Without `--child`: act as the parent. Open <marker-dir>\wedge-parent.txt
 *     (depfile record this), spawn one child WITHOUT --child argv, wait
 *     for the child with a 12 s deadline, then open
 *     <marker-dir>\wedge-parent-after.txt. Exit 0.
 *   - With `--child`: open <marker-dir>\wedge-child-before.txt, sleep
 *     for 8 seconds, then open <marker-dir>\wedge-child-after.txt. Exit 0.
 *
 * Why this exercises waitDeadlineMs:
 *   The framework's defaultInjectionConfig has waitDeadlineMs=5000.
 *   When fs-snoop spawns the parent (via the framework's
 *   injectShimIntoChild), LoadLibraryW returns in milliseconds — no
 *   wedge there. When the parent spawns the wedge child, the
 *   framework's injectShimIntoChild fires LoadLibraryW in the child.
 *   The child has not yet reached its `Sleep(8000)` call when
 *   LoadLibraryW runs (DLL load happens before main); so injection
 *   completes fine. The Sleep happens AFTER injection — it doesn't
 *   block the propagation path.
 *
 *   The deadline really matters under loader-lock contention: if a
 *   child's CRT init grabs a lock that another thread holds, our
 *   LoadLibraryW remote thread can't complete. Without the deadline
 *   (pre-framework INFINITE), the parent would wedge forever. The
 *   wedge child here simulates that worst-case timing by sleeping
 *   inside main() — the parent's wait should still bound at 12s
 *   regardless of whether injection raced or not.
 *
 * Strict-equality contract: the depfile must contain
 *   - 3 mrFileOpen records (parent-before, child-before, child-after, parent-after = 4 actually)
 *   - 1 mrProcessSpawn record (the wedge-child spawn).
 *
 * Wall-clock contract: the test wrapper measures the fixture's total
 * runtime. It must be < 12s (the child sleeps 8s; the framework's
 * own 5s deadline can stack at most once per child level).
 */

#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include <stdio.h>
#include <stdlib.h>

static int open_marker(const wchar_t *marker_dir, const wchar_t *name)
{
    wchar_t path[1024];
    _snwprintf(path, 1024, L"%ls\\%ls", marker_dir, name);
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ,
                           NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 1;
    CloseHandle(h);
    return 0;
}

static int child_mode(const wchar_t *marker_dir)
{
    if (open_marker(marker_dir, L"wedge-child-before.txt") != 0) return 4;
    Sleep(8000);
    if (open_marker(marker_dir, L"wedge-child-after.txt") != 0) return 5;
    return 0;
}

static int parent_mode(const wchar_t *self, const wchar_t *marker_dir)
{
    if (open_marker(marker_dir, L"wedge-parent.txt") != 0) return 6;

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    wchar_t cmdline[2048];
    _snwprintf(cmdline, 2048, L"\"%ls\" --child \"%ls\"", self, marker_dir);
    BOOL ok = CreateProcessW(self, cmdline, NULL, NULL, FALSE,
                              0, NULL, NULL, &si, &pi);
    if (!ok) {
        fwprintf(stderr, L"CreateProcessW failed (err %lu)\n",
                 GetLastError());
        return 7;
    }

    DWORD rc = WaitForSingleObject(pi.hProcess, 12000);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (rc == WAIT_TIMEOUT) {
        fwprintf(stderr, L"wedge child wait timed out at 12s\n");
        return 8;
    }
    if (rc == WAIT_FAILED) {
        fwprintf(stderr, L"WaitForSingleObject failed (err %lu)\n",
                 GetLastError());
        return 9;
    }

    if (open_marker(marker_dir, L"wedge-parent-after.txt") != 0) return 10;
    return 0;
}

int wmain(int argc, wchar_t **argv)
{
    if (argc == 3 && wcscmp(argv[1], L"--child") == 0) {
        return child_mode(argv[2]);
    }
    if (argc != 2) {
        fwprintf(stderr, L"usage: %ls <marker-dir>\n", argv[0]);
        return 2;
    }
    return parent_mode(argv[0], argv[1]);
}
