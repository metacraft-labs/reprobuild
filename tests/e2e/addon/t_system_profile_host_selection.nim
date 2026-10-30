## ReproOS add-on mode: system-scope host selection, through the real CLI.
##
## `t_system_profile_host_selection`, against the real `build/bin/repro`:
##
## One system profile (`system.nim`) with two activities, `web` and `backup`,
## each holding one `fs.systemFile` in its `resources:` block, a profile-wide
## file, and a profile-wide file under a RUNTIME guard
## (`when host() == "a6sel-web":`). Beside it, the home profile's `hosts:`
## registry declares two add-on hosts that select one activity each through
## the block form of `system:` -- `a6sel-web` indented, `a6sel-backup`
## inline -- and an add-on host using the short form, which selects `default`
## only. The base is Debian 13 (the `os-release` fixture).
##
## 1. `repro infra plan --host a6sel-web` plans exactly the web activity's
##    file, the profile-wide file and the guarded file; `--host
##    a6sel-backup` exactly the backup file and the profile-wide file (the
##    guard does not hold there); `--host a6sel-short` the profile-wide file
##    alone. Each report names the selection (`system  : activities ...;
##    realised add-on-debian`) and the registry entry.
## 2. The runtime guard selects per host instead of being refused: before
##    add-on mode a system profile with a runtime guard was refused outright
##    ("system profiles do not evaluate runtime predicates"); here the same
##    profile plans, and the guarded file appears for one host only.
## 3. Refusals: a host whose entry selects an activity the system profile
##    does not declare is refused, naming it; a system profile with its own
##    `hosts:` block is refused (the home profile's registry is the only
##    one); nothing is planned in either case.
##
## Vacuity: the hosts' plans differ, and each contains the file only its
## activity holds -- "every host plans everything" and "nothing is planned"
## both fail.
##
## No mocks: real `repro`, real Nim, real profile compiles of both profiles,
## real planner (read-only observation of `/etc/a6sel-test/...`, which does
## not exist, so every file plans as `create`). The base is chosen through
## the `os-release` seam (see `addon_test_support`). Nothing is applied.
##
## Platforms: every host (the plan is read-only and the base is a fixture).

import std/[os, strutils, unittest]

import ../m83/profile_compile_edge_harness
import ./addon_test_support

const HomeProfile = """
import repro_profile

profile "a6selRegistry":
  activity default:
    a6selnosuchpackage

  hosts:
    "a6sel-web":
      activities: [default]
      system:
        mode: addOn
        activities: [web]
    "a6sel-backup":
      activities: [default]
      system: {mode: addOn, activities: [backup]}
    "a6sel-short":
      system: addOn
    "a6sel-unknown":
      system: {mode: addOn, activities: [nosuchactivity]}
"""

const SystemProfile = """
import repro_profile

profile "a6selSystem":
  activity web:
    resources:
      fsSystemFile(path = "/etc/a6sel-test/web.conf", content = "web\n",
        address = "webConf")

  activity backup:
    resources:
      fsSystemFile(path = "/etc/a6sel-test/backup.conf",
        content = "backup\n", address = "backupConf")

  resources:
    fsSystemFile(path = "/etc/a6sel-test/base.conf", content = "base\n",
      address = "baseConf")
    when host() == "a6sel-web":
      fsSystemFile(path = "/etc/a6sel-test/web-only.conf", content = "w\n",
        address = "webOnlyConf")
"""

const
  WebFile = "create system-file /etc/a6sel-test/web.conf"
  BackupFile = "create system-file /etc/a6sel-test/backup.conf"
  BaseFile = "create system-file /etc/a6sel-test/base.conf"
  GuardedFile = "create system-file /etc/a6sel-test/web-only.conf"

suite "ReproOS add-on mode: system-scope host selection":

  test "t_system_profile_host_selection":
    let sb = newProfileSandbox("a6sel", HomeProfile)
    defer: sb.dispose()
    sb.writeProfileFile("system.nim", SystemProfile)
    let systemPath = sb.profileDir / "system.nim"
    let stateDir = sb.root / "infra-state"
    createDir(stateDir)
    let env = [baseEnv("debian-13"),
               ("REPROBUILD_ACTION_CACHE_ROOT", sb.root / "action-cache")]

    proc plan(host: string): ReproRun =
      result = sb.runRepro(["infra", "plan", "--state-dir", stateDir,
        "--profile", systemPath, "--host", host], host = "",
        extraEnv = env)
      checkpoint "plan " & host & " -> " & $result.exitCode & "\n" &
        result.stdout & result.stderr

    # 1 + 2. Each host plans its own activity's resources, and the guard.
    let web = plan("a6sel-web")
    require web.exitCode == 0
    check planLines(web.stdout).len == 3
    for line in [WebFile, BaseFile, GuardedFile]:
      check ("* " & line & "  [create]") in planLines(web.stdout)
    check BackupFile notin web.stdout
    check "system  : activities default, web; realised add-on-debian" in
      web.stdout
    check "host a6sel-web: system managed here in add-on mode (system " &
      "activities: default, web)" in web.stdout

    let backup = plan("a6sel-backup")
    require backup.exitCode == 0
    check planLines(backup.stdout).len == 2
    for line in [BackupFile, BaseFile]:
      check ("* " & line & "  [create]") in planLines(backup.stdout)
    check WebFile notin backup.stdout
    check GuardedFile notin backup.stdout
    check "system  : activities default, backup; realised add-on-debian" in
      backup.stdout

    let short = plan("a6sel-short")
    require short.exitCode == 0
    check planLines(short.stdout) == @["* " & BaseFile & "  [create]"]
    check "system  : activities default; realised add-on-debian" in
      short.stdout

    # Vacuity: the three plans differ pairwise.
    check planLines(web.stdout) != planLines(backup.stdout)
    check planLines(backup.stdout) != planLines(short.stdout)

    # 3. Refusals.
    let unknown = plan("a6sel-unknown")
    check unknown.exitCode == 1
    check "selects system activity nosuchactivity" in unknown.stderr
    check "which the system profile does not declare (declared: web, " &
      "backup)" in unknown.stderr
    check "plan-id" notin unknown.stdout

    sb.writeProfileFile("system.nim", SystemProfile & """
  hosts:
    "a6sel-web": [default]
""")
    let ownHosts = plan("a6sel-web")
    check ownHosts.exitCode == 1
    check "would be a second host registry that nothing reads" in
      ownHosts.stderr
    check "plan-id" notin ownHosts.stdout
