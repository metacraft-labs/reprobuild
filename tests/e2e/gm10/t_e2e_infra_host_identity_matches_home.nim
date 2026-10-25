## `repro infra` / `repro system` resolve the host with the ONE resolver
## `repro home` uses (Home-Profile-Intent-Layer.md §Host Identity;
## CLI/infra/README.md §Host identity; reprobuild-pm issue
## 2026-10-17-repro-infra-host-identity-differs-from-repro-home).
##
## Before the fix `repro infra plan` / `apply` and `repro system sync` /
## `rollback` recorded `--host`, else `%COMPUTERNAME%` verbatim, else
## `localhost`, while `repro home` and the GM10 registry gate used
## `$REPRO_HOST` / `--host` / the lower-cased hostname. So on POSIX every
## machine recorded `localhost`, and the plan report's `host :` line and its
## `registry:` line named different hosts.
##
## Against the real `build/bin/repro`, with `$REPRO_HOST` removed so the OS
## hostname decides. The hostname is set through the variable the platform's
## rule reads first (`$HOSTNAME` on POSIX, `%COMPUTERNAME%` on Windows), in
## MIXED case, so the lower-casing is exercised; on POSIX `%COMPUTERNAME%` is
## set to a decoy as well, which the old infra rule would have recorded.
##
## * `e2e_infra_and_home_record_one_hostname_identity`: `repro home apply`
##   records generation host `gm10-ident-host` (`repro home history`), and
##   `repro infra plan` reports `host : gm10-ident-host` with the registry
##   line keyed by the same name; `repro infra apply`, `repro system sync`
##   and `repro system rollback` report it and record it in their generations
##   (`repro system history`: `host=gm10-ident-host`). Neither `localhost`
##   nor the decoy appears anywhere.
## * `e2e_registry_gate_sees_the_host_repro_home_sees`: hostname
##   `GM10-Ident-Elsewhere` (declared `system: managedElsewhere`) is refused
##   by plan, apply, sync and rollback as `gm10-ident-elsewhere`, while
##   `repro home apply --plan` plans that same host; hostname
##   `GM10-Ident-Undeclared` is refused by `repro home` naming
##   `gm10-ident-undeclared`, and `repro infra plan` reports that same name
##   as not declared. Negative control: the first case, where the hostname
##   names a host managed here and everything proceeds.
## * `e2e_infra_refuses_host_conflicts_like_home`: `$REPRO_HOST=A` with
##   `--host B` is refused, exit 2 and the same diagnostic, by plan, apply,
##   sync, rollback and `repro home apply --plan`; an empty `--host=` too; the
##   state directory is unchanged. Negative control: `$REPRO_HOST=A --host A`
##   plans.
## * `e2e_state_recorded_under_the_old_identity_stays_usable`: a generation
##   and a plan recorded as `localhost` (exactly what the old rule wrote on
##   POSIX; produced here with `--host localhost`). Then, as the hostname:
##   `repro system history` still lists the generation (`host=localhost`);
##   `repro infra plan` carries a `note :` naming both identities;
##   `repro infra apply --plan <localhost plan>` is refused naming both hosts,
##   commits no generation (negative control: the same apply with
##   `--host localhost` proceeds); `repro system sync` commits a generation
##   under the new identity, `repro system rollback <localhost generation>`
##   succeeds, and afterwards the note is gone.
##
## Falsifying mutations (performed; see the GM10 milestone Verification):
## (M1) `resolveInfraHost` returning the old rule (`--host`, else
## `%COMPUTERNAME%`, else `localhost`) -- the first, second and fourth cases
## go red; (M2) the gate keyed by `--host` only, bypassing the resolver for
## the registry -- the second case goes red; (M3) `resolveHostFrom` without
## the `$REPRO_HOST` conflict refusal -- the third case goes red; (M4)
## `runInfraApply` without the plan-host check -- the fourth case goes red;
## (M5) `normalizeHostName` not lower-casing -- the first two go red.
##
## No mocks: real `repro`, real profile-compile edge, real home apply of
## fixture packages bound through the documented `REPRO_TEST_PACKAGE_SOURCE`
## seam, real system apply of an action edge whose only effect is a marker
## file in the sandbox (as in t_e2e_infra_apply_refuses_externally_managed_host;
## `requiresElevation = true` hands it to the apply's broker closure, so
## nothing prompts). Platforms: every host; the steps that commit a system
## generation need `/bin/sh` for the marker edge and, on Windows, an elevated
## broker, so there they are skipped with that reason and eli-pc runs them
## (GM10 Verification `eli_pc_infra_host_identity`).

