## M7 + M8 + M9 + M10 + M11 + M13 host-side runner: drive the macOS
## Phase-5 driver-validation gates inside a Tart-managed macOS guest.
##
## Per the M7 + M8 + M9 + M10 + M11 + M13 deliverables, fourteen gates
## need their destructive halves exercised inside a real macOS VM:
##
##   1. fs.systemFile        — tests/e2e/m69/t_e2e_repro_infra_fs_system_file.nim
##                             + REPRO_PHASE5_MACOS_FS_VM=1 (M7; driver-direct
##                             arm; reuses M69 file per M6 decision but
##                             gates a NEW macOS-specific destructive suite
##                             that does not need the broker / `repro`
##                             binary).
##   2. fs.userFile          — tests/e2e/macos-phase5/
##                             t_e2e_macos_phase5_fs_user_file.nim
##                             + REPRO_PHASE5_MACOS_FS_USERFILE_VM=1 (M7).
##   3. fs.managedBlock      — tests/e2e/macos-phase5/
##                             t_e2e_macos_phase5_fs_managed_block.nim
##                             + REPRO_PHASE5_MACOS_FS_MANAGEDBLOCK_VM=1 (M7).
##   4. env.userPath/Variable — tests/e2e/macos-phase5/
##                             t_e2e_macos_phase5_env_user_path.nim
##                             + REPRO_PHASE5_MACOS_ENV_VM=1 (M8; PATH +
##                             variable via `~/.zprofile`, new login-shell
##                             verification, negative-launchctl assertion).
##   5. shell.integration    — tests/e2e/macos-phase5/
##                             t_e2e_macos_phase5_shell_integration.nim
##                             + REPRO_PHASE5_MACOS_SHELL_VM=1 (M8; direnv
##                             hook applied to `~/.zshrc`, new interactive-
##                             shell verification of `_direnv_hook` in
##                             `precmd_functions`).
##   6. macos.systemDefault  — tests/e2e/macos-phase5/
##                             t_e2e_macos_phase5_macos_system_default.nim
##                             + REPRO_PHASE5_MACOS_DEFAULTS_VM=1 (M9;
##                             `defaults write /Library/Preferences/<test
##                             domain>` apply / re-apply (no-op) / destroy
##                             round-trip; needs root because the system-
##                             scope plist lands under /Library/Preferences/).
##   7. os.timezone          — tests/e2e/macos-phase5/
##                             t_e2e_macos_phase5_os_timezone.nim
##                             + REPRO_PHASE5_MACOS_TZ_VM=1 (M9;
##                             `systemsetup -settimezone` apply +
##                             out-of-band `systemsetup -gettimezone`
##                             verification + restore prior; needs root).
##   8. os.hostname          — tests/e2e/macos-phase5/
##                             t_e2e_macos_phase5_os_hostname.nim
##                             + REPRO_PHASE5_MACOS_HOSTNAME_VM=1 (M9;
##                             `scutil --set ComputerName/HostName/
##                             LocalHostName` triple-slot apply + out-of-
##                             band `scutil --get` verification that ALL
##                             three slots are synchronized; needs root).
##   9. launchd.systemDaemon — tests/e2e/macos-phase5/
##                             t_e2e_macos_phase5_launchd_system_daemon.nim
##                             + REPRO_PHASE5_MACOS_LAUNCHD_DAEMON_VM=1 (M10;
##                             writes a disposable `/Library/LaunchDaemons/
##                             <label>.plist` + `launchctl bootstrap system`,
##                             verifies via out-of-band `launchctl print
##                             system/<label>`, destroys via the driver
##                             and asserts no orphaned plists; needs root
##                             because /Library/LaunchDaemons/ writes +
##                             `launchctl bootstrap system` are system-scope).
##  10. launchd.userAgent    — tests/e2e/macos-phase5/
##                             t_e2e_macos_phase5_launchd_user_agent.nim
##                             + REPRO_PHASE5_MACOS_LAUNCHD_AGENT_VM=1 (M10;
##                             writes a disposable `~/Library/LaunchAgents/
##                             <label>.plist` + `launchctl bootstrap gui/
##                             <uid>`, verifies via out-of-band `launchctl
##                             print gui/<uid>/<label>`, destroys and
##                             asserts no orphans; runs as the cirruslabs
##                             admin user — NOT under sudo — because
##                             agents live in the gui/<uid> domain).
##  11. passwd.user (macOS)  — tests/e2e/m69/
##                             t_e2e_repro_infra_passwd_user_safe_destroy.nim
##                             + REPRO_M69_PASSWD_VM=1 (M11; REUSES the
##                             existing M69 gate per the M6 punch-list —
##                             the gate's destructive half is already
##                             guarded by `(defined(linux) or
##                             defined(macosx))` AND the macOS arm of the
##                             driver was shipped earlier with `dscl . -read
##                             /Users/<name>` + `sysadminctl -addUser` +
##                             `dseditgroup` for extraGroups. M11 validates
##                             that macOS arm in Tart for the first time;
##                             ALSO implicitly re-validates the M82 post-
##                             apply canonicalization fix on macOS — the
##                             gate's create / safe-destroy cycle exercises
##                             the masked-by-desired canonical-state digest
##                             code path the M82 fix corrected. Needs root
##                             because dscl + sysadminctl mutations land in
##                             /var/db/dslocal and need system privileges).
##  12. passwd.group (macOS) — tests/e2e/macos-phase5/
##                             t_e2e_macos_phase5_passwd_group.nim
##                             + REPRO_PHASE5_MACOS_PASSWD_GROUP_VM=1 (M11;
##                             NEW destructive scenario AND M11 ships the
##                             driver's macOS arm — see
##                             libs/repro_elevation/src/repro_elevation/
##                             posix_system_driver.nim, the
##                             `when defined(macosx)` branch of
##                             `applyPasswdGroup` / `destroyPasswdGroup` /
##                             `observePasswdGroupRaw` added by M11. Uses
##                             `dscl . -create /Groups/<name>` +
##                             `PrimaryGroupID` computation +
##                             `dseditgroup` for membership + `dscl . -delete
##                             /Groups/<name>` for destroy; out-of-band
##                             `dscl . -read /Groups/<name>` + `dseditgroup
##                             -o read` witnesses verify the group's
##                             registration. Asserts the driver does NOT
##                             use `groupadd` (which is absent on stock
##                             macOS — a `which groupadd` precondition
##                             check makes the negative assertion
##                             constructive). Needs root because dscl
##                             mutations to /Local/Default/Groups are
##                             system-scope).
##  13. pkg.homebrewFormula  — tests/e2e/macos-phase5/
##                             t_e2e_macos_phase5_homebrew_formula.nim
##                             + REPRO_PHASE5_MACOS_BREW_FORMULA_VM=1 (M13;
##                             NEW destructive scenario for the existing
##                             driver — see libs/repro_homebrew_adapter/
##                             src/repro_homebrew_adapter/formula.nim,
##                             shipped pre-M13 as part of M83 step 9
##                             Driver A. Uses the generic open-source
##                             fixture `jq`: `brew install jq` apply /
##                             re-apply (no-op) / `brew uninstall jq`
##                             destroy round-trip with out-of-band
##                             `brew list --formula --versions jq` +
##                             `<prefix>/bin/jq` symlink check; runs as
##                             the cirruslabs admin user — NOT under
##                             sudo — because Homebrew installs unelevated
##                             under the user-writable prefix (/opt/
##                             homebrew on Apple Silicon, /usr/local on
##                             Intel)).
##  14. pkg.homebrewCask     — tests/e2e/macos-phase5/
##                             t_e2e_macos_phase5_homebrew_cask.nim
##                             + REPRO_PHASE5_MACOS_BREW_CASK_VM=1 (M13;
##                             NEW destructive scenario for the existing
##                             driver — see libs/repro_homebrew_adapter/
##                             src/repro_homebrew_adapter/cask.nim,
##                             shipped pre-M13 as part of M83 step 9
##                             Driver B. Uses the generic open-source
##                             font fixture `font-fira-code`:
##                             `brew install --cask font-fira-code`
##                             apply / re-apply (no-op) / `brew uninstall
##                             --cask font-fira-code` destroy round-trip
##                             with out-of-band `brew list --cask
##                             --versions font-fira-code` + ~/Library/
##                             Fonts/FiraCode*.ttf font-drop check;
##                             runs as the cirruslabs admin user — NOT
##                             under sudo — because Homebrew Cask
##                             installs unelevated and drops fonts under
##                             the user's ~/Library/Fonts/).
##
## For each gate:
##   1. Cross-build the gate binary on the host (arm64 macOS host →
##      arm64 macOS guest; same arch, same OS, so a plain `nim c
##      --os:macosx` produces a binary the guest can execute).
##   2. Invoke `vm-harness run --backend tart-macos` with --copy-to to
##      stage the binary into the guest at /tmp/<gate>.
##   3. Run the gate inside the guest (via the cirruslabs admin user)
##      with the appropriate env var; the fs.systemFile gate is
##      additionally wrapped in `sudo -E -n` so the destructive arm
##      can write under /etc/.
##   4. Verify the gate's RESULT.txt shows PASS, the DONE sentinel
##      exists, and the captured exit code is 0.
##
## Skips cleanly on non-macOS hosts or when tart / sshpass are
## missing. Honors `VMH_TART_SKIP_MACOS=1` to opt out on
## space-constrained CI (the cirruslabs macOS golden is multi-GB).
##
## Run with:
##   nim c -r --threads:on tests/e2e/macos-phase5/run_phase5_in_tart.nim
##
## Exit code 0 = all 14 gates PASS; non-zero = at least one gate
## failed (which one is logged to stderr).

