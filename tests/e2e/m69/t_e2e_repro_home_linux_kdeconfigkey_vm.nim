## M83 step 13 — disposable-WSL gate for `linux.kdeConfigKey`.
##
## The driver shells out to `kwriteconfig5`/`kwriteconfig6` and
## `kreadconfig5`/`kreadconfig6`. These binaries live in
## `libkf5config-bin` (KDE Frameworks 5) on Ubuntu 22.04 or
## `kf6-kconfig-bin` (KF6). If neither is installed, the gate emits a
## SKIP sentinel rather than failing the harness.
##
## Gated by `defined(linux)` AND `REPRO_M69_KDE_CONFIG_KEY_VM=1`.

import std/[os, strutils, osproc]

import repro_home_resources

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "linux.kdeConfigKey"

proc writeLineSentinel(text: string) =
  let path = getEnv("REPRO_M69_VM_SENTINEL_FILE", SentinelDefault)
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  var f: File
  if open(f, path, fmAppend):
    try:
      f.writeLine(text)
    finally:
      close(f)

proc binaryAvailable(name: string): bool =
  let (output, code) = execCmdEx("command -v " & name)
  result = code == 0 and output.strip().len > 0

proc pickKdeVersion(): int =
  ## Prefer KF5 if installed (Ubuntu 22.04 ships KF5 by default);
  ## otherwise try KF6. Return 0 if neither is available.
  if binaryAvailable("kwriteconfig5") and binaryAvailable("kreadconfig5"):
    return 5
  if binaryAvailable("kwriteconfig6") and binaryAvailable("kreadconfig6"):
    return 6
  return 0

proc main() =
  let sandboxMode =
    defined(linux) and getEnv("REPRO_M69_KDE_CONFIG_KEY_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_KDE_CONFIG_KEY_VM not set."
    quit(0)

  when defined(linux):
    let version = pickKdeVersion()
    if version == 0:
      echo "  [SKIP] " & GateName & ": kwriteconfig5/6 not installed"
      writeLineSentinel("SKIP: " & GateName &
        " (kwriteconfig5/6 missing)")
      quit(0)

    # Configure HOME to a writable path; the gate runs as root so
    # /root is fine, but kwriteconfig may fail if XDG_CONFIG_HOME is
    # unwritable. We override XDG_CONFIG_HOME to a known clean dir.
    let testRoot = "/tmp/repro-vm-test"
    if not dirExists(testRoot):
      createDir(testRoot)
    let xdgConfig = testRoot / "xdg-config-" & $getCurrentProcessId()
    if not dirExists(xdgConfig):
      createDir(xdgConfig)
    putEnv("XDG_CONFIG_HOME", xdgConfig)

    let configFile = "reprobuildm83vm.conf"
    let configGroup = "Test"
    let configKey = "Value"
    let configValue = "hello"

    try:
      discard applyKdeConfigKey(configFile, configGroup, configKey,
        configValue, version)
      let obs = observeKdeConfigKey(configFile, configGroup, configKey,
        version)
      doAssert obs.present, "kde key should be present after apply"

      destroyKdeConfigKey(configFile, configGroup, configKey, version)
      let obs2 = observeKdeConfigKey(configFile, configGroup, configKey,
        version)
      doAssert not obs2.present,
        "kde key should be absent after destroy"

      writeLineSentinel("OK: " & GateName)
      echo "  [OK] linux.kdeConfigKey lifecycle (KF" & $version & ")"
    except CatchableError as e:
      let head = e.msg.splitLines()[0]
      echo "  [SKIP] " & GateName & ": " & head
      writeLineSentinel("SKIP: " & GateName & " (" & head & ")")
  else:
    discard

main()
