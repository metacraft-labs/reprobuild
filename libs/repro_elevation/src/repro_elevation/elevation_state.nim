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

import repro_core/process_privilege

# ---------------------------------------------------------------------------
# Public surface.
# ---------------------------------------------------------------------------

proc isProcessElevated*(): bool =
  ## True when the current `repro` process is already running with an
  ## elevated / root token. The apply driver consults this once at
  ## entry: when true, the privileged set runs in-process with no
  ## broker.
  ## One answer for every library (`repro_core/process_privilege`); a
  ## token Windows will not describe is a broker-launch error here, as
  ## before.
  try:
    processIsPrivileged()
  except EPrivilegeQuery as e:
    raiseBrokerLaunch(e.msg)

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
