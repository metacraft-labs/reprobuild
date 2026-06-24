## Windows-System-Resources Phase G end-to-end fixture: a system
## profile that mixes live-state resource templates with action-edge
## typed-tool calls inside a single ``resources:`` block — mirrors
## the production ``system_windows_runner.nim`` shape.
##
## The fixture compiles + runs (the macro recognises both call
## shapes); the emitted ProfileIntent JSON is read back by the e2e
## test which asserts:
##
##   * resources[] carries the live-state items (fsSystemDirectory +
##     windowsService).
##   * buildActions[] carries the action edges (expandArchive.build
##     + bare inlineExecCall).
##   * each action edge has requiresElevation = true so the apply's
##     broker hook fires.
##
## The fixture does NOT actually apply against a live system —
## that's the L3 integration test the campaign's reviewer drives
## against the libvirt Win11 guest.

import repro_profile
import repro_project_dsl
import repro_dsl_stdlib/packages/expand_archive as expandArchive

profile "systemActionEdgesPhaseG":
  resources:
    # Live-state: the runner directory the archive extracts into.
    fsSystemDirectory(path = "C:\\actions-runner",
      address = "runnerDir")

    # Action edge: extract the runner archive (typed tool).
    expandArchive.build(
      archive = "C:\\actions-runner-cache\\actions-runner.zip",
      destination = "C:\\actions-runner",
      marker = "C:\\actions-runner\\config.cmd",
      requiresElevation = true,
      address = "extractRunner",
      dependsOn = ["runnerDir"])

    # Action edge: run the runner's config.cmd (bare inlineExecCall).
    inlineExecCall(
      argv = @[
        "C:\\actions-runner\\config.cmd",
        "--unattended", "--replace",
        "--url", "https://github.com/metacraft-labs",
        "--token", "@FILE:C:\\actions-runner-tokens\\mcl.token",
        "--name", "windows-runner-001"],
      toolIdentityRefs = @["C:\\actions-runner\\config.cmd"],
      inputs = @["C:\\actions-runner-tokens\\mcl.token"],
      outputs = @["C:\\actions-runner\\.runner"],
      requiresElevation = true,
      address = "configureRunner",
      dependsOn = @["extractRunner"])

    # Live-state: the service the configured runner registers.
    # NOTE: a future phase will support live-state ``dependsOn`` that
    # references action-edge outputs (the "interleaved dependency
    # graph" follow-up the spec § 2.3 calls out). Phase G runs all
    # action edges before all live-state items, so the explicit
    # cross-kind dep is omitted here.
    windowsService(
      name = "actions.runner.metacraft-labs.windows-runner-001",
      startType = Automatic, state = Running,
      displayName = "GitHub Actions Runner (windows-runner-001)",
      binPath = "C:\\actions-runner\\bin\\Runner.Listener.exe",
      address = "runnerService")
