/* fixture_deep_tree.c — adversarial fixture for the framework's
 * grandchild-injection chain.
 *
 * Operation:
 *   - Argv: `<marker-dir> <remaining-depth>`.
 *   - At every level: open <marker-dir>\dt.<remaining-depth>.txt via
 *     CreateFileW (depfile records this).
 *   - If remaining-depth > 0: spawn one child invoked with
 *     remaining-depth - 1. Wait for the child. Exit.
 *   - If remaining-depth == 0: just open the marker file and exit.
 *
 * Why this covers the framework's grandchild-injection chain:
 *   - Pre-framework path: fs-snoop injected the shim into the first
 *     child. That child's snoopCreateProcessW then injected the shim
 *     into the grandchild via the bespoke INFINITE-wait path. With N
 *     levels, N-1 cross-process injections chain back-to-back.
 *   - Post-framework: each level's snoopCreateProcessW calls
 *     stackable_hooks/propagation_windows.injectShimIntoChild with
 *     the safety knobs. Verifies the chain still propagates correctly
 *     under the new deadline + skip-if-already-mapped semantics.
 *
 * Strict-equality contract: the depfile must contain exactly
 *   - N+1 mrFileOpen records (one per level including depth=0), AND
 *   - N mrProcessSpawn records (one per CreateProcessW),
 * where N is the depth argument the top-level invocation got.
 *
 * The depth is capped at 8 in this fixture (any deeper risks a
 * StackOverflow on the child-side init thread; we want to test the
 * propagation path, not the OS scheduler). 8 levels is enough to
 * expose any chain-truncation bug — webpack's call graph is shallower
 * than 8 in practice (it's wide, not deep).
 */

#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include <stdio.h>
#include <stdlib.h>

static int open_marker(const wchar_t *marker_dir, int depth_label)
{
    wchar_t path[1024];
    _snwprintf(path, 1024, L"%ls\\dt.%d.txt", marker_dir, depth_label);
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ,
                           NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 1;
    CloseHandle(h);
    return 0;
}

static int spawn_descendant(const wchar_t *self, const wchar_t *marker_dir,
                            int remaining_depth)
{
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    wchar_t cmdline[2048];
    _snwprintf(cmdline, 2048, L"\"%ls\" \"%ls\" %d",
               self, marker_dir, remaining_depth);

    BOOL ok = CreateProcessW(self, cmdline, NULL, NULL, FALSE,
                              0, NULL, NULL, &si, &pi);
    if (!ok) {
        fwprintf(stderr,
                 L"CreateProcessW failed at remaining_depth=%d (err %lu)\n",
                 remaining_depth, GetLastError());
        return 2;
    }

    DWORD rc = WaitForSingleObject(pi.hProcess, 60000);
    if (rc == WAIT_TIMEOUT || rc == WAIT_FAILED) {
        fwprintf(stderr,
                 L"WaitForSingleObject rc=0x%lx at remaining_depth=%d\n",
                 rc, remaining_depth);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        return 3;
    }

    DWORD exit_code = 1;
    GetExitCodeProcess(pi.hProcess, &exit_code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int)exit_code;
}

int wmain(int argc, wchar_t **argv)
{
    if (argc != 3) {
        fwprintf(stderr, L"usage: %ls <marker-dir> <remaining-depth>\n",
                 argv[0]);
        return 2;
    }
    const wchar_t *marker_dir = argv[1];
    int remaining_depth = _wtoi(argv[2]);
    if (remaining_depth < 0 || remaining_depth > 8) {
        fwprintf(stderr, L"remaining-depth must be in 0..8: %d\n",
                 remaining_depth);
        return 2;
    }

    /* Open the level-specific marker BEFORE recursing so the depfile
     * sees every depth label even if the descendant fails. */
    if (open_marker(marker_dir, remaining_depth) != 0) {
        return 4;
    }

    if (remaining_depth == 0) {
        return 0;
    }
    return spawn_descendant(argv[0], marker_dir, remaining_depth - 1);
}