import std/[os, strutils, unittest]

import repro_test_support/reasoned_skip

import ../m83/profile_compile_edge_harness

const
  Pointer = "example-org/gm10-ident"
  HereHost = "gm10-ident-host"
  CanCommitSystemGenerations = defined(linux) or defined(macosx)
    ## The marker edge is `/bin/sh`; see the header.

const HomeProfile = """
import repro_profile

profile "gm10Identity":
  activity default:
    `gm10-ident-base`

  hosts:
    "gm10-ident-host": [default]
    "gm10-ident-elsewhere":
      activities: [default]
      system: managedElsewhere("example-org/gm10-ident")
"""

proc systemProfile(markerDir: string): string =
  ## An action-edge-only system profile: `/bin/sh` writes a marker. Free of
  ## double quotes so it survives into the Nim literal.
  let cmd = "mkdir -p out; printf '%s' 'gm10-ident' > 'out/marker.txt'"
  """
import repro_profile

profile "gm10IdentSystem":
  resources:
    inlineExecCall(
      argv = @["/bin/sh", "-c", "@CMD@"],
      cwd = @CWD@,
      outputs = @["out/marker.txt"],
      requiresElevation = true,
      address = "gm10IdentMarker",
      commandStatsId = "gm10.ident.marker")
""".multiReplace(("@CMD@", cmd),
    # A Nim literal, quoted and escaped: a Windows `C:\Users\...` read
    # verbatim is a `\U` escape and fails the profile compile.
    ("@CWD@", escape(markerDir)))

type Fixture = object
  sb: ProfileSandbox
  systemPath: string
  stateDir: string
  baseEnv: seq[(string, string)]

proc newFixture(label: string): Fixture =
  result.sb = newProfileSandbox(label, HomeProfile)
  let markerDir = result.sb.root / "marker"
  createDir(markerDir)
  result.sb.writeProfileFile("system.nim", systemProfile(markerDir))
  result.systemPath = result.sb.profileDir / "system.nim"
  result.stateDir = result.sb.root / "infra-state"
  createDir(result.stateDir)
  result.baseEnv = @[("REPROBUILD_ACTION_CACHE_ROOT",
                      result.sb.root / "action-cache")]
  result.baseEnv.add result.sb.fixturePackageEnv(["gm10-ident-base"])

proc hostnameEnv(mixedCase: string): seq[(string, string)] =
  ## The OS hostname as the platform's rule reads it first. On POSIX a
  ## `%COMPUTERNAME%` decoy is set too: the old `repro infra` rule took it on
  ## every platform.
  when defined(windows):
    @[("COMPUTERNAME", mixedCase)]
  else:
    @[("HOSTNAME", mixedCase), ("COMPUTERNAME", "GM10-DECOY-PC")]

proc run(f: Fixture; args: openArray[string]; hostname = "";
         reproHost = ""): ReproRun =
  ## One `repro` run. `reproHost` "" removes `$REPRO_HOST`, so the hostname
  ## decides; `hostname` "" leaves the OS hostname alone.
  var env = f.baseEnv
  if hostname.len > 0:
    env.add hostnameEnv(hostname)
  result = f.sb.runRepro(args, host = reproHost, extraEnv = env)
  checkpoint("repro " & args.join(" ") & " [hostname=" & hostname &
    " REPRO_HOST=" & reproHost & "] -> " & $result.exitCode &
    "\n--- stdout\n" & result.stdout & "\n--- stderr\n" & result.stderr)

proc infra(f: Fixture; args: openArray[string]; hostname = "";
           reproHost = ""): ReproRun =
  ## A system-scope command against the fixture's profile and state dir.
  var argv = @args
  argv.add ["--profile", f.systemPath, "--state-dir", f.stateDir]
  f.run(argv, hostname, reproHost)

proc field(output, label: string): string =
  ## The value of a `  <label> : <value>` report line ("" when absent).
  for line in output.splitLines():
    let s = line.strip()
    if s.startsWith(label):
      let rest = s[label.len .. ^1].strip()
      if rest.startsWith(":"):
        return rest[1 .. ^1].strip()
  ""

