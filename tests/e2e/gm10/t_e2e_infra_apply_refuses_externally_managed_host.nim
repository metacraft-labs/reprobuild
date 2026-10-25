## GM10: `repro infra plan` / `repro infra apply` / `repro system sync`
## refuse a host whose system scope the host registry says is managed
## elsewhere (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md
## §Hosts, feature 2; CLI/infra/apply.md §Hosts whose system is managed
## elsewhere).
##
## `e2e_infra_apply_refuses_externally_managed_host`, against the real
## `build/bin/repro`:
##
## A configuration directory holds a home profile (`home.nim`) whose `hosts:`
## registry declares
##
##   * `gm10-here`      -- system managed here (no `system:` key);
##   * `gm10-elsewhere` -- `system: managedElsewhere("example-org/gm10-infra")`;
##   * `gm10-nopointer` -- `system: managedElsewhere` (no pointer);
##
## and, beside it, a system profile (`system.nim`) whose only resource is an
## action edge that writes a marker file into the sandbox. The marker is the
## observable proof that an apply ran: it exists exactly when the system
## profile was applied.
##
## 1. Refusal. For `gm10-elsewhere`, `repro infra plan`, `repro infra apply
##    --no-preview`, `repro system sync` and `repro system rollback` (which
##    re-applies a generation) each exit 1 with a diagnostic that
##    names the host, the pointer and the registry, and change nothing: the
##    marker is absent, and the system state directory holds no plan,
##    generation, lock or current pointer (its tree, minus the profile
##    compile cache, is identical before and after). The host is found both
##    by `--host` and, without `--host`, by `$REPRO_HOST` (the identity
##    `repro home` uses). `gm10-nopointer` is refused too, saying that the
##    registry names no manager.
## 2. Negative control (the milestone's): the same profiles for `gm10-here`
##    -- `repro infra plan` exits 0 and reports the registry; `repro infra
##    apply --no-preview` exits 0, commits a generation and writes the marker.
##    An undeclared host plans as before, and the report says it is not
##    declared.
## 3. Which registry. A system profile in a directory without `home.nim` is
##    gated only by `--home-profile-dir`: without it the plan for
##    `gm10-elsewhere` proceeds and reports "registry: none" (no fallback to
##    the user's default home profile directory, which `$REPRO_HOME_PROFILE_DIR`
##    points at the same registry here -- so a fallback would show up as a
##    refusal); with it, the host is refused. A `--home-profile-dir` without
##    `home.nim` is an error.
## 4. Refusals of input that would otherwise be ignored: a system profile
##    whose own `hosts:` says `system: managedElsewhere` is refused (the
##    registry is the home profile's); a registry that does not compile is a
##    refusal, with nothing planned.
##
## Vacuity: the negative control's marker exists with the expected payload,
## so the action edge does run when nothing refuses -- the refusal cases'
## absent marker is caused by the refusal.
##
## Falsifying mutation (performed, see the GM10 milestone Verification):
## `managedElsewhereRefusal` returning "" (the planner ignoring the
## attribute) lets the apply proceed -- the refusal checks fail and the
## marker appears.
##
## No mocks: real `repro`, real Nim, real profile-compile edge, real apply
## of a real action edge whose only effect is a file inside the sandbox. The
## edge carries `requiresElevation = true`, as in
## `t_infra_apply_profile_without_live_state.nim`, so the engine hands it to
## the apply's broker closure instead of the monitored-spawn path; nothing
## prompts and nothing outside the sandbox is touched.
##
## Platforms: every host. Only the negative control's apply is POSIX-only:
## its marker edge runs `/bin/sh`, and on Windows an elevated edge goes
## through the elevation broker. On Windows that one step is skipped with its
## reason and everything else runs; eli-pc runs it under GM1w.

import std/[os, strutils, unittest]

import repro_test_support/reasoned_skip

import ../m83/profile_compile_edge_harness

const
  Pointer = "example-org/gm10-infra"
  MarkerPayload = "gm10-system-applied"

const HomeProfile = """
import repro_profile

profile "gm10Registry":
  activity default:
    gm10nosuchpackage

  hosts:
    "gm10-here": [default]
    "gm10-elsewhere":
      activities: [default]
      system: managedElsewhere("example-org/gm10-infra")
    "gm10-nopointer":
      activities: [default]
      system: managedElsewhere
"""