import std/[options, os, osproc, sequtils, strutils, tables, tempfiles,
            times, unittest]

when not defined(macosx):
  echo "[skip] run_phase5_in_tart: macOS host required"
  quit(0)

# ---------------------------------------------------------------------------
# Configuration. We resolve paths relative to the repo root so the runner
# is invocable from any cwd.

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

const VmHarnessBin = "/Users/zahary/metacraft/vm-harness/build/bin/vm-harness"

type
  GateSpec = object
    name: string            ## short identifier used in paths + output
    sourcePath: string      ## relative-to-repo-root Nim test source
    envVar: string          ## env var to set inside the guest
    needsRoot: bool         ## true → wrap in `sudo -E -n` in guest
    timeoutSec: int         ## per-gate timeout (vm-harness exec)

let Gates = @[
  GateSpec(
    name: "fs-systemfile",
    sourcePath: "tests/e2e/m69/t_e2e_repro_infra_fs_system_file.nim",
    envVar: "REPRO_PHASE5_MACOS_FS_VM",
    needsRoot: true,                    # writes under /etc/
    timeoutSec: 180),
  GateSpec(
    name: "fs-userfile",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_fs_user_file.nim",
    envVar: "REPRO_PHASE5_MACOS_FS_USERFILE_VM",
    needsRoot: false,                   # writes under $HOME
    timeoutSec: 180),
  GateSpec(
    name: "fs-managedblock",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_fs_managed_block.nim",
    envVar: "REPRO_PHASE5_MACOS_FS_MANAGEDBLOCK_VM",
    needsRoot: false,                   # writes under $HOME
    timeoutSec: 180),
  GateSpec(
    name: "env-userpath",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_env_user_path.nim",
    envVar: "REPRO_PHASE5_MACOS_ENV_VM",
    needsRoot: false,                   # writes under $HOME (~/.zprofile)
    # Includes new-shell verification (zsh -l spawn) + launchctl probe.
    timeoutSec: 240),
  GateSpec(
    name: "shell-integration",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_shell_integration.nim",
    envVar: "REPRO_PHASE5_MACOS_SHELL_VM",
    needsRoot: false,                   # writes under $HOME (~/.zshrc)
    # Includes `brew install direnv` fallback + interactive zsh spawn;
    # `brew install` is the long pole on a cold guest.
    timeoutSec: 600),
  GateSpec(
    name: "macos-systemdefault",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_macos_system_default.nim",
    envVar: "REPRO_PHASE5_MACOS_DEFAULTS_VM",
    needsRoot: true,                    # writes /Library/Preferences/<dom>
    timeoutSec: 180),
  GateSpec(
    name: "os-timezone",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_os_timezone.nim",
    envVar: "REPRO_PHASE5_MACOS_TZ_VM",
    needsRoot: true,                    # systemsetup -settimezone needs root
    timeoutSec: 180),
  GateSpec(
    name: "os-hostname",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_os_hostname.nim",
    envVar: "REPRO_PHASE5_MACOS_HOSTNAME_VM",
    needsRoot: true,                    # scutil --set needs root
    timeoutSec: 180),
  GateSpec(
    name: "launchd-systemdaemon",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_launchd_system_daemon.nim",
    envVar: "REPRO_PHASE5_MACOS_LAUNCHD_DAEMON_VM",
    needsRoot: true,                    # /Library/LaunchDaemons/ + bootstrap system
    timeoutSec: 180),
  GateSpec(
    name: "launchd-useragent",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_launchd_user_agent.nim",
    envVar: "REPRO_PHASE5_MACOS_LAUNCHD_AGENT_VM",
    needsRoot: false,                   # ~/Library/LaunchAgents/ + bootstrap gui/<uid>
    timeoutSec: 180),
  GateSpec(
    name: "passwd-user",
    sourcePath: "tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim",
    envVar: "REPRO_M69_PASSWD_VM",      # REUSES the existing M69 env var
    needsRoot: true,                    # dscl + sysadminctl are system-scope
    # sysadminctl -addUser on a fresh macOS guest is the slow step
    # (account-creation triggers the user-template copy + the
    # Spotlight-index registration for the new home dir); budget
    # 240s like env-userpath.
    timeoutSec: 240),
  GateSpec(
    name: "passwd-group",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_passwd_group.nim",
    envVar: "REPRO_PHASE5_MACOS_PASSWD_GROUP_VM",
    needsRoot: true,                    # dscl mutations to /Local/Default/Groups
    timeoutSec: 180),
  GateSpec(
    name: "homebrew-formula",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_homebrew_formula.nim",
    envVar: "REPRO_PHASE5_MACOS_BREW_FORMULA_VM",
    needsRoot: false,                   # brew runs unelevated as the admin user
    # `brew install jq` on a cold cirruslabs guest can take a minute
    # if Homebrew decides to refresh its index; once the bottle is
    # cached the install is sub-10s. Budget 600s like shell-integration
    # which has the same brew-install dependency.
    timeoutSec: 600),
  GateSpec(
    name: "homebrew-cask",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_homebrew_cask.nim",
    envVar: "REPRO_PHASE5_MACOS_BREW_CASK_VM",
    needsRoot: false,                   # brew --cask runs unelevated
    # `brew install --cask font-fira-code` pulls a small ~5 MB bottle
    # plus font installation under ~/Library/Fonts/. Same 600s budget
    # as the formula gate (the index-refresh dominates on a cold guest).
    timeoutSec: 600)]

