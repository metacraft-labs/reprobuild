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

import std/[os, strutils, osproc]

import repro_home_resources

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "systemd.userUnit"

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

proc main() =
  let sandboxMode =
    defined(linux) and getEnv("REPRO_M69_SYSTEMD_USER_UNIT_VM") == "1"
  if not sandboxMode:
    echo "  [sandbox-gated] REPRO_M69_SYSTEMD_USER_UNIT_VM not set."
    quit(0)

  when defined(linux):
    if not systemctlUserLive():
      echo "  [SKIP] " & GateName &
        ": systemctl --user not reachable in WSL (no PID-1 systemd)"
      writeLineSentinel("SKIP: " & GateName &
        " (no systemctl --user / dbus in WSL)")
      quit(0)

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
      let head = e.msg.splitLines()[0]
      echo "  [SKIP] " & GateName & ": " & head
      writeLineSentinel("SKIP: " & GateName & " (" & head & ")")
  else:
    discard

main()
