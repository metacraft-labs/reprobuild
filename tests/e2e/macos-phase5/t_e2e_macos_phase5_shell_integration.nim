## M6 Phase-5 Gate: e2e_macos_phase5_shell_integration
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the
## `shell.integration` driver (home-scope, in
## `libs/repro_home_resources/src/repro_home_resources/drivers/shell_integration.nim`)
## has had only a Linux WSL gate
## (`tests/e2e/m69/t_e2e_repro_home_shell_integration_vm.nim`,
## `defined(linux)` only). On macOS the target is `~/.zshrc` (zsh
## default since Catalina). This gate is the M6 macOS scaffolding;
## M8 populates the concrete `direnv hook zsh` apply + new-shell
## verification + destroy scenario.
##
## M6 deliverable: the non-destructive half asserts the resource-
## typed digest stability and resource validation. The
## `shell.integration` driver is a thin wrapper around the
## `fs.managedBlock` splice (see `shell_integration.nim`); the splice
## itself is already covered by the macOS fs.managedBlock M6 gate.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half appends a shell-init managed block to a real
## shell-profile in `$HOME`. Guarded by BOTH `defined(macosx)` AND
## `REPRO_PHASE5_MACOS_SHELL_INTEGRATION_VM=1`. M8 lands the
## concrete sandbox scenario.

import std/[os, unittest]

import repro_home_resources

let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_SHELL_INTEGRATION_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: typed digest + validation. Always runs.
# ===========================================================================

suite "shell.integration: typed-resource wiring + digest":

  test "a shell.integration Resource accepts canonical fields":
    let r = Resource(kind: rkShellIntegration,
      address: "shellInt:~/.zshrc#direnv",
      lifecyclePolicy: lpDefault,
      shellHostFilePath: "/Users/zahary/.zshrc",
      shellBlockId: "direnv",
      shellBlockContent: "eval \"$(direnv hook zsh)\"\n")
    check resourceValidationError(r) == ""
    check realWorldIdentity(r) ==
      "/Users/zahary/.zshrc#direnv"

  test "digestOfResource changes when block content changes":
    var r = Resource(kind: rkShellIntegration,
      address: "shellInt:digest",
      lifecyclePolicy: lpDefault,
      shellHostFilePath: "/tmp/repro-m6-shell.txt",
      shellBlockId: "m6",
      shellBlockContent: "echo v=1\n")
    let d0 = digestOfResource(r)
    r.shellBlockContent = "echo v=2\n"
    let d1 = digestOfResource(r)
    check d0 != d1

  test "resourceKindFromString recognizes shell.integration":
    check resourceKindFromString("shell.integration") == rkShellIntegration

# ===========================================================================
# DESTRUCTIVE: real `~/.zshrc` shell-init managed-block write on macOS.
# SANDBOX/VM-ONLY - guarded by BOTH macOS +
# `REPRO_PHASE5_MACOS_SHELL_INTEGRATION_VM=1`. M8 lands the concrete
# scenario.
# ===========================================================================

suite "shell.integration: REAL apply / verify / destroy (sandbox-only)":

  test "real shell.integration lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_SHELL_INTEGRATION_VM " &
        "not set (or not on macOS) - the real `~/.zshrc` direnv-hook " &
        "managed-block write + new-shell verification scenario is " &
        "NOT EXERCISED on this host. Run this gate inside a " &
        "disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_SHELL_INTEGRATION_VM=1 to exercise the " &
        "real shell-init mutation. The pure-logic suites above " &
        "already proved the typed-field digest + validation without " &
        "mutating any host."
    else:
      echo "  [sandbox-scaffold] " &
        "REPRO_PHASE5_MACOS_SHELL_INTEGRATION_VM set; M6 scaffold " &
        "present, M8 will populate the concrete `direnv hook zsh` " &
        "lifecycle steps."
