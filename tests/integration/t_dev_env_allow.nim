import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support

proc envEntries(env: StringTableRef): seq[tuple[name, value: string]] =
  for key, value in env.pairs():
    result.add((key, value))

proc runRepro(reproBin, workingDir: string; args: openArray[string]; env: seq[tuple[key, val: string]] = @[]): tuple[exitCode: int; output: string] =
  var envTab = newStringTable()
  for k, v in envPairs():
    if k.startsWith("__REPRO_"):
      envTab[k] = ""
      continue
    envTab[k] = v
  for item in env:
    envTab[item.key] = item.val
  let res = runShell(shellCommand(@[reproBin] & @args, envTab.envEntries),
    workingDir)
  (exitCode: res.code, output: res.output)

suite "integration_dev_env_allow":
  test "directory allow and deny workflow":
    let repoRoot = getCurrentDir()
    let reproBin = repoRoot / "build" / "bin" / "repro"

    # Create a temporary directory structure mimicking a project
    let tempRoot = createTempDir("repro-test-allow", "")
    defer: removeDir(tempRoot)

    let projectDir = tempRoot / "project"
    createDir(projectDir)
    writeFile(projectDir / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package test:\n" &
      "  defaultToolProvisioning \"path\"\n" &
      "  uses:\n" &
      "    \"nim >=2.2 <3.0\"\n" &
      "  devEnv:\n" &
      "    activity \"default\"\n" &
      "    setEnv \"FIXTURE_MODE\", \"dev\"\n"
    )

    # Override XDG_CONFIG_HOME so we don't poison the user's real configs
    let customXdgConfig = tempRoot / "xdg-config"
    createDir(customXdgConfig)

    let actionCacheRoot = tempRoot / "action-cache"
    let daemonStateDir = tempRoot / "daemon-state"
    createDir(actionCacheRoot)
    createDir(daemonStateDir)

    let env = @[
      ("XDG_CONFIG_HOME", customXdgConfig),
      ("HOME", tempRoot),
      ("REPROBUILD_ACTION_CACHE_ROOT", actionCacheRoot),
      ("REPRO_ACTION_CACHE_SHM", "0"),
      ("REPRO_DAEMON", "off"),
      ("REPRO_DAEMON_ENDPOINT",
        daemonSocketEndpoint("repro-dev-env-allow-" & $getCurrentProcessId())),
      ("REPRO_DAEMON_STATE_DIR", daemonStateDir)
    ]

    # 1. Initially, export zsh should be blocked because it's untrusted
    let resExportBlocked = runRepro(reproBin, projectDir, @["dev-env", "export", "zsh"], env)
    check resExportBlocked.exitCode == 0
    check "repro: dev-env directory" in resExportBlocked.output
    check "is not allowed/trusted" in resExportBlocked.output
    check "Run 'repro allow'" in resExportBlocked.output

    # 2. Allow the directory (without arguments, defaults to current directory)
    let resAllow = runRepro(reproBin, projectDir, @["allow"], env)
    check resAllow.exitCode == 0
    check "Allowed repro dev-env for:" in resAllow.output

    # 3. Export should now proceed past the trust check (it will still fail because it's a dummy project, but not block on trust)
    let resExportAllowed = runRepro(reproBin, projectDir, @["dev-env", "export", "zsh"], env)
    # It should not print the trust block warning message
    check "is not allowed/trusted" notin resExportAllowed.output

    # 4. Deny the directory (without arguments, defaults to current directory)
    let resDeny = runRepro(reproBin, projectDir, @["deny"], env)
    check resDeny.exitCode == 0
    check "Denied/removed repro dev-env trust for:" in resDeny.output

    # 5. Export should be blocked again
    let resExportBlockedAgain = runRepro(reproBin, projectDir, @["dev-env", "export", "zsh"], env)
    check resExportBlockedAgain.exitCode == 0
    check "is not allowed/trusted" in resExportBlockedAgain.output

    # 6. Test allowing arbitrary non-project directory
    let nonProjectDir = tempRoot / "non-project"
    createDir(nonProjectDir)
    let resAllowNonProj = runRepro(reproBin, nonProjectDir, @["allow"], env)
    check resAllowNonProj.exitCode == 0
    check "Allowed repro dev-env for:" in resAllowNonProj.output
    check nonProjectDir in resAllowNonProj.output

    # 7. Test warning suppression using __REPRO_WARNED
    let blockedDir = tempRoot / "blocked-project"
    createDir(blockedDir)
    writeFile(blockedDir / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package blocked:\n" &
      "  defaultToolProvisioning \"path\"\n" &
      "  uses:\n" &
      "    \"nim >=2.2 <3.0\"\n" &
      "  devEnv:\n" &
      "    activity \"default\"\n" &
      "    setEnv \"FIXTURE_MODE\", \"dev\"\n"
    )

    # First time, should output warning and export __REPRO_WARNED
    let resWarn1 = runRepro(reproBin, blockedDir, @["dev-env", "export", "zsh"], env)
    check resWarn1.exitCode == 0
    check "is not allowed/trusted" in resWarn1.output
    check "export __REPRO_WARNED=" in resWarn1.output

    # Second time, with __REPRO_WARNED in environment matching project dir, should be silent (no output)
    let envWithWarned = env & @[("__REPRO_WARNED", blockedDir)]
    let resWarn2 = runRepro(reproBin, blockedDir, @["dev-env", "export", "zsh"], envWithWarned)
    check resWarn2.exitCode == 0
    check resWarn2.output.strip() == ""

    # Now allow the directory
    discard runRepro(reproBin, blockedDir, @["allow"], env)

    # Exporting should now clear __REPRO_WARNED (unset __REPRO_WARNED)
    let resWarnClear = runRepro(reproBin, blockedDir, @["dev-env", "export", "zsh"], env)
    check "unset __REPRO_WARNED" in resWarnClear.output
