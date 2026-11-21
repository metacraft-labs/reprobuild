## The deliberate writes are positive controls for the guard, not mocked apply
## behavior. All writes target its disposable ambient home, never the operator.
import std/[os, osproc, strutils, unittest]
import repro_test_support/home_apply_guard
import repro_test_support/registry_isolation

suite "home-apply ambient home guard":
  test "isolates fallback paths and restores the complete environment":
    let before = getEnv("HOME")
    let overrideExisted = existsEnv("REPRO_HOME_POSIX_PATH_RC")
    let overrideBefore = getEnv("REPRO_HOME_POSIX_PATH_RC")
    let registryExisted = existsEnv(RegistryRootEnvVar)
    let registryBefore = getEnv(RegistryRootEnvVar)
    withHomeApplyGuard:
      check getHomeDir().strip(chars = {DirSep}) != before.strip(chars = {DirSep})
      check getEnv("USERPROFILE") == getEnv("HOME")
      check getEnv("XDG_CONFIG_HOME") == getEnv("HOME") / ".config"
      check not existsEnv("REPRO_HOME_POSIX_PATH_RC")
      # An in-process apply on Windows writes the fake hive, not HKCU.
      let hive = getEnv(RegistryRootEnvVar)
      check hive.len > 0
      check hive != registryBefore
      check hive.extractFilename == RegistryHiveDirName
      check dirExists(hive.parentDir)
    check getEnv("HOME") == before
    check existsEnv("REPRO_HOME_POSIX_PATH_RC") == overrideExisted
    check getEnv("REPRO_HOME_POSIX_PATH_RC") == overrideBefore
    check existsEnv(RegistryRootEnvVar) == registryExisted
    check getEnv(RegistryRootEnvVar) == registryBefore

  test "rejects bash zsh and fish fallback writes":
    let before = getEnv("HOME")
    for rc in [".bashrc", ".zshrc", ".config/fish/config.fish"]:
      expect IOError:
        withHomeApplyGuard:
          let path = getHomeDir() / rc
          createDir(path.parentDir())
          writeFile(path, "# unexpected apply fallback\n")
      check getEnv("HOME") == before

  test "guard verification runs after an exception":
    let before = getEnv("HOME")
    expect IOError:
      withHomeApplyGuard:
        writeFile(getHomeDir() / ".bashrc", "leak")
        raise newException(ValueError, "apply failed after write")
    check getEnv("HOME") == before

  test "clean body exceptions restore the environment":
    let before = getEnv("HOME")
    expect ValueError:
      withHomeApplyGuard:
        raise newException(ValueError, "apply failed before writing")
    check getEnv("HOME") == before

  when not defined(windows):
    test "child processes inherit confinement and writes fail the run":
      expect IOError:
        withHomeApplyGuard:
          let child = execCmdEx("sh -c 'printf leak > \"$HOME/.bashrc\"'",
            options = {poUsePath, poStdErrToStdOut})
          check child.exitCode == 0

    test "symlink creation is a violation without following its target":
      expect IOError:
        withHomeApplyGuard:
          createSymlink("/does-not-exist", getHomeDir() / ".bashrc")

  test "restores absent empty and nonempty environment values on violation":
    const names = ["HOME", "USERPROFILE", "XDG_CONFIG_HOME",
      "REPRO_HOME_POSIX_PATH_RC"]
    var original: array[names.len, tuple[present: bool, value: string]]
    for i, name in names:
      original[i] = (existsEnv(name), getEnv(name))
    defer:
      for i, name in names:
        if original[i].present: putEnv(name, original[i].value)
        else: delEnv(name)
    for mode in 0 .. 2:
      for name in names:
        if mode == 0: delEnv(name)
        else: putEnv(name, if mode == 1: "" else: "prior-value")
      expect IOError:
        withHomeApplyGuard:
          writeFile(getHomeDir() / ".bashrc", "leak")
      for name in names:
        check existsEnv(name) == (mode != 0)
        check getEnv(name) == (if mode == 2: "prior-value" else: "")

  test "deleting ambient home is also a violation":
    expect IOError:
      withHomeApplyGuard:
        removeDir(getHomeDir())

suite "registry isolation":
  test "beginRegistryIsolation installs a fresh hive and end restores the prior value":
    let priorExisted = existsEnv(RegistryRootEnvVar)
    let prior = getEnv(RegistryRootEnvVar)
    defer:
      if priorExisted: putEnv(RegistryRootEnvVar, prior)
      else: delEnv(RegistryRootEnvVar)
    for preset in ["", "preset-hive"]:
      if preset.len > 0: putEnv(RegistryRootEnvVar, preset)
      else: delEnv(RegistryRootEnvVar)
      let isolation = beginRegistryIsolation()
      check dirExists(isolation.hiveRoot)
      check getEnv(RegistryRootEnvVar) == registryHiveDir(isolation.hiveRoot)
      endRegistryIsolation(isolation)
      check not dirExists(isolation.hiveRoot)
      check existsEnv(RegistryRootEnvVar) == (preset.len > 0)
      check getEnv(RegistryRootEnvVar) == preset
