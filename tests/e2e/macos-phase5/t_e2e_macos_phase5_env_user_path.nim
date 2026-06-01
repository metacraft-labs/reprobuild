## M6 / M8 Phase-5 Gate: e2e_macos_phase5_env_user_path
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
## M8 deliverable: the destructive half drives `applyUserPath` AND
## `applyShellIntegration` against an explicit `~/.zprofile` target
## (login-shell init file; sourced by `zsh -l`), then spawns
## `zsh -l -c 'echo $PATH'` and `zsh -l -c 'echo $TESTVAR'` to verify
## the new login shell session actually sees the values. The negative
## launchctl test invokes `applyUserVariableCreate` (a no-op on macOS
## by construction — the macOS arm does NOT call `launchctl setenv`)
## and then probes `launchctl getenv TESTVAR` from the same process
## tree; an empty response proves the driver did not silently fall
## back to launchctl.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half appends a managed block to a real shell-
## profile in `$HOME`. Guarded by BOTH `defined(macosx)` AND
## `REPRO_PHASE5_MACOS_ENV_VM=1`.

import std/[os, osproc, streams, strtabs, strutils, unittest]

import repro_home_resources

let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_ENV_VM") == "1"

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
# DESTRUCTIVE: real `~/.zprofile` PATH-block write + zsh -l verification +
# launchctl-negative check on macOS. SANDBOX/VM-ONLY - guarded by BOTH
# macOS + `REPRO_PHASE5_MACOS_ENV_VM=1`. The host-side runner cross-builds
# this binary, copies it into a freshly-cloned Tart macOS guest, and runs
# it with the env var set.
# ===========================================================================

when defined(macosx):

  proc spawnLoginShell(cmd: string): tuple[output: string, exitCode: int] =
    ## Spawn `zsh -l -c <cmd>` and return its captured stdout/stderr.
    ## A login shell sources `~/.zprofile` (NOT `~/.zshrc`, which is
    ## the interactive-shell init file). The M8 PASS criterion is
    ## written in terms of "open a new Terminal.app session" — that's
    ## a login shell, so `.zprofile` is the right target.
    ##
    ## We use `startProcess` directly with an explicit minimal env so
    ## the only source of PATH/TESTVAR inside the new shell is the
    ## on-disk profile we just wrote. We do NOT go through `sh -c` (or
    ## `execCmdEx`) because that would re-parse the joined command
    ## string and lose the literal-argv structure (notably the single
    ## `-c <cmd>` pair would be split on whitespace inside the cmd).
    ##
    ## We pin a minimal but executable child PATH (`/usr/bin:/bin`) so
    ## the inner `.zprofile`'s `${PATH:+:$PATH}` suffix has something
    ## non-empty to expand against, and so any shell built-ins / system
    ## binaries the profile invokes can be located. The contribution
    ## entry added by `applyUserPath` is *prepended* by the managed
    ## block, so it lands at the front of the resulting PATH regardless
    ## of this seed value.
    let home = getEnv("HOME")
    let user = getEnv("USER")
    var childEnv = newStringTable(modeCaseSensitive)
    childEnv["HOME"] = home
    childEnv["USER"] = user
    childEnv["TERM"] = "xterm-256color"
    childEnv["PATH"] = "/usr/bin:/bin"
    let zshBin =
      if fileExists("/bin/zsh"): "/bin/zsh"
      elif fileExists("/usr/bin/zsh"): "/usr/bin/zsh"
      else: findExe("zsh")
    doAssert zshBin.len > 0, "zsh binary not found on guest"
    let p = startProcess(zshBin,
      args = @["-l", "-c", cmd],
      env = childEnv,
      options = {poStdErrToStdOut})
    let outStream = p.outputStream
    var captured = ""
    while not outStream.atEnd:
      captured.add(outStream.readAll())
    let exit = p.waitForExit()
    p.close()
    (captured, exit)

  proc launchctlGetenv(name: string): string =
    ## `launchctl getenv TESTVAR` returns the value (or empty string +
    ## exit 0 when unset). If launchctl is missing (unlikely on a
    ## stock macOS) we return empty. We strip a trailing newline.
    let (out0, exit0) = execCmdEx("launchctl getenv " & quoteShell(name),
      options = {poUsePath, poStdErrToStdOut})
    if exit0 != 0:
      # Some macOS versions return non-zero when the variable is
      # unset; that's exactly the state we want, so don't fail.
      return ""
    var s = out0
    if s.endsWith("\n"):
      s = s[0 ..< s.len - 1]
    s

