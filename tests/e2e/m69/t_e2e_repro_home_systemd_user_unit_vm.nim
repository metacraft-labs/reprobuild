## M83 step 13 — disposable-WSL gate for `systemd.userUnit` (home scope).
##
## This driver requires:
##   1. systemd running as PID 1 (NOT the case in our throwaway WSL
##      Ubuntu rootfs, which boots a plain init).
##   2. a per-user `systemctl --user` instance reachable via DBus.
##
## Inside a bare WSL rootfs without `/etc/wsl.conf` `[boot] systemd=true`
## + `wsl --terminate` activation (which the harness deliberately avoids
## per its README: that activation needs a mid-script `wsl --terminate`),
## `systemctl --user daemon-reload` returns "Failed to connect to bus".
## The driver's `applyUserUnit` raises `EResourceDriver` in that case.
##
## The gate therefore PRE-CHECKS whether `systemctl --user` can
## connect, and emits a SKIP sentinel when it can't. This documents
## the deferral exactly as the prompt's failure-resistance guidance
## allows ("what WSL cannot test, the next Linux VM catches"). The
## real `systemctl --user` flow is exercised on a Hyper-V / real-
## Linux VM.
##
## Gated by `defined(linux)` AND `REPRO_M69_SYSTEMD_USER_UNIT_VM=1`.

import std/[os, strutils, osproc, unittest]

import repro_home_resources

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "systemd.userUnit"
const GateEnv = "REPRO_M69_SYSTEMD_USER_UNIT_VM"
  ## Sandbox gate. The disposable-VM harness sets this; on an
  ## ordinary developer or CI host it is unset and the case
  ## below registers as a skip carrying GateSkipReason, so the
  ## run counts it and the skip census says why. It used to
  ## ``echo`` and ``quit(0)`` at module init instead, which made
  ## the binary an opaque exit-0 PASS that no gate could see.
const GateSkipReason =
  "[sandbox-gated] REPRO_M69_SYSTEMD_USER_UNIT_VM not set."

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

proc systemctlUserLive(): bool =
  ## Quick smoke that `systemctl --user` is reachable. A non-zero exit
  ## means no user dbus / no systemd-as-PID-1.
  let (_, code) = execCmdEx("systemctl --user is-system-running 2>&1")
  result = code == 0

proc main(): string =
  ## Returns "" when the scenario ran, or a skip reason when a
  ## secondary in-VM prerequisite is missing.
  when defined(linux):
    if not systemctlUserLive():
      writeLineSentinel("SKIP: " & GateName &
        " (no systemctl --user / dbus in WSL)")
      # Returning the reason (rather than ``quit(0)``) keeps the case a
      # reported SKIP. A bare ``quit`` from inside a test body exits
      # before the protocol result document is written, so the runner
      # would have to fall back to the exit code and call it a PASS.
      return GateName &
        ": systemctl --user not reachable in WSL (no PID-1 systemd)"

    let homeDir = getEnv("HOME", "/root")
    let unitName = "repro-m83-vm-" & $getCurrentProcessId() & ".service"
    let unitContent =
      "[Unit]\n" &
      "Description=Reprobuild M83 step 13 systemd user-unit smoke\n" &
      "[Service]\n" &
      "Type=oneshot\n" &
      "ExecStart=/bin/true\n"

    try:
      discard applyUserUnit(homeDir, unitName, unitContent,
        enabled = false, state = susStopped)
      let obs = observeUserUnit(homeDir, unitName)
      doAssert obs.present, "user unit should be present after apply"
      destroyUserUnit(homeDir, unitName)
      let obs2 = observeUserUnit(homeDir, unitName)
      doAssert not obs2.present, "user unit should be absent after destroy"
      writeLineSentinel("OK: " & GateName)
      echo "  [OK] systemd.userUnit lifecycle"
    except CatchableError as e:
      # The reachability of `systemctl --user` is decided ABOVE, before
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

suite "e2e_repro_home_systemd_user_unit_vm":
  test "systemd.userUnit disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      let secondaryGate = main()
      if secondaryGate.len > 0:
        skip(secondaryGate)
    else:
      skip(GateSkipReason)
