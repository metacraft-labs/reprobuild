## M83 step 13 — disposable-WSL gate for `linux.kdeConfigKey`.
##
## The driver shells out to `kwriteconfig5`/`kwriteconfig6` and
## `kreadconfig5`/`kreadconfig6`. These binaries live in
## `libkf5config-bin` (KDE Frameworks 5) on Ubuntu 22.04 or
## `kf6-kconfig-bin` (KF6). If neither is installed, the gate emits a
## SKIP sentinel rather than failing the harness.
##
## Gated by `defined(linux)` AND `REPRO_M69_KDE_CONFIG_KEY_VM=1`.

import std/[os, strutils, osproc, unittest]

import repro_home_resources

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "linux.kdeConfigKey"
const GateEnv = "REPRO_M69_KDE_CONFIG_KEY_VM"
  ## Sandbox gate. The disposable-VM harness sets this; on an
  ## ordinary developer or CI host it is unset and the case
  ## below registers as a skip carrying GateSkipReason, so the
  ## run counts it and the skip census says why. It used to
  ## ``echo`` and ``quit(0)`` at module init instead, which made
  ## the binary an opaque exit-0 PASS that no gate could see.
const GateSkipReason =
  "[sandbox-gated] REPRO_M69_KDE_CONFIG_KEY_VM not set."

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

proc main(): string =
  ## Returns "" when the scenario ran, or a skip reason when a
  ## secondary in-VM prerequisite is missing.
  when defined(linux):
    let version = pickKdeVersion()
    if version == 0:
      writeLineSentinel("SKIP: " & GateName &
        " (kwriteconfig5/6 missing)")
      # Returning the reason (rather than ``quit(0)``) keeps the case a
      # reported SKIP. A bare ``quit`` from inside a test body exits
      # before the protocol result document is written, so the runner
      # would have to fall back to the exit code and call it a PASS.
      return GateName & ": kwriteconfig5/6 not installed"

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
      # Whether `kwriteconfig5/6` exists at all is decided ABOVE, before
      # any work starts. Anything raised from here down is an operational
      # failure of the apply/observe/destroy lifecycle itself, and it
      # fails the case.
      #
      # This used to write a SKIP sentinel and fall out of the `except`
      # with no re-raise, so the enclosing case body completed normally
      # and `unittest` recorded a PASS while the sentinel file said SKIP
      # and the lifecycle had not run. `doAssert` raises `AssertionDefect`
      # (a `Defect`), so the assertions above still propagated; what the
      # swallow hid was exactly the `OSError`/`IOError`/`EResourceDriver`
      # class this gate exists to detect.
      let head = e.msg.splitLines()[0]
      echo "  [FAIL] " & GateName & ": " & head
      writeLineSentinel("FAIL: " & GateName & " (" & head & ")")
      raise
  else:
    discard

suite "e2e_repro_home_linux_kdeconfigkey_vm":
  test "linux.kdeConfigKey disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      let secondaryGate = main()
      if secondaryGate.len > 0:
        skip(secondaryGate)
    else:
      skip(GateSkipReason)