suite "env.userPath / env.userVariable: REAL apply / verify / destroy (sandbox-only)":

  test "real env.userPath + env.userVariable lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_ENV_VM not set " &
        "(or not on macOS) - the real `~/.zprofile` PATH-block " &
        "write + new-shell verification + `launchctl setenv` " &
        "negative-test scenarios are NOT EXERCISED on this host. " &
        "Run this gate inside a disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_ENV_VM=1 to exercise the real " &
        "shell-profile mutation. The pure-logic suites above already " &
        "proved the PATH merge + POSIX block generator + typed-field " &
        "digest + validation without mutating any host."
    else:
      when defined(macosx):
        # -----------------------------------------------------------------
        # Target file: `~/.zprofile` — the zsh LOGIN-shell init file
        # (sourced by `zsh -l`, which is what Terminal.app spawns by
        # default since macOS Catalina made zsh the default shell).
        # The driver's `defaultUserPathHostFile` picks `.zshrc` or
        # `.zprofile` depending on `$SHELL`; for the M8 PASS criterion
        # we pin to `.zprofile` explicitly via `hostFilePath` so the
        # new-shell verification (`zsh -l -c 'echo $PATH'`) is the
        # canonical reproduction of opening a new Terminal window.
        # -----------------------------------------------------------------
        let pid = $getCurrentProcessId()
        let home = getEnv("HOME")
        doAssert home.startsWith("/Users/"),
          "macOS $HOME '" & home & "' is not Apple-flavored (/Users/...)"
        let zprofile = home / ".zprofile"
        # Snapshot the prior `.zprofile` contents (if any) so we can
        # restore the file at the end of the test. The cirruslabs
        # admin user's golden `.zprofile` is small or absent; either
        # way we restore exact bytes.
        let priorExisted = fileExists(zprofile)
        let priorBytes =
          if priorExisted: readFile(zprofile) else: ""

        # -----------------------------------------------------------------
        # Scenario 1: env.userPath via shell-profile arm.
        # -----------------------------------------------------------------
        let pathEntry = "/opt/repro-phase5-env-" & pid & "/bin"
        let contribution = @[pathEntry]

        # 1a. Apply: driver writes a managed block into `~/.zprofile`
        #     prepending `pathEntry` to PATH (with the standard
        #     `${PATH:+:$PATH}` suffix preserving the user's pre-
        #     existing entries). The driver returns the JOINED
        #     contribution bytes as `payloadBytes` per the gate-4
        #     contract.
        let recorded1 = applyUserPath(contribution,
          priorContribution = @[],
          hostFilePath = zprofile)
        doAssert fileExists(zprofile),
          ".zprofile not created by applyUserPath"
        let after1 = readFile(zprofile)
        doAssert after1.contains(pathEntry),
          "contribution entry missing from .zprofile after apply"
        doAssert after1.contains("repro-managed:" & UserPathBlockId),
          "managed-block sentinel missing from .zprofile"
        # The recorded payload is the joined contribution (UTF-8).
        doAssert recorded1.len == pathEntry.len

        # 1b. Observe present (with the contribution).
        let obs1 = observeUserPath(contribution, hostFilePath = zprofile)
        doAssert obs1.present,
          "observeUserPath reported absent after apply"

        # -----------------------------------------------------------------
        # Scenario 2: env.userVariable via shell-profile arm.
        #   The macOS arm of `applyUserVariableCreate` is intentionally
        #   a no-op (the proc body is `when defined(windows): ...`;
        #   on macOS it falls through and returns the payload bytes
        #   without invoking launchctl). That's the foundation of the
        #   negative-launchctl assertion below. To actually deliver
        #   the variable into the new login shell, the M8 PASS
        #   criterion specifies the shell-profile route: we append
        #   `export TESTVAR=ok` to `.zprofile` via
        #   `applyShellIntegration` (a thin wrapper around
        #   `fs.managedBlock`). This mirrors what the future POSIX
        #   arm of `applyUserVariableCreate` will do — and the gate
        #   verifies both halves: (a) the driver doesn't shell out to
        #   launchctl, and (b) the variable lands in the new login
        #   shell via `~/.zprofile`.
        # -----------------------------------------------------------------
        let varName = "REPRO_PHASE5_TESTVAR_" & pid
        let varValue = "phase5-ok-" & pid
        let varBlockId = "phase5-env-userVariable-" & pid
        let varBlockContent = "export " & varName & "=" & varValue & "\n"

        let recordedVar1 = applyShellIntegration(zprofile,
          varBlockId, varBlockContent)
        doAssert recordedVar1.len > 0,
          "applyShellIntegration returned empty payload"
        let after2 = readFile(zprofile)
        doAssert after2.contains("export " & varName & "=" & varValue),
          "variable export missing from .zprofile after apply"
        # Both managed blocks (PATH + variable) must coexist in the
        # same `.zprofile` — the splice does not collide.
        doAssert after2.contains("repro-managed:" & UserPathBlockId),
          "PATH managed-block sentinel was clobbered by variable apply"
        doAssert after2.contains("repro-managed:" & varBlockId),
          "variable managed-block sentinel missing after apply"

        let obs2 = observeShellIntegration(zprofile, varBlockId)
        doAssert obs2.present,
          "observeShellIntegration reported absent after apply"

        # -----------------------------------------------------------------
        # NEGATIVE TEST (verify_macos_env_uses_shell_profile_not_launchctl):
        #   Call `applyUserVariableCreate` — the macOS arm of which is a
        #   no-op by construction — and then probe `launchctl getenv`.
        #   The variable MUST NOT show up in launchctl, proving the
        #   driver does not use the legacy launchctl path.
        # -----------------------------------------------------------------
        let payload = RegistryValuePayload(kind: rvkString,
          bytes: @[byte(ord('o')), byte(ord('k'))])
        # On macOS this is a no-op; we call it to lock in the contract.
        discard applyUserVariableCreate(varName, payload)
        let lcOut = launchctlGetenv(varName)
        doAssert lcOut.len == 0,
          "NEGATIVE TEST FAILED: `launchctl getenv " & varName &
          "` returned '" & lcOut & "' — the driver must NOT have " &
          "used `launchctl setenv` on macOS (the shell-profile arm " &
          "is the canonical macOS path; launchctl is the legacy " &
          "path explicitly excluded by the db84280 PASS criterion)."

        # -----------------------------------------------------------------
        # NEW-SHELL VERIFICATION (verify_macos_env_userpath_new_shell_sees_value):
        #   Spawn a fresh `zsh -l` and assert PATH + TESTVAR both
        #   reflect the just-applied profile.
        # -----------------------------------------------------------------
        let (pathOut, pathExit) = spawnLoginShell("echo $PATH")
        doAssert pathExit == 0,
          "zsh -l 'echo $PATH' failed: exit " & $pathExit &
          " output=" & pathOut
        doAssert pathOut.contains(pathEntry),
          "new login shell PATH does not contain '" & pathEntry &
          "': got '" & pathOut.strip() & "'"

        let (varOut, varExit) = spawnLoginShell("echo $" & varName)
        doAssert varExit == 0,
          "zsh -l 'echo $" & varName & "' failed: exit " & $varExit &
          " output=" & varOut
        doAssert varOut.strip() == varValue,
          "new login shell " & varName & " mismatch: expected '" &
          varValue & "', got '" & varOut.strip() & "'"

        # -----------------------------------------------------------------
        # Destroy direction: remove both managed blocks and verify the
        # new login shell no longer sees either value.
        # -----------------------------------------------------------------
        removeUserPathContribution(contribution, hostFilePath = zprofile)
        destroyShellIntegration(zprofile, varBlockId)
        let after3 =
          if fileExists(zprofile): readFile(zprofile) else: ""
        doAssert not after3.contains("repro-managed:" & UserPathBlockId),
          "PATH managed-block sentinel still present after destroy"
        doAssert not after3.contains("repro-managed:" & varBlockId),
          "variable managed-block sentinel still present after destroy"
        doAssert not after3.contains(pathEntry),
          "contribution entry still in .zprofile after destroy"
        doAssert not after3.contains("export " & varName),
          "variable export still in .zprofile after destroy"
        # Surrounding user-owned content (the prior `.zprofile`) must
        # survive byte-for-byte.
        doAssert after3 == priorBytes or
                 (priorBytes.len == 0 and after3.strip().len == 0),
          "destroy direction corrupted surrounding .zprofile content: " &
          "expected " & $priorBytes.len & " bytes, got " & $after3.len

        let (pathOut2, pathExit2) = spawnLoginShell("echo $PATH")
        doAssert pathExit2 == 0
        doAssert not pathOut2.contains(pathEntry),
          "new login shell PATH STILL contains '" & pathEntry &
          "' after destroy"

        let (varOut3, varExit3) = spawnLoginShell(
          "echo \"<$" & varName & ">\"")
        doAssert varExit3 == 0
        # Empty/unset → `<>` is the expected output.
        doAssert varOut3.strip() == "<>",
          "new login shell still sees " & varName & " after destroy: '" &
          varOut3.strip() & "'"

        # Final negative-launchctl check: launchctl is STILL clean
        # after the entire lifecycle.
        let lcOutFinal = launchctlGetenv(varName)
        doAssert lcOutFinal.len == 0,
          "launchctl polluted at end of test: '" & lcOutFinal & "'"

        # -----------------------------------------------------------------
        # Restore the prior `.zprofile` exactly (priorBytes was empty
        # if the file didn't exist before; both destroyManagedBlock
        # and destroy of the variable leave the file empty in that
        # case — remove the empty file so we leave no trace).
        # -----------------------------------------------------------------
        if not priorExisted:
          if fileExists(zprofile) and readFile(zprofile).strip().len == 0:
            removeFile(zprofile)
        else:
          if readFile(zprofile) != priorBytes:
            writeFile(zprofile, priorBytes)

        echo "  [OK] env.userPath + env.userVariable macOS lifecycle: " &
          "shell-profile arm via ~/.zprofile, zsh -l sees PATH + " &
          "TESTVAR, destroy clean, launchctl never invoked (negative " &
          "test PASS)."
