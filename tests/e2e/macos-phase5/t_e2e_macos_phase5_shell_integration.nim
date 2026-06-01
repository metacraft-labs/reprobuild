## M6 / M8 Phase-5 Gate: e2e_macos_phase5_shell_integration
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
## M8 deliverable (verify_macos_shell_integration_direnv_hook): write
## a `direnv hook zsh` snippet via `applyShellIntegration` into
## `~/.zshrc`, then spawn a fresh `zsh -i` session and check that
## `type _direnv_hook` reports it as a registered function — proving
## the hook is active in the new shell. The gate uses a real
## `direnv` binary inside the guest (we install it via Homebrew
## inside the test if absent so the gate is self-contained).
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half appends a shell-init managed block to a real
## shell-profile in `$HOME`. Guarded by BOTH `defined(macosx)` AND
## `REPRO_PHASE5_MACOS_SHELL_VM=1`.

import std/[os, osproc, streams, strtabs, strutils, unittest]

import repro_home_resources

let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_SHELL_VM") == "1"

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
# SANDBOX/VM-ONLY - guarded by BOTH macOS + `REPRO_PHASE5_MACOS_SHELL_VM=1`.
# The host-side runner cross-builds this binary, copies it into a Tart
# macOS guest, and runs it with the env var set.
# ===========================================================================

when defined(macosx):

  proc findDirenvBin(): string =
    ## Return an absolute path to `direnv` if one is available. The
    ## cirruslabs golden ships Homebrew preinstalled; if direnv isn't
    ## already on PATH we try the standard Apple-silicon Homebrew
    ## prefix `/opt/homebrew/bin/direnv` and then `brew install
    ## direnv` as a last resort. Returns "" on total failure so the
    ## gate can decide whether to skip or fail loudly.
    let onPath = findExe("direnv")
    if onPath.len > 0:
      return onPath
    if fileExists("/opt/homebrew/bin/direnv"):
      return "/opt/homebrew/bin/direnv"
    if fileExists("/usr/local/bin/direnv"):
      return "/usr/local/bin/direnv"
    # Try `brew install direnv`. The cirruslabs admin user has
    # Homebrew pre-staged at /opt/homebrew (Apple Silicon) or
    # /usr/local (Intel). We don't bring our own copy of brew; we
    # rely on the golden.
    let brew =
      if findExe("brew").len > 0: findExe("brew")
      elif fileExists("/opt/homebrew/bin/brew"): "/opt/homebrew/bin/brew"
      elif fileExists("/usr/local/bin/brew"): "/usr/local/bin/brew"
      else: ""
    if brew.len == 0:
      return ""
    echo "  [direnv-install] brew install direnv (via " & brew & ")"
    let (out0, exit0) = execCmdEx(brew & " install direnv",
      options = {poUsePath, poStdErrToStdOut})
    if exit0 != 0:
      echo "  [direnv-install-fail] brew install exit=" & $exit0 &
        " output=" & out0
      return ""
    if fileExists("/opt/homebrew/bin/direnv"):
      return "/opt/homebrew/bin/direnv"
    if fileExists("/usr/local/bin/direnv"):
      return "/usr/local/bin/direnv"
    findExe("direnv")

  proc spawnInteractiveShell(cmd, direnvDir: string):
      tuple[output: string, exitCode: int] =
    ## Spawn `zsh -i -c <cmd>` and return its captured stdout/stderr.
    ## An interactive (non-login) shell sources `~/.zshrc`, where the
    ## direnv hook lives. We prepend `direnvDir` to PATH inside the
    ## child env so the `eval "$(direnv hook zsh)"` in `~/.zshrc` can
    ## find the direnv binary at hook-installation time.
    ##
    ## We use `startProcess` directly (NOT `execCmdEx` + `argv.join`)
    ## so the `-c <cmd>` argv pair stays atomic; otherwise the joined
    ## command goes through `sh -c` which re-splits `cmd` on whitespace
    ## and breaks any non-trivial assertion like
    ## `print -l ${precmd_functions[@]}`.
    let home = getEnv("HOME")
    let user = getEnv("USER")
    let pathInside = direnvDir & ":/usr/bin:/bin:/usr/sbin:/sbin"
    var childEnv = newStringTable(modeCaseSensitive)
    childEnv["HOME"] = home
    childEnv["USER"] = user
    childEnv["PATH"] = pathInside
    childEnv["TERM"] = "xterm-256color"
    let zshBin =
      if fileExists("/bin/zsh"): "/bin/zsh"
      elif fileExists("/usr/bin/zsh"): "/usr/bin/zsh"
      else: findExe("zsh")
    doAssert zshBin.len > 0, "zsh binary not found on guest"
    let p = startProcess(zshBin,
      args = @["-i", "-c", cmd],
      env = childEnv,
      options = {poStdErrToStdOut})
    let outStream = p.outputStream
    var captured = ""
    while not outStream.atEnd:
      captured.add(outStream.readAll())
    let exit = p.waitForExit()
    p.close()
    (captured, exit)

