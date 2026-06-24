## Windows-System-Resources Phase B fixture: a system profile that
## exercises ALL FOUR of `windows.service`'s new optional fields
## (`displayName`, `binPath`, `recoveryActions`, `recoveryResetSeconds`)
## alongside the legacy three-field shape. Mirrors the production
## `system_windows_runner.nim` profile's actions-runner service
## descriptor.
##
## The e2e gate compiles + runs this fixture and asserts the emitted
## ProfileIntent JSON carries the matching fields. Nothing is applied
## — the service is just a placeholder.

import repro_profile

profile "systemWindowsServicePhaseB":
  resources:
    # Legacy three-field shape: a back-compat baseline next to the
    # Phase B stanza below. A regression that injected a Phase B default
    # field on this stanza would fail the e2e assertion.
    windowsService(name = "sshd",
      startType = Automatic, state = Running,
      address = "legacyService")

    # Full Phase B shape: all four optional fields set.
    windowsService(
      name = "actions.runner.metacraft-labs.windows-runner-001",
      startType = Automatic, state = Running,
      displayName = "GitHub Actions Runner (windows-runner-001)",
      binPath = "C:\\actions-runner\\bin\\Runner.Listener.exe",
      recoveryActions = @[
        (action: wsraRestart, delayMs: 5000),
        (action: wsraRestart, delayMs: 10000),
        (action: wsraReboot, delayMs: 60000)],
      recoveryResetSeconds = 86400,
      address = "actionsRunnerService")
