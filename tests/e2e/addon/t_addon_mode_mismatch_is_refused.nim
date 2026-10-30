## ReproOS add-on mode: the planner refuses a registry mode that disagrees
## with the host's base (`EAddOnModeMismatch`), a base no add-on realisation
## covers (`EAddOnUnsupportedBase`), and a field the `add-on-debian`
## realisation does not allow (`EAddOnOutOfScope`, naming the field and the
## activity), through the real CLI.
##
## `t_addon_mode_mismatch_is_refused` (the A6 gate for threat-model G21 /
## T31; it also covers `EAddOnOutOfScope`), against the real
## `build/bin/repro`, with the base chosen per run from the committed
## `os-release` fixtures:
##
## 1. `system: addOn` on a ReproOS base and on a NixOS base: `repro infra
##    plan`, `repro infra apply --no-preview` and `repro system sync` each
##    exit 1 with `EAddOnModeMismatch`, naming the host, the registry and
##    the observed base, and the state directory is unchanged (no plan,
##    generation, lock or pointer).
## 2. A host the registry declares WITHOUT `system:` on a Debian base is
##    refused the same way, the diagnostic asking for `addOn` or
##    `managedElsewhere`. Negative controls: the same host on a ReproOS base
##    plans; a host the registry does not declare plans on Debian as before,
##    and the report says it is not declared.
## 3. `system: addOn` on Ubuntu 24.04 and on Raspberry Pi OS 13 (`ID_LIKE=
##    debian`) plans through `add-on-debian`; on Arch it is
##    `EAddOnUnsupportedBase`.
## 4. An add-on host selecting an activity that sets a machine-only field
##    (`os.hostname`) is `EAddOnOutOfScope` naming `os.hostname` and the
##    activity; one whose firewall rule targets a table other than the
##    add-on's own is `EAddOnOutOfScope` naming
##    `linux.firewallRule.chain`. Nothing is planned. The same profile plans
##    for an add-on host that does not select those activities.
##
## Vacuity: the negative controls plan (exit 0, a plan id), so every refusal
## above is the check's, not a broken fixture.
##
## Falsifying mutation (run red then green, recorded in the A6 report): a
## planner that treats an undeclared mode on a registry-declared distribution
## host as `addOn` plans writes for `mm-full` on Debian, so step 2's refusal
## checks fail and the state fingerprint changes. The mutation is compiled
## in with `REPROBUILD_MUTATIONS=1 just build` (`-d:reproMutations`) and
## armed with `REPRO_A6_MUTATE_UNDECLARED_MODE_AS_ADDON=1` in the environment
## of `repro` (`infra_host_registry.checkHostSystemMode`); a production build
## does not contain it.
##
## No mocks: real `repro`, real Nim, real profile compiles, real planner
## (read-only). The base is chosen through the `os-release` seam
## (`addon_test_support`). Nothing is applied: the refused applies are
## refused before anything runs, which the unchanged state directory shows.
##
## Platforms: every host.

import std/[os, strutils, unittest]

import ../m83/profile_compile_edge_harness
import ./addon_test_support

const HomeProfile = """
import repro_profile

profile "a6mmRegistry":
  activity default:
    a6mmnosuchpackage

  hosts:
    "mm-addon":
      system: addOn
    "mm-full": [default]
    "mm-machine":
      system: {mode: addOn, activities: [machine]}
    "mm-fw":
      system: {mode: addOn, activities: [fw]}
"""

const SystemProfile = """
import repro_profile

profile "a6mmSystem":
  activity machine:
    resources:
      osHostname(hostname = "renamed", address = "hostName")

  activity fw:
    resources:
      linuxFirewallRule(chain = "inet filter input", name = "ssh",
        protocol = "tcp", action = "accept", localPort = "22",
        address = "sshRule")

  resources:
    fsSystemFile(path = "/etc/a6mm-test/base.conf", content = "x\n",
      address = "baseConf")
"""

proc stateFingerprint(stateDir: string): seq[string] =
  treeFingerprint(stateDir, [stateDir / "profile-cache"])

