## M83 step 13 — disposable-WSL gate for `linux.dconfKey`.
##
## The driver shells out to `dconf write` / `dconf read` / `dconf reset`,
## auto-wrapping every invocation with `dbus-run-session --` when
## `$DBUS_SESSION_BUS_ADDRESS` is empty. As long as the distro ships
## `dconf-cli` AND `dbus-run-session` (the `dbus-x11` package on Ubuntu)
## the gate exercises the full lifecycle end-to-end on a bare WSL
## rootfs without a desktop session.
##
## The only legitimate SKIP path is "the distro is missing a binary"
## (apt-get install failed) — the driver itself never SKIPs on a
## live bus or its absence.
##
## Gated by `defined(linux)` AND `REPRO_M69_DCONF_KEY_VM=1`.

import std/[os, strutils, osproc, unittest]

import repro_home_resources

const SentinelDefault = "/tmp/repro-vm-test/sentinels.txt"
const GateName = "linux.dconfKey"
const GateEnv = "REPRO_M69_DCONF_KEY_VM"
  ## Sandbox gate. The disposable-VM harness sets this; on an
  ## ordinary developer or CI host it is unset and the case
  ## below registers as a skip carrying GateSkipReason, so the
  ## run counts it and the skip census says why. It used to
  ## ``echo`` and ``quit(0)`` at module init instead, which made
  ## the binary an opaque exit-0 PASS that no gate could see.
const GateSkipReason =
  "[sandbox-gated] REPRO_M69_DCONF_KEY_VM not set."

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

proc binaryPresent(name: string): bool =
  let (output, code) = execCmdEx("command -v " & name)
  result = code == 0 and output.strip().len > 0

proc main() =
  when defined(linux):
    # Provisioning prereqs: missing-binary is a HARD failure, not a
    # SKIP — the harness installs both via apt-get in stage A. A
    # missing binary here means the harness is broken.
    #
    # These three failure paths `raise` rather than `quit(1)`. A bare
    # `quit` from inside a test body tears the process down before
    # `testEnded` writes the protocol result document, so the runner has
    # nothing to read and has to fall back to the exit code — which loses
    # the message, the checkpoints and the case's identity. Re-raising
    # lets `unittest` record a FAILED case carrying the diagnostic.
    if not binaryPresent("dconf"):
      echo "  [FAIL] " & GateName & ": dconf binary missing"
      writeLineSentinel("FAIL: " & GateName & " (dconf binary missing)")
      raise newException(IOError, GateName & ": dconf binary missing")
    if not binaryPresent("dbus-run-session"):
      echo "  [FAIL] " & GateName & ": dbus-run-session missing"
      writeLineSentinel("FAIL: " & GateName &
        " (dbus-run-session missing — install dbus-x11)")
      raise newException(IOError, GateName &
        ": dbus-run-session missing — install dbus-x11")

    # Use a namespaced key under /org/reprobuild/m83-vm-test/ so we
    # don't disturb any real GNOME settings (and there is no schema
    # for our path — dconf accepts the write anyway).
    let key = "/org/reprobuild/m83-vm-test/value"
    let value = "'hello'"  # GVariant string literal

    try:
      discard applyDconfKey(key, value)
      let obs = observeDconfKey(key)
      doAssert obs.present, "dconf key should be present after apply"
      destroyDconfKey(key)
      let obs2 = observeDconfKey(key)
      doAssert not obs2.present, "dconf key should be absent after destroy"
      writeLineSentinel("OK: " & GateName)
      echo "  [OK] linux.dconfKey lifecycle"
    except CatchableError as e:
      # A failure now is a real driver bug, NOT an environment
      # limitation — every prereq was just verified. Fail hard so
      # the harness verdict reflects it.
      let head = e.msg.splitLines()[0]
      echo "  [FAIL] " & GateName & ": " & head
      writeLineSentinel("FAIL: " & GateName & " (" & head & ")")
      raise
  else:
    discard

suite "e2e_repro_home_linux_dconfkey_vm":
  test "linux.dconfKey disposable-VM lifecycle":
    if defined(linux) and getEnv(GateEnv) == "1":
      main()
    else:
      skip(GateSkipReason)