# ---------------------------------------------------------------------------
# Build phase — one binary per gate.

proc buildGateBinary(gate: GateSpec; outDir: string): string =
  ## Compile the gate's Nim source into a self-contained binary at
  ## `<outDir>/<name>-gate`. Returns the path to the binary. Raises
  ## IOError on build failure.
  let src = ProjectRoot / gate.sourcePath
  doAssert fileExists(src),
    "gate source missing: " & src
  let binPath = outDir / (gate.name & "-gate")
  let nimcache = outDir / ("nimcache-" & gate.name)
  createDir(nimcache)
  echo "  [build] " & gate.name & " → " & binPath
  let buildStart = epochTime()
  let cmd = @["nim", "c",
              "--hints:off",
              "--warning:UnusedImport:off",
              "--warning:CaseTransition:off",
              "--threads:on",
              "-d:release",
              "--nimcache:" & nimcache,
              "--out:" & binPath,
              src]
  let proc1 = startProcess(cmd[0], workingDir = ProjectRoot,
                          args = cmd[1 .. ^1],
                          options = {poUsePath, poStdErrToStdOut,
                                     poParentStreams})
  let exitCode = proc1.waitForExit()
  proc1.close()
  let elapsedMs = int((epochTime() - buildStart) * 1000)
  if exitCode != 0:
    raise newException(IOError,
      "build failed for gate " & gate.name & " (exit " & $exitCode &
      "); see stderr for nim output")
  doAssert fileExists(binPath),
    "build claimed success but binary missing: " & binPath
  echo "  [build-ok] " & gate.name & " (" & $elapsedMs & " ms)"
  binPath