suite "ReproOS add-on mode: mode mismatch and out-of-scope refusals":

  test "t_addon_mode_mismatch_is_refused":
    let sb = newProfileSandbox("a6mm", HomeProfile)
    defer: sb.dispose()
    sb.writeProfileFile("system.nim", SystemProfile)
    let systemPath = sb.profileDir / "system.nim"
    let stateDir = sb.root / "infra-state"
    createDir(stateDir)

    proc run(args: openArray[string]; host, base: string): ReproRun =
      var argv = @args
      argv.add ["--state-dir", stateDir, "--profile", systemPath,
                "--host", host]
      result = sb.runRepro(argv, host = "", extraEnv = [baseEnv(base),
        ("REPROBUILD_ACTION_CACHE_ROOT", sb.root / "action-cache")])
      checkpoint args.join(" ") & " --host " & host & " on " & base &
        " -> " & $result.exitCode & "\n" & result.stdout & result.stderr

    # A first successful plan creates the state directory's layout, so the
    # fingerprints below compare like with like.
    let control = run(["infra", "plan"], "mm-full", "reproos")
    require control.exitCode == 0
    check "plan-id" in control.stdout
    check "system  : activities default; realised full" in control.stdout

    # 1. addOn on a base that is not a distribution host.
    for base in ["reproos", "nixos"]:
      for cmd in [@["infra", "plan"], @["infra", "apply", "--no-preview"],
                  @["system", "sync"]]:
        let before = stateFingerprint(stateDir)
        let r = run(cmd, "mm-addon", base)
        check r.exitCode == 1
        check "EAddOnModeMismatch: host mm-addon is declared `system: " &
          "addOn`" in r.stderr
        check "observed base : " & base in r.stderr
        check "host registry : " & sb.profileDir / "home.nim" in r.stderr
        check stateFingerprint(stateDir) == before

    # 2. A declared host without `system:` on a distribution base.
    for cmd in [@["infra", "plan"], @["infra", "apply", "--no-preview"]]:
      let before = stateFingerprint(stateDir)
      let r = run(cmd, "mm-full", "debian-13")
      check r.exitCode == 1
      check "EAddOnModeMismatch: host mm-full runs debian 13" in r.stderr
      check "add `system: addOn` to its `hosts:` entry" in r.stderr
      check "`system: managedElsewhere(" in r.stderr
      check stateFingerprint(stateDir) == before
    let undeclared = run(["infra", "plan"], "mm-undeclared", "debian-13")
    check undeclared.exitCode == 0
    check "host mm-undeclared not declared; system managed here" in
      undeclared.stdout
    check "realised full" in undeclared.stdout

    # 3. addOn on the Debian family plans; on Arch there is no realisation.
    for base in ["ubuntu-24.04", "raspbian-13", "debian-13"]:
      let r = run(["infra", "plan"], "mm-addon", base)
      check r.exitCode == 0
      check "system  : activities default; realised add-on-debian" in
        r.stdout
      check "* create system-file /etc/a6mm-test/base.conf  [create]" in
        r.stdout
    block:
      let before = stateFingerprint(stateDir)
      let r = run(["infra", "plan"], "mm-addon", "arch")
      check r.exitCode == 1
      check "EAddOnUnsupportedBase: host mm-addon is declared `system: " &
        "addOn`, but it runs arch" in r.stderr
      check stateFingerprint(stateDir) == before

    # 4. Out-of-scope fields, named with the activity that set them.
    block:
      let before = stateFingerprint(stateDir)
      let machine = run(["infra", "plan"], "mm-machine", "debian-13")
      check machine.exitCode == 1
      check "EAddOnOutOfScope: field `os.hostname` of os.hostname " &
        "`hostName`, set by activity `machine`" in machine.stderr
      check "base networking" in machine.stderr
      let fw = run(["infra", "plan"], "mm-fw", "debian-13")
      check fw.exitCode == 1
      check "EAddOnOutOfScope: field `linux.firewallRule.chain`" in fw.stderr
      check "set by activity `fw`" in fw.stderr
      check "inet repro" in fw.stderr
      check "plan-id" notin machine.stdout & fw.stdout
      check stateFingerprint(stateDir) == before
