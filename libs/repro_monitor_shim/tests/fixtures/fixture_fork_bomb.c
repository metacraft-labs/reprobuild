/* fixture_fork_bomb.c — adversarial fixture for the framework's
 * concurrent-injection path.
 *
 * Operation:
 *   - Without `--child` argv: act as the parent. Spawn N children via
 *     CreateProcessW; each child gets a unique marker index passed as
 *     its second argv. Wait for every child. Exit 0 on success.
 *   - With `--child <marker> <index>`: open <marker>.<index>.txt via
 *     CreateFileW (so the shim records an mrFileOpen against the
 *     child-side instrumented process). Exit 0.
 *
 * Why this covers the framework's safer injectShimIntoChild:
 *   - Every spawn fires the framework's autoPropagateCreateProcessW
 *     equivalent inside the shim's snoopCreateProcessW (which calls
 *     stackable_hooks/propagation_windows.injectShimIntoChild).
 *   - With N=16 children spawned back-to-back, the framework's
 *     maxInFlight=16 semaphore admits all of them concurrently; any
 *     bug in the admission control or wait-deadline would surface as
 *     either a missing mrFileOpen record (child not instrumented) or
 *     a parent-side hang (pre-framework INFINITE behaviour).
 *
 * Invocation:
 *   fixture_fork_bomb.exe <marker-dir> <N>
 *   fixture_fork_bomb.exe --child <marker-dir> <index>
 *
 * Strict-equality contract (mirrors M73 Phase 2): the depfile must
 * contain exactly N mrProcessSpawn records (one per child) AND exactly
 * N mrFileOpen records matching the marker dir (one per child's
 * CreateFileW). Any other count is a regression.
 */

#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include <stdio.h>
#include <stdlib.h>

static int child_mode(const wchar_t *marker_dir, int index)
{
    wchar_t path[1024];
    /* The shim's snoop hook records every CreateFileW. We use
     * OPEN_ALWAYS so a non-existent file still produces a recordable
     * event without depending on a pre-populated marker tree. */
    _snwprintf(path, 1024, L"%ls\\fb.%d.txt", marker_dir, index);
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ,
                           NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        CloseHandle(h);
    }
    return 0;
}

static int parent_mode(const wchar_t *self, const wchar_t *marker_dir, int n)
{
    if (n <= 0 || n > 256) {
        fwprintf(stderr, L"N out of range (1..256): %d\n", n);
        return 2;
    }

    HANDLE *child_handles = (HANDLE *)calloc((size_t)n, sizeof(HANDLE));
    if (child_handles == NULL) return 3;

    for (int i = 0; i < n; i++) {
        STARTUPINFOW si;
        PROCESS_INFORMATION pi;
        ZeroMemory(&si, sizeof(si));
        si.cb = sizeof(si);
        ZeroMemory(&pi, sizeof(pi));

        wchar_t cmdline[2048];
        _snwprintf(cmdline, 2048,
                   L"\"%ls\" --child \"%ls\" %d",
                   self, marker_dir, i);

        BOOL ok = CreateProcessW(self, cmdline, NULL, NULL, FALSE,
                                  0, NULL, NULL, &si, &pi);
        if (!ok) {
            fwprintf(stderr, L"CreateProcessW failed for index %d (err %lu)\n",
                     i, GetLastError());
            free(child_handles);
            return 4;
        }
        CloseHandle(pi.hThread);
        child_handles[i] = pi.hProcess;
    }

    /* Wait for every child. We use WaitForMultipleObjects in batches
     * of MAXIMUM_WAIT_OBJECTS so N up to 256 is supported. */
    int waited = 0;
    while (waited < n) {
        DWORD batch = (DWORD)(n - waited);
        if (batch > MAXIMUM_WAIT_OBJECTS) batch = MAXIMUM_WAIT_OBJECTS;
        DWORD rc = WaitForMultipleObjects(batch, &child_handles[waited],
                                           TRUE, 30000);
        if (rc == WAIT_TIMEOUT || rc == WAIT_FAILED) {
            fwprintf(stderr, L"WaitForMultipleObjects rc=0x%lx (err %lu)\n",
                     rc, GetLastError());
            for (int j = 0; j < n; j++) {
                if (child_handles[j]) CloseHandle(child_handles[j]);
            }
            free(child_handles);
            return 5;
        }
        waited += (int)batch;
    }

    for (int i = 0; i < n; i++) {
        if (child_handles[i]) CloseHandle(child_handles[i]);
    }
    free(child_handles);
    return 0;
}

int wmain(int argc, wchar_t **argv)
{
    if (argc == 4 && wcscmp(argv[1], L"--child") == 0) {
        return child_mode(argv[2], _wtoi(argv[3]));
    }
    if (argc != 3) {
        fwprintf(stderr,
                 L"usage: %ls <marker-dir> <N>\n"
                 L"       %ls --child <marker-dir> <index>\n",
                 argv[0], argv[0]);
        return 2;
    }
    return parent_mode(argv[0], argv[1], _wtoi(argv[2]));
}