proc systemProfile(markerDir: string): string =
  ## An action-edge-only system profile: `/bin/sh` writes the marker. The
  ## command is free of double quotes so it survives into the Nim literal.
  let cmd = "mkdir -p out; printf '%s' '" & MarkerPayload &
    "' > 'out/marker.txt'"
  """
import repro_profile

profile "gm10System":
  resources:
    inlineExecCall(
      argv = @["/bin/sh", "-c", "@CMD@"],
      cwd = @CWD@,
      outputs = @["out/marker.txt"],
      requiresElevation = true,
      address = "gm10Marker",
      commandStatsId = "gm10.infra.marker")
""".multiReplace(("@CMD@", cmd),
    # A Nim literal, quoted and escaped: a Windows `C:\Users\...` read
    # verbatim is a `\U` escape and fails the profile compile.
    ("@CWD@", escape(markerDir)))

proc stateFingerprint(stateDir: string): seq[string] =
  ## The system state directory minus the profile-compile cache: the plan
  ## files, generations, locks and the current pointer a refused command
  ## must not create.
  treeFingerprint(stateDir, [stateDir / "profile-cache"])

suite "GM10: repro infra refuses a host whose system is managed elsewhere":

  test "e2e_infra_apply_refuses_externally_managed_host":
    block:
      let sb = newProfileSandbox("gm10-infra", HomeProfile)
      defer: sb.dispose()
      let markerDir = sb.root / "marker"
      createDir(markerDir)
      let marker = markerDir / "out" / "marker.txt"
      sb.writeProfileFile("system.nim", systemProfile(markerDir))
      let systemPath = sb.profileDir / "system.nim"
      let stateDir = sb.root / "infra-state"
      createDir(stateDir)
      let cacheEnv = [("REPROBUILD_ACTION_CACHE_ROOT",
                       sb.root / "action-cache")]

      proc infra(args: openArray[string]; host = ""): ReproRun =
        var argv = @args
        argv.add ["--profile", systemPath, "--state-dir", stateDir]
        sb.runRepro(argv, host = host, extraEnv = cacheEnv)

      proc checkRefused(run: ReproRun; command, host, by: string) =
        checkpoint(command & " " & host & " stdout:\n" & run.stdout)
        checkpoint(command & " " & host & " stderr:\n" & run.stderr)
        check run.exitCode == 1
        check (command & ": refusing host " & host &
          ": its system is managed elsewhere, by " & by) in run.stderr
        check ("host registry : " & sb.profilePath) in run.stderr
        check "Nothing was planned or changed" in run.stderr
        check "plan-id" notin run.stdout
        check "generation" notin run.stdout

      # 1. Refusals: nothing changes.
      let before = stateFingerprint(stateDir)
      checkRefused(infra(["infra", "plan", "--host", "gm10-elsewhere"]),
        "repro infra plan", "gm10-elsewhere", Pointer)
      checkRefused(infra(["infra", "apply", "--no-preview", "--host",
        "gm10-elsewhere"]), "repro infra apply", "gm10-elsewhere", Pointer)
      checkRefused(infra(["system", "sync", "--host", "gm10-elsewhere"]),
        "repro system sync", "gm10-elsewhere", Pointer)
      # A rollback re-applies a generation's system profile: refused too.
      checkRefused(infra(["system", "rollback", "--host", "gm10-elsewhere"]),
        "repro system rollback", "gm10-elsewhere", Pointer)
      # Without --host the registry is keyed by $REPRO_HOST, as `repro home`.
      checkRefused(infra(["infra", "apply", "--no-preview"],
        host = "gm10-elsewhere"), "repro infra apply", "gm10-elsewhere",
        Pointer)
      checkRefused(infra(["infra", "apply", "--no-preview", "--host",
        "gm10-nopointer"]), "repro infra apply", "gm10-nopointer",
        "something other than this configuration (the registry names no " &
        "manager)")
      check not fileExists(marker)
      check stateFingerprint(stateDir) == before
      for dir in ["plans", "generations", "locks"]:
        check not dirExists(stateDir / dir)

      # 2. Negative control: the same profiles on a host managed here plan
      # and apply normally.
      let plan = infra(["infra", "plan", "--host", "gm10-here"])
      checkpoint("plan gm10-here:\n" & plan.stdout & plan.stderr)
      check plan.exitCode == 0
      check "plan-id : " in plan.stdout
      check ("registry: " & sb.profilePath &
        " (host gm10-here: system managed here)") in plan.stdout
      let undeclared = infra(["infra", "plan", "--host", "gm10-undeclared"])
      checkpoint("plan gm10-undeclared:\n" & undeclared.stdout &
        undeclared.stderr)
      check undeclared.exitCode == 0
      check "(host gm10-undeclared not declared; system managed here)" in
        undeclared.stdout
      when defined(linux) or defined(macosx):
        let apply = infra(["infra", "apply", "--no-preview", "--host",
          "gm10-here"])
        checkpoint("apply gm10-here:\n" & apply.stdout & apply.stderr)
        check apply.exitCode == 0
        check "  generation   : " in apply.stdout
        check "registry     : " in apply.stdout
        # Vacuity: the edge runs when nothing refuses.
        check fileExists(marker)
        if fileExists(marker):
          check readFile(marker) == MarkerPayload
      else:
        # Applying the control needs the marker edge to run: `/bin/sh` here,
        # and on Windows an elevated broker (as in
        # t_infra_apply_profile_without_live_state). The refusals and plans
        # above run everywhere; eli-pc records this branch under GM1w.
        skip("applying the negative control needs /bin/sh and, on Windows, " &
          "an elevated broker; eli-pc runs the rest of this gate (GM1w)")

      # 3. Which registry: only the configuration's own.
      let lone = sb.root / "lone"
      createDir(lone)
      let loneSystem = lone / "system.nim"
      writeFile(loneSystem, systemProfile(markerDir))
      let loneState = sb.root / "lone-state"
      createDir(loneState)
      let noRegistry = sb.runRepro(["infra", "plan", "--profile", loneSystem,
        "--state-dir", loneState, "--host", "gm10-elsewhere"], host = "",
        extraEnv = cacheEnv)
      checkpoint("lone plan:\n" & noRegistry.stdout & noRegistry.stderr)
      check noRegistry.exitCode == 0
      check "registry: none" in noRegistry.stdout
      let named = sb.runRepro(["infra", "plan", "--profile", loneSystem,
        "--state-dir", loneState, "--host", "gm10-elsewhere",
        "--home-profile-dir", sb.profileDir], host = "", extraEnv = cacheEnv)
      checkRefused(named, "repro infra plan", "gm10-elsewhere", Pointer)
      let missing = sb.runRepro(["infra", "plan", "--profile", loneSystem,
        "--state-dir", loneState, "--host", "gm10-here",
        "--home-profile-dir", lone], host = "", extraEnv = cacheEnv)
      checkpoint("missing registry:\n" & missing.stdout & missing.stderr)
      check missing.exitCode == 1
      check ("--home-profile-dir " & lone & " holds no home.nim") in
        missing.stderr

      # 4a. A system profile cannot carry the attribute itself.
      let own = sb.root / "own"
      createDir(own)
      writeFile(own / "system.nim", """
import repro_profile

profile "gm10OwnHosts":
  hosts:
    "gm10-elsewhere":
      system: managedElsewhere("example-org/gm10-infra")
  resources:
    fsSystemFile(path = "/etc/gm10-never.conf", content = "x")
""")
      let ownRun = sb.runRepro(["infra", "plan", "--profile",
        own / "system.nim", "--state-dir", loneState, "--host", "gm10-here"],
        host = "", extraEnv = cacheEnv)
      checkpoint("own hosts:\n" & ownRun.stdout & ownRun.stderr)
      check ownRun.exitCode == 1
      check "cannot say who manages a host's system" in ownRun.stderr
      check "home profile's `hosts:` registry" in ownRun.stderr

      # 4b. A registry that does not compile refuses, naming it.
      let broken = sb.root / "broken"
      createDir(broken)
      writeFile(broken / "home.nim", """
import repro_profile

profile "gm10Broken":
  hosts:
    "gm10-here":
      system: managedSomewhere
""")
      writeFile(broken / "system.nim", systemProfile(markerDir))
      let brokenState = sb.root / "broken-state"
      createDir(brokenState)
      let brokenRun = sb.runRepro(["infra", "apply", "--no-preview",
        "--profile", broken / "system.nim", "--state-dir", brokenState,
        "--host", "gm10-here"], host = "", extraEnv = cacheEnv)
      checkpoint("broken registry:\n" & brokenRun.stdout & brokenRun.stderr)
      check brokenRun.exitCode == 1
      check ("cannot read the host registry " & broken / "home.nim") in
        brokenRun.stderr
      check "unknown `system:` value `managedSomewhere`" in brokenRun.stderr
      check not dirExists(brokenState / "generations")
