/* M73 Phase 3 — dispatch-mechanism 1A: __declspec(dllimport) CreateFileA.
 *
 * Parallel of fixture_mech1_iat.c but targeting the ANSI variant. The
 * compiler resolves CreateFileA through the kernel32 import library at
 * link time; every call site emits an indirect jump through this binary's
 * PE Import Address Table slot:
 *
 *     call qword ptr [__imp_CreateFileA]
 *
 * Phase 1 already landed the hookTable entry HookCreateFileA + its
 * inline trampoline + the snoopCreateFileA callback (which emits
 * mrFileOpen records identical to the W-variant case). Phase 3's job is
 * to prove that install actually catches the A-variant dispatch
 * surface end-to-end; this fixture provides the IAT-routed flavour.
 *
 * Invocation: fixture_mech1_iat_a.exe <marker> <count>
 *
 * The marker is an ANSI string (char *) so the path embeds directly in
 * each CreateFileA call's lpFileName argument. The depfile's
 * snoopCreateFileA emits `$lpFileName` which on Nim resolves to the C
 * string; the marker substring is verified by the harness.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Use the ANSI entry point (main, not wmain) so argv is char ** and the
 * marker stays in the ANSI domain end-to-end. CreateFileA expects LPCSTR
 * (ANSI / current-code-page); passing argv[1] directly is correct. */
int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <marker> <count>\n", argv[0]);
    return 2;
  }
  const char *marker = argv[1];
  int count = atoi(argv[2]);
  if (count <= 0) {
    fprintf(stderr, "count must be > 0\n");
    return 2;
  }
  for (int i = 0; i < count; ++i) {
    char path[1024];
    /* _snprintf is the mingw-w64 form. We deliberately leave room for
     * the NUL terminator and force it explicitly so a truncation never
     * yields a non-NUL-terminated path that crashes CreateFileA. */
    _snprintf(path, 1024, "%s.%d.txt", marker, i);
    path[1023] = '\0';
    /* CreateFileA via the __declspec(dllimport) IAT slot — the standard
     * ANSI kernel32 calling convention. The shim's hookCreateFileA
     * trampoline lives at the kernel32 function body (inline detour
     * landed in Phase 1); the IAT slot resolves to the trampoline at
     * loader-time so this call lands on snoopCreateFileA which emits
     * mrFileOpen with the ANSI path string. */
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
      CloseHandle(h);
    } else {
      /* Keep iterating so the per-mechanism record count still equals
       * exactly N on transient errors — the depfile records the call
       * regardless of whether the return value was a valid handle. */
      fprintf(stderr, "CreateFileA failed for %s (err=%lu)\n",
              path, (unsigned long)GetLastError());
    }
  }
  return 0;
}
