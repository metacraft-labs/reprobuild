## Already-elevated detection (M81 deliverable 2).
##
## Per Elevation-And-Privileged-Operations.md "The Already-Elevated
## Fast Path": `repro` detects its own token elevation at entry. When
## elevated, the privileged set runs in-process — NO broker, NO
## prompt. This is the common case for scripted / CI system applies
## run from an already-elevated context.
##
## Windows: `GetTokenInformation` with `TokenElevation` on the
## current process token. POSIX: `geteuid() == 0`.

import ./errors

when defined(windows):
  # ---------------------------------------------------------------------
  # Win32 binding — hand-rolled, tiny stable surface, same convention
  # as the M68 registry driver.
  # ---------------------------------------------------------------------
  type
    HANDLE = pointer
    DWORD = uint32
    BOOL = int32

  const
    TokenElevation = 20'u32              ## TOKEN_INFORMATION_CLASS value
    TOKEN_QUERY: DWORD = 0x0008

  proc GetCurrentProcess(): HANDLE
    {.importc, stdcall, dynlib: "kernel32".}

  proc OpenProcessToken(processHandle: HANDLE; desiredAccess: DWORD;
                        tokenHandle: ptr HANDLE): BOOL
    {.importc, stdcall, dynlib: "advapi32".}

  proc GetTokenInformation(tokenHandle: HANDLE; tokenInformationClass: uint32;
                           tokenInformation: pointer;
                           tokenInformationLength: DWORD;
                           returnLength: ptr DWORD): BOOL
    {.importc, stdcall, dynlib: "advapi32".}

  proc CloseHandle(h: HANDLE): BOOL
    {.importc, stdcall, dynlib: "kernel32".}

  proc detectElevatedWindows(): bool =
    ## Query `TOKEN_ELEVATION.TokenIsElevated` on the current
    ## process token. A non-zero `TokenIsElevated` means the process
    ## holds a full administrator token.
    var token: HANDLE
    if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, addr token) == 0:
      raiseBrokerLaunch("OpenProcessToken failed while checking " &
        "token elevation")
    defer: discard CloseHandle(token)
    var elevated: DWORD = 0             ## TOKEN_ELEVATION is one DWORD
    var returned: DWORD = 0
    if GetTokenInformation(token, TokenElevation, addr elevated,
        DWORD(sizeof(elevated)), addr returned) == 0:
      raiseBrokerLaunch("GetTokenInformation(TokenElevation) failed")
    return elevated != 0

else:
  proc geteuid(): uint32 {.importc, header: "<unistd.h>".}

# ---------------------------------------------------------------------------
# Public surface.
# ---------------------------------------------------------------------------

proc isProcessElevated*(): bool =
  ## True when the current `repro` process is already running with an
  ## elevated / root token. The apply driver consults this once at
  ## entry: when true, the privileged set runs in-process with no
  ## broker.
  when defined(windows):
    detectElevatedWindows()
  else:
    geteuid() == 0'u32

const ForceBrokerEnvVar* = "REPRO_FORCE_BROKER"
  ## TEST-ONLY seam. When this environment variable is set to a
  ## non-empty value, `shouldUseBroker` reports `true` even when the
  ## process is already elevated, so the integration gate can
  ## exercise the real broker launch + IPC + dispatch path without an
  ## interactive UAC prompt (an already-elevated parent's `runas`
  ## launch of the broker child does NOT raise a prompt). It is
  ## strictly test infrastructure: it never weakens or bypasses any
  ## authentication, drift, or closed-set check — it only forces the
  ## process-topology decision. Production callers must never set it.

proc forceBrokerRequested*(envValue: string): bool =
  ## Pure predicate over the env var's value, so it is unit-testable
  ## without touching the real process environment.
  envValue.len > 0