proc stateFingerprint(stateDir: string): seq[string] =
  treeFingerprint(stateDir, [stateDir / "profile-cache"])

proc noLegacyIdentity(r: ReproRun) =
  check "localhost" notin r.stdout
  check "GM10-DECOY-PC" notin r.stdout
  check "gm10-decoy-pc" notin r.stdout

suite "GM10: repro infra and repro home resolve one host identity":

  test "e2e_infra_and_home_record_one_hostname_identity":
    let f = newFixture("gm10-ident-one")
    defer: f.sb.dispose()
    const Hostname = "GM10-Ident-Host"
    # repro home: the generation records the lower-cased hostname.
    let home = f.run(["home", "apply"], hostname = Hostname)
    require home.exitCode == 0
    let homeHistory = f.run(["home", "history"], hostname = Hostname)
    check ("host=" & HereHost) in homeHistory.stdout
    # repro infra plan: the recorded host and the registry key agree.
    let plan = f.infra(["infra", "plan"], hostname = Hostname)
    check plan.exitCode == 0
    check plan.stdout.field("host") == HereHost
    check ("registry: " & f.sb.profilePath & " (host " & HereHost &
      ": system managed here)") in plan.stdout
    plan.noLegacyIdentity()
    when CanCommitSystemGenerations:
      let apply = f.infra(["infra", "apply", "--no-preview"],
        hostname = Hostname)
      check apply.exitCode == 0
      check apply.stdout.field("host") == HereHost
      check ("(host " & HereHost & ": system managed here)") in apply.stdout
      apply.noLegacyIdentity()
      let sync = f.infra(["system", "sync"], hostname = Hostname)
      check sync.exitCode == 0
      check sync.stdout.field("host") == HereHost
      sync.noLegacyIdentity()
      let rollback = f.infra(["system", "rollback",
        apply.stdout.field("generation")], hostname = Hostname)
      check rollback.exitCode == 0
      check rollback.stdout.field("host") == HereHost
      let history = f.infra(["system", "history"], hostname = Hostname)
      check history.exitCode == 0
      # Three generations, every one recorded as the hostname identity.
      check history.stdout.count("host=" & HereHost) == 3
      history.noLegacyIdentity()
      # Same identity, so no note anywhere.
      for r in [apply, sync, rollback]:
        check r.stdout.field("note") == ""
    else:
      skip("committing a system generation needs the /bin/sh marker edge " &
        "and, on Windows, an elevated broker; eli-pc runs it " &
        "(eli_pc_infra_host_identity)")

  test "e2e_registry_gate_sees_the_host_repro_home_sees":
    let f = newFixture("gm10-ident-gate")
    defer: f.sb.dispose()
    const Elsewhere = "GM10-Ident-Elsewhere"
    let before = stateFingerprint(f.stateDir)
    for (args, command) in [
        (@["infra", "plan"], "repro infra plan"),
        (@["infra", "apply", "--no-preview"], "repro infra apply"),
        (@["system", "sync"], "repro system sync"),
        (@["system", "rollback"], "repro system rollback")]:
      let r = f.infra(args, hostname = Elsewhere)
      check r.exitCode == 1
      check (command & ": refusing host gm10-ident-elsewhere: its system " &
        "is managed elsewhere, by " & Pointer) in r.stderr
    check stateFingerprint(f.stateDir) == before
    # repro home resolves the same name: it plans that declared host.
    let homePlan = f.run(["home", "apply", "--plan"], hostname = Elsewhere)
    check homePlan.exitCode == 0
    check "gm10-ident-base" in homePlan.stdout
    # An undeclared hostname: both name the same lower-cased host.
    const Undeclared = "GM10-Ident-Undeclared"
    let homeUndeclared = f.run(["home", "apply", "--plan"],
      hostname = Undeclared)
    check homeUndeclared.exitCode != 0
    check "host `gm10-ident-undeclared` is not declared" in
      homeUndeclared.stderr
    let infraUndeclared = f.infra(["infra", "plan"], hostname = Undeclared)
    check infraUndeclared.exitCode == 0
    check infraUndeclared.stdout.field("host") == "gm10-ident-undeclared"
    check "(host gm10-ident-undeclared not declared; system managed here)" in
      infraUndeclared.stdout

  test "e2e_infra_refuses_host_conflicts_like_home":
    let f = newFixture("gm10-ident-conflict")
    defer: f.sb.dispose()
    let before = stateFingerprint(f.stateDir)
    const Conflict = "--host gm10-ident-elsewhere conflicts with " &
      "$REPRO_HOST=gm10-ident-host (which takes precedence); unset one of them"
    for (args, command) in [
        (@["infra", "plan"], "repro infra plan"),
        (@["infra", "apply", "--no-preview"], "repro infra apply"),
        (@["system", "sync"], "repro system sync"),
        (@["system", "rollback"], "repro system rollback")]:
      let r = f.infra(args & @["--host", "gm10-ident-elsewhere"],
        reproHost = HereHost)
      check r.exitCode == 2
      check (command & ": " & Conflict) in r.stderr
      let empty = f.infra(args & @["--host="], reproHost = "")
      check empty.exitCode == 2
      check (command & ": --host needs a non-empty name") in empty.stderr
    check stateFingerprint(f.stateDir) == before
    let home = f.run(["home", "apply", "--plan", "--host",
      "gm10-ident-elsewhere"], reproHost = HereHost)
    check home.exitCode == 2
    check ("repro home apply --plan: " & Conflict) in home.stderr
    # Negative control: the same name in both is accepted.
    let agree = f.infra(["infra", "plan", "--host", HereHost],
      reproHost = HereHost)
    check agree.exitCode == 0
    check agree.stdout.field("host") == HereHost

  test "e2e_state_recorded_under_the_old_identity_stays_usable":
    when CanCommitSystemGenerations:
      let f = newFixture("gm10-ident-legacy")
      defer: f.sb.dispose()
      const Hostname = "GM10-Ident-Host"
      # What the old rule recorded on a POSIX machine.
      let legacyApply = f.infra(["infra", "apply", "--no-preview", "--host",
        "localhost"])
      require legacyApply.exitCode == 0
      let legacyGen = legacyApply.stdout.field("generation")
      check legacyGen.len > 0
      let legacyPlan = f.infra(["infra", "plan", "--host", "localhost"])
      require legacyPlan.exitCode == 0
      let legacyPlanId = legacyPlan.stdout.field("plan-id")
      check legacyPlanId.len > 0

      # Still listed under the identity it recorded.
      let history = f.infra(["system", "history"], hostname = Hostname)
      check ("host=localhost") in history.stdout
      check legacyGen in history.stdout
      # The change of identity is reported, not silent.
      let plan = f.infra(["infra", "plan"], hostname = Hostname)
      check plan.exitCode == 0
      check plan.stdout.field("note") ==
        "the current generation " & legacyGen & " recorded host " &
        "'localhost'; this run is host '" & HereHost & "' (earlier " &
        "generations stay listed and remain rollback targets)"
      # A plan recorded for the old identity is refused, naming both hosts,
      # and nothing is committed.
      let gensBefore = f.infra(["system", "history"], hostname = Hostname)
      let refused = f.infra(["infra", "apply", "--plan", legacyPlanId],
        hostname = Hostname)
      check refused.exitCode == 1
      check ("plan '" & legacyPlanId & "' was made for host 'localhost', " &
        "but this apply is host '" & HereHost & "'") in refused.stderr
      check "Re-run `repro infra plan` as this host" in refused.stderr
      let gensAfter = f.infra(["system", "history"], hostname = Hostname)
      check gensAfter.stdout.field("generations") ==
        gensBefore.stdout.field("generations")
      # Negative control: applied as the host it was made for, it proceeds.
      let accepted = f.infra(["infra", "apply", "--plan", legacyPlanId,
        "--host", "localhost"])
      check accepted.exitCode == 0
      # A new-identity generation, then a rollback to the old one.
      let sync = f.infra(["system", "sync"], hostname = Hostname)
      check sync.exitCode == 0
      check "recorded host 'localhost'" in sync.stdout.field("note")
      let rollback = f.infra(["system", "rollback", legacyGen],
        hostname = Hostname)
      check rollback.exitCode == 0
      check rollback.stdout.field("to generation") == legacyGen
      check rollback.stdout.field("host") == HereHost
      # The rollback committed a generation as the hostname: no note now.
      let after = f.infra(["infra", "plan"], hostname = Hostname)
      check after.exitCode == 0
      check after.stdout.field("note") == ""
    else:
      skip("committing a system generation needs the /bin/sh marker edge " &
        "and, on Windows, an elevated broker; eli-pc runs it " &
        "(eli_pc_infra_host_identity)")
