import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

proc runRepro(reproBin, workingDir: string; args: openArray[string]; env: seq[tuple[key, val: string]] = @[]): tuple[exitCode: int; output: string] =
  var envTab = newStringTable()
  for k, v in envPairs():
    envTab[k] = v
  for item in env:
    envTab[item.key] = item.val
  var process = startProcess(reproBin,
    args = @args,
    workingDir = workingDir,
    env = envTab,
    options = {poUsePath, poStdErrToStdOut})
  let output =
    if process.outputStream != nil: process.outputStream.readAll()
    else: ""
  let exitCode = process.waitForExit()
  process.close()
  (exitCode: exitCode, output: output)

suite "integration_dev_env_allow":
  test "directory allow and deny workflow":
    let repoRoot = getCurrentDir()
    let reproBin = repoRoot / "build" / "bin" / "repro"
    
    # Create a temporary directory structure mimicking a project
    let tempRoot = createTempDir("repro-test-allow", "")
    defer: removeDir(tempRoot)
    
    let projectDir = tempRoot / "project"
    createDir(projectDir)
    writeFile(projectDir / "reprobuild.nim", "package test:\n  discard\n")
    
    # Override XDG_CONFIG_HOME so we don't poison the user's real configs
    let customXdgConfig = tempRoot / "xdg-config"
    createDir(customXdgConfig)
    
    let env = @[("XDG_CONFIG_HOME", customXdgConfig)]
    
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