# ---------------------------------------------------------------------------
# vm-harness invocation. Per the M7 prompt's authoring pattern, we use
# the vm-harness CLI (the same one the M2 baseline tests use) rather
# than embedding the Nim library, so the runner is a thin wrapper that
# is auditable end-to-end.

type
  GateRunResult = object
    gateName: string
    verdict: string         ## "PASS" / "FAIL" / "ERROR" / "INCOMPLETE"
    exitCode: int
    elapsedMs: int
    outputDir: string

proc runGateInTart(gate: GateSpec; binPath, outDir: string): GateRunResult =
  ## Invoke `vm-harness run --backend tart-macos`. The gate binary is
  ## copied into the guest at /tmp/<name>-gate; the guest-side command
  ## sets the env var and (for fs.systemFile) elevates via sudo. The
  ## DONE sentinel + RESULT.txt are inspected after the run completes.
  let guestBin = "/tmp/" & gate.name & "-gate"
  # Build the guest-side command. We wrap the binary in `env` so the
  # gate's env var is set explicitly without trampling on the
  # cirruslabs guest's PATH / HOME. For root-requiring gates we
  # additionally prefix `sudo -E -n` (passwordless sudo on the
  # cirruslabs admin user; -E preserves the env var, -n fails fast
  # rather than prompting).
  var guestCmd: seq[string]
  if gate.needsRoot:
    guestCmd = @["sudo", "-E", "-n",
                 "env", gate.envVar & "=1", guestBin]
  else:
    guestCmd = @["env", gate.envVar & "=1", guestBin]
  let args = @[VmHarnessBin, "run",
               "--backend", "tart-macos",
               "--guest", "macos",
               "--baseline", "phase5-" & gate.name,
               "--source-image", "ghcr.io/cirruslabs/macos-tahoe-base:latest",
               "--cpus", "4",
               "--memory-mb", "8192",
               "--disk-gb", "80",
               "--output-dir", outDir,
               "--copy-to", binPath & ":" & guestBin,
               "--timeout-sec", $gate.timeoutSec,
               "--"] & guestCmd
  echo "  [vm-harness] gate=" & gate.name & " output=" & outDir
  let runStart = epochTime()
  let proc1 = startProcess(args[0], args = args[1 .. ^1],
                           options = {poUsePath, poStdErrToStdOut,
                                      poParentStreams})
  let exit = proc1.waitForExit()
  proc1.close()
  let elapsedMs = int((epochTime() - runStart) * 1000)

  # Inspect the output envelope to extract the verdict. The harness
  # writes RESULT.txt + DONE in <outputDir>; the DONE sentinel
  # contains the verdict text on the first line.
  var verdict = "ERROR"
  let donePath = outDir / "DONE"
  if fileExists(donePath):
    verdict = readFile(donePath).strip()
  GateRunResult(gateName: gate.name,
                verdict: verdict,
                exitCode: exit,
                elapsedMs: elapsedMs,
                outputDir: outDir)