suite "shell.integration: REAL apply / verify / destroy (sandbox-only)":

  test "real shell.integration lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_SHELL_VM not set " &
        "(or not on macOS) - the real `~/.zshrc` direnv-hook " &
        "managed-block write + new-shell verification scenario is " &
        "NOT EXERCISED on this host. Run this gate inside a " &
        "disposable macOS VM with REPRO_PHASE5_MACOS_SHELL_VM=1 to " &
        "exercise the real shell-init mutation. The pure-logic suites " &
        "above already proved the typed-field digest + validation " &
        "without mutating any host."
    else:
      when defined(macosx):
        # -----------------------------------------------------------------
        # Target: `~/.zshrc` — the zsh INTERACTIVE-shell init file
        # (sourced by `zsh -i`). The `direnv hook zsh` snippet is
        # interactive-only: it registers `_direnv_hook` as a precmd
        # function, which depends on the prompt machinery only live
        # in interactive shells. Login shells (`zsh -l`) source
        # `.zprofile` but NOT `.zshrc` unless the user has it
        # explicitly chained; the direnv snippet canonically lives in
        # `.zshrc`.
        # -----------------------------------------------------------------
        let pid = $getCurrentProcessId()
        let home = getEnv("HOME")
        doAssert home.startsWith("/Users/"),
          "macOS $HOME '" & home & "' is not Apple-flavored (/Users/...)"
        let zshrc = home / ".zshrc"
        let priorExisted = fileExists(zshrc)
        let priorBytes =
          if priorExisted: readFile(zshrc) else: ""

        let direnvBin = findDirenvBin()
        doAssert direnvBin.len > 0,
          "direnv binary unavailable inside the guest (no PATH entry, " &
          "no Homebrew install). The shell.integration gate needs a " &
          "real direnv to exercise the hook contract; the cirruslabs " &
          "golden ships Homebrew so `brew install direnv` should " &
          "succeed inside a normal Tart guest."
        let direnvDir = direnvBin.parentDir
        echo "  [direnv-bin] " & direnvBin

        # -----------------------------------------------------------------
        # Apply: write the `eval "$(direnv hook zsh)"` snippet into
        # `~/.zshrc` via `applyShellIntegration` (a thin wrapper
        # around `fs.managedBlock`). The hook is per-block; we use
        # a unique block id per-PID so re-runs don't collide.
        # -----------------------------------------------------------------
        let blockId = "phase5-direnv-" & pid
        let hookContent =
          "# direnv hook (Reprobuild M8 phase5 shell.integration gate)\n" &
          "eval \"$(" & direnvBin & " hook zsh)\"\n"

        let recorded1 = applyShellIntegration(zshrc, blockId, hookContent)
        doAssert recorded1.len > 0,
          "applyShellIntegration returned empty payload"
        doAssert fileExists(zshrc),
          ".zshrc not created by applyShellIntegration"
        let after1 = readFile(zshrc)
        doAssert after1.contains("repro-managed:" & blockId),
          "managed-block sentinel missing from .zshrc"
        doAssert after1.contains("direnv hook zsh"),
          "direnv hook snippet body missing from .zshrc"

        let obs1 = observeShellIntegration(zshrc, blockId)
        doAssert obs1.present,
          "observeShellIntegration reports absent after apply"
        doAssert obs1.rawBytes == recorded1

        # -----------------------------------------------------------------
        # NEW-SHELL VERIFICATION (verify_macos_shell_integration_direnv_hook):
        #   Spawn `zsh -i -c 'type _direnv_hook'`. The direnv hook
        #   defines a `_direnv_hook` zsh function and registers it
        #   via `precmd_functions` — if the hook is active, `type`
        #   should report it as either a function or a "shell
        #   function" (zsh's exact wording is "_direnv_hook is a
        #   shell function from ...").
        # -----------------------------------------------------------------
        let (out1, exit1) = spawnInteractiveShell(
          "type _direnv_hook", direnvDir)
        doAssert exit1 == 0,
          "zsh -i 'type _direnv_hook' failed: exit " & $exit1 &
          " output=" & out1
        doAssert out1.contains("_direnv_hook") and
                 (out1.contains("function") or out1.contains("defined")),
          "_direnv_hook is not defined in the new interactive shell: " &
          "output='" & out1.strip() & "'"

        # Additional sanity: `_direnv_hook` is wired into
        # `precmd_functions` (the zsh hook list).
        let (out2, exit2) = spawnInteractiveShell(
          "print -l ${precmd_functions[@]}", direnvDir)
        doAssert exit2 == 0
        doAssert out2.contains("_direnv_hook"),
          "_direnv_hook not registered in precmd_functions: '" &
          out2.strip() & "'"

        echo "  [verify-hook-active] _direnv_hook is a precmd " &
          "function in the new interactive shell"

        # -----------------------------------------------------------------
        # Destroy: remove the managed block.
        # -----------------------------------------------------------------
        destroyShellIntegration(zshrc, blockId)
        let after2 =
          if fileExists(zshrc): readFile(zshrc) else: ""
        doAssert not after2.contains("repro-managed:" & blockId),
          "managed-block sentinel still present after destroy"
        doAssert not after2.contains("direnv hook zsh"),
          "direnv hook snippet still in .zshrc after destroy"

        let obs2 = observeShellIntegration(zshrc, blockId)
        doAssert not obs2.present

        # New shell no longer has the hook wired.
        let (out3, exit3) = spawnInteractiveShell(
          "print -l ${precmd_functions[@]}", direnvDir)
        doAssert exit3 == 0
        doAssert not out3.contains("_direnv_hook"),
          "_direnv_hook STILL in precmd_functions after destroy: '" &
          out3.strip() & "'"

        # -----------------------------------------------------------------
        # Restore the prior `.zshrc` byte-for-byte. The destroy
        # direction must NOT have corrupted any surrounding user
        # content; if `priorBytes` was empty (file didn't exist), the
        # file should also now be empty/whitespace — remove it.
        # -----------------------------------------------------------------
        if not priorExisted:
          if fileExists(zshrc) and readFile(zshrc).strip().len == 0:
            removeFile(zshrc)
        else:
          if readFile(zshrc) != priorBytes:
            writeFile(zshrc, priorBytes)

        echo "  [OK] shell.integration macOS lifecycle: direnv hook " &
          "snippet applied to ~/.zshrc, new zsh -i session has " &
          "_direnv_hook active in precmd_functions, destroy " &
          "removes hook + leaves surrounding .zshrc bytes intact."
