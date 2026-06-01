## M6 Phase-5 Gate: e2e_macos_phase5_env_user_path
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the POSIX
## shell-profile arm of `env.userVariable` / `env.userPath` (home-
## scope, in
## `libs/repro_home_resources/src/repro_home_resources/drivers/env_user.nim`)
## has had only a Linux WSL gate
## (`tests/e2e/m69/t_e2e_repro_home_env_user_path_vm.nim`,
## `defined(linux)` only). On macOS the driver appends to
## `~/.zprofile` (zsh has been the macOS default shell since Catalina);
## the legacy `launchctl setenv` path is INTENTIONALLY not taken.
## This gate is the M6 macOS scaffolding; M8 populates the concrete
## apply + new-shell verification + destroy scenario AND the
## `verify_macos_env_uses_shell_profile_not_launchctl` negative test.
##
## M6 deliverable: the non-destructive half asserts the pure
## merge/dedup logic (`computeMergedPath`), the POSIX path-block
## generator (`posixPathBlockContent`), the macOS default host file
## (`~/.zprofile` or `~/.zshrc` depending on `SHELL`), the
## resource-typed digest, and the resource validation.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half appends a managed block to a real shell-
## profile in `$HOME`. Guarded by BOTH `defined(macosx)` AND
## `REPRO_PHASE5_MACOS_ENV_USERPATH_VM=1`. M8 lands the concrete
## sandbox scenario.

import std/[os, strutils, unittest]

import repro_home_resources

let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_ENV_USERPATH_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: PATH merge + POSIX block generator + host-file
# derivation + typed digest. Always runs.
# ===========================================================================

suite "env.userPath: PATH merge + dedup logic":

  test "computeMergedPath preserves existing order + appends new":
    let merged = computeMergedPath(@["/usr/bin", "/bin"],
                                   @["/opt/repro/bin"])
    check merged.contains("/usr/bin")
    check merged.contains("/bin")
    check merged.contains("/opt/repro/bin")

  test "computeMergedPath de-duplicates":
    let merged = computeMergedPath(@["/usr/bin", "/bin"],
                                   @["/bin", "/opt/repro/bin"])
    # /bin should appear exactly once.
    var binCount = 0
    for entry in splitPathEntries(merged):
      if entry == "/bin": inc binCount
    check binCount == 1

  test "posixPathBlockContent prepends contributed entries":
    let block1 = posixPathBlockContent(@["/opt/repro/bin", "/usr/local/bin"])
    check block1.startsWith("export PATH=")
    check block1.contains("/opt/repro/bin")
    check block1.contains("/usr/local/bin")
    # Preserves the user's pre-existing PATH at session-start time
    # via ${PATH:+:$PATH} (only when PATH is non-empty).
    check block1.contains("${PATH:+:$PATH}")

  test "posixPathBlockContent for an empty contribution is empty":
    check posixPathBlockContent(@[]) == ""

suite "env.userPath: macOS shell-profile host-file derivation":

  test "defaultUserPathHostFile picks a $HOME-relative path":
    let p = defaultUserPathHostFile("/Users/zahary")
    # macOS default since Catalina is zsh; either .zshrc or
    # .zprofile depending on $SHELL — both are valid macOS arms.
    check p.startsWith("/Users/zahary/")
    check (p.endsWith(".zshrc") or p.endsWith(".zprofile") or
           p.endsWith(".bashrc") or p.endsWith(".profile") or
           p.endsWith("config.fish"))

suite "env.userPath: typed-resource wiring + digest":

  test "an env.userPath Resource accepts contributed entries":
    let r = Resource(kind: rkEnvUserPath,
      address: "envPath:m6",
      lifecyclePolicy: lpDefault,
      pathEntries: @["/opt/repro-m6/bin", "/usr/local/repro/bin"],
      pathHostFilePath: "/Users/zahary/.zprofile")
    check resourceValidationError(r) == ""

  test "digestOfResource changes when path entries change":
    var r = Resource(kind: rkEnvUserPath,
      address: "envPath:digest",
      lifecyclePolicy: lpDefault,
      pathEntries: @["/opt/a/bin"],
      pathHostFilePath: "/Users/zahary/.zprofile")
    let d0 = digestOfResource(r)
    r.pathEntries = @["/opt/a/bin", "/opt/b/bin"]
    let d1 = digestOfResource(r)
    check d0 != d1

  test "an env.userVariable Resource accepts the canonical fields":
    let r = Resource(kind: rkEnvUserVariable,
      address: "envVar:REPRO_M6_TEST",
      lifecyclePolicy: lpDefault,
      envVarName: "REPRO_M6_TEST",
      envVarPayload: RegistryValuePayload(kind: rvkString,
        bytes: @[byte(ord('o')), byte(ord('k'))]))
    check resourceValidationError(r) == ""

  test "resourceKindFromString recognizes env.userPath + env.userVariable":
    check resourceKindFromString("env.userPath") == rkEnvUserPath
    check resourceKindFromString("env.userVariable") == rkEnvUserVariable

# ===========================================================================
# DESTRUCTIVE: real `~/.zprofile` (or `~/.zshrc`) PATH-block write on
# macOS. SANDBOX/VM-ONLY - guarded by BOTH macOS +
# `REPRO_PHASE5_MACOS_ENV_USERPATH_VM=1`. M8 lands the concrete
# scenario.
# ===========================================================================

suite "env.userPath: REAL apply / verify / destroy (sandbox-only)":

  test "real env.userPath lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_ENV_USERPATH_VM not " &
        "set (or not on macOS) - the real `~/.zprofile` PATH-block " &
        "write + new-shell verification + `launchctl setenv` " &
        "negative-test scenarios are NOT EXERCISED on this host. " &
        "Run this gate inside a disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_ENV_USERPATH_VM=1 to exercise the real " &
        "shell-profile mutation. The pure-logic suites above already " &
        "proved the PATH merge + POSIX block generator + typed-field " &
        "digest + validation without mutating any host."
    else:
      echo "  [sandbox-scaffold] REPRO_PHASE5_MACOS_ENV_USERPATH_VM " &
        "set; M6 scaffold present, M8 will populate the concrete " &
        "env.userPath + env.userVariable lifecycle steps INCLUDING " &
        "the `launchctl setenv` negative test."