# ---------------------------------------------------------------------------
# Pre-flight: tart + sshpass + the cirruslabs golden cached.

proc checkPrerequisites(): bool =
  if findExe("tart").len == 0:
    echo "[skip] tart not on PATH"
    return false
  if findExe("sshpass").len == 0:
    echo "[skip] sshpass not on PATH"
    return false
  if not fileExists(VmHarnessBin):
    echo "[skip] vm-harness binary missing at " & VmHarnessBin &
      " — build it via `nim c` in vm-harness repo first"
    return false
  if getEnv("VMH_TART_SKIP_MACOS", "") == "1":
    echo "[skip] VMH_TART_SKIP_MACOS=1 set; macOS golden pull is " &
      "multi-GB and may exceed CI disk budgets"
    return false
  true

# ---------------------------------------------------------------------------
# Entry point.

proc main(): int =
  if not checkPrerequisites():
    return 0          # graceful skip — not a failure

  let workRoot = createTempDir("repro-m7-phase5-", "")
  echo "[m7-runner] workRoot=" & workRoot
  echo "[m7-runner] ProjectRoot=" & ProjectRoot
  echo "[m7-runner] vm-harness=" & VmHarnessBin

  # 1. Build all gate binaries up front so we fail fast on any build
  #    error before incurring the multi-minute Tart provisioning cost.
  var binaries: Table[string, string]
  for gate in Gates:
    let buildDir = workRoot / ("build-" & gate.name)
    createDir(buildDir)
    let binPath = buildGateBinary(gate, buildDir)
    binaries[gate.name] = binPath

  # 2. Run each gate sequentially in its own ephemeral Tart guest.
  #    Per-gate revert via Tart is ~6-13s per M2 measurements; total
  #    budget per gate ≤90s once the golden is cached.
  var results: seq[GateRunResult]
  var anyFail = false
  for gate in Gates:
    let outDir = workRoot / ("output-" & gate.name)
    createDir(outDir)
    let r = runGateInTart(gate, binaries[gate.name], outDir)
    results.add(r)
    echo "  [result] " & gate.name & ": verdict=" & r.verdict &
      " exit=" & $r.exitCode & " elapsed=" & $r.elapsedMs & "ms"
    if r.verdict != "PASS" or r.exitCode != 0:
      anyFail = true
      # Dump the gate's RESULT.txt + the last 80 lines of the
      # command-run capture for diagnostics.
      let resultPath = outDir / "RESULT.txt"
      if fileExists(resultPath):
        echo "    ---- RESULT.txt ----"
        echo readFile(resultPath)
      let cmdRunPath = outDir / "01-command-run.txt"
      if fileExists(cmdRunPath):
        echo "    ---- 01-command-run.txt (tail) ----"
        let lines = readFile(cmdRunPath).splitLines()
        let tail = lines[max(0, lines.len - 80) ..< lines.len]
        for ln in tail: echo "      " & ln

  echo ""
  echo "[m7-runner] Summary:"
  for r in results:
    echo "  " & r.gateName & ": " & r.verdict &
      " (exit " & $r.exitCode & ", " & $r.elapsedMs & "ms)"

  if anyFail:
    echo "[m7-runner] FAIL — at least one gate did not PASS"
    return 1
  echo "[m7-runner] OK — all " & $Gates.len &
    " Phase-5 driver-validation gates PASS in Tart " &
    "(M7 fs.* primitives + M8 env / shell.integration arms + " &
    "M9 macos.systemDefault / os.timezone / os.hostname arms + " &
    "M10 launchd.systemDaemon / launchd.userAgent arms + " &
    "M11 passwd.user (REUSES M69 gate) / passwd.group (NEW driver arm + scenario) + " &
    "M13 pkg.homebrewFormula (jq) / pkg.homebrewCask (font-fira-code))"
  return 0

quit(main())
